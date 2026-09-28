#!/usr/bin/env python3
"""Exercise ROI Info's production color load/action with real AppKit conversion.

ROIWindow is Swift since #714: the load (in -setROI::) and the -setColor:
action are taken from ROIWindow.swift, with the conversion to 16-bit
channels from HistoView.swift, and compiled into a Swift program with a stub
ROI.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sources

root = sources.ROOT
path = sources.source_path('ROIWindow').relative_to(root).as_posix()
helpers_path = sources.source_path('HistoView').relative_to(root).as_posix()


def read(relative):
    return (subprocess.check_output(['git', '-C', str(root), 'show', sys.argv[1] + ':' + relative])
            if len(sys.argv) > 1 else (root / relative).read_bytes()).decode('utf-8')


source = read(path)
a = source.index('        let rgb = roi?.rgbcolor ?? RGBColor()')
b = source.index('thicknessSlider?.floatValue =', a)
load = source[a:b]
a = source.index('    @IBAction @objc(setColor:)')
b = source.index('    @objc(addROIValues:dictionary:)', a)
action = source[a:b]
helpers = read(helpers_path)
a = helpers.index('func roiChartUInt16(')
b = helpers.index('\n}\n', a) + 3
conversion = helpers[a:b]
code = r'''
import Cocoa
extension NSNotification.Name { static let OsirixROIChange = NSNotification.Name("QA ROI changed") }
final class ROI: NSObject {
    var rgbcolor = RGBColor()
    var name: String! = ""
}
CONVERSION
final class Peer: NSObject {
    var roi: ROI?
    var colorButton: NSColorWell!
    var comments: NSTextView!
    func loadColor() {
LOAD    }
    func allWithSameName() -> Bool { return false }
    func setAllMatchingROIsToSameParams(as iROI: ROI!, withNewName newName: String!) { abort() }
ACTION}
func fail(_ message: String) -> Never { NSLog("FAIL: %@", message); exit(1) }
_ = NSApplication.shared
let p = Peer(); p.roi = ROI(); p.colorButton = NSColorWell()
var notifications = 0
let token = NotificationCenter.default.addObserver(forName: .OsirixROIChange, object: p.roi, queue: nil) { _ in notifications += 1 }
let cases: [(UInt16, UInt16, UInt16)] = [(32768,32768,32768),(12345,45678,23456),(65535,0,0),(0,65535,0),(0,0,65535),(65535,65535,0),(0,0,0),(65535,65535,65535)]
for (r, g, b) in cases {
    var expected = RGBColor(); expected.red = r; expected.green = g; expected.blue = b
    p.roi!.rgbcolor = expected
    for j in 0..<20 {
        p.loadColor(); p.setColor(p.colorButton)
        let got = p.roi!.rgbcolor
        if abs(Int(got.red) - Int(expected.red)) > 1 || abs(Int(got.green) - Int(expected.green)) > 1 || abs(Int(got.blue) - Int(expected.blue)) > 1 {
            fail("roundtrip \(j): RGB \(expected.red),\(expected.green),\(expected.blue) became \(got.red),\(got.green),\(got.blue)")
        }
    }
}
if notifications != 160 { fail("notifications == 160 (got \(notifications))") }
NotificationCenter.default.removeObserver(token)
NSLog("PASS: 8 colors retain 16-bit channels through 20 ROI Info load/apply cycles; change notifications delivered")
'''.replace('CONVERSION', conversion).replace('LOAD', load).replace('ACTION', action)
with tempfile.TemporaryDirectory(prefix='horos-roi-color-') as d:
    p = Path(d)
    (p / 'test.swift').write_text(code)
    subprocess.run(['xcrun', 'swiftc', '-Onone', '-framework', 'Cocoa', str(p / 'test.swift'),
                    '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True)
