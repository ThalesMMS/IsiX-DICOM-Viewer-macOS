#!/usr/bin/env python3
"""The annotation levels, with Custom, and the popup that picks them.

HorosAnnotationLevel is compiled and asked:

* None, Graphic, Basic and Full show what they showed: Graphic the graphics
  without the scale ruler or text, Basic all but the patient's name, Full
  everything; Plugin Only the graphics and the ruler, its text left to plugins.
* Custom shows an element unless the Custom Annotations sheet unchecked it,
  and draws text only while one text element is checked.
* Tab steps None, Graphic, Basic, Full and back to None, with Custom after
  Full only while it hides something (until then it shows what Full shows);
  Plugin Only goes to None, as a level past Full did.
* The tokens of the annotation layout fall to their element.
* Drawing ROIs at None makes the level Graphic; at Custom with the ROIs
  unchecked, it checks them again.

The wiring is read from the sources: the 2D view draws each graphic element
and each text token through the rule, Tab and the ROI paths use it, the
toolbar item installs the popup in the view the ten localized Viewer.xib keep
empty, 2D Viewer > Annotations gets Custom, and the Custom Annotations sheet
makes Custom the level when a check changes, not when it opens.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
import re
import subprocess
import tempfile
from pathlib import Path

from sources import class_text

root = Path(__file__).resolve().parents[1]
sources = root / 'Horos/Sources'

driver = r'''
import Foundation

func check(_ condition: Bool, _ message: String) {
    if !condition { FileHandle.standardError.write(("FAIL: " + message + "\n").data(using: .utf8)!); exit(1) }
}
typealias E = AnnotationElement
let graphics: [E] = [.rois, .colorBar, .scaleRuler, .referenceLines]
let text: [E] = [.orientation, .patientName, .imageInfo, .windowLevel, .mousePosition, .otherFields]
check(Set(graphics + text) == Set(E.allCases), "every element is a graphic or text")
check(text.allSatisfy { $0.isText } && !graphics.contains { $0.isText }, "isText")
check(Set(E.allCases.map { $0.hiddenKey }).count == E.allCases.count, "one default per element")

func shown(_ level: Int) -> Set<E> { Set(E.allCases.filter { AnnotationLevel.shows($0, level: level) }) }
check(shown(0).isEmpty, "None shows nothing")
check(shown(1) == [.rois, .colorBar, .referenceLines], "Graphic: \(shown(1))")
check(shown(2) == Set(E.allCases).subtracting([.patientName]), "Basic: \(shown(2))")
check(shown(3) == Set(E.allCases), "Full")
check(shown(4) == Set(graphics), "Plugin Only")
check(shown(5) == Set(E.allCases), "a new Custom level shows everything")
check([0, 1, 4].allSatisfy { !AnnotationLevel.showsText(level: $0) }, "no text at None, Graphic, Plugin Only")
check([2, 3, 5].allSatisfy { AnnotationLevel.showsText(level: $0) }, "text at Basic, Full, Custom")

let hidden: [String: Any] = [E.rois.hiddenKey: true, E.windowLevel.hiddenKey: true]
UserDefaults.standard.setVolatileDomain(hidden, forName: UserDefaults.argumentDomain)
check(shown(5) == Set(E.allCases).subtracting([.rois, .windowLevel]), "Custom follows its checks: \(shown(5))")
check(shown(3) == Set(E.allCases) && shown(1) == [.rois, .colorBar, .referenceLines], "the checks leave the other levels alone")
UserDefaults.standard.setVolatileDomain(Dictionary(uniqueKeysWithValues: text.map { ($0.hiddenKey, true) }), forName: UserDefaults.argumentDomain)
check(!AnnotationLevel.showsText(level: 5), "Custom without text")
check(shown(5) == Set(graphics), "Custom keeps its graphics without text")
UserDefaults.standard.setVolatileDomain([:], forName: UserDefaults.argumentDomain)

check(!AnnotationLevel.isCustomized, "a new Custom level hides nothing")
check([0, 1, 2, 3, 5].map { AnnotationLevel.level(after: $0) } == [1, 2, 3, 0, 0], "Tab cycle without a customized Custom level")
UserDefaults.standard.setVolatileDomain([E.windowLevel.hiddenKey: true], forName: UserDefaults.argumentDomain)
check(AnnotationLevel.isCustomized, "a hidden element customizes Custom")
check([0, 1, 2, 3, 5].map { AnnotationLevel.level(after: $0) } == [1, 2, 3, 5, 0], "Tab cycle with a customized Custom level")
UserDefaults.standard.setVolatileDomain([E.windowLevel.hiddenKey: false], forName: UserDefaults.argumentDomain)
check(!AnnotationLevel.isCustomized && AnnotationLevel.level(after: 3) == 0, "every element shown again: Custom leaves the cycle")
UserDefaults.standard.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
check(AnnotationLevel.level(after: 4) == 0 && AnnotationLevel.level(after: 9) == 0, "off the cycle")

let tokens: [String: E] = [
    "Orientation": .orientation, "PatientName": .patientName,
    "Window Level / Window Width": .windowLevel,
    "Mouse Position (px)": .mousePosition, "Mouse Position (mm)": .mousePosition,
    "Image Size": .imageInfo, "View Size": .imageInfo, "Zoom": .imageInfo, "Rotation Angle": .imageInfo,
    "Image Position": .imageInfo, "Thickness / Location / Position": .imageInfo,
    "Plugin": .otherFields, "DICOM_0008_0020": .otherFields, "DB_study.studyName": .otherFields,
]
for (token, element) in tokens {
    check(AnnotationLevel.element(forItem: token) == element, "token \(token)")
}

// revealROIs writes the persistent defaults: the domain of this binary,
// emptied before and after.
let domain = "horos-annotation-level-check"
UserDefaults.standard.removePersistentDomain(forName: domain)
UserDefaults.standard.set(0, forKey: "ANNOTATIONS")
check(AnnotationLevel.revealROIs() && UserDefaults.standard.integer(forKey: "ANNOTATIONS") == 1, "None becomes Graphic")
check(!AnnotationLevel.revealROIs(), "Graphic already shows ROIs")
UserDefaults.standard.set(5, forKey: "ANNOTATIONS")
UserDefaults.standard.set(true, forKey: E.rois.hiddenKey)
check(AnnotationLevel.revealROIs() && AnnotationLevel.shows(.rois, level: 5), "Custom checks the ROIs again")
check(AnnotationLevel.currentLevelShowsPatientName, "Custom with the name checked")
UserDefaults.standard.set(true, forKey: E.patientName.hiddenKey)
check(!AnnotationLevel.currentLevelShowsPatientName, "Custom with the name unchecked")
UserDefaults.standard.removePersistentDomain(forName: domain)
print("ok")
'''

with tempfile.TemporaryDirectory() as folder:
    folder = Path(folder)
    (folder / 'main.swift').write_text(driver)
    binary = folder / 'horos-annotation-level-check'
    subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', '-module-cache-path', str(folder / 'modules'),
                    str(sources / 'AnnotationLevel.swift'), str(folder / 'main.swift'), '-o', str(binary)], check=True)
    try:
        subprocess.run([str(binary)], check=True)
    finally:
        # The binary empties its defaults domain; the empty file goes too.
        (Path.home() / 'Library/Preferences' / f'{binary.name}.plist').unlink(missing_ok=True)

failures = []


def expect(condition, message):
    if not condition:
        failures.append(message)


header = (sources / 'DCMView.h').read_text(encoding='latin1')
level = (sources / 'AnnotationLevel.swift').read_text()
expect('enum { annotNone = 0, annotGraphics, annotBase, annotFull };' in header, 'the levels of DCMView.h changed')
for name, value in [('none', 0), ('graphic', 1), ('basic', 2), ('full', 3), ('pluginOnly', 4), ('custom', 5)]:
    expect(f'@objc public static let {name} = {value}' in level, f'AnnotationLevel.{name} is not {value}')

drawing = (sources / 'DCMView+Drawing.swift').read_text()
frame = drawing[drawing.index('public dynamic func drawFrame(_ aRect: NSRect)'):]
frame = frame[:frame.index('self.horos_recordAnnotationRects = false')]
for element in ['colorBar', 'rois', 'referenceLines', 'scaleRuler']:
    expect(f'AnnotationLevel.shows(.{element}, level: annotations)' in frame,
           f'drawFrame does not ask the level for {element}')
expect('annotations >= annotBase' not in frame, 'the ruler still follows Base')
keyboard = (sources / 'DCMView+Keyboard.swift').read_text()
expect('AnnotationLevel.level(after: Int(self.horos_annotationType))' in keyboard, 'Tab does not step through Custom')
popup = (sources / 'AnnotationsPopUp.swift').read_text()
present = popup[popup.index('public static func present(on window: NSWindow?)'):popup.index('private override init()')]
expect('choose(level:' not in present, 'opening Customize Annotations changes the level')
toggle = popup[popup.index('@objc private func toggle(_ sender: NSButton)'):popup.index('@objc private func close(_ sender: Any?)')]
expect('AnnotationsMenu.choose(level: AnnotationLevel.custom)' in toggle, 'changing a check does not make Custom the level')
text = class_text('DCMView')
expect(not re.search(r'\.set\([^\n]*annotGraphics[^\n]*forKey: "ANNOTATIONS"', text), 'DCMView still turns None into Graphic itself')
# The click of a ROI tool reveals them in DCMView+Mouse.swift, the ROI editing
# in DCMView+ROIEditing.swift.
editing = (sources / 'DCMView+ROIEditing.swift').read_text()
mouse = (sources / 'DCMView+Mouse.swift').read_text()
expect(mouse.count('AnnotationLevel.revealROIs()') + editing.count('AnnotationLevel.revealROIs()') == 2,
       'DCMView does not reveal ROIs through the level')
expect(not re.search(r'\.set\([^\n]*forKey: "ANNOTATIONS"', editing), 'the ROI editing still turns None into Graphic itself')
text = class_text('ROI')
expect('forKey: "ANNOTATIONS"' not in text, 'the ROI still turns None into Graphic itself')
expect(text.count('AnnotationLevel.revealROIs()') == 2, 'the ROI does not reveal ROIs through the level')
viewer = (((sources / 'ViewerController.m').read_text(encoding='latin1')) if (sources / 'ViewerController.m').exists() else '')
# The window title moved to ViewerController+WindowLifecycle.swift; the
# series menu and the series list, to ViewerController+SeriesPopup.swift and
# +SeriesThumbnails.swift, where the four patient lines (local and PACS
# studies, in each) go through seriesListPatientLine, which asks the level.
lifecycle = sources / 'ViewerController+WindowLifecycle.swift'
swift_title = lifecycle.read_text().count('AnnotationLevel.currentLevelShowsPatientName') if lifecycle.exists() else 0
objc_lines = viewer.count('[HorosAnnotationLevel currentLevelShowsPatientName]')
popup_file, list_file = sources / 'ViewerController+SeriesPopup.swift', sources / 'ViewerController+SeriesThumbnails.swift'
if objc_lines == 0 and popup_file.exists():
    popup, thumbnails = popup_file.read_text(), list_file.read_text()
    line = popup[popup.index('func seriesListPatientLine('):]
    line = line[:line.index('\n}\n')]
    asks = 'showsPatientName: AnnotationLevel.currentLevelShowsPatientName' in line
    objc_lines = 4 if asks and popup.count('seriesListPatientLine(') - 1 == 2 and thumbnails.count('seriesListPatientLine(') == 2 else 0
expect('annotFull' not in viewer and objc_lines + swift_title == 5,
       'window titles and series menus do not ask the level for the patient name')

draw = (sources / 'DCMView+WindowLevel+Coordinates.swift').read_text()
draw = draw[draw.index('public dynamic func drawTextualData(_ size: NSRect, annotationsLevel'):]
draw = draw[:draw.index('@objc(drawTextualData::)')]
expect(draw.count('AnnotationLevel.shows(.orientation, level: annotations)') == 2, 'orientation not asked twice')
loop = draw[draw.index('let item = objcObject(annotArray.object(at: j), NSString.self)'):]
expect(loop.index('if !AnnotationLevel.shows(element, level: annotations) {') < loop.index('if item.isEqual(to: "Image Size")'),
       'the text tokens are not filtered first')
expect('annotFull' not in draw, 'the patient name still follows Full only')

toolbar = (sources / 'ViewerController+Toolbar.swift').read_text()
item = toolbar[toolbar.index('} else if itemIdent == AnnotationsToolbarItemIdentifier {'):]
item = item[:item.index('} else if itemIdent ==', 1)]
expect(item.index('AnnotationsPopUpButton.install(in: self.horos_annotations)') < item.index('setView(self.horos_annotations)'),
       'the popup is not installed before the item reads its size')
expect('AnnotationsMenu.installInMainMenu()' in toolbar[toolbar.index('func setupToolbar()'):], 'the menu bar has no Custom')

xibs = sorted((root / 'Horos/Resources').glob('*.lproj/Viewer.xib'))
expect(len(xibs) == 10, f'{len(xibs)} Viewer.xib')
for xib in xibs:
    text = xib.read_text()
    start = text.index('<customView id="2577" userLabel="Annotations">')
    block = text[start:text.index('</customView>', start)]
    expect('<subviews>' not in block and 'values.ANNOTATIONS' not in block, f'{xib.parent.name}: the radios are still there')
    expect(re.search(r'<constraint firstAttribute="width" constant="100" id="[^"]+"/>', block) and 'width="100"' in block,
           f'{xib.parent.name}: the empty view keeps the radios\' width')
    expect('<outlet property="annotations" destination="2577"' in text, f'{xib.parent.name}: the outlet moved')

if failures:
    raise SystemExit('FAIL: ' + '; '.join(failures))
print('ok')
