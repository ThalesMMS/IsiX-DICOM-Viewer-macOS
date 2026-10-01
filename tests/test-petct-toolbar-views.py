#!/usr/bin/env python3
"""The PET-CT WL/WW & CLUT and Fusion views keep their layout in the palette and on the bar (#935).

The palette draws an item that is not on the toolbar from a snapshot: AppKit
puts the item's view in an `NSToolbarSnapshotWindow` and lays it out at its
fitting size, and the view keeps that size afterwards; the orthogonal PET-CT
viewer then takes the item's size from the view's frame. The constraints of
the WL/WW & CLUT view (id 141 in PETCT.xib) fixed neither its width nor its
height, and nothing held the Opacity pop-up next to its «Opacity:» label: the
pop-up was pinned to the bottom edge and the label hung below the CLUT row.
Laid out at its fitting size, the view shrank, the Opacity pop-up rode up over
the CLUT row and the «Opacity:» label fell below the view, over the item's
label. The view now has width and height constraints equal to its designed
frame, as the VR (#898) and endoscopy (#931) views have, and the Opacity
pop-up is aligned on its label's baseline, the three rows 16 pt apart.

The Fusion view (id 67) had the defect #889 fixed in the 2D viewer: its Mode
pop-up was fixed at 77 pt, too narrow for «High-Low-High» and «Inverse Log»,
and the 77 pt plus the «Mode:» label, 30.5 pt wide, made a 125.5 pt row that
the view rounded to 126 pt, off its 125 pt frame. The pop-up now takes its
content's width and the view is 147 x 35 pt.

The views of both PETCT.xib localizations are copied into a nib of their own,
compiled with ibtool and loaded in AppKit. They are checked on a bar that holds
them from the start, as the default set does, with the palette open over it,
and then from a bar that holds neither, so that the palette draws them from
its snapshot, and once dragged to the bar. Items are made as the viewer makes
them: the WL/WW & CLUT item takes its view's frame as minimum and maximum size,
the Fusion item as minimum size.

`<git revision>` as an optional argument reads the xibs from that revision:
that is the negative control.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs (#803)
from copy import deepcopy
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
LOCALES = ('en', 'ja-JP')
# The views the viewer hands to these items, by the item identifier.
VIEWS = {'WLWW': '141', '2DBlending': '67'}


def read(relative):
    if revision is None:
        return (root / relative).read_bytes()
    return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{relative}'],
                                   stderr=subprocess.DEVNULL)


code = r'''
import AppKit

final class Host: NSObject, NSToolbarDelegate {
    var views: [String: NSView] = [:]
    var defaults: [String] = []
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        defaults.map { NSToolbarItem.Identifier($0) }
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        views.keys.sorted().map { NSToolbarItem.Identifier($0) }
    }
    // As OrthogonalMPRPETCTViewer does.
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        guard let view = views[id.rawValue] else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = id.rawValue == "WLWW" ? "WL/WW & CLUT" : "Fusion"
        item.paletteLabel = item.label
        item.view = view
        let size = ToolbarPolicy.designedSize(of: view)
        ToolbarPolicy.constrainView(of: item, minimum: size, maximum: id.rawValue == "WLWW" ? size : .zero)
        return item
    }
}

var failures: [String] = []
func check(_ condition: Bool, _ message: @autoclosure () -> String) {
    if !condition { failures.append(message()) }
}
func close(_ a: NSSize, _ b: NSSize) -> Bool { abs(a.width - b.width) <= 0.5 && abs(a.height - b.height) <= 0.5 }
func descendants(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants(in: $0) } }
func find<T: NSView>(_ id: String, in view: NSView) -> T {
    descendants(in: view).first { $0.identifier?.rawValue == "xib" + id } as! T
}
func rect(_ control: NSView, in view: NSView) -> NSRect {
    control.superview!.convert(control.alignmentRect(forFrame: control.frame), to: view)
}

/// What the viewer puts in the WL/WW & CLUT pop-ups, which pull down and
/// show their first item.
func fill(_ view: NSView) {
    for (id, title) in [("150", "Other"), ("144", "No CLUT"), ("156", "Linear Table")] {
        let popup: NSPopUpButton = find(id, in: view)
        popup.item(at: 0)!.title = title
        popup.item(at: 0)!.isHidden = false
    }
}

/// WL/WW, CLUT and Opacity on three lines, top to bottom, each label beside
/// its pop-up, all inside the view; the Fusion Mode pop-up wide enough for
/// every mode.
func checkLayout(_ views: [String: NSView], _ design: [String: NSSize], _ context: String) {
    for (name, view) in views.sorted(by: { $0.key < $1.key }) {
        check(close(view.frame.size, design[name]!),
              "\(context) \(name): \(view.frame.size), designed \(design[name]!)")
        view.layoutSubtreeIfNeeded()
        for control in descendants(in: view).dropFirst()
        where control.identifier?.rawValue.hasPrefix("xib") == true && type(of: control) != NSView.self {
            let frame = rect(control, in: view)
            check(view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame),
                  "\(context) \(name): \(type(of: control)) \(control.identifier?.rawValue ?? "") at \(frame) outside \(view.bounds)")
        }
    }
    let wlww = views["WLWW"]!
    var above: NSRect?
    for (labelID, popupID, title) in [("155", "150", "WL/WW"), ("149", "144", "CLUT"), ("143", "156", "Opacity")] {
        let label: NSTextField = find(labelID, in: wlww)
        let popup: NSPopUpButton = find(popupID, in: wlww)
        let l = rect(label, in: wlww), p = rect(popup, in: wlww)
        check(abs(l.midY - p.midY) <= 1.0, "\(context) WLWW: «\(label.stringValue)» at \(l) beside the \(title) pop-up at \(p)")
        check(l.maxX <= p.minX, "\(context) WLWW: «\(label.stringValue)» at \(l) runs into the \(title) pop-up at \(p)")
        let needed = label.intrinsicContentSize
        check(l.width >= needed.width - 0.5 && l.height >= needed.height - 0.5,
              "\(context) WLWW: «\(label.stringValue)» needs \(needed), has \(l.size)")
        let row = l.union(p)
        if let above {
            check(row.maxY <= above.minY + 0.5, "\(context) WLWW: the \(title) row \(row) overlaps the row above, \(above)")
        }
        above = row
    }

    let fusion = views["2DBlending"]!
    let mode: NSPopUpButton = find("71", in: fusion)
    let selected = mode.indexOfSelectedItem
    for title in ["High-Low-High", "Inverse Log"] {
        mode.selectItem(withTitle: title)
        check(mode.intrinsicContentSize.width <= rect(mode, in: fusion).width + 0.5,
              "\(context) Fusion: «\(title)» needs \(mode.intrinsicContentSize.width) pt, the Mode pop-up has \(rect(mode, in: fusion).width)")
    }
    mode.selectItem(at: selected)
}

func load(_ locale: String, _ bundle: Bundle, _ host: Host) {
    var objects: NSArray?
    precondition(NSNib(nibNamed: locale, bundle: bundle)!.instantiate(withOwner: nil, topLevelObjects: &objects))
    for case let view as NSView in objects! { host.views[view.identifier!.rawValue] = view }
    fill(host.views["WLWW"]!)
}

func window(_ host: Host, _ name: String) -> (NSWindow, NSToolbar) {
    let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 900, height: 300),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let toolbar = NSToolbar(identifier: "HorosPETCTToolbarViewsTest-\(name)-\(getpid())")
    toolbar.delegate = host
    toolbar.allowsUserCustomization = true
    window.toolbar = toolbar
    window.orderFront(nil)
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
    return (window, toolbar)
}

func palette(_ window: NSWindow, _ toolbar: NSToolbar, _ context: String, _ body: () -> Void) {
    toolbar.runCustomizationPalette(nil)
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))
    let sheet = window.attachedSheet
    check(sheet != nil, "\(context): the customization palette did not open")
    body()
    if let sheet { window.endSheet(sheet) }
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
}

@main struct Test {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        for path in CommandLine.arguments.dropFirst() {
            let url = URL(fileURLWithPath: path)
            let locale = url.deletingPathExtension().lastPathComponent
            let bundle = Bundle(url: url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())!

            // The default set: both items on the bar from the start.
            let onBar = Host()
            load(locale, bundle, onBar)
            let design = onBar.views.mapValues { $0.frame.size }
            for (name, view) in onBar.views.sorted(by: { $0.key < $1.key }) {
                check(close(view.fittingSize, design[name]!),
                      "\(locale) \(name): fitting size \(view.fittingSize), designed \(design[name]!)")
            }
            onBar.defaults = ["2DBlending", "WLWW"]
            let (first, firstBar) = window(onBar, "\(locale)-default")
            for (name, view) in onBar.views { check(view.window === first, "\(locale) \(name): not on the default bar") }
            checkLayout(onBar.views, design, "\(locale) default bar")
            palette(first, firstBar, "\(locale) default") { checkLayout(onBar.views, design, "\(locale) palette over the default bar") }
            checkLayout(onBar.views, design, "\(locale) default bar after the palette")
            first.close()

            // Off the bar: the palette draws them from its snapshot, and
            // they keep that size once dragged to the bar.
            let offBar = Host()
            load(locale, bundle, offBar)
            let (second, secondBar) = window(offBar, "\(locale)-palette")
            palette(second, secondBar, "\(locale) palette") { checkLayout(offBar.views, design, "\(locale) palette") }
            for name in offBar.views.keys.sorted() {
                secondBar.insertItem(withItemIdentifier: NSToolbarItem.Identifier(name), at: secondBar.items.count)
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
            for (name, view) in offBar.views { check(view.window === second, "\(locale) \(name): not on the bar") }
            checkLayout(offBar.views, design, "\(locale) bar after the palette")
            second.close()
            print("\(locale): checked the WL/WW & CLUT and Fusion views")
        }
        for failure in failures { FileHandle.standardError.write("FAIL: \(failure)\n".data(using: .utf8)!) }
        exit(failures.isEmpty ? 0 : 1)
    }
}
'''

with tempfile.TemporaryDirectory(prefix='horos-petct-toolbar-') as folder:
    work = Path(folder)
    resources = work / 'Probe.bundle/Contents/Resources'
    resources.mkdir(parents=True)
    (resources.parent / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'org.horosproject.petct-toolbar-views-test',
        'CFBundlePackageType': 'BNDL',
    }))
    nibs = []
    for locale in LOCALES:
        source = ET.fromstring(read(f'Horos/Resources/{locale}.lproj/PETCT.xib'))
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
                print(f'FAIL: {locale}: the {name} view ({identifier}) is gone from PETCT.xib', file=sys.stderr)
                sys.exit(1)
            view = deepcopy(view)
            for node in view.iter():
                node.attrib.pop('customClass', None)
                for connection in list(node.findall('connections')):
                    node.remove(connection)
                if node.tag in ('customView', 'popUpButton', 'textField', 'slider') and node.get('id'):
                    node.set('identifier', 'xib' + node.get('id'))
            view.set('identifier', name)
            objects.append(view)
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
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', *map(str, [root / 'Horos/Sources/ToolbarPolicy.swift', root / 'Horos/Sources/ToolbarImage.swift', root / 'Horos/Sources/ToolbarMenuBridge.swift']), '-parse-as-library', str(swift), '-o', str(binary)],
                   check=True, capture_output=True)
    result = subprocess.run([str(binary), *map(str, nibs)], capture_output=True, text=True)
    sys.stdout.write(result.stdout)
    sys.stderr.write(result.stderr)
    if result.returncode:
        sys.exit(1)

print('PASS: the PET-CT WL/WW & CLUT and Fusion views keep three lines and their size in the palette and on the bar')
