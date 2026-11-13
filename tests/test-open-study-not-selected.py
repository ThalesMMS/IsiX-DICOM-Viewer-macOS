#!/usr/bin/env python3
"""A study opened while another row is selected opens its own series.

-databaseOpenStudy: is sent for the selected row by a double click, and for any
study by the viewers (a Command-click on a study of the series list), the
menus and the plugins. With one series to open, the opening took the series
from the thumbnails, which are those of the row selected in the list: asked
for study B while study A was selected, it opened A again.

The thumbnails now stand for the line to open only when it is of their study;
a line of another study opens by itself. ViewerOpener.swift is read as it is:

- text: the lists to open are taken from the lines, not from the thumbnails,
  when the thumbnails are of another study; the study of the thumbnails is read
  from the series or the image they show.
- rule: ViewerOpener.thumbnailsStand, taken as it is and compiled: the same
  study, or a study that is not known on either side, is the thumbnails'; another
  study is not.

`<git revision>` as an optional argument reads the source from that revision,
the negative control.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
OPENER = 'Horos/Sources/ViewerOpener.swift'


def source(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode()
    return (root / path).read_text(encoding='utf-8')


def fail(message):
    print('FAIL:', message)
    sys.exit(1)


def function(text, signature):
    """The text of the Swift method with that signature, up to the next method or mark."""
    start = text.find(signature)
    if start < 0:
        fail(f'{signature.strip()} not found in {OPENER}')
    following = re.search(r'\n    (?:///|// MARK:|(?:(?:private|nonisolated|static|@\w+) )*func )', text[start + len(signature):])
    return text[start:start + len(signature) + following.start() if following else len(text)]


opener = source(OPENER)
opening = function(opener, '    func open(_ selectedLines: [Any]?, movie movieViewer: Bool, viewer: ViewerController?, tileWindows: Bool = true,')
opening = '\n'.join(line for line in opening.splitlines() if not line.strip().startswith('//'))

if 'Self.thumbnailsStand(forLineOf: (study as? NSManagedObject)?.objectID, thumbnailsOf: thumbnailsStudy?.objectID)' not in opening:
    fail('the opening does not ask whether the thumbnails are of the study of the line to open')
if 'let thumbnailsStudy = (matrixViewArray.first as? DicomSeries)?.study ?? (matrixViewArray.first as? DicomImage)?.series?.study' not in opening:
    fail('the study of the thumbnails is not read from the series or the image they show')
lines = 'if (cells.count == 1 && selectedLines.count > 1) || !ofThumbnails {'
if lines not in opening:
    fail('a line of another study than the thumbnails\' still opens what the thumbnails show')
branch = opening[opening.index(lines):]
from_lines, from_thumbnails = branch[:branch.index('} else {')], branch[branch.index('} else {'):]
if 'for line in selectedLines {' not in from_lines or 'matrixViewArray' in from_lines:
    fail('the lines of another study are not opened by themselves')
if 'for curFile in ThumbnailCellTag.rows(tags: cells.map(\\.tag), of: matrixViewArray) {' not in from_thumbnails:
    fail('the selected study no longer opens the series of its selected thumbnails')
print('ok: text - a line of another study than the thumbnails\' opens by itself; the selected study opens its thumbnails')

if shutil.which('xcrun') is None:
    print('skipped: the rule needs xcrun (swiftc)', file=sys.stderr)
    sys.exit(SKIPPED)

RULE = function(opener, '    nonisolated static func thumbnailsStand<')
MAIN = r'''
import Foundation

enum ViewerOpener {
RULE
}

var failures: [String] = []
@MainActor func check(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }

let a = NSUUID(), b = NSUUID()
check(ViewerOpener.thumbnailsStand(forLineOf: a, thumbnailsOf: a), "the thumbnails of the line's own study do not stand for it")
check(!ViewerOpener.thumbnailsStand(forLineOf: b, thumbnailsOf: a), "the thumbnails of another study stand for the line")
check(!ViewerOpener.thumbnailsStand(forLineOf: a, thumbnailsOf: b), "the thumbnails of another study stand for the line")
check(ViewerOpener.thumbnailsStand(forLineOf: a, thumbnailsOf: Optional<NSUUID>.none), "with no thumbnails the line is not theirs")
check(ViewerOpener.thumbnailsStand(forLineOf: Optional<NSUUID>.none, thumbnailsOf: a), "a line whose study is not known is not the thumbnails'")
check(ViewerOpener.thumbnailsStand(forLineOf: Optional<String>.none, thumbnailsOf: Optional<String>.none), "nothing known is not the thumbnails'")
check(ViewerOpener.thumbnailsStand(forLineOf: "1.2.3", thumbnailsOf: "1.2.3") && !ViewerOpener.thumbnailsStand(forLineOf: "1.2.3", thumbnailsOf: "1.2.4"),
      "the rule does not compare the studies by value")

for failure in failures { print("FAIL: \(failure)") }
exit(failures.isEmpty ? 0 : 1)
'''

with tempfile.TemporaryDirectory(prefix='horos-open-study-not-selected-') as tmp:
    tmp = Path(tmp)
    (tmp / 'main.swift').write_text(MAIN.replace('RULE', RULE))
    try:
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-module-name', 'Horos', str(tmp / 'main.swift'), '-o', str(tmp / 'rule')],
                       check=True, capture_output=True)
    except subprocess.CalledProcessError as e:
        fail('the rule did not build: ' + (e.stderr or b'').decode(errors='replace')[-3000:])
    result = subprocess.run([str(tmp / 'rule')], capture_output=True, text=True, timeout=60)
    if result.returncode != 0:
        fail('; '.join(line[len('FAIL: '):] for line in (result.stdout + result.stderr).splitlines() if line.startswith('FAIL:'))
             or f'exit {result.returncode}')
print('ok: rule - the thumbnails stand for a line of their study, or of a study that is not known, and for no other')
print('PASS: a study opened while another row is selected opens its own series, not the thumbnails of the selected study')
