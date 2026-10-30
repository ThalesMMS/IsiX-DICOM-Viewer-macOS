#!/usr/bin/env python3
"""Production point deletion and the viewer's removal branch, run together.

The ROI is this checkout's, linked as the application's build compiled it
(tests/roi_harness.py); the viewer's branch is the Delete key's, in
DCMView+Keyboard.swift, compiled into a Swift stand-in of the view that the
probe drives. The branch sends the ROI the messages it sends the application's
ROI, through an Objective-C protocol the ROI class is given at run time. Without
a build the test is skipped.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import roi_harness  # noqa: E402

root = roi_harness.ROOT


def source(name):
    path = 'Horos/Sources/' + name
    return (subprocess.check_output(['git', '-C', str(root), 'show', sys.argv[1] + ':' + path]) if len(sys.argv) > 1
            else (root / path).read_bytes()).decode('latin1')


s = source('DCMView+Keyboard.swift')
a = s.index('                        if r.deleteSelectedPoint() == false && r.locked == false {')
b = s.index('\n                        }\n', a) + len('\n                        }\n')
branch = s[a:b]
tools = source('DCMView+Tools.swift')
post = tools[tools.index('private typealias InputPostIMP'):tools.index('/// An index compared with a count')]

VIEW = r'''
import Foundation
import ObjectiveC

/// What the branch asks the ROI, the application's ROI given this protocol at run time.
@objc protocol CancelROI {
    @objc(ROImode) var roImode: Int { get }
    func deleteSelectedPoint() -> Bool
    var locked: Bool { get }
    var groupID: TimeInterval { get }
}
typealias ROI = CancelROI
let ROI_drawing: Int32 = 1, ROI_selectedModify: Int32 = 3
extension NSNotification.Name { static let OsirixRemoveROI = NSNotification.Name("removeROI") }
POST
@objc(CancelView) final class CancelView: NSObject {
    @objc var horos_curROI: AnyObject?
    @objc var horos_drawingROI = false
    @objc var rArray = NSMutableArray()
    func deleteROIGroupID(_ group: TimeInterval) {}
    // The alias-removal helper is exercised with real slice lists by test-roi-volumetric-length.
    func removeROI(fromSliceOrVolume r: ROI) { rArray.removeObject(identicalTo: r) }
    // Answers whether the whole ROI went, which is what makes the viewer select another.
    @objc(erase:) func erase(_ object: AnyObject) -> Bool {
        if !class_conformsToProtocol(object_getClass(object), CancelROI.self) {
            class_addProtocol(object_getClass(object), CancelROI.self)
        }
        let r = object as! ROI
        var i = rArray.indexOfObjectIdentical(to: r)
        var removed = false
BRANCH
        _ = i
        return removed
    }
}
'''.replace('POST', post).replace('BRANCH', branch)

PROBE = r'''
#define check(...) do{ if( !(__VA_ARGS__)) { fprintf( stderr, "FAIL line %d: %s\n", __LINE__, #__VA_ARGS__); exit( 1); } } while( 0)

// The stand-in view, in Swift (VIEW below).
@interface CancelView : NSObject
@property(retain) ROI *horos_curROI;
@property BOOL horos_drawingROI;
@property(retain) NSMutableArray *rArray;
- (BOOL) erase:(ROI*) r;
@end

/// A ROI being drawn with `count` points, each on its own slice.
static ROI *make( ToolMode type, int count)
{
    ROI *r = [[ROI alloc] initWithType: type : 1 : NSZeroPoint];
    [r setROIMode: ROI_drawing];
    for( int i = 0; i < count; i++)
    {
        [r.points addObject: [MyPoint point: NSMakePoint( i * 10, i * 3)]];
        [r.zPositions addObject: @(10 + i)];
    }
    return r;
}

static NSArray *xs( ROI *r) { NSMutableArray *a = [NSMutableArray array]; for( MyPoint *p in r.points) [a addObject: @(p.x / 10)]; return a; }

int main( int argc, const char **argv) { @autoreleasepool {
    if( argc > 1 && strcmp( argv[ 1], "--probe-link") == 0) return 0;
    for( NSNumber *t in @[@(tCPolygon), @(tOPolygon), @(tPencil)])
    {
        ROI *r = make( (ToolMode) t.intValue, 2);
        CancelView *v = [CancelView new]; v.horos_curROI = r; v.horos_drawingROI = YES; v.rArray = [NSMutableArray arrayWithObject: r];
        check( ![v erase: r]); check( r.points.count == 1 && v.horos_curROI == r && v.horos_drawingROI && v.rArray.count == 1);
        check( [v erase: r]); check( r.points.count == 0 && r.zPositions.count == 0 && v.horos_curROI == nil && !v.horos_drawingROI && v.rArray.count == 0);
        check( ![r deleteSelectedPoint]);
    }
    ROI *r = make( tCPolygon, 4); [r setROIMode: ROI_selectedModify]; [r setValue: @1 forKey: @"selectedModifyPoint"];
    check( [r deleteSelectedPoint]); check( [xs( r) isEqual: @[@0, @2, @3]] && [r.zPositions isEqual: @[@10, @12, @13]]);
    [r setValue: @999 forKey: @"selectedModifyPoint"]; check( [r deleteSelectedPoint]); check( r.points.count == 3);
    ROI *legacy = make( tCPolygon, 2); [legacy.zPositions removeAllObjects]; check( [legacy deleteSelectedPoint]); check( ![legacy deleteSelectedPoint]);
    ROI *lockedROI = make( tCPolygon, 1); lockedROI.locked = YES; check( ![lockedROI deleteSelectedPoint] && lockedROI.points.count == 1);
    ROI *other = make( tCPolygon, 1); CancelView *v = [CancelView new]; v.horos_curROI = make( tCPolygon, 3); v.horos_drawingROI = YES;
    v.rArray = [NSMutableArray arrayWithObjects: other, v.horos_curROI, nil];
    check( [v erase: other]); check( v.horos_curROI != nil && v.horos_drawingROI && v.rArray.count == 1);
    printf( "PASS: empty drawing removal, viewer state, per-vertex slice positions, edit bounds, legacy positions, locked ROI and unrelated drawing\n");
    return 0;
}}
'''

try:
    roi_harness.objc_command()
    roi_harness.objects_dir()
except LookupError as error:
    print(f'skipped: {error}', file=sys.stderr)
    sys.exit(roi_harness.SKIPPED)
with tempfile.TemporaryDirectory(prefix='horos-roi-cancel-') as folder:
    view = Path(folder) / 'view.swift'
    view.write_text(VIEW)
    harness = roi_harness.build(roi_harness.WORKTREE, Path(folder) / 'probe', roi_harness.PRELUDE + PROBE, extra_swift=[view])
    result = subprocess.run([str(harness)], capture_output=True, text=True, timeout=300)
sys.stdout.write(result.stdout)
sys.stderr.write(result.stderr)
sys.exit(result.returncode)
