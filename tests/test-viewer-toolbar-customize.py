#!/usr/bin/env python3
"""The 2D viewer's toolbar views keep their size through Customize Toolbar (#942).

ViewerController hands its view-based toolbar items views from Viewer.xib, with
the view's frame as the item's minimum and maximum size (Slice Cine Rate: 100
to 200 pt wide). When the customization palette closes, the toolbar lays its
items out again from the views' constraints, and a view whose constraints do
not fix its size collapses to its fitting size: after «Customize Toolbar»,
adding Convolution Filters and clicking Done, the Series pop-up shrank to
66 x 13, 2D/3D to 43 x 16, and Convolution Filters came in 0 pt high, its «No
Filter» drawn on the label line. It is the defect the VR (#898), endoscopy
(#931), PET-CT (#935), orthogonal MPR (#937) and Curved MPR (#939) views had.
Every 2D toolbar view now has width and height constraints of its own (Slice
Cine Rate: a minimum width of 100 pt, as the item may grow to 200 pt).

A view whose only subview is a control is taken by the toolbar for that
control: AppKit draws it large on the bar and extra large in the palette, and
measures the item from it. The Windows Tiling, Series, 2D/3D and Convolution
Filters pop-ups, and the Shutter and Propagate buttons, now sit in a holder
view that fills their item view, so each keeps the control size it was laid
out with.

The palette's «drag the default set into the toolbar» strip draws a snapshot
of the default bar, as tall as its tallest item plus 23 pt for the labels,
from 6 pt above the bottom of a 78 pt clipping view: an item taller than 49 pt
cuts the top of every item there (#939). The default set rose to 98 pt;
Orientation (53 pt) and Mouse button function (51 pt) are now 49 pt high, and
the pop-ups no longer count at their enlarged size.

The views of both Viewer.xib localizations are copied into a nib of their own,
compiled with ibtool and loaded in AppKit with the Swift classes they name;
the items are made as ViewerController makes them, ToolbarPolicy included. On
an Expanded bar holding the default set, the palette is opened, the default
set's strip must stay inside its clipping view, Convolution Filters is added
while the palette runs, and the palette is closed; then the other views are
drawn by the palette from a bar that holds none of them and added to it. Each
time every view must keep its designed size and its place inside its item,
every control must lie inside its view at the control size it was laid out
with, and every label's ink must lie inside its field and its view.

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
# The views ViewerController hands to its toolbar items, by item identifier.
VIEWS = {
    'WindowsTiling': '2536', 'SeriesPopup': '2622', 'Annotations': '2577', 'Patient': '1031',
    'Tools': '21', 'WLWW': '92', 'Reconstruction': '737', 'Orientation': '1769', 'Fusion': '372',
    'PropagateSettings': '1975', 'Speed': '14',
    'Series': '537', '2DBlending': '475', 'Filters': '382', 'Subtraction': '789', 'RGB': '857',
    'status': '1052', 'keyImages': '1204', 'Shutter': '1739', 'Movie': '505', 'LUT12Bit': '2424',
}
# The view-based items of the default set, in its order.
DEFAULTS = ['WindowsTiling', 'SeriesPopup', 'Annotations', 'Patient', 'Tools', 'WLWW', 'Reconstruction',
            'Orientation', 'Fusion', 'PropagateSettings', 'Speed']
KEEP_CLASSES = {'HorosCellSlider', 'HorosCellSliderCell', 'HorosThickSlabModePopUpButtonCell'}
SWIFT_SOURCES = [root / 'Horos/Sources/HorosCellSlider.swift',
                 root / 'Horos/Sources/ViewerToolbarItemViews.swift',
                 root / 'Horos/Sources/ToolbarMenuBridge.swift',
                 root / 'Horos/Sources/ToolbarPolicy.swift',
                 root / 'Horos/Sources/ToolbarImage.swift']


def read(relative):
    if revision is None:
        return (root / relative).read_bytes()
    return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{relative}'],
                                   stderr=subprocess.DEVNULL)


code = r'''
import AppKit

let defaultSet = CommandLine.arguments[1].split(separator: ",").map(String.init)

final class Host: NSObject, NSToolbarDelegate {
    var views: [String: NSView] = [:]
    var defaults: [String] = []
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        defaults.map { NSToolbarItem.Identifier($0) }
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        views.keys.sorted().map { NSToolbarItem.Identifier($0) }
    }
    // As ViewerController does.
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        guard let view = views[id.rawValue] else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = id.rawValue
        item.paletteLabel = item.label
        if id.rawValue == "WindowsTiling" { WindowsTilingImage.install(in: view) }
        item.view = view
        if id.rawValue == "Speed" {
            let height = ToolbarPolicy.designedSize(of: view).height
            ToolbarPolicy.constrainView(of: item, minimum: NSSize(width: 100, height: height), maximum: NSSize(width: 200, height: height))
        } else {
            let size = ToolbarPolicy.designedSize(of: view)
            ToolbarPolicy.constrainView(of: item, minimum: size, maximum: size)
        }
        ToolbarPolicy.prepare(item)
        return item
    }
}

var failures: [String] = []
func check(_ condition: Bool, _ message: @autoclosure () -> String) {
    if !condition { failures.append(message()) }
}
func close(_ a: NSSize, _ b: NSSize) -> Bool { abs(a.width - b.width) <= 0.5 && abs(a.height - b.height) <= 0.5 }
// Hidden views draw nothing and take no room (the Thick Slab slice count, #985).
func descendants(in view: NSView) -> [NSView] { [view] + view.subviews.filter { !$0.isHidden }.flatMap { descendants(in: $0) } }

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

func checkLayout(_ views: [String: NSView], _ design: [String: NSSize], _ context: String, onBar: Bool) {
    for (name, view) in views.sorted(by: { $0.key < $1.key }) {
        let size = view.frame.size, designed = design[name]!
        if name == "Speed" {
            // Slice Cine Rate may grow on the bar from 100 up to 200 pt.
            check(size.width >= min(100, designed.width) - 0.5 && size.width <= 200.5
                  && abs(size.height - designed.height) <= 0.5,
                  "\(context) \(name): \(size), designed \(designed), 100 to 200 pt wide")
        } else {
            check(close(size, designed), "\(context) \(name): \(size), designed \(designed)")
        }
        // On the bar, the view lies whole inside the item AppKit draws it in.
        if onBar, let holder = view.superview {
            check(holder.bounds.insetBy(dx: -0.5, dy: -0.5).contains(view.frame),
                  "\(context) \(name): at \(view.frame) in its item's \(holder.bounds)")
        }
        view.layoutSubtreeIfNeeded()
        for control in descendants(in: view).dropFirst() where control is NSControl {
            let frame = control.superview!.convert(control.alignmentRect(forFrame: control.frame), to: view)
            check(frame.width >= 1 && frame.height >= 1,
                  "\(context) \(name): \(type(of: control)) collapsed to \(frame.size)")
            check(view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame),
                  "\(context) \(name): \(type(of: control)) at \(frame) outside \(view.bounds)")
            // AppKit enlarges the control of a view that holds nothing else.
            if let designed = controlSizes[ObjectIdentifier(control)] {
                check((control as! NSControl).controlSize == designed,
                      "\(context) \(name): \(type(of: control)) drawn at control size \((control as! NSControl).controlSize.rawValue), laid out for \(designed.rawValue)")
            }
            guard let field = control as? NSTextField, !field.isEditable, !field.isBezeled,
                  !field.stringValue.isEmpty else { continue }
            let text = field.stringValue
            guard let columns = ink(field) else {
                check(false, "\(context) \(name): «\(text)» draws nothing in \(field.frame.size)")
                continue
            }
            check(columns.lowerBound >= 0.5 && columns.upperBound <= field.bounds.width - 0.5,
                  "\(context) \(name): «\(text)» inks \(columns) of its \(field.bounds.width) pt field")
            let left = field.convert(NSPoint(x: columns.lowerBound, y: 0), to: view).x
            let right = field.convert(NSPoint(x: columns.upperBound, y: 0), to: view).x
            check(left >= 0 && right <= view.bounds.width,
                  "\(context) \(name): «\(text)» inks \(left)...\(right), outside the view's 0...\(view.bounds.width)")
        }
    }
}

/// The control size each control was laid out with in the xib.
var controlSizes: [ObjectIdentifier: NSControl.ControlSize] = [:]

func load(_ locale: String, _ bundle: Bundle, _ host: Host, _ names: [String]) {
    var objects: NSArray?
    precondition(NSNib(nibNamed: locale, bundle: bundle)!.instantiate(withOwner: nil, topLevelObjects: &objects))
    for case let view as NSView in objects! where names.contains(view.identifier!.rawValue) {
        host.views[view.identifier!.rawValue] = view
        for case let control as NSControl in descendants(in: view) { controlSizes[ObjectIdentifier(control)] = control.controlSize }
    }
}

func window(_ host: Host, _ name: String) -> (NSWindow, NSToolbar) {
    let window = NSWindow(contentRect: NSRect(x: 20, y: 80, width: 1600, height: 300),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.toolbarStyle = .expanded
    let toolbar = NSToolbar(identifier: "HorosViewerToolbarCustomizeTest-\(name)-\(getpid())")
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
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
for path in CommandLine.arguments.dropFirst(2) {
    let url = URL(fileURLWithPath: path)
    let locale = url.deletingPathExtension().lastPathComponent
    let bundle = Bundle(url: url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())!

    var design: [String: NSSize] = [:]
    var names: [String] = []
    do {
        let host = Host()
        var objects: NSArray?
        precondition(NSNib(nibNamed: locale, bundle: bundle)!.instantiate(withOwner: nil, topLevelObjects: &objects))
        for case let view as NSView in objects! { host.views[view.identifier!.rawValue] = view }
        design = host.views.mapValues { $0.frame.size }
        names = host.views.keys.sorted()
        for (name, view) in host.views.sorted(by: { $0.key < $1.key }) {
            let fitting = view.fittingSize
            if name == "Speed" {
                check(abs(fitting.height - design[name]!.height) <= 0.5 && fitting.width >= 100 - 0.5
                      && fitting.width <= design[name]!.width + 0.5,
                      "\(locale) \(name): fitting size \(fitting), designed \(design[name]!)")
            } else {
                check(close(fitting, design[name]!), "\(locale) \(name): fitting size \(fitting), designed \(design[name]!)")
            }
        }
    }
    let others = names.filter { !defaultSet.contains($0) }

    // The default set on the bar; the palette opened over it; Convolution
    // Filters added while it runs; Done.
    do {
        let host = Host()
        load(locale, bundle, host, defaultSet + ["Filters"])
        host.defaults = defaultSet
        let (window, toolbar) = window(host, "\(locale)-default")
        for name in defaultSet { check(host.views[name]!.window === window, "\(locale) \(name): not on the default bar") }
        var onBar = host.views.filter { defaultSet.contains($0.key) }
        checkLayout(onBar, design, "\(locale) default bar", onBar: true)
        palette(window, toolbar, "\(locale) palette over the default bar", defaultSet: true) {
            checkLayout(onBar, design, "\(locale) palette over the default bar", onBar: true)
            toolbar.insertItem(withItemIdentifier: NSToolbarItem.Identifier("Filters"), at: defaultSet.firstIndex(of: "Fusion")! + 1)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        }
        onBar = host.views
        for (name, view) in onBar { check(view.window === window, "\(locale) \(name): not on the bar after Done") }
        checkLayout(onBar, design, "\(locale) default bar after Done", onBar: true)
        window.close()
    }

    // Off the bar: the palette draws them from its snapshot, and they keep
    // that size once added to the bar and the palette closed.
    for (index, group) in [others, defaultSet].enumerated() {
        let host = Host()
        load(locale, bundle, host, group)
        let (window, toolbar) = window(host, "\(locale)-palette-\(index)")
        palette(window, toolbar, "\(locale) palette") {
            checkLayout(host.views, design, "\(locale) palette", onBar: false)
            for name in group {
                toolbar.insertItem(withItemIdentifier: NSToolbarItem.Identifier(name), at: toolbar.items.count)
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        }
        for (name, view) in host.views { check(view.window === window, "\(locale) \(name): not on the bar") }
        checkLayout(host.views, design, "\(locale) bar after Done", onBar: true)
        window.close()
    }
    print("\(locale): checked \(names.count) views")
}
for failure in failures { FileHandle.standardError.write("FAIL: \(failure)\n".data(using: .utf8)!) }
exit(failures.isEmpty ? 0 : 1)
'''

with tempfile.TemporaryDirectory(prefix='horos-viewer-toolbar-customize-') as folder:
    work = Path(folder)
    resources = work / 'Probe.bundle/Contents/Resources'
    resources.mkdir(parents=True)
    (resources.parent / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'org.horosproject.viewer-toolbar-customize-test',
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
        source = ET.fromstring(read(f'Horos/Resources/{locale}.lproj/Viewer.xib'))
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
                print(f'FAIL: {locale}: the {name} view ({identifier}) is gone from Viewer.xib', file=sys.stderr)
                sys.exit(1)
            view = deepcopy(view)
            for node in view.iter():
                if node.get('customClass') not in KEEP_CLASSES:
                    node.attrib.pop('customClass', None)
                for connection in list(node.findall('connections')):
                    node.remove(connection)
                for key in ('image', 'alternateImage'):
                    image = node.get(key)
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
    swift = work / 'main.swift'
    swift.write_text(code)
    binary = work / 'test'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', *map(str, SWIFT_SOURCES), str(swift),
                    '-framework', 'AppKit', '-o', str(binary)],
                   check=True, capture_output=True)
    result = subprocess.run([str(binary), ','.join(DEFAULTS), *map(str, nibs)], capture_output=True, text=True)
    sys.stdout.write(result.stdout)
    sys.stderr.write(''.join(line + '\n' for line in result.stderr.splitlines()
                             if 'Could not find image named' not in line))
    if result.returncode:
        sys.exit(1)

print('PASS: the 2D toolbar views keep their size and place through Customize Toolbar, in the palette and on the bar')
