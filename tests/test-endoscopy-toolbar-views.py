#!/usr/bin/env python3
"""The endoscopy toolbar views keep their size and layout in the palette and on the bar (#931).

The palette draws an item that is not on the toolbar from a snapshot: AppKit
puts the item's view in an `NSToolbarSnapshotWindow` and lays it out at its
fitting size, and the view keeps that size afterwards. EndoscopyViewer then
takes the item's minimum and maximum size from the view's frame. The
constraints of the WL/WW views (MPR and 3D) did not fix their height, those of
the two Mouse button function views fixed neither their width nor their height,
and those of the Shading view let its width fall to that of its widest line:
out of the bar, the items came out of the palette as a thin line, or narrower
than designed, and kept that size once dragged back to the bar. The Level of
Detail view already had a size of its own (#904).

The Shading item writes three lines, «Ambient», «Diffuse» and «Specular»; the
window keeps its Expanded toolbar so that the third line shows (#869), and the
text field must still hold the three lines at the view's fixed size.

The views of both Endoscopy.xib localizations are copied into a nib of their
own, compiled with ibtool and loaded in AppKit; the palette is opened on an
Expanded toolbar that holds none of them, so every one goes through the
snapshot window, and they are then put on the bar the way EndoscopyViewer
builds the items.

`<git revision>` as an optional argument reads the nibs from that revision:
that is the negative control.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs (#803)
from copy import deepcopy
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None

# The views EndoscopyViewer hands to its toolbar items, by the item they serve.
VIEWS = {
    'WLWW2D': '140', 'WLWW3D': '106', 'Tools2D': '58', 'Tools3D': '40',
    'Shading': '280', 'LOD': '310',
}
LOCALES = ('en', 'ja-JP')


def read(relative):
    if revision is None:
        return (root / relative).read_bytes()
    return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{relative}'],
                                   stderr=subprocess.DEVNULL)


code = r'''
import AppKit

final class Host: NSObject, NSToolbarDelegate {
    var views: [String: NSView] = [:]
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        views.keys.sorted().map { NSToolbarItem.Identifier($0) }
    }
    // As EndoscopyViewer does: the view's frame as minimum size, and as
    // maximum size for all but Shading and Level of Detail.
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        guard let view = views[id.rawValue] else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = id.rawValue
        item.paletteLabel = item.label
        item.view = view
        item.minSize = view.frame.size
        if id.rawValue != "Shading" && id.rawValue != "LOD" { item.maxSize = view.frame.size }
        return item
    }
}

var failures: [String] = []
func check(_ condition: Bool, _ message: @autoclosure () -> String) {
    if !condition { failures.append(message()) }
}
func close(_ a: NSSize, _ b: NSSize) -> Bool { abs(a.width - b.width) <= 0.5 && abs(a.height - b.height) <= 0.5 }
func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
    ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants(type, in: $0) }
}

// What EndoscopyVRController writes in the Shading item, at its widest.
let shadingText = String(format: "Ambient: %2.1f\nDiffuse: %2.1f\nSpecular :%2.1f-%2.1f", 0.15, 0.65, 0.75, 50.0)

/// The controls whole inside their view, and the Shading text on three lines.
func checkLayout(_ views: [String: NSView], _ context: String) {
    for (name, view) in views.sorted(by: { $0.key < $1.key }) {
        for control in view.subviews {
            let frame = control.convert(control.alignmentRect(forFrame: control.bounds), to: view)
            check(view.bounds.insetBy(dx: -1.5, dy: -1.5).contains(frame),
                  "\(context) \(name): \(type(of: control)) at \(frame) outside \(view.bounds)")
        }
    }
    let shading = views["Shading"]!
    let fields = descendants(NSTextField.self, in: shading).filter { $0.stringValue.hasPrefix("Ambient") }
    check(fields.count == 1, "\(context) Shading: \(fields.count) value fields")
    for field in fields {
        let needed = field.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: 10_000, height: 10_000))
        check(field.bounds.height >= needed.height - 0.5 && field.bounds.width >= needed.width - 0.5,
              "\(context) Shading: the three lines need \(needed), the field is \(field.bounds.size)")
        let frame = field.convert(field.bounds, to: shading)
        check(shading.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame),
              "\(context) Shading: the value field \(frame) is outside \(shading.bounds)")
    }
}

@main struct Test {
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
            let design = host.views.mapValues { $0.frame.size }
            for field in descendants(NSTextField.self, in: host.views["Shading"]!)
                where field.stringValue.hasPrefix("Ambient") {
                field.stringValue = shadingText
            }

            for (name, view) in host.views.sorted(by: { $0.key < $1.key }) {
                check(close(view.fittingSize, design[name]!),
                      "\(locale) \(name): fitting size \(view.fittingSize), designed \(design[name]!)")
            }

            let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1400, height: 300),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.toolbarStyle = .expanded
            let toolbar = NSToolbar(identifier: "HorosEndoscopyToolbarViewsTest-\(locale)-\(getpid())")
            toolbar.delegate = host
            toolbar.allowsUserCustomization = true
            window.toolbar = toolbar
            window.orderFront(nil)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
            toolbar.runCustomizationPalette(nil)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))
            let sheet = window.attachedSheet
            check(sheet != nil, "\(locale): the customization palette did not open")

            for (name, view) in host.views.sorted(by: { $0.key < $1.key }) {
                check(close(view.frame.size, design[name]!),
                      "\(locale) \(name): \(view.frame.size) after the palette, designed \(design[name]!)")
            }
            checkLayout(host.views, "\(locale) palette")

            if let sheet { window.endSheet(sheet) }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
            // Dragged to the bar afterwards, each item takes the size the
            // snapshot left its view.
            for name in host.views.keys.sorted() {
                toolbar.insertItem(withItemIdentifier: NSToolbarItem.Identifier(name), at: toolbar.items.count)
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
            for (name, view) in host.views.sorted(by: { $0.key < $1.key }) {
                check(view.window === window, "\(locale) \(name): not on the bar")
                check(close(view.frame.size, design[name]!),
                      "\(locale) \(name): \(view.frame.size) on the bar, designed \(design[name]!)")
            }
            checkLayout(host.views, "\(locale) bar")
            window.close()
            print("\(locale): checked \(host.views.count) views")
        }
        for failure in failures { FileHandle.standardError.write("FAIL: \(failure)\n".data(using: .utf8)!) }
        exit(failures.isEmpty ? 0 : 1)
    }
}
'''

with tempfile.TemporaryDirectory(prefix='horos-endoscopy-toolbar-') as folder:
    work = Path(folder)
    resources = work / 'Probe.bundle/Contents/Resources'
    resources.mkdir(parents=True)
    (resources.parent / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'org.horosproject.endoscopy-toolbar-views-test',
        'CFBundlePackageType': 'BNDL',
    }))
    nibs = []
    # The palette lays its snapshots out in SwiftUI, which stops the process on
    # an image cell without an image: the artwork the views name comes along.
    artwork = {}
    for path in (root / 'Horos/Resources').rglob('*'):
        if path.suffix.lower() in ('.pdf', '.png', '.tif', '.tiff', '.icns', '.jpg'):
            artwork.setdefault(path.stem, path)
    for locale in LOCALES:
        source = ET.fromstring(read(f'Horos/Resources/{locale}.lproj/Endoscopy.xib'))
        document = ET.Element('document', source.attrib)
        for dependency in source.findall('dependencies'):
            document.append(deepcopy(dependency))
        objects = ET.SubElement(document, 'objects')
        ET.SubElement(objects, 'customObject', id='-2', userLabel="File's Owner", customClass='NSObject')
        ET.SubElement(objects, 'customObject', id='-1', userLabel='First Responder', customClass='FirstResponder')
        ET.SubElement(objects, 'customObject', id='-3', userLabel='Application', customClass='NSObject')
        for name, identifier in VIEWS.items():
            view = source.find(f'.//customView[@id="{identifier}"]')
            if view is None:
                print(f'FAIL: {locale}: the {name} view ({identifier}) is gone from Endoscopy.xib', file=sys.stderr)
                sys.exit(1)
            view = deepcopy(view)
            for node in view.iter():
                node.attrib.pop('customClass', None)
                for connection in list(node.findall('connections')):
                    node.remove(connection)
            view.set('identifier', name)
            objects.append(view)
            for node in view.iter():
                image = node.get('image')
                if image and image not in artwork and ':' not in image:
                    print(f'FAIL: {locale}: no artwork for {image}', file=sys.stderr)
                    sys.exit(1)
                if image in artwork and not (resources / artwork[image].name).exists():
                    shutil.copy(artwork[image], resources)
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
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(swift), '-o', str(binary)],
                   check=True, capture_output=True)
    result = subprocess.run([str(binary), *map(str, nibs)], capture_output=True, text=True)
    sys.stdout.write(result.stdout)
    sys.stderr.write(''.join(line + '\n' for line in result.stderr.splitlines()
                             if 'Could not find image named' not in line))
    if result.returncode:
        sys.exit(1)

print('PASS: the endoscopy toolbar views keep their designed size and layout in the customization palette and on the bar')
