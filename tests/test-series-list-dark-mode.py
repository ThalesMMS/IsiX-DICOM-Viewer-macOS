#!/usr/bin/env python3
"""The viewer's series list stays legible in the dark appearance.

The cells of a series shown in the viewer (red), fused with it (green) and of
another study (grey) had fixed light pastel backgrounds, and their titles take
the system's text colour: light text on a light fill in the dark appearance.
HorosSeriesListColors gives each a dark shade there and keeps the pastels in
the light appearance.

The colours are compiled from the source and resolved in both appearances. The
cell paints them at 75% over the window's background, and the title must keep a
contrast of at least 4.5:1 against that blend. The wiring in the viewer and the
cell that resolves the dynamic colour before reading its components are checked
in the sources.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
failures = []
colors = (root / 'Horos/Sources/SeriesListColors.swift').read_text()
viewer = (((root / 'Horos/Sources/ViewerController.m').read_bytes()) if (root / 'Horos/Sources/ViewerController.m').exists() else b'').decode('latin1')
cell = (root / 'Horos/Sources/ThumbnailCell.swift').read_text()

DRIVER = r'''
import AppKit
func luminance(_ c: NSColor) -> Double {
    func channel(_ v: CGFloat) -> Double { let v = Double(v); return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
}
func over(_ top: NSColor, _ alpha: CGFloat, _ bottom: NSColor) -> NSColor {
    NSColor(srgbRed: top.redComponent * alpha + bottom.redComponent * (1 - alpha),
            green: top.greenComponent * alpha + bottom.greenComponent * (1 - alpha),
            blue: top.blueComponent * alpha + bottom.blueComponent * (1 - alpha), alpha: 1)
}
var failed = false
for name in [NSAppearance.Name.aqua, .darkAqua] {
    let appearance = NSAppearance(named: name)!
    appearance.performAsCurrentDrawingAppearance {
        let window = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)!
        let label = over(NSColor.labelColor.usingColorSpace(.sRGB)!, NSColor.labelColor.usingColorSpace(.sRGB)!.alphaComponent, window)
        for (what, color) in [("shown", SeriesListColors.shown), ("fused", SeriesListColors.fused), ("other study", SeriesListColors.otherStudy)] {
            let fill = over(color.usingColorSpace(.sRGB)!, 0.75, window)
            let (a, b) = (luminance(fill), luminance(label))
            let ratio = (max(a, b) + 0.05) / (min(a, b) + 0.05)
            print(String(format: "%@ %@: %.2f", name.rawValue, what, ratio))
            if ratio < 4.5 { failed = true }
        }
    }
}
let dark = SeriesListColors.shown.usingColorSpace(.sRGB)!
NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
    if SeriesListColors.shown.usingColorSpace(.sRGB)! == dark { print("the light appearance has no pastel of its own"); failed = true }
}
exit(failed ? 1 : 0)
'''

with tempfile.TemporaryDirectory(prefix='horos-series-colors-') as directory:
    work = Path(directory)
    (work / 'SeriesListColors.swift').write_text(colors)
    (work / 'main.swift').write_text(DRIVER)
    built = subprocess.run(['xcrun', 'swiftc', str(work / 'SeriesListColors.swift'), str(work / 'main.swift'), '-o', str(work / 'contrast')],
                           capture_output=True, text=True)
    if built.returncode:
        failures.append('the colours do not compile:\n' + built.stderr[-1500:])
    else:
        run = subprocess.run([str(work / 'contrast')], capture_output=True, text=True, timeout=60)
        print(run.stdout.strip())
        if run.returncode:
            failures.append('a title is below 4.5:1 on its background\n' + run.stderr[-800:])

if '- (void) buildMatrixPreview: (BOOL) showSelected' in viewer:
    for gone in ('_fusionedItemColor', '_differentStudyColor'):
        if gone in viewer:
            failures.append('the fixed colour %s is still used' % gone)
    preview = viewer[viewer.index('- (void) buildMatrixPreview: (BOOL) showSelected'):]
    preview = preview[:preview.index('\n- ', 1)]
    fills = [line.strip() for line in preview.splitlines() if 'setBackgroundColor' in line]
    fixed = [line for line in fills if 'HorosSeriesListColors.' not in line and 'setBackgroundColor: nil' not in line and 'setBackgroundColor:nil' not in line]
    popup = viewer[viewer.index('- (void) buildSeriesPopup'):]
    popup = popup[:popup.index('\n- ', 1)]
    menu_colours = 'HorosSeriesListColors.shown forKey: NSBackgroundColorAttributeName' in popup and 'HorosSeriesListColors.fused forKey: NSBackgroundColorAttributeName' in popup
else:
    # The list and the menu are Swift (ViewerController+SeriesThumbnails.swift,
    # +SeriesPopup.swift).
    thumbnails = (root / 'Horos/Sources/ViewerController+SeriesThumbnails.swift').read_text()
    menu = (root / 'Horos/Sources/ViewerController+SeriesPopup.swift').read_text()
    for gone in ('_fusionedItemColor', '_differentStudyColor'):
        if gone in viewer + thumbnails + menu:
            failures.append('the fixed colour %s is still used' % gone)
    preview = thumbnails[thumbnails.index('func buildMatrixPreview(_ showSelected: Bool)'):thumbnails.index('func matrixPreviewSelectCurrentSeries()')]
    fills = [line.strip() for line in preview.splitlines() if 'backgroundColor =' in line]
    fixed = [line for line in fills if 'SeriesListColors.' not in line and not line.endswith('backgroundColor = nil')]
    popup = menu[menu.index('func buildSeriesPopup()'):menu.index('func loadSelectedSeries(')]
    menu_colours = 'attributes[.backgroundColor] = SeriesListColors.shown' in popup and 'attributes[.backgroundColor] = SeriesListColors.fused' in popup
if fixed or len(fills) < 8:
    failures.append('the series list cells do not all take the appearance\'s colours: %r' % fixed)
if not menu_colours:
    failures.append('the series menu does not take the appearance\'s colours')
if 'backgroundColor.usingColorSpace(.genericRGB)' not in cell:
    failures.append('the thumbnail cell reads the components of an unresolved dynamic colour')

if failures:
    print('FAIL')
    for failure in failures:
        print(' -', failure)
    sys.exit(1)
print('PASS: the series list keeps its titles legible in the light and dark appearances')
