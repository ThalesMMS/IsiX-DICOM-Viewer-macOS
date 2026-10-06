#!/usr/bin/env python3
"""The 3D MPR offers the Series Selection item and reopens on the chosen series."""
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sources

root = Path(__file__).resolve().parents[1]
failures = []


def require(condition, message):
    if not condition:
        failures.append(message)


def body(text, signature):
    at = text.find(signature)
    if at < 0:
        return ''
    opening = text.index('{', at)
    depth, index = 0, opening
    while index < len(text):
        if text[index] == '{':
            depth += 1
        elif text[index] == '}':
            depth -= 1
            if depth == 0:
                return text[opening:index + 1]
        index += 1
    return ''


mpr = sources.source_text('MPRController')
viewer = (root / 'Horos/Sources/ViewerController.m').read_bytes().decode('utf-8')
pbx = (root / 'Horos.xcodeproj/project.pbxproj').read_text()

allowed = body(mpr, 'func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar)')
require('MPRController.seriesPopupItemIdentifier' in allowed,
        'the MPR does not allow the Series Selection item')
require('static let seriesPopupItemIdentifier = "SeriesPopup"' in mpr,
        'the MPR item does not share the 2D identifier SeriesPopup')

item = body(mpr, 'func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier')
branch = item[item.find('MPRController.seriesPopupItemIdentifier'):]
require('NSLocalizedString("Series Selection"' in branch and 'makeSeriesPopupView()' in branch,
        'the Series Selection branch does not build the pop-up item as the 2D does')
require(item.rfind('ToolbarPolicy.prepare(toolbarItem)') > item.find('MPRController.seriesPopupItemIdentifier'),
        'the Series Selection item does not go through the toolbar policy')

# A view item with a minimum size and no maximum takes every spare point of a
# wide bar: Axis Colors, Views and Series each did, hundreds of points wide.
require('maximum: .zero' not in item,
        'a 3D MPR toolbar item is left free to grow over the spare room of the bar')

menu = body(mpr, 'fileprivate func rebuildSeriesMenu()')
require('self.acceptsForMPR($0)' in menu and 'imageSeriesContainingPixels(true)' in menu,
        'the menu does not filter the series the MPR can open')
require('#selector(seriesPopupSelect(_:))' in menu, 'series items do not select the series')

select = body(mpr, 'fileprivate dynamic func seriesPopupSelect(_ sender: Any?)')
opened = select.find('source.mprViewer(self)')
found = select.find('FindViewer("MPR", source.pixList(0))')
closed = select.find('self.window?.close()')
require(opened >= 0 and found > opened and closed > found,
        'the MPR must ask the 2D viewer to open the new MPR, find it, and only then close')
require('replacement !== self' in select, 'a refused series must leave the MPR open')
require('loadSeries(series, nil, true, keyImagesOnly: false)' in select,
        'a series without a 2D viewer is not opened in one')

action = body(viewer, '- (IBAction) mprViewer:(id) sender')
require('[sender isKindOfClass: [MPRController class]]' in action,
        '-mprViewer: does not recognise the MPR it replaces')
frame = action.find('[[viewer window] setFrame: [replacedMPRWindow frame] display: NO]')
place = action.find('[self place3DViewerWindow:viewer]')
show = action.find('[viewer showWindow:self]')
require(0 <= frame < show and 0 <= place < show,
        'the replacing MPR must take the frame before it shows, and a normal MPR keeps its placement')
require('reconstructionOpeningDecision' in action and 'diagnosis' in action,
        '-mprViewer: must still run the geometry checks')
require('MPRSeriesSelection.swift in Sources' in pbx, 'MPRSeriesSelection.swift is not in the Horos target')

code = r'''
@main struct Test {
 static func main() {
  typealias S = MPRSeriesSelection.Slice
  func volume(_ n: Int) -> [S] { (0..<n).map { S(width: 512, height: 512, sliceLocation: Double($0) * 1.25) } }

  precondition(MPRSeriesSelection.accepts(volume(120)), "a regular volume is offered")
  precondition(!MPRSeriesSelection.accepts(volume(1)), "a single image of one frame is not")
  precondition(!MPRSeriesSelection.accepts([]), "an empty series is not")

  var mixed = volume(40); mixed[7].width = 256
  precondition(!MPRSeriesSelection.accepts(mixed), "slices of different sizes are not")
  var taller = volume(40); taller[3].height = 400
  precondition(!MPRSeriesSelection.accepts(taller), "slices of different heights are not")

  let samePlace = (0..<30).map { _ in S(width: 256, height: 256, sliceLocation: 12.5) }
  precondition(!MPRSeriesSelection.accepts(samePlace), "a time series at one location is not")

  let unknown = (0..<30).map { _ in S(width: nil, height: nil, sliceLocation: nil) }
  precondition(MPRSeriesSelection.accepts(unknown), "a series the database cannot judge stays offered")
  var partly = samePlace; partly[4].sliceLocation = nil
  precondition(MPRSeriesSelection.accepts(partly), "an unknown location does not refuse the series")
  var partlySized = volume(20); partlySized[2].width = nil
  precondition(MPRSeriesSelection.accepts(partlySized), "an unknown size does not refuse the series")

  print("PASS: the Series Selection menu keeps volumes and leaves out single images, mixed sizes and one-location series")
 }
}
'''

if not failures:
    with tempfile.TemporaryDirectory(prefix='horos-mpr-series-') as folder:
        p = Path(folder)
        (p / 'test.swift').write_text(code)
        built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                                str(root / 'Horos/Sources/MPRSeriesSelection.swift'), str(p / 'test.swift'),
                                '-o', str(p / 'test')])
        require(built.returncode == 0, 'MPRSeriesSelection.swift does not compile on its own')
        if built.returncode == 0:
            require(subprocess.run([str(p / 'test')]).returncode == 0, 'the series rules are wrong')

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('PASS: MPR Series Selection item allowed, filtered, reopened in the same frame')
