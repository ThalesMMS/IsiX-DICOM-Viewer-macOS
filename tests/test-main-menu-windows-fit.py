#!/usr/bin/env python3
"""No title, table header or pop-up of the main nib is cut, in any language.

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
  the nib gives its column;
- every pop-up shows the widest of its items whole, and every pull-down its
  title, by the measure of tests/pane_titles.py, which is the one of the window
  nibs' test: a pop-up of a toolbar item needs its title, in whole points, and
  23 points at the small and the mini size, 26 at the regular one. The pop-ups
  of the main nib are those of three items of the database window's toolbar.
  FILTERS names the two the code of the window lays out again: the nib gives
  them the small size and 106 points, and DatabaseBrowserLayout makes each of
  the regular size, in the system font, as wide as the widest of its items and
  its margin, and never under 124 points. They are measured as the code leaves
  them, and the source has to hold what does it. They were 124 points wide in
  every language, and the modality filter read «Все модальности», which needs
  137, cut: the measure is checked against it, at those 124 points. IMAGE_ONLY
  names the pull-down that draws an image and no title, whose menu the code
  fills with the report templates of the user. A pop-up that is in neither
  list is measured in the frame its nib gives it, and one that is not measured
  at all fails.

- no control that shows a text reaches more than 3 points outside a view
  above it (tests/pane_titles.py, the measure of the window nibs' test), and
  the status line under the study list keeps to its pane at any width. The
  code of the window gives that pane the width of the column above it each
  time the columns change, and a view resized so keeps the margins of a
  subview only where its mask leaves them fixed. The line was 2 points wider
  than the room its pane had for it, with its width and its right margin both
  flexible: the measure of the nib, which resizes nothing, saw 2 points and
  let them pass, and in the window the line passed its pane by more the wider
  the pane was, up to the divider, where a long line was cut with no margin.
  STATUS_LINE names it, and its frame has to end inside its pane with the
  width alone flexible. PANES_SIZED_BY_THE_WINDOW names the controls the
  measure finds outside a view that the nib keeps with no size.

`--inventory` prints, for each pop-up and language, the item measured, what it
needs, the 124 points both filters had and the width they have now.
"""
from pathlib import Path
import json
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pane_titles  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / 'Horos/Resources'
LANGUAGES = ('en', 'ar', 'de', 'es', 'fr', 'hi', 'it-IT', 'ja-JP', 'ko', 'pt-BR', 'ru', 'zh-Hans')

# The pop-ups of the filters of the database window, by the outlet of the view of their toolbar item, with the call
# that hands that view to the layout: the first control of the view is the pop-up, which the layout makes of the
# regular size, in the system font, and as wide as the widest of its items needs. The frame and the size of the nib
# are never shown.
LAYOUT = ROOT / 'Horos/Sources/DatabaseBrowserLayout.swift'
PREPARED = ROOT / 'Horos/Sources/BrowserController+Window.swift'
FILTERS = {
    'timeIntervalView': 'if let view = horos_timeIntervalView { DatabaseBrowserLayout.prepareFilterView(view) }',
    'modalityFilterView': 'if let view = horos_modalityFilterView { DatabaseBrowserLayout.prepareFilterView(view) }',
}
LAID_OUT = (
    'popup.controlSize = .regular',
    'popup.font = .systemFont(ofSize: NSFont.systemFontSize)',
    'let titles = popup.itemArray.filter { !$0.isSeparatorItem && !$0.isHidden }.map(\\.title)',
    'let widths = titles.map { NSAttributedString(string: $0, attributes: attributes).size().width }',
    'popup.widthAnchor.constraint(equalToConstant: filterWidth(itemWidths: widths)).isActive = true',
    'max(filterMinimumWidth, (itemWidths.max() ?? 0).rounded(.up) + filterTitleMargin)',
)
MINIMUM = re.compile(r'static let filterMinimumWidth: CGFloat = (\d+)\n')
MARGIN = re.compile(r'static let filterTitleMargin: CGFloat = (\d+)\n')
# What the measure counts beside the title of a pop-up of the regular size in a toolbar (tests/pane_titles.py).
TOOLBAR_MARGIN = 26
# The width both filters had, whatever their items: the measure is checked at it.
FIXED_WIDTH = 124
CUT_AT_FIXED_WIDTH = f'ru: the pop-up "Все модальности" needs 137 points, its frame (id %s) has {FIXED_WIDTH}'

# Pull-downs that draw an image and no title, by their outlet, with the source and the call that fills their menu:
# the one of the report's toolbar item lists the templates of the user as it opens, under an empty title.
IMAGE_ONLY = {
    'reportTemplatesListPopUpButton': ('Horos/Sources/StudyReports.swift',
                                       'guard let popUp = browser.horos_reportTemplatesListPopUpButton,'),
}

# Controls the measure finds outside a view above them (contained) because the nib keeps that view with no size, by
# their ids: the window gives the view its size when it loads, and the text of each is bound, so the one of the nib
# is never shown.
PANES_SIZED_BY_THE_WINDOW = {
    # The message about the studies of the other nodes, over the thumbnails: the nib stores the pane of the
    # thumbnails 0 points wide and 1 high, with the label 196 points under it.
    '14751',
}

# The status line under the study list, by its outlet: the code of the window resizes the pane that holds it
# (BrowserController+SplitView gives the first pane of the bottom split the width of the column above it).
STATUS_LINE = 'databaseDescription'
STATUS_PANE_RESIZED = (ROOT / 'Horos/Sources/BrowserController+SplitView.swift',
                       'objcSubview(bottomSplit, 0)?.frame = NSMakeRect(0, 0, dividerPosition, splitFrame.size.height)')
FIELD_IN_PANE = re.compile(r'<customView id="[^"]+">\s*<rect key="frame" x="0.0" y="0.0" width="([\d.]+)" height="[\d.]+"/>'
                           r'(?:(?!</customView>).)*?<textField [^>]*\bid="%s">\s*<rect key="frame" x="([\d.]+)" y="[\d.]+" width="([\d.]+)" '
                           r'height="[\d.]+"/>\s*<autoresizingMask key="autoresizingMask"([^/]*)/>', re.S)

POP_UP = re.compile(r'<popUpButton [^>]*?id="([^"]+)"[^>]*>.*?</popUpButton>', re.S)


def outlet(text, name):
    """The id of the object the outlet `name` of the nib names, or None."""
    found = re.search(r'<outlet property="%s" destination="([^"]+)"' % re.escape(name), text)
    return found.group(1) if found else None


def filter_pop_up(text, name):
    """(start, end, id) of the pop-up that is the first control of the view the outlet `name` names, or None."""
    view = re.search(r'\n        <customView id="%s"[^>]*>.*?\n        </customView>' % re.escape(outlet(text, name) or '-'), text, re.S)
    found = POP_UP.search(text, view.start(), view.end()) if view else None
    return (found.start(), found.end(), found.group(1)) if found else None


def as_laid_out(text, width):
    """The nib with the pop-up of each filter as the layout leaves it, `width` points wide, or None if one is not
    the small pop-up in the small system font the nib has today."""
    for name in FILTERS:
        place = filter_pop_up(text, name)
        if place is None:
            return None
        start, end, _ = place
        pop_up = text[start:end]
        head, menu, rest = pop_up.partition('<menu ')
        regular = re.sub(r'(<rect key="frame" [^>]*?width=")[^"]+(")', rf'\g<1>{width}\2', head, count=1)
        regular = regular.replace(' controlSize="small"', '', 1).replace('<font key="font" metaFont="smallSystem"/>',
                                                                         '<font key="font" metaFont="system"/>', 1)
        if head.count(' controlSize="small"') != 1 or head.count('<font key="font" metaFont="smallSystem"/>') != 1 or regular == head:
            return None
        text = text[:start] + regular + menu + rest + text[end:]
    return text

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

titles = pane_titles.measure(variants, every_window=True, contained=True)
for identifier in PANES_SIZED_BY_THE_WINDOW:
    unbound = [language for language, path in variants.items() if identifier not in pane_titles.bound_titles(path)]
    if unbound:
        failures.append(f'the text of the control {identifier} is no longer bound in {unbound}: it is a text of the nib, to be measured')
    if not any(item.get('contained') is False and item['id'] == identifier for item in titles):
        failures.append(f'the control {identifier} is no longer outside its view in the nib: take it off PANES_SIZED_BY_THE_WINDOW')
titles = [item for item in titles if not (item.get('contained') is False and item['id'] in PANES_SIZED_BY_THE_WINDOW)]
failures += pane_titles.misfits(titles)
if STATUS_PANE_RESIZED[1] not in STATUS_PANE_RESIZED[0].read_text(encoding='utf-8'):
    failures.append(f'{STATUS_PANE_RESIZED[0].name} no longer resizes the pane of the status line as "{STATUS_PANE_RESIZED[1]}"')
for language, path in variants.items():
    text = path.read_text(encoding='utf-8')
    line = re.search(r'<outlet property="%s" destination="([^"]+)"' % STATUS_LINE, text)
    found = re.search(FIELD_IN_PANE.pattern % re.escape(line.group(1)), text, re.S) if line else None
    if not found:
        failures.append(f'{language}: the status line is not a field of the first view of its pane')
        continue
    pane, x, width, mask = float(found.group(1)), float(found.group(2)), float(found.group(3)), found.group(4).strip()
    if x + width > pane:
        failures.append(f'{language}: the status line ends at {x + width:.0f} points in a pane of {pane:.0f}')
    if mask != 'widthSizable="YES"':
        failures.append(f'{language}: the status line does not keep its margins when its pane is resized (its mask is {mask or "fixed"})')
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

english = variants['en'].read_text(encoding='utf-8') if 'en' in variants else ''
layout = LAYOUT.read_text(encoding='utf-8')
prepared = PREPARED.read_text(encoding='utf-8')
failures += [f'{LAYOUT.name} no longer holds "{line}": the pop-up of a filter is not laid out as it is measured here'
             for line in LAID_OUT if line not in layout]
failures += [f'{PREPARED.name} no longer holds "{call}": the pop-up of {name} is shown as its nib has it'
             for name, call in FILTERS.items() if call not in prepared]
minimum, margin = MINIMUM.search(layout), MARGIN.search(layout)
if not minimum or not margin:
    failures.append(f'{LAYOUT.name} names no least width or no margin for the pop-up of a filter')
minimum, margin = (int(minimum.group(1)) if minimum else FIXED_WIDTH), (int(margin.group(1)) if margin else 0)
filters = {name: (filter_pop_up(english, name) or (0, 0, None))[2] for name in FILTERS}
failures += [f'the view of {name} holds no pop-up in the English nib' for name, identifier in filters.items() if not identifier]
image_only = {name: outlet(english, name) for name in IMAGE_ONLY}
for name, (source, call) in IMAGE_ONLY.items():
    if call not in (ROOT / source).read_text(encoding='utf-8'):
        failures.append(f'{source} no longer holds "{call}": the menu of {name} is the one of its nib')
    for language, path in variants.items():
        found = re.search(r'<popUpButton [^>]*?id="%s"[^>]*>\s*(?:<[^>]*/>\s*)*<popUpButtonCell [^>]*>' % re.escape(image_only[name] or '-'),
                          path.read_text(encoding='utf-8'))
        if not found or ' imagePosition="only"' not in found.group(0):
            failures.append(f'{language}: the pull-down of {name} is no longer one that draws its image only')
every_pop_up = {match.group(1) for match in POP_UP.finditer(english)}
expected = every_pop_up - set(image_only.values())

pop_ups = []
with tempfile.TemporaryDirectory(prefix='horos-main-menu-pop-ups-') as folder:
    copies = {}
    for language, path in variants.items():
        text = as_laid_out(path.read_text(encoding='utf-8'), FIXED_WIDTH)
        if text is None:
            failures.append(f'{language}: the pop-ups of the filters are not the small ones of 106 points the layout takes')
            continue
        copies[language] = Path(folder) / f'{language}.xib'
        copies[language].write_text(text, encoding='utf-8')
    if copies:
        pop_ups = [item for item in pane_titles.measure(copies, every_window=True, every_view=True, pop_ups=True)
                   if item.get('popUp') or 'error' in item]
for language in copies:
    unmeasured = expected - {item['id'] for item in pop_ups if item.get('popUp') and item['language'] == language}
    failures += [f'{language}: the pop-up {identifier} was not measured, and no list names it' for identifier in sorted(unmeasured)]
# The measure itself: at the width both filters had, the Russian modality filter has to be reported.
at_fixed_width = pane_titles.misfits(pop_ups)
if 'ru' in copies and CUT_AT_FIXED_WIDTH % filters['modalityFilterView'] not in at_fixed_width:
    failures.append(f'the measure does not report the modality filter, which needs 137 points in Russian, in {FIXED_WIDTH}')
# What the layout gives the pop-up of a filter: the widest of its items in whole points and its margin, or the least width.
inventory = []
for item in pop_ups:
    if item.get('popUp') and item['id'] in filters.values():
        inventory.append((item['id'], item['language'], item['title'], item['needed'], item['width'],
                          max(minimum, item['needed'] - TOOLBAR_MARGIN + margin)))
        item['width'] = inventory[-1][-1]
    elif item.get('popUp'):
        inventory.append((item['id'], item['language'], item['title'], item['needed'], item['width'], item['width']))
failures += pane_titles.misfits(pop_ups)

if '--inventory' in sys.argv[1:]:
    names = {identifier: name for name, identifier in filters.items()}
    for identifier, language, title, needed, before, has in sorted(inventory, key=lambda row: (row[0], LANGUAGES.index(row[1]))):
        print(f'{names.get(identifier, identifier)} ({identifier}) {language}: "{title}" needs {needed:.0f}, had {before:.0f}'
              f'{" (cut)" if needed > before + 0.5 else ""}, has {has:.0f}{" (cut)" if needed > has + 0.5 else ""}')
    print(f'{sum(1 for row in inventory if row[3] > row[4] + 0.5)} of {len(inventory)} were cut, '
          f'{sum(1 for row in inventory if row[3] > row[5] + 0.5)} are')

if failures:
    for failure in failures[:60]:
        print('FAIL: ' + failure)
    sys.exit(f'{len(failures)} titles, headers or pop-ups of the main nib are cut')
print(f'PASS: {len([item for item in titles if "id" in item])} titles and {len(headers)} table headers of the main nib\'s windows '
      f'and {len(inventory)} pop-ups of its toolbar items fit in {len(variants)} languages')
