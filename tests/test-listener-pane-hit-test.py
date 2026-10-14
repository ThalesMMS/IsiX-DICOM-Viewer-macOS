#!/usr/bin/env python3
"""Every control of the Listener preferences gets the clicks made on it.

The box that holds the AE title, port and timeouts reserved, above its border,
the room of a title it does not have. That room covered 13 of the 18 points of
"Activate DICOM listener when IsiX DICOM Viewer is running", the box being the
later sibling: a click on the middle of the checkbox or on its text reached
the box, and only its top edge switched the listener on or off.

Each variant of the pane is compiled with ibtool and loaded; at nine points
inside every visible control (three points in from the edges of what it draws), the window's hit
test must find that control, something inside it or another control - never
a box or a plain view that only holds others. Over the box and the title of a
checkbox or radio button only that button may answer: in German and Russian
the field of the XML-RPC port covered the end of its checkbox's title.
"""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
SKIPPED = 2

if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc, ibtool)', file=sys.stderr)
    sys.exit(SKIPPED)

CHECK = r'''
import AppKit

final class Owner: NSObject {
    @IBOutlet @objc var mainWindow: NSWindow?
    override func value(forUndefinedKey key: String) -> Any? { nil }
    override func setValue(_ value: Any?, forUndefinedKey key: String) {}
}
var failed = false
func check(_ condition: Bool, _ what: String) {
    if !condition { FileHandle.standardError.write("FAIL: \(what)\n".data(using: .utf8)!); failed = true }
}
func controls(in view: NSView) -> [NSControl] {
    view.subviews.flatMap { sub -> [NSControl] in
        if let control = sub as? NSControl, !(sub is NSTableView) { return [control] }
        return controls(in: sub)
    }
}
func name(of control: NSControl) -> String {
    let text = (control as? NSButton)?.title ?? control.stringValue
    return "\(type(of: control)) \"\(text.prefix(40))\" at \(control.frame)"
}
_ = NSApplication.shared
var checked = 0
var listener = false
MainActor.assumeIsolated {
    for path in CommandLine.arguments.dropFirst() {
        let nibName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let owner = Owner()
        var objects: NSArray?
        let nib = NSNib(nibData: try! Data(contentsOf: URL(fileURLWithPath: path)), bundle: nil)
        guard nib.instantiate(withOwner: owner, topLevelObjects: &objects), let content = owner.mainWindow?.contentView else {
            check(false, "\(nibName): the pane did not load"); continue
        }
        for control in controls(in: content) where !control.isHiddenOrHasHiddenAncestor {
            // What a checkbox or radio button draws, its box and its title, may
            // end before its frame does; a field placed after the text then
            // rightly takes the clicks over the rest of the frame.
            var area = control.bounds
            if let button = control as? NSButton, let cell = button.cell, button.title.isEmpty == false {
                area.size.width = min(area.width, cell.cellSize.width)
            }
            let bounds = area.insetBy(dx: min(3, area.width / 4), dy: min(3, area.height / 4))
            var missed: [String] = []
            for fx in [0.0, 0.5, 1.0] {
                for fy in [0.0, 0.5, 1.0] {
                    let local = NSPoint(x: bounds.minX + bounds.width * fx, y: bounds.minY + bounds.height * fy)
                    let point = content.superview!.convert(control.convert(local, to: nil), from: nil)
                    let hit = content.hitTest(point)
                    // Another control on top is a layout choice; a box or a
                    // plain view is not. Over what a checkbox or a radio button
                    // draws, though, only that button may answer: a field
                    // covering the end of its title hid the text and took the
                    // clicks on it.
                    let mine = hit === control || hit?.isDescendant(of: control) == true
                    let drawn = (control as? NSButton).map { $0.title.isEmpty == false } ?? false
                    if hit == nil || !(mine || (!drawn && hit is NSControl)) {
                        missed.append("(\(Int(local.x)),\(Int(local.y))) -> \(hit.map { "\(type(of: $0)) \($0.frame)" } ?? "nothing")")
                    }
                }
            }
            check(missed.isEmpty, "\(nibName): \(name(of: control)) does not get clicks at \(missed.joined(separator: "; "))")
            checked += 1
            if let button = control as? NSButton, button.infoForBinding(.value)?[.observedKeyPath] as? String == "values.STORESCP" {
                listener = true
            }
        }
    }
}
check(listener, "the listener's checkbox (bound to values.STORESCP) was not among the controls checked")
if failed { exit(1) }
print("PASS: \(checked) controls in \(CommandLine.arguments.count - 1) variants of the Listener pane get their clicks")
'''

with tempfile.TemporaryDirectory(prefix='horos-listener-hit-') as folder:
    folder = Path(folder)
    xibs = {language: root / 'Preference Panes/OSIListenerPreferencePane' / f'{language}.lproj' for language in ('Base', 'ja-JP')}
    xibs.update({language: root / 'Horos/Resources' / f'{language}.lproj'
                 for language in ('ar', 'de', 'fr', 'hi', 'ko', 'pt-BR', 'ru', 'zh-Hans')})
    nibs = []
    for language, location in xibs.items():
        nib = folder / f'{language}.nib'
        built = subprocess.run(['xcrun', 'ibtool', '--compile', str(nib), str(location / 'OSIListenerPreferencePanePref.xib')],
                               capture_output=True, text=True)
        if built.returncode or not nib.exists():
            print(f'FAIL: {language}: the pane does not compile\n{built.stdout[-800:]}{built.stderr[-800:]}')
            sys.exit(1)
        nibs.append(str(nib))
    (folder / 'main.swift').write_text(CHECK)
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(folder / 'modules'), str(folder / 'main.swift'),
                    '-o', str(folder / 'check')], check=True)
    ran = subprocess.run([str(folder / 'check'), *nibs], capture_output=True, text=True, timeout=180)
    if ran.returncode:
        print('\n'.join(line for line in ran.stderr.splitlines() if line.startswith('FAIL')) or ran.stderr[-3000:])
        sys.exit(1)
    print(ran.stdout.strip())
