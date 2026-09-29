#!/usr/bin/env python3
"""The orthogonal PET-CT Fusion item shows its percentage from the start.

The percentage field of the PET-CT Fusion item (blendingPercentage, id 79 in
PETCT.xib) read "-" until the slider moved: its title in the xib was "-", and
only -moveBlendingFactorSlider:, which the PET-CT controller sends when the
fusion factor changes, wrote the slider's value into it (#933). This is the
defect #889 fixed in the 2D viewer and #932 in Volume Rendering.

The field now shows the slider's percentage, (v + 256) / 5.12: the xib's title
is 50%, for the slider's centre, and the viewer writes the slider's percentage
when it is set up, before its toolbar is built. The PET-CT viewer always fuses,
so the slider and the percentage are both enabled.

The Blending view of both PETCT.xib localizations is copied into a nib of its
own, compiled with ibtool and loaded in AppKit; it is checked in the
customization palette, which draws it from a snapshot, and on the bar.

`<git revision>` as an optional argument reads the xibs and the viewer from
that revision: that is the negative control.
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
VIEW, PERCENT, SLIDER = '67', '79', '70'


def read(relative):
    if revision is None:
        return (root / relative).read_bytes()
    return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{relative}'],
                                   stderr=subprocess.DEVNULL)


# The viewer writes the slider's percentage when it is set up, before its
# toolbar takes the Fusion view.
viewer = read('Horos/Sources/OrthogonalMPRPETCTViewer.swift').decode('utf-8')
setup = viewer[viewer.index('self.init(windowNibName: "PETCT")'):]
setup = setup[:setup.index('self.setupToolbar()')]
source_failed = 'self.showBlendingPercentage()' not in setup
if source_failed:
    print('FAIL: the PET-CT viewer does not show the fusion percentage when it is set up (#933)', file=sys.stderr)
move = viewer[viewer.index('func moveBlendingFactorSlider('):]
move = move[:move.index('\n    }\n')]
if 'showBlendingPercentage()' not in move and '5.12' not in move:
    print('FAIL: moving the slider no longer writes the percentage', file=sys.stderr)
    source_failed = True

code = r'''
import AppKit

final class Host: NSObject, NSToolbarDelegate {
    var views: [String: NSView] = [:]
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        views.keys.sorted().map { NSToolbarItem.Identifier($0) }
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        guard let view = views[id.rawValue] else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = "Fusion"
        item.paletteLabel = item.label
        item.view = view
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

/// The percentage matches the slider, is enabled with it, fits "100%" and
/// stays inside the view.
func checkFusion(_ view: NSView, _ context: String) {
    guard let slider = descendants(NSSlider.self, in: view).first(where: { $0.identifier?.rawValue == "BlendingSlider" }),
          let percent = descendants(NSTextField.self, in: view).first(where: { $0.identifier?.rawValue == "BlendingPercentage" })
    else { check(false, "\(context): no slider or percentage"); return }
    let expected = String(format: "%0.0f%%", Double(Float(slider.doubleValue + 256.0)) / 5.12)
    check(percent.stringValue == expected,
          "\(context): the percentage reads \"\(percent.stringValue)\" for a slider at \(slider.doubleValue), not \(expected)")
    check(slider.isEnabled && percent.isEnabled == slider.isEnabled,
          "\(context): percentage enabled \(percent.isEnabled), slider enabled \(slider.isEnabled)")
    let widest = NSTextField(labelWithString: "100%")
    widest.font = percent.font
    check(widest.intrinsicContentSize.width <= percent.alignmentRect(forFrame: percent.frame).width + 0.5,
          "\(context): \"100%\" does not fit \(percent.frame)")
    let frame = percent.convert(percent.bounds, to: view)
    check(view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame),
          "\(context): percentage at \(frame) outside \(view.bounds)")
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
            let view = host.views["2DBlending"]!
            checkFusion(view, "\(locale) nib")

            let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 700, height: 300),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.toolbarStyle = .expanded
            let toolbar = NSToolbar(identifier: "HorosPETCTFusionTest-\(locale)-\(getpid())")
            toolbar.delegate = host
            toolbar.allowsUserCustomization = true
            window.toolbar = toolbar
            window.orderFront(nil)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
            toolbar.runCustomizationPalette(nil)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))
            let sheet = window.attachedSheet
            check(sheet != nil, "\(locale): the customization palette did not open")
            checkFusion(view, "\(locale) palette")
            if let sheet { window.endSheet(sheet) }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))

            toolbar.insertItem(withItemIdentifier: NSToolbarItem.Identifier("2DBlending"), at: 0)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
            check(view.window === window, "\(locale): the Fusion view is not on the bar")
            checkFusion(view, "\(locale) bar")
            window.close()
            print("\(locale): checked the Fusion view")
        }
        if !failures.isEmpty {
            for failure in failures { FileHandle.standardError.write("FAIL: \(failure)\n".data(using: .utf8)!) }
            exit(1)
        }
    }
}
'''

with tempfile.TemporaryDirectory(prefix='horos-petct-fusion-') as folder:
    work = Path(folder)
    resources = work / 'Probe.bundle/Contents/Resources'
    resources.mkdir(parents=True)
    (resources.parent / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'org.horosproject.petct-fusion-percentage-test',
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
        view = source.find(f'.//customView[@id="{VIEW}"]')
        if view is None:
            print(f'FAIL: {locale}: the Fusion view ({VIEW}) is gone from PETCT.xib', file=sys.stderr)
            sys.exit(1)
        view = deepcopy(view)
        for node in view.iter():
            node.attrib.pop('customClass', None)
            for connection in list(node.findall('connections')):
                node.remove(connection)
        view.set('identifier', '2DBlending')
        for identifier, name in ((PERCENT, 'BlendingPercentage'), (SLIDER, 'BlendingSlider')):
            # The fields the viewer's outlets name.
            node = view.find(f'.//*[@id="{identifier}"]')
            if node is None:
                print(f'FAIL: {locale}: {name} ({identifier}) is gone from PETCT.xib', file=sys.stderr)
                sys.exit(1)
            node.set('identifier', name)
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
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(swift), '-o', str(binary)], check=True)
    result = subprocess.run([str(binary), *map(str, nibs)], capture_output=True, text=True)
    sys.stdout.write(result.stdout)
    sys.stderr.write(result.stderr)
    if result.returncode or source_failed:
        sys.exit(1)

print('PASS: the PET-CT Fusion item shows the slider\'s percentage, enabled with it, in the palette and on the bar')
