#!/usr/bin/env python3
"""Verify the unmounted-database-volume wait: which volume is watched, and that the alert survives."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
import sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
import sources
# AppController is Swift; the volume wait is ApplicationLifecycle's (ApplicationLifecycle.swift).
app=sources.class_text('AppController')
# NSPanel (N2) is Swift; the assertions read its Swift spelling.
panel=sources.source_text('NSPanel+N2')
code=[line for line in panel.splitlines() if not line.lstrip().startswith('//')]
assert not any('NSGetAlertPanel(' in line for line in code), 'the alert is built with NSGetAlertPanel again'
assert not any('autorelease' in line or 'release()' in line for line in code), 'the alert window is released again'
assert any('ModalAlertPanel.panel(' in line for line in code), 'the panel no longer comes from the Swift helper'
# The volume being waited for must survive a nil resolved path. Which volume is
# watched is DatabaseVolume.documentsVolume (IsiXStorage, its cases run by
# DatabaseVolumeTests); the launch hands it the folder the user chose and shows
# the panel of DatabaseVolumeWait.
start=app.index('    private static func waitForDatabaseVolumes(')
guard=app[start:app.index('DatabaseVolumeWait(volume:',start)]
for statement in ['DatabaseVolume.documentsVolume(resolved: dataBasePath','chosenFolder: preferences[DatabasePreferences.databaseLocationURL]',
                  '!FileManager.default.fileExists(atPath: volume)']:
    assert statement in guard, f'missing in the volume guard: {statement}'
wait=app[app.index('@MainActor struct DatabaseVolumeWait {'):]
assert 'NSPanel.alert(withTitle:' in wait[:wait.index('DatabaseVolume.step(')], 'the volume wait no longer shows the alert panel'
volume=(root/'Modules/IsiXStorage/Sources/DatabaseVolume.swift').read_text()
documents=volume[volume.index('public static func documentsVolume('):volume.index('public static func dataVolume(')]
for statement in ['if let resolved, !resolved.hasPrefix("/Volumes/") { return nil }','locationMode == 1 ? chosenFolder : nil',
                  '(resolved ?? "").isEmpty ? configured : resolved']:
    assert statement in documents, f'missing in the volume guard: {statement}'
assert 'components.count >= 3' in volume, 'the volume is no longer the first three path components'
source=r'''
import AppKit
// The code under test is the main actor's.
MainActor.assumeIsolated {
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
var window: NSWindow!
autoreleasepool {
    window = ModalAlertPanel.panel(title: "Horos Data", message: "The volume is not available.",
                                   defaultButton: "Quit", alternateButton: "Continue",
                                   icon: nil, endsSheet: false)
}
// The old helper released a window its alert still owned; the alert's dealloc then
// messaged freed memory when the pool drained. Touching it here is that test.
precondition(window.title.isEmpty || !window.title.isEmpty)
precondition(window.contentView != nil)
let buttons = window.contentView!.subviews.compactMap { $0 as? NSButton }
    + (window.contentView!.subviews.flatMap { $0.subviews }.compactMap { $0 as? NSButton })
precondition(buttons.count >= 2, "the alert must carry both buttons, found \(buttons.count)")
let tags = Set(buttons.map(\.tag))
precondition(tags.contains(ModalAlertPanel.defaultButtonResponse), "default button must answer 1")
precondition(tags.contains(ModalAlertPanel.alternateButtonResponse), "alternate button must answer 0")
let titles = Set(buttons.map(\.title))
precondition(titles.contains("Quit") && titles.contains("Continue"))
// A panel with no alternate button is still well formed.
let single = ModalAlertPanel.panel(title: "t", message: "m", defaultButton: "OK",
                                   alternateButton: nil, icon: nil, endsSheet: false)
precondition(single.contentView != nil)
autoreleasepool { }
precondition(window.contentView != nil, "the alert window must outlive the pool it was made in")
print("PASS: the alert window survives its autorelease pool, both buttons answer 1 and 0, and the volume guard reads the configured path")
}
'''
with tempfile.TemporaryDirectory(prefix='horos-volume-wait-') as tmp:
    p=Path(tmp);(p/'main.swift').write_text(source)
    subprocess.run(['xcrun','swiftc',str(root/'Horos/Sources/ModalAlertPanel.swift'),str(root/'Horos/Sources/IdentityToken.swift'),str(p/'main.swift'),'-o',str(p/'test')],check=True)
    subprocess.run([str(p/'test')],check=True)
