#!/usr/bin/env python3
"""A new contour drawn over a ROI of a neighbouring image joins its object.

Volume, renaming and propagation group a series' ROIs by name. New ROIs get a
numbered name ("Oval 1", "Oval 2") by default, so each is an object of its
own; with ROIJoinOverlappingOnAdjacentImage on (the default), a contour that
covers at least a tenth of a ROI on one of the two images before or after it
takes that ROI's name once it is finished. The nearest image wins, then the
larger overlap. Images whose plane is not parallel, "Unnamed" ROIs and
contours still being drawn are left alone, and nothing joins with the
option off.

The production -[DCMView planePointsOfROI:onImage:] and
-joinFinishedContourToAdjacentObject run here against stand-ins for DCMPix,
ROI and MyPoint, with the real HorosROIObjectJoin and HorosROIName. The
production creation block also runs, including naming and join eligibility. The defaults, the hooks in
-mouseDown:/-mouseUp:, the ROI Manager's rename and the check box bound in
every localization of the Viewer pane are checked in the sources.
"""
from pathlib import Path
import subprocess
import tempfile
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
KEY = 'ROIJoinOverlappingOnAdjacentImage'
view = (root / 'Horos/Sources/DCMView.m').read_bytes().decode('utf-8')


def body(signature):
    start = view.index(signature)
    return view[start:view.index('\n}\n', start) + 3]


methods = body('- (NSArray*)planePointsOfROI:(ROI*)roi onImage:(long)image') + \
    body('- (void)joinFinishedContourToAdjacentObject')

creation = view[view.index('                                NSString *roiName = [ROI defaultName];'):]
creation = creation[:creation.index('                                // Shift is the lens')]

code = r'''
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import "Join-Swift.h"
enum { tOval, tDynAngle, tTAGT, tAxis, tOPolygon, tCPolygon, tAngle, tArrow, tPlain, tPencil, tMesure, tROI, t2DPoint, tText };
enum { ROI_sleep = 0, ROI_drawing = 1, ROI_selected = 2 };
static NSString *OsirixROIChangeNotification = @"OsirixROIChangeNotification";
static char HorosContourAwaitingJoinKey;
@interface MyPoint : NSObject
@property float x, y;
@end
@implementation MyPoint
@end
@interface ROI : NSObject
@property(copy) NSString *name;
@property long ROImode;
@property BOOL area;
@property(retain) NSArray *points;
@end
static NSString *defaultROIName;
@implementation ROI
+ (NSString*)defaultName { return defaultROIName; }
+ (void)setDefaultName:(NSString*)name { defaultROIName = name; }
- (BOOL)isValidForVolume { return self.area; }
@end
// Pixel (x, y) is origin + x * spacing * row + y * spacing * column.
@interface DCMPix : NSObject { @public double o[9]; double spacing; }
@property double originX, originY, originZ;
@end
@implementation DCMPix
- (void)orientationDouble:(double*)c { memcpy(c, o, sizeof o); }
- (void)convertPixDoubleX:(double)x pixY:(double)y toDICOMCoords:(double*)d
{
    d[0] = self.originX + spacing * (x * o[0] + y * o[3]);
    d[1] = self.originY + spacing * (x * o[1] + y * o[4]);
    d[2] = self.originZ + spacing * (x * o[2] + y * o[5]);
}
@end
@interface DCMView : NSObject { @public NSMutableArray *curRoiList, *dcmRoiList, *dcmPixList; short curImage; }
@end
@implementation DCMView
- (DCMPix*)curDCM { return dcmPixList[curImage]; }
- (BOOL)is2DViewer { return YES; }
- (void)nameAndPrepareROI:(ROI*)aNewROI tool:(int)tool {
CREATION
}
METHODS
@end
#define check(...) do { if (!(__VA_ARGS__)) { NSLog(@"FAIL: %s", #__VA_ARGS__); return 1; } } while (0)
static DCMPix *axial(double z, double spacing)
{
    DCMPix *p = [DCMPix new];
    double o[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
    memcpy(p->o, o, sizeof o); p->spacing = spacing; p.originZ = z;
    return p;
}
static ROI *circle(NSString *name, float cx, float cy, float r)
{
    ROI *roi = [ROI new]; roi.name = name; roi.area = YES; roi.ROImode = ROI_selected;
    NSMutableArray *points = [NSMutableArray array];
    for (int i = 0; i < 48; i++) {
        MyPoint *p = [MyPoint new];
        p.x = cx + r * cos(i * 2 * M_PI / 48); p.y = cy + r * sin(i * 2 * M_PI / 48);
        [points addObject:p];
    }
    roi.points = points;
    return roi;
}
static DCMView *series(int images)
{
    DCMView *v = [DCMView new];
    v->dcmPixList = [NSMutableArray array]; v->dcmRoiList = [NSMutableArray array];
    for (int i = 0; i < images; i++) { [v->dcmPixList addObject:axial(i * 3.0, 0.5)]; [v->dcmRoiList addObject:[NSMutableArray array]]; }
    return v;
}
static void draw(DCMView *v, int image, ROI *roi)
{
    v->curImage = image; v->curRoiList = v->dcmRoiList[image];
    [v->curRoiList addObject:roi];
    objc_setAssociatedObject(v, &HorosContourAwaitingJoinKey, roi, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [v joinFinishedContourToAdjacentObject];
}
int main() { @autoreleasepool {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setVolatileDomain:@{@"KEY": @YES} forName:NSArgumentDomain];
    __block int changes = 0;
    [[NSNotificationCenter defaultCenter] addObserverForName:OsirixROIChangeNotification object:nil queue:nil usingBlock:^(NSNotification *n) { changes++; }];

    // A lesion outlined on images 2 and 3 is one object; a separate oval is not.
    DCMView *v = series(8);
    [v->dcmRoiList[2] addObject:circle(@"Oval 1", 100, 100, 20)];
    ROI *next = circle(@"Oval 2", 106, 100, 20), *apart = circle(@"Oval 3", 300, 300, 20);
    draw(v, 3, next);
    draw(v, 3, apart);
    check([next.name isEqualToString:@"Oval 1"] && [apart.name isEqualToString:@"Oval 3"] && changes == 1);

    // Outlining every other image still joins; the nearest image wins.
    ROI *skipped = circle(@"Oval 4", 100, 100, 20);
    draw(v, 5, skipped);
    check([skipped.name isEqualToString:@"Oval 1"]);
    [v->dcmRoiList[6] addObject:circle(@"Lesion B", 112, 100, 20)];
    ROI *between = circle(@"Oval 5", 100, 100, 20);
    draw(v, 7, between);
    check([between.name isEqualToString:@"Lesion B"]);

    // Edges that only touch, Unnamed ROIs and non-volume ROIs stay apart.
    DCMView *w = series(4);
    [w->dcmRoiList[0] addObject:circle(@"Oval 1", 100, 100, 20)];
    [w->dcmRoiList[0] addObject:circle(@"Unnamed", 300, 100, 20)];
    ROI *length = circle(@"Measurement 1", 100, 300, 20); length.area = NO;
    [w->dcmRoiList[0] addObject:length];
    ROI *touching = circle(@"Oval 2", 139, 100, 20), *overUnnamed = circle(@"Oval 3", 300, 100, 20), *overLength = circle(@"Oval 4", 100, 300, 20);
    draw(w, 1, touching); draw(w, 1, overUnnamed); draw(w, 1, overLength);
    check([touching.name isEqualToString:@"Oval 2"] && [overUnnamed.name isEqualToString:@"Oval 3"] && [overLength.name isEqualToString:@"Oval 4"]);

    // A sagittal image with the same pixel coordinates is another plane.
    DCMView *s = series(2);
    double sagittal[9] = {0, 1, 0, 0, 0, 1, 1, 0, 0};
    memcpy(((DCMPix*)s->dcmPixList[0])->o, sagittal, sizeof sagittal);
    [s->dcmRoiList[0] addObject:circle(@"Oval 1", 100, 100, 20)];
    ROI *crossing = circle(@"Oval 2", 100, 100, 20);
    draw(s, 1, crossing);
    check([crossing.name isEqualToString:@"Oval 2"]);

    // Contours of images with another spacing and origin compare in millimetres.
    DCMView *m = series(2);
    ((DCMPix*)m->dcmPixList[0])->spacing = 1.0; ((DCMPix*)m->dcmPixList[0]).originX = -50;
    [m->dcmRoiList[0] addObject:circle(@"Oval 1", 100, 100, 10)];   // centre at x = 50 mm, y = 100 mm
    ROI *mm = circle(@"Oval 2", 100, 200, 20);                    // centre at x = 50 mm, y = 100 mm
    draw(m, 1, mm);
    check([mm.name isEqualToString:@"Oval 1"]);

    // A contour still being drawn waits; the option off leaves names alone.
    DCMView *p = series(2);
    [p->dcmRoiList[0] addObject:circle(@"Oval 1", 100, 100, 20)];
    ROI *drawing = circle(@"Polygon 1", 100, 100, 20); drawing.ROImode = ROI_drawing;
    draw(p, 1, drawing);
    check([drawing.name isEqualToString:@"Polygon 1"] && objc_getAssociatedObject(p, &HorosContourAwaitingJoinKey) == drawing);
    drawing.ROImode = ROI_selected;
    [p joinFinishedContourToAdjacentObject];
    check([drawing.name isEqualToString:@"Oval 1"] && objc_getAssociatedObject(p, &HorosContourAwaitingJoinKey) == nil);
    [d setVolatileDomain:@{@"KEY": @NO} forName:NSArgumentDomain];
    ROI *off = circle(@"Oval 2", 100, 100, 20);
    draw(p, 1, off);
    check([off.name isEqualToString:@"Oval 2"]);

    // Execute the actual mouseDown naming and eligibility block, across slices.
    [d setVolatileDomain:@{@"KEY": @YES} forName:NSArgumentDomain];
    [ROI setDefaultName:@"Lesão"];
    DCMView *named = series(5);
    for (int i = 0; i < 3; i++) {
        named->curImage = i; named->curRoiList = named->dcmRoiList[i];
        ROI *r = circle(@"Unnamed", 100 + 150*i, 100, 20);
        [named nameAndPrepareROI:r tool:tOval];
        check([r.name isEqualToString:[NSString stringWithFormat:@"Lesão %d", i+1]]);
        check(objc_getAssociatedObject(named, &HorosContourAwaitingJoinKey) == r);
        [named->curRoiList addObject:r];
        [named joinFinishedContourToAdjacentObject];
        check([r.name isEqualToString:[NSString stringWithFormat:@"Lesão %d", i+1]]);
    }
    [ROI setDefaultName:@"Lesão 1"];
    named->curImage = 3; named->curRoiList = named->dcmRoiList[3];
    ROI *over = circle(@"Unnamed", 400, 100, 20);
    [named nameAndPrepareROI:over tool:tOval];
    check([over.name isEqualToString:@"Lesão 4"]);
    [named->curRoiList addObject:over];
    [named joinFinishedContourToAdjacentObject];
    check([over.name isEqualToString:@"Lesão 3"]);
    [d setVolatileDomain:@{@"KEY": @NO} forName:NSArgumentDomain];
    ROI *separate = circle(@"Unnamed", 400, 100, 20);
    [named nameAndPrepareROI:separate tool:tOval];
    check([separate.name isEqualToString:@"Lesão 4"]);
    check(objc_getAssociatedObject(named, &HorosContourAwaitingJoinKey) == nil);

    // Unset restores tool names. Empty-name and text-tool behavior is retained.
    [ROI setDefaultName:nil];
    [named nameAndPrepareROI:separate tool:tOval];
    check([separate.name isEqualToString:@"Oval 1"]);
    [named nameAndPrepareROI:separate tool:tCPolygon];
    check([separate.name isEqualToString:@"Polygon 1"]);
    [d setVolatileDomain:@{@"EmptyNameForNewROIs": @YES} forName:NSArgumentDomain];
    separate.name = @"Unnamed";
    [named nameAndPrepareROI:separate tool:tOval];
    check([separate.name isEqualToString:@"Unnamed"]);
    [named nameAndPrepareROI:separate tool:t2DPoint];
    check([separate.name isEqualToString:@"Point 1"]);
    [ROI setDefaultName:@"Lesão"];
    [named nameAndPrepareROI:separate tool:tOval];
    check([separate.name isEqualToString:@"Lesão 4"]);
    [ROI setDefaultName:@""];
    [named nameAndPrepareROI:separate tool:tOval];
    check([separate.name isEqualToString:@""]);
    [ROI setDefaultName:nil];
    [d setVolatileDomain:@{} forName:NSArgumentDomain];
    separate.name = @"Double-Click to edit";
    [named nameAndPrepareROI:separate tool:tText];
    check([separate.name isEqualToString:@"Double-Click to edit"]);

    // Suffix continuation, holes, no double suffix, whitespace and overflow.
    check([[HorosROIName availableNameFrom:@"Lesão" existingNames:@[@"Lesão 1", @"Lesão 3"]] isEqualToString:@"Lesão 2"]);
    check([[HorosROIName availableNameFrom:@"Lesão 7" existingNames:@[]] isEqualToString:@"Lesão 7"]);
    check([[HorosROIName availableNameFrom:@"Lesão 7" existingNames:@[@"Lesão 7"]] isEqualToString:@"Lesão 8"]);
    check([[HorosROIName availableNameFrom:@"Lesão1" existingNames:@[@"Lesão1"]] isEqualToString:@"Lesão2"]);
    check([[HorosROIName availableNameFrom:@"Lesão 009" existingNames:@[@"Lesão 009"]] isEqualToString:@"Lesão 010"]);
    check([[HorosROIName availableNameFrom:@"Lesão 99999999999999999999" existingNames:@[@"Lesão 99999999999999999999"]] isEqualToString:@"Lesão 100000000000000000000"]);
    check([[HorosROIName availableNameFrom:@"  Lesão  " existingNames:@[]] isEqualToString:@"Lesão 1"]);
    check([[HorosROIName availableNameFrom:@"   " existingNames:@[]] isEqualToString:@""]);
    check([[HorosROIName availableNameFrom:@"7" existingNames:@[@"7"]] isEqualToString:@"8"]);

    check([HorosROIObjectJoin isUnnamed:nil] && [HorosROIObjectJoin isUnnamed:@""] && [HorosROIObjectJoin isUnnamed:@"Unnamed"] && ![HorosROIObjectJoin isUnnamed:@"Oval 1"]);
    check([HorosROIObjectJoin.preferenceKey isEqualToString:@"KEY"]);
    NSLog(@"PASS: joins across one or two images, nearest first, in millimetres; touching, Unnamed, other planes, drawing and option off stay apart");
}}
'''.replace('METHODS', methods).replace('CREATION', creation).replace('KEY', KEY)

with tempfile.TemporaryDirectory(prefix='horos-roi-object-join-') as folder:
    p = Path(folder)
    (p / 'test.m').write_text(code)
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(p / 'modules'),
                    str(root / 'Horos/Sources/ROIObjectJoin.swift'), str(root / 'Horos/Sources/ROIName.swift'), '-emit-library', '-module-name', 'Join',
                    '-emit-objc-header-path', str(p / 'Join-Swift.h'), '-o', str(p / 'libJoin.dylib')], check=True)
    subprocess.run(['xcrun', 'clang', '-fno-objc-arc', '-fobjc-arc-exceptions', '-framework', 'Cocoa', '-I', folder,
                    str(p / 'test.m'), '-L', folder, '-lJoin', '-Wl,-rpath,' + folder, '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True)

# A numbered contour of a 2D viewer is remembered when it is created, and
# decided after the mouse up that finishes it.
creation = view[view.index('// A numbered contour may belong to an object'):]
creation = creation[:creation.index('[curRoiList addObject: aNewROI];')]
assert '[ROI defaultName] == nil' not in creation
for condition in ('[HorosROIObjectJoin isUnnamed: aNewROI.name] == NO',
                  '[aNewROI isValidForVolume]', '[self is2DViewer]', 'HorosROIObjectJoin.isEnabled'):
    assert condition in creation, condition
up = view[view.index('[r mouseRoiUp: tempPt scaleValue: (float) scaleValue];'):]
assert up.index('[self joinFinishedContourToAdjacentObject];') < up.index('if(repulsorROIEdition)'), 'not decided on mouse up'
assert up.index('[self deleteInvalidROIs];') < up.index('[self joinFinishedContourToAdjacentObject];')

defaults = (root / 'Horos/Sources/DefaultsOsiriX.m').read_bytes().decode('utf-8')
assert 'setObject:@"0" forKey:@"EmptyNameForNewROIs"' in defaults, 'new ROIs are still unnamed by default'
assert f'setObject:@"1" forKey:@"{KEY}"' in defaults, 'the option is not registered on'

manager = (root / 'Horos/Sources/ROIManagerController.swift').read_text()
rename = manager[manager.index('setObjectValue anObject'):]
rename = rename[:rename.index('\n    }\n')]
assert 'ROIObjectJoin.isUnnamed(editedROI.name)' in rename and 'editedROI.name = anObject as? String' in rename
assert rename.index('editedROI.name = anObject') < rename.index('renameSeriesROIwithName'), 'an Unnamed ROI is renamed with the others'

panes = [root / 'Preference Panes/OSIViewerPreferencePane' / f'{language}.lproj' for language in ('Base', 'ja-JP')]
panes += [root / 'Horos/Resources' / f'{language}.lproj' for language in ('ar', 'de', 'fr', 'hi', 'ko', 'pt-BR', 'ru', 'zh-Hans')]
for pane in panes:
    tree = ET.parse(pane / 'OSIViewerPreferencePanePref.xib')
    assert len(tree.findall(f'.//binding[@keyPath="values.{KEY}"]')) == 1, pane.name
    box = tree.find('.//box[@id="100"]')
    view_frame = box.find('view/rect')
    controls = box.find('view/subviews')
    button = controls.find('button[@id="roi-join-overlap-control"]')
    assert button is not None and button.find('buttonCell').get('title') and button.get('toolTip'), pane.name
    frames = {}
    for control in controls:
        r = control.find('rect')
        x, y, w, h = (float(r.get(k)) for k in ('x', 'y', 'width', 'height'))
        assert y + h <= float(view_frame.get('height')), f'{pane.name}: {control.get("id")} outside its box'
        frames[control.get('id')] = (x, y, w, h)
    mine = frames['roi-join-overlap-control']
    for other, (x, y, w, h) in frames.items():
        if other != 'roi-join-overlap-control':
            assert x >= mine[0] + mine[2] or x + w <= mine[0] or y >= mine[1] + mine[3] or y + h <= mine[1], f'{pane.name}: overlaps {other}'
print(f'PASS: {KEY} registered on and bound in {len(panes)} localizations; numbered names by default; Unnamed renamed alone')
