#!/usr/bin/env python3
"""The endoscopy Level of Detail item keeps its width on the bar.

EndoscopyViewer gives the item its view's frame as minimum size and no maximum,
and the view's constraints did not fix its width: the labels «Fine» and
«Coarse», with a low compression resistance, pinned the ends of the slider, so
the bar laid the item out at its fitting width. The item came out about 70 pt
wide, the labels touching over a short track and the knob against its left end,
where the MPR and VR items are some 120 pt wide.

The LOD view of both Endoscopy.xib localizations is copied into a nib of its
own, compiled with ibtool and loaded in AppKit, put on an Expanded toolbar the
way EndoscopyViewer builds the item, and drawn by the customization palette,
which lays the view out at its fitting size in a snapshot window and leaves it
so; the item is then put back on the bar, where it takes that size.

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

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
LOCALES = ('en', 'ja-JP')
LOD_VIEW = '310'


def read(relative):
    if revision is None:
        return (root / relative).read_bytes()
    return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{relative}'],
                                   stderr=subprocess.DEVNULL)


code = r'''
import AppKit

final class Host: NSObject, NSToolbarDelegate {
    var view: NSView!
    var onBar = true
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        onBar ? [NSToolbarItem.Identifier("LOD")] : []
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [NSToolbarItem.Identifier("LOD")]
    }
    // As EndoscopyViewer does: the frame as minimum size, no maximum.
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = "Level of Detail"
        item.paletteLabel = item.label
        item.view = view
        ToolbarPolicy.constrainView(of: item, minimum: ToolbarPolicy.designedSize(of: view), maximum: .zero)
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

func checkLOD(_ view: NSView, _ context: String) {
    check(view.frame.width >= 110, "\(context): the item is \(view.frame.width) pt wide")
    guard let slider = descendants(NSSlider.self, in: view).first else {
        check(false, "\(context): no slider"); return
    }
    let fields = descendants(NSTextField.self, in: view)
    guard let fine = fields.first(where: { $0.stringValue == "Fine" }),
          let coarse = fields.first(where: { $0.stringValue == "Coarse" }) else {
        check(false, "\(context): labels \(fields.map(\.stringValue))"); return
    }
    let track = slider.convert(slider.bounds, to: view)
    let left = fine.convert(fine.bounds, to: view)
    let right = coarse.convert(coarse.bounds, to: view)
    check(track.width >= 100, "\(context): the slider is \(track.width) pt long")
    check(view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(track), "\(context): slider \(track) outside \(view.bounds)")
    check(right.minX - left.maxX >= 20, "\(context): Fine \(left) and Coarse \(right) touch")
    check(abs(left.minX - track.minX) <= 3 && abs(right.maxX - track.maxX) <= 3,
          "\(context): the labels \(left) \(right) are not over the ends of \(track)")
    check(fine.frame.width >= fine.intrinsicContentSize.width - 0.5
              && coarse.frame.width >= coarse.intrinsicContentSize.width - 0.5,
          "\(context): a label is squeezed: \(fine.frame.width)/\(fine.intrinsicContentSize.width), \(coarse.frame.width)/\(coarse.intrinsicContentSize.width)")
    let knob = (slider.cell as! NSSliderCell).knobRect(flipped: slider.isFlipped)
    check(slider.bounds.insetBy(dx: -0.5, dy: -0.5).contains(knob), "\(context): knob \(knob) outside \(slider.bounds)")
}

@main struct Test {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        for path in CommandLine.arguments.dropFirst() {
            let url = URL(fileURLWithPath: path)
            let locale = url.deletingPathExtension().lastPathComponent
            let bundle = Bundle(url: url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())!
            for onBar in [true, false] {
                var objects: NSArray?
                precondition(NSNib(nibNamed: locale, bundle: bundle)!.instantiate(withOwner: nil, topLevelObjects: &objects))
                let host = Host()
                host.view = objects!.compactMap { $0 as? NSView }.first!
                host.onBar = onBar
                let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 700, height: 300),
                                      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.toolbarStyle = .expanded
                let toolbar = NSToolbar(identifier: "HorosEndoscopyLODTest-\(locale)-\(onBar)-\(getpid())")
                toolbar.delegate = host
                toolbar.allowsUserCustomization = true
                window.toolbar = toolbar
                window.orderFront(nil)
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.4))
                if onBar {
                    check(host.view.window === window, "\(locale) bar: the item is not on the bar")
                    checkLOD(host.view, "\(locale) bar")
                } else {
                    toolbar.runCustomizationPalette(nil)
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))
                    check(window.attachedSheet != nil, "\(locale): the customization palette did not open")
                    checkLOD(host.view, "\(locale) palette")
                    if let sheet = window.attachedSheet { window.endSheet(sheet) }
                    // Dragged to the bar afterwards, the item takes the size
                    // the snapshot left the view.
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
                    toolbar.insertItem(withItemIdentifier: NSToolbarItem.Identifier("LOD"), at: 0)
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.4))
                    check(host.view.window === window, "\(locale) bar after the palette: the item is not on the bar")
                    checkLOD(host.view, "\(locale) bar after the palette")
                }
                window.close()
            }
            print("\(locale): checked the LOD item on the bar and in the palette")
        }
        for failure in failures { FileHandle.standardError.write("FAIL: \(failure)\n".data(using: .utf8)!) }
        exit(failures.isEmpty ? 0 : 1)
    }
}
'''

with tempfile.TemporaryDirectory(prefix='horos-endoscopy-lod-') as folder:
    work = Path(folder)
    resources = work / 'Probe.bundle/Contents/Resources'
    resources.mkdir(parents=True)
    (resources.parent / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'org.horosproject.endoscopy-lod-test',
        'CFBundlePackageType': 'BNDL',
    }))
    nibs = []
    for locale in LOCALES:
        source = ET.fromstring(read(f'Horos/Resources/{locale}.lproj/Endoscopy.xib'))
        view = source.find(f'.//customView[@id="{LOD_VIEW}"]')
        if view is None or view.get('userLabel') != 'LOD':
            print(f'FAIL: {locale}: the LOD view ({LOD_VIEW}) is gone from Endoscopy.xib', file=sys.stderr)
            sys.exit(1)
        document = ET.Element('document', source.attrib)
        for dependency in source.findall('dependencies'):
            document.append(deepcopy(dependency))
        objects = ET.SubElement(document, 'objects')
        ET.SubElement(objects, 'customObject', id='-2', userLabel="File's Owner", customClass='NSObject')
        ET.SubElement(objects, 'customObject', id='-1', userLabel='First Responder', customClass='FirstResponder')
        ET.SubElement(objects, 'customObject', id='-3', userLabel='Application', customClass='NSObject')
        view = deepcopy(view)
        for node in view.iter():
            node.attrib.pop('customClass', None)
            for connection in list(node.findall('connections')):
                node.remove(connection)
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

print('PASS: the endoscopy Level of Detail item keeps its width, labels and slider on the bar and in the palette')
