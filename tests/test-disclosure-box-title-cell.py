#!/usr/bin/env python3
"""N2DisclosureBox returns its disclosure cell and N2StepsView can show a step (#746).

-[N2DisclosureBox initWithTitle:content:] never returned. The `titleCell`
getter was `return self.titleCell;`, which calls itself, and NSBox has no
-setTitleCell:, so the setter was an unrecognized selector. The Swift
translation of #709 kept both. N2StepView is an N2DisclosureBox, and
N2StepsView makes one for every step added: the step API of the SDK could not
be used at all.

NSBox cannot take the disclosure cell as its own title cell either: it shows
its title in an NSTextField built on that cell, and a button cell there raises
as soon as the box lays its title out again. So the box keeps NSBox's title
cell, with an empty title, and holds and draws the disclosure cell itself.

The real sources of the box, the disclosure cell and the step classes, with
the N2View layout they use, are compiled into a small program run in a child
process with a time limit, since the defect is a hang or a stack overflow:
- a box is made, `titleCell` is its N2DisclosureButtonCell, drawn in the
  title rect, the setter installs another one, NSBox's own title stays an
  empty NSTextFieldCell;
- the box expands and collapses, with its notifications, from `toggle:` as a
  click on the triangle sends it, and draws in both states;
- an N2StepsView gets an N2Steps with one step: the step view is made, the
  step becomes active and its view is shown, then inactive and hidden, and the
  steps view draws.

`<git revision>` as an optional argument reads the sources from that
revision, the negative control.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
folder = 'Nitrogen/Sources'

SWIFT = ['N2DisclosureBox', 'N2DisclosureButtonCell', 'N2Step', 'N2Steps', 'N2StepView', 'N2StepsView',
         'N2View', 'N2Layout', 'N2ColumnLayout', 'N2CellDescriptor', 'NSView+N2']
OBJC = ['N2Exceptions+CAPI.m', 'N2DisclosureBox+CAPI.m', 'N2Step+CAPI.m', 'N2Steps+CAPI.m', 'N2View+CAPI.m', 'N2MinMax.mm', 'N2Alignment.mm']
HEADERS = ['N2Exceptions.h', 'N2DisclosureBox.h', 'N2DisclosureButtonCell.h', 'N2Step.h', 'N2Steps.h', 'N2StepView.h', 'N2StepsView.h',
           'N2View.h', 'N2Layout.h', 'N2ColumnLayout.h', 'N2CellDescriptor.h']


def read(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}'])
    return (root / path).read_bytes()


MAIN = r'''
import Cocoa

setvbuf(stdout, nil, _IONBF, 0)

func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition {
        print("FAIL line \(line): \(message)")
        exit(1)
    }
}

func draw(_ view: NSView) -> Bool {
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    return true
}

/// Pixels painted inside `rect` of the box, drawn alone.
func painted(_ box: NSBox, in rect: NSRect) -> Int {
    guard let bitmap = box.bitmapImageRepForCachingDisplay(in: box.bounds) else { return 0 }
    box.cacheDisplay(in: box.bounds, to: bitmap)
    let scale = CGFloat(bitmap.pixelsWide) / box.bounds.width
    var count = 0
    for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
        for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
            if let color = bitmap.colorAt(x: x, y: bitmap.pixelsHigh - 1 - y), color.alphaComponent > 0.3 { count += 1 }
        }
    }
    return count
}

var posted: [String] = []
for name in [Notification.Name.N2DisclosureBoxWillExpand, .N2DisclosureBoxDidExpand, .N2DisclosureBoxDidCollapse, .N2DisclosureBoxDidToggle] {
    NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { posted.append($0.name.rawValue) }
}

print("making the box")
let content = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
let box = N2DisclosureBox(title: "Details", content: content)
print("box made")

let cell = box.titleCell as? N2DisclosureButtonCell
check(cell != nil, "titleCell is \(type(of: box.titleCell)), not an N2DisclosureButtonCell")
check(cell!.title == "Details" && box.title == "Details", "the title is not the cell's")
check(cell!.target === box && cell!.action == #selector(N2DisclosureBox.toggle(_:)), "the cell does not toggle the box")
check((box as NSBox).value(forKey: "titleCell") as AnyObject === cell!, "titleCell answers Objective-C with another cell")
check(!box.isExpanded() && content.superview == nil, "a new box is expanded")
check(draw(box), "the collapsed box does not draw")
check(box.titleRect.width > cell!.textSize().width, "the title rect does not hold the triangle and the title")
// Collapsed, the box is as wide as its margins; a layout widens it.
box.setFrameSize(NSSize(width: 240, height: box.frame.height))
check(painted(box, in: box.titleRect) > 20, "neither triangle nor title is drawn")
check(((box as NSBox).value(forKey: "_titleCell") as? NSTextFieldCell)?.stringValue == "", "NSBox shows a title of its own")
let collapsedHeight = box.frame.height

// A click on the triangle: the cell switches its state, then sends toggle:.
cell!.state = .on
box.toggle(cell)
check(box.isExpanded() && content.isDescendant(of: box), "toggle: did not expand the box")
check(box.frame.height >= collapsedHeight + content.frame.height, "the expanded box does not hold its content")
check(draw(box), "the expanded box does not draw")
cell!.state = .off
box.toggle(cell)
check(!box.isExpanded() && content.superview == nil, "toggle: did not collapse the box")
check(box.frame.height == collapsedHeight, "the collapsed box kept the content's height")
check(draw(box), "the collapsed box does not draw again")
check(posted == ["N2DisclosureBoxWillExpandNotification", "N2DisclosureBoxDidExpandNotification", "N2DisclosureBoxDidToggleNotification",
                 "N2DisclosureBoxDidCollapseNotification", "N2DisclosureBoxDidToggleNotification"], "notifications: \(posted)")

let other = N2DisclosureButtonCell()
box.titleCell = other
check(box.titleCell as AnyObject === other, "the setter did not install the cell")
box.title = "Renamed"
check(other.title == "Renamed" && box.title == "Renamed", "the title does not go to the installed cell")
check((box as NSBox).value(forKey: "_titleCell") is NSTextFieldCell, "NSBox lost its own title cell")
box.titlePosition = .noTitle
box.titlePosition = .atTop
check(draw(box), "the box does not draw after NSBox laid its title out again")
print("box: titleCell, setter, expand, collapse and drawing")

print("making the steps view")
let stepContent = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 60))
let step = N2Step(title: "Open", enclosedView: stepContent)
let steps = N2Steps()
steps.content = NSMutableArray()
let stepsView = N2StepsView(frame: NSRect(x: 0, y: 0, width: 240, height: 100))
// Made in code, the view observes every N2Steps; a second awakeFromNib
// would observe twice.
steps.addObject(step)
print("step added")

let stepView = stepsView.stepView(for: step)
check(stepView != nil, "no view for the step")
check(stepsView.subviews.filter { $0 is N2StepView }.count == 1, "one step, \(stepsView.subviews.count) views")
check(steps.currentStep === step && step.active, "the step is not the current one")
check(stepView!.titleCell is N2DisclosureButtonCell && stepView!.title == "Open", "the step view's title cell")
check(stepView!.isExpanded() && stepContent.isDescendant(of: stepView!), "the active step is not shown")
check(draw(stepsView), "the steps view does not draw with its step shown")
step.active = false
check(!stepView!.isExpanded() && stepContent.superview == nil, "the inactive step is still shown")
check(draw(stepsView), "the steps view does not draw with its step hidden")
step.title = "Opened"
check(stepView!.title == "Opened", "the step view's title did not follow the step")
steps.removeObject(step)
check(stepsView.stepView(for: step) == nil, "the step view outlived its step")
print("steps view: one step added, shown, hidden, drawn and removed")
print("done")
'''

with tempfile.TemporaryDirectory(prefix='horos-disclosure-box-') as tmp:
    p = Path(tmp)
    src = p / 'src'
    src.mkdir()
    for name in HEADERS + OBJC + ['N2MinMax.h', 'N2Alignment.h', 'N2Operators.h', 'NSView+N2.h']:
        (src / name).write_bytes(read(f'{folder}/{name}'))
    for name in SWIFT:
        (src / f'{name}.swift').write_bytes(read(f'{folder}/{name}.swift'))
    (p / 'main.swift').write_text(MAIN)
    (p / 'bridging.h').write_text('#define HOROS_BRIDGING_HEADER 1\n#import <Cocoa/Cocoa.h>\n'
                                  + ''.join(f'#import "{name}"\n' for name in HEADERS))
    swiftc = ['xcrun', 'swiftc', '-Onone', '-module-name', 'Horos', '-suppress-warnings',
              '-import-objc-header', str(p / 'bridging.h'), '-Xcc', '-I' + str(src),
              *[str(src / f'{name}.swift') for name in SWIFT]]

    def compile(command):
        build = subprocess.run(command, capture_output=True, text=True)
        if build.returncode:
            print(build.stderr[-4000:])
            print('FAIL: the sources do not compile')
            sys.exit(1)

    # The Objective-C parts import the generated interface, as in the app.
    compile(swiftc + ['-typecheck', '-emit-objc-header-path', str(p / 'Horos-Swift.h')])
    objects = []
    for name in OBJC:
        obj = p / (name + '.o')
        compile(['xcrun', 'clang', '-c', '-fobjc-arc', '-Wno-deprecated-declarations',
                 '-I', str(src), '-I', str(p), str(src / name), '-o', str(obj)])
        objects.append(str(obj))
    compile(swiftc + [str(p / 'main.swift'), *objects, '-lc++', '-o', str(p / 'probe')])

    try:
        run = subprocess.run([str(p / 'probe')], capture_output=True, text=True, timeout=60)
        output, code = run.stdout, run.returncode
    except subprocess.TimeoutExpired as expired:
        output = expired.stdout.decode() if isinstance(expired.stdout, bytes) else (expired.stdout or '')
        code = 'timeout'

lines = output.strip().splitlines()
if code != 0 or not lines or lines[-1] != 'done':
    last = lines[-1] if lines else 'nothing'
    print(f'FAIL: the program ended with {code} after "{last}"')
    sys.exit(1)
print('PASS: N2DisclosureBox returns and installs its disclosure cell, expands, collapses and draws; '
      'N2StepsView shows, hides and removes a step')
