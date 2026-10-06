#!/usr/bin/env python3
"""The X-Y plot of a line whose values are all equal draws a flat line.

PlotView scaled each value by the span between the smallest and the largest
value. When every value is the same the span is zero, each height was 0/0, and
NSBezierPath refused the NaN point with an exception raised from -drawRect:,
which stopped the application. The heights now come from PlotView.plotY, which
puts a plot without a span, and a NaN value, at half height.

This compiles the real PlotView.swift, with the chart helpers of
HistoView.swift and doubles of ROI and DCMPix, draws it into a bitmap and reads
back where the black plot line is: flat values, flat values with the mouse
trace shown, a NaN value, and a gradient that must draw as before.

`<git revision>` as an optional argument reads the sources from that revision,
the negative control.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def read(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode()
    return (root / path).read_text()


plot_view = read('Horos/Sources/PlotView.swift')
histo_view = read('Horos/Sources/HistoView.swift')
helpers = re.findall(r'^func (?:roiChartLong|roiChartTextAttributes)\(.*?^\}\n', histo_view, re.M | re.S)
if len(helpers) != 2:
    print('FAIL: the chart helpers of HistoView.swift are not where they were')
    sys.exit(1)

doubles = '''import AppKit

public final class DCMPix: NSObject {
    var fullwl: Float = 40
    var fullww: Float = 400
    var wl: Float = 40
    var ww: Float = 400
}

public final class ROI: NSObject {
    var mousePosMeasure: Float = 0
    var curView: NSView?
    var pix: DCMPix? = DCMPix()
}

''' + '\n'.join(helpers)

main = '''import AppKit

let width = 200, height = 100
let values: [Float]
switch CommandLine.arguments[1] {
case "flat", "flat-mouse": values = Array(repeating: 37, count: 10)
case "nan": values = [1, 2, 3, .nan, 5, 6, 7, 8, 9, 10]
default: values = (0..<10).map { Float($0) }
}
let view = PlotView(frame: NSRect(x: 0, y: 0, width: width, height: height))
let roi = ROI()
view.setCurROI(roi)
let buffer = UnsafeMutablePointer<Float>.allocate(capacity: values.count)
buffer.initialize(from: values, count: values.count)
view.setData(buffer, values.count)
if CommandLine.arguments[1] == "flat-mouse" {
    let event = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 100, y: 50),
                                   modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                   eventNumber: 0, clickCount: 1, pressure: 1)!
    view.mouseDown(with: event)
}
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
view.draw(view.bounds)
NSGraphicsContext.restoreGraphicsState()
// The rows, counted from the bottom as the view does, where a column is black,
// leaving out the frame.
for x in [20, 100, 180] {
    var rows: [String] = []
    for y in 1..<(height - 1) {
        let color = bitmap.colorAt(x: x, y: height - 1 - y)!.usingColorSpace(.deviceRGB)!
        if color.redComponent < 0.3 && color.greenComponent < 0.3 && color.blueComponent < 0.3 {
            rows.append(String(y))
        }
    }
    print("\\(x) " + rows.joined(separator: ","))
}
'''

# Where the black line must cross columns 20, 100 and 180, in rows from the
# bottom. The gradient's are those of the former drawing: values 0 to 9 span
# -0.9 to 9.99, and the columns fall on 0.9, 4.5 and 8.1.
expected = {
    'flat': {20: 50, 100: 50, 180: 50},
    'flat-mouse': {20: 50, 180: 50},
    'nan': {},
    'gradient': {20: 16.5, 100: 49.6, 180: 82.6},
}
descriptions = {
    'flat': 'ten equal values',
    'flat-mouse': 'ten equal values with the mouse trace',
    'nan': 'a NaN value',
    'gradient': 'a gradient',
}

failures = []
with tempfile.TemporaryDirectory(prefix='horos-plot-view-') as directory:
    directory = Path(directory)
    (directory / 'PlotView.swift').write_text(plot_view)
    (directory / 'Doubles.swift').write_text(doubles)
    (directory / 'main.swift').write_text(main)
    binary = directory / 'plot'
    subprocess.run(['xcrun', 'swiftc', '-module-name', 'Horos',
                    str(directory / 'main.swift'), str(directory / 'Doubles.swift'),
                    str(directory / 'PlotView.swift'), '-o', str(binary)],
                   check=True, capture_output=True)
    for case, crossings in expected.items():
        done = subprocess.run([str(binary), case], capture_output=True, text=True)
        if done.returncode:
            reason = next((line for line in done.stderr.split('\n') if 'reason' in line), '')
            failures.append(f'{descriptions[case]}: the drawing stopped with status {done.returncode} {reason.strip()}')
            continue
        columns = {}
        for line in done.stdout.split('\n'):
            if line:
                column, _, rows = line.partition(' ')
                columns[int(column)] = [int(row) for row in rows.split(',') if row]
        for column, row in crossings.items():
            rows = columns.get(column, [])
            if not rows or not any(abs(found - row) <= 2 for found in rows):
                failures.append(f'{descriptions[case]}: column {column} is black at rows {rows}, not near {row}')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
print('PASS: a plot of equal values, with or without the mouse trace, or with a NaN value, '
      'draws a line at half height, and a gradient draws as before')
