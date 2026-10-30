#!/usr/bin/env python3
"""ROI font-size menu stays enabled from the 2D viewer after a redraw.

Increase/Decrease Font Size target the first responder. After a font action
the OpenGL view can lose first-responder while it rebuilds, so the next menu
validation must still find the actions on ViewerController and enable them from
LabelFONTSIZE rather than from a selected ROI.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]


def source(name):
    path = 'Horos/Sources/' + name
    if len(sys.argv) <= 1 and not (root / path).exists():
        raise subprocess.CalledProcessError(1, path)
    return (subprocess.check_output(['git', 'show', sys.argv[1] + ':' + path], stderr=subprocess.DEVNULL)
            if len(sys.argv) > 1 else (root / path).read_bytes()).decode('latin1')


# DCMView is Swift; DCMView.m is read only at a revision that still has it.
try:
    view = source('DCMView.m')
except subprocess.CalledProcessError:
    view = ''
# The helper is Swift (DCMView+Drawing.swift) once the drawing left DCMView.m.
try:
    drawing = source('DCMView+Drawing.swift')
except subprocess.CalledProcessError:
    drawing = ''
# ViewerController is Swift; ViewerController.m is read only at a revision that still has it.
try:
    controller = source('ViewerController.m')
except subprocess.CalledProcessError:
    controller = ''
header = source('ViewerController.h')
# The viewer's font-size actions and its menu validation are Swift now
# (ViewerController+Presentation.swift, +MenuValidation.swift), declared for
# Objective-C by ViewerController+Menus.h; their forwarding over stand-ins
# runs in test-viewer-menus-equivalence.py.
swift = '- (void) increaseFontSize:' not in controller


def isolate(text, start, *stops):
    if start not in text:
        print('FAIL: missing', start, file=sys.stderr)
        sys.exit(1)
    a = text.index(start)
    end = len(text)
    for stop in stops:
        i = text.find(stop, a + len(start))
        if i != -1:
            end = min(end, i)
    return text[a:end]


if drawing:
    helper = isolate(drawing, '    @objc(labelFontSizeMenuItemIsEnabled:)', '\n    @objc(increaseFontSize:)')
else:
    helper = isolate(view, '+ (BOOL) labelFontSizeMenuItemIsEnabled:',
                     '\n- (BOOL)validateMenuItem:', '\n- (void) increaseFontSize:')
if swift:
    presentation = source('ViewerController+Presentation.swift')
    increase = isolate(presentation, '@objc(increaseFontSize:)', '\n    @objc(decreaseFontSize:)')
    decrease = isolate(presentation, '@objc(decreaseFontSize:)', '\n    /// Turns the image')
    # Objective-C sees the Swift actions by their @objc names, through the
    # generated interface.
    header = presentation
else:
    increase = isolate(controller, '- (void) increaseFontSize:',
                       '\n- (void) decreaseFontSize:')
    decrease = isolate(controller, '- (void) decreaseFontSize:',
                       '\n- (void) rotate0:', '\n- (void) flipVertical:')
# DCMView's -validateMenuItem: calls -horosValidateMenuItem: of
# DCMView+ROIEditing.swift; before that it was in DCMView.m.
try:
    roi_editing = source('DCMView+ROIEditing.swift')
except subprocess.CalledProcessError:
    roi_editing = ''
if roi_editing:
    view_validate = isolate(roi_editing, 'func horosValidateMenuItem(', '\n    // MARK: - Files')
    view_validate = view_validate.replace('DCMView.labelFontSizeMenuItemIsEnabled(', '[DCMView labelFontSizeMenuItemIsEnabled:')
else:
    view_validate = isolate(view, '- (BOOL)validateMenuItem:',
                             '\n- (IBAction) roiSaveSelected:')
if swift:
    controller_validate = isolate(source('ViewerController+MenuValidation.swift'), 'func validateMenuItem(', '\n}\n')
else:
    controller_validate = isolate(controller, '- (BOOL)validateMenuItem:',
                                   '\n- (IBAction) resetWindowsState:')
validate_call = 'DCMView.labelFontSizeMenuItemIsEnabled(item)' if swift else '[DCMView labelFontSizeMenuItemIsEnabled:'
forward_up = 'horos_imageView?.increaseFontSize(sender)' if swift else '[imageView increaseFontSize: sender]'
forward_down = 'horos_imageView?.decreaseFontSize(sender)' if swift else '[imageView decreaseFontSize: sender]'

if 'increaseThickness:' in helper or 'ROI_selected' in helper:
    print('FAIL: font-size enablement must not require a selected ROI', file=sys.stderr)
    sys.exit(1)
if 'LabelFONTSIZE' not in helper:
    print('FAIL: font-size menu enablement must read LabelFONTSIZE', file=sys.stderr)
    sys.exit(1)
if '[DCMView labelFontSizeMenuItemIsEnabled:' not in view_validate:
    print('FAIL: DCMView validateMenuItem must use the shared LabelFONTSIZE helper',
          file=sys.stderr)
    sys.exit(1)
if 'increaseFontSize:' not in view_validate or 'decreaseFontSize:' not in view_validate:
    print('FAIL: DCMView validateMenuItem does not mention the font-size actions',
          file=sys.stderr)
    sys.exit(1)
if validate_call not in controller_validate:
    print('FAIL: ViewerController validateMenuItem must use the shared LabelFONTSIZE helper',
          file=sys.stderr)
    sys.exit(1)
if 'windowWillClose' in increase or 'closeWindow' in increase + decrease:
    print('FAIL: font-size actions must not recreate the viewer', file=sys.stderr)
    sys.exit(1)
if forward_up not in increase:
    print('FAIL: ViewerController increaseFontSize: must forward to imageView',
          file=sys.stderr)
    sys.exit(1)
if forward_down not in decrease:
    print('FAIL: ViewerController decreaseFontSize: must forward to imageView',
          file=sys.stderr)
    sys.exit(1)
if 'increaseFontSize:' not in header or 'decreaseFontSize:' not in header:
    print('FAIL: ViewerController must declare the font-size actions', file=sys.stderr)
    sys.exit(1)
for forbidden in ('HorosROILineGeometry', 'HorosROILabelPresentation',
                  'generateGeometryFromSelectedLine', 'tMesure'):
    if forbidden in increase + decrease + helper:
        print('FAIL: font-size menu must not touch ROI geometry', file=sys.stderr)
        sys.exit(1)

# The Swift helper is compiled as a method of a Swift class and reached through
# a C function; the Objective-C one, as a method of the DCMView double.
SWIFT = r'''
import Cocoa
class DCMView: NSObject {
HELPER}
@_cdecl("swiftLabelFontSizeMenuItemIsEnabled")
func swiftLabelFontSizeMenuItemIsEnabled(_ item: NSMenuItem) -> Bool { DCMView.labelFontSizeMenuItemIsEnabled(item) }
'''.replace('HELPER', helper)
if drawing:
    helper = '''BOOL swiftLabelFontSizeMenuItemIsEnabled(NSMenuItem *item);
+ (BOOL) labelFontSizeMenuItemIsEnabled:(NSMenuItem *)item { return swiftLabelFontSizeMenuItemIsEnabled(item); }'''

code = r'''
#import <Cocoa/Cocoa.h>
@interface DCMView:NSObject
+ (BOOL) labelFontSizeMenuItemIsEnabled:(NSMenuItem *)item;
@end
@implementation DCMView
HELPER
@end
@interface ImageView:NSObject
@property int increases;
@property int decreases;
-(void)increaseFontSize:(id)sender;
-(void)decreaseFontSize:(id)sender;
@end
@implementation ImageView
-(void)increaseFontSize:(id)sender{self.increases++;}
-(void)decreaseFontSize:(id)sender{self.decreases++;}
@end
@interface ViewerController:NSObject {ImageView *imageView;}
-(void)increaseFontSize:(id)sender;
-(void)decreaseFontSize:(id)sender;
@end
@implementation ViewerController
INCREASE
DECREASE
@end
#define check(...) do {if(!(__VA_ARGS__)){NSLog(@"FAIL: %s",#__VA_ARGS__);return 1;}}while(0)
int main(){@autoreleasepool{
 NSUserDefaults *d=[NSUserDefaults standardUserDefaults];
 NSMenuItem *up=[[NSMenuItem alloc] initWithTitle:@"Increase Font Size" action:@selector(increaseFontSize:) keyEquivalent:@""];
 NSMenuItem *down=[[NSMenuItem alloc] initWithTitle:@"Decrease Font Size" action:@selector(decreaseFontSize:) keyEquivalent:@""];
 for(NSNumber *size in @[@6,@13,@60]){
  [d setVolatileDomain:@{@"LabelFONTSIZE":size} forName:NSArgumentDomain];
  BOOL canUp=[DCMView labelFontSizeMenuItemIsEnabled:up];
  BOOL canDown=[DCMView labelFontSizeMenuItemIsEnabled:down];
  if(size.intValue==6){check(!canDown);check(canUp);}
  else if(size.intValue==13){check(canUp);check(canDown);}
  else {check(!canUp);check(canDown);}
 }
 ViewerController *vc=[ViewerController new];
 ImageView *view=[ImageView new];
 [vc setValue:view forKey:@"imageView"];
 [vc increaseFontSize:up];
 [vc decreaseFontSize:down];
 check(view.increases==1 && view.decreases==1);
 NSLog(@"PASS: LabelFONTSIZE 6/13/60 menu enablement and viewer forwarding");
}}
'''
if swift:
    # The Swift forwards (checked above); the program forwards the same way.
    increase = '- (void) increaseFontSize:(id) sender\n{\n    [imageView increaseFontSize: sender];\n}'
    decrease = '- (void) decreaseFontSize:(id) sender\n{\n    [imageView decreaseFontSize: sender];\n}'
code = code.replace('HELPER', helper).replace('INCREASE', increase).replace('DECREASE', decrease)

with tempfile.TemporaryDirectory(prefix='horos-roi-font-menu-') as d:
    p = Path(d)
    (p / 'test.m').write_text(code)
    if drawing:
        (p / 'helper.swift').write_text(SWIFT)
        subprocess.run(['xcrun', 'swiftc', '-c', '-parse-as-library', '-module-name', 'FontMenu', str(p / 'helper.swift'),
                        '-o', str(p / 'helper.o')], check=True)
        subprocess.run(['xcrun', 'clang', '-c', '-fno-objc-arc', str(p / 'test.m'), '-o', str(p / 'test.o')], check=True)
        subprocess.run(['xcrun', 'swiftc', str(p / 'helper.o'), str(p / 'test.o'), '-framework', 'Cocoa', '-o', str(p / 'test')],
                       check=True)
    else:
        subprocess.run(['xcrun', 'clang', '-fno-objc-arc', '-fsanitize=undefined',
                        '-framework', 'Cocoa', str(p / 'test.m'), '-o', str(p / 'test')],
                       check=True)
    subprocess.run([str(p / 'test')], check=True)
