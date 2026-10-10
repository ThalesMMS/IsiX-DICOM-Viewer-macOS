#!/usr/bin/env python3
"""After a deletion, the slice's ROI created last is selected.

Deleting the selected ROIs with the Delete key (-[DCMView keyDown:]) or Cut
(-[DCMView cut:]) leaves selected the first ROI of the slice's list that is
neither hidden, locked nor unselectable, so that the next Delete removes it.
The list runs from the front to the back and a new ROI is brought to the
front, so the first is the newest, and the list keeps that order through a
save and a reopening. -[ViewerController bringToFrontROI:], called on every
new ROI, is checked to still insert at the start. Nothing is selected while another ROI is still selected or
being edited, and nothing when ROISelectPreviousAfterDelete is off.

The production -selectSuccessorOfDeletedROIs and HorosROIDeletionSuccessor
run here against a stand-in ROI with the properties they read. The switch is
registered on and bound once in every localization of the Viewer pane.
"""
from pathlib import Path
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
KEY = 'ROISelectPreviousAfterDelete'
view = (root / 'Horos/Sources/DCMView.m').read_bytes().decode('latin1')


def body(signature):
    start = view.index(signature)
    return view[start:view.index('\n}\n', start) + 3]


method = body('- (void)selectSuccessorOfDeletedROIs')

code = r'''
#import <Cocoa/Cocoa.h>
#import "Successor-Swift.h"
enum { ROI_sleep = 0, ROI_selected = 2, ROI_selectedModify = 3 };
static NSString *OsirixROISelectedNotification = @"OsirixROISelectedNotification";
@interface ROI : NSObject
@property BOOL hidden, locked, selectable;
@property(setter=setROIMode:) long ROImode;
@end
@implementation ROI
@end
@interface DCMView : NSObject { @public NSMutableArray *curRoiList; }
@end
@implementation DCMView
METHOD
@end
#define check(...) do { if (!(__VA_ARGS__)) { NSLog(@"FAIL: %s", #__VA_ARGS__); return 1; } } while (0)
static ROI *roi(void) { ROI *r = [ROI new]; r.selectable = YES; return r; }
int main() { @autoreleasepool {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setVolatileDomain:@{@"KEY": @YES} forName:NSArgumentDomain];
    __block ROI *notified = nil;
    [[NSNotificationCenter defaultCenter] addObserverForName:OsirixROISelectedNotification object:nil queue:nil usingBlock:^(NSNotification *n) { notified = n.object; }];

    // Created a, b, c: each new ROI went to the front, so the list is c, b, a.
    ROI *a = roi(), *b = roi(), *c = roi();
    DCMView *v = [DCMView new];
    v->curRoiList = [NSMutableArray arrayWithObjects:c, b, a, nil];
    [v selectSuccessorOfDeletedROIs];
    check(c.ROImode == ROI_selected && notified == c && b.ROImode == ROI_sleep && a.ROImode == ROI_sleep);

    // Delete again: the previous one, down to the first created.
    [v->curRoiList removeObject:c]; notified = nil;
    [v selectSuccessorOfDeletedROIs];
    check(b.ROImode == ROI_selected && notified == b);
    [v->curRoiList removeObject:b];
    [v selectSuccessorOfDeletedROIs];
    check(a.ROImode == ROI_selected && notified == a);
    [v->curRoiList removeObject:a]; notified = nil;
    [v selectSuccessorOfDeletedROIs];
    check(notified == nil);

    // Hidden, locked and unselectable ROIs are skipped.
    ROI *hidden = roi(), *locked = roi(), *fixed = roi(), *open = roi();
    hidden.hidden = YES; locked.locked = YES; fixed.selectable = NO;
    v->curRoiList = [NSMutableArray arrayWithObjects:hidden, locked, fixed, open, nil];
    [v selectSuccessorOfDeletedROIs];
    check(open.ROImode == ROI_selected && locked.ROImode == ROI_sleep && hidden.ROImode == ROI_sleep && fixed.ROImode == ROI_sleep);

    // A ROI still selected or being edited keeps the selection as it is.
    ROI *older = roi(), *edited = roi();
    edited.ROImode = ROI_selectedModify; notified = nil;
    v->curRoiList = [NSMutableArray arrayWithObjects:edited, older, nil];
    [v selectSuccessorOfDeletedROIs];
    check(older.ROImode == ROI_sleep && notified == nil);

    // Switched off, nothing is selected.
    [d setVolatileDomain:@{@"KEY": @NO} forName:NSArgumentDomain];
    ROI *last = roi();
    v->curRoiList = [NSMutableArray arrayWithObjects:last, nil];
    [v selectSuccessorOfDeletedROIs];
    check(last.ROImode == ROI_sleep && notified == nil);
    check([HorosROIDeletionSuccessor.preferenceKey isEqualToString:@"KEY"]);
    NSLog(@"PASS: front of the list first, repeated deletions, hidden/locked/unselectable skipped, selection kept, switch off");
}}
'''.replace('METHOD', method).replace('KEY', KEY)

with tempfile.TemporaryDirectory(prefix='horos-delete-successor-') as folder:
    p = Path(folder)
    (p / 'test.m').write_text(code)
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(p / 'modules'),
                    str(root / 'Horos/Sources/ROIDeletionSuccessor.swift'), '-emit-library', '-module-name', 'Successor',
                    '-emit-objc-header-path', str(p / 'Successor-Swift.h'), '-o', str(p / 'libSuccessor.dylib')], check=True)
    subprocess.run(['xcrun', 'clang', '-fno-objc-arc', '-fobjc-arc-exceptions', '-framework', 'Cocoa', '-I', folder,
                    str(p / 'test.m'), '-L', folder, '-lSuccessor', '-Wl,-rpath,' + folder, '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True)

# Both deletion paths call it once their whole ROIs are gone, and a new ROI
# still goes to the front of its slice.
for signature in ('-(IBAction) cut:(id) sender', '- (void) keyDown:(NSEvent *)event'):
    start = view.index(signature)
    text = view[start:view.index('\n}\n', start)]
    if signature.startswith('- (void) keyDown'):
        text = text[text.index('NSDeleteFunctionKey'):text.index('Return - Enter - Space')]
    assert text.count('removed = YES;') >= 1, f'{signature}: a deletion does not mark the ROI removed'
    assert 'if( removed)\n' in text and '[self selectSuccessorOfDeletedROIs];' in text, f'{signature}: no successor selected'
creation = view[view.index('[curRoiList addObject: aNewROI];'):]
assert creation.index('[[self windowController] bringToFrontROI: aNewROI];') < 1200, 'a new ROI is no longer brought to the front'
editing = (root / 'Horos/Sources/ViewerController+ROI+Editing.swift').read_text()
front = editing[editing.index('func bring(toFrontROI roi: ROI!)'):]
front = front[:front.index('} else {')]
assert 'objcInsert(self.roi2CurrentSlice(), roi, 0)' in front, 'Bring to Front no longer inserts at the start of the list'

defaults = (root / 'Horos/Sources/DefaultsOsiriX.m').read_bytes().decode('latin1')
assert f'setObject:@"1" forKey:@"{KEY}"' in defaults, 'the switch is not registered on'
panes = [root / 'Preference Panes/OSIViewerPreferencePane' / f'{language}.lproj' for language in ('Base', 'ja-JP')]
panes += [root / 'Horos/Resources' / f'{language}.lproj' for language in ('ar', 'de', 'fr', 'hi', 'ko', 'pt-BR', 'ru', 'zh-Hans')]
for pane in panes:
    tree = ET.parse(pane / 'OSIViewerPreferencePanePref.xib')
    assert len(tree.findall(f'.//binding[@keyPath="values.{KEY}"]')) == 1, pane.name
    box = tree.find('.//box[@id="100"]/view')
    button = box.find('.//button[@id="roi-delete-successor-control"]')
    assert button is not None and button.find('buttonCell').get('title'), pane.name
    frame = button.find('rect')
    mine = (float(frame.get('x')), float(frame.get('y')))
    for other in box.iter('button'):
        r = other.find('rect')
        if other is not button and r is not None:
            assert (float(r.get('x')), float(r.get('y'))) != mine, f'{pane.name}: overlaps {other.get("id")}'
print(f'PASS: {KEY} registered on and bound in {len(panes)} localizations; Delete and Cut select the successor')
