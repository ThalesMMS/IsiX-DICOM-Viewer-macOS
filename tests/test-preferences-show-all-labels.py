#!/usr/bin/env python3
"""Every label of the Preferences "Show All" view fits under its icon, in every language.

The view draws each pane's title in its column, wrapped at the column's width,
in the lines its label has room for. A word wider than the column is broken
inside the word: in Russian "Местоположе-ние" and "Маршрутизац-ия" showed on
two lines. A title that needs three lines loses its third: in Spanish
"Disposición de las anotaciones" showed "Disposición de" and "las". The view
gives each column the width its titles need to take at most two lines, as
System Settings shows them, with no word broken.

PreferencesView is compiled from its source and laid out with the pane titles
of every catalog, in the groups the settings window gives them; each title is
then measured here, with the view's font, at the width of its own button,
against the label's height and two lines.
"""
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONTROLLER = ROOT / 'Horos/Sources/PreferencesWindowController.swift'
VIEW = ROOT / 'Horos/Sources/PreferencesView.swift'
# Scripts written without spaces break between any two characters; only their line count matters.
UNSPACED = {'ja-JP', 'zh-Hans'}

LAYOUT = r'''
import AppKit
// What PreferencesView.swift takes from the application.
final class PreferencesWindowContext: NSObject { @objc var parentBundle: Bundle? }
extension NSImage { @objc func shadowImage() -> NSImage { self } }

let style = NSParagraphStyle.default.mutableCopy() as! NSMutableParagraphStyle
style.alignment = .center
let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.labelFont(ofSize: NSFont.smallSystemFontSize), .paragraphStyle: style]
let languages = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: [[String]]]
var results: [[String: Any]] = []
MainActor.assumeIsolated {
    for (language, groups) in languages {
        let view = PreferencesView(frame: .zero)
        for group in groups {
            for title in group.dropFirst() { view.addItem(withTitle: title, image: nil, toGroupWithName: group[0], context: nil) }
        }
        view.layout()
        let oneLine = ("X" as NSString).boundingRect(with: NSSize(width: 1000, height: 1000), options: [.usesLineFragmentOrigin], attributes: attributes).height
        for case let button as NSButton in view.subviews {
            let width = button.frame.width
            let height = (button.title as NSString).boundingRect(with: NSSize(width: width, height: 10000), options: [.usesLineFragmentOrigin],
                                                                 attributes: attributes).height
            // A line may break at a space or after a hyphen.
            let words = button.title.replacingOccurrences(of: "-", with: "- ").split(whereSeparator: { $0.isWhitespace }).map { String($0) }
            let widest = words.map { ($0 as NSString).size(withAttributes: attributes).width }.max() ?? 0
            results.append(["language": language, "title": button.title, "width": width, "height": height, "lines": height / oneLine,
                            "widest": widest, "x": button.frame.minX, "y": button.frame.minY, "viewWidth": view.frame.width])
        }
    }
}
print(String(data: try! JSONSerialization.data(withJSONObject: results), encoding: .utf8)!)
'''


def catalog(path):
    raw = path.read_bytes()
    text = raw.decode('utf-16') if raw[:2] in (b'\xff\xfe', b'\xfe\xff') else raw.decode('utf-8')
    unescape = lambda value: value.replace('\\"', '"').replace('\\n', '\n').replace('\\\\', '\\')
    return {unescape(key): unescape(value) for key, value in re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";', text, re.M)}


def constant(name, source):
    return float(re.search(r'static let %s: CGFloat = ([\d.]+)' % name, source).group(1))


if not shutil.which('xcrun'):
    print('skipped: needs xcrun (swiftc)', file=sys.stderr)
    sys.exit(2)

# The panes in their groups, as the settings window adds them: a group's name, then its panes' titles.
controller = CONTROLLER.read_text(encoding='utf-8')
groups = []
for match in re.finditer(r'name = NSLocalizedString\("([^"]+)", comment: "Section in preferences window"\)'
                         r'|withTitle: NSLocalizedString\("([^"]+)", comment: "Panel in preferences window[^"]*"\)', controller):
    if match.group(1):
        groups.append([match.group(1)])
    elif groups:
        groups[-1].append(match.group(2))
panes = [title for group in groups for title in group[1:]]
assert len(groups) >= 3 and len(panes) >= 20 and 'Annotation Layout' in panes, groups
view = VIEW.read_text(encoding='utf-8')
label = constant('labelHeight', view)

languages = {'en': groups}
for path in sorted((ROOT / 'Horos/Resources').glob('*.lproj/Localizable.strings')):
    language = path.parent.stem
    if language != 'en':
        values = catalog(path)
        languages[language] = [[values.get(text, text) for text in group] for group in groups]

with tempfile.TemporaryDirectory(prefix='horos-show-all-') as folder:
    folder = Path(folder)
    (folder / 'main.swift').write_text(LAYOUT)
    shutil.copy(VIEW, folder / 'PreferencesView.swift')
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-module-cache-path', str(folder / 'modules'),
                            str(folder / 'main.swift'), str(folder / 'PreferencesView.swift'), '-o', str(folder / 'layout')],
                           capture_output=True, text=True)
    if built.returncode:
        print('FAIL: PreferencesView does not compile with the layout harness\n' + built.stderr[-2000:])
        sys.exit(1)
    (folder / 'titles.json').write_text(json.dumps(languages))
    ran = subprocess.run([str(folder / 'layout'), str(folder / 'titles.json')], capture_output=True, text=True, timeout=120, check=True)
    measured = json.loads(ran.stdout)

failures = []
for language in languages:
    found = [item for item in measured if item['language'] == language]
    if len(found) != len(panes):
        failures.append(f'{language}: {len(found)} panes laid out, {len(panes)} expected')
for item in measured:
    language, title, width = item['language'], item['title'], item['width']
    if item['height'] > label or item['lines'] > 2.01:
        failures.append(f'{language}: "{title}" needs {item["height"]:.0f} points of height ({item["lines"]:.1f} lines) in its '
                        f'column of {width:.0f}; the label has {label:.0f} and shows two lines')
    if language not in UNSPACED and item['widest'] > width:
        failures.append(f'{language}: a word of "{title}" needs {item["widest"]:.0f} points, its column has {width:.0f}')
# Buttons of a row side by side, in one grid: a column has one x in every row.
for language in languages:
    columns = {}
    for item in measured:
        if item['language'] == language:
            columns.setdefault(item['y'], []).append((item['x'], item['width']))
    rows = [sorted(row) for row in columns.values()]
    for row in rows:
        for (x, width), (next_x, _) in zip(row, row[1:]):
            if x + width > next_x:
                failures.append(f'{language}: two panes overlap in a row of the Show All view')
    for index in range(max((len(row) for row in rows), default=0)):
        if len({row[index][0] for row in rows if index < len(row)}) > 1:
            failures.append(f'{language}: column {index} of the Show All view does not line up across its rows')

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print(f'PASS: {len(panes)} pane labels fit the Show All view in {len(languages)} languages, in two lines at most')
