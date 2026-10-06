// Prepares a medium from inside the development app: the burn window's own
// controller, destination a disc image, every image of the active local database.
// Injected with DYLD_INSERT_LIBRARIES.
//
//   HOROS_BURN_TRIGGER   a path: start once that file exists
//   HOROS_BURN_DMG       where the disc image goes (the save panel answers with it)
//   HOROS_BURN_LOG       a JSON lines file
//   HOROS_BURN_ESTIMATES how many times to time -estimateFolderSize: (default 50)
//   HOROS_BURN_ANONYMIZE if set, the anonymization panel of an anonymized burn is
//                        answered OK, with the fields the defaults hold
//   HOROS_BURN_VOLUME    a mounted test volume: the burn goes to it as to a USB
//                        key, and its "erase" confirmation is answered OK. The
//                        probe refuses to burn unless that volume is the only one
//                        the window offers, so no other volume can be erased
//
// Lines written: {"estimate": {"text", "us": [...]}} - the size field's text and
// the time of each estimate - then {"burn": {...}} when the burn has ended: the
// seconds from -burn: to the end, whether the disc image exists, and the text of
// any alert the window raised instead (a failure is shown, not a success).
//
//   xcrun clang -dynamiclib -fobjc-arc -framework Cocoa tools/probe-burn-media.m -o probe-burn-media.dylib
#import <Cocoa/Cocoa.h>
#include <objc/runtime.h>
#include <mach/mach_time.h>

@interface NSObject (BurnMediaProbe)
+ (id)activeLocalDatabase;
- (NSArray *)objectsForEntity:(id)entity;
- (id)entityForName:(NSString *)name;
- (id)initWithFiles:(NSArray *)files managedObjects:(NSArray *)objects;
- (IBAction)burn:(id)sender;
- (IBAction)estimateFolderSize:(id)sender;
- (BOOL)buttonsDisabled;
- (NSArray *)volumes;
- (IBAction)actionOk:(id)sender;
@end

static NSString *logPath, *dmgPath, *volumePath;
static BOOL anonymize;

static void writeLine(NSDictionary *object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (!handle) {
        [[NSData data] writeToFile:logPath atomically:NO];
        handle = [NSFileHandle fileHandleForWritingAtPath:logPath];
    }
    [handle seekToEndOfFile];
    [handle writeData:data];
    [handle writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];
}

static double microseconds(uint64_t start, uint64_t end) {
    static mach_timebase_info_data_t timebase;
    if (timebase.denom == 0) mach_timebase_info(&timebase);
    return (double)(end - start) * timebase.numer / timebase.denom / 1000.0;
}

// Runs a block on the main thread and waits for it. A run loop block in the common
// modes, not dispatch_sync: the window raises a failure with -[NSAlert runModal]
// inside a main queue block, and the main queue runs nothing else until that alert
// is dismissed, so a dispatch_sync would wait for it forever.
static void onMainThread(void (^block)(void)) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
        block();
        dispatch_semaphore_signal(done);
    });
    CFRunLoopWakeUp(CFRunLoopGetMain());
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
}

// The text of every visible alert, its fields at any depth.
static NSString *alertText(void) {
    NSMutableArray *texts = [NSMutableArray array];
    for (NSWindow *window in NSApp.windows) {
        if (!window.isVisible || ![window.className containsString:@"Alert"]) continue;
        NSMutableArray *views = [NSMutableArray arrayWithObject:window.contentView];
        while (views.count) {
            NSView *view = views.lastObject;
            [views removeLastObject];
            if ([view isKindOfClass:NSTextField.class] && [(NSTextField *)view stringValue].length)
                [texts addObject:[(NSTextField *)view stringValue]];
            [views addObjectsFromArray:view.subviews];
        }
    }
    return texts.count ? [texts componentsJoinedByString:@" | "] : nil;
}

// The anonymization panel -burn: runs before it starts the thread, answered OK.
// Nothing else is answered here: a failure alert stays up to be read.
static void answerBurnPanels(void) {
    NSWindow *modal = NSApp.modalWindow;
    id owner = modal.windowController;
    if (anonymize && [NSStringFromClass([owner class]) containsString:@"Anonymization"] && [owner respondsToSelector:@selector(actionOk:)]) {
        writeLine(@{@"answered": @"anonymization panel"});
        [owner actionOk:nil];
        return;
    }
}

// +[HorosAlertPanel runCriticalWithTitle:...]: the confirmation that the test
// volume will be erased is answered with its default button, without a window
// (the alert's own modal loop runs no timer). Every other alert runs as before.
static IMP originalRunCritical;
static NSInteger answerRunCritical(id cls, SEL selector, NSString *title, NSString *message, NSString *defaultButton,
                                   NSString *alternateButton, NSString *otherButton) {
    if (volumePath && [message containsString:volumePath] && [message containsString:@"ENTIRE"]) {
        writeLine(@{@"answered": @"erase confirmation"});
        return 1; // NSAlertDefaultReturn
    }
    return ((NSInteger (*)(id, SEL, NSString *, NSString *, NSString *, NSString *, NSString *))originalRunCritical)(
        cls, selector, title, message, defaultButton, alternateButton, otherButton);
}

// The save panel of a DMG burn: answered with HOROS_BURN_DMG, never shown.
static NSModalResponse answerSavePanel(id panel, SEL selector) { return NSModalResponseOK; }
static NSURL *savePanelURL(id panel, SEL selector) { return [NSURL fileURLWithPath:dmgPath]; }

__attribute__((constructor)) static void installBurnMediaProbe(void) {
    NSDictionary *environment = NSProcessInfo.processInfo.environment;
    NSString *trigger = environment[@"HOROS_BURN_TRIGGER"];
    dmgPath = environment[@"HOROS_BURN_DMG"];
    logPath = environment[@"HOROS_BURN_LOG"];
    volumePath = environment[@"HOROS_BURN_VOLUME"];
    anonymize = environment[@"HOROS_BURN_ANONYMIZE"] != nil;
    NSInteger estimates = environment[@"HOROS_BURN_ESTIMATES"] ? [environment[@"HOROS_BURN_ESTIMATES"] integerValue] : 50;
    if (!trigger || !dmgPath || !logPath) return;
    unsetenv("DYLD_INSERT_LIBRARIES");
    method_setImplementation(class_getInstanceMethod(NSSavePanel.class, @selector(runModal)), (IMP)answerSavePanel);
    method_setImplementation(class_getInstanceMethod(NSSavePanel.class, @selector(URL)), (IMP)savePanelURL);
    writeLine(@{@"probe": @"loaded"});
    [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil
                                                     queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        if (volumePath) {
            Method runCritical = class_getClassMethod(NSClassFromString(@"HorosAlertPanel"),
                                                      NSSelectorFromString(@"runCriticalWithTitle:message:defaultButton:alternateButton:otherButton:"));
            if (runCritical) originalRunCritical = method_setImplementation(runCritical, (IMP)answerRunCritical);
        }
        [NSThread detachNewThreadWithBlock:^{
            @autoreleasepool {
                for (int wait = 0; wait < 3000 && ![NSFileManager.defaultManager fileExistsAtPath:trigger]; wait++)
                    usleep(100000);
                __block id controller = nil;
                __block NSMutableDictionary *estimate = [NSMutableDictionary dictionary];
                onMainThread(^{
                    id database = [NSClassFromString(@"DicomDatabase") activeLocalDatabase];
                    NSArray *images = [database objectsForEntity:[database entityForName:@"Image"]];
                    NSArray *paths = [images valueForKey:@"completePath"];
                    NSArray *identifiers = [images valueForKey:@"objectID"];
                    controller = [[NSClassFromString(@"BurnerWindowController") alloc] initWithFiles:paths managedObjects:identifiers];
                    [controller showWindow:nil];
                    NSMutableArray *times = [NSMutableArray array];
                    for (NSInteger i = 0; i < estimates; i++) {
                        uint64_t t0 = mach_absolute_time();
                        [controller estimateFolderSize:nil];
                        [times addObject:@(microseconds(t0, mach_absolute_time()))];
                    }
                    NSTextField *field = [controller valueForKey:@"sizeField"];
                    estimate[@"text"] = field.stringValue ?: @"";
                    estimate[@"us"] = times;
                    estimate[@"files"] = @(paths.count);
                });
                writeLine(@{@"estimate": estimate});
                if (volumePath) {
                    // The only volume offered must be the test volume: -burn: erases the one selected.
                    __block NSArray *offered = nil;
                    onMainThread(^{ offered = [controller volumes]; });
                    if (offered.count != 1 || ![offered.firstObject isEqual:volumePath]) {
                        writeLine(@{@"burn": @{@"refused": [NSString stringWithFormat:@"volumes offered: %@", offered], @"finished": @NO,
                                               @"dmg_exists": @NO, @"alert": [NSNull null]}});
                        return;
                    }
                    onMainThread(^{ [controller setValue:@0 forKey:@"selectedUSB"]; });
                }
                NSTimer *answer = [NSTimer timerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *timer) { answerBurnPanels(); }];
                onMainThread(^{ [NSRunLoop.mainRunLoop addTimer:answer forMode:NSRunLoopCommonModes]; });
                uint64_t start = mach_absolute_time();
                onMainThread(^{ [controller burn:nil]; });
                // The burn runs on a thread of its own; the window disables its
                // buttons meanwhile and enables them again at the end, success or not.
                usleep(300 * 1000);
                __block BOOL busy = YES;
                __block NSString *alert = nil;
                for (int wait = 0; wait < 1200 && busy; wait++) {
                    usleep(100 * 1000);
                    onMainThread(^{
                        busy = [controller buttonsDisabled];
                        alert = alertText() ?: alert;
                    });
                }
                usleep(500 * 1000);
                onMainThread(^{ alert = alertText() ?: alert; [answer invalidate]; });
                writeLine(@{@"burn": @{@"seconds": @(microseconds(start, mach_absolute_time()) / 1e6), @"finished": @(!busy),
                                       @"dmg_exists": @([NSFileManager.defaultManager fileExistsAtPath:dmgPath]),
                                       @"alert": alert ?: [NSNull null]}});
            }
        }];
    }];
}
