#!/usr/bin/env python3
"""The 3D MPR toolbar views lay out whole, in the palette and on the bar.

Shadings: the Shading check box started 1 pt left of its view and the
Edit button 2 pt from it, so the rounded capsule of the Customize Toolbar
panel cut them; the three-line text was 81 pt wide, narrower than the lines
MPRController writes, and 36 pt tall in a 35 pt view. The controls now sit
6 pt and more inside the view and the text has the room of its three lines,
written as the VR window writes them ("Specular: 0.44/44.44", the widest the
shading panel's ranges give). The item takes its view's frame as its maximum
size, so it does not grow into empty room on the bar.

The check box's title was cut at the 65 pt of its frame in the languages that
write «Shading» longer (pt-BR, de, ru). MPRShadingItemLayout replaces the
frames by constraints and the item takes the width the running language asks
(ToolbarPolicy.localizedSize): in every localization the check box is as wide
as its title, the button as its own, and neither reaches the values. The check
box shows whether the hidden view renders with shading when the window opens.

Thick Slab: the mode popup showed "MIP - Max Intensity Pr..." cut in
its 132 pt. HorosMPRThickSlabModePopUpButtonCell draws the name before the
dash ("MIP") and keeps the full names in the menu, which the overflow menu
copies. The dash is the one the language writes: the German copy, which has
an en dash, and the Russian one, which has an em dash for one mode, showed
the whole name cut; every mode of every copy is checked.

The views of every MPR.xib localization are copied into a nib of their own,
compiled with ibtool and loaded in AppKit; the palette is opened on a toolbar
that holds none of them, so each goes through the snapshot window, and the
items are then put on an Expanded bar, as MPRController does, next to a
flexible space.

`<git revision>` as an optional argument reads the nibs from that revision:
that is the negative control.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from copy import deepcopy
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parent))
import isix_modules  # noqa: E402  - the mode popup takes a mode's short name from IsiXImaging
import sources

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None

# The views MPRController hands to its toolbar items, by the item they serve.
VIEWS = {'tbShading': '731', 'tbThickSlab': '659'}
KEEP_CLASSES = {'HorosMPRThickSlabModePopUpButtonCell'}
SWIFT = [root / 'Horos/Sources/MPRToolbarItemViews.swift', root / 'Horos/Sources/ToolbarMenuBridge.swift']
LOCALES = tuple(sorted(p.parent.name[:-6] for p in (root / 'Horos/Resources').glob('*.lproj/MPR.xib')))


def read(relative):
    if revision is None:
        return (root / relative).read_bytes()
    return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{relative}'],
                                   stderr=subprocess.DEVNULL)


def body(text, signature):
    at = text.find(signature)
    if at < 0:
        return ''
    opening = text.index('{', at)
    depth = 0
    for index in range(opening, len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[opening:index + 1]
    return ''


failures = []
mpr = read(str(sources.source_path('MPRController').relative_to(root))).decode('utf-8')
view_item = body(mpr, 'func viewItem(_ label: String, _ view: NSView?)')
if 'ToolbarPolicy.constrainView(of: toolbarItem, minimum: size, maximum: size)' not in view_item:
    failures.append('MPR view items do not use the fixed view contract exercised below')
if not re.search(r'itemIdent\.rawValue == "tbShading" \{\s*let widest = ShadingValuesText\.localized\(.*?\)\)\s*'
                 r'MPRShadingItemLayout\.fill\(toolbarItem, view: tbShading, check: shadingCheck, values: shadingValues, '
                 r'widestText: widest\)\s*\}', mpr):
    failures.append('the Shadings item is not laid out on constraints and sized for the running language')
if not re.search(r'horosShowShadingValues\(\)\s*shadingCheck\?\.state = \(hiddenVRView\?\.shading\(\) \?\? 0\) != 0 '
                 r'\? \.on : \.off\s*let nc = NotificationCenter', mpr):
    failures.append('the Shading check box is not given the state the hidden view renders with when the window is made')

code = r'''
import AppKit
import IsiXImaging

final class Host: NSObject, NSToolbarDelegate {
    var views: [String: NSView] = [:]
    var onBar: [NSToolbarItem.Identifier] = []
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { onBar }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        views.keys.sorted().map { NSToolbarItem.Identifier($0) } + [.flexibleSpace]
    }
    // As MPRController's viewItem does, with the maximum size the source check requires.
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        guard let view = views[id.rawValue] else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = "Thick Slab"
        item.paletteLabel = item.label
        item.view = view
        if id.rawValue == "tbShading" {
            let buttons = descendants(NSButton.self, in: view)
            MPRShadingItemLayout.fill(item, view: view, check: buttons.first { $0.imagePosition == .imageLeft },
                                      values: descendants(NSTextField.self, in: view).first { $0.stringValue.contains("\n") },
                                      widestText: widestValues)
            item.isBordered = false
            return item
        }
        let size = ToolbarPolicy.designedSize(of: view)
        ToolbarPolicy.constrainView(of: item, minimum: size, maximum: size)
        item.isBordered = false
        return item
    }
}

let widestValues = "Ambient: 0.44\nDiffuse: 0.44\nSpecular: 0.44/44.44"
var failures: [String] = []
func check(_ condition: Bool, _ message: @autoclosure () -> String) {
    if !condition { failures.append(message()) }
}
func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
    ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants(type, in: $0) }
}

/// Every control of the Shading view whole inside it, off the capsule's edge.
@MainActor func checkShading(_ view: NSView, _ context: String) {
    let design = ToolbarPolicy.localizedSize(of: view)
    check(abs(view.frame.width - design.width) <= 0.5 && abs(view.frame.height - design.height) <= 0.5,
          "\(context): view \(view.frame.size), asked \(design)")
    let buttons = descendants(NSButton.self, in: view)
    let texts = descendants(NSTextField.self, in: view).filter { $0.stringValue.contains("\n") }
    for button in buttons {
        check(button.intrinsicContentSize.width <= button.frame.width + 0.5,
              "\(context) \(button.title): the title needs \(button.intrinsicContentSize.width) pt, the button has \(button.frame.width)")
        if let text = texts.first {
            check(button.frame.maxX <= text.frame.minX, "\(context) \(button.title): \(button.frame) reaches the values \(text.frame)")
        }
    }
    check(buttons.count == 2, "\(context): \(buttons.count) buttons")
    check(texts.count == 1, "\(context): \(texts.count) shading texts")
    for control in buttons as [NSView] + texts as [NSView] {
        let frame = control.convert(control.bounds, to: view)
        let name = (control as? NSButton)?.title ?? "text"
        check(frame.minX >= 6 && frame.maxX <= view.bounds.maxX - 4 && frame.minY >= 0 && frame.maxY <= view.bounds.maxY,
              "\(context) \(name): \(frame) not inside \(view.bounds) with a margin")
    }
    if let text = texts.first {
        let fit = text.fittingSize
        check(fit.width <= text.frame.width && fit.height <= text.frame.height,
              "\(context): the three lines need \(fit), the text has \(text.frame.size)")
    }
}

/// The mode popup shows the short name of every mode, whole, with the full
/// names in its menu and in the overflow menu.
@MainActor func checkThickSlab(_ view: NSView, _ item: NSToolbarItem?, _ context: String) {
    let popups = descendants(NSPopUpButton.self, in: view)
    check(popups.count == 1, "\(context) Thick Slab: \(popups.count) popups")
    guard let popup = popups.first, let cell = popup.cell as? NSPopUpButtonCell else { return }
    // In every language: the name up to the dash the language writes, whole
    // in the popup, with the menu's name as the tooltip.
    for (index, listed) in popup.itemArray.enumerated() {
        popup.selectItem(at: index)
        let shown = cell.menuItem?.title ?? ""
        check(shown == ThickSlabModeName.short(of: listed.title) && !shown.isEmpty,
              "\(context) Thick Slab: the popup shows \"\(shown)\" for \"\(listed.title)\"")
        check(!shown.contains(" - ") && !shown.contains(" \u{2013} ") && !shown.contains(" \u{2014} "),
              "\(context) Thick Slab: the popup shows \"\(shown)\", dash and all")
        // A mode with no abbreviation is as wide as its translation, which
        // is the nib's to hold; the abbreviation of one that has it fits.
        check(shown == listed.title.trimmingCharacters(in: .whitespaces) || cell.cellSize.width <= popup.frame.width,
              "\(context) Thick Slab: \"\(shown)\" needs \(cell.cellSize.width) pt in a \(popup.frame.width) pt popup")
        check(popup.toolTip == listed.title, "\(context) Thick Slab: tooltip \(popup.toolTip ?? "nil") for \"\(listed.title)\"")
    }
    // The names of the nib that keeps the modes in English.
    guard context.hasPrefix("en ") else { popup.selectItem(withTag: 1); return }
    let expected = [1: ("MIP", "MIP - Max Intensity Projection"), 2: ("minIP", "minIP - Min Intensity Projection"),
                    3: ("Mean", "Mean"), 0: ("Volume Rendering", "Volume Rendering ")]
    for (tag, names) in expected.sorted(by: { $0.key < $1.key }) {
        check(popup.selectItem(withTag: tag), "\(context) Thick Slab: no mode \(tag)")
        check(popup.selectedTag() == tag, "\(context) Thick Slab: selected \(popup.selectedTag()), not \(tag)")
        check(popup.selectedItem?.title == names.1, "\(context) Thick Slab: the menu names \(tag) \"\(popup.selectedItem?.title ?? "")\"")
        check(cell.menuItem?.title == names.0, "\(context) Thick Slab: the popup shows \"\(cell.menuItem?.title ?? "")\" for \(names.1)")
        check(cell.cellSize.width <= popup.frame.width,
              "\(context) Thick Slab: \"\(cell.menuItem?.title ?? "")\" needs \(cell.cellSize.width) pt in a \(popup.frame.width) pt popup")
        check(popup.toolTip == names.1, "\(context) Thick Slab: tooltip \(popup.toolTip ?? "nil")")
    }
    popup.selectItem(withTag: 1)
    if let item {
        ToolbarMenuBridge.install(for: item)
        let titles = item.menuFormRepresentation?.submenu?.items.map(\.title) ?? []
        check(titles.contains("MIP - Max Intensity Projection") && titles.contains("minIP - Min Intensity Projection"),
              "\(context) Thick Slab: the overflow menu lists \(titles)")
    }
}

@main @MainActor struct Test {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        for path in CommandLine.arguments.dropFirst() {
            let url = URL(fileURLWithPath: path)
            let locale = url.deletingPathExtension().lastPathComponent
            let bundle = Bundle(url: url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())!
            var objects: NSArray?
            precondition(NSNib(nibNamed: locale, bundle: bundle)!.instantiate(withOwner: nil, topLevelObjects: &objects))
            let host = Host()
            for case let view as NSView in objects! { host.views[view.identifier!.rawValue] = view }
            let shading = host.views["tbShading"]!
            let designed = shading.frame.size
            // What MPRController writes from the hidden VR view's values, at
            // the widest the shading panel's ranges give (4 is the widest digit).
            for text in descendants(NSTextField.self, in: shading) where text.stringValue.contains("\n") { text.stringValue = widestValues }

            let window = NSWindow(contentRect: NSRect(x: 40, y: 80, width: 1400, height: 300),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.toolbarStyle = .expanded
            let toolbar = NSToolbar(identifier: "HorosMPRToolbarViewsTest-\(locale)-\(getpid())")
            toolbar.delegate = host
            toolbar.allowsUserCustomization = true
            window.toolbar = toolbar
            window.orderFront(nil)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
            toolbar.runCustomizationPalette(nil)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))
            let sheet = window.attachedSheet
            check(sheet != nil, "\(locale): the customization palette did not open")
            checkShading(shading, "\(locale) palette")
            checkThickSlab(host.views["tbThickSlab"]!, nil, "\(locale) palette")
            if let sheet { window.endSheet(sheet) }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))

            // On the bar as in the MPR's default set: Shadings, then a flexible space.
            toolbar.insertItem(withItemIdentifier: .flexibleSpace, at: 0)
            toolbar.insertItem(withItemIdentifier: NSToolbarItem.Identifier("tbShading"), at: 0)
            toolbar.insertItem(withItemIdentifier: NSToolbarItem.Identifier("tbThickSlab"), at: 0)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
            check(shading.window === window, "\(locale): Shadings is not on the bar")
            checkShading(shading, "\(locale) bar")
            let design = shading.frame.size
            check(design.height == designed.height, "\(locale): the Shadings view is \(design.height) pt tall, designed \(designed.height)")
            checkThickSlab(host.views["tbThickSlab"]!,
                           toolbar.items.first { $0.itemIdentifier.rawValue == "tbThickSlab" }, "\(locale) bar")
            if let holder = shading.superview {
                check(holder.frame.width <= design.width + 12,
                      "\(locale): the Shadings item takes \(holder.frame.width) pt for a \(design.width) pt view")
            }
            window.close()
            print("\(locale): checked the Shadings and Thick Slab views")
        }
        if !failures.isEmpty {
            for failure in failures { FileHandle.standardError.write("FAIL: \(failure)\n".data(using: .utf8)!) }
            exit(1)
        }
    }
}
'''

with tempfile.TemporaryDirectory(prefix='horos-mpr-toolbar-') as folder:
    work = Path(folder)
    resources = work / 'Probe.bundle/Contents/Resources'
    resources.mkdir(parents=True)
    (resources.parent / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'org.horosproject.mpr-toolbar-views-test',
        'CFBundlePackageType': 'BNDL',
    }))
    nibs = []
    for locale in LOCALES:
        source = ET.fromstring(read(f'Horos/Resources/{locale}.lproj/MPR.xib'))
        document = ET.Element('document', source.attrib)
        for dependency in source.findall('dependencies'):
            document.append(deepcopy(dependency))
        objects = ET.SubElement(document, 'objects')
        ET.SubElement(objects, 'customObject', id='-2', userLabel="File's Owner", customClass='NSObject')
        ET.SubElement(objects, 'customObject', id='-1', userLabel='First Responder', customClass='FirstResponder')
        ET.SubElement(objects, 'customObject', id='-3', userLabel='Application', customClass='NSObject')
        for name, identifier in VIEWS.items():
            view = source.find(f'.//*[@id="{identifier}"]')
            if view is None:
                print(f'FAIL: {locale}: the {name} view ({identifier}) is gone from MPR.xib', file=sys.stderr)
                sys.exit(1)
            view = deepcopy(view)
            for node in view.iter():
                if node.get('customClass') not in KEEP_CLASSES:
                    node.attrib.pop('customClass', None)
                for connection in list(node.findall('connections')):
                    node.remove(connection)
            view.set('identifier', name)
            objects.append(view)
        for embedded in source.findall('resources'):
            document.append(deepcopy(embedded))
        xib = work / f'{locale}.xib'
        ET.ElementTree(document).write(xib, encoding='utf-8', xml_declaration=True)
        nib = resources / f'{locale}.nib'
        compiled = subprocess.run(['xcrun', 'ibtool', '--compile', str(nib), str(xib)],
                                  capture_output=True, text=True)
        if compiled.returncode:
            raise RuntimeError(compiled.stdout + compiled.stderr)
        nibs.append(nib)
    swift = work / 'Test.swift'
    swift.write_text(code)
    binary = work / 'test'
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', *map(str, [root / 'Horos/Sources/ToolbarPolicy.swift', root / 'Horos/Sources/ToolbarImage.swift']), '-parse-as-library', str(swift), *map(str, SWIFT),
                            *isix_modules.module_flags('IsiXImaging', work / 'isix'), '-o', str(binary)],
                   capture_output=True, text=True)
    if built.returncode:
        sys.exit('FAIL: the toolbar views do not compile with the test\n' + built.stderr[-4000:])
    result = subprocess.run([str(binary), *map(str, nibs)], capture_output=True, text=True)
    sys.stdout.write(result.stdout)
    sys.stderr.write(''.join(line + '\n' for line in result.stderr.splitlines()
                             if 'Could not find image named' not in line))
    if result.returncode:
        failures.append('the Shadings or Thick Slab view does not lay out whole')

if failures:
    for failure in failures:
        print('FAIL:', failure, file=sys.stderr)
    sys.exit(1)
print('PASS: the MPR Shadings and Thick Slab views lay out whole in the palette and on the bar')
