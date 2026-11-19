"""What the nibs of the settings window show, and how a language without a copy of a nib reads it.

The preference panes' nibs have a Base copy beside their sources and copies in
other languages, ja-JP beside the sources and the others in
Horos/Resources/<language>.lproj. Spanish and Italian have a catalog and no
copy: there a nib loads as its Base copy has it, and CatalogTranslation
(Preference Panes/PaneCatalogTranslation.swift) reads each text it shows from
Localizable.strings by its English text.

shown_texts() lists the texts of a window of a XIB that a user reads, as
CatalogTranslation reads them: titles of boxes, buttons, radio buttons and
tabs, labels (not what an editable field holds), placeholders, tooltips, the
items of a pop-up, segment labels, table headers and the items of a table's
pop-up cells, and the names a search field's predicate bindings give its menu
(attribute ELEMENT_TEXT, the text of their <string key="NSDisplayName">); a
tooltip IB stores on a cell is shown only by the cells of a TipMatrix (the
tools of the viewers, the radio buttons of a pane), which keeps them. What a binding gives (a label's value, a button's title, the
items of a pop-up whose content or selected value is bound) and the rows of a
table are data, and are left out; so are the texts of controls that the pane's
code fills, given by the outlets it fills them through.

A run of CatalogTranslation itself, compiled from its source with PaneFit, is
made by run_harness() on compiled nibs: it reports every text each window shows
after the catalog was applied, the room each pop-up and each table header
needs, whether controls whose text a binding gives kept it, whether the
subviews of standard controls were left alone, and what a pane's code does
after loading its nib (the pop-ups it fills, the rows and columns PaneFit lays
out, the columns of a saved layout it widens to their headers, the date
pickers it fits, and the room the settings window's toolbar leaves a pane's
title).
"""
from pathlib import Path
import base64
import json
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
HELPER = 'Preference Panes/PaneCatalogTranslation.swift'
# Bindings that make what a control shows data rather than a text of the nib.
DATA_BINDINGS = {
    'textField': {'value'},
    'button': {'title'},
    'popUpButton': {'content', 'contentObjects', 'contentValues', 'selectedObject', 'selectedValue'},
}
TABLES = ('tableView', 'outlineView')
# The matrix whose cells keep the tooltips of their nib.
TIP_MATRIX = 'IsiXTipMatrix'
TIP_MATRIX_SOURCE = 'Horos/Sources/TipMatrix.swift'


class Checkout:
    """The files of the checkout, or of a git revision."""

    def __init__(self, revision=None):
        self.revision = revision

    def read(self, path):
        path = Path(path)
        if self.revision:
            relative = str(path.relative_to(ROOT)) if path.is_absolute() else str(path)
            return subprocess.check_output(['git', '-C', str(ROOT), 'show', f'{self.revision}:{relative}'])
        return (path if path.is_absolute() else ROOT / path).read_bytes()

    def exists(self, path):
        try:
            self.read(path)
            return True
        except (OSError, subprocess.CalledProcessError):
            return False

    def catalog(self, language, folder):
        """The Localizable.strings of a language, as a dictionary."""
        path = Path(folder) / f'{language}.strings'
        path.write_bytes(self.read(ROOT / 'Horos/Resources' / f'{language}.lproj/Localizable.strings'))
        return json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)]))


# The attribute that names an element's own text: a binding option's value, <string key="NSDisplayName">All</string>.
ELEMENT_TEXT = '#text'


def text_of(element, attribute):
    """A text the XIB keeps in an attribute or, when it runs over lines, in a child <string key=...>."""
    if attribute == ELEMENT_TEXT:
        return element.text or ''
    if element.get(attribute) is not None:
        return element.get(attribute)
    child = element.find(f"string[@key='{attribute}']")
    if child is None:
        return None
    if child.get('base64-UTF8') == 'YES':
        raw = ''.join((child.text or '').split())
        try:
            return base64.b64decode(raw + '=' * (-len(raw) % 4)).decode('utf-8')
        except ValueError:
            return child.text or ''
    return child.text or ''


def set_text(element, attribute, value):
    if attribute == ELEMENT_TEXT:
        element.text = value
    elif element.get(attribute) is not None:
        element.set(attribute, value)
    else:
        # A text over lines, kept in base64 as IB does: it may hold characters XML does not take.
        child = element.find(f"string[@key='{attribute}']")
        # Without its padding, as IB writes it: ibtool reads a padded string as empty.
        child.set('base64-UTF8', 'YES')
        child.text = base64.b64encode(value.encode('utf-8')).decode('ascii').rstrip('=')


def windows(root):
    """The top-level windows and panels of a XIB."""
    return [element for element in root.find('objects') if element.tag in ('window', 'panel')]


def window_outlets(root):
    """{window id: outlet property} of the windows the File's Owner reaches by an outlet."""
    owner = next((element for element in root.find('objects') if element.get('id') == '-2'), None)
    outlets = {}
    for outlet in (owner.iter('outlet') if owner is not None else []):
        outlets.setdefault(outlet.get('destination'), outlet.get('property'))
    return outlets


def key_of(element, parents):
    """A key that names the same element in every copy of a XIB: its id or, for the few elements IB gives none
    (a table's header cell, a segment), its parent's id and its place."""
    if element.get('id'):
        return element.get('id')
    parent = parents.get(element)
    place = list(parent).index(element) if parent is not None else 0
    return f'{key_of(parent, parents) if parent is not None else "?"}/{element.tag}{place}'


def _bound(control):
    names = {binding.get('name') for binding in control.findall('connections/binding')}
    return bool(names & DATA_BINDINGS.get(control.tag, set()))


def shown_texts(window, root, filled_in_code=()):
    """[(element, attribute)] of the texts the window shows, as CatalogTranslation reads them."""
    parents = {child: parent for parent in root.iter() for child in parent}
    # An outlet's name, or "#" and the id of an element (a table column whose cells the code makes).
    filled = {outlet.get('destination') for outlet in root.iter('outlet') if outlet.get('property') in filled_in_code}
    filled |= {name[1:] for name in filled_in_code if name.startswith('#')}

    def ancestors(element):
        while element in parents:
            element = parents[element]
            yield element

    found = []
    for element in window.iter():
        chain = list(ancestors(element))
        table = next((index for index, ancestor in enumerate(chain) if ancestor.tag in TABLES), None)
        controls = [ancestor for ancestor in [element] + chain if ancestor.tag in ('textField', 'button', 'popUpButton')]
        control = controls[0] if controls else None
        from_code = any(ancestor.get('id') in filled for ancestor in [element] + chain)
        if table is not None:
            # A table's rows are data: its headers, and the items of its pop-up cells, are texts.
            column = next((ancestor for ancestor in chain if ancestor.tag == 'tableColumn'), None)
            if element.tag == 'tableHeaderCell':
                found.append((element, 'title'))
            elif element.tag == 'tableColumn' and text_of(element, 'headerToolTip'):
                found.append((element, 'headerToolTip'))
            elif element.tag == 'menuItem' and column is not None and not from_code and any(
                    ancestor.tag == 'popUpButtonCell' and ancestor.get('key') == 'dataCell' for ancestor in chain):
                found.append((element, 'title'))
            continue
        # A search field's predicate bindings name, in its menu and placeholder, what it searches.
        if element.tag == 'string' and element.get('key') == 'NSDisplayName' and len(chain) > 1 \
                and chain[1].tag == 'binding' and re.fullmatch(r'predicate\d*', chain[1].get('name') or ''):
            found.append((element, ELEMENT_TEXT))
            continue
        # AppKit keeps tooltips on views, and drops those IB stores on a cell: only the cells of a matrix that
        # tells them where they are (TipMatrix) show theirs.
        if text_of(element, 'toolTip') and (not element.tag.endswith('Cell') or (
                element.get('key') != 'prototype'
                and any(ancestor.tag == 'matrix' and ancestor.get('customClass') == TIP_MATRIX for ancestor in chain))):
            found.append((element, 'toolTip'))
        data = control is not None and _bound(control)
        if element.tag == 'box' and element.get('titlePosition') != 'noTitle':
            found.append((element, 'title'))
        elif element.tag == 'buttonCell' and element.get('key') != 'prototype' and element.get('imagePosition') != 'only' \
                and element.get('transparent') != 'YES':
            if not data and not from_code:
                found.append((element, 'title'))
        elif element.tag in ('popUpButtonCell', 'menuItem'):
            if not data and not from_code:
                found.append((element, 'title'))
        elif element.tag in ('textFieldCell', 'searchFieldCell', 'comboBoxCell', 'tokenFieldCell'):
            found.append((element, 'placeholderString'))
            if element.tag == 'textFieldCell' and element.get('editable') != 'YES' and not data and not from_code:
                found.append((element, 'title'))
        elif element.tag == 'tabViewItem':
            found.append((element, 'label'))
        elif element.tag == 'segment':
            found.append((element, 'label'))
    return [(element, attribute) for element, attribute in found if (text_of(element, attribute) or '').strip()]


def texts(window, root, filled_in_code=()):
    """{(key, attribute): text} of a window."""
    parents = {child: parent for parent in root.iter() for child in parent}
    return {(key_of(element, parents), attribute): text_of(element, attribute)
            for element, attribute in shown_texts(window, root, filled_in_code)}


STRING = re.compile(r'NSLocalizedString\(\s*"((?:[^"\\]|\\.)*)"')


def code_strings(source):
    """The catalog keys a Swift source reads with NSLocalizedString."""
    escapes = {'n': '\n', 't': '\t', '"': '"', '\\': '\\', "'": "'", '0': '\0'}
    return {re.sub(r'\\(.)', lambda m: escapes.get(m.group(1), m.group(1)), match.group(1))
            for match in STRING.finditer(source)}


# The binding names translated nibs lose, so that a nib loads without the value transformers only the app registers.
BINDING = re.compile(r'<binding [^>]*/>|<binding [^>]*[^/]>.*?</binding>', re.S)

HARNESS = r'''
import AppKit
final class Owner: NSObject {
    override func value(forUndefinedKey key: String) -> Any? { nil }
    override func setValue(_ value: Any?, forUndefinedKey key: String) {}
}
var results: [[String: Any]] = []
var headers: [[String: Any]] = []
// Per column, as the nib loaded it, before the catalog and a layout pass: its width, and what its English header needs.
var loadedWidth: [ObjectIdentifier: CGFloat] = [:]
var englishNeeded: [ObjectIdentifier: CGFloat] = [:]
@MainActor func columns(in view: NSView) -> [NSTableColumn] {
    var found = (view as? NSTableView)?.tableColumns ?? []
    if let tabs = view as? NSTabView { found += tabs.tabViewItems.compactMap(\.view).flatMap { columns(in: $0) } }
    return found + view.subviews.flatMap { columns(in: $0) }
}
@MainActor func record(_ view: NSView, _ texts: inout [String], _ popUps: inout [[String: Any]]) {
    if let tip = view.toolTip { texts.append(tip) }
    switch view {
    case let tabs as NSTabView:
        for item in tabs.tabViewItems {
            texts.append(item.label)
            if let tip = item.toolTip { texts.append(tip) }
            if let content = item.view { record(content, &texts, &popUps) }
        }
        return
    case let table as NSTableView:
        for column in table.tableColumns {
            texts.append(column.title)
            if let tip = column.headerToolTip { texts.append(tip) }
            if let cell = column.dataCell as? NSPopUpButtonCell { texts += cell.itemTitles }
            // A header truncates its title when the title needs more than the column's width. The width is the
            // nib's, or the one after layout when wider: a table the pane's code adds columns to scrolls, and its own
            // columns keep the nib's widths, while here the last one may shrink to the table.
            if !column.title.isEmpty && !column.isHidden {
                var header: [String: Any] = ["id": column.identifier.rawValue, "title": column.title,
                                             "needed": column.headerCell.cellSize.width,
                                             "width": max(column.width, loadedWidth[ObjectIdentifier(column)] ?? 0)]
                if let english = englishNeeded[ObjectIdentifier(column)] { header["english"] = english }
                headers.append(header)
            }
        }
        return
    case let box as NSBox:
        if box.titlePosition != .noTitle { texts.append(box.title) }
    case let popUp as NSPopUpButton:
        texts += popUp.itemTitles
        texts.append(popUp.title)
        popUps.append(["id": popUp.identifier?.rawValue ?? "", "title": popUp.title, "needed": popUp.cell!.cellSize.width,
                       "width": popUp.frame.width])
    case let segments as NSSegmentedControl:
        for index in 0..<segments.segmentCount {
            if let label = segments.label(forSegment: index) { texts.append(label) }
            if let tip = segments.toolTip(forSegment: index) { texts.append(tip) }
        }
    case let matrix as NSMatrix:
        for cell in matrix.cells {
            texts.append(cell.title)
            if let tip = matrix.toolTip(for: cell) { texts.append(tip) }
        }
    case let button as NSButton:
        texts.append(button.title)
    case let field as NSTextField:
        if let placeholder = field.placeholderString { texts.append(placeholder) }
        if !field.isEditable { texts.append(field.stringValue) }
    default:
        break
    }
    for child in view.subviews { record(child, &texts, &popUps) }
}
// What a binding gives is data, which CatalogTranslation leaves alone: a bound label, button title and pop-up keep
// their text, while the same controls without a binding take the catalog's.
do {
    let model = NSObjectController(content: NSMutableDictionary(dictionary: ["text": "Cancel", "items": ["Cancel"]]))
    let boundLabel = NSTextField(labelWithString: "Cancel"), freeLabel = NSTextField(labelWithString: "Cancel")
    let boundButton = NSButton(title: "Cancel", target: nil, action: nil), freeButton = NSButton(title: "Cancel", target: nil, action: nil)
    let boundPopUp = NSPopUpButton(), freePopUp = NSPopUpButton()
    freePopUp.addItem(withTitle: "Cancel")
    boundLabel.bind(.value, to: model, withKeyPath: "content.text")
    boundButton.bind(.title, to: model, withKeyPath: "content.text")
    boundPopUp.bind(.content, to: model, withKeyPath: "content.items")
    let view = NSView()
    for control in [boundLabel, freeLabel, boundButton, freeButton, boundPopUp, freePopUp] as [NSView] { view.addSubview(control) }
    CatalogTranslation.translate([view], with: { $0 == "Cancel" ? "Annuler" : $0 })
    results.append(["label": "bindings", "window": "",
                    "bound": [boundLabel.stringValue, boundButton.title, boundPopUp.itemTitles.first ?? ""],
                    "free": [freeLabel.stringValue, freeButton.title, freePopUp.itemTitles.first ?? ""]])
}
// A control's own subviews are AppKit's drawing of it (a search field's magnifier is a button titled "search", which
// shows the title once one is set): CatalogTranslation reads a control's texts and leaves those subviews alone. The
// names a search field's predicate bindings give its menu and placeholder are read from the catalog.
@MainActor func drawing(of control: NSView) -> [String] {
    var lines: [String] = []
    func walk(_ view: NSView, _ path: String) {
        var line = "\(path) \(type(of: view))"
        if let button = view as? NSButton { line += " title=\(button.title)" }
        if let field = view as? NSTextField { line += " value=\(field.stringValue) placeholder=\(field.placeholderString ?? "")" }
        if let tip = view.toolTip { line += " tip=\(tip)" }
        lines.append(line)
        for (index, child) in view.subviews.enumerated() { walk(child, "\(path)/\(index)") }
    }
    for (index, child) in control.subviews.enumerated() { walk(child, "\(index)") }
    return lines
}
do {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    let people = NSArrayController(content: NSMutableArray())
    let search = NSSearchField(frame: NSRect(x: 10, y: 10, width: 200, height: 22))
    search.placeholderString = "All"
    search.bind(NSBindingName("predicate"), to: people, withKeyPath: "filterPredicate",
                options: [.displayName: "All", .predicateFormat: "(name contains[c] $value) or (address contains[c] $value)"])
    search.bind(NSBindingName("predicate2"), to: people, withKeyPath: "filterPredicate",
                options: [.displayName: "Address", .predicateFormat: "address contains[c] $value"])
    let picker = NSDatePicker(frame: NSRect(x: 220, y: 10, width: 100, height: 22))
    let tokens = NSTokenField(frame: NSRect(x: 10, y: 40, width: 200, height: 22))
    tokens.placeholderString = "Cancel"
    let combo = NSComboBox(frame: NSRect(x: 10, y: 70, width: 200, height: 22))
    combo.addItem(withObjectValue: "Cancel")
    let button = NSButton(title: "Cancel", target: nil, action: nil)
    let check = NSButton(checkboxWithTitle: "Cancel", target: nil, action: nil)
    let popUp = NSPopUpButton(frame: NSRect(x: 220, y: 40, width: 120, height: 26))
    popUp.addItem(withTitle: "Cancel")
    let segments = NSSegmentedControl(labels: ["Cancel"], trackingMode: .selectOne, target: nil, action: nil)
    let scroll = NSScrollView(frame: NSRect(x: 350, y: 10, width: 200, height: 150))
    let table = NSTableView()
    table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("column")))
    table.tableColumns[0].title = "Cancel"
    scroll.documentView = table
    let controls: [NSView] = [search, picker, tokens, combo, button, check, popUp, segments, scroll]
    for control in controls { window.contentView?.addSubview(control) }
    window.contentView?.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    let before = controls.map(drawing)
    CatalogTranslation.translate([window], with: { "«\($0)»" })
    window.contentView?.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    let after = controls.map(drawing)
    let names = ["predicate", "predicate2"].map {
        (search.infoForBinding(NSBindingName($0))?[.options] as? [NSBindingOption: Any])?[.displayName] as? String ?? ""
    }
    var changed: [String] = []
    for (index, control) in controls.enumerated() where before[index] != after[index] {
        changed.append("\(type(of: control)): \(before[index].joined(separator: "; ")) -> \(after[index].joined(separator: "; "))")
    }
    results.append(["label": "controls", "window": "", "changed": changed, "placeholder": search.placeholderString ?? "",
                    "predicateNames": names, "tokens": tokens.placeholderString ?? "",
                    "titles": [button.title, check.title, popUp.itemTitles.first ?? "", segments.label(forSegment: 0) ?? "",
                               table.tableColumns[0].title]])
}
@MainActor func view(_ id: String, in roots: [NSView]) -> NSView? {
    for root in roots {
        if root.identifier?.rawValue == id { return root }
        if let tabs = root as? NSTabView, let found = view(id, in: tabs.tabViewItems.compactMap(\.view)) { return found }
        if let found = view(id, in: root.subviews) { return found }
    }
    return nil
}
@MainActor func descendants(_ root: NSView) -> [NSView] {
    var found = [root]
    if let tabs = root as? NSTabView { found += tabs.tabViewItems.compactMap(\.view).flatMap(descendants) }
    return found + root.subviews.flatMap(descendants)
}
@MainActor func crossing(_ view: NSView) -> [String] {
    (view.superview?.subviews ?? []).filter { other in
        let common = other.frame.intersection(view.frame)
        return other !== view && !other.isHidden && !common.isNull && common.width > 1 && common.height > 1
    }.map { $0.identifier?.rawValue ?? "\(type(of: $0))" }
}
// What a pane's code does to the nib after loading it, given by a spec: the items it puts in pop-ups and in a table
// column's pop-up cells, the rows PaneFit.flowRow lays out, PaneFit.fitColumns, the date pickers PaneFit fits in
// each region, and the room the settings window's toolbar leaves a pane's title.
@MainActor func apply(_ spec: [String: Any], to loaded: [Any], label: String) -> [String: Any] {
    let windows = loaded.compactMap { $0 as? NSWindow }
    let roots = windows.compactMap(\.contentView)
    var report: [String: Any] = [:]
    for (id, titles) in spec["fill"] as? [String: [String]] ?? [:] {
        guard let popUp = view(id, in: roots) as? NSPopUpButton else { report["missing \(id)"] = true; continue }
        popUp.removeAllItems()
        popUp.addItems(withTitles: titles)
    }
    let tables = roots.flatMap(descendants).compactMap { $0 as? NSTableView }
    for (id, titles) in spec["columnItems"] as? [String: [String]] ?? [:] {
        guard let cell = tables.lazy.compactMap({ $0.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(id))?.dataCell as? NSPopUpButtonCell }).first
        else { report["missing \(id)"] = true; continue }
        cell.removeAllItems()
        cell.addItems(withTitles: titles)
    }
    for row in spec["flowRow"] as? [[String]] ?? [] {
        guard let first = view(row[0], in: roots) else { report["missing \(row[0])"] = true; continue }
        PaneFit.flowRow(startingAt: first, until: row.count > 1 ? view(row[1], in: roots) : nil)
    }
    if spec["fitColumns"] as? Bool == true { tables.forEach(PaneFit.fitColumns) }
    // A layout the user saved: the widths its columns are given back, the column the table is sorted by, and the
    // widening of the columns that cut their header under those widths.
    if let saved = spec["savedWidths"] as? [String: Double] {
        for table in tables where table.tableColumns.contains(where: { $0.identifier.rawValue == spec["savedTable"] as? String }) {
            for column in table.tableColumns {
                if let width = saved[column.identifier.rawValue] { column.width = CGFloat(width) }
            }
            if let key = spec["sortedBy"] as? String, let prototype = table.tableColumns.compactMap(\.sortDescriptorPrototype).first(where: { $0.key == key }) {
                table.sortDescriptors = [prototype]
            }
            report["restored"] = table.tableColumns.filter { !$0.isHidden }.map { column -> [String: Any] in
                ["id": column.identifier.rawValue, "width": column.width,
                 "indicator": column.headerCell.sortIndicatorRect(forBounds: NSRect(x: 0, y: 0, width: 200, height: table.headerView?.frame.height ?? 0)).width]
            }
            if spec["widenColumns"] as? Bool == true { report["widened"] = PaneFit.widenColumnsToHeaders(of: table) }
            report["saved"] = table.tableColumns.filter { !$0.isHidden }.map { column -> [String: Any] in
                ["id": column.identifier.rawValue, "title": column.title, "width": column.width,
                 "header": column.title.isEmpty ? 0 : column.headerCell.cellSize.width]
            }
        }
    }
    report["views"] = (spec["report"] as? [String] ?? []).compactMap { id -> [String: Any]? in
        guard let found = view(id, in: roots) else { return nil }
        return ["id": id, "minX": found.frame.minX, "maxX": found.frame.maxX, "width": found.frame.width,
                "needed": PaneFit.neededWidth(of: found), "label": (found as? NSTextField).map { !$0.isEditable } ?? false,
                "superWidth": found.superview?.bounds.width ?? 0, "crossing": crossing(found)]
    }
    report["columns"] = tables.flatMap { table in
        table.tableColumns.filter { !$0.isHidden }.map { column -> [String: Any] in
            ["id": column.identifier.rawValue, "title": column.title, "width": column.width,
             "header": column.title.isEmpty ? 0 : column.headerCell.cellSize.width,
             "cell": (column.dataCell as? NSPopUpButtonCell)?.cellSize.width ?? 0,
             "items": (column.dataCell as? NSPopUpButtonCell)?.itemTitles ?? [],
             // A column of controls (pop-ups, checkboxes) needs its control; a column of text holds the user's data.
             "control": column.dataCell is NSButtonCell, "minWidth": column.minWidth,
             "loaded": loadedWidth[ObjectIdentifier(column)] ?? column.width,
             "controlNeeds": (column.dataCell as? NSButtonCell)?.cellSize.width ?? 0]
        }
    }
    var pickers: [[String: Any]] = []
    for locale in spec["datePickerLocales"] as? [String] ?? [] {
        for root in roots {
            let all = descendants(root)
            let frames = all.map(\.frame)
            let found = all.compactMap { $0 as? NSDatePicker }
            for picker in found { picker.locale = Locale(identifier: locale) }
            PaneFit.fitDatePickers(in: root)
            for picker in found {
                // What AppKit measures for the widest date of the picker's format in that locale, not PaneFit's figure.
                pickers.append(["locale": locale, "id": picker.identifier?.rawValue ?? "", "width": picker.frame.width,
                                "needed": picker.cell?.cellSize.width ?? .infinity, "crossing": crossing(picker),
                                "inside": picker.frame.maxX <= (picker.superview?.bounds.maxX ?? 0) + 0.5])
            }
            for (index, view) in all.enumerated() { view.frame = frames[index] }
        }
    }
    report["datePickers"] = pickers
    if let titles = spec["titles"] as? [[Any]], let window = windows.first(where: { $0.toolbar != nil }) {
        var room: [[String: Any]] = []
        for entry in titles {
            guard let title = entry.first as? String, let width = (entry.last as? NSNumber)?.doubleValue else { continue }
            window.title = title
            window.titleVisibility = .visible
            window.setContentSize(NSSize(width: width, height: 300))
            window.layoutIfNeeded()
            var fields: [NSTextField] = []
            func find(_ view: NSView) {
                if let field = view as? NSTextField, field.stringValue == title { fields.append(field) }
                view.subviews.forEach(find)
            }
            if let frame = window.contentView?.superview { find(frame) }
            if let field = fields.first {
                room.append(["title": title, "paneWidth": width, "width": field.frame.width, "needed": field.cell?.cellSize.width ?? 0])
            } else {
                room.append(["title": title, "paneWidth": width, "missing": true])
            }
        }
        report["titleRoom"] = room
    }
    return report
}
// Arguments in fours: a label, a compiled nib, the JSON of a catalog, or "-" for a copy shown as it is, and the JSON
// of a spec of what the pane's code does after loading the nib, or "-".
var arguments = Array(CommandLine.arguments.dropFirst())
while arguments.count >= 4 {
    let (label, path, strings, specPath) = (arguments[0], arguments[1], arguments[2], arguments[3])
    arguments.removeFirst(4)
    var objects: NSArray?
    let nib = NSNib(nibData: try! Data(contentsOf: URL(fileURLWithPath: path)), bundle: nil)
    guard nib.instantiate(withOwner: Owner(), topLevelObjects: &objects), let loaded = objects.map({ Array($0) }) else {
        results.append(["label": label, "error": "the nib did not load"]); continue
    }
    let tableColumns = loaded.compactMap { ($0 as? NSWindow)?.contentView }.flatMap { columns(in: $0) }
    (loadedWidth, englishNeeded) = ([:], [:])  // the columns of a former run are gone, and their identifiers reused
    for column in tableColumns { loadedWidth[ObjectIdentifier(column)] = column.width }
    if strings != "-" {
        for column in tableColumns where !column.title.isEmpty {
            englishNeeded[ObjectIdentifier(column)] = column.headerCell.cellSize.width
        }
        let catalog = try! JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: strings)))
        CatalogTranslation.translate(loaded, with: { catalog[$0] ?? $0 })
    }
    // What the pane's code does after loading the nib comes before what the windows show is recorded.
    var report: [String: Any]?
    if specPath != "-", let spec = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: specPath))) as? [String: Any] {
        report = apply(spec, to: loaded, label: label)
    }
    for case let window as NSWindow in loaded {
        var texts: [String] = []
        var popUps: [[String: Any]] = []
        headers = []
        // A window laid out by constraints has its frames only after a layout pass.
        window.contentView?.layoutSubtreeIfNeeded()
        if let content = window.contentView { record(content, &texts, &popUps) }
        for item in window.toolbar?.items ?? [] {
            texts += [item.label, item.paletteLabel]
            if let view = item.view { record(view, &texts, &popUps) }
        }
        results.append(["label": label, "window": window.identifier?.rawValue ?? "", "texts": texts, "popUps": popUps,
                        "headers": headers])
    }
    if var report {
        report["label"] = "spec|" + label
        report["window"] = ""
        results.append(report)
    }
}
print(String(data: try! JSONSerialization.data(withJSONObject: results), encoding: .utf8)!)
'''


IDENTIFIED = re.compile(r'<(window|panel|popUpButton|button|textField|datePicker|searchField) ([^>]*?)id="([^"]+)"([^>]*)>')


def compile_nib(text, folder, name):
    """A XIB's text compiled, without its bindings and with the XIB id of each window and control (that has no
    identifier of its own) as its identifier."""
    text = BINDING.sub('', text)
    text = IDENTIFIED.sub(lambda m: m.group(0) if 'identifier=' in m.group(2) + m.group(4)
                          else f'<{m.group(1)} {m.group(2)}id="{m.group(3)}" identifier="{m.group(3)}"{m.group(4)}>', text)
    xib, nib = Path(folder) / f'{name}.xib', Path(folder) / f'{name}.nib'
    xib.write_text(text, encoding='utf-8')
    built = subprocess.run(['xcrun', 'ibtool', '--compile', str(nib), str(xib)], capture_output=True, text=True)
    if built.returncode or not nib.exists():
        raise RuntimeError(f'{name} does not compile\n{built.stdout[-800:]}{built.stderr[-800:]}')
    return nib


def run_harness(helper_source, runs, folder):
    """runs: [(label, nib, catalog dict or None[, spec dict])]. Returns, per label and window id,
    {'texts': [...], 'popUps': [{id, title, needed, width}], 'headers': [{id, title, needed, width, english}]} (english:
    what the header needed in English, in a run with a catalog); under ('bindings', '') the texts of bound and
    unbound controls CatalogTranslation was run on ({'bound': [...], 'free': [...]}); under ('controls', '') what it
    changed in the subviews of standard controls ('changed'), the search field's placeholder and predicate names, and
    the controls' own titles, with a catalog that writes each text in «»; and under ('spec|' + label, '') what a run's
    spec gave: {'views', 'columns', 'datePickers', 'titleRoom'}, and for a spec with 'savedWidths' (the widths, by
    identifier, given back to the columns of the table that has the column 'savedTable', sorted by 'sortedBy')
    {'restored', 'widened', 'saved'}: the columns under those widths, whether PaneFit.widenColumnsToHeaders
    ('widenColumns') widened one, and the columns after it. Raises if CatalogTranslation does not compile."""
    folder = Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    (folder / 'main.swift').write_text(HARNESS, encoding='utf-8')
    (folder / 'PaneCatalogTranslation.swift').write_text(helper_source, encoding='utf-8')
    # The matrices of the nibs are TipMatrix: without the class a nib loads a plain matrix, which drops the
    # tooltips of its cells.
    compiled = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-module-cache-path', str(folder / 'modules'),
                               str(folder / 'main.swift'), str(folder / 'PaneCatalogTranslation.swift'),
                               str(ROOT / TIP_MATRIX_SOURCE), '-o', str(folder / 'harness')], capture_output=True, text=True)
    if compiled.returncode:
        raise RuntimeError('the harness with CatalogTranslation does not compile\n'
                           + compiled.stdout[-2000:] + compiled.stderr[-2000:])
    arguments = []
    for index, (label, nib, strings, *spec) in enumerate(runs):
        if strings is None:
            arguments += [label, str(nib), '-']
        else:
            path = folder / f'catalog-{index}.json'
            path.write_text(json.dumps(strings), encoding='utf-8')
            arguments += [label, str(nib), str(path)]
        if spec and spec[0]:
            path = folder / f'spec-{index}.json'
            path.write_text(json.dumps(spec[0]), encoding='utf-8')
            arguments.append(str(path))
        else:
            arguments.append('-')
    ran = subprocess.run([str(folder / 'harness'), *arguments], capture_output=True, text=True, timeout=600, check=True)
    shown = {}
    for item in json.loads(ran.stdout):
        if 'error' in item:
            raise RuntimeError(f'{item["label"]}: {item["error"]}')
        shown[(item['label'], item['window'])] = item
    return shown
