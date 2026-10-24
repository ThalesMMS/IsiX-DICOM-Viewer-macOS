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
cursor, and the predicate it asks run as they are in DCMView.m, compiled in a
stand-in view. The drag, the move, the click and the ROI geometry are checked
in their sources.
"""
import private_tmpdir  # noqa: F401
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import source_text  # noqa: E402

root = Path(__file__).resolve().parents[1]
view = (root / 'Horos/Sources/DCMView.m').read_bytes().decode('latin1')
roi = (root / 'Horos/Sources/ROI.m').read_bytes().decode('latin1')
drag = source_text('DCMView+MouseDragging')


def body(text, signature):
    start = text.index(signature)
    return text[start:text.index('\n}\n', start)]


# The measurement magnifier's key, as the stand-in has no Swift.
MEASURE = ('HorosMagnifierPresentation.measurementDefaultsKey', '@"magnifyingLensWhileMeasuring"')
predicate = (body(view, '- (BOOL) horosShiftLensWantedWithFlags:') + '\n}\n'
             + body(view, '- (BOOL) horosShiftHidesMeasurementMagnifierWithFlags:') + '\n}\n').replace(*MEASURE)
flags = body(view, '- (void) flagsChanged:(NSEvent *)event')
assert flags[flags.index('{'):].lstrip('{').lstrip().startswith('[self deleteLens];'), \
    'flagsChanged: no longer removes the lens first: releasing Shift would leave it'
lens_part = flags[flags.index('    BOOL roiHit = NO;'):flags.index('    if( roiHit == NO)\n')].replace(*MEASURE)

code = r'''
#import <AppKit/AppKit.h>
#define check(...) do{if(!(__VA_ARGS__)){NSLog(@"FAIL line %d: %s",__LINE__,#__VA_ARGS__);exit(1);}}while(0)
enum {tWL=0, tMesure=5, tROI=6};
@interface View:NSObject {
@public BOOL lensActive, mouseDragging, overROI, placing; int currentTool, computed, redraws; float mouseXPos, mouseYPos;
}
@end
@implementation View
-(BOOL)roiTool:(int)tool{return tool==tMesure||tool==tROI;}
-(void)deleteLens{lensActive=NO;}
-(void)computeMagnifyLens:(NSPoint)p{computed++;if(p.x==0&&p.y==0)return;if([[NSUserDefaults standardUserDefaults] boolForKey:@"magnifyingLens"])lensActive=YES;}
-(NSPoint)convertPoint:(NSPoint)p fromView:(id)v{return p;}
-(NSPoint)ConvertFromNSView2GL:(NSPoint)p{return p;}
-(id)clickInROI:(NSPoint)p{return overROI?self:nil;}
// Only the measurement magnifier asks whether a point is being placed.
-(BOOL)horosPlacingROIPoint{if(![[NSUserDefaults standardUserDefaults] boolForKey:@"magnifyingLensWhileMeasuring"])abort();return placing;}
-(void)setNeedsDisplay:(BOOL)b{redraws++;}
PREDICATE
-(void)flags:(NSEvent*)event
{
    [self deleteLens];
LENSPART
}
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
'''.replace('PREDICATE', predicate).replace('LENSPART', lens_part)

with tempfile.TemporaryDirectory(prefix='horos-shift-lens-') as d:
    p = Path(d)
    (p / 'test.m').write_text(code)
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-Werror', '-Wno-unused-variable', '-framework', 'AppKit',
                    str(p / 'test.m'), '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True)

# The move: Shift shows the lens of every tool while no button drags, a ROI
# tool's included, over a ROI and on the click; Shift+Control syncs 3D first.
moved = body(view, '-(void) mouseMovedInView:')
shift_branch = moved[moved.index('else if( (modifierFlags & (NSEventModifierFlagShift|'):]
shift_branch = shift_branch[:shift_branch.index('int\n')]
assert 'mouseDragging == NO' in shift_branch and '[self computeMagnifyLens: imageLocation];' in shift_branch
for gate in ('horosPlacingROIPoint', 'roiTool', 'NSEventTypeMouseMoved', 'horosROIUnderPoint'):
    assert gate not in shift_branch, f'the move still gates the ROI lens on {gate}'
assert moved.index('[self sync3DPosition];') < moved.index('else if( (modifierFlags & (NSEventModifierFlagShift|'), \
    'Shift+Control no longer syncs the 3D position first'

# The drag: the lens goes at each event and a ROI tool's comes back after the
# ROI has taken the point, if Shift alone is held.
dragged = drag[drag.index('    @objc(mouseDragged:)'):drag.index('    @objc(currentPointInView:)')]
roi_part = dragged[dragged.index('if self.roiTool(tool) {'):dragged.index('/********** Actions for Various Tools')]
assert dragged.index('self.deleteLens()') < dragged.index('if self.roiTool(tool) {')
assert roi_part.index('self.mouseDragged(forROIs: event)') < roi_part.index(
    'if self.horosShiftLensWanted(with: event.modifierFlags) {') < roi_part.index('self.computeMagnifyLens(self.preciseMagnifyLensPoint(tempPt))'), \
    'the drag does not show the lens over the point the ROI has taken'
header = (root / 'Horos/Sources/DCMView+SwiftIvars.h').read_text()
assert '- (BOOL) horosShiftLensWantedWithFlags:(NSEventModifierFlags) flags;' in header

# The click: the lens stays on it; Shift starts the two clicks of a length; a
# ROI drawn with Shift goes on this image alone; Shift+click on a ROI toggles it.
down = body(view, '- (void) mouseDown:(NSEvent *)event')
assert 'isAliased = YES' not in down and 'originalIndexForAlias' not in down, 'Shift still aliases a new ROI to the series'
toggle = down[down.index('if (([event modifierFlags] & NSEventModifierFlagShift) && !([event modifierFlags] & NSEventModifierFlagCommand) )'):]
toggle = toggle[:toggle.index('if( DoNothing == NO)')]
assert 'setROIMode: ROI_sleep' in toggle and 'DoNothing = YES' in toggle, 'Shift+click on a ROI no longer toggles its selection'
begin = body(view, '- (BOOL)beginLengthClick:')
assert 'NSEventModifierFlagShift' not in begin and 'NSEventModifierFlagCommand' in begin
assert 'horosShiftLensWantedWithFlags' not in body(view, '- (BOOL) shouldIgnoreHiddenCursorEvent:')

# The other uses of Shift: zoom for the tools that draw no ROI, fast scroll.
tool = body(view, '- (ToolMode) getTool: (NSEvent*) event')
assert 'if (([event modifierFlags] & NSEventModifierFlagShift))  tool = tZoom;' in tool
assert 'else if( [theEvent modifierFlags]  & NSEventModifierFlagShift)' in body(view, '- (void)scrollWheel:(NSEvent *)theEvent')

# The geometry: Shift alone constrains nothing in a ROI's drag, where every
# constraint asks the one predicate. The brush keeps Command without Shift for
# its eraser, which is no geometry.
dragged_roi = body(roi, '- (BOOL) mouseRoiDragged:')
shift_lines = [line.strip() for line in dragged_roi.splitlines() if 'NSEventModifierFlagShift' in line]
assert shift_lines == ['if( modifier & NSEventModifierFlagCommand && !(modifier & NSEventModifierFlagShift))'], shift_lines
assert dragged_roi.count('HorosROIDragIsConstrained( modifier)') == 4, \
    'the oval and rectangle drawn, the oval resized, and the length drawn and edited each ask the predicate'

# The predicate and the length's constraint run as they are in ROI.m.
helpers = roi[roi.index('static BOOL HorosROIDragIsConstrained('):roi.index('- (BOOL) mouseRoiDragged:')]
constraint = r'''
#import <AppKit/AppKit.h>
#define check(...) do{if(!(__VA_ARGS__)){NSLog(@"FAIL line %d: %s",__LINE__,#__VA_ARGS__);exit(1);}}while(0)
HELPERS
int main(){@autoreleasepool{
 unsigned int S=NSEventModifierFlagShift,O=NSEventModifierFlagOption,C=NSEventModifierFlagCommand,T=NSEventModifierFlagControl;
 check(HorosROIDragIsConstrained(S|O));
 check(HorosROIDragIsConstrained(S|O|NSEventModifierFlagCapsLock));
 // Shift alone is the lens, Option alone the window level, Command+Option the rotation.
 check(!HorosROIDragIsConstrained(0)&&!HorosROIDragIsConstrained(S)&&!HorosROIDragIsConstrained(O));
 check(!HorosROIDragIsConstrained(S|O|C)&&!HorosROIDragIsConstrained(S|O|T)&&!HorosROIDragIsConstrained(C|O));
 NSPoint a=NSMakePoint(100,100),e;
 e=HorosConstrainedLengthEnd(a,NSMakePoint(160,110),1);check(e.x==160&&e.y==100);   // horizontal
 e=HorosConstrainedLengthEnd(a,NSMakePoint(40,90),1);check(e.x==40&&e.y==100);
 e=HorosConstrainedLengthEnd(a,NSMakePoint(110,170),1);check(e.x==100&&e.y==170);   // vertical
 e=HorosConstrainedLengthEnd(a,NSMakePoint(90,30),1);check(e.x==100&&e.y==30);
 e=HorosConstrainedLengthEnd(a,NSMakePoint(160,150),1);check(e.x==160&&e.y==160);   // the four diagonals
 e=HorosConstrainedLengthEnd(a,NSMakePoint(160,50),1);check(e.x==160&&e.y==40);
 e=HorosConstrainedLengthEnd(a,NSMakePoint(40,150),1);check(e.x==40&&e.y==160);
 e=HorosConstrainedLengthEnd(a,NSMakePoint(40,50),1);check(e.x==40&&e.y==40);
 // A length of no extent stays where it is.
 e=HorosConstrainedLengthEnd(a,a,1);check(e.x==100&&e.y==100);
 // Pixels 1.25 times taller than wide, as in a reformatted plane: the angles
 // and the circle hold in millimetres, so a pixel up is 1.25 pixels across.
 e=HorosConstrainedLengthEnd(a,NSMakePoint(160,145),1.25);check(e.x==160&&e.y==148);   // diagonal in mm
 e=HorosConstrainedLengthEnd(a,NSMakePoint(160,50),1.25);check(e.x==160&&e.y==52);
 e=HorosConstrainedLengthEnd(a,NSMakePoint(160,120),1.25);check(e.x==160&&e.y==100);   // 22.6 degrees in mm
 e=HorosConstrainedLengthEnd(a,NSMakePoint(130,180),1.25);check(e.x==100&&e.y==180);
 check(HorosROIPixelRatio(0.5,0.625)==1.25);
 check(HorosROIPixelRatio(0,0.625)==1&&HorosROIPixelRatio(0.5,0)==1);
 // The circle's or square's width: the height's millimetres, on the side dragged to.
 check(HorosConstrainedWidth(10,40,1)==40&&HorosConstrainedWidth(-10,40,1)==-40&&HorosConstrainedWidth(10,-40,1)==40);
 check(HorosConstrainedWidth(10,40,1.25)==50&&HorosConstrainedWidth(-10,-40,1.25)==-50);
 NSLog(@"PASS");
}}
'''.replace('HELPERS', helpers)

with tempfile.TemporaryDirectory(prefix='horos-roi-constraint-') as d:
    p = Path(d)
    (p / 'test.m').write_text(constraint)
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-Werror', '-framework', 'AppKit',
                    str(p / 'test.m'), '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True)

print('PASS: Shift shows a ROI tool\'s lens before, on and during the click, over ROIs and between the two clicks of a '
      'length, goes on release mid-drag, constrains no geometry alone and aliases nothing; Shift+Option constrains '
      'the circle, the square and the length\'s angle; its other uses stay')
