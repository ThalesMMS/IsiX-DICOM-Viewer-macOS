#!/usr/bin/env python3
"""Shift is the lens of a ROI tool, at any moment of a measurement.

With a ROI tool, Shift alone shows the lens before the click, over a ROI, on
the click, during the drag that draws a ROI or moves a handle, and between the
two clicks of a length; releasing Shift removes it, even in the middle of a
drag, which goes on. Shift alone no longer constrains a ROI's geometry nor puts
a new ROI on every image of the series: Shift and Option together constrain an
oval to a circle, a rectangle to a square and a length to 0, 45 or 90 degrees.
Its other uses stay: Shift+click on a ROI
toggles its selection, Shift+Control syncs the 3D position, Shift+scroll
scrolls fast, and with a tool that draws no ROI Shift is the lens and the zoom.
With the measurement magnifier on, Shift alone hides it while a point is
placed, and brings it back when released; Shift with Option keeps it.

The modifier handler's lens part, -flagsChanged: from its ROI hit test to its
cursor, runs as it is in DCMView+Keyboard.swift, and the predicate it asks as it
is in DCMView+Drawing.swift, compiled as an extension of the same stand-in view
with IsiXImaging, whose ViewInput reads the modifiers. The drag, the move, the click and the ROI geometry are checked
in their sources, and the geometry's constraint runs as it is in IsiXROI.
"""
import private_tmpdir  # noqa: F401
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import class_text, source_text  # noqa: E402
import isix_modules  # noqa: E402

root = Path(__file__).resolve().parents[1]
drawing = (root / 'Horos/Sources/DCMView+Drawing.swift').read_text()
keyboard = source_text('DCMView+Keyboard')
mouse = source_text('DCMView+Mouse')
tracking = source_text('DCMView+MouseTracking')
length = source_text('DCMView+LengthClick')
tools = source_text('DCMView+Tools')
rules = (root / 'Modules/IsiXImaging/Sources/ViewInput/InputRules.swift').read_text()
roi = class_text('ROI')
drag = source_text('DCMView+MouseDragging')


def body(text, signature):
    """A Swift method, from `signature` to the brace that closes its body."""
    start = text.index(signature)
    depth = 0
    for end in range(text.index('{', start), len(text)):
        depth += {'{': 1, '}': -1}.get(text[end], 0)
        if depth == 0:
            return text[start:end + 1]
    raise ValueError(signature)


def swift_method(selector):
    start = drawing.index('    @objc(' + selector + ')')
    start = drawing.rindex('\n\n', 0, start) + 2
    return drawing[start:drawing.index('\n    }\n', start) + 7]


flags = body(keyboard, 'public override dynamic func flagsChanged(with event: NSEvent?)')
assert flags[flags.index('{'):].lstrip('{').lstrip().startswith('self.deleteLens()'), \
    'flagsChanged: no longer removes the lens first: releasing Shift would leave it'
lens_part = flags[flags.index('        var roiHit = false'):flags.index('        if roiHit == false {\n')]
modifiers = tools[tools.index('/// The modifier flags of an event, as ViewInput reads them'):tools.index('/// The messages of the former Objective-C')]
predicate = ('import AppKit\nimport IsiXImaging\nenum MagnifierPresentation { static let measurementDefaultsKey = "magnifyingLensWhileMeasuring" }\n'
             + modifiers + 'extension View {\n' + swift_method('horosShiftLensWantedWithFlags:')
             + swift_method('horosShiftHidesMeasurementMagnifierWithFlags:')
             + '    @objc(flags:) func flags(_ event: NSEvent?) {\n        self.deleteLens()\n' + lens_part
             + '        _ = roiHit\n    }\n}\n')

STAND_IN = r'''
#import <AppKit/AppKit.h>
enum {tWL=0, tMesure=5, tROI=6};
@interface View:NSObject {
@public BOOL lensActive, mouseDragging, overROI, placing; int currentTool, computed, redraws; float mouseXPos, mouseYPos;
}
@property(readonly) int currentTool;
// The accessors of DCMView+SwiftIvars.h the handler reads.
@property(readonly) int horos_currentTool;
@property(readonly) float horos_mouseXPos, horos_mouseYPos;
@property(readonly) BOOL horos_mouseDragging;
@property BOOL needsDisplay;
-(BOOL)roiTool:(int)tool;
-(BOOL)horosPlacingROIPoint;
-(void)deleteLens;
-(void)computeMagnifyLens:(NSPoint)p;
-(NSPoint)convertPoint:(NSPoint)p fromView:(NSView*)v;
-(NSPoint)ConvertFromNSView2GL:(NSPoint)p;
-(id)clickInROI:(NSPoint)p;
@end
'''

code = r'''
#import "View.h"
#import "Test-Swift.h"
#define check(...) do{if(!(__VA_ARGS__)){NSLog(@"FAIL line %d: %s",__LINE__,#__VA_ARGS__);exit(1);}}while(0)
@implementation View
-(int)currentTool{return currentTool;}
-(int)horos_currentTool{return currentTool;}
-(float)horos_mouseXPos{return mouseXPos;}
-(float)horos_mouseYPos{return mouseYPos;}
-(BOOL)horos_mouseDragging{return mouseDragging;}
-(BOOL)needsDisplay{return NO;}
-(BOOL)roiTool:(int)tool{return tool==tMesure||tool==tROI;}
-(void)deleteLens{lensActive=NO;}
-(void)computeMagnifyLens:(NSPoint)p{computed++;if(p.x==0&&p.y==0)return;if([[NSUserDefaults standardUserDefaults] boolForKey:@"magnifyingLens"])lensActive=YES;}
-(NSPoint)convertPoint:(NSPoint)p fromView:(NSView*)v{return p;}
-(NSPoint)ConvertFromNSView2GL:(NSPoint)p{return p;}
-(id)clickInROI:(NSPoint)p{return overROI?self:nil;}
// Only the measurement magnifier asks whether a point is being placed.
-(BOOL)horosPlacingROIPoint{if(![[NSUserDefaults standardUserDefaults] boolForKey:@"magnifyingLensWhileMeasuring"])abort();return placing;}
-(void)setNeedsDisplay:(BOOL)b{redraws++;}
@end
static NSEvent *flagsEvent(NSEventModifierFlags f){
 return [NSEvent keyEventWithType:NSEventTypeFlagsChanged location:NSMakePoint(10,10) modifierFlags:f timestamp:0 windowNumber:0 context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:56];}
int main(){@autoreleasepool{
 NSUserDefaults *d=[NSUserDefaults standardUserDefaults];
 [d registerDefaults:@{@"magnifyingLens":@YES}];
 View *v=[View new];v->mouseXPos=10;v->mouseYPos=10;
 int tools[]={tMesure,tROI};
 for(int i=0;i<2;i++){
  v->currentTool=tools[i];
  // Before the click, over a ROI, during a drag and while a point is placed.
  for(int over=0;over<2;over++)for(int dragging=0;dragging<2;dragging++){
   v->overROI=over;v->mouseDragging=dragging;
   [v flags:flagsEvent(NSEventModifierFlagShift)];check(v->lensActive);
   // Released, the lens goes and the drag stays.
   [v flags:flagsEvent(0)];check(!v->lensActive&&v->mouseDragging==dragging);
  }
  v->overROI=NO;v->mouseDragging=NO;
  for(NSNumber*f in @[@(NSEventModifierFlagShift|NSEventModifierFlagCommand),@(NSEventModifierFlagShift|NSEventModifierFlagOption),@(NSEventModifierFlagShift|NSEventModifierFlagControl)]){
   [v flags:flagsEvent(f.unsignedIntegerValue)];check(!v->lensActive);}
  check(![v horosShiftLensWantedWithFlags:NSEventModifierFlagShift|NSEventModifierFlagCommand]);
  check([v horosShiftLensWantedWithFlags:NSEventModifierFlagShift|NSEventModifierFlagCapsLock]);
 }
 // The lens preference still turns it off.
 [d registerDefaults:@{@"magnifyingLens":@NO}];
 v->currentTool=tMesure;[v flags:flagsEvent(NSEventModifierFlagShift)];check(!v->lensActive);
 check(![v horosShiftLensWantedWithFlags:NSEventModifierFlagShift]);
 [d registerDefaults:@{@"magnifyingLens":@YES}];
 // A tool that draws no ROI keeps its lens out of a drag.
 v->currentTool=tWL;check(![v horosShiftLensWantedWithFlags:NSEventModifierFlagShift]);
 v->mouseDragging=NO;[v flags:flagsEvent(NSEventModifierFlagShift)];check(v->lensActive);
 v->mouseDragging=YES;[v flags:flagsEvent(NSEventModifierFlagShift)];check(!v->lensActive);
 // The measurement magnifier on: Shift hides it while a point is placed, and
 // shows the lens otherwise; Shift+Option keeps it. Each change redraws.
 [d registerDefaults:@{@"magnifyingLensWhileMeasuring":@YES}];
 for(int i=0;i<2;i++){
  v->currentTool=tools[i];v->mouseDragging=YES;v->placing=YES;
  check([v horosShiftHidesMeasurementMagnifierWithFlags:NSEventModifierFlagShift]);
  check(![v horosShiftHidesMeasurementMagnifierWithFlags:NSEventModifierFlagShift|NSEventModifierFlagOption]);
  check(![v horosShiftHidesMeasurementMagnifierWithFlags:0]);
  int r=v->redraws;[v flags:flagsEvent(NSEventModifierFlagShift)];check(!v->lensActive&&v->redraws>r);
  r=v->redraws;[v flags:flagsEvent(0)];check(!v->lensActive&&v->redraws>r);
  v->placing=NO;[v flags:flagsEvent(NSEventModifierFlagShift)];check(v->lensActive);
 }
 v->currentTool=tWL;v->placing=YES;check(![v horosShiftHidesMeasurementMagnifierWithFlags:NSEventModifierFlagShift]);
 NSLog(@"PASS");
}}
'''

with tempfile.TemporaryDirectory(prefix='horos-shift-lens-') as d:
    p = Path(d)
    (p / 'View.h').write_text(STAND_IN)
    (p / 'predicate.swift').write_text(predicate)
    (p / 'test.m').write_text(code)
    module = isix_modules.module_flags('IsiXImaging', p / 'module')
    subprocess.run(['xcrun', 'swiftc', '-c', '-parse-as-library', '-module-name', 'Test', '-import-objc-header', str(p / 'View.h'),
                    *module, '-emit-objc-header-path', str(p / 'Test-Swift.h'), str(p / 'predicate.swift'), '-o', str(p / 'predicate.o')],
                   check=True, cwd=p)
    subprocess.run(['xcrun', 'clang', '-c', '-fobjc-arc', '-Werror', '-Wno-unused-variable', '-I', str(p),
                    str(p / 'test.m'), '-o', str(p / 'test.o')], check=True)
    subprocess.run(['xcrun', 'swiftc', str(p / 'predicate.o'), str(p / 'test.o'), *module, '-framework', 'AppKit', '-o', str(p / 'test')],
                   check=True)
    subprocess.run([str(p / 'test')], check=True)

# The move: Shift shows the lens of every tool while no button drags, a ROI
# tool's included, over a ROI and on the click; Shift+Control syncs 3D first.
moved = body(tracking, 'private func readPixelsUnderMouse(')
shift_branch = moved[moved.index('} else if ViewInput.isShiftAlone(modifiers)'):]
shift_branch = shift_branch[:shift_branch.index('let xPos')]
assert 'self.horos_mouseDragging == false' in shift_branch and 'self.computeMagnifyLens(imageLocation)' in shift_branch
for gate in ('horosPlacingROIPoint', 'roiTool', '.mouseMoved', 'horosROIUnderPoint'):
    assert gate not in shift_branch, f'the move still gates the ROI lens on {gate}'
assert moved.index('self.sync3DPosition()') < moved.index('} else if ViewInput.isShiftAlone(modifiers)'), \
    'Shift+Control no longer syncs the 3D position first'

# The drag: the lens goes at each event and a ROI tool's comes back after the
# ROI has taken the point, if Shift alone is held.
dragged = drag[drag.index('    @objc(mouseDragged:)'):drag.index('    @objc(currentPointInView:)')]
roi_part = dragged[dragged.index('if self.roiTool(tool) {'):dragged.index('/********** Actions for Various Tools')]
assert dragged.index('self.deleteLens()') < dragged.index('if self.roiTool(tool) {')
assert roi_part.index('self.mouseDragged(forROIs: event)') < roi_part.index(
    'if self.horosShiftLensWanted(with: event.modifierFlags) {') < roi_part.index('self.computeMagnifyLens(tempPt)'), \
    'the drag does not show the lens over the point the ROI has taken'
# The predicate keeps its Objective-C selector; its callers are all Swift now.
assert '    @objc(horosShiftLensWantedWithFlags:)\n' in drawing

# The click: the lens stays on it; Shift starts the two clicks of a length; a
# ROI drawn with Shift goes on this image alone; Shift+click on a ROI toggles it.
down = body(mouse, 'private func mouseDownWithROITool(')
assert 'isAliased = true' not in down and 'originalIndexForAlias' not in down, 'Shift still aliases a new ROI to the series'
toggle = down[down.index('if flags.contains(.shift) && !flags.contains(.command) {'):]
toggle = toggle[:toggle.index('if doNothing == false {')]
assert 'r.roImode = Int(ROI_sleep)' in toggle and 'doNothing = true' in toggle, 'Shift+click on a ROI no longer toggles its selection'
begin = body(length, 'public dynamic func beginLengthClick(')
assert '.shift' not in begin and '.command' in begin
assert 'horosShiftLensWanted' not in body(mouse, 'public dynamic func shouldIgnoreHiddenCursorEvent(')

# The other uses of Shift: zoom for the tools that draw no ROI, fast scroll.
tool = body(rules, 'public static func tool(button: Button')
assert 'if m & shift != 0 { tool = 2 } // zoom' in tool
assert 'ViewInput.tool(button: button' in body(tools, 'public dynamic func getTool(')
assert '} else if modifiers.contains(.shift) {' in body(source_text('DCMView+Scrolling'), 'public override dynamic func scrollWheel(')

# The geometry: Shift alone constrains nothing in a ROI's drag, where every
# constraint asks the one predicate. The brush keeps Command without Shift for
# its eraser, which is no geometry.
dragged_roi = roi[roi.index('    private func drag(to pt: NSPoint'):]
dragged_roi = dragged_roi[:dragged_roi.index('\n    }\n') + 6]
shift_lines = [line.strip() for line in dragged_roi.splitlines() if 'NSEvent.ModifierFlags.shift' in line]
assert shift_lines == ['if modifier & UInt32(NSEvent.ModifierFlags.command.rawValue) != 0 && '
                       'modifier & UInt32(NSEvent.ModifierFlags.shift.rawValue) == 0 {'], shift_lines
assert dragged_roi.count('ROIDragConstraint.isConstrained(modifierFlags: modifier)') == 1
assert len([line for line in dragged_roi.splitlines() if 'constrained' in line.replace('ROIDragConstraint.constrained', '')
            and 'let constrained' not in line]) == 4, \
    'the oval and rectangle drawn, the oval resized, and the length drawn and edited each ask the predicate'

# The predicate and the length's constraint run as they are in IsiXROI.
constraint = r"""
import AppKit
import IsiXROI
func check(_ c: Bool, _ line: Int = #line) { if !c { print("FAIL line \(line)"); exit(1) } }
let S = UInt32(NSEvent.ModifierFlags.shift.rawValue), O = UInt32(NSEvent.ModifierFlags.option.rawValue)
let C = UInt32(NSEvent.ModifierFlags.command.rawValue), T = UInt32(NSEvent.ModifierFlags.control.rawValue)
let K = UInt32(NSEvent.ModifierFlags.capsLock.rawValue)
func c(_ m: UInt32) -> Bool { ROIDragConstraint.isConstrained(modifierFlags: m) }
check(c(S|O))
check(c(S|O|K))
// Shift alone is the lens, Option alone the window level, Command+Option the rotation.
check(!c(0) && !c(S) && !c(O))
check(!c(S|O|C) && !c(S|O|T) && !c(C|O))
let a = CGPoint(x: 100, y: 100)
func e(_ x: CGFloat, _ y: CGFloat, _ r: Double = 1) -> CGPoint { ROIDragConstraint.constrainedLengthEnd(from: a, to: CGPoint(x: x, y: y), ratio: r) }
check(e(160, 110) == CGPoint(x: 160, y: 100))   // horizontal
check(e(40, 90) == CGPoint(x: 40, y: 100))
check(e(110, 170) == CGPoint(x: 100, y: 170))   // vertical
check(e(90, 30) == CGPoint(x: 100, y: 30))
check(e(160, 150) == CGPoint(x: 160, y: 160))   // the four diagonals
check(e(160, 50) == CGPoint(x: 160, y: 40))
check(e(40, 150) == CGPoint(x: 40, y: 160))
check(e(40, 50) == CGPoint(x: 40, y: 40))
// A length of no extent stays where it is.
check(e(100, 100) == a)
// Pixels 1.25 times taller than wide, as in a reformatted plane: the angles
// and the circle hold in millimetres, so a pixel up is 1.25 pixels across.
check(e(160, 145, 1.25) == CGPoint(x: 160, y: 148))   // diagonal in mm
check(e(160, 50, 1.25) == CGPoint(x: 160, y: 52))
check(e(160, 120, 1.25) == CGPoint(x: 160, y: 100))   // 22.6 degrees in mm
check(e(130, 180, 1.25) == CGPoint(x: 100, y: 180))
check(ROIDragConstraint.pixelRatio(spacingX: 0.5, spacingY: 0.625) == 1.25)
check(ROIDragConstraint.pixelRatio(spacingX: 0, spacingY: 0.625) == 1 && ROIDragConstraint.pixelRatio(spacingX: 0.5, spacingY: 0) == 1)
// The circle's or square's width: the height's millimetres, on the side dragged to.
func w(_ w: Double, _ h: Double, _ r: Double) -> Double { ROIDragConstraint.constrainedWidth(w, height: h, ratio: r) }
check(w(10, 40, 1) == 40 && w(-10, 40, 1) == -40 && w(10, -40, 1) == 40)
check(w(10, 40, 1.25) == 50 && w(-10, -40, 1.25) == -50)
print("PASS")
"""

with tempfile.TemporaryDirectory(prefix='horos-roi-constraint-') as d:
    p = Path(d)
    (p / 'main.swift').write_text(constraint)
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(p / 'cache'), *isix_modules.module_flags('IsiXROI', p),
                    str(p / 'main.swift'), '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True)

print('PASS: Shift shows a ROI tool\'s lens before, on and during the click, over ROIs and between the two clicks of a '
      'length, goes on release mid-drag, constrains no geometry alone and aliases nothing; Shift+Option constrains '
      'the circle, the square and the length\'s angle; its other uses stay')
