#!/usr/bin/env python3
"""Exercise production cine callbacks with a synthetic monotonic clock and a civil-clock jump.

Cadence steps a fake systemUptime so suite load cannot starve the production
zero-interval NSTimer. A real run-loop timer still checks that playback
continues across a civil-clock rollback.

This isolates scheduling from DICOM decoding, GPU rendering and synchronization.
"""
from pathlib import Path
import math
import re
import subprocess
import tempfile

# Same 3.2 s window as the original wall-clock run. The bound is still one
# missed or extra frame around elapsed*rate — not extra wall-clock slack.
# A loaded machine no longer changes the count, because time is simulated.
# Selecting 20/s and getting ~1/s or ~5/s still fails.
SIMULATED_SECONDS = 3.2


def cadence_ok(count, elapsed, selected):
    expected = elapsed * selected
    return math.floor(expected) - 1 <= count <= math.ceil(expected)


# Hand-checked literals for the 3.2 s window. 63 at 20/s is one missed frame
# (the original bound). 16 or 3 at 20/s is a truly wrong cadence.
assert cadence_ok(3, 3.2, 1) and cadence_ok(16, 3.2, 5) and cadence_ok(64, 3.2, 20)
assert cadence_ok(63, 3.2, 20)
assert not cadence_ok(62, 3.2, 20)
assert not cadence_ok(16, 3.2, 20) and not cadence_ok(3, 3.2, 20)
assert not cadence_ok(3, 3.2, 5)

root = Path(__file__).resolve().parents[1]

# -performAnimation: (the "Browse" player, ViewerController+SeriesNavigation.swift)
# and -performMovieAnimation: (the 4D player, ViewerController+FourDNavigation.swift)
# are Swift. They are taken as they stand, with the helper they share, and
# compiled with swiftc as an extension of an Objective-C double of the viewer,
# which reaches its instance variables through accessors spelled as in
# ViewerController+SwiftIvars.h; IsiXImaging and HorosFourDSeriesGuard are the
# app's own.
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401,E402  - its own TMPDIR for the tools it runs
from isix_modules import module_flags  # noqa: E402

root = Path(__file__).resolve().parents[1]
browse = (root / 'Horos/Sources/ViewerController+SeriesNavigation.swift').read_text(encoding='utf-8')
player = (root / 'Horos/Sources/ViewerController+FourDNavigation.swift').read_text(encoding='utf-8')


def method(text, start):
    found = re.search(re.escape(start) + r'.*?\n    \}\n', text, re.S)
    if not found:
        raise SystemExit('FAIL: no %r' % start)
    return found.group(0)


uptime = 'ProcessInfo.processInfo.systemUptime'
callbacks = (method(browse, '    @objc(performAnimation:)') + method(player, '    @objc(performMovieAnimation:)')
             + method(browse, '    func isLoadingFirstHalf()'))
if callbacks.count(uptime) < 2:
    raise SystemExit(f'expected systemUptime in cine callbacks, found {callbacks.count(uptime)}')
callbacks = callbacks.replace(uptime, 'testUptime()')
if 'systemUptime' in callbacks:
    raise SystemExit('missed a systemUptime substitution')
# The players start from the uptime, as -PlayStop: and -MoviePlayStop: set it.
slice_start = method(browse, '    @objc(PlayStop:)')
phase_start = method(player, '    @objc(MoviePlayStop:)')
for field, body in [('horos_lastTime', slice_start), ('horos_lastTimeFrame', slice_start), ('horos_lastMovieTime', phase_start)]:
    if f'{field} = {uptime}' not in body:
        raise SystemExit(f'the player no longer starts {field} from the uptime')
initializers = 'v->lastTime=testUptime(); v->lastTimeFrame=testUptime(); v->lastMovieTime=testUptime();'

header = r'''
#pragma clang diagnostic ignored "-Wnullability-completeness"
#import <AppKit/AppKit.h>
double testUptime(void);
@interface ImageProbe : NSObject
@property NSInteger curImage;
@property BOOL flippedData;
- (void)setIndex:(NSInteger)index;
- (void)sendSyncMessage:(NSInteger)value;
- (void)displayIfNeeded;
@end
@interface ViewerController : NSObject {
@public
 NSThread *loadingThread;
 NSTimeInterval lastTime, lastMovieTime, lastTimeFrame;
 NSSlider *speedSlider, *movieRateSlider;
 NSTextField *speedText;
 NSButton *loopButton;
 ImageProbe *imageView;
 NSMutableArray *pixList[1];
 short curMovieIndex, maxMovieIndex;
 float direction;
 BOOL windowWillClose;
 long speedometer;
 int sliceCount, phaseCount;
}
- (void)setMovieIndex:(short)value;
- (void)propagateSettings;
- (void)adjustSlider;
// The accessors of ViewerController+SwiftIvars.h, on the same ivars.
@property(retain, nullable) NSThread* horos_loadingThread;
@property(assign) BOOL horos_windowWillClose;
- (nullable NSMutableArray*)horos_pixListAt:(NSInteger)index;
@property(assign) short horos_curMovieIndex;
@property(assign) short horos_maxMovieIndex;
@property(assign) NSTimeInterval horos_lastTime;
@property(assign) NSTimeInterval horos_lastTimeFrame;
@property(assign) NSTimeInterval horos_lastMovieTime;
@property(assign) long horos_speedometer;
@property(assign) float horos_direction;
@property(readonly, nullable) NSTextField* horos_speedText;
@property(readonly, nullable) NSSlider* horos_speedSlider;
@property(readonly, nullable) NSSlider* horos_movieRateSlider;
@property(readonly, nullable) ImageProbe* horos_imageView;
@property(readonly, nullable) NSButton* horos_loopButton;
@end
'''
code = r'''
#import "Harness.h"
#include <math.h>
#include <stdio.h>
static double clockOffset;
static double testClock;
static BOOL useTestClock;
double testUptime(void) {
 return useTestClock ? testClock : NSProcessInfo.processInfo.systemUptime;
}
@interface TestWallClock : NSObject
+ (NSTimeInterval)timeIntervalSinceReferenceDate;
@end
@implementation TestWallClock
+ (NSTimeInterval)timeIntervalSinceReferenceDate { return NSDate.timeIntervalSinceReferenceDate + clockOffset; }
@end
#define NSDate TestWallClock
@interface ViewerController (Players)
- (void)performAnimation:(id)sender;
- (void)performMovieAnimation:(id)sender;
@end
@implementation ImageProbe
- (void)setIndex:(NSInteger)index { self.curImage=index; }
- (void)sendSyncMessage:(NSInteger) value {}
- (void)displayIfNeeded {}
@end
@implementation ViewerController
- (id)init { if ((self=[super init])) {
 speedSlider=[NSSlider new]; speedSlider.maxValue=60;
 movieRateSlider=[NSSlider new]; movieRateSlider.maxValue=60;
 speedText=[NSTextField new]; loopButton=[NSButton new]; loopButton.state=NSControlStateValueOn;
 imageView=[ImageProbe new]; pixList[0]=[@[@0,@1,@2] mutableCopy]; direction=1; maxMovieIndex=3;
 } return self; }
- (void)setMovieIndex:(short)value { phaseCount++; }
- (void)propagateSettings {}
- (void)adjustSlider { sliceCount++; }
- (NSThread*)horos_loadingThread { return loadingThread; }
- (void)setHoros_loadingThread:(NSThread*)value { loadingThread=value; }
- (BOOL)horos_windowWillClose { return windowWillClose; }
- (void)setHoros_windowWillClose:(BOOL)value { windowWillClose=value; }
- (NSMutableArray*)horos_pixListAt:(NSInteger)index { return pixList[index]; }
- (short)horos_curMovieIndex { return curMovieIndex; }
- (void)setHoros_curMovieIndex:(short)value { curMovieIndex=value; }
- (short)horos_maxMovieIndex { return maxMovieIndex; }
- (void)setHoros_maxMovieIndex:(short)value { maxMovieIndex=value; }
- (NSTimeInterval)horos_lastTime { return lastTime; }
- (void)setHoros_lastTime:(NSTimeInterval)value { lastTime=value; }
- (NSTimeInterval)horos_lastTimeFrame { return lastTimeFrame; }
- (void)setHoros_lastTimeFrame:(NSTimeInterval)value { lastTimeFrame=value; }
- (NSTimeInterval)horos_lastMovieTime { return lastMovieTime; }
- (void)setHoros_lastMovieTime:(NSTimeInterval)value { lastMovieTime=value; }
- (long)horos_speedometer { return speedometer; }
- (void)setHoros_speedometer:(long)value { speedometer=value; }
- (float)horos_direction { return direction; }
- (void)setHoros_direction:(float)value { direction=value; }
- (NSTextField*)horos_speedText { return speedText; }
- (NSSlider*)horos_speedSlider { return speedSlider; }
- (NSSlider*)horos_movieRateSlider { return movieRateSlider; }
- (ImageProbe*)horos_imageView { return imageView; }
- (NSButton*)horos_loopButton { return loopButton; }
@end
static void runFor(double duration) {
 double end=NSProcessInfo.processInfo.systemUptime+duration;
 while (NSProcessInfo.processInfo.systemUptime < end)
  [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[(id)NSClassFromString(@"NSDate") dateWithTimeIntervalSinceNow:0.01]];
}
int main(void) { @autoreleasepool {
 [NSApplication sharedApplication];
 if (!(floor(3.2*20)-1 <= 63 && 63 <= ceil(3.2*20))) return 1;
 if (floor(3.2*20)-1 <= 16 && 16 <= ceil(3.2*20)) return 1;
 for (int mode=0; mode<2; mode++) {
  for (NSNumber *rate in @[@1,@5,@20]) {
   ViewerController *v=[ViewerController new];
   v->speedSlider.floatValue=rate.floatValue; v->movieRateSlider.floatValue=rate.floatValue;
   useTestClock=YES; testClock=1000;
   INITIALIZERS
   const double step=0.0001;
   const int ticks=(int)llround(3.2/step);
   for (int i=0;i<ticks;i++) {
    testClock+=step;
    if (mode) [v performMovieAnimation:nil]; else [v performAnimation:nil];
   }
   int count=mode ? v->phaseCount : v->sliceCount;
   double elapsed=3.2;
   double expected=elapsed*rate.doubleValue;
   NSLog(@"%@ selected %@: %d advances / %.3f s simulated (%.3f/s)",mode ? @"phase" : @"slice",rate,count,elapsed,count/elapsed);
   if (!(count >= floor(expected)-1 && count <= ceil(expected))) {
    fprintf(stderr,"FAIL: count >= floor(expected)-1 && count <= ceil(expected) (%s %.0f : %d advances, expected %.3f, allow [%.0f, %.0f])\n",
      mode ? "phase" : "slice", rate.doubleValue, count, expected, floor(expected)-1, ceil(expected));
    return 1;
   }
   // An NTP/manual correction must not freeze cine until civil time catches up.
   useTestClock=NO;
   INITIALIZERS
   count=mode ? v->phaseCount : v->sliceCount;
   NSTimer *timer=[NSTimer scheduledTimerWithTimeInterval:0 target:v selector:mode ? @selector(performMovieAnimation:) : @selector(performAnimation:) userInfo:nil repeats:YES];
   clockOffset=-3600;
   runFor(1.2);
   int after=mode ? v->phaseCount : v->sliceCount;
   if (!(after > count)) {
    fprintf(stderr,"FAIL: after > count (%s %.0f : %d after civil-clock rollback, was %d)\n",
      mode ? "phase" : "slice", rate.doubleValue, after, count);
    return 1;
   }
   [timer invalidate]; clockOffset=0;
  }
 }
 NSLog(@"PASS: slice and phase cadence on simulated uptime, playback continues across civil-clock rollback");
} }
'''.replace('INITIALIZERS', initializers)
with tempfile.TemporaryDirectory(prefix='horos-cine-timing-') as directory:
    path = Path(directory)
    (path/'Harness.h').write_text(header)
    (path/'test.m').write_text(code)
    (path/'Players.swift').write_text('import AppKit\nimport IsiXImaging\n\nextension ViewerController {\n' + callbacks + '}\n')
    subprocess.run(['xcrun','clang','-c','-fobjc-arc','-I',str(path),str(path/'test.m'),'-o',str(path/'test.o')],check=True)
    subprocess.run(['xcrun','swiftc','-parse-as-library',*module_flags('IsiXImaging', path / 'modules'),
                    '-import-objc-header',str(path/'Harness.h'),str(path/'Players.swift'),
                    str(root/'Horos/Sources/FourDSeriesGuard.swift'),str(path/'test.o'),
                    '-framework','AppKit','-o',str(path/'test')],check=True)
    subprocess.run([str(path/'test')],check=True,timeout=300)
