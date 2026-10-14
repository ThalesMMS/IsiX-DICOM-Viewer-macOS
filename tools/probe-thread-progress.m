// In-app recorder of thread progress notifications, injected into the
// development app with DYLD_INSERT_LIBRARIES.
//
// Every thread handed to -[ThreadsManager addThreadAndStart:] - the source of
// the activity window: incoming imports, retrieves, remote database updates -
// gets an observer for the keys the activity cell and the progress window
// observe. When the thread exits, one JSON line records its name and, for each
// key, [notifications, redundant, changes]: every notification received, those
// whose value read before equals the value read after, and those announcing a
// value other than the previous notification's (a change notified twice, once
// nested in the other, counts two notifications and one change); plus the last
// details a notification announced and the details the thread reads as it exits.
//
// It also drives the flows the validation needs, each named by the environment:
//   HOROS_THREAD_PROGRESS_LOG      the JSON lines file (required)
//   HOROS_THREAD_PROGRESS_REMOTE   a port: opens the app's own shared database as
//                                  a remote one and runs an update (index download)
//   HOROS_THREAD_PROGRESS_RETRIEVE a servers JSON file: C-GET retrieve of the first
//                                  study of the first node, on a thread started the
//                                  way the query window starts it
//   HOROS_THREAD_PROGRESS_CANCEL_AFTER seconds: then cancels that retrieve the way
//                                  the activity window's cancel button does
//   HOROS_THREAD_PROGRESS_CANCEL_NAMED a thread name: with CANCEL_AFTER, cancels the
//                                  first thread of that name the app starts itself
//                                  (an XML-RPC retrieve), the same way
//   HOROS_THREAD_PROGRESS_TRIGGER  a path: drive once that file exists (the harness
//                                  writes it when the database is ready)
//
//   xcrun clang -dynamiclib -fobjc-arc -framework Cocoa tools/probe-thread-progress.m -o probe.dylib
#import <Cocoa/Cocoa.h>
#include <objc/runtime.h>

@interface NSObject (ThreadProgressProbe)
+ (id)defaultManager;
- (void)addThreadAndStart:(NSThread *)thread;
+ (id)databaseForLocation:(NSString *)location port:(NSUInteger)port name:(NSString *)name update:(BOOL)update;
- (NSThread *)initiateUpdate;
- (id)initWithDataset:(void *)d callingAET:(id)a calledAET:(id)b hostname:(id)c port:(int)p transferSyntax:(int)t
          compression:(float)f extraParameters:(id)e;
- (id)initWithCallingAET:(id)a distantServer:(id)s;
- (void)setShowErrorMessage:(BOOL)b;
- (void)setNoSmartMode:(BOOL)b;
- (void)queryWithValues:(id)v;
- (NSArray *)children;
- (void)performRetrieve:(NSArray *)a;
- (NSUInteger)countOfSuccessfulSuboperations;
- (NSUInteger)countOfSuboperations;
@end

@interface NSThread (ThreadProgressProbe)
- (NSString *)status;
- (void)setStatus:(NSString *)status;
- (NSString *)progressDetails;
- (void)setSupportsCancel:(BOOL)supportsCancel;
- (void)setIsCancelled:(BOOL)isCancelled;
@end

static NSArray<NSString *> *const ObservedKeys(void) {
    return @[@"status", @"progress", @"progressDetails", @"isCancelled", @"supportsCancel", @"supportsBackgrounding"];
}

static FILE *logFile = NULL;

static void writeLine(NSDictionary *object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
    if (!data || !logFile) return;
    flockfile(logFile);
    fwrite(data.bytes, 1, data.length, logFile);
    fputc('\n', logFile);
    fflush(logFile);
    funlockfile(logFile);
}

static double uptime(void) {
    return NSProcessInfo.processInfo.systemUptime;
}

@interface ThreadProgressRecorder : NSObject
@property (strong) NSMutableDictionary<NSString *, NSMutableArray<NSNumber *> *> *counts;
@property (strong) NSMutableDictionary<NSString *, id> *lastAnnounced;
@property (copy) NSString *lastAnnouncedDetails;
@property BOOL announcedDetails;
@property double observedAt, knownProgressAt;
@property (strong) NSMutableArray<NSString *> *statuses;
@end

@implementation ThreadProgressRecorder

- (instancetype)init {
    if ((self = [super init])) {
        _counts = [NSMutableDictionary dictionary];
        _lastAnnounced = [NSMutableDictionary dictionary];
        for (NSString *key in ObservedKeys()) _counts[key] = [@[@0, @0, @0] mutableCopy];
        _statuses = [NSMutableArray array];
        _knownProgressAt = -1;
    }
    return self;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    id old = change[NSKeyValueChangeOldKey], new = change[NSKeyValueChangeNewKey];
    if ([old isKindOfClass:NSNull.class]) old = nil;
    if ([new isKindOfClass:NSNull.class]) new = nil;
    BOOL redundant = old == new || [old isEqual:new];
    @synchronized (self) {
        NSMutableArray<NSNumber *> *count = self.counts[keyPath];
        count[0] = @([count[0] integerValue] + 1);
        if (redundant) count[1] = @([count[1] integerValue] + 1);
        id previous = self.lastAnnounced[keyPath];
        id announced = new ?: [NSNull null];
        if (!previous || ![previous isEqual:announced]) count[2] = @([count[2] integerValue] + 1);
        self.lastAnnounced[keyPath] = announced;
        // When the bar first had a value instead of sweeping, and the titles
        // the row showed: the first ones and the last.
        if ([keyPath isEqualToString:@"progress"] && self.knownProgressAt < 0 && [new doubleValue] >= 0 && new)
            self.knownProgressAt = uptime() - self.observedAt;
        if ([keyPath isEqualToString:@"status"] && [new isKindOfClass:NSString.class] && ![self.statuses.lastObject isEqual:new]) {
            if (self.statuses.count >= 6) [self.statuses removeLastObject];
            [self.statuses addObject:new];
        }
        if ([keyPath isEqualToString:@"progressDetails"]) {
            self.lastAnnouncedDetails = new;
            self.announcedDetails = YES;
        }
    }
}

@end

static NSMutableSet<NSValue *> *observedThreads;
static void (*originalAddThread)(id, SEL, NSThread *);

static void observeThread(NSThread *thread) {
    NSValue *identity = [NSValue valueWithNonretainedObject:thread];
    @synchronized (observedThreads) {
        if (thread.isFinished || [observedThreads containsObject:identity]) return;
        [observedThreads addObject:identity];
    }
    ThreadProgressRecorder *recorder = [ThreadProgressRecorder new];
    recorder.observedAt = uptime();
    for (NSString *key in ObservedKeys())
        [thread addObserver:recorder forKeyPath:key options:NSKeyValueObservingOptionOld | NSKeyValueObservingOptionNew context:NULL];
    double observedAt = uptime();
    // The app's ThreadsManager waits for the same notification to drop the thread.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSNotificationName willExit = NSThreadWillExitNotification;
#pragma clang diagnostic pop
    __block id token = [NSNotificationCenter.defaultCenter addObserverForName:willExit object:thread
                                                                       queue:nil usingBlock:^(NSNotification *note) {
        NSMutableDictionary *line = [NSMutableDictionary dictionary];
        @synchronized (recorder) {
            line[@"thread"] = thread.name ?: @"";
            line[@"observed_seconds"] = @(uptime() - observedAt);
            line[@"counts"] = recorder.counts;
            line[@"known_progress_seconds"] = recorder.knownProgressAt < 0 ? [NSNull null] : @(recorder.knownProgressAt);
            line[@"statuses"] = recorder.statuses;
            line[@"last_announced_details"] = recorder.announcedDetails ? (recorder.lastAnnouncedDetails ?: [NSNull null]) : @"(none)";
        }
        line[@"details_read_at_exit"] = thread.progressDetails ?: [NSNull null];
        line[@"status_at_exit"] = thread.status ?: [NSNull null];
        line[@"cancelled"] = @(thread.isCancelled);
        for (NSString *key in ObservedKeys()) [thread removeObserver:recorder forKeyPath:key];
        [NSNotificationCenter.defaultCenter removeObserver:token];
        writeLine(@{@"thread_exit": line});
    }];
}

static NSString *cancelNamed = nil;
static double cancelNamedAfter = 0;

static void addThreadAndStart(id manager, SEL selector, NSThread *thread) {
    if (thread && !thread.isMainThread) observeThread(thread);
    originalAddThread(manager, selector, thread);
    if (thread && cancelNamed && [thread.name isEqualToString:cancelNamed]) {
        cancelNamed = nil;  // the first one only
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(cancelNamedAfter * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (thread.isFinished) return;
            // What -[ThreadCell cancelThreadAction:] does.
            [thread setStatus:@"Cancelling..."];
            [thread setIsCancelled:YES];
            writeLine(@{@"cancel_named": thread.name});
        });
    }
}

static NSThread *waitForThread(NSThread *thread, double seconds) {
    double deadline = uptime() + seconds;
    while (thread && !thread.isFinished && uptime() < deadline) usleep(20000);
    return thread;
}

static void driveRemoteUpdate(NSUInteger port) {
    double start = uptime();
    NSMutableDictionary *line = [NSMutableDictionary dictionary];
    @try {
        id remote = [NSClassFromString(@"RemoteDicomDatabase") databaseForLocation:@"127.0.0.1" port:port
                                                                             name:@"thread progress probe" update:NO];
        NSThread *thread = [remote initiateUpdate];
        line[@"started"] = @(thread != nil);
        waitForThread(thread, 120);
        line[@"finished"] = @(thread.isFinished);
    } @catch (NSException *e) {
        line[@"exception"] = [NSString stringWithFormat:@"%@: %@", e.name, e.reason];
    }
    line[@"seconds"] = @(uptime() - start);
    writeLine(@{@"remote_update": line});
}

static void driveRetrieve(NSString *serversPath, double cancelAfter) {
    NSArray *servers = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:serversPath] options:0 error:NULL];
    NSDictionary *server = servers.firstObject;
    NSMutableDictionary *line = [NSMutableDictionary dictionary];
    if (!server) {
        writeLine(@{@"retrieve": @{@"error": @"no server"}});
        return;
    }
    id root = [[NSClassFromString(@"DCMTKRootQueryNode") alloc] initWithDataset:NULL callingAET:@"HOROSDEV"
                                                                      calledAET:server[@"AETitle"] hostname:@"127.0.0.1"
                                                                           port:[server[@"Port"] intValue] transferSyntax:0
                                                                    compression:0 extraParameters:server];
    [root setShowErrorMessage:NO];
    [root queryWithValues:@[]];
    id study = [[root children] firstObject];
    if (!study) {
        writeLine(@{@"retrieve": @{@"error": @"no study"}});
        return;
    }
    [study setNoSmartMode:YES];
    [study setShowErrorMessage:NO];
    __block NSThread *thread = nil;
    __block id controller = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        // As -[QueryController retrieve...] starts it: a named thread with a
        // status, cancellable, handed to the activity window's manager.
        controller = [[NSClassFromString(@"QueryController") alloc] initWithWindow:nil];
        id manager = [[NSClassFromString(@"QueryArrayController") alloc] initWithCallingAET:@"HOROSDEV" distantServer:server];
        [controller setValue:manager forKey:@"queryManager"];
        thread = [[NSThread alloc] initWithTarget:controller selector:@selector(performRetrieve:) object:@[study]];
        thread.name = @"Retrieving images...";
        [thread setStatus:@"1 study"];
        [thread setSupportsCancel:YES];
        [[NSClassFromString(@"ThreadsManager") defaultManager] addThreadAndStart:thread];
    });
    double start = uptime();
    if (cancelAfter > 0) {
        while (!thread.isFinished && uptime() - start < cancelAfter) usleep(20000);
        if (!thread.isFinished) {
            line[@"cancel_requested_seconds"] = @(uptime() - start);
            dispatch_sync(dispatch_get_main_queue(), ^{
                // What -[ThreadCell cancelThreadAction:] does.
                [thread setStatus:@"Cancelling..."];
                [thread setIsCancelled:YES];
            });
        }
    }
    // What the Dock tile showed meanwhile, twice a second: its percentages,
    // and how many samples showed the plain icon.
    NSMutableArray *dock = [NSMutableArray array];
    NSUInteger plain = 0;
    for (double deadline = uptime() + 120; !thread.isFinished && uptime() < deadline; usleep(500000)) {
        __block NSNumber *percent = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{
            percent = [[NSClassFromString(@"HorosDockProgress") valueForKey:@"shared"] valueForKey:@"displayedPercent"];
        });
        if (!percent) plain++;
        else if (![dock.lastObject isEqual:percent]) [dock addObject:percent];
    }
    line[@"dock_percents"] = dock;
    line[@"dock_plain_samples"] = @(plain);
    line[@"finished"] = @(thread.isFinished);
    line[@"cancelled"] = @(thread.isCancelled);
    line[@"seconds"] = @(uptime() - start);
    line[@"received"] = @([study countOfSuccessfulSuboperations]);
    line[@"expected"] = @([study countOfSuboperations]);
    writeLine(@{@"retrieve": line});
}

__attribute__((constructor)) static void installThreadProgressProbe(void) {
    const char *path = getenv("HOROS_THREAD_PROGRESS_LOG");
    if (!path) return;
    logFile = fopen(path, "a");
    if (!logFile) return;
    NSDictionary *environment = NSProcessInfo.processInfo.environment;
    unsetenv("DYLD_INSERT_LIBRARIES");
    observedThreads = [NSMutableSet set];
    Method add = class_getInstanceMethod(NSClassFromString(@"ThreadsManager"), @selector(addThreadAndStart:));
    if (add) originalAddThread = (void (*)(id, SEL, NSThread *))method_setImplementation(add, (IMP)addThreadAndStart);
    writeLine(@{@"probe": @"loaded", @"threads_manager_hooked": @(add != NULL)});

    NSString *remote = environment[@"HOROS_THREAD_PROGRESS_REMOTE"];
    NSString *retrieve = environment[@"HOROS_THREAD_PROGRESS_RETRIEVE"];
    double cancelAfter = [environment[@"HOROS_THREAD_PROGRESS_CANCEL_AFTER"] doubleValue];
    cancelNamed = environment[@"HOROS_THREAD_PROGRESS_CANCEL_NAMED"];
    cancelNamedAfter = cancelAfter;
    NSString *trigger = environment[@"HOROS_THREAD_PROGRESS_TRIGGER"];
    if ((!remote && !retrieve) || !trigger) return;
    [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil
                                                     queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            @autoreleasepool {
                double deadline = uptime() + 300;
                while (![NSFileManager.defaultManager fileExistsAtPath:trigger] && uptime() < deadline) usleep(100000);
                writeLine(@{@"driving": @"started"});
                if (remote) driveRemoteUpdate((NSUInteger)remote.integerValue);
                if (retrieve) driveRetrieve(retrieve, cancelAfter);
                writeLine(@{@"driving": @"done"});
            }
        });
    }];
}
