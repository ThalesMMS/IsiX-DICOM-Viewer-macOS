#!/usr/bin/env python3
"""The texts written over the image follow the language of the interface, all of them.

The annotations in the corners of a 2D view and of the database's preview, the
notices under the top orientation letter, the labels of the ROIs and the line
of the 3D view that says what is under the mouse were listed as technical texts
that may stay as English writes them, and each catalog translated another part:
Italian wrote "Spessore: … Posizione: …" under "Image size", German and Spanish
"Bildgröße" over "Thickness: … Location: …", French and Brazilian Portuguese
left all of it in English beside a translated window.

What is checked, in the eleven catalogs that are not the English one:

- the set is the one the sources write: the keys of `annotationPhrases` and of
  the notices in DCMView+WindowLevel+Coordinates.swift, of the labels in
  ROI+Label.swift, of the names the Viewers pane gives the statistics in
  ROILabelPresentation.swift, of the line under a 3D view in
  VRView+Gestures.swift and of the measurements written over it in
  VRView+Measure.swift. A key added there is to be listed here, as translated
  or as kept;
- a translated text differs from the English one in every catalog. A language
  whose word is the English word is listed in SAME, with the word;
- a kept text is the English one in every catalog: an abbreviation, a unit, the
  letters of a measurement and the orientation letters, of which the place of
  an image in its series shows the first byte;
- every value takes the conversions of the English value, in its order unless
  they are numbered, begins and ends with the white space of its key (a field
  of a line is written after another: " Angle: 0" after "Zoom: 100%"), and has
  its line breaks;
- the lines of a corner take room: with the default annotations of
  AnnotationsDefault.plist and the values of one image, AnnotationOverlayLayout
  places the lines of each language in a view of the size of a small preview of
  the database window, with the image fused with another and without, and in a
  tile of a 2D viewer. Measured with the font each of them draws with, no line
  leaves the view, no line of a corner reaches a line of another corner, and no
  corner is more than 30% wider than the English one;
- the names of the statistics fit in their row of the Viewers pane, which
  tests/test-roi-compact-label-pane.py measures.

The length of a line, the angle of three points and the statistics of the oval
of a 3D view are of the set: VTK holds their texts, in UTF-8, and the view draws
them on its overlay as it draws the others.
"""
from pathlib import Path
import json
import plistlib
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
import isix_modules  # noqa: E402

LANGUAGES = ('ar', 'de', 'es', 'fr', 'hi', 'it-IT', 'ja-JP', 'ko', 'pt-BR', 'ru', 'zh-Hans')

# The fields of AnnotationPhrases and the keys the view gives them.
PHRASES = {
    'imageSize': 'Image size: %ld x %ld', 'viewSize': 'View size: %ld x %ld',
    'mouseColour': 'X: %d px Y: %d px Value: R:%ld G:%ld B:%ld', 'mouseGrey': 'X: %d px Y: %d px Value: %2.2f %@',
    'fusedColour': 'Fused Image : X: %d px Y: %d px Value: R:%ld G:%ld B:%ld',
    'fusedGrey': 'Fused Image : X: %d px Y: %d px Value: %2.2f %@',
    'suv': 'SUV: %.2f', 'fusedSUV': 'SUV (fused image): %.2f', 'zoom': 'Zoom: %0.0f%%', 'angle': ' Angle: %0.0f',
    'imageRange': 'Im: %ld-%ld/%ld %@', 'image': 'Im: %ld/%ld %@',
    'windowLevelDecimals': 'WL: %0.4f WW: %0.4f', 'windowLevel': 'WL: %d WW: %d',
    'windowPercent': 'From: %d %% (%0.2f) to: %d %% (%0.2f)',
    'thicknessMicronsLocationMicrons': 'Thickness: %0.2f %cm Location: %0.2f %cm',
    'thicknessMicrons': 'Thickness: %0.2f %cm Location: %0.2f mm', 'thickness': 'Thickness: %0.2f mm Location: %0.2f mm',
    'slabThickness': 'Thickness: %@ Location: %0.2f mm', 'position': 'Position: %@ ',
}
LETTERS = {'R', 'L', 'A', 'P', 'I', 'S'}

# What every language writes in its own words.
TRANSLATED = {
    # The annotations of a view.
    'Image size: %ld x %ld', 'View size: %ld x %ld',
    'X: %d px Y: %d px Value: R:%ld G:%ld B:%ld', 'X: %d px Y: %d px Value: %2.2f %@',
    'Fused Image : X: %d px Y: %d px Value: R:%ld G:%ld B:%ld', 'Fused Image : X: %d px Y: %d px Value: %2.2f %@',
    'SUV (fused image): %.2f', 'Zoom: %0.0f%%', ' Angle: %0.0f', 'From: %d %% (%0.2f) to: %d %% (%0.2f)',
    'Thickness: %0.2f %cm Location: %0.2f %cm', 'Thickness: %0.2f %cm Location: %0.2f mm',
    'Thickness: %0.2f mm Location: %0.2f mm', 'Thickness: %@ Location: %0.2f mm', 'Position: %@ ',
    # The notices under the top orientation letter, and the marks of a view.
    'Horizontally & Vertically Flipped', 'Horizontally Flipped', 'Vertically Flipped', 'VOI LUT Applied',
    'Different frame of reference', 'Different study', 'Reference lines are turned off', 'Planes do not intersect',
    'Previous', 'Tilt corrected (%0.1f\u00b0)',
    # The label of an ROI.
    'Fused Image', 'Mean: %0.3f%@', 'SDev: %0.3f%@', 'Sum: %0.0f%@', 'Median: %@%@', 'Min: %0.3f%@', 'Max: %0.3f%@',
    'Skewness: %0.3f Kurtosis: %0.3f',
    'Area: %0.1f %cm\u00b2', 'Area: %0.3f mm\u00b2', 'Area: %0.3f cm\u00b2', 'Area: %0.3f pix2',
    'Calcium Score: %0.1f', 'Calcium Volume: %0.1f', 'Calcium Mass: %0.1f',
    'Value: %0.3f%@', 'Fused Image Value: %0.3f%@',
    '2D Pos: X:n/a %@ Y:%0.3f %@', '2D Pos: X:%0.3f %@ Y:n/a %@', '2D Pos: X:n/a %@ Y:n/a %@',
    '2D Pos: X:%0.3f %@ Y:%0.3f %@', '2D Pos: X:%0.3f px Y:%0.3f px', '3D Pos: X:%0.3f mm Y:%0.3f mm Z:%0.3f mm',
    'Length: %@', 'Length: X=%0.3f %@, Y=%0.3f %@', '3D Length: %@',
    'Angle: %0.2f%@ with: %@', 'Angle: %0.2f%@', 'Angle 2: %0.2f%@', 'Angle: %0.3f%@ / %0.3f%@',
    # The names the Viewers pane gives the statistics of that label.
    'Area (ROI statistic)', 'Mean (ROI statistic)', 'SDev (ROI statistic)', 'Sum (ROI statistic)',
    'Median (ROI statistic)', 'Min (ROI statistic)', 'Max (ROI statistic)',
    # The line under a 3D view.
    'View Size: %d x %d', '   Pixel: %@    %@ %@', '   Measurement: %@ ', '   Angle: %2.1f degrees ', '   Scale: %2.3f %% ',
    # The measurements written over a 3D view: the length of a line, the angle of three points, the statistics of the oval.
    'Length: %@ ', 'Angle: %2.1f degrees ', 'Mean: %2.2f SDev: %2.2f\nMin: %2.2f Max: %2.2f',
}
# What stays as English writes it: abbreviations, units and the letters of a measurement.
KEPT = {
    'SUV: %.2f', 'Im: %ld-%ld/%ld %@', 'Im: %ld/%ld %@', 'WL: %0.4f WW: %0.4f', 'WL: %d WW: %d',
    '(W: %@ H: %@)', 'A: %@', 'B: %@', 'C: %@', 'B-C: %@', 'SUV', 'cm/sec', 'm/sec',
} | LETTERS
# Keys of ROI+Label.swift that are no text of a label: the name an ROI has before it is given one, which the label
# leaves out, and the median of an ROI that has none, which Hindi and Japanese write in their words.
NOT_OF_THE_SET = {'Unnamed', 'N/A'}
# The languages that write a text as English does, by the word they share with it.
SAME = {
    'Zoom: %0.0f%%': {'de', 'es', 'it-IT', 'pt-BR'},            # Zoom
    'Position: %@ ': {'de'},                                      # Position
    'Median: %@%@': {'de'}, 'Median (ROI statistic)': {'de'},     # Median
    'Min: %0.3f%@': {'de', 'it-IT'}, 'Max: %0.3f%@': {'de', 'it-IT'},
    'Min (ROI statistic)': {'de', 'fr', 'it-IT'}, 'Max (ROI statistic)': {'de', 'fr', 'it-IT'},
    'Area: %0.1f %cm\u00b2': {'it-IT'}, 'Area: %0.3f mm\u00b2': {'it-IT'}, 'Area: %0.3f cm\u00b2': {'it-IT'},
    'Area: %0.3f pix2': {'it-IT'}, 'Area (ROI statistic)': {'it-IT'},
    '   Pixel: %@    %@ %@': {'de', 'it-IT', 'pt-BR'},            # Pixel
}

# Where each text is written: the keys of a block of a source, which are all of this test.
SWIFT_KEY = re.compile(r'NSLocalizedString\(\s*"((?:\\.|[^"\\])*)"')


def swift_keys(text):
    """The keys of the NSLocalizedString calls of `text`."""
    keys = set()
    for literal in SWIFT_KEY.findall(text):
        literal = re.sub(r'\\u\{([0-9A-Fa-f]+)\}', lambda match: chr(int(match.group(1), 16)), literal)
        keys.add(json.loads('"' + literal + '"'))
    return keys


def between(text, start, end, name):
    if start not in text or end not in text[text.index(start):]:
        sys.exit(f'{name}: the block from {start!r} to {end!r} was not found')
    return text[text.index(start):text.index(end, text.index(start))]


def source(name):
    return (ROOT / 'Horos/Sources' / name).read_text(encoding='utf-8')


failures = []
view = source('DCMView+WindowLevel+Coordinates.swift')
phrases = swift_keys(between(view, 'private let annotationPhrases', 'return phrases', 'the phrases of the annotations'))
if phrases != set(PHRASES.values()) | LETTERS:
    failures.append(f'the phrases of the annotations are not the ones listed: {sorted(phrases ^ (set(PHRASES.values()) | LETTERS))}')
written = phrases
written |= swift_keys(between(view, 'public dynamic func drawOrientation', 'let commands = ', 'the notices'))
written |= swift_keys(source('ROI+Label.swift')) - NOT_OF_THE_SET
written |= {key for key in swift_keys(source('ROILabelPresentation.swift')) if key.endswith(' (ROI statistic)')}
written |= swift_keys(between(source('VRView+Gestures.swift'), 'let s = NSMutableString(string:', 'pixelInformation?.stringValue = s',
                              'the line under a 3D view'))
written |= swift_keys(source('VRView+Measure.swift'))
written |= swift_keys(between(source('ViewerReferenceLines.swift'), 'reasonForIncompatibleFrame', 'logPrefix', 'the reference line notices'))
for name, key in (('PreviousStudyMark.swift', 'Previous'), ('GantryTiltPolicy.swift', 'Tilt corrected (%0.1f\u00b0)')):
    if key not in swift_keys(source(name)):
        failures.append(f'{name} no longer writes {key!r}')
    written.add(key)
# The width and height of an ROI are named W/H by the pane in the catalogs that keep the letters.
listed = TRANSLATED | KEPT | {'W/H (ROI statistic)'}
if written - listed:
    failures.append(f'written over the image and not listed as translated or kept: {sorted(written - listed)}')
if listed - written:
    failures.append(f'listed and written by no source read here: {sorted(listed - written)}')
if TRANSLATED & KEPT:
    failures.append(f'both translated and kept: {sorted(TRANSLATED & KEPT)}')


def catalog(language):
    path = ROOT / f'Horos/Resources/{language}.lproj/Localizable.strings'
    return json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)]))


CONVERSION = re.compile(r'%(?:(\d+)\$)?[-+ 0#]*\d*(?:\.\d+)?((?:ll|l|hh|h|q|z)?[@dDiuUxXoOfeEgGcCsSaAp%])')
# What isolates a run of numbers in a line that reads from the right.
ISOLATES = '\u2066\u2067\u2068\u2069\u200e\u200f'


def conversions(text):
    """The conversions of a format as (position, kind): numbered ones by their number, the others in their order."""
    found = [(number, kind) for number, kind in CONVERSION.findall(text) if kind != '%']
    if any(number for number, _ in found):
        return sorted((int(number or 0), kind) for number, kind in found)
    return [(index + 1, kind) for index, (_, kind) in enumerate(found)]


def edges(text):
    """The white space a text begins and ends with."""
    bare = text.strip(ISOLATES)
    return bare[:len(bare) - len(bare.lstrip(' '))], bare[len(bare.rstrip(' ')):]


english = catalog('en')
catalogs = {language: catalog(language) for language in LANGUAGES}
for language, table in catalogs.items():
    for key in sorted(TRANSLATED | KEPT):
        original = english.get(key, key)
        value = table.get(key)
        if value is None:
            failures.append(f'{language}: no entry for {key!r}')
            continue
        if key in KEPT and value != original:
            failures.append(f'{language}: {key!r} is an abbreviation that stays, and is written {value!r}')
        if key in TRANSLATED and value == original and language not in SAME.get(key, ()):
            failures.append(f'{language}: {key!r} is left in English')
        if key in TRANSLATED and value != original and language in SAME.get(key, ()):
            failures.append(f'{language}: {key!r} is listed as the same word as English and is written {value!r}')
        if conversions(value) != conversions(original) or value.count('%%') != original.count('%%'):
            failures.append(f'{language}: {key!r} = {value!r} does not take the conversions of {original!r}')
        if edges(value) != edges(key):
            failures.append(f'{language}: {key!r} = {value!r} does not begin and end with the spaces of its key')
        if any(value.count(character) != key.count(character) for character in '\n\r\t'):
            failures.append(f'{language}: {key!r} = {value!r} changes the line breaks')
    for letter in LETTERS:
        if not (len(table[letter]) == 1 and table[letter].isascii()):
            failures.append(f'{language}: the orientation letter {letter} is written {table[letter]!r}')

if failures:
    print('\n'.join(failures[:60]))
    sys.exit(f'{len(failures)} texts written over the image fail')

# The lines of the default annotations, for one image: a CT slice of a study with its patient and its series.
SAMPLE = {
    ('DB', 'name'): 'DOE^JANE', ('DB', 'patientID'): '1234567', ('DB', 'studyName'): 'CT ABDOMEN W CONTRAST',
    ('DB', 'seriesDescription'): 'AXIAL 3.0 SOFT', ('DB', 'id'): '4', ('DB', 'date'): '19/11/2026, 10:42:07',
    ('Special', "Patient's Actual Age"): '45 y', ('Special', "Patient's Age At Acquisition"): '44 y',
    ('DICOM', 'TransferSyntaxUID'): '1.2.840.10008.1.2.1',
    # A CT slice has no echo time, repetition time or field strength: their lines are not shown.
    ('DICOM', 'EchoTime'): None, ('DICOM', 'RepetitionTime'): None, ('DICOM', 'MagneticFieldStrength'): None,
}
template = plistlib.loads((ROOT / 'Horos/Resources/AnnotationsDefault.plist').read_bytes())['Default']


def lines_of(position, without=()):
    lines = []
    for line in template[position]:
        fields, valued = [], False
        for field in line['fullContent']:
            kind, name = field['type'], field.get('field') or field.get('name')
            if kind == 'Manual':
                fields.append(name)
            elif kind == 'Special' and (kind, name) not in SAMPLE:
                if name not in without:
                    fields.append(name)
                    valued = True
            elif (kind, name) not in SAMPLE:
                sys.exit(f'the default annotations have a field this test has no value for: {kind} {name}')
            elif SAMPLE[(kind, name)] is not None:
                fields.append(SAMPLE[(kind, name)])
                valued = True
        if valued:
            lines.append(fields)
    return lines


CORNERS = ('TopLeft', 'TopRight', 'LowerLeft', 'LowerRight')
# The preview of the database window draws with the system font of 12 points and shows no position in
# millimetres; a 2D viewer draws with the font of the preferences, Geneva of 14 points when none is chosen.
PREVIEW = {position: lines_of(position, without=('Mouse Position (mm)',)) for position in CORNERS}
VIEWER = {position: lines_of(position) for position in CORNERS}
CASES = [
    {'name': 'the preview of the database window, 400 x 300', 'positions': PREVIEW, 'fontSize': 12.0, 'width': 400.0, 'height': 300.0, 'fused': False},
    {'name': 'the same preview with a fused image', 'positions': PREVIEW, 'fontSize': 12.0, 'width': 400.0, 'height': 300.0, 'fused': True},
    {'name': 'a tile of a 2D viewer, 640 x 400', 'positions': VIEWER, 'fontName': 'Geneva', 'fontSize': 14.0, 'width': 640.0, 'height': 400.0, 'fused': False},
]
# How much wider than the English one a corner may be.
WIDER = 1.3

DRIVER = r'''
import AppKit
import IsiXImaging

/// What a view shows of one image: the same in every language.
struct Sample: AnnotationValueSource {
    let probe: AnnotationPixelProbe
    func shows(_ token: String) -> Bool { true }
    func showsPatientName() -> Bool { true }
    func imageSize() -> (width: Int, height: Int) { (512, 512) }
    func pixelProbe() -> AnnotationPixelProbe? { probe }
    func zoom() -> Float { 1.73 }
    func rotation() -> Float { 270 }
    func imagePosition() -> AnnotationImagePosition {
        AnnotationImagePosition(current: 99, count: 300, stack: 1, flipped: false, step: (0, 0, -3))
    }
    func millimetrePosition() -> AnnotationMillimetrePosition? {
        AnnotationMillimetrePosition(x: -123.45, y: 67.89, z: 1647, isPlane: true, pixelSpacingX: 0.7)
    }
    func windowLevel() -> AnnotationWindowLevel {
        AnnotationWindowLevel(level: 40, width: 400, windowsAsPET: probe.fused != nil, maximumOfSeries: probe.fused != nil ? 4000 : 0)
    }
    func slice() -> AnnotationSlice {
        AnnotationSlice(thickness: 3, location: 1647, stack: 1, viewPosition: nil, patientPosition: nil, hasLocation: true)
    }
    func thickSlab() -> (thickness: Float, location: Float) { (0, 0) }
    func patientName() -> String? { nil }
}

let input = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
let languages = input["languages"] as! [String: [String: String]]
let cases = input["cases"] as! [[String: Any]]
var answer: [String: Any] = [:]
for (language, texts) in languages {
    var phrases = AnnotationPhrases.english
    phrases.imageSize = texts["imageSize"]!
    phrases.viewSize = texts["viewSize"]!
    phrases.mouseColour = texts["mouseColour"]!
    phrases.mouseGrey = texts["mouseGrey"]!
    phrases.fusedColour = texts["fusedColour"]!
    phrases.fusedGrey = texts["fusedGrey"]!
    phrases.suv = texts["suv"]!
    phrases.fusedSUV = texts["fusedSUV"]!
    phrases.zoom = texts["zoom"]!
    phrases.angle = texts["angle"]!
    phrases.imageRange = texts["imageRange"]!
    phrases.image = texts["image"]!
    phrases.windowLevelDecimals = texts["windowLevelDecimals"]!
    phrases.windowLevel = texts["windowLevel"]!
    phrases.windowPercent = texts["windowPercent"]!
    phrases.thicknessMicronsLocationMicrons = texts["thicknessMicronsLocationMicrons"]!
    phrases.thicknessMicrons = texts["thicknessMicrons"]!
    phrases.thickness = texts["thickness"]!
    phrases.slabThickness = texts["slabThickness"]!
    phrases.position = texts["position"]!
    var measured: [[[String: Any]]] = []
    for each in cases {
        let size = CGFloat(each["fontSize"] as! Double)
        let font = (each["fontName"] as? String).flatMap { NSFont(name: $0, size: size) } ?? NSFont.systemFont(ofSize: size)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let letter = NSAttributedString(string: "B", attributes: attributes).size()
        let fused = each["fused"] as! Bool
        let image = AnnotationPixelProbe.Reading(x: 511, y: 511, value: .grey(-1024), suvConverted: false, suv: fused ? 12.34 : nil)
        let other = AnnotationPixelProbe.Reading(x: 127, y: 127, value: .grey(12345.67), suvConverted: true, suv: 12.34)
        let sample = Sample(probe: AnnotationPixelProbe(image: image, fused: fused ? other : nil))
        let layout = AnnotationOverlayLayout(originX: 0, originY: 0, width: each["width"] as! Double, height: each["height"] as! Double, scale: 1,
                                             characterWidth: Double(letter.width), lineHeight: Double(letter.height))
        var lines: [[String: Any]] = []
        for (position, fields) in each["positions"] as! [String: [[String]]] {
            let drawn = layout.commands(for: position, lines: fields, fullText: true, patientNamePrefix: "\u{1}", phrases: phrases, values: sample)
            for case let .text(text, x, y, alignment) in drawn.commands {
                let width = Double(NSAttributedString(string: text, attributes: attributes).size().width)
                let left = alignment == .left ? Double(x) : alignment == .right ? Double(x) - width : Double(x) - width / 2
                lines.append(["position": position, "text": text, "left": left, "right": left + width, "y": y, "height": Double(letter.height)])
            }
        }
        measured.append(lines)
    }
    answer[language] = measured
}
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: answer, options: [.sortedKeys]))
'''

with tempfile.TemporaryDirectory() as folder:
    folder = Path(folder)
    target = ['-target', 'arm64-apple-macos15.0']
    flags = isix_modules.module_flags('IsiXImaging', folder / 'modules', target)
    (folder / 'main.swift').write_text(DRIVER)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', *target, *flags, str(folder / 'main.swift'), '-o', str(folder / 'measure')],
                   check=True)
    tables = dict(catalogs, en=english)
    request = {'cases': CASES, 'languages': {language: {field: table.get(key, key) for field, key in PHRASES.items()}
                                             for language, table in tables.items()}}
    (folder / 'request.json').write_text(json.dumps(request))
    measured = json.loads(subprocess.check_output([str(folder / 'measure'), str(folder / 'request.json')]))


def faults(lines, case):
    """What is wrong with the lines of a view: one that leaves it, two of different corners that meet."""
    found = []
    for line in lines:
        if line['left'] < 0 or line['right'] > case['width'] or line['y'] > case['height'] or line['y'] - line['height'] < 0:
            found.append(f'{line["text"]!r} leaves the view')
        for other in lines:
            if line['position'] < other['position'] and abs(line['y'] - other['y']) < line['height'] \
                    and line['left'] < other['right'] and other['left'] < line['right']:
                found.append(f'{line["text"]!r} of {line["position"]} reaches {other["text"]!r} of {other["position"]}')
    return found


def extent(lines, position):
    return max((line['right'] - line['left'] for line in lines if line['position'] == position), default=0.0)


widest = {}
for index, case in enumerate(CASES):
    reference = measured['en'][index]
    if len(reference) < 10:
        sys.exit(f'{case["name"]}: only {len(reference)} lines were placed')
    for fault in faults(reference, case):
        failures.append(f'{case["name"]}, en: {fault}: the view is too small to say anything of a translation')
    for language in LANGUAGES:
        lines = measured[language][index]
        if len(lines) != len(reference):
            failures.append(f'{case["name"]}, {language}: {len(lines)} lines where English writes {len(reference)}')
        for fault in faults(lines, case):
            failures.append(f'{case["name"]}, {language}: {fault}')
        for position in ('TopLeft', 'LowerLeft'):
            ratio = extent(lines, position) / extent(reference, position)
            widest[language] = max(widest.get(language, 0), ratio)
            if ratio > WIDER:
                failures.append(f'{case["name"]}, {language}: the lines of {position} are {ratio:.2f} times as wide as the English ones')
# A line that is the same in every language says nothing: the translated ones must be among those measured.
for language in LANGUAGES:
    same = sum(1 for index in range(len(CASES)) for line, other in zip(sorted(map(json.dumps, measured[language][index])),
                                                                         sorted(map(json.dumps, measured['en'][index]))) if line == other)
    total = sum(len(measured['en'][index]) for index in range(len(CASES)))
    if total - same < 12:
        failures.append(f'{language}: only {total - same} of the {total} measured lines differ from the English ones')

if failures:
    print('\n'.join(failures[:60]))
    sys.exit(f'{len(failures)} lines over the image fail')
print(f'PASS: {len(TRANSLATED)} texts written over the image are translated and {len(KEPT)} kept in {len(LANGUAGES)} catalogs; '
      f'in {len(CASES)} views no line leaves the view or reaches another corner, and the widest corner is '
      f'{max(widest.values()):.2f} times the English one ({max(widest, key=widest.get)})')
