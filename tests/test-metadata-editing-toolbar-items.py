#!/usr/bin/env python3
"""The Meta-Data window's DICOM editing commands are ordinary toolbar items.

Edit, Add, Apply and the level the modifications apply to were one toolbar
item whose view, 42 points high, stacked the three buttons over labels of its
own beside two rows of radio buttons. A toolbar that gives a labelled item
less height than that (the one of macOS 15 does) draws the item's label over
the lower part of the view, on the labels inside it.

XMLEditingToolbarItem.swift is compiled here against stand-ins for the window
controller and the toolbar policy, and its items are asked for as a toolbar
asks:

- Edit, Add and Apply are items with an image, a label and an action and no
  view, so the toolbar draws their labels; the level is a pop-up button of
  the height of a control, with its four levels in the order of their tags;
- no view of an item holds a label, and none is higher than a control;
- Add and the level are usable while the window edits, Apply when there is a
  modification to write, and Edit shows another image while it edits; the
  pop-up sets the window's level and follows it;
- an identifier that is none of these gets no item, and asking raises nothing;
- a toolbar saved while the four were one item, "Editing", gets them where
  that item was; one of the four the toolbar already has is not put twice.

In the sources: the window offers the four in a new toolbar, accepts the
single item only until the four have taken its place, and gives the search
item the height of its field. No XMLViewer.xib keeps the editing view, the
search view of each is as high as its field, and every language has the
labels.
"""
import private_tmpdir  # noqa: F401
from pathlib import Path
import json
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

from sources import source_text

ROOT = Path(__file__).resolve().parents[1]
CONTROL_HEIGHT = 30
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


driver = r'''
import AppKit

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: " + message); failures += 1 }
}

// The window controller, as far as the items know it.
final class XMLController: NSObject {
    private var editing = false
    private var modifications = 0
    var calls: [String] = []
    @objc dynamic var editingLevel: Int32 = 1
    @objc dynamic var editingActivated: Bool {
        get { editing }
        set { editing = newValue }
    }
    @objc(modificationsToApply) func modificationsToApply() -> Bool { modifications > 0 }
    @objc(switchEditing:) func switchEditing(_ sender: Any?) {
        calls.append("switchEditing")
        editing.toggle()
        willChangeValue(forKey: "editingActivated")
        didChangeValue(forKey: "editingActivated")
    }
    @objc(addDICOMField:) func addDICOMField(_ sender: Any?) { calls.append("addDICOMField") }
    @objc(applyModifications:) func applyModifications(_ sender: Any?) {
        calls.append("applyModifications")
        modify(-modifications)
    }
    func modify(_ count: Int) {
        willChangeValue(forKey: "modificationsToApply")
        modifications += count
        didChangeValue(forKey: "modificationsToApply")
    }
}

@MainActor enum ToolbarPolicy {
    static var constrained: [String: NSSize] = [:]
    static func prepare(_ item: NSToolbarItem?) {}
    static func constrainView(of item: NSToolbarItem?, minimum: NSSize, maximum: NSSize) {
        if let item, minimum == maximum { constrained[item.itemIdentifier.rawValue] = minimum }
    }
}

@MainActor final class Delegate: NSObject, NSToolbarDelegate {
    let controller: XMLController
    var allowed: [String]
    init(controller: XMLController, allowed: [String]) { self.controller = controller; self.allowed = allowed }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if let item = XMLEditingToolbarItem.item(identifier.rawValue, for: controller) { return item }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = identifier.rawValue
        return item
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { allowed.map { NSToolbarItem.Identifier($0) } }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        (allowed + XMLEditingToolbarItem.identifiers + [XMLEditingToolbarItem.legacyIdentifier]).map { NSToolbarItem.Identifier($0) }
    }
}

@MainActor func labels(in view: NSView?) -> [NSView] {
    guard let view else { return [] }
    let own: [NSView] = view is NSTextField ? [view] : []
    return own + view.subviews.flatMap { labels(in: $0) }
}

@MainActor func run() {
    // The application's images, which this program has no bundle for.
    let artwork = ["Autofill", "add-large", "Save"].map { name -> NSImage in
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in NSColor.gray.setFill(); rect.fill(); return true }
        image.setName(name)
        return image
    }
    defer { _ = artwork }
    let controller = XMLController()
    check(XMLEditingToolbarItem.identifiers == ["EditingEdit", "EditingAdd", "EditingApply", "EditingLevel"], "the four items changed: \(XMLEditingToolbarItem.identifiers)")
    check(XMLEditingToolbarItem.legacyIdentifier == "Editing", "the single item a saved toolbar names is no longer Editing")

    // An identifier of another item: nothing, and nothing raised when what was made for it goes.
    for other in ["Search", "Export.icns", "", "EditingOther"] {
        autoreleasepool { check(XMLEditingToolbarItem.item(other, for: controller) == nil, "\(other) got an editing item") }
    }

    var items: [String: NSToolbarItem] = [:]
    for identifier in XMLEditingToolbarItem.identifiers { items[identifier] = XMLEditingToolbarItem.item(identifier, for: controller) }
    guard let edit = items["EditingEdit"], let add = items["EditingAdd"], let apply = items["EditingApply"], let level = items["EditingLevel"] else {
        check(false, "one of the four has no item"); return
    }
    for (item, action) in [(edit, "switchEditing:"), (add, "addDICOMField:"), (apply, "applyModifications:")] {
        let name = item.itemIdentifier.rawValue
        check(item.view == nil, "\(name) has a view: the toolbar does not draw it as its other items")
        check(!item.label.isEmpty && item.paletteLabel == item.label && !(item.toolTip ?? "").isEmpty, "\(name) lacks a label or a tooltip")
        check(item.target === controller && item.action.map(NSStringFromSelector) == action, "\(name) does not send \(action) to the window")
        check(!item.autovalidates, "\(name) is validated by the toolbar, which knows nothing of the editing")
    }
    check(Set([edit.label, add.label, apply.label, level.label]).count == 4, "two items share a label")
    guard let popUp = level.view as? NSPopUpButton else { check(false, "the level is not a pop-up button"); return }
    check(popUp.itemArray.map(\.tag) == [0, 1, 2, 3] && popUp.numberOfItems == 4 && Set(popUp.itemTitles).count == 4, "the levels are not the four, by their tags: \(popUp.itemTitles)")
    check(popUp.frame.height > 0 && popUp.frame.height <= CONTROLHEIGHT, "the level's pop-up is \(popUp.frame.height) points high")
    check(ToolbarPolicy.constrained["EditingLevel"] == popUp.frame.size, "the level's view is not kept at the pop-up's size")
    for item in [edit, add, apply, level] {
        check(labels(in: item.view).isEmpty, "\(item.itemIdentifier.rawValue) holds a label of its own")
        check((item.view?.frame.height ?? 0) <= CONTROLHEIGHT, "\(item.itemIdentifier.rawValue) has a view higher than a control")
    }

    // What the window is doing.
    func state() -> [Bool] { [add.isEnabled, apply.isEnabled, level.isEnabled, popUp.isEnabled] }
    check(state() == [false, false, false, false], "Add, Apply or the level is usable before the window edits: \(state())")
    check(popUp.selectedTag() == 1, "the pop-up does not open on the window's level")
    let idle = edit.image
    check(idle != nil, "Edit has no image")
    _ = edit.target?.perform(edit.action, with: edit)
    check(controller.editingActivated && state() == [true, false, true, true], "editing on: \(state())")
    check(edit.image != nil && edit.image !== idle, "Edit looks the same while the window edits")
    controller.modify(2)
    check(state() == [true, true, true, true], "a modification to write: \(state())")
    _ = apply.target?.perform(apply.action, with: apply)
    check(state() == [true, false, true, true], "after applying: \(state())")
    popUp.selectItem(withTag: 3)
    _ = popUp.target?.perform(popUp.action, with: popUp)
    check(controller.editingLevel == 3, "the pop-up does not set the window's level: \(controller.editingLevel)")
    controller.editingLevel = 0
    controller.modify(1)
    check(popUp.selectedTag() == 0, "the pop-up does not follow the window's level")
    _ = edit.target?.perform(edit.action, with: edit)
    check(!controller.editingActivated && state() == [false, false, false, false], "editing off: \(state())")
    check(edit.image === idle, "Edit keeps its pressed image after the editing")
    check(controller.calls == ["switchEditing", "applyModifications", "switchEditing"], "the items sent \(controller.calls)")

    // The single item of a saved toolbar: the four as one group.
    guard let group = XMLEditingToolbarItem.item("Editing", for: controller) as? NSToolbarItemGroup else { check(false, "Editing is not answered with a group"); return }
    check(group.subitems.map(\.itemIdentifier.rawValue) == XMLEditingToolbarItem.identifiers && !group.label.isEmpty, "the group does not hold the four")

    // A toolbar saved with it gets the four where it was.
    func identifiers(_ toolbar: NSToolbar) -> [String] { toolbar.items.map(\.itemIdentifier.rawValue) }
    func toolbar(_ saved: [String], _ name: String) -> (NSToolbar, Delegate) {
        let delegate = Delegate(controller: controller, allowed: ["Search", "Export.icns", "Validator"])
        let toolbar = NSToolbar(identifier: "test-" + name)
        toolbar.autosavesConfiguration = false
        toolbar.delegate = delegate
        while !toolbar.items.isEmpty { toolbar.removeItem(at: 0) }
        for (index, identifier) in saved.enumerated() { toolbar.insertItem(withItemIdentifier: NSToolbarItem.Identifier(identifier), at: index) }
        return (toolbar, delegate)
    }
    let (saved, savedDelegate) = toolbar(["Search", "Editing", "Export.icns", "Validator"], "saved")
    check(identifiers(saved) == ["Search", "Editing", "Export.icns", "Validator"], "the saved toolbar was not built: \(identifiers(saved))")
    XMLEditingToolbarItem.replaceLegacyItem(in: saved)
    check(identifiers(saved) == ["Search", "EditingEdit", "EditingAdd", "EditingApply", "EditingLevel", "Export.icns", "Validator"], "the four did not take the single item's place: \(identifiers(saved))")
    XMLEditingToolbarItem.replaceLegacyItem(in: saved)
    check(identifiers(saved).count == 7, "replacing twice changed the toolbar")
    let (partial, partialDelegate) = toolbar(["EditingAdd", "Search", "Editing"], "partial")
    XMLEditingToolbarItem.replaceLegacyItem(in: partial)
    check(identifiers(partial) == ["EditingAdd", "Search", "EditingEdit", "EditingApply", "EditingLevel"], "an item the toolbar had was put twice or moved: \(identifiers(partial))")
    let (plain, plainDelegate) = toolbar(["Search", "EditingEdit", "Validator"], "plain")
    XMLEditingToolbarItem.replaceLegacyItem(in: plain)
    check(identifiers(plain) == ["Search", "EditingEdit", "Validator"], "a toolbar without the single item was changed: \(identifiers(plain))")
    XMLEditingToolbarItem.replaceLegacyItem(in: nil)
    _ = (savedDelegate, partialDelegate, plainDelegate)
}

MainActor.assumeIsolated { autoreleasepool { run() } }
if failures > 0 { exit(1) }
print("PASS: Edit, Add and Apply are plain toolbar items and the level a pop-up of a control's height; they follow what the window edits; a saved toolbar's single item gives way to the four where it was")
'''.replace('CONTROLHEIGHT', str(CONTROL_HEIGHT))

with tempfile.TemporaryDirectory(prefix='horos-xml-toolbar-') as directory:
    work = Path(directory)
    (work / 'main.swift').write_text(driver)
    build = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(work / 'cache'),
                            str(ROOT / 'Horos/Sources/XMLEditingToolbarItem.swift'), str(work / 'main.swift'), '-o', str(work / 'test')],
                           capture_output=True, text=True, timeout=600)
    if build.returncode:
        print(build.stdout + build.stderr)
        sys.exit(1)
    run = subprocess.run([str(work / 'test')], capture_output=True, text=True, timeout=120)
    print((run.stdout + run.stderr).strip())
    check(run.returncode == 0, f'the items failed (exit {run.returncode})')

controller = source_text('XMLController')
check('} else if let editing = XMLEditingToolbarItem.item(itemIdent, for: self) {' in controller, 'the window does not ask XMLEditingToolbarItem for its items')
check('.flexibleSpace] + XMLEditingToolbarItem.identifiers.map { NSToolbarItem.Identifier($0) } + [' in controller, 'a new toolbar does not show the four')
check('array.addObjects(from: XMLEditingToolbarItem.identifiers)' in controller
      and 'if acceptsLegacyEditingItem { array.add(XMLEditingToolbarItem.legacyIdentifier) }' in controller, 'the palette offers the single item, or not the four')
setup = controller[controller.index('public func setupToolbar()'):]
setup = setup[:setup.index('\n    }\n')]
check(setup.index('self.window?.toolbar = toolbar') < setup.index('XMLEditingToolbarItem.replaceLegacyItem(in: toolbar)') < setup.index('acceptsLegacyEditingItem = false'),
      'the four do not take the single item\'s place once the saved toolbar is loaded')
check('dicomEditingView' not in controller, 'the window still has the editing view')
check('size.height = max(size.height, (search?.intrinsicContentSize.height ?? 0).rounded(.up))' in controller
      and 'ToolbarPolicy.constrainView(of: toolbarItem, minimum: size, maximum: size)' in controller, 'the search item is not as high as its field')

geometries = {}
for path in sorted((ROOT / 'Horos/Resources').glob('*.lproj/XMLViewer.xib')):
    language = path.parent.name
    text = path.read_text()
    tree = ET.parse(path)
    check('dicomEditingView' not in text and tree.find('.//customView[@id="53"]') is None, f'{language}: the nib keeps the editing view')
    check(tree.find('.//matrix') is None, f'{language}: the nib keeps a radio matrix')
    search = tree.find('.//customView[@id="26"]')
    check(search is not None, f'{language}: no search view')
    if search is None:
        continue
    field = search.find('subviews/searchField')
    rect = lambda node: tuple(float(node.find('rect[@key="frame"]').get(key)) for key in ('x', 'y', 'width', 'height'))
    check(field is not None and len(list(search.find('subviews'))) == 1, f'{language}: the search view holds more than its field')
    check(rect(search)[3] <= CONTROL_HEIGHT and field is not None and rect(search)[3] == rect(field)[3] and rect(field)[1] == 0,
          f'{language}: the search view is {rect(search)[3]:g} points high, its field {rect(field)[3]:g} at {rect(field)[1]:g}')
    geometries[language] = (rect(search), rect(field))
# English and the eight languages that have a copy of the nib; the others read the English one with their catalog.
check(len(geometries) >= 9, f'only {len(geometries)} XMLViewer.xib found')
check(len(set(geometries.values())) == 1, 'the languages do not share one geometry')

keys = ['Edit', 'Add', 'Apply', 'Level', 'Image', 'Series', 'Study', 'Patient', 'DICOM Editing', 'Activate the edition', 'Add a new group/element',
        'Save the modifications to the file', 'Apply the modifications to this image, to its series, to its study or to the patient']
item = source_text('XMLEditingToolbarItem')
for key in keys:
    check(f'NSLocalizedString("{key}"' in item, f'the items no longer use "{key}"')
catalogs = sorted((ROOT / 'Horos/Resources').glob('*.lproj/Localizable.strings'))
check(len(catalogs) == 12, f'{len(catalogs)} catalogs')
for catalog in catalogs:
    language = catalog.parent.name
    strings = json.loads(subprocess.run(['plutil', '-convert', 'json', '-o', '-', str(catalog)], capture_output=True, text=True, check=True).stdout)
    for key in keys:
        check(bool(strings.get(key)), f'{language}: no "{key}"')
    if language not in ('en.lproj',):
        check(strings.get('Level') != 'Level', f'{language}: Level is not translated')
        check(strings.get('Apply the modifications to this image, to its series, to its study or to the patient') != keys[-1], f'{language}: the level\'s tooltip is not translated')

if failures:
    for failure in failures:
        print(f'FAIL: {failure}')
    sys.exit(1)
print(f'PASS: the window offers the four items and replaces the single one; {len(geometries)} nibs keep only a search view of a control\'s height; 12 languages have the labels')
