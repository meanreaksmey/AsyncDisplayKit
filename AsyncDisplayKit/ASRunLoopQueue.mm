//
//  ASRunLoopQueue.mm
//  AsyncDisplayKit
//
//  Created by Rahul Malik on 3/7/16.
//
//  Copyright (c) 2014-present, Facebook, Inc.  All rights reserved.
//  This source code is licensed under the BSD-style license found in the
//  LICENSE file in the root directory of this source tree. An additional grant
//  of patent rights can be found in the PATENTS file in the same directory.
//

#import "ASRunLoopQueue.h"
#import "ASThread.h"
#import "ASLog.h"

#import <cstdlib>
#import <deque>

#define ASRunLoopQueueLoggingEnabled 0

static void runLoopSourceCallback(void *info) {
  // No-op
#if ASRunLoopQueueLoggingEnabled
  NSLog(@"<%@> - Called runLoopSourceCallback", info);
#endif
}

#pragma mark - ASDeallocThread

@interface ASDeallocThread : NSThread
@property (nonatomic, strong) ASRunLoopQueue *deallocQueue;
@end

@implementation ASDeallocThread

- (void)main
{
  self.name = @"ASDeallocThread";
  [self deallocQueue];
  while (YES) {
    // This method will still return once all sources have finished.
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate distantFuture]];
    // Waiting 100ms allows some objects to collect without too much thrash.
    [NSThread sleepForTimeInterval:0.1];
  }
  ASDisplayNodeFailAssert(@"ASDeallocThread should never exit");
}

- (ASRunLoopQueue *)deallocQueue
{
  if (_deallocQueue == nil) {
    _deallocQueue = [[ASRunLoopQueue alloc] initWithRunLoop:CFRunLoopGetCurrent() andHandler:nil];
    _deallocQueue.ensureExclusiveMembership = NO;
  }
  ASDisplayNodeAssertNotNil(_deallocQueue, @"Starting dealloc thread should have created dealloc queue");
  return _deallocQueue;
}

@end

#pragma mark - ASRunLoopQueue

@interface ASRunLoopQueue () {
  CFRunLoopRef _runLoop;
  CFRunLoopObserverRef _runLoopObserver;
  CFRunLoopSourceRef _runLoopSource;
  std::deque<id> _internalQueue;
  ASDN::RecursiveMutex _internalQueueLock;
  
#if ASRunLoopQueueLoggingEnabled
  NSTimer *_runloopQueueLoggingTimer;
#endif
}

@property (nonatomic, copy) void (^queueConsumer)(id dequeuedItem, BOOL isQueueDrained);

@end

@implementation ASRunLoopQueue

+ (instancetype)sharedDeallocationQueue
{
  static ASDeallocThread *deallocThread = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    deallocThread = [[ASDeallocThread alloc] init];
    [deallocThread start];
  });
  return [deallocThread deallocQueue];
}

- (instancetype)initWithRunLoop:(CFRunLoopRef)runloop andHandler:(void(^)(id dequeuedItem, BOOL isQueueDrained))handlerBlock
{
  if (self = [super init]) {
    _runLoop = runloop;
    _internalQueue = std::deque<id>();
    _queueConsumer = [handlerBlock copy];
    _batchSize = 1;
    _ensureExclusiveMembership = YES;
    
    // Self is guaranteed to outlive the observer.  Without the high cost of a weak pointer,
    // __unsafe_unretained allows us to avoid flagging the memory cycle detector.
    __unsafe_unretained __typeof__(self) weakSelf = self;
    void (^handlerBlock) (CFRunLoopObserverRef observer, CFRunLoopActivity activity) = ^(CFRunLoopObserverRef observer, CFRunLoopActivity activity) {
      [weakSelf processQueue];
    };
    _runLoopObserver = CFRunLoopObserverCreateWithHandler(NULL, kCFRunLoopBeforeWaiting, true, 0, handlerBlock);
    CFRunLoopAddObserver(_runLoop, _runLoopObserver,  kCFRunLoopCommonModes);
    
    // It is not guaranteed that the runloop will turn if it has no scheduled work, and this causes processing of
    // the queue to stop. Attaching a custom loop source to the run loop and signal it if new work needs to be done
    CFRunLoopSourceContext *runLoopSourceContext = (CFRunLoopSourceContext *)calloc(1, sizeof(CFRunLoopSourceContext));
    if (runLoopSourceContext) {
      runLoopSourceContext->perform = runLoopSourceCallback;
#if ASRunLoopQueueLoggingEnabled
      runLoopSourceContext->info = (__bridge void *)self;
#endif
      _runLoopSource = CFRunLoopSourceCreate(NULL, 0, runLoopSourceContext);
      CFRunLoopAddSource(runloop, _runLoopSource, kCFRunLoopCommonModes);
      free(runLoopSourceContext);
    }

#if ASRunLoopQueueLoggingEnabled
    _runloopQueueLoggingTimer = [NSTimer timerWithTimeInterval:1.0 target:self selector:@selector(checkRunLoop) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_runloopQueueLoggingTimer forMode:NSRunLoopCommonModes];
#endif
  }
  return self;
}

- (void)dealloc
{
  if (CFRunLoopContainsSource(_runLoop, _runLoopSource, kCFRunLoopCommonModes)) {
    CFRunLoopRemoveSource(_runLoop, _runLoopSource, kCFRunLoopCommonModes);
  }
  CFRelease(_runLoopSource);
  _runLoopSource = nil;
  
  if (CFRunLoopObserverIsValid(_runLoopObserver)) {
    CFRunLoopObserverInvalidate(_runLoopObserver);
  }
  CFRelease(_runLoopObserver);
  _runLoopObserver = nil;
}

#if ASRunLoopQueueLoggingEnabled
- (void)checkRunLoop
{
    NSLog(@"<%@> - Jobs: %ld", self, _internalQueue.size());
}
#endif

- (void)processQueue
{
  if (_queueConsumer == nil) {
    // If we have no block to run on each item, just dump the entire queue (e.g. sharedDeallocationQueue)
    _internalQueueLock.lock();
    _internalQueue.clear();
    _internalQueueLock.unlock();
    return;
  }
  
  std::deque<id> itemsToProcess = std::deque<id>();
  
  BOOL isQueueDrained = NO;
  {
    ASDN::MutexLocker l(_internalQueueLock);

    // Early-exit if the queue is empty.
    if (_internalQueue.empty()) {
      return;
    }
    
    ASProfilingSignpostStart(0, self);

    // Snatch the next batch of items.
    NSUInteger totalNodeCount = _internalQueue.size();
    for (int i = 0; i < MIN(self.batchSize, totalNodeCount); i++) {
      id node = _internalQueue[0];
      itemsToProcess.push_back(node);
      _internalQueue.pop_front();
    }

    if (_internalQueue.empty()) {
      isQueueDrained = YES;
    }
  }

  unsigned long numberOfItems = itemsToProcess.size();
  for (int i = 0; i < numberOfItems; i++) {
    if (isQueueDrained && i == numberOfItems - 1) {
      _queueConsumer(itemsToProcess[i], YES);
    } else {
      _queueConsumer(itemsToProcess[i], isQueueDrained);
    }
  }

  // If the queue is not fully drained yet force another run loop to process next batch of items
  if (!isQueueDrained) {
    CFRunLoopSourceSignal(_runLoopSource);
    CFRunLoopWakeUp(_runLoop);
  }
  
  ASProfilingSignpostEnd(0, self);
}

- (void)enqueue:(id)object
{
  if (!object) {
    return;
  }
  
  // Check if the object exists.
  BOOL foundObject = NO;
  
  _internalQueueLock.lock();
  
  if (_ensureExclusiveMembership) {
    for (id currentObject : _internalQueue) {
      if (currentObject == object) {
        foundObject = YES;
        break;
      }
    }
  }

  if (!foundObject) {
    _internalQueue.push_back(object);
    _internalQueueLock.unlock();
    
    CFRunLoopSourceSignal(_runLoopSource);
    CFRunLoopWakeUp(_runLoop);
  } else {
    _internalQueueLock.unlock();
  }
}

@end
