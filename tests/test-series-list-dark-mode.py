#!/usr/bin/env python3
"""The viewer's series list stays legible in the dark appearance.

The cells of a series shown in the viewer (blue), fused with it (green) and of
another study (grey) had fixed light pastel backgrounds, and their titles take
the system's text colour: light text on a light fill in the dark appearance.
HorosSeriesListColors gives each a dark shade there and keeps the pastels in
the light appearance.

A viewer whose study is a previous one of the patient has an orange frame, and
the series it shows had the blue fill of the current study. Their fill is now
an orange made from the colour of a previous study as the blue was from that
of the current one: the same hue, and the share of its saturation and of its
brightness the blue has of its own. The frame of the study is stroked on the
fill in the same hue, so their lightness is measured apart, as for the blue.
An orange frame is itself lighter than a blue one: in the light appearance
even a white fill would leave it at 1.97 where the blue has 2.06, so the pale
orange is held to 1.7 there, and to the blue's 2.0 in the dark appearance. The
presenter takes the fill from the study the frame's rule gives the window.

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
        for (what, color) in [("shown", SeriesListColors.shown), ("shown, previous study", SeriesListColors.shownPrevious),
                              ("fused", SeriesListColors.fused), ("other study", SeriesListColors.otherStudy)] {
            let fill = over(color.usingColorSpace(.sRGB)!, 0.75, window)
            let (a, b) = (luminance(fill), luminance(label))
            let ratio = (max(a, b) + 0.05) / (min(a, b) + 0.05)
            print(String(format: "%@ %@: %.2f", name.rawValue, what, ratio))
            if ratio < 4.5 { failed = true }
        }
        // The series shown is tinted with the blue of the current study, and
        // the frame of that study is stroked on the tint: same hue, so only
        // lightness tells them apart.
        let shown = SeriesListColors.shown.usingColorSpace(.sRGB)!
        if !(shown.blueComponent > shown.greenComponent && shown.greenComponent > shown.redComponent) {
            print("\(name.rawValue) shown is not a blue"); failed = true
        }
        let frame = NSColor(calibratedRed: 0.30, green: 0.60, blue: 1.00, alpha: 1).usingColorSpace(.sRGB)!
        let (a, b) = (luminance(over(shown, 0.75, window)), luminance(frame))
        let apart = (max(a, b) + 0.05) / (min(a, b) + 0.05)
        print(String(format: "%@ shown against the frame of its study: %.2f", name.rawValue, apart))
        if apart < 2.0 { failed = true }

        // The series shown of a previous study: the orange of that study, as
        // a tint, under the orange frame.
        let previous = SeriesListColors.shownPrevious.usingColorSpace(.sRGB)!
        if !(previous.redComponent > previous.greenComponent && previous.greenComponent > previous.blueComponent) {
            print("\(name.rawValue) shown of a previous study is not an orange"); failed = true
        }
        let previousFrame = NSColor(calibratedRed: 1.00, green: 0.58, blue: 0.12, alpha: 1).usingColorSpace(.sRGB)!
        let (c, d) = (luminance(over(previous, 0.75, window)), luminance(previousFrame))
        let previousApart = (max(c, d) + 0.05) / (min(c, d) + 0.05)
        print(String(format: "%@ shown of a previous study against the frame of its study: %.2f", name.rawValue, previousApart))
        // The orange frame is lighter than the blue one: on a light fill it cannot be as far from it.
        if previousApart < (name == .aqua ? 1.7 : 2.0) { failed = true }
        // Made from its study's colour as the blue is from its own: the hue
        // kept, the same share of the saturation and of the brightness.
        func shares(_ tint: NSColor, of study: NSColor) -> (hue: CGFloat, saturation: CGFloat, brightness: CGFloat) {
            var (h, s, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            var (sh, ss, sb): (CGFloat, CGFloat, CGFloat) = (0, 0, 0)
            tint.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            study.getHue(&sh, saturation: &ss, brightness: &sb, alpha: &a)
            return (abs(h - sh) * 360, s / ss, b / sb)
        }
        let (blue, orange) = (shares(shown, of: frame), shares(previous, of: previousFrame))
        print(String(format: "%@ shares of saturation and brightness: blue %.2f %.2f, orange %.2f %.2f", name.rawValue,
                     blue.saturation, blue.brightness, orange.saturation, orange.brightness))
        if orange.hue > 6 || abs(orange.saturation - blue.saturation) > 0.05 || abs(orange.brightness - blue.brightness) > 0.05 {
            print("\(name.rawValue) the orange is not made from its study's colour as the blue is"); failed = true
        }
        if previous == shown { print("\(name.rawValue) a previous study has the fill of the current one"); failed = true }
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
            failures.append('a title is below 4.5:1 on its background, or the series shown is not a blue, or an orange for a previous study, '
                            'the frame stands out on\n' + run.stderr[-800:])

if '- (void) buildMatrixPreview: (BOOL) showSelected' in viewer:
    for gone in ('_fusionedItemColor', '_differentStudyColor'):
        if gone in viewer:
            failures.append('the fixed colour %s is still used' % gone)
    preview = viewer[viewer.index('- (void) buildMatrixPreview: (BOOL) showSelected'):]
    preview = preview[:preview.index('\n- ', 1)]
    fills = [line.strip() for line in preview.splitlines() if 'setBackgroundColor' in line]
    fixed = [line for line in fills if 'HorosSeriesListColors.' not in line and 'setBackgroundColor: nil' not in line and 'setBackgroundColor:nil' not in line]
    least = 8
    popup = viewer[viewer.index('- (void) buildSeriesPopup'):]
    popup = popup[:popup.index('\n- ', 1)]
    menu_colours = 'HorosSeriesListColors.shown forKey: NSBackgroundColorAttributeName' in popup and 'HorosSeriesListColors.fused forKey: NSBackgroundColorAttributeName' in popup
else:
    # The list and the menu are Swift: the list is built by
    # ViewerController+SeriesThumbnails.swift, or by SeriesListPresenter.swift
    # since it moved there; the menu by +SeriesPopup.swift.
    thumbnails = (root / 'Horos/Sources/ViewerController+SeriesThumbnails.swift').read_text()
    presenter_path = root / 'Horos/Sources/SeriesListPresenter.swift'
    presenter = presenter_path.read_text() if presenter_path.is_file() else ''
    menu = (root / 'Horos/Sources/ViewerController+SeriesPopup.swift').read_text()
    for gone in ('_fusionedItemColor', '_differentStudyColor'):
        if gone in viewer + thumbnails + presenter + menu:
            failures.append('the fixed colour %s is still used' % gone)
    if presenter:
        # Every cell takes nil or the colour of a tint of the list's model,
        # and each tint is a colour of SeriesListColors.
        preview = presenter[presenter.index('// MARK: - Building the list'):]
        fills = [line.strip() for line in preview.splitlines() if 'backgroundColor =' in line]
        fixed = [line for line in fills if not line.endswith('backgroundColor = nil') and 'backgroundColor = Self.color(of: ' not in line]
        tints = presenter[presenter.index('private static func color(of tint: SeriesListModel.Tint)'):]
        tints = tints[:tints.index('\n    }\n')]
        for tint, colour in (('none', 'nil'), ('otherStudy', 'SeriesListColors.otherStudy'), ('shown(.current)', 'SeriesListColors.shown'),
                             ('shown(.previous)', 'SeriesListColors.shownPrevious'), ('fused', 'SeriesListColors.fused')):
            if 'case .%s: return %s' % (tint, colour) not in tints:
                fixed.append('the tint %s is not %s' % (tint, colour))
        # The study of the fill is the one the frame's rule gives the window:
        # the list's model is told it, and tints the series shown by it.
        study = presenter[presenter.index('static func windowStudy(of viewer: ViewerController) -> SeriesIdentity.Study {'):]
        study = study[:study.index('\n    }\n')]
        if 'WindowFrameRule.frame(' not in study or 'SeriesListIdentification.study(of: viewer)' not in study:
            fixed.append('the fill of the series shown does not take its study from the rule of the frame')
        if 'countedCells: countedCells, windowStudy: Self.windowStudy(of: viewer))' not in presenter:
            fixed.append("the list's model is not told the study of the window")
        model = (root / 'Modules/IsiXImaging/Sources/ViewerSeriesList/SeriesListModel.swift').read_text()
        if 'if series.isShown { return .shown(windowStudy) }' not in model:
            fixed.append("the list's model does not tint the series shown by the study of the window")
        # The cell resets, the study, its hidden series, the series and its
        # colour, the placeholder.
        least = 6
    else:
        preview = thumbnails[thumbnails.index('func buildMatrixPreview(_ showSelected: Bool)'):thumbnails.index('func matrixPreviewSelectCurrentSeries()')]
        fills = [line.strip() for line in preview.splitlines() if 'backgroundColor =' in line]
        fixed = [line for line in fills if 'SeriesListColors.' not in line and not line.endswith('backgroundColor = nil')]
        least = 8
    if 'private func fill(_ menu: NSMenu?, from model: SeriesMenuModel' in menu:
        # SeriesMenuPresenter fills the menu from the highlights of its model.
        popup = menu[menu.index('private func fill(_ menu: NSMenu?, from model: SeriesMenuModel'):menu.index('private func newItem()')]
    else:
        popup = menu[menu.index('func buildSeriesPopup()'):menu.index('func loadSelectedSeries(')]
    menu_colours = 'attributes[.backgroundColor] = SeriesListColors.shown\n' in popup and 'attributes[.backgroundColor] = SeriesListColors.fused' in popup
    if presenter and 'private func fill(_ menu: NSMenu?, from model: SeriesMenuModel' in menu:
        # The series the viewer shows have in the menu the colour they have
        # in the list: the menu's model is told the study of the window by
        # the list's own rule, and highlights the series shown by it.
        for highlight, colour in (('current', 'shown'), ('previous', 'shownPrevious')):
            if 'case .shown(.%s):\n                    attributes[.backgroundColor] = SeriesListColors.%s\n' % (highlight, colour) not in popup:
                menu_colours = False
        if 'SeriesMenuModel(studies: read.studies, windowStudy: SeriesListPresenter.windowStudy(of: viewer))' not in menu:
            failures.append("the series menu's model is not told the study of the window by the rule of the list")
        menu_model = (root / 'Modules/IsiXImaging/Sources/ViewerSeriesList/SeriesMenuModel.swift').read_text()
        if 'if series.isShown { return .shown(windowStudy) }' not in menu_model:
            failures.append("the series menu's model does not highlight the series shown by the study of the window")
if fixed or len(fills) < least:
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
