#!/usr/bin/env python3
"""The annotation levels, with Custom, and the popup that picks them.

HorosAnnotationLevel is compiled and asked:

* None, Graphic, Basic and Full show what they showed: Graphic the graphics
  without the scale ruler or text, Basic all but the patient's name, Full
  everything; Plugin Only the graphics and the ruler, its text left to plugins.
* Custom shows an element unless the Custom Annotations sheet unchecked it,
  and draws text only while one text element is checked.
* Tab steps None, Graphic, Basic, Full, Custom and back to None; Plugin Only
  goes to None, as a level past Full did.
* The tokens of the annotation layout fall to their element.
* Drawing ROIs at None makes the level Graphic; at Custom with the ROIs
  unchecked, it checks them again.

The wiring is read from the sources: the 2D view draws each graphic element
and each text token through the rule, Tab and the ROI paths use it, the
toolbar item installs the popup in the view the ten localized Viewer.xib keep
empty, and 2D Viewer > Annotations gets Custom.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
import re
import subprocess
import tempfile
from pathlib import Path

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

check([0, 1, 2, 3, 5].map { AnnotationLevel.level(after: $0) } == [1, 2, 3, 5, 0], "Tab cycle")
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

view = (sources / 'DCMView.m').read_text(encoding='latin1')
frame = view[view.index('- (void) drawFrame:(NSRect)aRect'):]
frame = frame[:frame.index('recordAnnotationRects = NO;')]
for element in ['ColorBar', 'Rois', 'ReferenceLines', 'ScaleRuler']:
    expect(f'[HorosAnnotationLevel shows: HorosAnnotationElement{element} level: annotations]' in frame,
           f'drawFrame does not ask the level for {element}')
expect('annotations >= annotBase' not in frame, 'the ruler still follows Base')
expect('(int)[HorosAnnotationLevel levelAfter: annotationType]' in view, 'Tab does not step through Custom')
for path in ['DCMView.m', 'ROI.m']:
    text = (sources / path).read_text(encoding='latin1')
    expect('setInteger: annotGraphics forKey: @"ANNOTATIONS"' not in text, f'{path} still turns None into Graphic itself')
    expect(text.count('[HorosAnnotationLevel revealROIs]') == 2, f'{path} does not reveal ROIs through the level')
viewer = (sources / 'ViewerController.m').read_text(encoding='latin1')
expect('annotFull' not in viewer and viewer.count('[HorosAnnotationLevel currentLevelShowsPatientName]') == 5,
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
