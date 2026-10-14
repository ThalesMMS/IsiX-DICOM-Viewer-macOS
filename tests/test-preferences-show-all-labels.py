#!/usr/bin/env python3
"""Every label of the Preferences "Show All" view fits under its icon, in every language.

The view draws each pane's title in its column, wrapped at the column's width,
in the lines its label has room for. A word wider than the column is broken
inside the word: in Russian "Местоположе-ние" and "Маршрутизац-ия" showed on
two lines. Each title is measured here with the view's own font, column width
and label height, read from its sources, against every catalog's translation.
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

MEASURE = r'''
import AppKit
let width = CGFloat(Double(CommandLine.arguments[1])!)
let titles = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))) as! [String]
let style = NSParagraphStyle.default.mutableCopy() as! NSMutableParagraphStyle
style.alignment = .center
let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.labelFont(ofSize: NSFont.smallSystemFontSize), .paragraphStyle: style]
var results: [[String: Any]] = []
for title in titles {
    let height = (title as NSString).boundingRect(with: NSSize(width: width, height: 10000), options: [.usesLineFragmentOrigin],
                                                  attributes: attributes).height
    // A line may break at a space or after a hyphen.
    let words = title.replacingOccurrences(of: "-", with: "- ").split(whereSeparator: { $0.isWhitespace }).map { String($0) }
    let widest = words.map { ($0 as NSString).size(withAttributes: attributes).width }.max() ?? 0
    results.append(["title": title, "height": height, "widest": widest])
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

panes = re.findall(r'NSLocalizedString\("([^"]+)", comment: "Panel in preferences window"\)', CONTROLLER.read_text(encoding='utf-8'))
assert len(panes) >= 16, panes
view = VIEW.read_text(encoding='utf-8')
column, label = constant('colWidth', view), constant('labelHeight', view)

titles = {'en': panes}
for path in sorted((ROOT / 'Horos/Resources').glob('*.lproj/Localizable.strings')):
    language = path.parent.stem
    if language != 'en':
        values = catalog(path)
        titles[language] = [values.get(pane, pane) for pane in panes]

with tempfile.TemporaryDirectory(prefix='horos-show-all-') as folder:
    folder = Path(folder)
    (folder / 'main.swift').write_text(MEASURE)
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(folder / 'modules'), str(folder / 'main.swift'),
                    '-o', str(folder / 'measure')], check=True, capture_output=True)
    (folder / 'titles.json').write_text(json.dumps(sorted({title for values in titles.values() for title in values})))
    ran = subprocess.run([str(folder / 'measure'), str(column), str(folder / 'titles.json')],
                         capture_output=True, text=True, timeout=120, check=True)
    measured = {item['title']: item for item in json.loads(ran.stdout)}

failures = []
for language, values in titles.items():
    for pane, title in zip(panes, values):
        item = measured[title]
        if item['height'] > label:
            failures.append(f'{language}: "{title}" ({pane}) needs {item["height"]:.0f} points of height, the label has {label:.0f}')
        if language not in UNSPACED and item['widest'] > column:
            failures.append(f'{language}: a word of "{title}" ({pane}) needs {item["widest"]:.0f} points, the column has {column:.0f}')

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print(f'PASS: {len(panes)} pane labels fit the Show All view in {len(titles)} languages')
