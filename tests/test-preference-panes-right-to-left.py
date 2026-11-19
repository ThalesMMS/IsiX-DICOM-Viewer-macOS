#!/usr/bin/env python3
"""The preference panes are mirrored in a language written from right to left.

The nibs of the panes are laid out by frames and their copies keep the frames
of the English nib: in Arabic the label stayed on the left of its pop-up and
the box of a checkbox on the left of its title. `PaneMirror` mirrors a loaded
pane. What is checked, with the helper compiled as the app compiles it:

- Arabic and Hebrew are mirrored, and no language written from left to right;
- in a view made here, each view goes to the other side of the view it is in,
  inside a box and inside a tab too; a margin kept on one side is kept on the
  other; text set to one side goes to the other and centred text stays; the
  box of a checkbox follows the direction; every control is told it;
- mirrored twice, the frames are those it had;
- the Arabic copy of the Viewers pane, compiled and loaded: after the mirror
  no view leaves the view it is in, and every checkbox has its box on the
  side the direction gives it;
- the loader of the panes mirrors the windows of a nib, and the pane that
  lays its own rows out afterwards asks it not to.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
helper = root / 'Preference Panes/PaneCatalogTranslation.swift'
failures = []

MAIN = r'''
import AppKit
_ = NSApplication.shared
var failed = false
func expect(_ ok: Bool, _ message: String) { if !ok { print("FAIL: \(message)"); failed = true } }

expect(PaneMirror.isNeeded(language: "ar") && PaneMirror.isNeeded(language: "he"), "Arabic and Hebrew are mirrored")
for language in ["en", "de", "fr", "ja-JP", "ko", "zh-Hans", "hi", "ru", "pt-BR", "es", "it-IT"] {
    expect(!PaneMirror.isNeeded(language: language), "\(language) is not mirrored")
}
expect(!PaneMirror.isNeeded(language: nil), "no language, no mirror")

let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
let label = NSTextField(labelWithString: "Label:")
label.frame = NSRect(x: 20, y: 250, width: 100, height: 17); label.alignment = .right
let popUp = NSPopUpButton(frame: NSRect(x: 130, y: 245, width: 150, height: 25))
popUp.autoresizingMask = [.maxXMargin]
let check = NSButton(checkboxWithTitle: "A checkbox", target: nil, action: nil)
check.frame = NSRect(x: 20, y: 200, width: 200, height: 18); check.alignment = .left; check.imagePosition = .imageLeft
let centred = NSTextField(labelWithString: "Centre")
centred.frame = NSRect(x: 150, y: 170, width: 100, height: 17); centred.alignment = .center
let box = NSBox(frame: NSRect(x: 50, y: 60, width: 200, height: 100)); box.boxType = .custom; box.borderWidth = 0; box.contentViewMargins = .zero
let inner = NSTextField(frame: NSRect(x: 10, y: 10, width: 60, height: 22)); inner.alignment = .left
box.contentView?.addSubview(inner)
let tabs = NSTabView(frame: NSRect(x: 260, y: 20, width: 130, height: 120))
let item = NSTabViewItem(identifier: "a"); item.view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 60))
let tabbed = NSButton(frame: NSRect(x: 5, y: 5, width: 40, height: 20)); item.view?.addSubview(tabbed); tabs.addTabViewItem(item)
let stretched = NSTextField(frame: NSRect(x: 20, y: 20, width: 100, height: 22)); stretched.autoresizingMask = [.minXMargin, .width]
for view in [label, popUp, check, centred, box, tabs, stretched] as [NSView] { root.addSubview(view) }
let innerWidth = box.contentView!.bounds.width
let tabWidth = item.view!.bounds.width
let before = root.subviews.map(\.frame)

PaneMirror.mirror(contentsOf: root)
expect(label.frame.minX == 280 && popUp.frame.minX == 120, "the label goes to the right of its pop-up: \(label.frame.minX), \(popUp.frame.minX)")
expect(label.frame.minX >= popUp.frame.maxX, "the label and the pop-up overlap")
expect(label.alignment == .left, "a label set to the right is set to the left, towards its field")
expect(check.frame.minX == 180 && check.alignment == .right, "the checkbox and its text go to the right")
expect(check.imagePosition == .imageLeading && check.userInterfaceLayoutDirection == .rightToLeft, "the box of a checkbox follows the direction")
expect(centred.frame.minX == 150 && centred.alignment == .center, "centred text stays centred")
expect(box.frame.minX == 150 && inner.frame.minX == innerWidth - 70 && inner.alignment == .right, "a box is mirrored and what it holds too: \(inner.frame.minX) of \(innerWidth)")
expect(tabbed.frame.minX == tabWidth - 45, "what a tab holds is mirrored: \(tabbed.frame.minX) of \(tabWidth)")
expect(popUp.autoresizingMask == [.minXMargin] && stretched.autoresizingMask == [.maxXMargin, .width], "a margin kept on one side is kept on the other")
expect(popUp.userInterfaceLayoutDirection == .rightToLeft && label.userInterfaceLayoutDirection == .rightToLeft, "every control is told the direction")
PaneMirror.mirror(contentsOf: root)
expect(root.subviews.map(\.frame) == before, "mirrored twice, the frames are those it had")

// The Arabic copy of a pane. Its bindings ask its owner for the pane's values: this one has none.
final class Owner: NSObject {
    override func value(forUndefinedKey key: String) -> Any? { nil }
    override func setValue(_ value: Any?, forUndefinedKey key: String) {}
}
let owner = Owner()
let nib = NSNib(nibData: try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])), bundle: nil)
var top: NSArray?
expect(nib.instantiate(withOwner: owner, topLevelObjects: &top), "the Arabic copy loads")
var views = 0, checkboxes = 0
for case let window as NSWindow in top ?? [] {
    guard let content = window.contentView else { continue }
    func inside(_ view: NSView) -> [ObjectIdentifier: Bool] {
        var result: [ObjectIdentifier: Bool] = [:]
        var stack = [view]
        while let next = stack.popLast() {
            for subview in next.subviews where !(next is NSControl) && !(next is NSScrollView) {
                result[ObjectIdentifier(subview)] = next.bounds.insetBy(dx: -0.5, dy: -0.5).contains(subview.frame)
                stack.append(subview)
            }
        }
        return result
    }
    let was = inside(content)
    PaneMirror.mirror(contentsOf: content)
    let now = inside(content)
    for (view, fitted) in was where fitted { views += 1; expect(now[view] == true, "a view left the view it is in") }
    var stack = [content]
    while let next = stack.popLast() {
        stack.append(contentsOf: next.subviews)
        if let tabs = next as? NSTabView { stack.append(contentsOf: tabs.tabViewItems.compactMap(\.view).filter { $0.superview == nil }) }
        guard let button = next as? NSButton, let cell = button.cell as? NSButtonCell, !(next is NSPopUpButton), !button.title.isEmpty else { continue }
        if cell.imagePosition == .imageLeft || cell.imagePosition == .imageRight { expect(false, "the button \(button.title) keeps its image on a fixed side") }
        if cell.imagePosition == .imageLeading { checkboxes += 1; expect(button.userInterfaceLayoutDirection == .rightToLeft, "\(button.title) was not told the direction") }
    }
}
expect(views > 50 && checkboxes > 10, "the Arabic copy was not walked: \(views) views, \(checkboxes) checkboxes")
if failed { exit(1) }
print("PASS: a pane is mirrored for Arabic: \(views) views of the Viewers pane stay inside theirs, \(checkboxes) checkboxes follow the direction")
'''

text = helper.read_text(encoding='utf-8')
if 'if mirrors && PaneMirror.isNeeded() { PaneMirror.mirror(contentsOf: content) }' not in text:
    failures.append('the loader of the panes does not mirror the windows of a nib')
annotations = (root / 'Preference Panes/OSICustomImageAnnotations/OSICustomImageAnnotations.swift').read_text(encoding='utf-8')
if 'instantiatePaneNib(named: "OSICustomImageAnnotations", mirrors: false' not in annotations:
    failures.append('the Annotation Layout pane, which lays its rows out after the load, is mirrored before it does')

with tempfile.TemporaryDirectory(prefix='horos-pane-mirror-') as directory:
    path = Path(directory)
    (path / 'main.swift').write_text(MAIN)
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', str(helper), str(path / 'main.swift'), '-o', str(path / 'test')],
                           capture_output=True, text=True)
    if built.returncode:
        sys.exit('FAIL: the helper does not mirror a pane:\n' + built.stderr[-1500:])
    copy = root / 'Horos/Resources/ar.lproj/OSIViewerPreferencePanePref.xib'
    subprocess.run(['xcrun', 'ibtool', '--errors', '--compile', str(path / 'pane.nib'), str(copy)], check=True, capture_output=True)
    compiled = path / 'pane.nib'
    if compiled.is_dir():
        compiled = compiled / 'keyedobjects.nib'
    ran = subprocess.run([str(path / 'test'), str(compiled)], capture_output=True, text=True)
    lines = [line for line in ran.stdout.splitlines() if line.startswith(('FAIL', 'PASS'))]
    if ran.returncode or not any(line.startswith('PASS') for line in lines):
        failures.extend(lines or [ran.stderr[-800:]])
    else:
        print(lines[-1])

if failures:
    sys.exit('FAIL:\n' + '\n'.join(failures))
