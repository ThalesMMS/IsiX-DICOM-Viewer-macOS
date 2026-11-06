#!/usr/bin/env python3
"""Compile production rate actions and verify independent rates and reverse labels.

-frameRate and -speedSliderAction: (ViewerController+SeriesNavigation.swift),
-movieRate and -movieRateSliderAction: (ViewerController+FourDNavigation.swift)
are Swift façades of the viewer's CinePlayback (CinePlayback.swift), which
reads and writes the default speeds through the viewer's graph. The façades,
the viewer's `cine` (ViewerController+PlaybackState.swift) and the speeds of
CinePlayback are taken as they stand and compiled with swiftc, against
IsiXPreferences, over an Objective-C double of the viewer, which reaches its
controls through accessors spelled as in ViewerController+SwiftIvars.h, and a
graph whose preferences are the harness's.
"""
from pathlib import Path
import re
import subprocess, tempfile
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
import harness_defaults  # the harness's preferences stay in its own process
from isix_modules import module_flags
root=Path(__file__).resolve().parents[1]


def swift_method(name, selector):
    text=(root/'Horos/Sources'/('ViewerController+%s.swift' % name)).read_text(encoding='utf-8')
    found=re.search(r'    @objc\(%s\)\n.*?\n    \}\n' % re.escape(selector), text, re.S)
    if not found:
        raise SystemExit('FAIL: ViewerController+%s.swift has no @objc(%s)' % (name, selector))
    return found.group(0)


def member(text, name, where):
    """The declaration `name` (a func or var, with its doc comment) of a type in `text`."""
    found=re.search(r'(?:    ///[^\n]*\n)*    (?:private )?(?:static )?(?:func|var) %s\b.*?\n    \}\n' % re.escape(name), text, re.S)
    if not found:
        raise SystemExit('FAIL: %s has no %s' % (where, name))
    return found.group(0)


methods=(swift_method('SeriesNavigation','frameRate')+swift_method('SeriesNavigation','speedSliderAction:')
         +swift_method('FourDNavigation','movieRate')+swift_method('FourDNavigation','movieRateSliderAction:'))
playback=(root/'Horos/Sources/ViewerController+PlaybackState.swift').read_text(encoding='utf-8')
methods+=member(playback,'cine','ViewerController+PlaybackState.swift')
cine=(root/'Horos/Sources/CinePlayback.swift').read_text(encoding='utf-8')
start=cine.index('@MainActor final class CinePlayback {')
shell=cine[start:cine.index('\n    /// The "Browse" player\'s timer', start)]
if 'init(viewer: ViewerController, preferences: any PreferenceStore)' not in shell:
    raise SystemExit('FAIL: CinePlayback is no longer made over the viewer and its preferences')
speeds=''.join(member(cine,name,'CinePlayback.swift') for name in
               ('frameRate','movieRate','speedChanged','movieRateChanged','imagesPerSecond','framesPerSecond'))
header=r'''
#pragma clang diagnostic ignored "-Wnullability-completeness"
#import <AppKit/AppKit.h>
@interface WindowProbe:NSObject
@property(getter=isKeyWindow) BOOL keyWindow;
@end
// On the main actor, as the app's viewer is by its AppKit superclass.
NS_SWIFT_UI_ACTOR
@interface ViewerController:NSObject {
@public
 NSSlider *speedSlider,*movieRateSlider;
 NSTextField *speedText,*movieTextSlide;
 float direction;
}
@property(retain) WindowProbe *window;
@property(readonly) NSSlider *speedSlider,*movieRateSlider;
@property(readonly) NSTextField *speedText,*movieTextSlide;
+ (NSMutableArray*)getDisplayed2DViewers;
// The accessors of ViewerController+SwiftIvars.h, on the same ivars.
@property(readonly, nullable) NSTimer* horos_timer;
@property(readonly, nullable) NSTimer* horos_movieTimer;
@property(readonly) NSTimeInterval horos_lastTime;
@property(readonly) NSTimeInterval horos_lastMovieTime;
@property(readonly, nullable) NSSlider* horos_speedSlider;
@property(readonly, nullable) NSSlider* horos_movieRateSlider;
@property(readonly, nullable) NSTextField* horos_speedText;
@property(readonly, nullable) NSTextField* horos_movieTextSlide;
@property(assign) float horos_direction;
@end
'''
code=r'''
#import "Harness.h"
#define check(c) NSCAssert((c),@"failed: %s",#c)
@interface ViewerController (Rates)
- (float)frameRate;
- (float)movieRate;
- (void)speedSliderAction:(id)sender;
- (void)movieRateSliderAction:(id)sender;
@end
@implementation WindowProbe
@end
static NSMutableArray *viewers;
@implementation ViewerController
@synthesize speedSlider,movieRateSlider,speedText,movieTextSlide;
- (NSTimer*)horos_timer{return nil;}
- (NSTimer*)horos_movieTimer{return nil;}
- (NSTimeInterval)horos_lastTime{return 0;}
- (NSTimeInterval)horos_lastMovieTime{return 0;}
- (NSSlider*)horos_speedSlider{return speedSlider;}
- (NSSlider*)horos_movieRateSlider{return movieRateSlider;}
- (NSTextField*)horos_speedText{return speedText;}
- (NSTextField*)horos_movieTextSlide{return movieTextSlide;}
- (float)horos_direction{return direction;}
- (void)setHoros_direction:(float)value{direction=value;}
+ (NSMutableArray*)getDisplayed2DViewers{return [[viewers mutableCopy] autorelease];}
- (id)init{if((self=[super init])){
 speedSlider=[NSSlider new];speedSlider.maxValue=60;
 movieRateSlider=[NSSlider new];movieRateSlider.maxValue=60;
 speedText=[NSTextField new];movieTextSlide=[NSTextField new];
 self.window=[[WindowProbe new] autorelease];direction=1;
}return self;}
@end
int main(void){@autoreleasepool {
 [NSApplication sharedApplication];
 ViewerController *source=[ViewerController new],*reverse=[ViewerController new],*custom=[ViewerController new];
 viewers=[@[source,reverse,custom] mutableCopy];source.window.keyWindow=YES;reverse->direction=-1;
 for(ViewerController *v in viewers){v.speedSlider.floatValue=10;v.movieRateSlider.floatValue=3;}
 custom.speedSlider.floatValue=7;custom.movieRateSlider.floatValue=4;
 [NSUserDefaults.standardUserDefaults setFloat:10 forKey:@"defaultFrameRate"];
 [NSUserDefaults.standardUserDefaults setFloat:3 forKey:@"defaultMovieRate"];
 source.speedSlider.floatValue=5;[source speedSliderAction:nil];
 check(reverse.speedSlider.floatValue==5);check(custom.speedSlider.floatValue==7);
 check([source.speedText.stringValue hasPrefix:@"5.0"]);
 check([reverse.speedText.stringValue hasPrefix:@"-5.0"]);
 check(reverse.movieRateSlider.floatValue==3);check(custom.movieRateSlider.floatValue==4);
 source.movieRateSlider.floatValue=2;[source movieRateSliderAction:nil];
 check(reverse.movieRateSlider.floatValue==2);check(custom.movieRateSlider.floatValue==4);
 check(reverse.speedSlider.floatValue==5);check(custom.speedSlider.floatValue==7);
 check([reverse.speedText.stringValue hasPrefix:@"-5.0"]);
 check([source movieRate]==2 && [source frameRate]==5);
 source.window.keyWindow=NO;source.speedSlider.floatValue=9;[source speedSliderAction:nil];
 check(reverse.speedSlider.floatValue==5);
 check([NSUserDefaults.standardUserDefaults floatForKey:@"defaultFrameRate"]==5);
 [NSUserDefaults.standardUserDefaults removeObjectForKey:@"defaultFrameRate"];
 [NSUserDefaults.standardUserDefaults removeObjectForKey:@"defaultMovieRate"];
 NSLog(@"PASS: independent slice/phase controls, reversed label, customized rates preserved, only key viewer propagates");
}}
'''
with tempfile.TemporaryDirectory(prefix='horos-cine-controls-') as tmp:
 p=Path(tmp);(p/'Harness.h').write_text(header);(p/'test.m').write_text(code + harness_defaults.OBJC)
 (p/'Rates.swift').write_text('import AppKit\nimport IsiXImaging\nimport IsiXPreferences\n\n'
                             '// The viewer\'s graph, whose preferences are the harness\'s.\n'
                             '@MainActor struct HarnessGraph {\n    var preferences: any PreferenceStore { UserDefaults.standard }\n}\n\n'
                             'extension ViewerController {\n    var sessionGraph: HarnessGraph! { HarnessGraph() }\n\n'+methods+'}\n\n'
                             +shell+speeds+'}\n')
 subprocess.run(['xcrun','clang','-c','-fno-objc-arc','-I',str(p),str(p/'test.m'),'-o',str(p/'test.o')],check=True)
 subprocess.run(['xcrun','swiftc','-parse-as-library',*module_flags('IsiXImaging', p / 'modules'),*module_flags('IsiXPreferences', p / 'modules'),'-import-objc-header',str(p/'Harness.h'),str(p/'Rates.swift'),
                 str(p/'test.o'),'-framework','AppKit','-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True,timeout=60)
