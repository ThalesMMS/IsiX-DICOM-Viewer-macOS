#!/usr/bin/env python3
"""No title or table header of the main nib's windows is cut, in any language.

MainMenu.xib holds, beside the menu, the database window and the sheets it
opens: the password of a ZIP file or of a database, the name of an album, the
users a study is shared with or notified to, the rebuild of the database, the
choice among the series of a 4D acquisition. Their copies are generated from
the English nib with each catalog's texts (tools/localize-main-menu.py), in
the English geometry: a label, a checkbox or a button whose translation needs
more than the English frame is cut, "Sortieren nach:" in 45 points, and so is
the header of a column of the study list, "Anzahl der Serien" in 50.

Every copy is compiled and loaded without its bindings (tests/pane_titles.py):

- every title fits its control, by the rule of the preference panes' test: a
  label on one line may need 3 points more than its frame, a button, checkbox
  or radio button nothing more, a wrapped label fits its lines and its longest
  word, and two controls of one view do not overlap in what they draw;
- every header of a table column that is shown needs no more than the width
  the nib gives its column.
"""
from pathlib import Path
import json
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pane_titles  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / 'Horos/Resources'
LANGUAGES = ('en', 'ar', 'de', 'es', 'fr', 'hi', 'it-IT', 'ja-JP', 'ko', 'pt-BR', 'ru', 'zh-Hans')

HEADERS = r'''
import AppKit
final class Owner: NSObject {
    override func value(forUndefinedKey key: String) -> Any? { nil }
    override func setValue(_ value: Any?, forUndefinedKey key: String) {}
}
func tables(in view: NSView) -> [NSTableView] {
    view.subviews.compactMap { $0 as? NSTableView } + view.subviews.flatMap { tables(in: $0) }
}
var found: [[String: Any]] = []
for path in CommandLine.arguments.dropFirst() {
    let language = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    var objects: NSArray?
    let nib = NSNib(nibData: try! Data(contentsOf: URL(fileURLWithPath: path)), bundle: nil)
    guard nib.instantiate(withOwner: Owner(), topLevelObjects: &objects) else {
        found.append(["language": language, "error": "the nib did not load"]); continue
    }
    for window in (objects as? [Any] ?? []).compactMap({ $0 as? NSWindow }) {
        guard let content = window.contentView else { continue }
        for table in tables(in: content) {
            for column in table.tableColumns where !column.title.isEmpty && !column.isHidden {
                found.append(["language": language, "id": column.identifier.rawValue, "title": column.title,
                              "needed": column.headerCell.cellSize.width, "width": column.width])
            }
        }
    }
}
print(String(data: try! JSONSerialization.data(withJSONObject: found), encoding: .utf8)!)
'''

if not pane_titles.available():
    print('skipped: needs xcrun (swiftc, ibtool)', file=sys.stderr)
    sys.exit(2)

variants = {language: RESOURCES / f'{language}.lproj/MainMenu.xib' for language in LANGUAGES}
failures = [f'MainMenu.xib: no {language} copy' for language, path in variants.items() if not path.exists()]
variants = {language: path for language, path in variants.items() if path.exists()}

titles = pane_titles.measure(variants, every_window=True)
failures += pane_titles.misfits(titles)
measured = {item['language'] for item in titles if 'id' in item}
if measured != set(variants):
    failures.append(f'only {sorted(measured)} of the {len(variants)} copies were measured')

with tempfile.TemporaryDirectory(prefix='horos-main-menu-headers-') as folder:
    folder = Path(folder)
    nibs = []
    for language, path in variants.items():
        stripped = folder / f'{language}.xib'
        stripped.write_text(pane_titles.BINDING.sub('', path.read_text(encoding='utf-8')), encoding='utf-8')
        nib = folder / f'{language}.nib'
        built = subprocess.run(['xcrun', 'ibtool', '--compile', str(nib), str(stripped)], capture_output=True, text=True)
        if built.returncode or not nib.exists():
            sys.exit(f'{language}: MainMenu.xib does not compile\n{built.stdout[-600:]}{built.stderr[-600:]}')
        nibs.append(str(nib))
    (folder / 'main.swift').write_text(HEADERS)
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(folder / 'modules'), str(folder / 'main.swift'),
                    '-o', str(folder / 'headers')], check=True, capture_output=True)
    headers = json.loads(subprocess.run([str(folder / 'headers'), *nibs], capture_output=True, text=True, timeout=300,
                                        check=True).stdout)
for header in headers:
    if 'error' in header:
        failures.append(f'{header["language"]}: {header["error"]}')
    elif header['needed'] > header['width'] + 0.5:
        failures.append(f'{header["language"]}: the header "{header["title"]}" needs {header["needed"]:.0f} points, '
                        f'its column ({header["id"]}) has {header["width"]:.0f}')
if len(headers) < 30 * len(variants):
    failures.append(f'only {len(headers)} table headers were found in {len(variants)} copies')

if failures:
    for failure in failures[:60]:
        print('FAIL: ' + failure)
    sys.exit(f'{len(failures)} titles or headers of the main nib are cut')
print(f'PASS: {len([item for item in titles if "id" in item])} titles and {len(headers)} table headers of the main nib\'s windows '
      f'fit in {len(variants)} languages')
