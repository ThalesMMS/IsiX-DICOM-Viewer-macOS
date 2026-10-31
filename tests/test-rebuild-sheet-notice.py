#!/usr/bin/env python3
"""The sheet of the rebuild says that a complete rebuild undoes series split by hand.

A split series (`RP-` at the end of its identifier) exists only in the index, and
a complete rebuild groups the images by the series in their files: nothing is lost,
but the split goes. The sheet says so, under its two choices, in every language.

The sheet comes from MainMenu.xib of each language, with no room for a line whose
length depends on the language, so the line is added when the sheet is first shown,
sized from its text. This reads the frames of the sheet from each localized nib
and the text from each catalog, compiles addRebuildNotice from the source and runs
it on a window built from them: the whole text fits, nothing overlaps, what is under
the choices keeps its place above the bottom, what is above them its place under the
top, and a second showing adds nothing.

`<git revision>` as an optional argument reads the source of that revision, the
negative control.
"""
from pathlib import Path
import json
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401,E402  - its own TMPDIR for the tools it runs

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
SOURCE = 'Horos/Sources/BrowserController+DatabaseMaintenance.swift'
TRANSLATED = ('ar', 'de', 'es', 'fr', 'hi', 'it-IT', 'ja-JP', 'ko', 'pt-BR', 'ru', 'zh-Hans')
WINDOW = '14365'
CHOICES = '14380'
failures = []


def read():
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{SOURCE}']).decode('utf-8')
    return (root / SOURCE).read_text()


def catalog(language):
    raw = (root / ('Horos/Resources/%s.lproj/Localizable.strings' % language)).read_bytes()
    return raw.decode('utf-16' if raw[:2] in (b'\xff\xfe', b'\xfe\xff') else 'utf-8')


def translation(language, key):
    found = re.search(r'^"%s" = "(.*)";$' % re.escape(key), catalog(language), re.M)
    return found.group(1) if found else None


def sheet_of(language):
    """The size of the sheet's content and the frames of its views, from its nib."""
    xib = (root / ('Horos/Resources/%s.lproj/MainMenu.xib' % language)).read_text(encoding='utf-8')
    start = xib.index('id="%s"' % WINDOW)
    window = xib[start:xib.index('</window>', start)]
    size = re.search(r'contentRect" x="[-\d.]+" y="[-\d.]+" width="([\d.]+)" height="([\d.]+)"', window)
    views = []
    for tag, identifier, x, y, width, height in re.findall(
            r'<(textField|button|matrix|box|imageView)\b[^>]*\bid="([^"]+)"[^>]*>\s*<rect key="frame" x="([-\d.]+)" y="([-\d.]+)" width="([\d.]+)" height="([\d.]+)"', window):
        views.append({'id': identifier, 'frame': [float(x), float(y), float(width), float(height)]})
    return {'width': float(size.group(1)), 'height': float(size.group(2)), 'views': views}


source = read()
helper = re.search(r'^/// Adds `text` under the choices.*?^}\n', source, re.S | re.M)
called = re.search(r'addRebuildNotice\(NSLocalizedString\("((?:\\.|[^"\\])*)"', source)
if helper is None or called is None:
    print('FAIL: the sheet of the rebuild does not add the notice')
    sys.exit(1)
key = json.loads('"%s"' % called.group(1))
if 'by hand' not in key or 'complete rebuild' not in key.lower():
    failures.append('the text does not say that a complete rebuild undoes what was done by hand: %r' % key)

# -ReBuildDatabaseSheet: forwards to DatabaseMaintenance.showRebuildSheet(), in the same file.
sheet_method = re.search(r'    func showRebuildSheet\(.*?^    }\n', source, re.S | re.M)
begin = re.search(r'^private func beginRebuildSheet\(.*?^}\n', source, re.S | re.M)
if sheet_method is None or 'beginRebuildSheet(sheet, choices: browser.horos_rebuildType' not in sheet_method.group(0) or begin is None \
        or 'addRebuildNotice(' not in begin.group(0) or begin.group(0).index('addRebuildNotice(') > begin.group(0).index('beginSheet('):
    failures.append('the notice is not added before the sheet is shown')

languages = {}
for language in ('en',) + TRANSLATED:
    text = translation(language, key)
    if text is None:
        failures.append('%s: the catalog does not have the text' % language)
        continue
    if language != 'en' and text == key:
        failures.append('%s: the text is not translated' % language)
    languages[language] = dict(sheet_of(language), text=text)
    if not any(view['id'] == CHOICES for view in languages[language]['views']):
        failures.append('%s: the choices of the sheet are not where this test reads them' % language)

DRIVER = r"""
import AppKit

HELPER

func emit(_ key: String, _ value: String) { print("\(key)\t\(value)") }

struct View: Decodable { let id: String; let frame: [CGFloat] }
struct Sheet: Decodable { let width: CGFloat; let height: CGFloat; let views: [View]; let text: String }

let sheets = try! JSONDecoder().decode([String: Sheet].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))

MainActor.assumeIsolated {
    _ = NSApplication.shared
    for (language, sheet) in sheets {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: sheet.width, height: sheet.height), styleMask: [.titled], backing: .buffered, defer: true)
        var views: [String: NSView] = [:]
        for view in sheet.views {
            let made = NSView(frame: NSRect(x: view.frame[0], y: view.frame[1], width: view.frame[2], height: view.frame[3]))
            made.autoresizingMask = [.maxXMargin, .minYMargin] // as every view of this sheet in the nib
            window.contentView!.addSubview(made)
            views[view.id] = made
        }
        let content = window.contentView!
        let choices = views["14380"]!
        let before = sheet.views.map { (id: $0.id, frame: views[$0.id]!.frame) }
        addRebuildNotice(sheet.text, to: window, under: choices)
        let grown = content.bounds.height
        addRebuildNotice(sheet.text, to: window, under: choices)

        let notices = content.subviews.compactMap { $0 as? NSTextField }
        emit("\(language).notices", "\(notices.count)")
        emit("\(language).second showing", content.bounds.height == grown ? "no change" : "grew again")
        guard let notice = notices.first else { continue }

        let needed = notice.attributedStringValue.boundingRect(with: NSSize(width: notice.frame.width - 4, height: 10000), options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        emit("\(language).lines", "\(Int((needed / 13).rounded()))")
        emit("\(language).fits", notice.frame.height >= ceil(needed) ? "yes" : "no: \(notice.frame.height) for \(needed)")
        emit("\(language).inside", content.bounds.contains(notice.frame) ? "yes" : "no")
        var overlaps: [String] = []
        for (id, view) in views where view.frame.intersects(notice.frame) && id != "mx7-rd-lkR" { overlaps.append(id) }
        if views["mx7-rd-lkR"]!.frame.maxY > notice.frame.minY { overlaps.append("separator") }
        emit("\(language).overlaps", overlaps.joined(separator: ","))
        let grownBy = content.bounds.height - sheet.height
        var moved: [String] = []
        for (id, frame) in before {
            let now = views[id]!.frame
            let under = frame.maxY <= 108
            if now.minY != frame.minY + (under ? 0 : grownBy) || now.minX != frame.minX || now.size != frame.size { moved.append(id) }
        }
        emit("\(language).moved", moved.joined(separator: ","))
        emit("\(language).grew", grownBy > 0 && grownBy == notice.frame.height + 4 ? "by the notice" : "by \(grownBy)")
    }
}
emit("end", "reached")
"""

if languages:
    with tempfile.TemporaryDirectory(prefix='horos-rebuild-notice-') as directory:
        directory = Path(directory)
        (directory / 'sheets.json').write_text(json.dumps(languages))
        (directory / 'main.swift').write_text(DRIVER.replace('HELPER', helper.group(0).replace('private func', 'func')))
        binary = directory / 'rebuild-notice'
        built = subprocess.run(['xcrun', '--sdk', 'macosx', 'swiftc', '-suppress-warnings', '-o', str(binary), str(directory / 'main.swift')],
                               capture_output=True, text=True)
        if built.returncode != 0:
            print('FAIL: the notice does not compile:\n%s' % built.stderr[-2500:])
            sys.exit(1)
        run = subprocess.run([str(binary), str(directory / 'sheets.json')], capture_output=True, text=True, timeout=120)
        if run.returncode != 0:
            failures.append('the driver failed: %s' % run.stderr[-800:])
        results = dict(line.split('\t', 1) for line in run.stdout.splitlines() if '\t' in line)
    if results.get('end') != 'reached':
        failures.append('the driver did not reach its end')
    for language in languages:
        for field, want in (('notices', '1'), ('second showing', 'no change'), ('fits', 'yes'), ('inside', 'yes'),
                            ('overlaps', ''), ('moved', ''), ('grew', 'by the notice')):
            got = results.get('%s.%s' % (language, field))
            if got != want:
                failures.append('%s, %s: %r, expected %r' % (language, field, got, want))

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: the sheet of the rebuild says, in %d languages, that a complete rebuild undoes series split by hand, and the line fits each of them' % len(languages))
