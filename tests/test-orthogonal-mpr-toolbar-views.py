#!/usr/bin/env python3
"""The orthogonal MPR toolbar views keep their layout in the palette and on the bar.

The palette draws an item that is not on the toolbar from a snapshot: AppKit
puts the item's view in an `NSToolbarSnapshotWindow` and lays it out at its
fitting size, and the view keeps that size afterwards; OrthogonalMPRViewer then
takes the item's size from the view's frame. The WL/WW & CLUT view (id 186 in
OrthogonalMPR.xib) had the defect fixed in PETCT.xib: its constraints
fixed neither its width nor its height, and nothing held the Opacity pop-up
next to its «Opacity:» label, since the pop-up was pinned to the bottom edge.
Its fitting size had no height, and on the title-bar toolbar of the default
set the view was squeezed to 36 pt, so that the three 16 pt pop-ups overlapped.
The view now has width and height constraints, 165 x 48 pt, as the PET-CT
view has, and the Opacity pop-up is aligned on its label's baseline, the three
rows 16 pt apart.

The Mouse button function view (id 60) and the Thick Slab view (id 142) had
no height either: their fitting heights were 0 pt, the palette drew them 0 pt
tall, and on the bar they were squeezed to 36 pt, the tool matrix and the
thickness slider past the bottom edge. The Mouse button function view now has
width and height constraints, 308 x 38 pt, and the Thick Slab view a height
constraint, 40 pt. The 4D Player view (id 278) keeps its height
and its controls; its width follows its content, 167 pt, in the palette.

The views of both OrthogonalMPR.xib localizations are copied into a nib of
their own, compiled with ibtool and loaded in AppKit. They are checked on a bar
that holds them from the start, as the default set does, with the palette open
over it, and then from a bar that holds none, so that the palette draws them
from its snapshot, and once dragged to the bar. Items are made as the viewer
makes them: every item takes its view's frame as minimum and maximum size. Thick
Slab used to take its frame 200 pt wider as a minimum with no maximum, and on
a wide bar it grew over every spare point; its view now has a width constraint
too, 236 pt, the width its controls ask for, and holds the whole slider.

`<git revision>` as an optional argument reads the xibs from that revision:
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

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
# Every localization of the nib: the Thick Slab view's width follows the
# translated titles of its controls.
LOCALES = ('en', 'ja-JP', 'pt-BR', 'de', 'fr', 'ar', 'hi', 'ko', 'ru', 'zh-Hans')
# The views the viewer hands to these items, by the item identifier.
VIEWS = {'Tools': '60', 'WLWW': '186', 'ThickSlab': '142', 'Movie': '278'}


def read(relative):
    if revision is None:
        return (root / relative).read_bytes()
    return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{relative}'],
                                   stderr=subprocess.DEVNULL)


code = r'''
import AppKit

let labels = ["Tools": "Mouse button function", "WLWW": "WL/WW & CLUT", "ThickSlab": "Thick Slab", "Movie": "4D Player"]
let order = ["Tools", "WLWW", "ThickSlab", "Movie"]
// The views whose size is fixed; the others keep their height.
let fixed: Set<String> = ["Tools", "WLWW", "ThickSlab"]

final class Host: NSObject, NSToolbarDelegate {
    var views: [String: NSView] = [:]
    var defaults: [String] = []
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        defaults.map { NSToolbarItem.Identifier($0) }
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        order.map { NSToolbarItem.Identifier($0) }
    }
    // As OrthogonalMPRViewer does.
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        guard let view = views[id.rawValue] else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = labels[id.rawValue]!
        item.paletteLabel = item.label
        item.view = view
        let size = id.rawValue == "ThickSlab" ? ToolbarPolicy.localizedSize(of: view) : ToolbarPolicy.designedSize(of: view)
        ToolbarPolicy.constrainView(of: item, minimum: size, maximum: size)
        return item
    }
}

var failures: [String] = []
func check(_ condition: Bool, _ message: @autoclosure () -> String) {
    if !condition { failures.append(message()) }
}
func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 0.5 }
func close(_ a: NSSize, _ b: NSSize) -> Bool { close(a.width, b.width) && close(a.height, b.height) }
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
    for (id, title) in [("201", "Other"), ("193", "No CLUT"), ("188", "Linear Table")] {
        let popup: NSPopUpButton = find(id, in: view)
        popup.item(at: 0)!.title = title
        popup.item(at: 0)!.isHidden = false
    }
}

/// The Mouse button function and WL/WW & CLUT views at their designed size,
/// Thick Slab at its designed height and 4D Player within 1 pt of it; every
/// control inside its view; WL/WW, CLUT and Opacity on three lines, top to
/// bottom, each label beside its pop-up.
func checkLayout(_ views: [String: NSView], _ design: [String: NSSize], _ context: String) {
    for name in order {
        let view = views[name]!
        let sized = fixed.contains(name) ? close(view.frame.size, design[name]!)
            : name == "ThickSlab" ? close(view.frame.height, design[name]!.height)
            : abs(view.frame.height - design[name]!.height) <= 1.0
        check(sized && view.frame.width > 0, "\(context) \(name): \(view.frame.size), designed \(design[name]!)")
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
    for (labelID, popupID, title) in [("198", "201", "WL/WW"), ("200", "193", "CLUT"), ("199", "188", "Opacity")] {
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
}

func load(_ locale: String, _ bundle: Bundle, _ host: Host) {
    var objects: NSArray?
    precondition(NSNib(nibNamed: locale, bundle: bundle)!.instantiate(withOwner: nil, topLevelObjects: &objects))
    for case let view as NSView in objects! { host.views[view.identifier!.rawValue] = view }
    fill(host.views["WLWW"]!)
}

func window(_ host: Host, _ name: String) -> (NSWindow, NSToolbar) {
    let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1400, height: 300),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let toolbar = NSToolbar(identifier: "HorosOrthogonalMPRToolbarViewsTest-\(name)-\(getpid())")
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

            // The default set: the four items on the bar from the start.
            let onBar = Host()
            load(locale, bundle, onBar)
            var design = onBar.views.mapValues { $0.frame.size }
            for name in order {
                let view = onBar.views[name]!
                let fitting = view.fittingSize
                // Thick Slab is as wide as its translated controls ask for;
                // the nib's frame is the same in every language.
                let sized = name == "ThickSlab"
                    ? close(fitting.height, design[name]!.height) && fitting.width > 0
                    : fixed.contains(name) ? close(fitting, design[name]!) : close(fitting.height, design[name]!.height)
                check(sized, "\(locale) \(name): fitting size \(fitting), designed \(design[name]!)")
                if name == "ThickSlab" {
                    design[name] = NSSize(width: fitting.width.rounded(.up), height: design[name]!.height)
                    check(ToolbarPolicy.localizedSize(of: view) == design[name]!, "\(locale) ThickSlab: localized size \(ToolbarPolicy.localizedSize(of: view)), fitting \(fitting)")
                }
            }
            onBar.defaults = order
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
            for name in order {
                secondBar.insertItem(withItemIdentifier: NSToolbarItem.Identifier(name), at: secondBar.items.count)
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
            for (name, view) in offBar.views { check(view.window === second, "\(locale) \(name): not on the bar") }
            checkLayout(offBar.views, design, "\(locale) bar after the palette")
            second.close()
            print("\(locale): checked the Mouse button function, WL/WW & CLUT, Thick Slab and 4D Player views")
        }
        for failure in failures { FileHandle.standardError.write("FAIL: \(failure)\n".data(using: .utf8)!) }
        exit(failures.isEmpty ? 0 : 1)
    }
}
'''

with tempfile.TemporaryDirectory(prefix='horos-orthogonal-mpr-toolbar-') as folder:
    work = Path(folder)
    resources = work / 'Probe.bundle/Contents/Resources'
    resources.mkdir(parents=True)
    (resources.parent / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'org.horosproject.orthogonal-mpr-toolbar-views-test',
        'CFBundlePackageType': 'BNDL',
    }))
    nibs = []
    for locale in LOCALES:
        source = ET.fromstring(read(f'Horos/Resources/{locale}.lproj/OrthogonalMPR.xib'))
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
                print(f'FAIL: {locale}: the {name} view ({identifier}) is gone from OrthogonalMPR.xib', file=sys.stderr)
                sys.exit(1)
            view = deepcopy(view)
            for node in view.iter():
                node.attrib.pop('customClass', None)
                # The app's images are not in the probe bundle, and a tool
                # button without its image stops the toolbar's layout.
                if node.get('image'):
                    node.set('image', 'NSActionTemplate')
                for connection in list(node.findall('connections')):
                    node.remove(connection)
                if node.tag in ('customView', 'popUpButton', 'textField', 'slider', 'button', 'matrix') and node.get('id'):
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

if not revision and 'maximum: .zero' in (root / 'Horos/Sources/OrthogonalMPRViewer.swift').read_text():
    print('FAIL: an Orthogonal MPR toolbar item is left free to grow over the spare room of the bar')
    sys.exit(1)
if not revision and 'ToolbarPolicy.localizedSize(of: ThickSlabView)' not in (root / 'Horos/Sources/OrthogonalMPRViewer.swift').read_text():
    print('FAIL: the Thick Slab item is not sized by its translated controls')
    sys.exit(1)

print('PASS: the orthogonal MPR toolbar views keep their size and their controls in the palette and on the bar')
