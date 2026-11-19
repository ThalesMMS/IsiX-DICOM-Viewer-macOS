#!/usr/bin/env python3
"""A 3D window takes its panels off the screen when it closes.

The 3D MPR, the volume rendering, the surface rendering and the endoscopy
windows each have panels of their own beside the window: the Shading panel
the Edit button of the shading presets opens, the 3D presets, the information
of a 3D point, the Path Assistant of the endoscopy and its parameters.
A panel is a window of the nib, and a window stays on the screen until
something orders it out: the Shading panel of a 3D MPR left open when the
window closed stayed there, with a table bound to the presets of a
controller that was gone and buttons that message it.

1. CompanionPanels, compiled as it is with a driver in AppKit: panels on the
   screen, one with a sheet, are off it after `takeOffScreen`, the sheet
   ended; a nil among them is passed over; nothing is told that a window will
   close, which a controller that hears it of every window of its nib would
   take for its own; a panel nothing else keeps is released once off the
   screen; and a panel made to be released when closed, as the Path Assistant
   is, is not released: it comes back when ordered front again, and goes
   once, with what keeps it.
2. Every panel of the nibs of the four windows, in every language's copy,
   is one the window's controller takes off the screen in -windowWillClose:,
   before it lets go of itself: the panels are read from the nibs (a window
   of class NSPanel that an outlet of the nib's owner, of its 3D view or, in
   the endoscopy, of the VR controller inside the nib names), so a panel
   added to a nib is asked of the controller too. A panel the nib releases
   when it is closed is never closed there: closed by the controller and
   then let go by the nib's owner, it would be released twice.

`<git revision>` as an optional argument reads the controllers from that
revision: that is the negative control.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / 'Horos/Resources'
HELPER = ROOT / 'Horos/Sources/CompanionPanels.swift'
revision = sys.argv[1] if len(sys.argv) > 1 else None
# The nib of a window, the file of its controller, and how the controller
# reaches the objects of the nib, by their class, whose outlets hold panels
# too: its 3D view and, in the endoscopy, the VR controller the nib makes.
WINDOWS = {
    'MPR': ('Horos/Sources/MPRController.swift', {}),
    'VR': ('Horos/Sources/VRController.swift', {'VRView': 'vrView?.'}),
    'SR': ('Horos/Sources/SRController.swift', {'SRView': 'srView?.'}),
    'Endoscopy': ('Horos/Sources/EndoscopyViewer.swift', {'EndoscopyVRController': 'vrController?.',
                                                          'EndoscopyVRView': 'vrController?.vrView?.'}),
}

if not shutil.which('xcrun'):
    print('skipped: needs xcrun (swiftc)', file=sys.stderr)
    sys.exit(2)

failures = []


def read(relative):
    if revision is None:
        return (ROOT / relative).read_text(encoding='utf-8')
    return subprocess.check_output(['git', '-C', str(ROOT), 'show', f'{revision}:{relative}'],
                                   stderr=subprocess.DEVNULL).decode('utf-8')


def body(text, signature):
    at = text.find(signature)
    if at < 0:
        return ''
    opening = text.index('{', at)
    depth = 0
    for index in range(opening, len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[opening:index + 1]
    return ''


def panels(xib):
    """The panels of a nib: (the outlet that names it, the class of the
    object whose outlet it is, None for the nib's owner, the panel's title,
    whether the nib releases the panel when it is closed), for every window
    of class NSPanel."""
    document = ET.parse(xib).getroot()
    parents = {child: parent for parent in document.iter() for child in parent}
    ids = {window.get('id'): window for window in document.iter('window') if window.get('customClass') == 'NSPanel'}
    found, named = [], set()
    for outlet in document.iter('outlet'):
        if outlet.get('destination') in ids:
            holder = parents[parents[outlet]]
            panel = ids[outlet.get('destination')]
            # A window of a nib is released when closed unless the nib says NO.
            found.append((outlet.get('property'), None if holder.get('id') == '-2' else holder.get('customClass'),
                          panel.get('title') or '', panel.get('releasedWhenClosed') != 'NO'))
            named.add(outlet.get('destination'))
    return found, sorted(set(ids) - named)


for nib, (source, reached) in WINDOWS.items():
    closing = body(read(source), 'func windowWillClose(_ notification: Notification)')
    if not closing:
        failures.append(f'{source}: no -windowWillClose:')
        continue
    released = closing.find('.autorelease()')
    if released < 0:
        failures.append(f'{source}: -windowWillClose: does not let go of the controller as it did; check where the panels go')
    taken = ' '.join(re.findall(r'CompanionPanels\.takeOffScreen\(([^)]*)\)', closing[:released if released >= 0 else None]))
    copies = sorted(RESOURCES.glob(f'*.lproj/{nib}.xib'))
    if not copies:
        failures.append(f'no copy of {nib}.xib')
    checked = set()
    for xib in copies:
        found, unnamed = panels(xib)
        language = xib.parent.name[:-len('.lproj')]
        if unnamed:
            failures.append(f'{language} {nib}.xib: no outlet names the panels {unnamed}; nothing can take them off the screen')
        if not found:
            failures.append(f'{language} {nib}.xib: no panel found; the window had one')
        for name, holder, title, released_when_closed in found:
            if holder is not None and holder not in reached:
                failures.append(f'{language} {nib}.xib: «{title}» is a panel of a {holder}, and the test does not know how '
                                f'{Path(source).stem} reaches one')
                continue
            expression = (reached[holder] if holder else '') + name
            checked.add(expression + (' (released when closed)' if released_when_closed else ''))
            in_call = re.search(r'(^|[\s,])%s\s*(,|$)' % re.escape(expression), taken)
            closed = re.search(r'(^|[^.\w])%s\?\.close\(\)' % re.escape(expression), closing[:released if released >= 0 else None])
            if not (in_call or closed):
                failures.append(f'{language} {nib}.xib: -windowWillClose: of {Path(source).stem} leaves the panel «{title}» '
                                f'({expression}) on the screen')
            if released_when_closed and closed:
                failures.append(f'{language} {nib}.xib: -windowWillClose: of {Path(source).stem} closes «{title}» ({expression}), '
                                f'which the nib releases when closed and its owner lets go of again')
    if checked:
        print(f'{nib}: the controller takes off the screen {", ".join(sorted(checked))}')

driver = r'''
import AppKit

final class Listener: NSObject, NSWindowDelegate {
    var closing = 0
    func windowWillClose(_ notification: Notification) { closing += 1 }
}

var failures: [String] = []
func check(_ condition: Bool, _ message: @autoclosure () -> String) {
    if !condition { failures.append(message()) }
}

@MainActor func panel(_ title: String, at x: CGFloat, releasedWhenClosed: Bool = false) -> NSPanel {
    // As the nibs make them: a utility panel, not released when closed
    // unless the nib leaves it so.
    let panel = NSPanel(contentRect: NSRect(x: x, y: 200, width: 220, height: 120),
                        styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel, .hudWindow],
                        backing: .buffered, defer: false)
    panel.title = title
    panel.isReleasedWhenClosed = releasedWhenClosed
    // The test is not the active application: the panel would hide itself.
    panel.hidesOnDeactivate = false
    return panel
}

@main @MainActor struct Test {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let listener = Listener()
        let shading = panel("Shading", at: 100), point = panel("Point Info", at: 360)
        for each in [shading, point] {
            each.delegate = listener
            each.orderFront(nil)
        }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        var sheetEnded = false
        point.beginSheet(sheet) { _ in sheetEnded = true }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.6))
        check(shading.isVisible && point.isVisible, "the panels are not on the screen before the window closes")
        check(point.attachedSheet === sheet, "the sheet did not open on the panel")

        CompanionPanels.takeOffScreen(shading, nil, point)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.6))
        check(!shading.isVisible, "the Shading panel is still on the screen")
        check(!point.isVisible, "the Point Info panel is still on the screen")
        check(point.attachedSheet == nil && sheetEnded && !sheet.isVisible, "the sheet of a panel was not ended")
        check(!app.windows.contains { $0.isVisible && ($0 === shading || $0 === point || $0 === sheet) },
              "the application still lists a panel as visible")
        check(listener.closing == 0, "\(listener.closing) windows were said to close; a panel is ordered out, not closed")
        // Once more, as two closing notifications would: nothing to do, nothing raised.
        CompanionPanels.takeOffScreen(shading, point)
        CompanionPanels.takeOffScreen()

        // A panel nothing else keeps goes once it is off the screen.
        weak var gone: NSPanel?
        autoreleasepool {
            let lone = panel("Lone", at: 620)
            lone.orderFront(nil)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
            gone = lone
            CompanionPanels.takeOffScreen(lone)
        }
        for _ in 0..<5 where gone != nil { autoreleasepool { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3)) } }
        check(gone == nil, "a panel taken off the screen that nothing keeps was not released")

        // A panel made to be released when closed is not released by leaving
        // the screen: what keeps it shows it again, and it goes once.
        weak var assistant: NSPanel?
        autoreleasepool {
            let kept = panel("Path Assistant", at: 620, releasedWhenClosed: true)
            kept.delegate = listener
            assistant = kept
            for round in 1...2 {
                kept.orderFront(nil)
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
                check(kept.isVisible, "round \(round): the panel released when closed did not come back on the screen")
                CompanionPanels.takeOffScreen(kept)
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
                check(!kept.isVisible, "round \(round): the panel released when closed is still on the screen")
            }
            check(CFGetRetainCount(kept) >= 1 && assistant === kept, "the panel released when closed was let go while kept")
            kept.delegate = nil
        }
        for _ in 0..<5 where assistant != nil { autoreleasepool { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3)) } }
        check(assistant == nil, "the panel released when closed did not go with what kept it")
        check(listener.closing == 0, "\(listener.closing) windows were said to close after the panel released when closed left the screen")

        if !failures.isEmpty {
            for failure in failures { FileHandle.standardError.write("FAIL: \(failure)\n".data(using: .utf8)!) }
            exit(1)
        }
        print("the panels left the screen, the sheet ended, and nothing was told of a closing window")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='isix-companion-panels-') as folder:
    work = Path(folder)
    (work / 'Test.swift').write_text(driver)
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', str(HELPER), str(work / 'Test.swift'),
                            '-o', str(work / 'test')], capture_output=True, text=True)
    if built.returncode:
        sys.exit('FAIL: CompanionPanels does not compile with the driver\n' + built.stderr[-3000:])
    ran = subprocess.run([str(work / 'test')], capture_output=True, text=True)
    sys.stdout.write(ran.stdout)
    sys.stderr.write(ran.stderr)
    if ran.returncode:
        failures.append('the panels do not leave the screen')

if failures:
    for failure in failures:
        print('FAIL:', failure, file=sys.stderr)
    sys.exit(1)
print('PASS: the 3D MPR, the volume rendering, the surface rendering and the endoscopy take their panels off the screen when they close')
