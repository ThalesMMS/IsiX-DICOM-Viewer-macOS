#!/usr/bin/env python3
"""A trackpad pinch or rotation reaches the other viewers as it happens.

The zoom tool and the scroll-wheel zoom call -[ViewerController
propagateSettings] on every change, so viewers that share settings follow.
-magnifyWithEvent: and -rotateWithEvent: changed the zoom and the angle
without it: the other viewers followed only at the next click, whose
-mouseDown: ends in -mouseDragged:. The production gesture handlers run here
against a stand-in DCMView and window controller, in a 2D viewer and in a
view that is not one (MPR, CPR), which must not propagate.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
view = (root / 'Horos/Sources/DCMView.m').read_bytes().decode('utf-8')


def body(signature):
    start = view.index(signature)
    return view[start:view.index('\n}\n', start) + 3]


methods = body('-(void) magnifyWithEvent:(NSEvent *)anEvent') + body('-(void) rotateWithEvent:(NSEvent *)anEvent')

code = r'''
#import <Cocoa/Cocoa.h>
@interface Controller : NSObject
@property int propagations, cancels;
@end
@implementation Controller
- (void)propagateSettings { self.propagations++; }
@end
@interface Gesture : NSObject
@property CGFloat deltaZ;
@property float rotation;
@end
@implementation Gesture
@end
@interface DCMView : NSObject { @public float scaleValue, rotation; BOOL twoD; Controller *controller; }
@end
@implementation DCMView
- (BOOL)is2DViewer { return twoD; }
- (Controller*)windowController { return controller; }
- (void)cancelOpeningScaleToFitForInteraction { controller.cancels++; }
- (void)setScaleValue:(float)x { scaleValue = x; }
- (void)setRotation:(float)x { rotation = x; }
- (void)setNeedsDisplay:(BOOL)flag {}
METHODS
@end
#define check(...) do { if (!(__VA_ARGS__)) { NSLog(@"FAIL: %s", #__VA_ARGS__); return 1; } } while (0)
int main() { @autoreleasepool {
    DCMView *v = [DCMView new];
    v->controller = [Controller new]; v->twoD = YES; v->scaleValue = 1;
    Gesture *pinch = [Gesture new]; pinch.deltaZ = 30;
    [v magnifyWithEvent:(NSEvent*)pinch];
    check(fabsf(v->scaleValue - 1.5f) < 1e-5 && v->controller.propagations == 1 && v->controller.cancels == 1);
    [v magnifyWithEvent:(NSEvent*)pinch];
    check(v->controller.propagations == 2);

    Gesture *turn = [Gesture new]; turn.rotation = 10;
    [v rotateWithEvent:(NSEvent*)turn];
    check(fabsf(v->rotation + 15) < 1e-5 && v->controller.propagations == 3 && v->controller.cancels == 3);

    // A view that is not a 2D viewer changes itself only.
    DCMView *mpr = [DCMView new];
    mpr->controller = [Controller new]; mpr->scaleValue = 1;
    [mpr magnifyWithEvent:(NSEvent*)pinch];
    [mpr rotateWithEvent:(NSEvent*)turn];
    check(fabsf(mpr->scaleValue - 1.5f) < 1e-5 && mpr->controller.propagations == 0);
    NSLog(@"PASS: pinch and rotation propagate from a 2D viewer on every gesture event, not from other views");
}}
'''.replace('METHODS', methods)

with tempfile.TemporaryDirectory(prefix='horos-gesture-propagate-') as folder:
    p = Path(folder)
    (p / 'test.m').write_text(code)
    subprocess.run(['xcrun', 'clang', '-fno-objc-arc', '-Wno-objc-method-access', '-framework', 'Cocoa',
                    str(p / 'test.m'), '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True)
print('PASS: trackpad gestures propagate like the zoom tool')
