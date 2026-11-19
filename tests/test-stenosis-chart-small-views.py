#!/usr/bin/env python3
"""The Stenosis tool's chart draws in a view of any size, down to none.

The chart is as wide as the strip under the stretched view leaves it. Its plot
was the view's bounds inset by fixed margins, which is the null rectangle, of
infinite origin, in a view narrower than 72 points or lower than 36: the
curve's first point then left the path without a current point, the line to
the second raised, and an exception raised while a view draws ends the
application. With the numbers beside the controls, a stretched view narrower
than about 655 points was enough.

StenosisChart.swift is compiled here with the module and drawn, with a
measured stretch, in views of those sizes:

- it draws without raising in views of no size, narrower or lower than the
  margins, and of one point;
- in every view with a size the curve is there: the picture differs from the
  one of a stretch with no lumen;
- sections whose position or area is not a number are left out, alone or
  among the others;
- a click in a view of any size shows a section within the stretch;
- the strip gives the chart, the numbers and the controls the widths
  Stenosis.StripLayout shares out, and no longer what is left of a panel of
  fixed width (the shares themselves are
  IsiXImagingTests.StenosisChartGeometryTests).
"""
import private_tmpdir  # noqa: F401
from pathlib import Path
import subprocess
import sys
import tempfile

import isix_modules
from sources import source_text

ROOT = Path(__file__).resolve().parents[1]

driver = r'''
import AppKit
import IsiXImaging

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: " + message); failures += 1 }
}

@MainActor final class Source: StenosisChartSource {
    var chartContent: StenosisChartContent?
    var shown: [Double] = []
    func showSection(atStretchPosition mm: Double) { shown.append(mm) }
}

@MainActor func measured(valid: Bool = true) -> StenosisChartContent {
    var sections = (0...60).map { i -> StenosisChartContent.Section in
        let position = Double(i) * 0.5
        let area = 28 - 20 * exp(-pow((position - 15) / 4, 2))
        return .init(position: position, area: valid ? area : 0, isValid: valid)
    }
    sections[30].corrected = true
    sections[40] = .init(position: 20, area: 0, isValid: false, lumenTaken: true)
    return StenosisChartContent(sections: sections, stretchLength: 30, references: [0...4, 24...30],
                                minimum: valid ? (15, 8) : nil, current: 12)
}

/// The chart drawn at a size, as the bytes of a bitmap larger than any of them.
@MainActor func picture(of chart: StenosisChart, _ size: NSSize) -> Data {
    chart.frame = NSRect(origin: .zero, size: size)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 480, pixelsHigh: 200, bitsPerSample: 8, samplesPerPixel: 4,
                                  hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    chart.draw(chart.bounds)
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return Data(bytes: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
}

@MainActor func run() {
    let source = Source()
    let chart = StenosisChart(source: source)
    let sizes = [NSSize(width: 400, height: 120), NSSize(width: 0, height: 0), NSSize(width: 60, height: 120),
                 NSSize(width: 400, height: 30), NSSize(width: 71, height: 35), NSSize(width: 30, height: 10),
                 NSSize(width: 1, height: 1), NSSize(width: 0, height: 120), NSSize(width: 400, height: 0)]
    for size in sizes {
        source.chartContent = measured()
        let curve = picture(of: chart, size)
        source.chartContent = measured(valid: false)
        let flat = picture(of: chart, size)
        if size.width >= 30 && size.height >= 10 {
            check(curve != flat, "no curve in a view of \(size.width) x \(size.height)")
        }
        source.chartContent = nil
        _ = picture(of: chart, size)
    }

    // Sections that are no numbers: alone, and among the others.
    let nothing: [StenosisChartContent.Section] = [
        .init(position: .nan, area: 3, isValid: true), .init(position: 2, area: .infinity, isValid: true, corrected: true),
        .init(position: -.infinity, area: .nan, isValid: true, lumenTaken: true),
    ]
    for size in sizes {
        source.chartContent = StenosisChartContent(sections: nothing, stretchLength: 30, references: [-.infinity ... .infinity],
                                                   minimum: (.nan, .infinity), current: .infinity)
        _ = picture(of: chart, size)
        var mixed = measured()
        mixed.sections.insert(contentsOf: nothing, at: 0)
        mixed.sections.insert(contentsOf: nothing, at: 20)
        source.chartContent = mixed
        let curve = picture(of: chart, size)
        source.chartContent = measured(valid: false)
        if size.width >= 30 && size.height >= 10 { check(curve != picture(of: chart, size), "no curve among sections that are no numbers") }
        source.chartContent = StenosisChartContent(sections: measured().sections, stretchLength: .nan)
        _ = picture(of: chart, size)
    }

    // A click shows a section of the stretch, whatever the view's size.
    func click(_ x: CGFloat) {
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: x, y: 5), modifierFlags: [], timestamp: 0,
                                       windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        chart.mouseDown(with: event)
    }
    source.chartContent = measured()
    for size in sizes {
        chart.frame = NSRect(origin: .zero, size: size)
        source.shown = []
        for x in [-50, 0, 10, 208, 5000] as [CGFloat] { click(x) }
        check(source.shown.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 30 }, "a click in a view of \(size.width) x \(size.height) shows \(source.shown)")
        check(size.width <= 0 || size.height <= 0 || source.shown.count == 5, "a click in a view of \(size.width) x \(size.height) is lost")
    }
    chart.frame = NSRect(x: 0, y: 0, width: 400, height: 120)
    source.shown = []
    click(208)
    check(source.shown == [15], "the middle of the plot is not the middle of the stretch: \(source.shown)")
    source.chartContent = nil
    click(208)
    check(source.shown == [15], "a click with no stretch shows a section")
}

MainActor.assumeIsolated { run() }
if failures > 0 { exit(1) }
print("PASS: the chart draws its curve in views down to 30 x 10 points, draws nothing and raises nothing in smaller ones or with sections that are no numbers, and a click shows a section of the stretch")
'''

with tempfile.TemporaryDirectory(prefix='horos-stenosis-chart-') as directory:
    work = Path(directory)
    (work / 'main.swift').write_text(driver)
    flags = isix_modules.module_flags('IsiXImaging', work / 'modules', ['-O'])
    build = subprocess.run(['xcrun', 'swiftc', '-O', '-swift-version', '5', '-module-cache-path', str(work / 'cache'), *flags,
                            str(ROOT / 'Horos/Sources/StenosisChart.swift'), str(work / 'main.swift'), '-o', str(work / 'test')],
                           capture_output=True, text=True, timeout=600)
    if build.returncode:
        print(build.stdout + build.stderr)
        sys.exit(1)
    run = subprocess.run([str(work / 'test')], capture_output=True, text=True, timeout=120)
    print((run.stdout + run.stderr).strip())
    failed = run.returncode != 0
    if run.returncode < 0:
        print(f'FAIL: the drawing ended on signal {-run.returncode}')

chart = source_text('StenosisChart')
tool = source_text('StenosisTool')
checks = [
    ('insetBy' not in chart and 'Stenosis.ChartGeometry(bounds: bounds' in chart, 'the plot comes from the geometry, not from an inset of the bounds'),
    ('final class StenosisChart' not in tool and 'chart = StenosisChart(source: tool)' in tool, 'the strip shows the chart of its tool'),
    ('Stenosis.StripLayout(width: bounds.width, numbers: Self.numbersWidth, controls: controlsWidth)' in tool
     and 'chart.frame = NSRect(x: 0, y: 0, width: widths.chart, height: bounds.height)' in tool
     and 'bounds.width - panelWidth' not in tool, 'the strip shares its width out, the chart first'),
    ('override func resizeSubviews(withOldSize oldSize: NSSize)' in tool, 'the strip shares its width again when it is resized'),
    ('controlsScroll.hasHorizontalScroller = true' in tool, 'controls narrower than they need scroll sideways'),
]
for ok, what in checks:
    if not ok:
        print('FAIL: ' + what)
        failed = True
if failed:
    sys.exit(1)
print('PASS: the strip gives the chart its width before the numbers and the controls')
