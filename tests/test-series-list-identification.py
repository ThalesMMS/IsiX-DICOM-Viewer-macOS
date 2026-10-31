#!/usr/bin/env python3
"""The series identification preference chooses colours, numbers or both.

Compile the actual policy and identity allocation, including unknown preferences,
stable series identities and badge contrast.
Check the list, title and live preference paths use that policy.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
driver = r'''
import AppKit

// Only the host boundary is doubled; the allocation below is production code.
final class ViewerController: NSObject {
    var series: NSObject?
    func currentSeries() -> NSObject? { series }
}

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
}
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

viewer = (((root / 'Horos/Sources/ViewerController.m').read_text()) if (root / 'Horos/Sources/ViewerController.m').exists() else '')
cell = (root / 'Horos/Sources/ThumbnailCell.swift').read_text()
# The series list and menu are Objective-C of ViewerController.m, or Swift
# (ViewerController+SeriesPopup.swift, +SeriesThumbnails, +SeriesListDock).
objc_list = '- (void) buildMatrixPreview: (BOOL) showSelected' in viewer
if objc_list:
    assert 'seriesTitleWithName:' not in viewer, 'identification mode must not prepend DICOM SeriesNumber to thumbnail names'
    assert 'setFrameColor: [HorosSeriesListIdentification showsColorsIn:' in viewer
    assert 'setWindowNumber: 0' in viewer, 'reused cells must clear old window markers'
    assert viewer.count('HorosSetThumbnailWindowNumber( cell, [seriesWindowNumbers objectForKey: curSeries])') == 2
else:
    popup = (root / 'Horos/Sources/ViewerController+SeriesPopup.swift').read_text()
    thumbnails = (root / 'Horos/Sources/ViewerController+SeriesThumbnails.swift').read_text()
    dock = (root / 'Horos/Sources/ViewerController+SeriesListDock.swift').read_text()
    # The list and its dock moved to SeriesListPresenter.swift, which fills the
    # cells from SeriesListModel (IsiXImaging).
    presenter_path = root / 'Horos/Sources/SeriesListPresenter.swift'
    presenter = presenter_path.read_text() if presenter_path.is_file() else None
    assert 'seriesTitleWithName' not in popup + thumbnails + (presenter or ''), 'identification mode must not prepend DICOM SeriesNumber to thumbnail names'
    if presenter is None:
        assert 'cell.frameColor = SeriesListIdentification.showsColors(in: UserDefaults.standard) ? color : nil' in thumbnails
        assert 'cell.windowNumber = 0' in thumbnails, 'reused cells must clear old window markers'
        assert thumbnails.count('setThumbnailWindowNumber(cell, seriesWindowNumbers?.object(forKey: curSeries) as? NSNumber)') == 2
    else:
        assert 'cell.frameColor = SeriesListIdentification.showsColors(in: preferences) ? color : nil' in presenter
        assert 'cell.windowNumber = 0' in presenter, 'reused cells must clear old window markers'
        # A series cell, and a study cell framed by its first hidden series in a window.
        assert 'setWindowNumber(cell, build.windowNumbers?.object(forKey: curSeries) as? NSNumber)' in presenter
        assert 'setWindowNumber(cell, build.windowNumbers?.object(forKey: series[framing]) as? NSNumber)' in presenter
        dock = presenter
# The window title is the viewer's graph's (ViewerSessionGraph+WindowLife.swift)
# and the window colours of the series are ViewerController+ViewerRegistry.swift's.
lifecycle = (root / 'Horos/Sources/ViewerSessionGraph+WindowLife.swift').read_text()
registry = (root / 'Horos/Sources/ViewerController+ViewerRegistry.swift').read_text()
assert 'SeriesListIdentification.windowLabel(number: ViewerWindowColors.number(for: viewer))' in lifecycle
if objc_list:
    observation = viewer[viewer.index('-(void)observeValueForKeyPath:'):]
    observation = observation[:observation.index('\n- (void) autoHideMatrix')]
    assert observation.index('HorosSeriesListIdentification.defaultsKey') < observation.index('UseFloatingThumbnailsList')
    assert '[self setWindowTitle: self]' in observation and '[self buildMatrixPreview: NO]' in observation
elif presenter is None:
    observation = dock[dock.index('override func observeValue(forKeyPath'):dock.index('@objc(autoHideMatrix)')]
    assert observation.index('SeriesListIdentification.defaultsKey') < observation.index('UseFloatingThumbnailsList')
    assert 'viewer.setWindowTitle(viewer)' in observation and 'viewer.buildMatrixPreview(false)' in observation
else:
    observation = presenter[presenter.index('func preferenceChanged('):presenter.index('func autoHide()')]
    assert observation.index('SeriesListIdentification.defaultsKey') < observation.index('if isFloating')
    assert 'viewer.setWindowTitle(viewer)' in observation and 'viewer.buildMatrixPreview(false)' in observation
# Removed in -dealloc, or in the graph's tearDown (ViewerSessionGraph+ViewerLife.swift) since the class is Swift.
viewer_lifecycle = root / 'Horos/Sources/ViewerSessionGraph+ViewerLife.swift'
assert 'removeObserver:self forKeyPath:HorosSeriesListIdentification.defaultsKey' in viewer or (
    viewer_lifecycle.exists() and 'removeObserver(viewer, forKeyPath: SeriesListIdentification.defaultsKey)' in viewer_lifecycle.read_text())
draw = cell[cell.index('public override func draw(withFrame'):]
assert draw.index('super.draw(withFrame:') < draw.index('guard windowNumber > 0')
assert 'SeriesListIdentification.windowLabel(number: windowNumber)' in draw
assert '@objc public var windowNumber: Int = 0' in cell
print('PASS: series marks, stable window numbers, default behavior, contrast and live refresh')

# Every identification colour must follow Numbers, including already open windows.
colors = registry[registry.index('    class func horosSeriesWindowColors()'):registry.index('    class func horosSeriesWindowNumbers()')]
assert '!SeriesListIdentification.showsColors(in: processGraph.preferences)' in colors
if objc_list:
    for start, end, count in [('- (void) buildSeriesPopup', '- (void) loadSelectedSeries:', 1),
                              ('- (void) buildMatrixPreview: (BOOL) showSelected', '- (void) matrixPreviewSelectCurrentSeries', 2)]:
        section = viewer[viewer.index(start):viewer.index(end, viewer.index(start))]
        assert section.count('if( showsSeriesColors && [viewerSeries containsObject: curSeries])') == count
        assert section.count('if( showsSeriesColors && [[self blendingController] currentSeries] == curSeries)') == count
else:
    # The menu is built by SeriesMenuPresenter (in the same file) from a
    # SeriesMenuModel (IsiXImaging) since the menu moved there.
    menu_model_path = root / 'Modules/IsiXImaging/Sources/ViewerSeriesList/SeriesMenuModel.swift'
    menu_model = menu_model_path.read_text() if 'SeriesMenuModel(' in popup and menu_model_path.is_file() else None
    sections = [] if menu_model else [(popup, 'func buildSeriesPopup()', 'func loadSelectedSeries(', 1)]
    if menu_model:
        # The menu's model highlights a series shown, else fused, only when the
        # menu colours them; the presenter reads both from the viewer.
        highlight = menu_model[menu_model.index('public func highlight(of series: Series)'):]
        assert highlight.index('if showsSeriesColors && series.isShown { return .shown }') < highlight.index('if showsSeriesColors && series.isFused { return .fused }')
        assert 'let isShown = viewerSeries.contains(series)' in popup
        assert 'isFused: showsSeriesColors && !isShown && self.viewer.blending()?.currentSeries() === series' in popup
        assert 'showsSeriesColors = SeriesListIdentification.showsColors(in: preferences)' in popup
    if presenter is None:
        sections.append((thumbnails, 'func buildMatrixPreview(_ showSelected: Bool)', 'func matrixPreviewSelectCurrentSeries()', 2))
    for text, start, end, count in sections:
        section = text[text.index(start):text.index(end, text.index(start))]
        assert section.count('if showsSeriesColors && viewerSeries.contains(curSeries) {') == count
        assert section.count('if showsSeriesColors && blending()?.currentSeries() === curSeries {') == count
    if presenter is not None:
        # The list's model tints the series shown, else fused, only when the
        # list colours them; the presenter reads both from the viewer.
        assert 'isShown: viewerSeries.contains(each), isFused: fused === each' in presenter
        assert 'let fused = viewer.blending()?.currentSeries()' in presenter
        model = (root / 'Modules/IsiXImaging/Sources/ViewerSeriesList/SeriesListModel.swift').read_text()
        tint = model[model.index('private func seriesTint('):]
        assert 'guard showsSeriesColors else { return nil }' in tint
        assert tint.index('if series.isShown { return .shown }') < tint.index('if series.isFused { return .fused }')
        assert 'let showsSeriesColors = SeriesListIdentification.showsColors(in: preferences)' in presenter
# The frame is drawn by DCMView+Drawing.swift.
drawing = (root / 'Horos/Sources/DCMView+Drawing.swift').read_text()
border = drawing[drawing.index('if ViewerController.numberOf2DViewer() > 1'):drawing.index('PlanarFrameGraphics.drawWindowBorder(size:')]
assert 'SeriesListIdentification.showsColors(in: UserDefaults.standard)' in border
if objc_list:
    assert 'needsToBuildSeriesPopupMenu = YES' in observation
    assert '[view setNeedsDisplay: YES]' in observation
else:
    assert 'horos_needsToBuildSeriesPopupMenu = true' in observation
    assert 'view.needsDisplay = true' in observation
print('PASS: Numbers suppresses window borders, thumbnail fills and popup colours; live redraw')
