#!/usr/bin/env python3
"""ROI > Show on All Images of the Series makes the selected ROIs one ROI on every image.

Shift is only the lens of the ROI tools, and Shift-click no longer draws a ROI
on every image of the series. The menu command gives that back for ROIs already
drawn, with the mechanism the ROI archive reads and writes: the ROI is flagged
`isAliased`, remembers its image in `originalIndexForAlias`, and the one object
goes in the ROI list of every image of the same series.

Checked here:

* the enablement rule, compiled with the tool-mode table it asks: every type a
  2D tool draws can be shown on all images; a ROI already shown so, a length
  measured between slices, a layer and the 3D types cannot; a selection is all
  or nothing, whatever its order, and an empty one is refused;
* the menu item: in the ROI menu, with Option-Command-L, which no other item of
  the main menu uses, translated from each catalog that has the title, and the
  same in every language's menu;
* the command: it is validated by the rule, takes one undo step before it
  changes anything, and sets the two alias fields the archive keeps;
* the undo snapshot, compiled as it is in ViewerController.m: a ROI shown on
  every image comes back as one copy shared by every image, so undo and redo
  keep it one ROI; and a ROI copy keeps the image the alias was made on.
"""
import private_tmpdir  # noqa: F401
from pathlib import Path
import json
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import source_text  # noqa: E402

root = Path(__file__).resolve().parents[1]
resources = root / 'Horos/Resources'
failures = []

ACTION = 'showSelectedROIsOnAllImagesOfSeries:'
TITLE = 'Show on All Images of the Series'
LANGUAGES = ('ar', 'de', 'es', 'fr', 'hi', 'it-IT', 'ja-JP', 'ko', 'pt-BR', 'ru', 'zh-Hans')


def catalog(language):
    return json.loads(subprocess.check_output(
        ['plutil', '-convert', 'json', '-o', '-', str(resources / f'{language}.lproj/Localizable.strings')]))


def shortcut(item):
    mask = item.find('modifierMask')
    if mask is None:
        mods = {'command'}
    else:
        mods = {name for name in ('control', 'option', 'shift', 'command') if mask.get(name) == 'YES'}
    key = item.get('keyEquivalent') or ''
    if key != key.lower():
        mods.add('shift')
    return key.lower(), frozenset(mods)


def alias_items(language):
    menu = ET.parse(resources / f'{language}.lproj/MainMenu.xib').getroot()
    found = []
    for parent in menu.iter('menu'):
        items = parent.find('items')
        for item in (items if items is not None else []):
            action = item.find('connections/action')
            if item.tag == 'menuItem' and action is not None and action.get('selector') == ACTION:
                found.append((parent, item))
    return menu, found


# --- the menu item -------------------------------------------------------------
english, items = alias_items('en')
if len(items) != 1:
    failures.append(f'English main menu: {len(items)} items run {ACTION}, expected one')
else:
    parent, item = items[0]
    if item.get('title') != TITLE:
        failures.append(f'English title is {item.get("title")!r}')
    if parent.get('title') != 'ROI':
        failures.append(f'the item is in the {parent.get("title")!r} menu, not ROI')
    if shortcut(item) != ('l', frozenset({'option', 'command'})):
        failures.append(f'shortcut is {shortcut(item)}, expected Option-Command-L')
    clashes = [other.get('title') for other in english.iter('menuItem')
               if other is not item and other.get('keyEquivalent') and shortcut(other) == shortcut(item)]
    if clashes:
        failures.append(f'Option-Command-L is also used by {clashes}')
    siblings = [child.find('connections/action').get('selector') for child in parent.find('items')
                if child.find('connections/action') is not None]
    if 'roiPropagateSlab:' not in siblings:
        failures.append('the item left the ROI menu that holds the propagation commands')

for language in LANGUAGES:
    _, localized = alias_items(language)
    if len(localized) != 1:
        failures.append(f'{language}: {len(localized)} items run {ACTION}')
        continue
    item = localized[0][1]
    expected = catalog(language).get(TITLE, TITLE)
    if item.get('title') != expected:
        failures.append(f'{language}: title {item.get("title")!r}, catalog says {expected!r}')
    if shortcut(item) != ('l', frozenset({'option', 'command'})):
        failures.append(f'{language}: shortcut {shortcut(item)}')
    # Japanese keeps the English titles of its neighbours too.
    if language != 'ja-JP' and expected == TITLE:
        failures.append(f'{language}: no translation of {TITLE!r} in its catalog')

# --- the command ---------------------------------------------------------------
viewer = (root / 'Horos/Sources/ViewerController.m').read_bytes().decode('latin1')
validation = viewer[viewer.index(f'@selector({ACTION}))'):]
validation = validation[:validation.index('else if(')]
if 'canShowSelectedROIsOnAllImagesOfSeries' not in validation:
    failures.append('validateMenuItem: does not ask the rule about the command')

action_source = source_text('ViewerController+ROIAlias')
action = action_source[action_source.index('func showSelectedROIsOnAllImagesOfSeries'):]
undo = action.find('self.add(toUndoQueue: "roi")')
if action.count('toUndoQueue') != 1 or undo < 0:
    failures.append('the command must take exactly one ROI undo step')
for change in ('roi.isAliased = true', 'roi.originalIndexForAlias = Int32(current)', 'slice.add(roi)'):
    position = action.find(change)
    if position < 0:
        failures.append(f'the command no longer does `{change}`')
    elif position < undo:
        failures.append(f'`{change}` happens before the undo step is taken')
if 'horosROIsForAllImagesOfSeries()' not in action:
    failures.append('the command does not check the rule before acting')

roi = (root / 'Horos/Sources/ROI.m').read_bytes().decode('latin1')
copy = roi[roi.index('- (id) copyWithZone:(NSZone *)zone'):]
copy = copy[:copy.index('\n}\n')]
if 'c->originalIndexForAlias = originalIndexForAlias;' not in copy:
    failures.append('a ROI copy forgets the image its alias was made on')

# --- the rule ------------------------------------------------------------------
rule_driver = r'''
import Foundation

@main struct Check {
    static func may(_ type: Int, aliased: Bool = false, between: Bool = false) -> Bool {
        ROIMenuEnablement.mayShowROIOnAllImages(type: type, aliased: aliased, betweenSlices: between)
    }
    static func main() {
        // The types the 2D tools draw: what Shift-click could put on every image.
        let drawn = [5, 6, 9, 10, 11, 12, 13, 14, 15, 19, 20, 26, 27, 29]
        for type in drawn {
            precondition(may(type), "type \(type) is drawn by a 2D tool")
            precondition(!may(type, aliased: true), "type \(type) already on every image")
        }
        precondition(!may(5, between: true), "a length between slices belongs to the volume")
        for type in 0..<40 where !drawn.contains(type) {
            precondition(!may(type), "type \(type) is not drawn on an image by a 2D tool")
        }
        let oval = (type: 9, aliased: false, betweenSlices: false)
        let polygon = (type: 11, aliased: false, betweenSlices: false)
        let aliased = (type: 6, aliased: true, betweenSlices: false)
        let volume = (type: 5, aliased: false, betweenSlices: true)
        precondition(!ROIMenuEnablement.mayShowROIsOnAllImages([]), "nothing selected")
        precondition(ROIMenuEnablement.mayShowROIsOnAllImages([oval, polygon]))
        precondition(ROIMenuEnablement.mayShowROIsOnAllImages([polygon, oval]))
        precondition(!ROIMenuEnablement.mayShowROIsOnAllImages([oval, aliased]))
        precondition(!ROIMenuEnablement.mayShowROIsOnAllImages([aliased, oval]))
        precondition(!ROIMenuEnablement.mayShowROIsOnAllImages([volume, oval]))
        precondition(!ROIMenuEnablement.mayShowROIsOnAllImages([oval, volume]))
        print("rule: drawn types only, all or nothing, order-independent")
    }
}
'''

undo_body = viewer[viewer.index('- (id) prepareObjectForUndo:(NSString*) string'):]
undo_body = undo_body[:undo_body.index('\n}\n') + 3]
undo_driver = r'''
#import <Foundation/Foundation.h>
#define check(...) do{if(!(__VA_ARGS__)){NSLog(@"FAIL line %d: %s",__LINE__,#__VA_ARGS__);exit(1);}}while(0)
static void N2LogException(NSException *e) { NSLog(@"%@", e); }
@interface ROI : NSObject <NSCopying>
@property BOOL isAliased;
@property int originalIndexForAlias;
@end
@implementation ROI
- (id)copyWithZone:(NSZone *)zone { ROI *c = [[[self class] alloc] init]; c.isAliased = self.isAliased; c.originalIndexForAlias = self.originalIndexForAlias; return c; }
@end
@interface HorosVolumeLengthROI : ROI
@property (copy) NSString *volumeIdentifier;
@end
@implementation HorosVolumeLengthROI
- (id)copyWithZone:(NSZone *)zone { HorosVolumeLengthROI *c = [super copyWithZone:zone]; c.volumeIdentifier = self.volumeIdentifier; return c; }
@end
@interface Viewer : NSObject { @public NSMutableArray *roiList[2]; int maxMovieIndex; }
- (id) prepareObjectForUndo:(NSString*) string;
@end
@implementation Viewer
BODY
@end
int main(void) {
    @autoreleasepool {
        Viewer *v = [Viewer new];
        v->maxMovieIndex = 1;
        ROI *alias = [ROI new]; alias.isAliased = YES; alias.originalIndexForAlias = 1;
        ROI *a = [ROI new], *b = [ROI new];
        ROI *other = [ROI new]; other.isAliased = YES; other.originalIndexForAlias = 0;
        v->roiList[0] = [@[[@[a, alias, other] mutableCopy], [@[alias, other] mutableCopy], [@[b, other, alias] mutableCopy]] mutableCopy];
        NSArray *slices = [[[v prepareObjectForUndo: @"roi"] objectForKey: @"rois"] objectAtIndex: 0];
        ROI *alias0 = slices[0][1], *alias1 = slices[1][0], *alias2 = slices[2][2];
        check(alias0 != alias && alias0.isAliased && alias0.originalIndexForAlias == 1);
        check(alias0 == alias1 && alias1 == alias2);
        check(slices[0][2] == slices[1][1] && slices[1][1] == slices[2][1] && slices[0][2] != alias0);
        check(slices[0][0] != a && slices[2][0] != b && slices[0][0] != slices[2][0]);
        printf("undo snapshot: one shared copy per ROI shown on every image\n");
    }
    return 0;
}
'''.replace('BODY', undo_body)

with tempfile.TemporaryDirectory(prefix='horos-roi-alias-menu-') as folder:
    directory = Path(folder)
    (directory / 'Check.swift').write_text(rule_driver)
    built = subprocess.run(['xcrun', 'swiftc', '-O',
                            str(root / 'Horos/Sources/ROIMenuEnablement.swift'),
                            str(root / 'Horos/Sources/ToolModeCapability.swift'),
                            str(directory / 'Check.swift'), '-o', str(directory / 'rule')],
                           capture_output=True, text=True)
    if built.returncode != 0:
        failures.append('the rule does not compile:\n' + (built.stderr or built.stdout))
    else:
        run = subprocess.run([str(directory / 'rule')], capture_output=True, text=True)
        sys.stdout.write(run.stdout)
        if run.returncode != 0:
            failures.append('the rule failed its checks:\n' + run.stderr)

    (directory / 'undo.m').write_text(undo_driver)
    built = subprocess.run(['xcrun', 'clang', '-Wno-objc-root-class', '-framework', 'Foundation',
                            str(directory / 'undo.m'), '-o', str(directory / 'undo')],
                           capture_output=True, text=True)
    if built.returncode != 0:
        failures.append('the undo snapshot does not compile:\n' + (built.stderr or built.stdout))
    else:
        run = subprocess.run([str(directory / 'undo')], capture_output=True, text=True)
        sys.stdout.write(run.stdout)
        if run.returncode != 0:
            failures.append('the undo snapshot failed its checks:\n' + run.stderr)

if failures:
    for failure in failures:
        print('FAIL: %s' % failure, file=sys.stderr)
    raise SystemExit(1)
print('PASS: Show on All Images of the Series is in the ROI menu of every language, '
      'with Option-Command-L, one undo step and the archive alias fields')
