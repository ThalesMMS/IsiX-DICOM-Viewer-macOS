#!/usr/bin/env python3
"""Run production subset selection with editable boundary values.

-produceNewArray: is Swift (BrowserController+SubSeriesSheets.swift), with the
range of IsiXImaging's SubSeriesSelection: compiled here as it is.
"""
from pathlib import Path
import subprocess, sys, tempfile
root = Path(__file__).resolve().parents[1]
s = (root / 'Horos/Sources/BrowserController+SubSeriesSheets.swift').read_text()
a = s.index('    @objc(produceNewArray:)')
method = s[a:s.index('    /// Whether the images the sheet keeps fit in memory', a)]
code = r'''
import Foundation
final class DicomSeries: NSObject { func sortDescriptorsForImages() -> [Any]? { [] } }
final class DicomImage: NSObject { var series: Any? }
final class BrowserController: NSObject {
    var horos_subFrom: Int32 = 0, horos_subTo: Int32 = 0, horos_subInterval: Int32 = 0
METHOD
}
func check(_ condition: Bool, _ message: String) { if !condition { print("FAIL: " + message); exit(1) } }
func lists(_ result: [Any]!) -> [[Int]] { (result ?? []).map { ($0 as! [NSNumber]).map(\.intValue) } }
let b = BrowserController()
let input: [Any] = [[0, 1, 2, 3, 4], [5, 6], [Int]()].map { $0.map { NSNumber(value: $0) } as NSArray }
b.horos_subFrom = 1; b.horos_subTo = 5; b.horos_subInterval = 1
check(lists(b.produceNewArray(input)) == [[0, 1, 2, 3, 4], [5, 6]], "normal")
b.horos_subFrom = 2; b.horos_subInterval = 2
check(lists(b.produceNewArray(input)) == [[2, 4]], "sampling")
b.horos_subFrom = 0; b.horos_subInterval = 0
check(lists(b.produceNewArray(input)) == [[0, 1, 2, 3, 4], [5, 6]], "zero bounds")
b.horos_subFrom = Int32.min; b.horos_subInterval = -1; b.horos_subTo = Int32.max
check(lists(b.produceNewArray(input)) == [[0, 1, 2, 3, 4], [5, 6]], "extreme bounds")
b.horos_subFrom = 4; b.horos_subTo = 2; check(b.produceNewArray(input).count == 0, "reversed")
b.horos_subFrom = Int32.max; b.horos_subTo = Int32.max; check(b.produceNewArray(input).count == 0, "past the end")
b.horos_subFrom = 1; b.horos_subTo = -1; check(b.produceNewArray(input).count == 0, "negative end")
check(b.produceNewArray([]).count == 0, "nothing")
print("PASS: normal sampling, unequal series, zero/negative/extreme bounds and reversed ranges")
'''.replace('METHOD', method)
with tempfile.TemporaryDirectory(prefix='horos-subseries-') as d:
    p = Path(d)
    (p / 'main.swift').write_text(code)
    subprocess.run(['xcrun', 'swiftc', '-sanitize=undefined', str(root / 'Modules/IsiXImaging/Sources/ViewerOpening/ViewerOpeningRules.swift'),
                    str(p / 'main.swift'), '-o', str(p / 'test')], check=True, timeout=300)
    subprocess.run([str(p / 'test')], check=True, timeout=60)
