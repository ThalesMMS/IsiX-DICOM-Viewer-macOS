"""What each title of a preference pane needs, in every language of the pane.

Each variant of the pane is copied with its controls tagged by their XIB ids,
compiled with ibtool and loaded; AppKit then says, for every visible checkbox,
radio button, push button and label, the room its title needs - on one line,
or, for a label that wraps, the height it needs at its width.
"""
from pathlib import Path
import json
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
LANGUAGES = ('ar', 'de', 'fr', 'hi', 'ko', 'pt-BR', 'ru', 'zh-Hans')


def variants(xib_name):
    """{language: path} of every variant of a pane: Base and ja-JP beside its sources, the others in Horos/Resources."""
    base = next((ROOT / 'Preference Panes').glob(f'*/Base.lproj/{xib_name}'))
    panes = {'Base': base}
    if (base.parent.parent / 'ja-JP.lproj' / xib_name).exists():
        panes['ja-JP'] = base.parent.parent / 'ja-JP.lproj' / xib_name
    panes.update({language: ROOT / 'Horos/Resources' / f'{language}.lproj' / xib_name for language in LANGUAGES
                  if (ROOT / 'Horos/Resources' / f'{language}.lproj' / xib_name).exists()})
    return panes


PANES = variants('OSIListenerPreferencePanePref.xib')
TAGGED = re.compile(r'<(button|textField|popUpButton|matrix|box) ([^>]*?)id="([^"]+)"(?![^>]* identifier=)')
# Bindings set values and states, not frames; some name value transformers that only the app
# registers, and a nib whose transformer is missing does not load.
FORMATTER_CLASS = re.compile(r'(<\w*[fF]ormatter\b[^>]*?) customClass="[^"]+"')
BINDING = re.compile(r'<binding [^>]*/>|<binding [^>]*[^/]>.*?</binding>', re.S)

# A table is named by its XIB id in what is reported of its headers; no nib names its tables otherwise.
TABLE = re.compile(r'<(tableView|outlineView) ((?:(?! identifier=)[^>])*?)id="([^"]+)"')

MEASURE = r'''
import AppKit
import Foundation

final class Owner: NSObject {
    @IBOutlet @objc var mainWindow: NSWindow?
    override func value(forUndefinedKey key: String) -> Any? { nil }
    override func setValue(_ value: Any?, forUndefinedKey key: String) {}
}
var results: [[String: Any]] = []
let everyWindow = CommandLine.arguments.contains("--every-window")
let everyView = CommandLine.arguments.contains("--every-view")
let everyTab = CommandLine.arguments.contains("--every-tab")
let pinViews = CommandLine.arguments.contains("--pin-views")
let headers = CommandLine.arguments.contains("--headers")
let popUps = CommandLine.arguments.contains("--pop-ups")
let contained = CommandLine.arguments.contains("--contained")
// Where a copy of a pop-up is given one width after another, to find the one its title needs.
let stage: NSView? = popUps ? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 2000, height: 200), styleMask: [.titled],
                                       backing: .buffered, defer: false).contentView : nil
// A tab view holds the view of its selected item only: with --every-tab the views of all its items are read.
func children(of view: NSView) -> [NSView] {
    if everyTab, let tabs = view as? NSTabView { return tabs.tabViewItems.compactMap(\.view) }
    return view.subviews
}
func controls(in view: NSView) -> [NSControl] {
    children(of: view).compactMap { $0 as? NSControl } + children(of: view).flatMap { controls(in: $0) }
}
// The view of a tab is laid out when its tab is shown: each is shown once, and keeps its frames.
func showEachTab(in view: NSView) {
    for child in view.subviews {
        guard let tabs = child as? NSTabView else { showEachTab(in: child); continue }
        let selected = tabs.selectedTabViewItem
        for item in tabs.tabViewItems {
            tabs.selectTabViewItem(item)
            tabs.layoutSubtreeIfNeeded()
            if let shown = item.view { showEachTab(in: shown) }
        }
        if let selected { tabs.selectTabViewItem(selected) }
    }
}
for path in CommandLine.arguments.dropFirst() where !path.hasPrefix("--") {
    let language = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    let owner = Owner()
    var objects: NSArray?
    let nib = NSNib(nibData: try! Data(contentsOf: URL(fileURLWithPath: path)), bundle: nil)
    guard nib.instantiate(withOwner: owner, topLevelObjects: &objects), everyWindow || owner.mainWindow?.contentView != nil else {
        results.append(["language": language, "error": "the pane did not load"]); continue
    }
    //ROOM
    // The pane's own window, then the sheets and panels its nib holds, in the order of their titles. A nib that
    // is no pane's (the main menu's) has no window of its owner's: all of its windows are measured.
    let others = (objects as? [Any] ?? []).compactMap { $0 as? NSWindow }.filter { $0 !== owner.mainWindow }
        .sorted { $0.title < $1.title }.compactMap(\.contentView)
    // The views a nib holds outside its windows are those of toolbar items: laid out at the size the nib gives them.
    let views = (objects as? [Any] ?? []).compactMap { $0 as? NSView }
    if pinViews {
        // A toolbar gives the view of an item the size its nib has: a view whose constraints leave its width or
        // its height free is held at its frame, and what does not fit inside is cut as the toolbar cuts it.
        for view in views where view.identifier?.rawValue != "pane-free-view" {
            for (attribute, length) in [(NSLayoutConstraint.Attribute.width, view.frame.width), (.height, view.frame.height)]
            where length > 0 && !view.constraints.contains(where: {
                $0.firstItem as? NSView === view && $0.firstAttribute == attribute && $0.secondItem == nil }) {
                NSLayoutConstraint(item: view, attribute: attribute, relatedBy: .equal, toItem: nil, attribute: .notAnAttribute,
                                   multiplier: 1, constant: length).isActive = true
            }
        }
    }
    for content in [owner.mainWindow?.contentView].compactMap({ $0 }) + (everyWindow ? others : []) + (everyView ? views : []) {
    // A pane laid out by constraints has its frames only after a layout pass.
    content.layoutSubtreeIfNeeded()
    if everyTab { showEachTab(in: content) }
    func record(_ id: String, _ title: String, _ cell: NSCell, _ frame: NSRect, oneLine: Bool = false) {
        // Buttons, checkboxes and radio buttons here are one line high; only a label wraps.
        let wraps = !oneLine && cell is NSTextFieldCell && (cell.wraps || cell.lineBreakMode == .byWordWrapping || cell.lineBreakMode == .byCharWrapping)
        // A wrapped title still needs its longest word on one line.
        let wrapped = wraps ? cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: frame.width, height: 10000)) : .zero
        // AppKit gives the cell of a button a size in whole pixels of the screen: whole points at 1x, half points at
        // 2x, where a title of 115.5 points passes in a frame of 115 and is 116 points and cut at 1x. The measure is
        // the one of a screen at 1x, whatever the screen it runs on.
        let needed = cell is NSButtonCell ? cell.cellSize.width.rounded(.up) : cell.cellSize.width
        results.append(["language": language, "id": id, "title": title, "width": frame.width, "height": frame.height,
                        "needed": needed, "wraps": wraps, "wrappedWidth": wrapped.width, "wrappedHeight": wrapped.height,
                        "button": cell is NSButtonCell])
    }
    // Two visible controls of the same view whose frames cross: a widened one runs into its neighbour.
    // A button's frame may run past its title, and a pop-up's frame holds its bezel's margin: compare what they draw.
    func drawn(_ control: NSControl) -> NSRect {
        if let button = control as? NSButton, !(control is NSPopUpButton), !button.title.isEmpty, let cell = button.cell {
            var area = control.frame
            area.size.width = min(area.width, cell.cellSize.width)
            return area
        }
        return control is NSPopUpButton ? control.frame.insetBy(dx: 3, dy: 3) : control.frame
    }
    // A matrix draws its cells, and nothing in the gaps between its rows and columns, where a nib may stand
    // other controls: the choices of a radio button under it, between that one and the next. A radio button or
    // a checkbox in a cell larger than it draws its title on one line, in the middle of the cell's height, and
    // no further than the title goes.
    func areas(_ control: NSControl) -> [NSRect] {
        guard let matrix = control as? NSMatrix, let superview = matrix.superview else { return [drawn(control)] }
        var cells: [NSRect] = []
        for row in 0..<matrix.numberOfRows {
            for column in 0..<matrix.numberOfColumns {
                guard let cell = matrix.cell(atRow: row, column: column) else { continue }
                var area = matrix.cellFrame(atRow: row, column: column)
                if let button = cell as? NSButtonCell, !button.isBordered {
                    let size = button.cellSize(forBounds: area)
                    area = NSRect(x: area.minX, y: area.midY - size.height / 2, width: min(area.width, size.width), height: size.height)
                }
                cells.append(matrix.convert(area, to: superview))
            }
        }
        return cells
    }
    let visible = controls(in: content).filter {
        !$0.isHiddenOrHasHiddenAncestor && $0.identifier?.rawValue.hasPrefix("pane-title:") == true
    }
    for (index, first) in visible.enumerated() {
        for second in visible[(index + 1)...] where first.superview === second.superview {
            let crosses = areas(first).contains { one in
                areas(second).contains { other in
                    let crossing = one.intersection(other)
                    return !crossing.isNull && crossing.width > 1 && crossing.height > 1
                }
            }
            if crosses {
                results.append(["language": language, "overlap": [String(first.identifier!.rawValue.dropFirst(11)),
                                                                String(second.identifier!.rawValue.dropFirst(11))]])
            }
        }
    }
    // A box draws its title on its top edge, inside the frame less a margin on each side.
    func boxes(in view: NSView) -> [NSBox] {
        children(of: view).compactMap { $0 as? NSBox } + children(of: view).flatMap { boxes(in: $0) }
    }
    for box in boxes(in: content) where !box.isHiddenOrHasHiddenAncestor && box.titlePosition != .noTitle && !box.title.isEmpty {
        guard let tagged = box.identifier?.rawValue, tagged.hasPrefix("pane-title:"),
              let cell = box.titleCell as? NSCell else { continue }
        let id = String(tagged.dropFirst(11))
        record(id, box.title, cell, NSRect(x: 0, y: 0, width: box.frame.width - 10, height: box.frame.height), oneLine: true)
    }
    // The header of a table column draws its title in the width of the column, and cuts what does not fit.
    func tables(in view: NSView) -> [NSTableView] {
        children(of: view).compactMap { $0 as? NSTableView } + children(of: view).flatMap { tables(in: $0) }
    }
    if headers {
        for table in tables(in: content) where !table.isHiddenOrHasHiddenAncestor && table.headerView != nil {
            let tagged = table.identifier?.rawValue ?? ""
            for (place, column) in table.tableColumns.enumerated() where !column.isHidden && !column.title.isEmpty {
                results.append(["language": language, "header": place + 1, "title": column.title,
                                "table": tagged.hasPrefix("pane-table:") ? String(tagged.dropFirst(11)) : tagged,
                                "width": column.width, "needed": column.headerCell.cellSize.width])
            }
        }
    }
    // A pull-down shows its title, the first of its items, and a pop-up the item that is chosen: what has to fit
    // is the title, or the widest of the items. What AppKit says the cell needs (cellSize) is more than the title
    // takes to be drawn whole, by 14 to 16 points at the regular size, 10 to 12 at the small one and 8 to 10 at
    // the mini one, so it is not the measure. The cell says the rect it gives the title it draws: as wide as the
    // title while the title is whole, and as wide as what is left of it once it is cut. A copy of the pop-up, in
    // a window of its own, is given one width after another, and the least one whose rect holds the whole title
    // is what the pop-up needs: the title and 34 points at the regular size, 30 at the small one, 24 at the mini
    // one and 16 at the mini one with no bezel. A pop-up that shows an image only draws no title.
    // A toolbar draws the pop-ups of its items closer to their titles, whatever their size says: in the running
    // application a pop-up of the small or of the mini size needs its title, in whole points, and 23 points, and
    // one of the regular size 26. The views a nib holds outside its windows are those of toolbar items, and
    // their pop-ups are measured so, except in the views named as held by no toolbar.
    let inToolbar = views.contains { $0 === content } && content.identifier?.rawValue != "pane-plain-view"
    if let stage {
        for control in controls(in: content) where !control.isHiddenOrHasHiddenAncestor {
            guard let popUp = control as? NSPopUpButton, popUp.imagePosition != .imageOnly,
                  let tagged = popUp.identifier?.rawValue, tagged.hasPrefix("pane-title:") else { continue }
            let id = String(tagged.dropFirst(11))
            guard let data = try? NSKeyedArchiver.archivedData(withRootObject: popUp, requiringSecureCoding: false),
                  let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else {
                results.append(["language": language, "error": "the pop-up \(id) could not be copied"]); continue
            }
            unarchiver.requiresSecureCoding = false
            guard let copy = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? NSPopUpButton,
                  let cell = copy.cell as? NSPopUpButtonCell else {
                results.append(["language": language, "error": "the pop-up \(id) could not be copied"]); continue
            }
            copy.translatesAutoresizingMaskIntoConstraints = true
            copy.removeConstraints(copy.constraints)
            stage.subviews.forEach { $0.removeFromSuperview() }
            stage.addSubview(copy)
            var widest: (title: String, text: CGFloat, index: Int)?
            // The title of a pull-down is the first item of its menu, which the menu hides.
            for item in copy.pullsDown ? Array(copy.itemArray.prefix(1)) : copy.itemArray.filter({ !$0.isHidden })
            where !item.isSeparatorItem && !item.title.isEmpty {
                let index = copy.index(of: item)
                if !copy.pullsDown { copy.selectItem(at: index) }
                let text = cell.attributedTitle.size().width
                if widest == nil || text > widest!.text { widest = (item.title, text, index) }
            }
            guard let widest else { continue }
            if inToolbar {
                let margin: CGFloat = popUp.controlSize == .small || popUp.controlSize == .mini ? 23 : 26
                results.append(["language": language, "id": id, "popUp": true, "pullsDown": popUp.pullsDown, "title": widest.title,
                                "width": popUp.frame.width, "needed": widest.text.rounded(.up) + margin])
                continue
            }
            if !copy.pullsDown { copy.selectItem(at: widest.index) }
            func whole(at width: CGFloat) -> Bool {
                copy.frame = NSRect(x: 0, y: 0, width: width, height: popUp.frame.height)
                return cell.titleRect(forBounds: copy.bounds).width >= widest.text.rounded(.up) - 0.5
            }
            var cut: CGFloat = 0, fits = (popUp.frame.width + 600).rounded(.up)
            if !whole(at: fits) {
                results.append(["language": language, "error": "the pop-up \(id) draws \"\(widest.title)\" whole at no width"]); continue
            }
            while fits - cut > 1 {
                let middle = ((cut + fits) / 2).rounded()
                if whole(at: middle) { fits = middle } else { cut = middle }
            }
            results.append(["language": language, "id": id, "popUp": true, "pullsDown": popUp.pullsDown, "title": widest.title,
                            "width": popUp.frame.width, "needed": fits])
        }
        stage.subviews.forEach { $0.removeFromSuperview() }
    }
    for control in controls(in: content) where !control.isHiddenOrHasHiddenAncestor && !(control is NSPopUpButton) {
        guard let tagged = control.identifier?.rawValue, tagged.hasPrefix("pane-title:") else { continue }
        let id = String(tagged.dropFirst(11))
        if let matrix = control as? NSMatrix {
            // A matrix's radio buttons are its cells, each in a frame of the matrix's cell size.
            for row in 0..<matrix.numberOfRows {
                for column in 0..<matrix.numberOfColumns {
                    guard let item = matrix.cell(atRow: row, column: column), item.title.isEmpty == false else { continue }
                    record("\(id)/\(row).\(column)", item.title, item, matrix.cellFrame(atRow: row, column: column))
                }
            }
            continue
        }
        guard let cell = control.cell else { continue }
        var title = ""
        if let button = control as? NSButton {
            if button.imagePosition == .imageOnly { continue }  // its title is never drawn
            title = button.title
        }
        else if let field = control as? NSTextField, !field.isEditable { title = field.stringValue }
        if title.isEmpty { continue }
        record(id, title, cell, control.frame)
    }
    // A control that reaches outside a view above it is cut there (contained): the last row of a box laid down past
    // its bottom, the first line of a sheet above its top. A window gives its content the room its constraints ask
    // for when it is shown, so it is laid out first; what a scroll view holds is scrolled, not cut (contained).
    if contained {
        content.window?.layoutIfNeeded()
        for control in visible where !(control is NSPopUpButton) {
            var shown = ""  // the text of the nib it shows (contained)
            if let button = control as? NSButton, button.imagePosition != .imageOnly { shown = button.title }
            else if let field = control as? NSTextField, !field.isEditable { shown = field.stringValue }
            else if let matrix = control as? NSMatrix { shown = matrix.cells.map(\.title).first { !$0.isEmpty } ?? "" }
            if shown.isEmpty { continue }
            // What it draws (contained): the cells of a matrix, the alignment rectangle of anything else.
            let drawnAreas = control is NSMatrix ? areas(control) : [control.alignmentRect(forFrame: control.frame)]
            var area = drawnAreas.dropFirst().reduce(drawnAreas[0]) { $0.union($1) }
            var holder = control.superview
            while let view = holder, !(view is NSClipView), view.superview != nil || view === content {
                let limits = view.bounds
                let outside = max(limits.minX - area.minX, area.maxX - limits.maxX, limits.minY - area.minY, area.maxY - limits.maxY)
                if outside > 3 {
                    results.append(["language": language, "id": String(control.identifier!.rawValue.dropFirst(11)), "contained": false,
                                    "outside": outside, "holder": view === content ? "window or view" : view.superview is NSBox ? "box" : "view",
                                    "title": shown])
                    break
                }
                if view === content { break }
                area = view.convert(area, to: view.superview)
                holder = view.superview
            }
        }
    }
    }
}
print(String(data: try! JSONSerialization.data(withJSONObject: results), encoding: .utf8)!)
'''


CONTROL = re.compile(r'<(button|textField|popUpButton|matrix) [^>]*?id="([^"]+)"')


def bound_titles(xib):
    """Ids of the controls whose shown text comes from a binding: their title in the XIB is a placeholder."""
    text = xib.read_text(encoding='utf-8')
    bound = set()
    for match in CONTROL.finditer(text):
        end = text.find(f'</{match.group(1)}>', match.end())
        # A label shows its value; a button's value is its state, and it shows its title.
        names = r'value|displayPatternValue\w*' if match.group(1) == 'textField' else r'title|displayPatternTitle\w*'
        # A pop-up whose items come from a binding shows data: the items its XIB holds are samples.
        if match.group(1) == 'popUpButton':
            names += r'|content\w*'
        if re.search(r'<binding [^>]*name="(%s)"' % names, text[match.end():end]):
            bound.add(match.group(2))
    return bound


def hidden_by_binding(xib):
    """Ids of the controls a binding shows or hides: two of them may share a place, one at a time."""
    text = xib.read_text(encoding='utf-8')
    hidden = set()
    for match in CONTROL.finditer(text):
        end = text.find(f'</{match.group(1)}>', match.end())
        if re.search(r'<binding [^>]*name="hidden\d*"', text[match.end():end]):
            hidden.add(match.group(2))
    return hidden


def measure(panes=PANES, separate_nibs=False, every_window=False, every_view=False, room=(), every_tab=False, pin_views=False,
            free_views=(), headers=False, pop_ups=False, plain_views=(), contained=False):
    """[{language, id, title, width, height, needed, wraps, wrappedWidth, wrappedHeight}] for every titled control
    and every titled cell of a matrix (id "matrix/row.column").

    The variants are copies of one nib, whose ids name the same controls, unless separate_nibs: then each variant
    is a nib of its own, and only its own bindings say which of its titles are data (an id names another control,
    bound or not, in another nib). With every_window, the sheets and panels of the nib are measured too, not
    only the pane's own window; with every_view, the views the nib holds outside its windows (those of toolbar
    items) as well; with every_tab, the views of all the items of a tab view, not only of the selected one.
    With pin_views, a view outside the windows keeps the size of its nib where its constraints leave it free, as a
    toolbar holds the view of an item, except the views whose ids free_views gives, which their toolbar lets grow.
    With headers, every titled column of every table that shows its headers is measured too, as
    {language, header: its place among the columns, table: the XIB id of its table, title, width, needed}.
    With pop_ups, every pull-down and pop-up that draws a title is measured too, as {language, id, popUp: True,
    pullsDown, title: the title of a pull-down or the widest item of a pop-up, width, needed: the least width at
    which its cell draws that title whole}; one whose items come from a binding is left out. A pop-up in a view
    outside the windows is measured as a toolbar draws it, unless plain_views gives the id of its view: one that
    no toolbar holds (a view a sheet or a save panel takes in).
    With contained, every control that shows a text of the nib and reaches more than 3 points outside a view
    above it - its box, its window - once the window is laid out is reported too, as {language, id, contained:
    False, outside: by how many points, holder: what cuts it, title}.
    `room` names the Swift sources of WindowNibFit: given them, every variant but the English one
    is measured after WindowNibFit made room in it, as a window that reads the catalog is shown."""
    with tempfile.TemporaryDirectory(prefix='horos-pane-titles-') as folder:
        folder = Path(folder)
        nibs = []
        for language, xib in panes.items():
            tagged = folder / f'{language}.xib'
            text = xib.read_text(encoding='utf-8')
            text = BINDING.sub('', text)
            # A formatter of a class of the application is not here to be unarchived, and the nib does not load:
            # it sets no frame, and the formatter of AppKit stands in for it.
            text = FORMATTER_CLASS.sub(r'\1', text)
            for free in free_views:
                text = re.sub(r'(\n        <customView )((?:(?! identifier=)[^>])*?id="%s")' % re.escape(free),
                              r'\1identifier="pane-free-view" \2', text)
            for plain in plain_views:
                text = re.sub(r'(\n        <customView )((?:(?! identifier=)[^>])*?id="%s")' % re.escape(plain),
                              r'\1identifier="pane-plain-view" \2', text)
            if headers:
                text = TABLE.sub(lambda m: f'<{m.group(1)} {m.group(2)}id="{m.group(3)}" identifier="pane-table:{m.group(3)}"', text)
            tagged.write_text(TAGGED.sub(lambda m: m.group(0) if ' identifier=' in m.group(0) else
                                         f'<{m.group(1)} {m.group(2)}id="{m.group(3)}" identifier="pane-title:{m.group(3)}"', text),
                              encoding='utf-8')
            nib = folder / f'{language}.nib'
            built = subprocess.run(['xcrun', 'ibtool', '--compile', str(nib), str(tagged)], capture_output=True, text=True)
            if built.returncode or not nib.exists():
                raise RuntimeError(f'{language}: the pane does not compile\n{built.stdout[-800:]}{built.stderr[-800:]}')
            nibs.append(str(nib))
        fitted = 'if language != "en" { MainActor.assumeIsolated { WindowNibFit.makeRoom(in: objects as? [Any] ?? []) } }'
        (folder / 'main.swift').write_text(MEASURE.replace('//ROOM', fitted if room else ''))
        subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(folder / 'modules'), str(folder / 'main.swift'),
                        *map(str, room), '-o', str(folder / 'measure')], check=True, capture_output=True)
        ran = subprocess.run([str(folder / 'measure'), *nibs, *(['--every-window'] if every_window else []),
                              *(['--every-view'] if every_view else []), *(['--every-tab'] if every_tab else []),
                              *(['--pin-views'] if pin_views else []), *(['--headers'] if headers else []),
                              *(['--pop-ups'] if pop_ups else []), *(['--contained'] if contained else [])],
                             capture_output=True, text=True, timeout=300, check=True)
        if separate_nibs:
            bound = {language: bound_titles(xib) for language, xib in panes.items()}
            hidden = {language: hidden_by_binding(xib) for language, xib in panes.items()}
        else:
            every_bound = set().union(*(bound_titles(xib) for xib in panes.values()))
            every_hidden = set().union(*(hidden_by_binding(xib) for xib in panes.values()))
            bound = {language: every_bound for language in panes}
            hidden = {language: every_hidden for language in panes}
        return [item for item in json.loads(ran.stdout)
                if ('overlap' in item and not hidden.get(item['language'], set()).intersection(item['overlap']))
                or ('overlap' not in item and item.get('id', '').split('/')[0] not in bound.get(item['language'], set()))
                # A control that a binding fills is drawn in its frame whatever it shows: outside what holds it,
                # it is cut like any other. The count of the key images stood past the end of its toolbar item.
                or item.get('contained') is False]


def available():
    return shutil.which('xcrun') is not None


def misfits(measured):
    """What does not fit, as messages - controls that overlap, the headers of table columns, and titles: a one-line label may need 3 points more than its frame, the padding
    AppKit counts in, while a button, checkbox or radio button truncates as soon as its title needs more than its frame; a wrapped label fits
    when its lines, and its longest word, fit the frame."""
    failures = []
    for item in measured:
        if 'error' in item:
            failures.append(f'{item["language"]}: {item["error"]}')
        elif 'overlap' in item:
            failures.append(f'{item["language"]}: controls {item["overlap"][0]} and {item["overlap"][1]} overlap')
        elif 'header' in item:
            # A header cuts its title as soon as the title needs more than the column has.
            if item['needed'] > item['width'] + 0.5:
                failures.append(f'{item["language"]}: the header "{item["title"]}" needs {item["needed"]:.0f} points, '
                                f'its column ({item["header"]} of table {item["table"]}) has {item["width"]:.0f}')
        elif item.get('contained') is False:
            # A control that reaches outside a view above it, a box or its window, is cut by it (contained).
            failures.append(f'{item["language"]}: "{item["title"]}" (id {item["id"]}) reaches {item["outside"]:.0f} points '
                            f'outside the {item["holder"]} that holds it')
        elif item.get('popUp'):
            # A pop-up cuts the title it shows as soon as the title needs more than the frame leaves it.
            if item['needed'] > item['width'] + 0.5:
                failures.append(f'{item["language"]}: the {"pull-down" if item["pullsDown"] else "pop-up"} "{item["title"]}" '
                                f'needs {item["needed"]:.0f} points, its frame (id {item["id"]}) has {item["width"]:.0f}')
        elif item['wraps'] and item['needed'] > item['width']:
            if item['wrappedWidth'] > item['width'] + 3 or item['wrappedHeight'] > item['height'] + 0.5:
                failures.append(f'{item["language"]}: "{item["title"]}" needs {item["wrappedWidth"]:.0f} x {item["wrappedHeight"]:.0f} '
                                f'points wrapped, its frame (id {item["id"]}) has {item["width"]:.0f} x {item["height"]:.0f}')
        elif item['needed'] > item['width'] + (0.5 if item.get('button') else 3):
            failures.append(f'{item["language"]}: "{item["title"]}" needs {item["needed"]:.0f} points, '
                            f'its frame (id {item["id"]}) has {item["width"]:.0f}')
    return failures
