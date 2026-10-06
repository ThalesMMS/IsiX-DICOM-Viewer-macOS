#!/usr/bin/env python3
"""The Volume Rendering toolbar views keep their size and layout in the palette and on the bar.

The palette draws an item that is not on the toolbar from a snapshot: AppKit
puts the item's view in an `NSToolbarSnapshotWindow` and lays it out at its
fitting size, and the view keeps that size afterwards. None of the VR views had
constraints that fix its height, so the fitting height was zero: 4D Player,
Scissor State, Background, Stereo and Mode came out as a thin line, in the
palette and then on the bar, whose item size VRController reads from the view's
frame.

The Clipping check box carried the title "Check" in a 13 pt wide button, so
the title wrapped into a 70 pt column that pushed the box off the view, over
the capsule's edge; it is now an image-only box, 6 pt from the left edge and
centred with the slider.

The palette gives an item label the view's width plus 4 pt. «WL/WW & CLUT &
Opacity» needs a little more than the 148 pt the 144 pt WLWW view got, so it
wrapped into two lines there. The view is 160 pt wide now, the extra width in
its three pop-up menus, and the label stays on one line in the palette and on
the bar.

The Perspective item put its three radios in a 2 × 2 grid, Parallel and
Endoscopy on top and Perspective alone below an empty, transparent cell. They
are now one column, Parallel, Perspective and Endoscopy, with the same tags the
projectionMode binding selects.

The Fusion item read "Percentage: -": the percentage field's title in VR.xib
was "-" and only a fused series wrote the slider's value into it. It now shows
the slider's percentage (50% for the slider's 128 of 256), dimmed with the
slider while no fusion is active; VRController enables both when it fuses.

The views of both VR.xib localizations are copied into a nib of their own,
compiled with ibtool and loaded in AppKit; the palette is opened on a toolbar
that holds none of them, so every one goes through the snapshot window, and
the items with a layout of their own are then put on the bar.

`<git revision>` as an optional argument reads the nibs from that revision:
that is the negative control.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
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

# The views VRController hands to its toolbar items, by the item they serve.
VIEWS = {
    'Movie': '462', 'ScissorState': 'PAf-vk-NLg', 'BackgroundColorView': '1018',
    'Stereo': '2314', 'Mode': '658', 'Perspective': '575', 'ClippingRange': '2270',
    'WLWW': '209', 'Tools': '239', 'OrientationsView': '888', 'Shading': '514',
    'LOD': '350', 'ConvolutionView': '953', 'CLUTEditors': '2298', '2DBlending': '386',
}
LOCALES = ('en', 'ja-JP')


def read(relative):
    if revision is None:
        return (root / relative).read_bytes()
    return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{relative}'],
                                   stderr=subprocess.DEVNULL)


# VRController enables the percentage with the slider when it fuses.
controller = read('Horos/Sources/VRController.mm').decode('latin1')
fusion = controller[controller.index('if( blendingController) // Blending! Activate image fusion'):]
fusion = fusion[:fusion.index('[self updateBlendingImage];')]
if '[blendingSlider setEnabled:YES];' not in fusion or '[blendingPercentage setEnabled:YES];' not in fusion:
    print('FAIL: VRController does not enable the fusion percentage with its slider', file=sys.stderr)
    source_failed = True
else:
    source_failed = False

code = r'''
import AppKit

final class Host: NSObject, NSToolbarDelegate {
    var views: [String: NSView] = [:]
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        views.keys.sorted().map { NSToolbarItem.Identifier($0) }
    }
    // As VRController does: the item's size is the view's frame when asked.
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        guard let view = views[id.rawValue] else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = labels[id.rawValue] ?? id.rawValue
        item.paletteLabel = item.label
        item.view = view
        ToolbarPolicy.constrainView(of: item, minimum: ToolbarPolicy.designedSize(of: view), maximum: .zero)
        item.isBordered = false
        return item
    }
}

/// The three projection radios in one column, one cell per mode, whole
/// inside the view; the binding selects the mode by tag.
func checkPerspective(_ views: [String: NSView], _ context: String) {
    let view = views["Perspective"]!
    guard let matrix = descendants(NSMatrix.self, in: view).first else {
        check(false, "\(context) Perspective: no matrix"); return
    }
    check(matrix.numberOfColumns == 1 && matrix.numberOfRows == 3,
          "\(context) Perspective: \(matrix.numberOfRows) × \(matrix.numberOfColumns) cells")
    let cells = matrix.cells
    check(cells.map(\.title) == ["Parallel", "Perspective", "Endoscopy"],
          "\(context) Perspective: cells \(cells.map(\.title))")
    check(cells.map(\.tag) == [1, 0, 2], "\(context) Perspective: tags \(cells.map(\.tag))")
    check(!cells.contains { ($0 as? NSButtonCell)?.isTransparent == true }, "\(context) Perspective: a transparent cell")
    let frame = matrix.convert(matrix.bounds, to: view)
    check(view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame),
          "\(context) Perspective: matrix \(frame) outside \(view.bounds)")
    for (row, cell) in cells.enumerated() {
        let natural = cell.cellSize
        check(natural.width <= matrix.cellSize.width + 0.5 && natural.height <= matrix.cellSize.height + 0.5,
              "\(context) Perspective: \(cell.title) needs \(natural), the matrix gives \(matrix.cellSize)")
        let rect = matrix.convert(matrix.cellFrame(atRow: row, column: 0), to: view)
        check(view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(rect),
              "\(context) Perspective: \(cell.title) at \(rect) outside \(view.bounds)")
    }
    for (tag, title) in [(1, "Parallel"), (0, "Perspective"), (2, "Endoscopy"), (1, "Parallel")] {
        check(matrix.selectCell(withTag: tag) && matrix.selectedCell()?.title == title,
              "\(context) Perspective: tag \(tag) selects \(matrix.selectedCell()?.title ?? "nothing")")
    }
}

/// The Fusion item shows the slider's percentage, dimmed with the slider
/// while no fusion is active, and the field has room for "100%".
func checkFusion(_ views: [String: NSView], _ context: String) {
    let view = views["2DBlending"]!
    guard let slider = descendants(NSSlider.self, in: view).first,
          let percent = descendants(NSTextField.self, in: view).first(where: { $0.identifier?.rawValue == "BlendingPercentage" })
    else { check(false, "\(context) Fusion: no slider or percentage"); return }
    let expected = String(format: "%0.0f%%", 100 * slider.doubleValue / 256)
    check(percent.stringValue == expected,
          "\(context) Fusion: the percentage reads \"\(percent.stringValue)\" for a slider at \(slider.doubleValue)")
    check(!slider.isEnabled && percent.isEnabled == slider.isEnabled,
          "\(context) Fusion: percentage enabled \(percent.isEnabled), slider enabled \(slider.isEnabled)")
    let widest = NSTextField(labelWithString: "100%")
    widest.font = percent.font
    check(widest.intrinsicContentSize.width <= percent.alignmentRect(forFrame: percent.frame).width + 0.5,
          "\(context) Fusion: \"100%\" does not fit \(percent.frame)")
    let frame = percent.convert(percent.bounds, to: view)
    check(view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame),
          "\(context) Fusion: percentage at \(frame) outside \(view.bounds)")
}

/// An item label that needs two lines at the width the palette or the
/// bar gives it.
func checkLabel(_ label: String, in root: NSView, _ context: String) {
    let fields = descendants(NSTextField.self, in: root).filter { $0.stringValue == label }
    check(!fields.isEmpty, "\(context): no label \"\(label)\"")
    for field in fields {
        guard let cell = field.cell else { continue }
        let line = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: 10_000, height: 10_000)).height
        let wrapped = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: field.bounds.width, height: 10_000)).height
        check(wrapped <= line + 0.5,
              "\(context): \"\(label)\" takes \(wrapped) pt at \(field.bounds.width) pt, one line is \(line) pt")
    }
}

// The labels VRController gives the items that are checked for more than size.
let labels = ["WLWW": "WL/WW & CLUT & Opacity", "Perspective": "Perspective", "ClippingRange": "Clipping"]

var failures: [String] = []
func check(_ condition: Bool, _ message: @autoclosure () -> String) {
    if !condition { failures.append(message()) }
}
func close(_ a: NSSize, _ b: NSSize) -> Bool { abs(a.width - b.width) <= 0.5 && abs(a.height - b.height) <= 0.5 }
func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
    ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants(type, in: $0) }
}

/// The views as the palette (`place` "palette") or the bar ("bar") left them.
func checkLayout(_ views: [String: NSView], _ context: String) {
    // The Clipping check box sits whole inside its view, off the left
    // edge, centred with the slider and labels, not stretched by a title.
    let clipping = views["ClippingRange"]!
    let boxes = descendants(NSButton.self, in: clipping).filter { !($0 is NSPopUpButton) }
    check(boxes.count == 1, "\(context) Clipping: \(boxes.count) check boxes")
    if let box = boxes.first {
        let frame = box.convert(box.bounds, to: clipping)
        check(frame.minX >= 4 && frame.maxX <= clipping.bounds.maxX && frame.minY >= 0 && frame.maxY <= clipping.bounds.maxY,
              "\(context) Clipping: check box at \(frame) in \(clipping.bounds)")
        check(frame.height <= 20 && abs(frame.midY - clipping.bounds.midY) <= 2,
              "\(context) Clipping: check box \(frame) is not a box centred in \(clipping.bounds)")
        check(box.title.isEmpty, "\(context) Clipping: the check box draws the title \"\(box.title)\"")
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

            for (name, view) in host.views.sorted(by: { $0.key < $1.key }) {
                check(close(view.fittingSize, design[name]!),
                      "\(locale) \(name): fitting size \(view.fittingSize), designed \(design[name]!)")
            }

            let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 900, height: 300),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.toolbarStyle = .expanded
            let toolbar = NSToolbar(identifier: "HorosVRToolbarViewsTest-\(locale)-\(getpid())")
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
            checkPerspective(host.views, "\(locale) palette")
            checkFusion(host.views, "\(locale) palette")
            if let sheet { checkLabel(labels["WLWW"]!, in: sheet.contentView!.superview!, "\(locale) palette") }

            if let sheet { window.endSheet(sheet) }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
            for name in ["ClippingRange", "Perspective", "WLWW", "2DBlending"] {
                toolbar.insertItem(withItemIdentifier: NSToolbarItem.Identifier(name), at: 0)
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
            for name in ["ClippingRange", "Perspective", "WLWW", "2DBlending"] {
                let view = host.views[name]!
                check(view.window === window, "\(locale) \(name): not on the bar")
                check(close(view.frame.size, design[name]!),
                      "\(locale) \(name): \(view.frame.size) on the bar, designed \(design[name]!)")
            }
            checkLayout(host.views, "\(locale) bar")
            checkPerspective(host.views, "\(locale) bar")
            checkFusion(host.views, "\(locale) bar")
            // On the bar the label is AppKit's own label view, under the item's
            // viewer: one line is its font's height.
            let wlww = host.views["WLWW"]!
            let viewer = wlww.superview!.convert(wlww.superview!.bounds, to: nil)
            let labelViews = descendants(NSView.self, in: window.contentView!.superview!).filter {
                String(describing: type(of: $0)).contains("LabelView")
                    && abs($0.superview!.convert($0.superview!.bounds, to: nil).midX - viewer.midX) < 1
            }
            check(labelViews.count == 1, "\(locale) bar: \(labelViews.count) label views under the WLWW item")
            for label in labelViews {
                check(label.frame.height <= 16, "\(locale) bar: the WLWW label is \(label.frame) tall")
            }
            window.close()
            print("\(locale): checked \(host.views.count) views")
        }
        if !failures.isEmpty {
            for failure in failures { FileHandle.standardError.write("FAIL: \(failure)\n".data(using: .utf8)!) }
            exit(1)
        }
    }
}
'''

with tempfile.TemporaryDirectory(prefix='horos-vr-toolbar-') as folder:
    work = Path(folder)
    resources = work / 'Probe.bundle/Contents/Resources'
    resources.mkdir(parents=True)
    (resources.parent / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'org.horosproject.vr-toolbar-views-test',
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
        source = ET.fromstring(read(f'Horos/Resources/{locale}.lproj/VR.xib'))
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
                print(f'FAIL: {locale}: the {name} view ({identifier}) is gone from VR.xib', file=sys.stderr)
                sys.exit(1)
            view = deepcopy(view)
            for node in view.iter():
                node.attrib.pop('customClass', None)
                for connection in list(node.findall('connections')):
                    node.remove(connection)
            view.set('identifier', name)
            if name == '2DBlending':
                # The percentage field, which the outlet names in VRController.
                percent = view.find('.//textField[@id="387"]')
                if percent is None:
                    print(f'FAIL: {locale}: the Fusion percentage (387) is gone from VR.xib', file=sys.stderr)
                    sys.exit(1)
                percent.set('identifier', 'BlendingPercentage')
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
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', *map(str, [root / 'Horos/Sources/ToolbarPolicy.swift', root / 'Horos/Sources/ToolbarImage.swift', root / 'Horos/Sources/ToolbarMenuBridge.swift']), '-parse-as-library', str(swift), '-o', str(binary)], check=True)
    result = subprocess.run([str(binary), *map(str, nibs)], capture_output=True, text=True)
    sys.stdout.write(result.stdout)
    sys.stderr.write(''.join(line + '\n' for line in result.stderr.splitlines()
                             if 'Could not find image named' not in line))
    if result.returncode or source_failed:
        sys.exit(1)

print('PASS: the VR toolbar views keep their designed size and layout in the customization palette and on the bar')
