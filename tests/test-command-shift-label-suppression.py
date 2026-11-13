#!/usr/bin/env python3
"""Command-Shift hides the labels of the measures only when the Viewers settings ask for it, and then in every window.

Command-Shift held once hid the labels of the ROIs in the 2D viewer, always:
a screenshot of a viewer taken with Command-Shift-4 lost its measures, and
nothing turned that off. It is a setting now, off unless the user turns it
on, and one place answers every window that draws measures.

MeasurementLabelSuppression.swift is compiled as it stands, with the real rule
of IsiXImaging and the real key of IsiXPreferences, around controlled views in
real windows and controlled preferences, and the modifiers the system reports
as held are controlled too:
  * with the setting as registered, no modifiers hide anything and nothing is
    drawn again;
  * with it on, Command-Shift (with other modifiers too) hides the labels of
    every image view of every window and the texts of every volume view, each
    drawn again once; Command or Shift alone hide nothing; released, all come
    back; a view shown later, told of the keys still held, hides too;
  * turned off while the keys are held, the labels come back at once, and
    turned on while they are held, they hide at once: no window is told again.
The views ask there and nowhere else: the modifier handler of DCMView, for
every kind of window and not only the 2D viewer's, and that of VRView. The key
is registered off, and the nib of the Viewers pane binds a checkbox to it in
each of its ten copies.
"""
from pathlib import Path
import re
import subprocess
import tempfile

import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
import harness_defaults
import isix_modules
from sources import source_path, source_text

ROOT = Path(__file__).resolve().parents[1]

DRIVER = harness_defaults.DOMAINS + r'''
import AppKit
import IsiXImaging
import IsiXPreferences
import ObjectiveC

// The application's preferences are a domain of this test only.
let suite = harnessDomainName("command-shift-label-suppression-\(getpid())")
let controlled = UserDefaults(suiteName: suite)!
enum PreferencesSource {
    enum process { static var preferences: UserDefaults { controlled } }
}
func onMainActor(_ body: @escaping @MainActor @Sendable () -> Void) {
    if Thread.isMainThread { MainActor.assumeIsolated(body) } else { DispatchQueue.main.async(execute: body) }
}

// The modifiers the system reports as held.
nonisolated(unsafe) var held: NSEvent.ModifierFlags = []
extension NSEvent { @objc class func controlled_modifierFlags() -> NSEvent.ModifierFlags { held } }
method_exchangeImplementations(class_getClassMethod(NSEvent.self, NSSelectorFromString("modifierFlags"))!,
                               class_getClassMethod(NSEvent.self, #selector(NSEvent.controlled_modifierFlags))!)

final class DCMView: NSView {
    var horos_suppress_labels = false
    var redraws = 0
    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set { if newValue { redraws += 1 }; super.needsDisplay = newValue }
    }
}
final class VRView: NSView {
    var textsHidden = false
    var redraws = 0
    /// As the view's: drawn again only when the adapter says something changed.
    func hideMeasurementTexts(_ hide: Bool) {
        if hide != textsHidden { textsHidden = hide; redraws += 1 }
    }
}

var failures: [String] = []
func check(_ condition: Bool, _ what: String) { if !condition { failures.append(what) } }

MainActor.assumeIsolated {
    _ = NSApplication.shared
    check(NSEvent.modifierFlags == held, "the modifiers held are the test's")
    // A 2D viewer with two tiles, an MPR with three planes and a volume rendering with its own view.
    var windows: [NSWindow] = []
    var images: [DCMView] = [], volumes: [VRView] = []
    func window(_ views: [NSView]) {
        let made = NSWindow(contentRect: NSMakeRect(0, 0, 300, 200), styleMask: .borderless, backing: .buffered, defer: false)
        made.isReleasedWhenClosed = false
        let split = NSView(frame: NSMakeRect(0, 0, 300, 200))
        made.contentView?.addSubview(split)
        for view in views {
            split.addSubview(view)
            if let image = view as? DCMView { images.append(image) }
            if let volume = view as? VRView { volumes.append(volume) }
        }
        windows.append(made)
    }
    window([DCMView(), DCMView()])
    window([DCMView(), DCMView(), DCMView()])
    window([VRView()])
    check(windows.allSatisfy { NSApp.windows.contains($0) }, "the windows are the application's")
    func hiddenImages() -> Int { images.filter(\.horos_suppress_labels).count }
    func hiddenVolumes() -> Int { volumes.filter(\.textsHidden).count }
    func redraws() -> Int { images.map(\.redraws).reduce(0, +) + volumes.map(\.redraws).reduce(0, +) }
    func rest() { for view in images { view.redraws = 0 }; for view in volumes { view.redraws = 0 } }
    let commandShift: NSEvent.ModifierFlags = [.command, .shift]
    rest()  // AppKit asked each view to draw when it entered its window.

    // As registered: off. No modifiers hide anything.
    check(controlled[ViewerPreferences.commandShiftHidesLabels] == false && controlled.object(forKey: "CommandShiftHidesROILabels") == nil,
          "the setting is off unless the user turns it on")
    for flags: NSEvent.ModifierFlags in [[], .shift, .command, commandShift, [.command, .shift, .option], [.command, .shift, .control]] {
        check(!MeasurementLabelSuppression.isAsked(by: flags), "off, \(flags.rawValue) does not ask to hide")
        MeasurementLabelSuppression.modifiersChanged(flags)
    }
    check(hiddenImages() == 0 && hiddenVolumes() == 0 && redraws() == 0, "off, Command-Shift hides nothing and nothing is drawn again: \(hiddenImages()), \(hiddenVolumes()), \(redraws())")

    // On: Command-Shift hides in every view of every window.
    controlled.set(true, forKey: ViewerPreferences.commandShiftHidesLabels.name)
    check(hiddenImages() == 0 && hiddenVolumes() == 0 && redraws() == 0, "turned on with no key held, nothing changes")
    for flags: NSEvent.ModifierFlags in [.shift, .command, [.shift, .option], [.command, .control]] {
        MeasurementLabelSuppression.modifiersChanged(flags)
    }
    check(hiddenImages() == 0 && hiddenVolumes() == 0 && redraws() == 0, "on, Command or Shift alone hide nothing")
    MeasurementLabelSuppression.modifiersChanged(commandShift)
    check(hiddenImages() == images.count && hiddenVolumes() == volumes.count, "on, Command-Shift hides the labels of every view of every window: \(hiddenImages()) of \(images.count), \(hiddenVolumes()) of \(volumes.count)")
    check(images.allSatisfy { $0.redraws == 1 } && volumes.allSatisfy { $0.redraws == 1 }, "each view is drawn again once")
    MeasurementLabelSuppression.modifiersChanged([.command, .shift, .option])
    check(hiddenImages() == images.count && redraws() == images.count + volumes.count, "another modifier with them changes nothing and draws nothing again")

    // A window shown while the keys are held: its view, told of them, hides too.
    let late = DCMView()
    window([late])
    late.redraws = 0
    MeasurementLabelSuppression.modifiersChanged(commandShift)
    check(late.horos_suppress_labels && late.redraws == 1 && redraws() == images.count + volumes.count, "a view shown later hides when it is told of the keys held")

    rest()
    MeasurementLabelSuppression.modifiersChanged([])
    check(hiddenImages() == 0 && hiddenVolumes() == 0 && redraws() == images.count + volumes.count, "released, every label comes back, each view drawn again once: \(redraws())")
    MeasurementLabelSuppression.modifiersChanged(.shift)
    check(redraws() == images.count + volumes.count, "and nothing is looked for while none hides")

    // The setting changes while the keys are held: it holds at once.
    held = commandShift
    MeasurementLabelSuppression.modifiersChanged(commandShift)
    check(hiddenImages() == images.count && hiddenVolumes() == volumes.count, "hidden again")
    rest()
    controlled.set(false, forKey: ViewerPreferences.commandShiftHidesLabels.name)
    check(hiddenImages() == 0 && hiddenVolumes() == 0 && redraws() == images.count + volumes.count,
          "turned off with the keys held, the labels come back at once: \(hiddenImages()), \(hiddenVolumes()), \(redraws())")
    rest()
    controlled.set(true, forKey: ViewerPreferences.commandShiftHidesLabels.name)
    check(hiddenImages() == images.count && hiddenVolumes() == volumes.count && redraws() == images.count + volumes.count,
          "turned on with the keys held, the labels hide at once: \(hiddenImages()), \(hiddenVolumes())")
    rest()
    controlled.removeObject(forKey: ViewerPreferences.commandShiftHidesLabels.name)
    check(hiddenImages() == 0 && hiddenVolumes() == 0, "back to the registered value with the keys held, the labels come back")
    held = []
    for made in windows { made.close() }
}
controlled.removePersistentDomain(forName: suite)
if !failures.isEmpty {
    for failure in failures { print("FAIL: " + failure) }
    exit(1)
}
print("PASS: off as registered, Command-Shift hides no label; on, it hides those of every view of every window while held, "
      + "and a change of the setting holds at once for the keys held")
'''

with tempfile.TemporaryDirectory(prefix='horos-label-suppression-') as directory:
    work = Path(directory)
    (work / 'main.swift').write_text(DRIVER)
    flags = isix_modules.module_flags('IsiXImaging', work / 'modules') + isix_modules.module_flags('IsiXPreferences', work / 'modules')
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', str(work / 'main.swift'), str(source_path('MeasurementLabelSuppression')),
                    *flags, '-o', str(work / 'test')], check=True)
    subprocess.run([str(work / 'test')], check=True)

# The views ask there and nowhere else.
keyboard = source_text('DCMView+Keyboard')
handler = keyboard[keyboard.index('public override dynamic func flagsChanged(with event: NSEvent?)'):]
handler = handler[:handler.index('\n    }\n')]
asked = handler.index('MeasurementLabelSuppression.modifiersChanged(event?.modifierFlags ?? [])')
assert asked < handler.index('if self.is2DViewer() == true'), 'every kind of window asks, not only the 2D viewer'
gestures = source_text('VRView+Gestures')
volume = gestures[gestures.index('public override func flagsChanged(with event: NSEvent)'):]
assert 'MeasurementLabelSuppression.modifiersChanged(event.modifierFlags)' in volume[:volume.index('\n    }\n')]
writers = {}
for path in sorted((ROOT / 'Horos/Sources').glob('*.swift')):
    text = path.read_text(encoding='utf-8', errors='replace')
    if re.search(r'horos_suppress_labels\s*=[^=]', text):
        writers[path.name] = len(re.findall(r'horos_suppress_labels\s*=[^=]', text))
    assert 'ViewInput.suppressesLabels(' not in text or path.name == 'MeasurementLabelSuppression.swift', path.name
# Its declaration in DCMView.swift, and the one place that sets it.
assert writers == {'DCMView.swift': 1, 'MeasurementLabelSuppression.swift': 1}, writers

# Registered off, and a checkbox of the Viewers pane in each copy of its nib.
assert 'PreferenceKey<Bool>("CommandShiftHidesROILabels", registered: false)' in source_text('ViewerPreferences')
nibs = [ROOT / 'Preference Panes/OSIViewerPreferencePane' / language / 'OSIViewerPreferencePanePref.xib' for language in ('Base.lproj', 'ja-JP.lproj')]
nibs += sorted((ROOT / 'Horos/Resources').glob('*.lproj/OSIViewerPreferencePanePref.xib'))
assert len(nibs) == 10, nibs
for nib in nibs:
    text = nib.read_text(encoding='utf-8')
    assert text.count('keyPath="values.CommandShiftHidesROILabels"') == 1 and text.count('id="command-shift-labels-control"') == 1, nib
