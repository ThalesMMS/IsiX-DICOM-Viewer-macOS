#!/usr/bin/env python3
"""-[ROIWindow removeAllROIsWithName:] closes its window.

The method removes the ROIs of that name from the viewer and ends the ROI
window. It called -windowWillClose: directly, with no notification: the
controller stored the name and comments, autoreleased itself and went when the
pool drained, with its window still on screen and the window's delegate
dangling. It now closes the window, and -windowWillClose: runs once, from the
close.

-removeAllROIsWithName: and -windowWillClose: are taken from ROIWindow.swift
and compiled with xcrun swiftc into a stand-in ROIWindow over a real window
whose delegate it is, as ROI.xib makes it, beside stand-in ROI and
ViewerController. The ROIs of that name are removed and the others kept, the
window is closed, and -windowWillClose: ran once, with the notification of the
close, and not again when the pool drained. `<git revision>` as an optional
argument reads that revision's source, the negative control.
"""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
path = 'Horos/Sources/ROIWindow.swift'


def read():
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode('utf-8')
    return (root / path).read_text(encoding='utf-8')


def method(source, signature, end='\n    }\n'):
    start = source.find(signature)
    if start < 0:
        return None
    return source[start:source.index(end, start) + len(end)]


if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc)', file=sys.stderr)
    sys.exit(2)

source = read()
remove_all = method(source, '    @objc(removeAllROIsWithName:)')
will_close = method(source, '    @objc(windowWillClose:)')
if remove_all is None or will_close is None:
    print('FAIL: -removeAllROIsWithName: or -windowWillClose: is gone from ROIWindow.swift; this test needs a new look')
    sys.exit(1)

swift = r'''import AppKit

extension NSNotification.Name {
    static let OsirixROIChange = NSNotification.Name("OsirixROIChangeNotification")
}

private func objcEqualStrings(_ a: String?, _ b: String?) -> Bool {
    guard let a = a, let b = b else { return false }
    return (a as NSString).isEqual(to: b)
}

final class ROI: NSObject {
    @objc var name: String?
    init(_ name: String) { self.name = name }
    static func saveDefaultSettings() {}
}

final class ViewerController: NSObject {
    let rois = NSMutableArray(array: [
        NSMutableArray(array: [ROI("A"), ROI("B"), ROI("A")]),
        NSMutableArray(array: [ROI("A")]),
        NSMutableArray(array: [ROI("C"), ROI("A"), ROI("A"), ROI("B")]),
    ])
    let view = NSView()
    func roiList() -> NSMutableArray? { rois }
    func imageView() -> NSView? { view }
}

var willClose: [NSNotification?] = []

/// ROIWindow as these two methods see it. As ROI.xib makes it, the controller
/// is its window's delegate.
final class ROIWindow: NSWindowController, NSWindowDelegate {
    private var roi: ROI?
    private var curController: ViewerController?
    @objc(windowWillClose) public private(set) var closing = false
    private var getName: Timer?

    init(roi: ROI, controller: ViewerController) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        self.roi = roi
        curController = controller
    }
    required init?(coder: NSCoder) { fatalError() }

    private func storeNameAndComments() -> NSException? {
        willClose.append(currentNotification)
        return nil
    }
    private var currentNotification: NSNotification?

%s

    @objc(windowWillClose:)
    public func windowWillClose(_ notification: NSNotification!) {
        currentNotification = notification
        realWindowWillClose(notification)
    }

%s
}

_ = NSApplication.shared
let viewer = ViewerController()
let window: NSWindow

do {
    let first = (viewer.rois[0] as! NSMutableArray)[1] as! ROI
    // The +1 the code that makes a ROIWindow keeps, which -windowWillClose: gives back.
    let controller = Unmanaged.passRetained(ROIWindow(roi: first, controller: viewer)).takeUnretainedValue()
    window = controller.window!
    window.orderFront(nil)
    precondition(window.isVisible, "the window is not on screen; the test sees nothing")

    autoreleasepool {
        controller.removeAllROIsWithName("A")

        let names = (viewer.rois as! [NSMutableArray]).map { ($0 as! [ROI]).map { $0.name! } }
        precondition(names == [["B"], [], ["C", "B"]], "the ROIs left are \(names), not those of other names")
        if window.isVisible {
            print("FAIL: the window is still on screen after -removeAllROIsWithName:")
            exit(1)
        }
        if willClose.count != 1 {
            print("FAIL: -windowWillClose: ran \(willClose.count) times, not once")
            exit(1)
        }
        if willClose[0] == nil {
            print("FAIL: -windowWillClose: was called directly, not by the close of the window")
            exit(1)
        }
    }
    precondition(willClose.count == 1, "-windowWillClose: ran again")
}
print("removeAllROIsWithName: removes the ROIs of that name and closes the window; -windowWillClose: ran once, from the close")
''' % (remove_all, will_close.replace(
    '    @objc(windowWillClose:)\n    public func windowWillClose(_ notification: NSNotification!) {',
    '    func realWindowWillClose(_ notification: NSNotification!) {'))

if 'func realWindowWillClose(' not in swift:
    print('FAIL: the signature of -windowWillClose: changed; this test needs a new look')
    sys.exit(1)

with tempfile.TemporaryDirectory(prefix='horos-roi-window-') as tmp:
    p = Path(tmp)
    (p / 'main.swift').write_text(swift)
    compiled = subprocess.run(['xcrun', 'swiftc', str(p / 'main.swift'), '-o', str(p / 'probe')], capture_output=True, text=True)
    if compiled.returncode:
        print(compiled.stderr.strip()[-3000:])
        print('FAIL: -removeAllROIsWithName: and -windowWillClose: did not compile in the stand-in')
        sys.exit(1)
    run = subprocess.run([str(p / 'probe')], capture_output=True, text=True, timeout=60)
    print((run.stdout + run.stderr).strip()[-2000:])
    if run.returncode:
        sys.exit(1)
print('ok: -removeAllROIsWithName: closes the ROI window')
