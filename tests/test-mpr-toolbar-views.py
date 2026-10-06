#!/usr/bin/env python3
"""The 3D MPR toolbar views lay out whole, in the palette and on the bar.

Shadings: the Shading check box started 1 pt left of its view and the
Edit button 2 pt from it, so the rounded capsule of the Customize Toolbar
panel cut them; the three-line text was 81 pt wide, narrower than the
"Specular :0.30, 15.00" line MPRController writes, and 36 pt tall in a 35 pt
view. The controls now sit 6 pt and more inside the view and the text has the
room of its three lines. The item takes its view's frame as its maximum size,
so it does not grow into empty room on the bar.

Thick Slab: the mode popup showed "MIP - Max Intensity Pr..." cut in
its 132 pt. HorosMPRThickSlabModePopUpButtonCell draws the name before " - "
("MIP") and keeps the full names in the menu, which the overflow menu copies.

The views of both MPR.xib localizations are copied into a nib of their own,
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
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sources

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None

# The views MPRController hands to its toolbar items, by the item they serve.
VIEWS = {'tbShading': '731', 'tbThickSlab': '659'}
KEEP_CLASSES = {'HorosMPRThickSlabModePopUpButtonCell'}
SWIFT = [root / 'Horos/Sources/MPRToolbarItemViews.swift', root / 'Horos/Sources/ToolbarMenuBridge.swift']
LOCALES = ('en', 'ja-JP')


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

code = r'''
import AppKit

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
        item.label = id.rawValue == "tbShading" ? "Shadings" : "Thick Slab"
        item.paletteLabel = item.label
        item.view = view
        let size = ToolbarPolicy.designedSize(of: view)
        ToolbarPolicy.constrainView(of: item, minimum: size, maximum: size)
        item.isBordered = false
        return item
    }
}

var failures: [String] = []
func check(_ condition: Bool, _ message: @autoclosure () -> String) {
    if !condition { failures.append(message()) }
}
func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
    ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants(type, in: $0) }
}

/// Every control of the Shading view whole inside it, off the capsule's edge.
func checkShading(_ view: NSView, _ design: NSSize, _ context: String) {
    check(abs(view.frame.width - design.width) <= 0.5 && abs(view.frame.height - design.height) <= 0.5,
          "\(context): view \(view.frame.size), designed \(design)")
    let buttons = descendants(NSButton.self, in: view)
    let texts = descendants(NSTextField.self, in: view).filter { !$0.stringValue.isEmpty && $0.stringValue.contains("Ambient") }
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
            let design = shading.frame.size
            // What MPRController writes once the hidden VR view gives its values.
            for text in descendants(NSTextField.self, in: shading) where text.stringValue.contains("Ambient") {
                text.stringValue = String(format: "Ambient: %2.2f\nDiffuse: %2.2f\nSpecular :%2.2f, %2.2f", 0.15, 0.90, 0.30, 15.00)
            }

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
            checkShading(shading, design, "\(locale) palette")
            checkThickSlab(host.views["tbThickSlab"]!, nil, "\(locale) palette")
            if let sheet { window.endSheet(sheet) }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))

            // On the bar as in the MPR's default set: Shadings, then a flexible space.
            toolbar.insertItem(withItemIdentifier: .flexibleSpace, at: 0)
            toolbar.insertItem(withItemIdentifier: NSToolbarItem.Identifier("tbShading"), at: 0)
            toolbar.insertItem(withItemIdentifier: NSToolbarItem.Identifier("tbThickSlab"), at: 0)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
            check(shading.window === window, "\(locale): Shadings is not on the bar")
            checkShading(shading, design, "\(locale) bar")
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
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', *map(str, [root / 'Horos/Sources/ToolbarPolicy.swift', root / 'Horos/Sources/ToolbarImage.swift']), '-parse-as-library', str(swift), *map(str, SWIFT), '-o', str(binary)],
                   check=True, capture_output=True)
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
