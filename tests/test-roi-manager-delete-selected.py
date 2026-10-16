#!/usr/bin/env python3
"""Deleting in the ROI Manager removes only the selected rows' ROIs.

New ROIs are all "Unnamed" by default. The Manager used to delete by name,
which removed every ROI of the series sharing the selected one's name, on
every slice. It now hands the selected ROI objects to -[DCMView deleteROIs:],
which removes them as the Delete key removes selected ROIs: one undo step,
locked ROIs kept, a grouped ROI's group removed with it.

The production -deleteROIs: and -deleteROIGroupID: run here against stand-ins
for ROI and for the DCMView state they touch. The Manager's action is checked
to call it and no longer to delete by name.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
view = (root / 'Horos/Sources/DCMView.m').read_bytes().decode('utf-8')


def body(signature):
    start = view.index(signature)
    return view[start:view.index('\n}\n', start) + 3]


methods = body('- (void)deleteROIs:(NSArray*)rois') + body('- (void)deleteROIGroupID:(NSTimeInterval)groupID')

code = r'''
#import <Cocoa/Cocoa.h>
static NSString *OsirixRemoveROINotification = @"OsirixRemoveROINotification";
static NSString *OsirixROIRemovedFromArrayNotification = @"OsirixROIRemovedFromArrayNotification";
#define N2LogExceptionWithStackTrace(e) NSLog(@"%@", e)
static NSRecursiveLock *drawLock = nil;
@interface ROI : NSObject
@property BOOL locked;
@property NSTimeInterval groupID;
@property(copy) NSString *name;
@end
@implementation ROI
@end
@interface Window : NSObject
@property int undoSteps;
@end
@implementation Window
- (void)addToUndoQueue:(NSString*)what { if ([what isEqualToString:@"roi"]) self.undoSteps++; }
@end
@interface DCMView : NSObject { @public NSMutableArray *curRoiList; Window *window; int stops, successors; }
@end
@implementation DCMView
- (Window*)windowController { return window; }
- (void)stopROIEditingForce:(BOOL)force { stops++; }
- (void)removeROIFromSliceOrVolume:(ROI*)roi { [curRoiList removeObjectIdenticalTo:roi]; }
- (void)selectSuccessorOfDeletedROIs { successors++; }
- (void)setNeedsDisplay:(BOOL)flag {}
METHODS
@end
#define check(...) do { if (!(__VA_ARGS__)) { NSLog(@"FAIL: %s", #__VA_ARGS__); return 1; } } while (0)
static ROI *roi(void) { ROI *r = [ROI new]; r.name = @"Unnamed"; return r; }
int main() { @autoreleasepool {
    drawLock = [NSRecursiveLock new];
    NSMutableArray *removed = [NSMutableArray array];
    [[NSNotificationCenter defaultCenter] addObserverForName:OsirixRemoveROINotification object:nil queue:nil usingBlock:^(NSNotification *n) { [removed addObject:n.object]; }];

    // Three unnamed ROIs on this slice and one on another slice.
    ROI *a = roi(), *b = roi(), *c = roi(), *elsewhere = roi();
    NSMutableArray *otherSlice = [NSMutableArray arrayWithObject:elsewhere];
    DCMView *v = [DCMView new];
    v->window = [Window new];
    v->curRoiList = [NSMutableArray arrayWithObjects:a, b, c, nil];

    [v deleteROIs:@[b]];
    check(v->curRoiList.count == 2 && [v->curRoiList indexOfObjectIdenticalTo:b] == NSNotFound);
    check([v->curRoiList indexOfObjectIdenticalTo:a] != NSNotFound && [v->curRoiList indexOfObjectIdenticalTo:c] != NSNotFound);
    check(otherSlice.count == 1 && removed.count == 1 && removed[0] == b);
    check(v->window.undoSteps == 1 && v->stops == 1 && v->successors == 1);

    // Several rows at once, in any order and repeated: each removed once, one undo step.
    [removed removeAllObjects];
    [v deleteROIs:@[c, a, c]];
    check(v->curRoiList.count == 0 && removed.count == 2 && v->window.undoSteps == 2);

    // A locked ROI stays, and nothing to remove records no undo step.
    ROI *locked = roi(); locked.locked = YES;
    v->curRoiList = [NSMutableArray arrayWithObject:locked];
    [removed removeAllObjects];
    [v deleteROIs:@[locked]];
    [v deleteROIs:@[]];
    [v deleteROIs:@[elsewhere]];
    check(v->curRoiList.count == 1 && removed.count == 0 && v->window.undoSteps == 2 && otherSlice.count == 1);

    // A grouped ROI takes its group with it, even when both rows are selected.
    ROI *g1 = roi(), *g2 = roi(), *single = roi();
    g1.groupID = g2.groupID = 42;
    v->curRoiList = [NSMutableArray arrayWithObjects:g1, single, g2, nil];
    [removed removeAllObjects];
    [v deleteROIs:@[g1, g2]];
    check(v->curRoiList.count == 1 && v->curRoiList[0] == single && removed.count == 2 && v->window.undoSteps == 3);
    NSLog(@"PASS: only the given ROIs, same-named ROIs kept, one undo step, locked kept, groups removed together");
}}
'''.replace('METHODS', methods)

with tempfile.TemporaryDirectory(prefix='horos-roi-manager-delete-') as folder:
    p = Path(folder)
    (p / 'test.m').write_text(code)
    subprocess.run(['xcrun', 'clang', '-fno-objc-arc', '-fobjc-arc-exceptions', '-framework', 'Cocoa',
                    str(p / 'test.m'), '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True)

manager = (root / 'Horos/Sources/ROIManagerController.swift').read_text()
action = manager[manager.index('public func deleteROI(_ sender: Any!)'):]
action = action[:action.index('\n    }\n')]
assert 'deleteROIs(selectedROIs)' in action, 'the Manager no longer deletes the selected ROI objects'
assert 'deleteSeriesROIwithName' not in action, 'the Manager deletes by name again'
header = (root / 'Horos/Sources/DCMView.h').read_bytes().decode('latin1')
assert '- (void)deleteROIs:(NSArray*)rois;' in header, 'deleteROIs: is not declared'
print('PASS: the ROI Manager deletes only the selected rows')
