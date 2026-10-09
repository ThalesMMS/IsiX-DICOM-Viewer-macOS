// A burst of scroll events on the 3D MPR, from inside the development app, injected with
// DYLD_INSERT_LIBRARIES and driven by numbered command files.
//
//   HOROS_MPR_COMMANDS  a folder: <n>.json is run for n = 1, 2, ... in order, and answered in
//                       <n>.out.json (written whole, then renamed)
//
//   {"action": "ping"}
//   {"action": "open", "series": "<SeriesInstanceUID>", "mode": 1, "thickness_mm": 1, "wl": 40, "ww": 400}
//       the series opened as the browser opens it, then its 3D MPR (-openMPRViewer, as the toolbar does):
//       clipping mode (1 MIP), slab thickness, WL/WW on the three views, 100 % (-actualSize:). MPR always
//       uses Metal; with "fill_screen" the window takes the screen's visible frame first. Answers the
//       window number and each view's frame in screen points, top-left origin.
//   {"action": "burst", "view": 1|2|3, "events": 120, "delta": 1.5, "first": 1|-1, "interval_ms": 0,
//    "kind": "wheel"|"drag"}
//       that many scroll-wheel events (line units, deltaY alternating +delta and -delta, starting with
//       first) sent to the view's -scrollWheel:, each in a block of its own queued on the main queue at
//       its moment, interval_ms apart, so the run loop can draw between them as it does for input, and
//       an event waits while the main thread is busy. With "drag", the view's tool
//       is the stack scroll tool (tNext) for the burst, the view gets -mouseDown: off the cross lines, then
//       the events as left-button drags of delta points, up and down alternately, sent to -mouseDragged:,
//       then -mouseUp:, whose times are answered apart (down_ms, up_ms); the tool is restored after. The
//       still-press timer of the mouse-down is cancelled at once, as a real drag's first movement does.
//       Answers when the last one has been handled, with the time each took and the burst's start on the
//       probe's clock. events is an integer from 1 to 10000, delta is positive, and the scheduled interval
//       from the first event to the last must be less than 300 seconds.
//   {"action": "state"}
//       per view: the reconstructed plane (DCMPix) size and the mean of its central quarter; how many times
//       the view drew since the probe was loaded and how long ago the last draw was; whether it needs
//       display, is hidden, and its window is visible; the controller's lowLOD.
//   {"action": "reslices"}
//       every plane reconstruction since the previous "reslices" (or since the probe was loaded): the
//       view (1, 2, 3, or 0 for another MPR view), its start on the probe's clock and its duration in ms,
//       as -[MPRDCMView horosMPRCopyImageWidth:height:] took it, cubic display plane included.
//
//   xcrun clang -dynamiclib -fobjc-arc -framework Cocoa tools/probe-mpr-scroll-burst.m -o probe-mpr-scroll-burst.dylib
#import <Cocoa/Cocoa.h>
#include <mach/mach_time.h>
#include <math.h>
#include <objc/message.h>
#include <objc/runtime.h>

@interface NSObject (MPRScrollBurstProbe)
+ (id)activeLocalDatabase;
+ (id)currentBrowser;
- (NSArray *)objectsForEntity:(id)entity;
- (id)entityForName:(NSString *)name;
- (id)loadSeries:(id)series :(id)viewer :(BOOL)firstViewer keyImagesOnly:(BOOL)keyImages;
- (BOOL)isEverythingLoaded;
- (id)openMPRViewer;
- (id)mprView1;
- (id)mprView2;
- (id)mprView3;
- (void)setClippingRangeMode:(int)mode;
- (void)setClippingRangeThicknessInMm:(float)thickness;
- (void)setWLWW:(float)wl :(float)ww;
- (IBAction)actualSize:(id)sender;
- (id)curDCM;
- (float *)fImage;
- (long)pwidth;
- (long)pheight;
- (BOOL)lowLOD;
- (int)currentTool;
- (void)setCurrentTool:(int)tool;
- (void)deleteMouseDownTimer;
@end

// -[DCMView currentTool] values: the stack scroll tool.
static const int stackScrollTool = 4;

static NSEvent *mouseEvent(NSView *view, NSEventType type, NSPoint inView, NSInteger number) {
    return [NSEvent mouseEventWithType:type location:[view convertPoint:inView toView:nil] modifierFlags:0
                             timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:view.window.windowNumber
                               context:nil eventNumber:number clickCount:1 pressure:type == NSEventTypeLeftMouseUp ? 0 : 1];
}

static id mprController = nil;
static NSMutableDictionary<NSValue *, NSNumber *> *drawCounts;
static NSMutableDictionary<NSValue *, NSNumber *> *lastDraws;
static IMP originalDrawRect;
static IMP originalCopyImage;
static NSMutableArray<NSArray *> *reslices;

static double nowMs(void) {
    static mach_timebase_info_data_t timebase;
    if (timebase.denom == 0) mach_timebase_info(&timebase);
    return (double)mach_absolute_time() * timebase.numer / timebase.denom / 1e6;
}

static id onMain(id (^block)(void)) {
    __block id result = nil;
    __block NSException *failure = nil;
    if ([NSThread isMainThread]) return block();
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try { result = block(); }
        @catch (NSException *exception) { failure = exception; }
    });
    if (failure) @throw failure;
    return result;
}

// Every draw of an MPR view, counted and timed: whether the view drew after the burst, and when.
static void countedDrawRect(id view, SEL selector, NSRect rect) {
    if ([view isKindOfClass:NSClassFromString(@"MPRDCMView")]) {
        NSValue *key = [NSValue valueWithPointer:(__bridge void *)view];
        drawCounts[key] = @(drawCounts[key].integerValue + 1);
        lastDraws[key] = @(nowMs());
    }
    ((void (*)(id, SEL, NSRect))originalDrawRect)(view, selector, rect);
}

static NSArray *views(void);

// Every plane reconstruction of an MPR view, with the view it was for, when it started and how long it took.
static float *countedCopyImage(id view, SEL selector, long *width, long *height) {
    double started = nowMs();
    float *image = ((float *(*)(id, SEL, long *, long *))originalCopyImage)(view, selector, width, height);
    NSUInteger index = [views() indexOfObjectIdenticalTo:view];
    [reslices addObject:@[@(index == NSNotFound ? 0 : index + 1), @(started), @(nowMs() - started)]];
    return image;
}

static NSArray *views(void) {
    NSCAssert([NSThread isMainThread], @"MPR views require the main thread");
    if (!mprController) return @[];
    id first = [mprController mprView1], second = [mprController mprView2], third = [mprController mprView3];
    return first && second && third ? @[first, second, third] : @[];
}

// A view's frame on the screen, in points with the origin at the top left, as screencapture -R takes it.
static NSDictionary *screenFrame(NSView *view) {
    NSCAssert([NSThread isMainThread], @"AppKit geometry requires the main thread");
    NSRect inWindow = [view convertRect:view.bounds toView:nil];
    NSRect onScreen = [view.window convertRectToScreen:inWindow];
    CGFloat top = NSMaxY(NSScreen.screens.firstObject.frame);
    return @{@"x": @(onScreen.origin.x), @"y": @(top - NSMaxY(onScreen)), @"width": @(onScreen.size.width),
             @"height": @(onScreen.size.height)};
}

static NSDictionary *openMPR(NSDictionary *command) {
    if (![command[@"series"] isKindOfClass:[NSString class]] || ![command[@"series"] length])
        return @{@"error": @"series must be a nonempty UID string"};
    id viewer = onMain(^id {
        id database = [NSClassFromString(@"DicomDatabase") activeLocalDatabase];
        for (id series in [database objectsForEntity:[database entityForName:@"Series"]])
            if ([[series valueForKey:@"seriesDICOMUID"] isEqualToString:command[@"series"]])
                return [[NSClassFromString(@"BrowserController") currentBrowser] loadSeries:series :nil :YES keyImagesOnly:NO];
        return nil;
    });
    if (!viewer) return @{@"error": @"no such series"};
    BOOL loaded = NO;
    for (int wait = 0; wait < 1200; wait++) {
        loaded = [onMain(^id { return @([viewer isEverythingLoaded]); }) boolValue];
        if (loaded) break;
        usleep(50 * 1000);
    }
    if (!loaded) return @{@"error": @"the series did not finish loading"};
    usleep(300 * 1000);
    id opened = onMain(^id {
        mprController = [viewer openMPRViewer];
        if (!mprController) return @{@"error": @"no 3D MPR window"};
        [mprController showWindow:nil];
        NSWindow *window = [mprController window];
        if ([command[@"fill_screen"] boolValue])
            [window setFrame:window.screen.visibleFrame display:YES];
        [window makeKeyAndOrderFront:nil];
        return @{@"ok": @YES};
    });
    if (![opened[@"ok"] boolValue]) return opened;
    usleep(1500 * 1000);
    return onMain(^id {
        NSArray *available = views();
        if (available.count != 3) return @{@"error": @"the 3D MPR views are not available"};
        [mprController setClippingRangeMode:[command[@"mode"] intValue]];
        [mprController setClippingRangeThicknessInMm:[command[@"thickness_mm"] floatValue]];
        NSMutableArray *frames = [NSMutableArray array];
        for (id view in available) {
            [view actualSize:nil];
            [view setWLWW:[command[@"wl"] floatValue] :[command[@"ww"] floatValue]];
            [frames addObject:screenFrame(view)];
        }
        NSWindow *window = [mprController window];
        return @{@"ok": @YES, @"window": @(window.windowNumber), @"frames": frames,
                 @"backing_scale": @(window.backingScaleFactor),
                 // The MPR reconstructs its planes in Metal only.
                 @"metal": @YES};
    });
}

static BOOL number(NSDictionary *command, NSString *key, double *result) {
    id value = command[key];
    if (![value isKindOfClass:[NSNumber class]] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID())
        return NO;
    double parsed = [value doubleValue];
    if (!isfinite(parsed)) return NO;
    *result = parsed;
    return YES;
}

static NSDictionary *burst(NSDictionary *command) {
    double eventCount, viewIndex, delta, interval = 0, first = 1;
    if (!number(command, @"events", &eventCount) || eventCount < 1 || eventCount > 10000 || trunc(eventCount) != eventCount)
        return @{@"error": @"events must be an integer from 1 to 10000"};
    if (!number(command, @"view", &viewIndex) || viewIndex < 1 || viewIndex > 3 || trunc(viewIndex) != viewIndex)
        return @{@"error": @"view must be 1, 2 or 3"};
    if (!number(command, @"delta", &delta) || delta <= 0 || delta > INT32_MAX)
        return @{@"error": @"delta must be positive and no greater than INT32_MAX"};
    if ((command[@"interval_ms"] && !number(command, @"interval_ms", &interval)) || interval < 0 ||
        !isfinite(interval * (eventCount - 1)) || interval * (eventCount - 1) >= 300000)
        return @{@"error": @"interval_ms must be nonnegative and schedule the burst in less than 300 seconds"};
    if ((command[@"first"] && !number(command, @"first", &first)) || (first != 1 && first != -1))
        return @{@"error": @"first must be 1 or -1"};
    id kind = command[@"kind"] ?: @"wheel";
    if (![kind isKindOfClass:[NSString class]] || !([kind isEqualToString:@"wheel"] || [kind isEqualToString:@"drag"]))
        return @{@"error": @"kind must be wheel or drag"};
    BOOL drag = [kind isEqualToString:@"drag"];
    NSInteger events = (NSInteger)eventCount;
    int direction = (int)first;
    id view = onMain(^id {
        NSArray *available = views();
        if (available.count != 3) return nil;
        NSView *selected = available[(NSInteger)viewIndex - 1];
        return selected.window.isVisible ? selected : nil;
    });
    if (!view) return @{@"error": @"no visible 3D MPR window"};
    // A drag starts off the cross lines, which the centre holds, and moves vertically.
    __block NSPoint dragPrevious = NSZeroPoint;
    __block int previousTool = 0;
    __block double downMs = 0;
    if (drag) {
        NSDictionary *down = onMain(^id {
            NSView *selected = view;
            NSRect bounds = selected.bounds;
            dragPrevious = NSMakePoint(NSMidX(bounds) + bounds.size.width / 5, NSMidY(bounds) + bounds.size.height / 5);
            previousTool = [view currentTool];
            [view setCurrentTool:stackScrollTool];
            NSEvent *event = mouseEvent(selected, NSEventTypeLeftMouseDown, dragPrevious, 0);
            if (!event) return @{@"error": @"could not create an AppKit mouse-down event"};
            double before = nowMs();
            [view mouseDown:event];
            // A real drag's first movement has a delta, which cancels the still-press timer that would
            // otherwise start dragging the image out of the view; these events carry none.
            [view deleteMouseDownTimer];
            downMs = nowMs() - before;
            return @{@"ok": @YES};
        });
        if (down[@"error"]) return down;
    }
    NSMutableArray *handled = [NSMutableArray array];
    __block BOOL stopped = NO;
    __block NSDictionary *failure = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block double start = 0;
    void (^handle)(NSInteger) = ^(NSInteger index) {
            double sign = (index % 2 == 0 ? direction : -direction);
            @synchronized (handled) { if (stopped) return; }
            NSDictionary *eventFailure = nil;
            NSArray *measurement = nil;
            @try {
                if (![view window].isVisible) {
                    eventFailure = @{@"error": @"the 3D MPR window closed during the burst"};
                } else if (drag) {
                    NSPoint location = NSMakePoint(dragPrevious.x, dragPrevious.y + sign * delta);
                    NSEvent *event = mouseEvent(view, NSEventTypeLeftMouseDragged, location, index + 1);
                    if (!event) {
                        eventFailure = @{@"error": @"could not create an AppKit drag event"};
                    } else {
                        double before = nowMs();
                        [view mouseDragged:event];
                        measurement = @[@(before - start), @(nowMs() - before), @(location.y - dragPrevious.y)];
                        dragPrevious = location;
                    }
                } else {
                    CGEventRef cg = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitLine, 1, 0);
                    if (!cg) {
                        eventFailure = @{@"error": @"could not create a scroll event"};
                    } else {
                        NSEvent *event;
                        @try {
                            CGEventSetDoubleValueField(cg, kCGScrollWheelEventFixedPtDeltaAxis1, sign * delta);
                            CGEventSetIntegerValueField(cg, kCGScrollWheelEventDeltaAxis1, (int64_t)lround(sign * delta));
                            event = [NSEvent eventWithCGEvent:cg];
                        } @finally { CFRelease(cg); }
                        if (!event) {
                            eventFailure = @{@"error": @"could not create an AppKit scroll event"};
                        } else {
                            double before = nowMs();
                            [view scrollWheel:event];
                            measurement = @[@(before - start), @(nowMs() - before), @(event.deltaY)];
                        }
                    }
                }
            } @catch (NSException *exception) {
                eventFailure = @{@"error": [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason]};
            }
            @synchronized (handled) {
                if (stopped) return;
                if (eventFailure) {
                    stopped = YES;
                    failure = eventFailure;
                    dispatch_semaphore_signal(done);
                } else {
                    [handled addObject:measurement];
                    if (index == events - 1) {
                        stopped = YES;
                        dispatch_semaphore_signal(done);
                    }
                }
            }
    };
    // Input arrives on time whatever the main thread is doing: a thread of its own waits for each event's
    // moment and only then queues it on the main queue, where it waits its turn as an event does.
    // dispatch_after would let the system batch the timers (by up to a tenth of their delay), so that
    // events came in clumps rather than interval_ms apart.
    static mach_timebase_info_data_t timebase;
    if (timebase.denom == 0) mach_timebase_info(&timebase);
    uint64_t origin = mach_absolute_time();
    start = (double)origin * timebase.numer / timebase.denom / 1e6;
    double ticksPerMs = 1e6 * timebase.denom / timebase.numer;
    [NSThread detachNewThreadWithBlock:^{
        for (NSInteger index = 0; index < events; index++) {
            mach_wait_until(origin + (uint64_t)llround(interval * index * ticksPerMs));
            @synchronized (handled) { if (stopped) return; }
            dispatch_async(dispatch_get_main_queue(), ^{ handle(index); });
        }
    }];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_SEC)) != 0) {
        @synchronized (handled) { stopped = YES; }
        return @{@"error": @"the burst did not finish"};
    }
    double endMs = nowMs();
    __block double upMs = 0;
    if (drag) onMain(^id {
        NSEvent *event = mouseEvent(view, NSEventTypeLeftMouseUp, dragPrevious, events + 1);
        double before = nowMs();
        if (event && [view window].isVisible) [view mouseUp:event];
        upMs = nowMs() - before;
        [view setCurrentTool:previousTool];
        return nil;
    });
    @synchronized (handled) {
        if (failure) return failure;
        NSMutableDictionary *answer = [@{@"ok": @YES, @"events": [handled copy], @"start_ms": @(start), @"end_ms": @(endMs)} mutableCopy];
        if (drag) { answer[@"down_ms"] = @(downMs); answer[@"up_ms"] = @(upMs); }
        return answer;
    }
}

static NSDictionary *state(void) {
    return onMain(^id {
        NSMutableArray *out = [NSMutableArray array];
        double now = nowMs();
        for (NSView *view in views()) {
            id pix = [(id)view curDCM];
            long width = [pix pwidth], height = [pix pheight];
            float *image = [pix fImage];
            double sum = 0; long count = 0;
            if (image && width > 3 && height > 3)
                for (long y = height / 4; y < 3 * height / 4; y++)
                    for (long x = width / 4; x < 3 * width / 4; x++, count++)
                        sum += image[y * width + x];
            NSValue *key = [NSValue valueWithPointer:(__bridge void *)view];
            [out addObject:@{@"width": @(width), @"height": @(height), @"central_mean": count ? @(sum / count) : [NSNull null],
                             @"draws": drawCounts[key] ?: @0,
                             @"since_last_draw_ms": lastDraws[key] ? @(now - lastDraws[key].doubleValue) : [NSNull null],
                             @"needs_display": @(view.needsDisplay), @"hidden": @(view.isHiddenOrHasHiddenAncestor),
                             @"window_visible": @(view.window.isVisible), @"frame": screenFrame(view)}];
        }
        return @{@"now_ms": @(now), @"views": out, @"low_lod": @(mprController ? [mprController lowLOD] : NO)};
    });
}

static NSDictionary *run(NSDictionary *command) {
    NSString *action = command[@"action"];
    if ([action isEqualToString:@"ping"]) return @{@"ok": @YES};
    if ([action isEqualToString:@"open"]) return openMPR(command);
    if ([action isEqualToString:@"burst"]) return burst(command);
    if ([action isEqualToString:@"state"]) return state();
    if ([action isEqualToString:@"reslices"]) return onMain(^id {
        NSArray *taken = [reslices copy];
        [reslices removeAllObjects];
        return @{@"ok": @YES, @"now_ms": @(nowMs()), @"reslices": taken};
    });
    return @{@"error": [NSString stringWithFormat:@"unknown action %@", action]};
}

__attribute__((constructor)) static void installMPRScrollBurstProbe(void) {
    NSString *folder = NSProcessInfo.processInfo.environment[@"HOROS_MPR_COMMANDS"];
    if (!folder) return;
    unsetenv("DYLD_INSERT_LIBRARIES");
    drawCounts = [NSMutableDictionary dictionary];
    lastDraws = [NSMutableDictionary dictionary];
    reslices = [NSMutableArray array];
    [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil
                                                     queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        Method draw = class_getInstanceMethod(NSClassFromString(@"DCMView"), @selector(drawRect:));
        if (draw) originalDrawRect = method_setImplementation(draw, (IMP)countedDrawRect);
        Method copyImage = class_getInstanceMethod(NSClassFromString(@"MPRDCMView"), NSSelectorFromString(@"horosMPRCopyImageWidth:height:"));
        if (copyImage) originalCopyImage = method_setImplementation(copyImage, (IMP)countedCopyImage);
        [NSThread detachNewThreadWithBlock:^{
            for (NSInteger number = 1;; number++) {
                NSString *commandPath = [folder stringByAppendingPathComponent:[NSString stringWithFormat:@"%ld.json", (long)number]];
                while (![NSFileManager.defaultManager fileExistsAtPath:commandPath]) usleep(20 * 1000);
                @autoreleasepool {
                    NSDictionary *answer;
                    @try {
                        NSData *input = [NSData dataWithContentsOfFile:commandPath];
                        id command = input ? [NSJSONSerialization JSONObjectWithData:input options:0 error:NULL] : nil;
                        answer = !input ? @{@"error": @"unreadable command"} :
                            [command isKindOfClass:[NSDictionary class]] ? run(command) : @{@"error": @"command must be a JSON object"};
                    } @catch (NSException *exception) {
                        answer = @{@"exception": [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason]};
                    }
                    NSData *data = [NSJSONSerialization dataWithJSONObject:answer options:0 error:NULL]
                        ?: [@"{\"error\": \"unserialisable answer\"}" dataUsingEncoding:NSUTF8StringEncoding];
                    NSString *partial = [folder stringByAppendingPathComponent:[NSString stringWithFormat:@".%ld.out.json", (long)number]];
                    [data writeToFile:partial atomically:NO];
                    rename(partial.fileSystemRepresentation,
                           [[folder stringByAppendingPathComponent:[NSString stringWithFormat:@"%ld.out.json", (long)number]] fileSystemRepresentation]);
                }
            }
        }];
    }];
}
