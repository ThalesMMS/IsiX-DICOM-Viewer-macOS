#!/usr/bin/env python3
"""The Curved MPR toolbar views show their labels whole, in the palette and on the bar (#939, #940).

CPRController hands its toolbar items views from CPR.xib. The «Fine» label of
the LOD view and the «0» label of the Curved MPR Angle view were pinned 2 pt
to the left of their view's leading edge, so the first letter of each was cut
at the left edge on the bar. The labels now sit on the leading edge, as the
endoscopy Level of Detail labels do (#904).

The palette draws an item that is not on the toolbar from a snapshot: AppKit
puts the item's view in an `NSToolbarSnapshotWindow` and lays it out at its
fitting size, and the view keeps that size afterwards; CPRController then
takes the item's minimum size from the view's frame (#898, #931). So every
view that CPRController puts on its bar must lay out at its designed size.

The views of both CPR.xib localizations are copied into a nib of their own,
compiled with ibtool and loaded in AppKit. They are checked on an Expanded bar
that holds them from the start, as the default set does, with the palette open
over it, and then from a bar that holds none of them, so that the palette draws
them from its snapshot, and once dragged to the bar. Items are made as
CPRController makes them: the view's frame as minimum size, and twice its
width as maximum size for Thick Slab. In each view, every control lies inside
the view and every label's ink lies inside the view and inside its own field.

The Axis Colors view was drawn 40 x 40 pt around three 20 pt colour wells,
but a colour well now draws at 48 x 24 pt: the view fitted at 68 x 44 in the
palette, and on the bar the wells were squeezed below their size (#940). Its
wells now sit in a row in a view of 160 x 24 pt; every colour well must be at
least the size it draws at.

Once every view had its designed height, the palette opened over the default
bar cut the tallest ones at the top: its «drag the default set» strip draws the
default bar's snapshot, the tallest item plus 23 pt for the labels, from 6 pt
above the bottom of a 78 pt strip, so an item taller than 49 pt rises past it,
and every item is centred on the tallest. WL & WW (64 pt), Path Assistant
(53 pt), Interpolation Mode (50 pt) and Tools (49 pt) were cut there; they are
now 48, 48, 48 and 38 pt high. With the palette open over the default bar, the
snapshot must stay inside the strip.

`<git revision>` as an optional argument reads the xibs from that revision:
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
LOCALES = ('en', 'ja-JP')
# The views CPRController hands to its toolbar items, by item identifier.
VIEWS = {
    'tbTools': '697', 'tbWLWW': '672', 'tbLOD': '652', 'tbStraightenedCPRAngle': '1163',
    'tbCPRType': '1403', 'tbHighRes': '1449', 'tbPathAssistant': '1465',
    'tbCPRPathMode': '1440', 'tbViewsPosition': '1430', 'tbThickSlab': '659',
    'tbInterpolationMode': 'ezI-rd-S8b', 'AxisColors': '816',
}


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
    // As CPRController does.
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        guard let view = views[id.rawValue] else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = id.rawValue
        item.paletteLabel = item.label
        item.view = view
        let size = ToolbarPolicy.designedSize(of: view)
        let maximum = id.rawValue == "tbThickSlab" ? NSSize(width: 2 * size.width, height: size.height) : .zero
        ToolbarPolicy.constrainView(of: item, minimum: size, maximum: maximum)
        return item
    }
}

var failures: [String] = []
func check(_ condition: Bool, _ message: @autoclosure () -> String) {
    if !condition { failures.append(message()) }
}
func close(_ a: NSSize, _ b: NSSize) -> Bool { abs(a.width - b.width) <= 0.5 && abs(a.height - b.height) <= 0.5 }
func descendants(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants(in: $0) } }

/// The columns of a label that its text inks, in the label's own coordinates.
func ink(_ field: NSTextField) -> ClosedRange<CGFloat>? {
    let bounds = field.bounds
    guard bounds.width >= 1, bounds.height >= 1,
          let rep = field.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
    field.cacheDisplay(in: bounds, to: rep)
    let scale = CGFloat(rep.pixelsWide) / bounds.width
    var first: Int?, last: Int?
    for x in 0..<rep.pixelsWide {
        for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
            if first == nil { first = x }
            last = x
            break
        }
    }
    guard let first, let last else { return nil }
    return (CGFloat(first) / scale)...(CGFloat(last + 1) / scale)
}

func checkLayout(_ views: [String: NSView], _ design: [String: NSSize], _ context: String) {
    for (name, view) in views.sorted(by: { $0.key < $1.key }) {
        // Thick Slab may grow on the bar up to the maximum size CPRController
        // gives it, twice its designed width.
        let size = view.frame.size, designed = design[name]!
        if name == "tbThickSlab" {
            check(size.width >= designed.width - 0.5 && size.width <= 2 * designed.width + 0.5
                  && abs(size.height - designed.height) <= 0.5,
                  "\(context) \(name): \(size), designed \(designed) up to twice as wide")
        } else {
            check(close(size, designed), "\(context) \(name): \(size), designed \(designed)")
        }
        view.layoutSubtreeIfNeeded()
        for control in descendants(in: view).dropFirst() where control is NSControl {
            let frame = control.superview!.convert(control.alignmentRect(forFrame: control.frame), to: view)
            check(view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame),
                  "\(context) \(name): \(type(of: control)) at \(frame) outside \(view.bounds)")
            // A colour well squeezed below the size it draws at loses its edges.
            if let well = control as? NSColorWell {
                let needed = well.intrinsicContentSize
                check(frame.width >= needed.width - 0.5 && frame.height >= needed.height - 0.5,
                      "\(context) \(name): colour well \(frame.size), smaller than the \(needed) it draws at")
            }
            guard let field = control as? NSTextField, !field.isEditable, !field.isBezeled else { continue }
            let text = field.stringValue
            guard let columns = ink(field) else {
                check(false, "\(context) \(name): «\(text)» draws nothing in \(field.frame.size)")
                continue
            }
            // The text inside its own field, clear of both edges...
            check(columns.lowerBound >= 0.5 && columns.upperBound <= field.bounds.width - 0.5,
                  "\(context) \(name): «\(text)» inks \(columns) of its \(field.bounds.width) pt field")
            // ...and the field's ink inside the view.
            let left = field.convert(NSPoint(x: columns.lowerBound, y: 0), to: view).x
            let right = field.convert(NSPoint(x: columns.upperBound, y: 0), to: view).x
            check(left >= 0 && right <= view.bounds.width,
                  "\(context) \(name): «\(text)» inks \(left)...\(right), outside the view's 0...\(view.bounds.width)")
        }
    }
}

func load(_ locale: String, _ bundle: Bundle, _ host: Host) {
    var objects: NSArray?
    precondition(NSNib(nibNamed: locale, bundle: bundle)!.instantiate(withOwner: nil, topLevelObjects: &objects))
    for case let view as NSView in objects! { host.views[view.identifier!.rawValue] = view }
}

func window(_ host: Host, _ name: String) -> (NSWindow, NSToolbar) {
    let window = NSWindow(contentRect: NSRect(x: 40, y: 80, width: 1400, height: 300),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.toolbarStyle = .expanded
    let toolbar = NSToolbar(identifier: "HorosCPRToolbarViewsTest-\(name)-\(getpid())")
    toolbar.delegate = host
    toolbar.allowsUserCustomization = true
    window.toolbar = toolbar
    window.orderFront(nil)
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
    return (window, toolbar)
}

/// The palette's «drag the default set into the toolbar» strip draws a snapshot
/// of the default bar, as tall as the bar's tallest item plus the room for the
/// labels, from its own origin up, inside a clipping view of a fixed height:
/// whatever of the snapshot rises above that view is cut at the top.
func checkDefaultSet(_ sheet: NSWindow, _ context: String) {
    guard let strip = descendants(in: sheet.contentView!).first(where: { "\(type(of: $0))" == "NSToolbarImageRepView" }) else {
        check(false, "\(context): no default-set strip in the palette")
        return
    }
    var clip = strip.superview
    while let view = clip, !view.clipsToBounds { clip = view.superview }
    guard let clip, strip.superview === clip else {
        check(false, "\(context): the default-set strip is not drawn in a clipping view")
        return
    }
    let drawn = strip.intrinsicContentSize
    check(drawn.height > 0, "\(context): the default-set strip draws no snapshot")
    let top = strip.frame.minY + drawn.height
    check(top <= clip.bounds.maxY + 0.5,
          "\(context): the default set's snapshot, \(drawn.height) pt high, rises to \(top) in a strip \(clip.bounds.height) pt high")
}

func palette(_ window: NSWindow, _ toolbar: NSToolbar, _ context: String, defaultSet: Bool = false, _ body: () -> Void) {
    toolbar.runCustomizationPalette(nil)
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))
    let sheet = window.attachedSheet
    check(sheet != nil, "\(context): the customization palette did not open")
    if defaultSet, let sheet { checkDefaultSet(sheet, context) }
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

            var design: [String: NSSize] = [:]
            var names: [String] = []
            do {
                let host = Host()
                load(locale, bundle, host)
                design = host.views.mapValues { $0.frame.size }
                names = host.views.keys.sorted()
                for (name, view) in host.views.sorted(by: { $0.key < $1.key }) {
                    check(close(view.fittingSize, design[name]!),
                          "\(locale) \(name): fitting size \(view.fittingSize), designed \(design[name]!)")
                }
            }
            // Half the items per bar, so that none of them overflows a window
            // that fits on the screen.
            let half = (names.count + 1) / 2
            for (index, group) in [Array(names[..<half]), Array(names[half...])].enumerated() {
                // The default set: the items on the bar from the start.
                let onBar = Host()
                load(locale, bundle, onBar)
                onBar.views = onBar.views.filter { group.contains($0.key) }
                onBar.defaults = group
                let (first, firstBar) = window(onBar, "\(locale)-default-\(index)")
                for (name, view) in onBar.views { check(view.window === first, "\(locale) \(name): not on the default bar") }
                checkLayout(onBar.views, design, "\(locale) default bar")
                palette(first, firstBar, "\(locale) default", defaultSet: true) { checkLayout(onBar.views, design, "\(locale) palette over the default bar") }
                checkLayout(onBar.views, design, "\(locale) default bar after the palette")
                first.close()

                // Off the bar: the palette draws them from its snapshot, and
                // they keep that size once dragged to the bar.
                let offBar = Host()
                load(locale, bundle, offBar)
                offBar.views = offBar.views.filter { group.contains($0.key) }
                let (second, secondBar) = window(offBar, "\(locale)-palette-\(index)")
                palette(second, secondBar, "\(locale) palette") { checkLayout(offBar.views, design, "\(locale) palette") }
                for name in group {
                    secondBar.insertItem(withItemIdentifier: NSToolbarItem.Identifier(name), at: secondBar.items.count)
                }
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
                for (name, view) in offBar.views { check(view.window === second, "\(locale) \(name): not on the bar") }
                checkLayout(offBar.views, design, "\(locale) bar after the palette")
                second.close()
            }
            print("\(locale): checked \(names.count) views")
        }
        for failure in failures { FileHandle.standardError.write("FAIL: \(failure)\n".data(using: .utf8)!) }
        exit(failures.isEmpty ? 0 : 1)
    }
}
'''

with tempfile.TemporaryDirectory(prefix='horos-cpr-toolbar-') as folder:
    work = Path(folder)
    resources = work / 'Probe.bundle/Contents/Resources'
    resources.mkdir(parents=True)
    (resources.parent / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'org.horosproject.cpr-toolbar-views-test',
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
        source = ET.fromstring(read(f'Horos/Resources/{locale}.lproj/CPR.xib'))
        document = ET.Element('document', source.attrib)
        for dependency in source.findall('dependencies'):
            document.append(deepcopy(dependency))
        objects = ET.SubElement(document, 'objects')
        ET.SubElement(objects, 'customObject', id='-2', userLabel="File's Owner", customClass='NSObject')
        ET.SubElement(objects, 'customObject', id='-1', userLabel='First Responder', customClass='FirstResponder')
        ET.SubElement(objects, 'customObject', id='-3', userLabel='Application', customClass='NSObject')
        for name, identifier in VIEWS.items():
            view = source.find(f'objects/*[@id="{identifier}"]')
            if view is None:
                print(f'FAIL: {locale}: the {name} view ({identifier}) is gone from CPR.xib', file=sys.stderr)
                sys.exit(1)
            view = deepcopy(view)
            for node in view.iter():
                node.attrib.pop('customClass', None)
                for connection in list(node.findall('connections')):
                    node.remove(connection)
                image = node.get('image')
                if image and image not in artwork and ':' not in image:
                    print(f'FAIL: {locale}: no artwork for {image}', file=sys.stderr)
                    sys.exit(1)
                if image in artwork and not (resources / artwork[image].name).exists():
                    shutil.copy(artwork[image], resources)
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
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', *map(str, [root / 'Horos/Sources/ToolbarPolicy.swift', root / 'Horos/Sources/ToolbarImage.swift', root / 'Horos/Sources/ToolbarMenuBridge.swift']), '-parse-as-library', str(swift), '-o', str(binary)],
                   check=True, capture_output=True)
    result = subprocess.run([str(binary), *map(str, nibs)], capture_output=True, text=True)
    sys.stdout.write(result.stdout)
    sys.stderr.write(''.join(line + '\n' for line in result.stderr.splitlines()
                             if 'Could not find image named' not in line))
    if result.returncode:
        sys.exit(1)

print('PASS: the Curved MPR toolbar views keep their size and show their labels whole in the palette and on the bar')
