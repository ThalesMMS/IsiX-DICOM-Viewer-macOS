#!/usr/bin/env python3
"""The ROI Manager lists, groups, filters, coalesces and exports as intended.

ROIManagerModel.swift and StudyMetadataExport.swift are compiled with a driver
on stand-in ROIs:

- scope: the slice on screen, or every slice;
- grouping: ROIs of one name across slices are one group, in the place their
  first ROI appears, with its count and slice range; "Unnamed" ROIs, and a
  name on a single row, stay rows;
- filters: name text (case and accents ignored), selected, visible, locked;
- the mixed state of a check over several ROIs;
- coalescing: one rebuild for a burst of changes, none while the window is
  hidden, one when it is shown again with changes pending;
- CSV: the header, a record per ROI with the slice counted from 1, a name
  with a comma and quotes escaped, CRLF records and the byte order mark.

The controller is checked to use the coalescer for every notification and to
build the file from those records.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sources = [root / 'Horos/Sources/ROIManagerModel.swift', root / 'Horos/Sources/StudyMetadataExport.swift']

DRIVER = r'''
import Foundation

final class FakeROI {
    let name: String
    var hidden = false, locked = false, selected = false
    init(_ name: String) { self.name = name }
}
let reader = ROIManagerReader(name: { ($0 as! FakeROI).name }, hidden: { ($0 as! FakeROI).hidden },
                              locked: { ($0 as! FakeROI).locked }, selected: { ($0 as! FakeROI).selected },
                              unnamed: { $0 == "Unnamed" || $0.isEmpty })
var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) { if !ok { print("FAIL line \(line): \(what)"); failures += 1 } }
func describe(_ items: [AnyObject]) -> String {
    items.map { item -> String in
        if let g = item as? ROIManagerGroup { return "\(g.name)[\(g.rows.count):\(g.firstSlice)-\(g.lastSlice)/\(g.sliceCount)]" }
        let r = item as! ROIManagerRow
        return "\((r.roi as! FakeROI).name)@\(r.slice)"
    }.joined(separator: " ")
}

// Slices: 0 liver, Unnamed; 1 liver, kidney, Unnamed; 2 liver; 3 spleen, Lésion.
let liver = (0..<3).map { _ in FakeROI("liver") }
let unnamed = [FakeROI("Unnamed"), FakeROI("Unnamed")]
let kidney = FakeROI("kidney"), spleen = FakeROI("spleen"), lesion = FakeROI("Lésion")
let slices: [[AnyObject]] = [[liver[0], unnamed[0]], [liver[1], kidney, unnamed[1]], [liver[2]], [spleen, lesion]]
func items(_ scope: ROIManagerScope, _ current: Int = 1, _ filter: ROIManagerFilter = ROIManagerFilter(), group: Bool = true) -> String {
    describe(ROIManagerModel.items(slices: slices, currentSlice: current, scope: scope, filter: filter, groupByName: group, reader: reader))
}

check(items(.series) == "liver[3:0-2/3] Unnamed@0 kidney@1 Unnamed@1 spleen@3 Lésion@3", items(.series))
check(items(.slice) == "liver@1 kidney@1 Unnamed@1", items(.slice))
check(items(.slice, 9) == "", "a slice out of range lists nothing")
check(items(.series, group: false) == "liver@0 Unnamed@0 liver@1 kidney@1 Unnamed@1 liver@2 spleen@3 Lésion@3", items(.series, group: false))

var f = ROIManagerFilter()
f.text = " LESION "
check(items(.series, 0, f) == "Lésion@3", "text ignores case, accents and spaces: " + items(.series, 0, f))
f = ROIManagerFilter(); f.text = "liv"
check(items(.series, 0, f) == "liver[3:0-2/3]", items(.series, 0, f))
liver[1].hidden = true; kidney.locked = true; spleen.selected = true
f = ROIManagerFilter(); f.visibleOnly = true
check(items(.series, 0, f) == "liver[2:0-2/2] Unnamed@0 kidney@1 Unnamed@1 spleen@3 Lésion@3", items(.series, 0, f))
f = ROIManagerFilter(); f.lockedOnly = true
check(items(.series, 0, f) == "kidney@1", items(.series, 0, f))
f = ROIManagerFilter(); f.selectedOnly = true
check(items(.series, 0, f) == "spleen@3", items(.series, 0, f))

let all = ROIManagerModel.items(slices: slices, currentSlice: 0, scope: .series, filter: ROIManagerFilter(), groupByName: true, reader: reader)
check(ROIManagerModel.rows(of: all).count == 8, "rows open the groups")
check(ROIManagerModel.state(of: [true, true]) == 1 && ROIManagerModel.state(of: [false]) == 0
      && ROIManagerModel.state(of: [true, false]) == -1 && ROIManagerModel.state(of: []) == 0, "check states")

// Coalescing: 4000 changes while shown schedule one rebuild; hidden, none.
let c = ROIManagerCoalescer()
var scheduled = 0
for _ in 0..<4000 { if c.changed(visible: true) { scheduled += 1 } }
check(scheduled == 1 && c.pending && c.dirty, "one rebuild for a burst: \(scheduled)")
c.fired(); c.rebuilt()
check(!c.pending && !c.dirty, "rebuilt")
for _ in 0..<100 { if c.changed(visible: false) { scheduled += 1 } }
check(scheduled == 1 && c.dirty && !c.pending, "none while hidden")
check(c.changed(visible: true), "shown again with changes pending")

// CSV.
var s = ROIManagerStatistics()
s.mean = 52.25; s.deviation = 3.5; s.minimum = -10; s.maximum = 120; s.total = 4180
let record = ROIManagerModel.csvRecord(name: "liver, \"left\"", slice: 0, areaCm2: 12.345678, statistics: s,
                                       hidden: false, locked: true, comments: "")
check(record == ["liver, \"left\"", "1", "12.3457", "52.250", "3.500", "-10.000", "120.000", "4180.000", "yes", "yes", ""], record.description)
let text = StudyMetadataExport.csv(fromRows: [ROIManagerModel.csvHeader, record])
check(text == "Name,Slice,Area (cm²),Mean,SDev,Min,Max,Sum,Visible,Locked,Comments\r\n\"liver, \"\"left\"\"\",1,12.3457,52.250,3.500,-10.000,120.000,4180.000,yes,yes,\r\n", text)
check(StudyMetadataExport.data(forCSV: text).prefix(3) == Data([0xEF, 0xBB, 0xBF]), "byte order mark")

if failures > 0 { exit(1) }
print("PASS: model")
'''

with tempfile.TemporaryDirectory(prefix='horos-roi-manager-model-') as folder:
    p = Path(folder)
    (p / 'main.swift').write_text(DRIVER)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', *map(str, sources), str(p / 'main.swift'),
                    '-o', str(p / 'model')], check=True)
    result = subprocess.run([str(p / 'model')], capture_output=True, text=True)
    sys.stdout.write(result.stdout)
    if result.returncode != 0:
        sys.exit('FAIL: the model driver failed')

controller = (root / 'Horos/Sources/ROIManagerController.swift').read_text()


def method(signature):
    start = controller.index(signature)
    return controller[start:controller.index('\n    }\n', start)]


schedule = method('private func scheduleRebuild()')
assert 'coalescer.changed(visible: window?.isVisible == true)' in schedule and 'coalescer.fired()' in schedule
for name in ('roiListModification', 'fireUpdate', 'currentImageChanged', 'roiSelected'):
    body = method(f'func {name}(_ note: NSNotification!)')
    assert 'scheduleRebuild()' in body and 'rebuild()' not in body.replace('scheduleRebuild()', ''), name
assert 'coalescer.rebuilt()' in method('private func rebuild()')
csv = method('func writeCSV(to url: URL) throws')
assert 'ROIManagerModel.csvHeader' in csv and 'ROIManagerModel.csvRecord(' in csv and 'StudyMetadataExport.data(forCSV:' in csv
print('PASS: the controller coalesces every notification and exports the model records')
