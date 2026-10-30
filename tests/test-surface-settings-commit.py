#!/usr/bin/env python3
"""Check production ApplySettings commits edits before rendering/persistence.

-[SRController ApplySettings:] (SRController.swift) is compiled here, as it is,
inside a stand-in controller whose sheet commits or refuses the pending edit,
and run for OK, Cancel and a refused edit, on the primary and the fusion
settings."""
from pathlib import Path
import subprocess, sys, tempfile
root = Path(__file__).resolve().parents[1]
s = (root / 'Horos/Sources/SRController.swift').read_text(encoding='utf-8')
a = s.index('    @IBAction func ApplySettings(_ sender: Any?) {')
b = s.index('\n    }\n', a) + 6
method = s[a:b].replace('@IBAction ', '')
code = r'''
import AppKit
final class App { var ended = false }
var app = App()
final class Sheet {
    var commit: () -> Bool = { true }
    var hidden = false, discarded = false
    func endEditing(for value: Any?) { discarded = true }
    func makeFirstResponder(_ value: NSResponder?) -> Bool { commit() }
    // As NSWindow (N2): the sheet is ordered out and its parent ends it.
    func orderOutAndEndSheet(returnCode: NSApplication.ModalResponse) { hidden = true; app.ended = true }
}
final class Sender: NSObject { @objc var tag = 0 }
final class Controller {
    var SRSettingsWindow: Sheet?
    var fusionSettingsWindow = false
    let settings = NSMutableDictionary(), blendingSettings = NSMutableDictionary()
    var resolution: Float = 0, firstSurface: Float = 0, secondSurface: Float = 0, firstTransparency: Float = 0
    var secondTransparency: Float = 0, decimate: Float = 0
    var smooth: Int32 = 0
    var firstColor: NSColor? = .white, secondColor: NSColor? = .systemPink
    var shouldDecimate = false, shouldSmooth = false, useFirstSurface = false, useSecondSurface = false, shouldRenderFusion = false
    var rendered: Float = -1
    func renderSurfaces() { rendered = firstSurface }
    func renderFusionSurfaces() { rendered = firstSurface }
METHOD
}
func check(_ condition: Bool, _ what: String) { if !condition { print("FAIL: \(what)"); exit(1) } }
for fusion in [false, true] {
    for mode in 0..<3 {
        app = App()
        let c = Controller()
        c.SRSettingsWindow = Sheet()
        c.settings["firstSurface"] = NSNumber(value: 300)
        c.blendingSettings["firstSurface"] = NSNumber(value: 300)
        c.fusionSettingsWindow = fusion
        c.firstSurface = 300
        var commits = 0
        c.SRSettingsWindow?.commit = { commits += 1; if mode == 2 { return false }; c.firstSurface = 50; return true }
        let button = Sender()
        button.tag = mode == 0 ? 0 : 1
        c.ApplySettings(button)
        let d = fusion ? c.blendingSettings : c.settings
        let stored = (d["firstSurface"] as? NSNumber)?.intValue
        if mode == 1 {
            check(commits == 1 && c.rendered == 50 && stored == 50, "OK commits the edit, renders and keeps it")
            check(app.ended && c.SRSettingsWindow!.hidden, "OK ends the sheet")
            check(c.shouldRenderFusion == fusion, "the fusion settings render the fused surfaces")
        } else {
            check(c.rendered == -1 && stored == 300, "nothing renders or is kept")
            check(commits == (mode == 2 ? 1 : 0), "only OK asks for the commit")
            check(app.ended == (mode == 0) && c.SRSettingsWindow!.hidden == (mode == 0), "Cancel ends the sheet; a refused edit keeps it")
            check(c.SRSettingsWindow!.discarded == (mode == 0), "Cancel discards the edit")
        }
    }
}
print("PASS: pending edit commit, cancellation, rejected validation, primary and fusion settings")
'''.replace('METHOD', method)
with tempfile.TemporaryDirectory(prefix='horos-surface-settings-') as d:
    p = Path(d)
    (p / 'main.swift').write_text(code)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', str(p / 'main.swift'), '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True)
