#!/usr/bin/env python3
"""The 3D windows write their shading values one way, in the user's language
and with the decimal separator of the user's region.

Beside the Shading check box the VR window, the endoscopy (a VRController) and
the MPR show three lines: the ambient, the diffuse and the specular
coefficients, with the specular power after the specular one. The VR wrote
them in two ways: one decimal and «Specular :0.3-15.0» when it opened and on
Revert Series (-horosShowShading), two decimals and «Specular :1.17, 6.98» for
a shading preset or a change in the shading panel (-applyShading:), with a
point in every region and in English in Portuguese and German. The endoscopy
wrote the one-decimal form again over its opening text (-load3DState), and the
MPR the two-decimal one into a field its nib never connected, so the MPR showed
the nib's placeholder («Specular: 0.6, 2.0») whatever the values.

1. The text, ShadingValuesText (IsiXImaging), compiled as it is with a driver
   and every catalog's text: two decimals for every number, so a preset shows
   its values as they are written (Glossy Bone: 1.17 and 6.98), the decimal
   separator of the region (a comma in Portuguese, German, French, Spanish,
   Italian and Russian), three lines, and the specular power after a slash,
   which a decimal comma cannot be taken for. Each language's text with the
   widest numbers the shading panel's ranges give (0 to 1, 1, 4 and 50, two
   decimals; the system font's digits are not all as wide) fits in each
   window, read from that language's nib: VR and endoscopy, beside the
   Shading check box, in the room their item's constraints leave the field;
   MPR, whose field is placed by its frame, in that frame, which must hold the
   text and the margin the cell keeps on each side (2 points).
   Its lowest marks (Hindi and Arabic draw below the Latin line) are whole in
   the field's height in each window. Asked with no locale, as the windows
   ask, the text takes the region the process runs with.
2. The windows: the catalog's text is read in one place,
   ShadingValuesText.localized, in the user's region (no locale given). The VR
   and the MPR each write the field in one place, through it, and no other use
   of the field sets its value or hands it elsewhere; the endoscopy writes it
   only through the VR's -horosShowShadingValues. The VR's opening and Revert
   Series (-horosShowShading, from the view's values), a preset or a change in
   the panel (-applyShading:), the endoscopy's opening (-load3DState) and the
   MPR's opening and -applyShading: (from its hidden view's values) go through
   them. Every copy of MPR.xib connects the field of its Shading item.
3. The catalogs: the key is in the twelve, each with the four numbers once
   (%1$@ to %4$@), translated in the eleven other than English, with no space
   before a colon except in French, where the typography wants one. The two
   former keys are gone.
4. The nibs: in every copy of VR.xib, Endoscopy.xib and MPR.xib, the four
   fields of the shading panel accept what their sliders give: the number
   formatter's minimum is 0 and its maximum the slider's (1, 1, 4 and 50), so
   a typed value cannot make the text wider than what part 1 measures.

`<git revision>` as an optional argument reads the files from that revision:
the negative control.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
TEXT = 'Modules/IsiXImaging/Sources/ViewerReconstruction/ShadingValuesText.swift'
OPENING = 'Modules/IsiXImaging/Sources/ViewerReconstruction/VolumeRenderingOpening.swift'
KEY = 'Ambient: %1$@\nDiffuse: %2$@\nSpecular: %3$@/%4$@'
FORMER_KEYS = ('Ambient: %2.1f\nDiffuse: %2.1f\nSpecular :%2.1f-%2.1f',
               'Ambient: %2.2f\nDiffuse: %2.2f\nSpecular :%2.2f, %2.2f')
LANGUAGES = ['en', 'pt-BR', 'de', 'fr', 'es', 'it-IT', 'ja-JP', 'ko', 'zh-Hans', 'ru', 'hi', 'ar']
# The languages with copies of the nibs; Spanish and Italian show the English ones.
NIB_LANGUAGES = [language for language in LANGUAGES if language not in ('es', 'it-IT')]
# A region of each language, and the separator its numbers take there.
REGIONS = {'en': 'en_US', 'pt-BR': 'pt_BR', 'de': 'de_DE', 'fr': 'fr_FR', 'es': 'es_ES', 'it-IT': 'it_IT',
           'ja-JP': 'ja_JP', 'ko': 'ko_KR', 'zh-Hans': 'zh_CN', 'ru': 'ru_RU', 'hi': 'hi_IN', 'ar': 'ar_SA'}
COMMA = {'pt_BR', 'de_DE', 'fr_FR', 'es_ES', 'it_IT', 'ru_RU', 'en_DE'}
POINT = {'en_US', 'ja_JP', 'ko_KR', 'zh_CN', 'hi_IN'}
# The shading panel's keys, as its fields and sliders bind them.
PANEL_KEYS = ('ambient', 'diffuse', 'specular', 'specularPower')


def read_bytes(path):
    if revision:
        result = subprocess.run(['git', '-C', str(root), 'show', f'{revision}:{path}'], capture_output=True)
        return result.stdout if result.returncode == 0 else None
    file = root / path
    return file.read_bytes() if file.exists() else None


def read(path):
    data = read_bytes(path)
    # A few Objective-C files are in Mac Roman; the keys sought are ASCII.
    return data.decode('utf-8', errors='replace') if data is not None else ''


def read_all(pattern):
    if revision:
        names = subprocess.check_output(['git', '-C', str(root), 'ls-tree', '--name-only', revision,
                                         'Horos/Sources/']).decode().split()
    else:
        names = [str(p.relative_to(root)) for p in (root / 'Horos/Sources').iterdir() if p.is_file()]
    return ''.join(read(name) for name in sorted(names) if re.fullmatch(pattern, name))


def method(text, signature):
    match = re.search(re.escape(signature) + r'.*?\n    }\n', text, re.S)
    return match.group(0) if match else ''


def code(text):
    """The text without its comments."""
    return re.sub(r'//[^\n]*', '', text)


def catalog(language, folder):
    data = read_bytes(f'Horos/Resources/{language}.lproj/Localizable.strings')
    if data is None:
        return {}
    copy = Path(folder) / f'{language}.strings'
    copy.write_bytes(data)
    return json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(copy)]))


def nib(language, name):
    """The language's copy of the nib, or the English one it shows without one."""
    return read(f'Horos/Resources/{language}.lproj/{name}.xib') or read(f'Horos/Resources/en.lproj/{name}.xib')


def element(text, tag, identifier):
    match = re.search(r'<%s [^>]*id="%s"[^>]*>.*?</%s>' % (tag, re.escape(identifier), tag), text, re.S)
    return match.group(0) if match else ''


def outlet(text, name):
    match = re.search(r'<outlet property="%s" destination="([^"]+)"' % name, text)
    return match.group(1) if match else None


def checkbox_title(text):
    """The title of the nib's Shading check box (the shadingCheck outlet)."""
    identifier = outlet(text, 'shadingCheck')
    match = identifier and re.search(r'<button [^>]*id="%s">.*?<buttonCell [^>]*title="([^"]*)"'
                                     % re.escape(identifier), text, re.S)
    return match.group(1) if match else None


def number(pattern, text, last=False):
    """The first match's number, or the last's: a view's own constraints
    follow those of its subviews."""
    found = re.findall(pattern, text)
    return float(found[-1 if last else 0]) if found else None


def own_constraints(view):
    """The constraints a view holds itself (the last block of its element,
    after those of its subviews), as dictionaries of their attributes."""
    blocks = re.findall(r'<constraints>(.*?)</constraints>', view, re.S)
    return [dict(re.findall(r'(\w+)="([^"]*)"', constraint))
            for constraint in re.findall(r'<constraint [^>]*/>', blocks[-1])] if blocks else []


def offset(constraints, holder, first, first_attribute, second, second_attribute):
    """The constant c of first.first_attribute = second.second_attribute + c
    (or at least that), from the constraint that relates them in either
    order; an item a constraint leaves out is the view that holds it."""
    for constraint in constraints:
        items = (constraint.get('firstItem', holder), constraint.get('firstAttribute'),
                 constraint.get('secondItem', holder), constraint.get('secondAttribute'))
        constant = float(constraint.get('constant', 0))
        if items == (first, first_attribute, second, second_attribute):
            return constant
        if items == (second, second_attribute, first, first_attribute):
            return -constant
    return None


def beside(text, tag, checkbox, field):
    """The room Auto Layout leaves the field beside the check box, read from
    the constraints of the innermost view of the tag that holds both: its
    width less the check box's inset, the field's inset and the least gap
    between them (the driver takes off the check box's own width). None when
    the nib lacks one of them."""
    holder, view = None, ''
    for match in re.finditer(r'<%s [^>]*id="([^"]+)"' % tag, text):
        candidate = element(text, tag, match.group(1))
        if f'id="{checkbox}"' in candidate and f'id="{field}"' in candidate:
            holder, view = match.group(1), candidate
    if holder is None:
        return None
    own = own_constraints(view)
    if tag == 'box':
        # The constraints to a box's edges lie on its content area, inside
        # its border.
        width = number(r'<view key="contentView"[^>]*>\s*<rect key="frame" x="[^"]+" y="[^"]+" width="([\d.]+)"', view)
    else:
        widths = [float(c['constant']) for c in own if c.get('firstAttribute') == 'width'
                  and 'firstItem' not in c and 'secondItem' not in c]
        width = widths[0] if widths else number(r'<rect key="frame" x="[^"]+" y="[^"]+" width="([\d.]+)"', view)
    insets = (offset(own, holder, checkbox, 'leading', holder, 'leading'),
              offset(own, holder, holder, 'trailing', field, 'trailing'),
              offset(own, holder, field, 'leading', checkbox, 'trailing'))
    return None if width is None or None in insets else width - sum(insets)


def windows(language):
    """Where each window writes the text in the language's nibs: the room it
    has (less the check box's width when the check box shares it), the
    field's height, and whether the field is placed by its frame. None for
    what a nib lacks."""
    result = []
    vr = nib(language, 'VR')
    field = element(vr, 'textField', outlet(vr, 'shadingValues') or '-')
    result.append({'name': 'VR', 'checkbox': checkbox_title(vr), 'frame': False,
                   'base': beside(vr, 'box', outlet(vr, 'shadingCheck') or '-', outlet(vr, 'shadingValues') or '-'),
                   'height': number(r'<constraint firstAttribute="height" constant="([\d.]+)"', field)})
    endoscopy = nib(language, 'Endoscopy')
    view = element(endoscopy, 'customView', outlet(endoscopy, 'shadingView') or '-')
    field = outlet(endoscopy, 'shadingValues') or '-'
    height = number(r'<constraint firstAttribute="height" constant="([\d.]+)"', view, last=True)
    top = number(r'<constraint firstItem="%s" firstAttribute="top" secondItem="[^"]+" secondAttribute="top" '
                 r'constant="([\d.]+)"' % re.escape(field), view)
    centred = re.search(r'<constraint firstItem="%s" firstAttribute="centerY"' % re.escape(field), view)
    # The field's top and centre fix its height.
    result.append({'name': 'Endoscopy', 'checkbox': checkbox_title(endoscopy), 'frame': False,
                   'base': beside(endoscopy, 'customView', outlet(endoscopy, 'shadingCheck') or '-', field),
                   'height': height - 2 * top if height and top is not None and centred else None})
    mpr = nib(language, 'MPR')
    field = element(mpr, 'textField', outlet(mpr, 'shadingValues') or '-')
    frame = re.search(r'<rect key="frame" x="[^"]+" y="[^"]+" width="([\d.]+)" height="([\d.]+)"/>', field)
    # Frames without constraints: the field's own frame, beside a check box
    # of fixed width.
    result.append({'name': 'MPR', 'checkbox': None, 'frame': True, 'base': float(frame.group(1)) if frame else None,
                   'height': float(frame.group(2)) if frame else None})
    return result


def bindings(value):
    return sorted(re.findall(r'%(?:(\d+)\$)?[-+#0 ]*\d*(?:\.\d+)?[@dfs]', value))


if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc)', file=sys.stderr)
    sys.exit(SKIPPED)

failures = []
controller = read_all(r'Horos/Sources/VRController(\+\w+)?\.swift')
endoscopy = read('Horos/Sources/EndoscopyVRController.swift')
mpr = read('Horos/Sources/MPRController.swift')
if not controller or not endoscopy or not mpr:
    print('FAIL: a 3D window is missing')
    sys.exit(1)

DRIVER = r'''
import AppKit

let opening = VolumeRenderingOpening.shadingValues
// The text as the windows ask for it, with no locale: the region the process
// runs with (-AppleLocale), which must decide the separator.
if CommandLine.arguments[1] == "--default" {
    print(ShadingValuesText.string(opening, template: CommandLine.arguments[2]))
    exit(0)
}

struct Window: Decodable { let name: String; let checkbox: String?; let frame: Bool; let base: Double?; let height: Double? }
struct Case: Decodable { let language: String; let template: String; let windows: [Window]; let locales: [String] }
let input = try! JSONDecoder().decode([Case].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
let glossyBone = VolumeRenderingOpening.ShadingValues(ambient: 0.15, diffuse: 0.24, specular: 1.17, specularPower: 6.98)
let mini = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .mini))

/// The widest number from 0 to `maximum` with two decimals in `locale`: the
/// system font's digits are not all as wide.
@MainActor func widest(_ maximum: Int, _ locale: Locale) -> Float {
    (0...maximum * 100).map { hundredths -> (Float, CGFloat) in
        let value = Float(hundredths) / 100
        return (value, (ShadingValuesText.number(value, locale: locale) as NSString).size(withAttributes: [.font: mini]).width)
    }.max { $0.1 < $1.1 }!.0
}

/// The lowest row of the field's drawing that has ink, from the top.
@MainActor func lowestInk(_ text: String, height: Double) -> Int {
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: height))
    field.isBezeled = false
    field.isBordered = false
    field.drawsBackground = false
    field.isEditable = false
    field.alignment = .right
    field.font = mini
    field.stringValue = text
    let image = field.bitmapImageRepForCachingDisplay(in: field.bounds)!
    field.cacheDisplay(in: field.bounds, to: image)
    var lowest = -1
    for y in 0..<image.pixelsHigh where (0..<image.pixelsWide).contains(where: { (image.colorAt(x: $0, y: y)?.alphaComponent ?? 0) > 0.05 }) {
        lowest = y
    }
    return lowest
}

var output: [[String: String]] = []
var widestValues: [String: VolumeRenderingOpening.ShadingValues] = [:]
MainActor.assumeIsolated {
    for item in input {
        for identifier in item.locales {
            let locale = Locale(identifier: identifier)
            let values = widestValues[identifier] ?? VolumeRenderingOpening.ShadingValues(
                ambient: widest(1, locale), diffuse: widest(1, locale), specular: widest(4, locale), specularPower: widest(50, locale))
            widestValues[identifier] = values
            let text = ShadingValuesText.string(values, template: item.template, locale: locale)
            let field = NSTextField(frame: .zero)
            field.isBezeled = false
            field.isBordered = false
            field.drawsBackground = false
            field.isEditable = false
            field.cell?.isScrollable = true
            field.cell?.lineBreakMode = .byClipping
            field.alignment = .right
            field.font = mini
            field.stringValue = text
            // Auto Layout places a field by its alignment rectangle, the text's
            // own width; a field placed by its frame also holds the margin its
            // cell keeps on each side.
            let width = field.intrinsicContentSize.width
            let frameWidth = field.frame(forAlignmentRect: NSRect(origin: .zero, size: field.intrinsicContentSize)).width
            var result = ["language": item.language, "locale": identifier,
                          "opening": ShadingValuesText.string(opening, template: item.template, locale: locale),
                          "preset": ShadingValuesText.string(glossyBone, template: item.template, locale: locale),
                          "widest": text]
            for window in item.windows {
                guard let base = window.base else { continue }
                var room = base
                if let title = window.checkbox {
                    let box = NSButton(checkboxWithTitle: title, target: nil, action: nil)
                    box.controlSize = .small
                    box.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
                    room -= box.intrinsicContentSize.width
                }
                result["room " + window.name] = String(room)
                result["need " + window.name] = String(Double(window.frame ? frameWidth : width))
            }
            output.append(result)
        }
        // The text's lowest marks in each window's field, against a field
        // with room to spare below them.
        let text = ShadingValuesText.string(opening, template: item.template, locale: Locale(identifier: item.locales[0]))
        let free = lowestInk(text, height: 80)
        for window in item.windows {
            guard let height = window.height else { continue }
            output.append(["language": item.language, "window": window.name, "height": String(height),
                           "lowest": String(lowestInk(text, height: height)), "free": String(free)])
        }
    }
}
print(String(decoding: try! JSONSerialization.data(withJSONObject: output), as: UTF8.self))
'''

with tempfile.TemporaryDirectory(prefix='horos-vr-shading-') as directory:
    p = Path(directory)
    catalogs = {language: catalog(language, p) for language in LANGUAGES}

    # 3. The catalogs.
    for language in LANGUAGES:
        for former in FORMER_KEYS:
            if former in catalogs[language]:
                failures.append(f'{language}: the catalog keeps the former key {former!r}')
        value = catalogs[language].get(KEY)
        if value is None:
            failures.append(f'{language}: the catalog lacks the shading values\' text')
            continue
        if bindings(value) != ['1', '2', '3', '4'] or value.count('%') != 4:
            failures.append(f'{language}: the four numbers once each, as %1$@ to %4$@: {value!r}')
        if value.count('\n') != 2:
            failures.append(f'{language}: three lines: {value!r}')
        if language != 'en':
            english = re.findall(r'\b(?:Ambient|Diffuse|Specular)\b', value)
            if english:
                failures.append(f'{language}: in English ({", ".join(english)}): {value!r}')
        if language != 'fr' and re.search(r'\S :', value):
            failures.append(f'{language}: a space before a colon: {value!r}')

    # 1. The text, compiled as it is.
    text, opening = read(TEXT), read(OPENING)
    templates = {language: catalogs[language].get(KEY) for language in LANGUAGES}
    places = {language: windows(language) for language in LANGUAGES}
    for language in LANGUAGES:
        for window in places[language]:
            if window['base'] is None or window['height'] is None:
                failures.append(f'{language} {window["name"]}: the nib\'s shading field is not where the test reads it')
    if not text or not opening:
        failures.append(f'{TEXT}: the text of the shading values is missing')
    elif None in templates.values():
        failures.append('the text of the shading values: not checked without every catalog\'s text')
    else:
        cases = []
        for language in LANGUAGES:
            # The language's region first, and both separators with Latin digits, for the width.
            locales = [REGIONS[language]] + sorted({'en_US', 'de_DE'} - {REGIONS[language]})
            if language == 'en':
                locales.append('en_DE')
            cases.append({'language': language, 'template': templates[language],
                          'windows': places[language], 'locales': locales})
        (p / 'cases.json').write_text(json.dumps(cases))
        (p / 'ShadingValuesText.swift').write_text(text)
        (p / 'VolumeRenderingOpening.swift').write_text(opening)
        (p / 'main.swift').write_text(DRIVER)
        built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', str(p / 'VolumeRenderingOpening.swift'),
                                str(p / 'ShadingValuesText.swift'), str(p / 'main.swift'), '-o', str(p / 'test')],
                               capture_output=True, text=True)
        if built.returncode != 0:
            failures.append('the text does not compile on its own:\n' + built.stderr[-2000:])
        else:
            ran = subprocess.run([str(p / 'test'), str(p / 'cases.json')], capture_output=True, text=True, timeout=300)
            if ran.returncode != 0:
                failures.append('the driver: ' + (ran.stderr.strip()[-800:] or 'failed'))
            else:
                results = json.loads(ran.stdout)
                pairs = 0
                for result in results:
                    language = result['language']
                    if 'window' in result:
                        if result['lowest'] != result['free']:
                            failures.append(f'{language} {result["window"]}: the lowest marks need row {result["free"]}, '
                                            f'the {float(result["height"]):.0f}-point field ends them at row {result["lowest"]}')
                        continue
                    pairs += 1
                    locale = result['locale']
                    if language == 'en' and locale == 'en_US':
                        if result['opening'] != 'Ambient: 0.15\nDiffuse: 0.90\nSpecular: 0.30/15.00':
                            failures.append(f'the opening\'s values in English: {result["opening"]!r}')
                        if result['preset'] != 'Ambient: 0.15\nDiffuse: 0.24\nSpecular: 1.17/6.98':
                            failures.append(f'a preset as it is written, in English: {result["preset"]!r}')
                    separator = ',' if locale in COMMA else '.' if locale in POINT else None
                    if separator:
                        numbers = re.findall(r'\d+[.,]\d+', result['opening'] + '\n' + result['preset'])
                        expected = [n.replace('.', separator) for n in
                                    ['0.15', '0.90', '0.30', '15.00', '0.15', '0.24', '1.17', '6.98']]
                        if numbers != expected:
                            failures.append(f'{language} in {locale}: two decimals and «{separator}»: {numbers}')
                    elif '٠٫١٥' not in result['opening']:
                        failures.append(f'{language} in {locale}: the region\'s digits and separator: {result["opening"]!r}')
                    if result['opening'].count('\n') != 2:
                        failures.append(f'{language} in {locale}: three lines: {result["opening"]!r}')
                    for name in ('VR', 'Endoscopy', 'MPR'):
                        room, need = result.get('room ' + name), result.get('need ' + name)
                        if room is not None and float(need) > float(room):
                            failures.append(f'{language} in {locale}, {name}: {result["widest"]!r} needs {float(need):.1f} '
                                            f'points, {float(room):.1f} fit there')
                print(f'the text checked in {pairs} language and region pairs, in the VR, endoscopy and MPR fields')
            # Without a locale the text takes the region the process runs
            # with; the user's own number symbols (AppleICUNumberSymbols)
            # are emptied so that the region alone decides.
            for region, expected in (('de_DE', 'Ambient: 0,15\nDiffuse: 0,90\nSpecular: 0,30/15,00'),
                                     ('en_US', 'Ambient: 0.15\nDiffuse: 0.90\nSpecular: 0.30/15.00')):
                ran = subprocess.run([str(p / 'test'), '--default', KEY, '-AppleLocale', region,
                                      '-AppleICUNumberSymbols', '{}'], capture_output=True, text=True, timeout=60)
                if ran.returncode != 0 or ran.stdout.rstrip('\n') != expected:
                    failures.append(f'without a locale, the text in {region} takes that region\'s separator: '
                                    f'{(ran.stdout or ran.stderr).strip()!r}')

# 2. The windows.
# The catalog's text, read in one place, in the user's region.
sources = code(read_all(r'Horos/Sources/.*\.(?:swift|m|mm)'))
reads = sources.count(f'NSLocalizedString({json.dumps(KEY)}')
localized = code(method(read_all(r'Horos/Sources/.*\.swift'),
                        '    static func localized(_ values: VolumeRenderingOpening.ShadingValues) -> String {'))
if reads != 1 or not re.search(r'\bstring\(values, template: NSLocalizedString\(%s,\s*comment: "[^"]*"\)\)'
                               % re.escape(json.dumps(KEY)), localized) \
        or not re.search(r'extension ShadingValuesText \{\s*static func localized\(', sources):
    failures.append(f'the catalog\'s text is read in one place, ShadingValuesText.localized, with no locale '
                    f'({reads} reads)')
for former in FORMER_KEYS:
    if json.dumps(former) in sources:
        failures.append(f'the sources still read the former key {former!r}')

# Every use of the field (the outlet, not VolumeRenderingOpening.shadingValues)
# other than its declaration: one that sets its value, or one that hands the
# field elsewhere (bound to another name or passed on), where its text could be
# set without the field's name, is a writer.
OUTLET = re.compile(r'(?:(?<![\w.])|(?<=\bself\.))shadingValues\b')
SETS_VALUE = re.compile(r'\s*[?!]?\s*\.\s*(?:(?:(?:attributed)?[sS]tringValue|objectValue|(?:integer|int|double|float)Value'
                        r'|placeholder(?:String|AttributedString))\s*=(?!=)|set\w*Value\b|take\w+ValueFrom\b|setValue\b)')
MEMBER = re.compile(r'\s*[?!]?\s*\.\s*\w')
DECLARATION = re.compile(r'\b(?:var|let)\s+shadingValues\s*:')


def writers(text):
    source = code(text)
    found = []
    for use in OUTLET.finditer(source):
        start, end = source.rfind('\n', 0, use.start()) + 1, source.find('\n', use.end())
        line = source[start:end].strip()
        if DECLARATION.search(line):
            continue
        rest = source[use.end():]
        if SETS_VALUE.match(rest) or not MEMBER.match(rest):
            found.append(line)
    return found


show = code(method(controller, '    final func horosShowShadingValues(_ values: VolumeRenderingOpening.ShadingValues) {'))
written = 'shadingValues?.stringValue = ShadingValuesText.localized(values)'
if writers(controller) != [written] or written not in show:
    failures.append(f'VR: one place writes the shading values field, through ShadingValuesText.localized: '
                    f'{writers(controller)}')
mpr_show = code(method(mpr, '    private func horosShowShadingValues() {'))
mpr_written = ('shadingValues?.stringValue = ShadingValuesText.localized(.init(ambient: ambient, diffuse: diffuse, '
               'specular: specular, specularPower: specularpower))')
# The Shadings item's layout is handed the field to place it, and writes nothing in it.
mpr_layout = 'MPRShadingItemLayout.fill(toolbarItem, view: tbShading, check: shadingCheck, values: shadingValues, widestText: widest)'
if 'stringValue =' in code((root / 'Horos/Sources/MPRToolbarItemViews.swift').read_text(encoding='utf-8').split('enum MPRShadingItemLayout')[1]):
    failures.append('the layout of the MPR\'s Shadings item writes in a field')
if [line for line in writers(mpr) if line != mpr_layout] != [mpr_written] or not re.search(
        r'hiddenVRView\?\.getShadingValues\(&ambient, &diffuse, &specular, &specularpower\)\s*\n\s*'
        + re.escape(mpr_written), mpr_show):
    failures.append(f'MPR: one place writes the shading values field, the hidden view\'s values through '
                    f'ShadingValuesText.localized: {writers(mpr)}')
if writers(endoscopy):
    failures.append(f'the endoscopy writes the shading values field itself: {writers(endoscopy)}')
for name, text in (('VR', controller), ('the endoscopy', endoscopy), ('MPR', mpr)):
    if 'Specular :' in code(text):
        failures.append(f'{name} still writes «Specular :»')

shading = code(method(controller, '    private func horosShowShading() {'))
if not re.search(r'vrView\?\.getShadingValues\(&ambient, &diffuse, &specular, &specularpower\)\s*\n\s*'
                 r'horosShowShadingValues\(\.init\(ambient: ambient, diffuse: diffuse, specular: specular, '
                 r'specularPower: specularpower\)\)', shading):
    failures.append('the opening and Revert Series write the view\'s shading values through -horosShowShadingValues')
apply = code(method(controller, '    public override final func applyShading(_ sender: Any!) {'))
if not re.search(r'vrView\?\.setShadingValues\(ambient, diffuse, specular, specularpower\)\s*\n\s*'
                 r'horosShowShadingValues\(\.init\(ambient: ambient, diffuse: diffuse, specular: specular, '
                 r'specularPower: specularpower\)\)', apply):
    failures.append('a preset and a change in the shading panel write the values they give the view '
                    'through -horosShowShadingValues')
for signature in ('    private func applySavedState() {', '    final func restoreOpeningPresentation() {'):
    if 'horosShowShading()' not in code(method(controller, signature)):
        failures.append(f'{signature.strip()} shows the shading values')
load = code(method(endoscopy, '    public override func load3DState() {'))
if not re.search(r'view\?\.getShadingValues\(&ambient, &diffuse, &specular, &specularpower\)\s*\n\s*'
                 r'horosShowShadingValues\(\.init\(ambient: ambient, diffuse: diffuse, specular: specular, '
                 r'specularPower: specularpower\)\)', load):
    failures.append('the endoscopy\'s opening writes the view\'s shading values through -horosShowShadingValues')
mpr_apply = code(method(mpr, '    @IBAction public override dynamic func applyShading(_ sender: Any!) {'))
if not re.search(r'hiddenVRView\?\.setShadingValues\(ambient, diffuse, specular, specularpower\)\s*\n\s*'
                 r'horosShowShadingValues\(\)', mpr_apply):
    failures.append('MPR: a preset and a change in the shading panel show the hidden view\'s values')
initialize = code(method(mpr, '    private func initialize(pix:'))
made = initialize.find('hiddenVRView = messagesView(hiddenVRController?.view())')
if made < 0 or initialize.find('horosShowShadingValues()', made) < 0:
    failures.append('MPR: the opening shows the hidden view\'s shading values')
for language in NIB_LANGUAGES:
    text = read(f'Horos/Resources/{language}.lproj/MPR.xib')
    item = element(text, 'box', outlet(text, 'tbShading') or '-')
    field = outlet(text, 'shadingValues')
    if not field or not re.search(r'<textField [^>]*id="%s"' % re.escape(field), item):
        failures.append(f'{language} MPR.xib: the Shading item\'s field is not the shadingValues outlet')

# 4. The shading panel's fields take what their sliders give.
for language in NIB_LANGUAGES:
    for name in ('VR', 'Endoscopy', 'MPR'):
        text = read(f'Horos/Resources/{language}.lproj/{name}.xib')
        for key in PANEL_KEYS:
            bound = r'<binding [^>]*name="value" keyPath="selection\.%s"' % key
            sliders = [s for s in re.findall(r'<slider [^>]*>.*?</slider>', text, re.S) if re.search(bound, s)]
            fields = [f for f in re.findall(r'<textField [^>]*>.*?</textField>', text, re.S)
                      if re.search(bound, f) and '<numberFormatter' in f]
            if len(sliders) != 1 or len(fields) != 1:
                failures.append(f'{language} {name}.xib {key}: {len(sliders)} sliders, {len(fields)} fields')
                continue
            cell = re.search(r'<sliderCell [^>]*>', sliders[0]).group(0)
            low = number(r'minValue="([-\d.]+)"', cell) or 0.0
            high = number(r'maxValue="([-\d.]+)"', cell)
            minimum = number(r'<decimal key="minimum" value="([^"]+)"/>', fields[0])
            maximum = number(r'<decimal key="maximum" value="([^"]+)"/>', fields[0])
            if minimum != low or maximum != high:
                failures.append(f'{language} {name}.xib {key}: the field accepts {minimum} to {maximum}, '
                                f'the slider gives {low} to {high}')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
print('PASS: the VR, endoscopy and MPR windows write their shading values one way, two decimals with the '
      'region\'s separator, in every language, whole in their fields, and the panel accepts only the sliders\' range')
