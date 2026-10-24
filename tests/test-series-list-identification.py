#!/usr/bin/env python3
"""The series identification preference chooses colours, numbers or both.

Compile the actual policy and window allocation, including unknown preferences,
missing/zero DICOM series numbers, stable window identities and badge contrast.
Check the list, title and live preference paths use that policy.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
driver = r'''
import AppKit

func check(_ condition: Bool, _ message: String) {
    if !condition { fatalError(message) }
}
let suite = "series-identification-" + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let key = SeriesListIdentification.defaultsKey
check(SeriesListIdentification.showsColors(in: defaults), "colours by default")
check(!SeriesListIdentification.showsNumbers(in: defaults), "no numeric marks by default")
for (mode, colors, numbers) in [(0, true, false), (1, false, true), (2, true, true), (-1, true, false), (3, true, false)] {
    defaults.set(mode, forKey: key)
    check(SeriesListIdentification.showsColors(in: defaults) == colors, "colour policy \(mode)")
    check(SeriesListIdentification.showsNumbers(in: defaults) == numbers, "number policy \(mode)")
    check(SeriesListIdentification.seriesTitle(name: "Axial", number: nil, defaults: defaults) == "Axial", "missing number")
    let title = SeriesListIdentification.seriesTitle(name: "Axial", number: 42, defaults: defaults)
    check(title == (numbers ? "Series 42 · Axial" : "Axial"), "series title \(mode)")
}
defaults.set(1, forKey: key)
check(SeriesListIdentification.seriesTitle(name: "", number: 0, defaults: defaults) == "Series 0", "zero is a valid series number")
check(SeriesListIdentification.seriesTitle(name: "Axial", number: -2, defaults: defaults) == "Series -2 · Axial", "signed DICOM integer")
MainActor.assumeIsolated {
    let first = NSObject(), second = NSObject(), third = NSObject()
    check(ViewerWindowColors.number(for: first) == 1, "first window")
    check(ViewerWindowColors.number(for: second) == 2, "second window")
    check(ViewerWindowColors.number(for: third) == 3, "third window")
    ViewerWindowColors.release(second)
    check(ViewerWindowColors.number(for: third) == 3, "closing another window does not renumber")
    check(ViewerWindowColors.number(for: NSObject()) == 2, "closed slot reused")
    for number in [1, 2, 3, 12] {
        check(SeriesListIdentification.windowLabel(number: number) == String(number), "bare number for window and badge")
    }
}
func luminance(_ color: NSColor) -> Double {
    let c = color.usingColorSpace(.sRGB)!
    func channel(_ x: CGFloat) -> Double {
        let x = Double(x)
        return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
}
for appearance in [NSAppearance.Name.aqua, .darkAqua] {
    NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
        let background = SeriesListIdentification.badgeBackgroundColor
        let text = SeriesListIdentification.badgeTextColor
        check(background.alphaComponent == 1, "image cannot reduce badge contrast")
        let ratio = (max(luminance(background), luminance(text)) + 0.05) / (min(luminance(background), luminance(text)) + 0.05)
        check(ratio >= 4.5, "badge contrast \(appearance)")
        print("\(appearance.rawValue): badge contrast \(ratio):1")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='horos-series-identification-') as folder:
    work = Path(folder)
    (work / 'main.swift').write_text(driver)
    subprocess.run(['xcrun', 'swiftc',
                    str(root / 'Horos/Sources/SeriesListIdentification.swift'),
                    str(root / 'Horos/Sources/ViewerWindowColors.swift'),
                    str(work / 'main.swift'), '-o', str(work / 'check')], check=True)
    subprocess.run([str(work / 'check')], check=True, timeout=60)

viewer = (root / 'Horos/Sources/ViewerController.m').read_text()
cell = (root / 'Horos/Sources/ThumbnailCell.swift').read_text()
assert 'seriesTitleWithName: name number: curSeries.id' in viewer
assert 'setFrameColor: [HorosSeriesListIdentification showsColorsIn:' in viewer
assert 'setWindowNumber: 0' in viewer, 'reused cells must clear old window markers'
assert viewer.count('HorosSetThumbnailWindowNumber( cell, [seriesWindowNumbers objectForKey: curSeries])') == 2
assert 'windowLabelForNumber: [HorosViewerWindowColors numberForViewer: self]' in viewer
observation = viewer[viewer.index('-(void)observeValueForKeyPath:'):]
observation = observation[:observation.index('\n- (void) autoHideMatrix')]
assert observation.index('HorosSeriesListIdentification.defaultsKey') < observation.index('UseFloatingThumbnailsList')
assert '[self setWindowTitle: self]' in observation and '[self buildMatrixPreview: NO]' in observation
assert 'removeObserver:self forKeyPath:HorosSeriesListIdentification.defaultsKey' in viewer
draw = cell[cell.index('public override func draw(withFrame'):]
assert draw.index('super.draw(withFrame:') < draw.index('guard windowNumber > 0')
assert 'SeriesListIdentification.windowLabel(number: windowNumber)' in draw
assert '@objc public var windowNumber: Int = 0' in cell
print('PASS: series marks, stable window numbers, default behavior, contrast and live refresh')

# Every identification colour must follow Numbers, including already open windows.
colors = viewer[viewer.index('+ (NSMapTable*) horosSeriesWindowColors'):viewer.index('+ (NSMapTable*) horosSeriesWindowNumbers')]
assert '![HorosSeriesListIdentification showsColorsIn: NSUserDefaults.standardUserDefaults]' in colors
for start, end, count in [('- (void) buildSeriesPopup', '- (void) loadSelectedSeries:', 1),
                          ('- (void) buildMatrixPreview: (BOOL) showSelected', '- (void) matrixPreviewSelectCurrentSeries', 2)]:
    section = viewer[viewer.index(start):viewer.index(end, viewer.index(start))]
    assert section.count('if( showsSeriesColors && [viewerSeries containsObject: curSeries])') == count
    assert section.count('if( showsSeriesColors && [[self blendingController] currentSeries] == curSeries)') == count
view = (root / 'Horos/Sources/DCMView.m').read_text()
border = view[view.index('if( [ViewerController numberOf2DViewer] > 1'):view.index('drawWindowBorderSize:')]
assert '[HorosSeriesListIdentification showsColorsIn: NSUserDefaults.standardUserDefaults]' in border
assert 'needsToBuildSeriesPopupMenu = YES' in observation
assert '[view setNeedsDisplay: YES]' in observation
print('PASS: Numbers suppresses window borders, thumbnail fills and popup colours; live redraw')
