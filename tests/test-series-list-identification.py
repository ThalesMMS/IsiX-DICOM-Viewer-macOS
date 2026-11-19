#!/usr/bin/env python3
"""The series of the open studies are told apart in one way: by study, number and active window.

A colour names the study: blue for the newest open study of a patient, orange
for one older than another open study of the same patient. A number names the
series: its place in its own study, in the order of the series list, on every
series thumbnail, on the colour of its study while a window shows the series
and on a neutral grey otherwise, and the same number in a badge on the windows
that show it. A frame names the active window: only its key view and the
thumbnail of its series are framed in the colour of the study; the other
windows have a thin neutral frame. The rule is SeriesIdentity (IsiXImaging),
with its own tests; this compiles the application's SeriesListIdentification
over it and checks the colours, the numbers the lists give and the windows
read, and the contrast of the digits, then that the list, the windows and the
menu use it and that the modes it replaces (colours, numbers, both) are gone,
with their preference and its pop-up in the Viewers settings.
"""
from pathlib import Path
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from isix_modules import module_flags  # noqa: E402
import default_preferences  # noqa: E402
import pane_titles  # noqa: E402

driver = r'''
import AppKit
import IsiXImaging

// Only the host boundary is doubled; the identification below is production code.
@MainActor final class PreviousStudyMark {
    static var previous: [ObjectIdentifier] = []
    static func isPrevious(_ viewer: AnyObject?) -> Bool { viewer.map { previous.contains(ObjectIdentifier($0)) } ?? false }
}
final class ImageView { var needsDisplay = false }
@MainActor final class SeriesListPresenter {
    var rebuilt: [String] = []
    func build(showSelected: Bool, selectionOnly: Bool) { rebuilt.append("\(showSelected) \(selectionOnly)") }
}
@MainActor public final class ViewerController: NSObject {
    let horos_imageView: ImageView? = ImageView()
    let seriesListPresenter = SeriesListPresenter()
}
public final class AnnotationBox: NSObject {
    let text: NSAttributedString, boxColor: NSColor
    public init(attributedString: NSAttributedString, boxColor: NSColor, borderColor: NSColor) { text = attributedString; self.boxColor = boxColor }
}

func check(_ condition: Bool, _ message: String) {
    if !condition { fatalError(message) }
}
func luminance(_ color: NSColor) -> Double {
    let c = color.usingColorSpace(.sRGB)!
    func channel(_ x: CGFloat) -> Double {
        let x = Double(x)
        return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
}
func contrast(_ a: NSColor, _ b: NSColor) -> Double {
    (max(luminance(a), luminance(b)) + 0.05) / (min(luminance(a), luminance(b)) + 0.05)
}

@main struct Main {
    @MainActor static func main() {
        let current = SeriesListIdentification.currentStudyColor, previous = SeriesListIdentification.previousStudyColor
        let neutral = SeriesListIdentification.neutralColor
        // Blue, orange and a grey without a hue of its own.
        let c = current.usingColorSpace(.genericRGB)!, p = previous.usingColorSpace(.genericRGB)!, n = neutral.usingColorSpace(.genericRGB)!
        check(c.blueComponent > c.redComponent && c.blueComponent > c.greenComponent, "the current study is blue")
        check(p.redComponent > p.greenComponent && p.greenComponent > p.blueComponent, "the previous study is orange")
        check(n.redComponent == n.greenComponent && n.greenComponent == n.blueComponent, "the neutral colour is a grey")
        check(SeriesListIdentification.color(of: .current) == current && SeriesListIdentification.color(of: .previous) == previous, "a colour per study")

        // A window has the colour of its study, as its "Previous" mark has it.
        let recent = NSObject(), older = NSObject()
        PreviousStudyMark.previous = [ObjectIdentifier(older)]
        check(SeriesListIdentification.study(of: recent) == .current && SeriesListIdentification.study(of: older) == .previous, "the study of a window")
        check(SeriesListIdentification.color(for: recent) == current && SeriesListIdentification.color(for: older) == previous, "the colour of a window")
        check(SeriesListIdentification.color(for: nil) == current, "no window: the current study's colour")

        // The active window changed: every window draws its frame again and
        // recolours its list, without building it anew.
        let windows = [ViewerController(), ViewerController()]
        SeriesListIdentification.activeWindowChanged(among: windows)
        check(windows.allSatisfy { $0.horos_imageView?.needsDisplay == true }, "the frames are drawn again")
        check(windows.allSatisfy { $0.seriesListPresenter.rebuilt == ["false true"] }, "the lists recolour their cells")

        // The numbers the lists give are the ones the windows read.
        let first = NSObject(), second = NSObject()
        check(SeriesListIdentification.number(of: first) == 0 && SeriesListIdentification.number(of: nil) == 0, "no list, no number")
        SeriesListIdentification.setNumber(1, of: first)
        SeriesListIdentification.setNumber(2, of: second)
        check(SeriesListIdentification.number(of: first) == 1 && SeriesListIdentification.number(of: second) == 2, "the numbers given")
        SeriesListIdentification.setNumber(3, of: first)
        check(SeriesListIdentification.number(of: first) == 3, "a list numbers its series again")
        SeriesListIdentification.forgetNumbers()
        check(SeriesListIdentification.number(of: first) == 0, "forgotten")

        // The digits are read on the three colours.
        for (name, background) in [("blue", current), ("orange", previous), ("grey", neutral)] {
            let ratio = contrast(background, SeriesListIdentification.numberTextColor)
            check(background.alphaComponent == 1, "the image cannot show through the \(name)")
            check(ratio >= 4.5, "the digits on the \(name): \(ratio)")
            print("\(name): contrast \(ratio):1")
        }

        // The window's badge: the number on the colour of the study, built once.
        let badge = SeriesListIdentification.badge(number: 2, study: .previous)
        check(badge.text.string.trimmingCharacters(in: .whitespaces) == "2" && badge.boxColor == previous, "the badge of a previous study's series")
        check(SeriesListIdentification.badge(number: 2, study: .previous) === badge, "one box per number and study")
        check(SeriesListIdentification.badge(number: 2, study: .current) !== badge
              && SeriesListIdentification.badge(number: 2, study: .current).boxColor == current, "the same number of the current study")
        check(SeriesListIdentification.badge(number: 12, study: .current).text.string == "12", "two digits")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='horos-series-identification-') as folder:
    work = Path(folder)
    (work / 'driver.swift').write_text(driver)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(work / 'modules'), *module_flags('IsiXImaging', work / 'isix'),
                    str(root / 'Horos/Sources/SeriesListIdentification.swift'), str(work / 'driver.swift'), '-o', str(work / 'check')], check=True)
    subprocess.run([str(work / 'check')], check=True, timeout=60)

failures = []


def source(name):
    return (root / 'Horos/Sources' / name).read_text()


def need(text, pieces, where):
    for piece, what in pieces:
        if piece not in text:
            failures.append(f'{where}: {what}')


# The list: a frame for the series of the active window, a number on every series cell.
presenter = source('SeriesListPresenter.swift')
need(presenter, [
    ('cell.frameColor = color', 'a cell is framed in the colour it is given'),
    ('cell.seriesNumber = 0', 'a reused cell loses its number'),
    ('let number = SeriesIdentity.number(atPlace: place)', 'a series is numbered by its place in its study'),
    ('SeriesListIdentification.setNumber(number, of: series)', 'the list tells the windows the number'),
    ('cell.numberColor = build.openColors?.object(forKey: series) as? NSColor', 'the number takes the colour of the study while a window shows the series'),
    ('if case .series(_, let place) = position { setNumber(cell, of: curSeries, atPlace: place, in: build) }', 'a filled series cell is numbered'),
    ('setNumber(seriesCell, of: curSeries, atPlace: place, in: build)', 'a recoloured series cell is numbered'),
    ('let windowColors = ViewerController.horosSeriesWindowColors()', 'the frames come from the active window'),
    ('let openColors = ViewerController.horosSeriesOpenColors()', 'the colours of the numbers come from the open windows'),
], 'the series list')
cell = source('ThumbnailCell.swift')
draw = cell[cell.index('public override func draw(withFrame'):cell.index('public override var cellSize')]
need(draw, [
    ('guard seriesNumber > 0 else { return }', 'only a series cell has a number'),
    ('(numberColor ?? SeriesListIdentification.neutralColor).setFill()', 'the number of a series no window shows is on the neutral colour'),
    ('.foregroundColor: SeriesListIdentification.numberTextColor', 'the digits have the contrast colour'),
], 'the thumbnail')

# Which series are framed and coloured.
registry = source('ViewerController+ViewerRegistry.swift')
frames = registry[registry.index('class func horosSeriesWindowColors()'):registry.index('class func horosSeriesOpenColors()')]
need(frames, [
    ('guard let active = viewerRegistry.frontMostDisplayedViewer(on: nil), let series = active.imageView()?.seriesObj() as AnyObject?,',
     'only the active window frames a thumbnail'),
    ('let color = ViewerWindowBorder.color(for: active, active: true) else { return colors }',
     'the thumbnail has the frame of the window\'s views, or none where they have none'),
    ('colors.setObject(color, forKey: series)', 'the frame has the colour of the window\'s frame'),
], 'the frames of the thumbnails')
for gone in ('displayedViewers.count > 1', 'numberOf2DViewer()'):
    if gone in frames:
        failures.append(f'the frames of the thumbnails: {gone} counts the windows apart from the frame of the views')
need(registry[registry.index('class func horosSeriesOpenColors()'):], [
    ('for (series, viewer) in viewerRegistry.displayedSeries() {', 'every displayed series has a colour'),
    ('colors.setObject(SeriesListIdentification.color(for: viewer), forKey: series)', 'the colour is its window\'s study\'s'),
], 'the colours of the numbers')

# The windows: the frame, the badge and what follows a change of the active window.
drawing = source('DCMView+Drawing.swift')
need(drawing, [
    ('if is2DViewer && self.stringID == nil, let viewer, !viewer.fullScreenON() {', 'a 2D viewer\'s own view may have a frame, out of full screen'),
    ('frameInset = ViewerWindowBorder.color(for: viewer, active: active).map {', 'the frame and its colour are asked where the thumbnail asks them'),
    ('PlanarFrameGraphics.drawWindowBorder(size: drawingFrameRect.size, scale: CGFloat(sf), color: $0, active: active) } ?? 0',
     'the frame is drawn in that colour, and none without one'),
], 'the frame of a window')
if 'numberOf2DViewer() > 1 && is2DViewer' in drawing:
    failures.append('the frame of a window: the view counts the registered viewers, in the Dock or on another Space too')

# One rule for the image and the thumbnail (WindowFrameRule, IsiXImaging, with
# its own tests): how many windows are on screen, and with one window whether
# it shows a study other than the one it was opened with.
border = source('ViewerWindowBorder.swift')
need(border, [
    ('switch WindowFrameRule.frame(severalOnScreen: graph.registry.severalViewersAreOnScreen, isActive: active,', 'the rule is the module\'s, over the windows on screen'),
    ('study: SeriesListIdentification.study(of: viewer), studies: graph.windowStudies) {', 'and over the study the window was opened with'),
    ('case .none: return nil', 'no frame'),
    ('case .neutral: return SeriesListIdentification.neutralColor', 'the neutral frame of the views that are not the active one'),
    ('case .study(let study): return SeriesListIdentification.color(of: study)', 'the colour of the study on the active view'),
    ('graph.windowStudies.show(study.flatMap { study in study.studyInstanceUID.map { StudyReference(uid: $0, date: study.date) } })',
     'the window keeps the study it shows, and the first as the one it was opened with'),
    ('graph.windowStudies.reopen()', 'an opening asked for makes the study shown the opening one'),
    ('forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak graph] _ in', 'a change of Space draws the frame again'),
    ('viewer.seriesListPresenter.build(showSelected: false, selectionOnly: true)', 'the lists recolour the cell that carries the frame'),
], 'the frame\'s rule')
# The widths drawn are the ones the annotations keep clear of.
rule = (root / 'Modules/IsiXImaging/Sources/ViewerSeriesList/WindowFrameRule.swift').read_text()
need(rule, [
    ('public static let activeWidth = 3.0', 'the rule has the width the active frame is drawn with'),
    ('public static let inactiveWidth = 2.0', 'and the width of the others'),
    ('public static var annotationReserve: Double { activeWidth + annotationClearance }', 'the annotations leave the frame and its clearance'),
], 'the widths of the frame')
counted = source('ViewerRegistry.swift')
counted = counted[counted.index('@MainActor var severalViewersAreOnScreen: Bool {'):counted.index('@MainActor func displayedSeries()')]
need(counted, [
    ('return WindowFrameRule.severalOnScreen(entries.lazy.map { entry in', 'the register counts the windows on screen by the module\'s rule'),
    ('WindowFrameRule.Presence(isVisible: window?.isVisible ?? false, isMiniaturized: window?.isMiniaturized ?? false,', 'a window in the Dock is not on screen'),
    ('isOnActiveSpace: window?.isOnActiveSpace ?? false,', 'nor one on another Space'),
    ('isClosing: entry.isClosing || entry.viewer.windowWillClose(), isFullScreen: entry.isFullScreen)', 'nor one closing or full screen'),
], 'the windows on screen')
# Where the study of a window is set: every series shown, and the openings asked for.
need(source('ViewerSeriesLoad.swift'), [
    ('ViewerWindowBorder.studyShown(firstImage()?.series?.study, in: viewer)', 'every series a window takes tells the study it shows'),
], 'the study a window shows')
opener = source('ViewerOpener.swift')
need(opener, [
    ('if viewerNavigations == 0, let viewer { ViewerWindowBorder.reopened(viewer) }', 'an opening asked for in an open window is the study it was opened with'),
], 'the study a window was opened with')
navigation = source('ViewerOpener+Navigation.swift')
for start in ('    func loadNextSeries(_ curImage: NSManagedObject?, direction: Int, viewer: ViewerController?, firstViewer: Bool, keyImagesOnly: Bool) {\n',
              '    func loadSeries(_ series: NSManagedObject?, viewer: ViewerController?, keyImagesOnly: Bool) -> ViewerController? {\n'):
    if start + '        viewerNavigations += 1\n        defer { viewerNavigations -= 1 }\n' not in navigation:
        failures.append('the study a window was opened with: a series taken from the viewer\'s own lists or steps changes it (' + start.strip()[:24] + ')')
graphics = source('PlanarFramePresenter.swift')
need(graphics[graphics.index('public static func drawWindowBorder('):graphics.index('public static func drawOverflow(')], [
    ('let width: Float = active ? 3 : 2', 'the active frame is 3 points wide, the others 2'),
    ('halfWidth: Float(Double(size.width) / 2) - width * sf / 2, halfHeight: Float(Double(size.height) / 2) - width * sf / 2)',
     'the frame is whole inside the view'),
], 'the frame of a window')
textual = source('DCMView+WindowLevel+Coordinates.swift')
need(textual, [
    ('let seriesNumber = viewer2D?.seriesMenuPresenter.numberOfShownSeries() ?? 0', 'a window shows the number of its series'),
    ('let badge = SeriesListIdentification.badge(number: seriesNumber, study: SeriesListIdentification.study(of: viewer2D))', 'the badge has the colour of the window\'s study'),
    ('let top = lowerCorners.labelTop(preferred:', '"Previous" keeps clear of the lower corners\' lines'),
    ('colourBoxSize: colourBoxSize, edgeReserve: viewer2D == nil ? 0 : WindowFrameRule.annotationReserve)',
     'the lines and the badge leave the room of the frame, with or without one'),
    ('edgeReserve: self.horos_stringID == nil && self.is2DViewer() ? WindowFrameRule.annotationReserve : 0)',
     'the orientation letters leave the room of the frame'),
], 'the window\'s annotations')
if 'studyNumber(dateIndex: self.horos_studyDateIndex)' in textual:
    failures.append('a window still draws the number of its study')
popup = source('ViewerController+SeriesPopup.swift')
need(popup, [
    ('let known = SeriesListIdentification.number(of: series)', 'a window reads the number a list gave'),
    ('let number = SeriesIdentity.number(atPlace: place)', 'or the place of the series among its study\'s, as the database lists them'),
    ('let seriesWindowColors = ViewerController.horosSeriesOpenColors()', 'the menu marks the series a window shows'),
], 'the series menu')
window = source('ViewerSessionGraph+WindowLife.swift')
became = window[window.index('func windowDidBecomeMain() {'):]
became = became[:became.index('\n    }\n')]
need(became, [
    ('SeriesListIdentification.activeWindowChanged(among: registry.displayedViewers)', 'every viewer follows the active window'),
], 'a window becoming the active one')
for moment in ('func windowDidMiniaturize() {', 'func windowDidDeminiaturize() {'):
    body = window[window.index(moment):]
    if 'ViewerWindowBorder.windowsChanged(among: registry.displayedViewers)' not in body[:body.index('\n    }\n')]:
        failures.append('the frames are not drawn again: ' + moment)
closing = window[window.index('func closeWindow() {'):window.index('func finishClosingWindow() {')]
if 'ViewerWindowBorder.windowClosed(viewer, remaining: registry.isClosingAllWindows ? [] : registry.displayedViewers)' not in closing:
    failures.append('the frames are not drawn again when a window closes')

# The modes it replaces are gone.
everything = ''.join(path.read_text(errors='replace') for folder in ('Horos/Sources', 'Preference Panes', 'Modules/IsiXPreferences/Sources',
                                                                     'Modules/IsiXImaging/Sources')
                     for path in sorted((root / folder).rglob('*.swift')))
# The two classes keep the members former plugins were linked against, which
# nothing in the application calls any more.
everything = everything.replace(source('ViewerWindowColors.swift'), '')
identification = source('SeriesListIdentification.swift')
former = identification[identification.index('    // MARK: - The former modes'):identification.index('    // MARK: - Numbers')]
need(former, [
    ('@objc public nonisolated static let defaultsKey = "SeriesListIdentificationMode"', 'the key former plugins read'),
    ('public nonisolated static func showsColors(in defaults: UserDefaults) -> Bool { true }', 'colours are always shown'),
    ('public nonisolated static func showsNumbers(in defaults: UserDefaults) -> Bool { true }', 'numbers are always shown'),
    ('public nonisolated static func windowLabel(number: Int) -> String { String(number) }', 'the label of a number'),
], 'the members kept for former plugins')
everything = everything.replace(former, '')
for gone in ('SeriesListIdentificationMode', 'ViewerWindowColors', 'showsSeriesColors', 'SeriesListIdentification.showsColors',
             'SeriesListIdentification.showsNumbers', 'windowLabel(number:', 'horosSeriesWindowNumbers', 'SeriesListIdentification.defaultsKey'):
    if gone in everything:
        failures.append(f'the application still uses {gone}')
if 'SeriesListIdentificationMode' in default_preferences.registered():
    failures.append('the mode is still a registered preference')
variants = pane_titles.variants('OSIViewerPreferencePanePref.xib')
for language, path in variants.items():
    if ET.parse(path).getroot().find('.//binding[@keyPath="values.SeriesListIdentificationMode"]') is not None:
        failures.append(f'{language}: the Viewers settings still offer the modes')
if len(variants) != 10:
    failures.append(f'{len(variants)} copies of the Viewers pane')

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('PASS: studies by colour, series by number on every thumbnail and window, the active window by its frame; the former modes are gone')
