#!/usr/bin/env python3
"""The WADO sheet of Locations shows every label whole, in every language.

The sheet's labels have frames drawn for the English text, and a translation
longer than that was clipped ("Caminho WA", "Recuperar sintax" in Portuguese).
`SheetLabelColumn.fit` widens the label column to the longest label of the
sheet's language and moves the controls right by as much.

Checked here, for the ten localized nibs compiled from source with ibtool and
the three rows the pane adds at run time (labels translated from each
language's catalog, placed as `addWADORetrieveRows` places them):

* after the fit, every label is as wide as its text needs, the label column
  ends before the first control, no label overlaps a control, and every view
  is inside the sheet;
* a second fit changes nothing;
* the negative control: without the fit, the Portuguese sheet has clipped labels.

An optional directory argument receives PNG images of the fitted sheets in
Portuguese, Russian, Korean, French and English.
"""
from pathlib import Path
import json
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
out = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else None
pane = root / 'Preference Panes/OSILocationsPreferencePane'
resources = root / 'Horos/Resources'
languages = ['Base', 'ja-JP', 'ar', 'de', 'fr', 'hi', 'ko', 'pt-BR', 'ru', 'zh-Hans']
runtime_keys = ['Parallel Requests:', 'Series Order:', 'Exclude Series:']

DRIVER = r'''
import AppKit
let app = NSApplication.shared
app.appearance = NSAppearance(named: .aqua)
final class Owner: NSObject {
    override func value(forUndefinedKey key: String) -> Any? { nil }
    override func setValue(_ value: Any?, forUndefinedKey key: String) {}
}
struct Case: Decodable { let language: String; let nib: String; let labels: [String] }
let cases = try! JSONDecoder().decode([Case].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
let output = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
var failures: [String] = []
var clippedWithoutFit: [String: Int] = [:]

@MainActor func sheet(_ c: Case, owner: Owner) -> (NSWindow, NSPopUpButton) {
    var objects: NSArray?
    let nib = NSNib(nibData: try! Data(contentsOf: URL(fileURLWithPath: c.nib)), bundle: nil)
    nib.instantiate(withOwner: owner, topLevelObjects: &objects)
    for case let window as NSWindow in objects ?? [] {
        guard let content = window.contentView,
              let syntax = content.subviews.compactMap({ $0 as? NSPopUpButton }).first(where: {
                  $0.itemArray.contains { $0.title == "Explicit Little Endian" || $0.tag == 13 } }),
              content.subviews.contains(where: { ($0 as? NSTextField)?.stringValue.contains("65535") == true })
        else { continue }
        // The rows the pane adds, placed as addWADORetrieveRows places them: the
        // sheet grows by three rows, the syntax row and what is above it go up,
        // and each new label takes its own width, ending 4 points before the
        // controls.
        let row: CGFloat = 30
        let syntaxFrame = syntax.frame
        let frames = content.subviews.map { ($0, $0.frame) }
        var frame = window.frame
        frame.size.height += 3 * row
        window.setFrame(frame, display: false)
        for (view, original) in frames {
            view.frame = original.minY >= syntaxFrame.minY - 4 ? original.offsetBy(dx: 0, dy: 3 * row) : original
        }
        for (index, title) in c.labels.enumerated() {
            let y = syntaxFrame.minY + CGFloat(2 - index) * row
            let control: NSView = index == 2
                ? NSTextField(frame: NSRect(x: syntaxFrame.minX + 3, y: syntaxFrame.minY + (syntaxFrame.height - 22) / 2,
                                            width: syntaxFrame.width - 6, height: 22))
                : NSPopUpButton(frame: NSRect(x: syntaxFrame.minX, y: y, width: index == 0 ? 80 : syntaxFrame.width,
                                              height: syntaxFrame.height), pullsDown: false)
            content.addSubview(control)
            let label = NSTextField(labelWithString: title)
            label.alignment = .right
            label.sizeToFit()
            let right = syntaxFrame.minX - 4
            label.frame = NSRect(x: right - label.frame.width, y: control.frame.midY - label.frame.height / 2,
                                 width: label.frame.width, height: label.frame.height)
            content.addSubview(label)
        }
        return (window, syntax)
    }
    fatalError("no WADO sheet in \(c.nib)")
}

@MainActor func clipped(_ content: NSView) -> [String] {
    content.subviews.compactMap { view in
        guard SheetLabelColumn.isLabel(view), let label = view as? NSTextField, !label.stringValue.isEmpty else { return nil }
        let inside = label.frame.minX >= 0 && label.frame.maxX <= content.bounds.width
        return label.fittingSize.width > label.frame.width + 0.5 || !inside ? label.stringValue : nil
    }
}

MainActor.assumeIsolated {
let owner = Owner()
for c in cases {
    let (plain, _) = sheet(c, owner: owner)
    clippedWithoutFit[c.language] = clipped(plain.contentView!).count
    let (window, syntax) = sheet(c, owner: owner)
    let content = window.contentView!
    SheetLabelColumn.fit(window, controlColumn: syntax.frame.minX)
    let first = content.subviews.map { $0.frame }
    let firstSize = window.frame.size
    for label in clipped(content) { failures.append("\(c.language): clipped label \(label)") }
    let labels = content.subviews.filter { SheetLabelColumn.isLabel($0) && ($0 as! NSTextField).alignment == .right }
    let controls = content.subviews.filter { !SheetLabelColumn.isLabel($0) }
    let firstControl = controls.filter { $0.frame.maxY > 50 }.map(\.frame.minX).min() ?? 0
    for label in labels where label.frame.maxX > firstControl {
        failures.append("\(c.language): label \((label as! NSTextField).stringValue) runs into the controls")
    }
    for (index, label) in labels.enumerated() { for other in labels[(index + 1)...] where label.frame.intersects(other.frame) {
        failures.append("\(c.language): labels \((label as! NSTextField).stringValue) and \((other as! NSTextField).stringValue) overlap")
    } }
    for label in labels { for control in controls where label.frame.intersects(control.frame) {
        failures.append("\(c.language): label \((label as! NSTextField).stringValue) overlaps a control")
    } }
    for view in content.subviews where view.frame.maxX > content.bounds.width + 0.5 || view.frame.minX < 0 {
        failures.append("\(c.language): a view leaves the sheet")
    }
    SheetLabelColumn.fit(window, controlColumn: syntax.frame.minX)
    if content.subviews.map({ $0.frame }) != first || window.frame.size != firstSize {
        failures.append("\(c.language): a second fit moved the sheet")
    }
    if let output, ["Base", "pt-BR", "ru", "ko", "fr"].contains(c.language) {
        let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.windowBackgroundColor.setFill(); content.bounds.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { content.cacheDisplay(in: content.bounds, to: rep) }
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(output)/wado-sheet-\(c.language).png"))
    }
    print("\(c.language): width \(Int(content.bounds.width)), clipped before the fit: \(clippedWithoutFit[c.language]!)")
}
}
if (clippedWithoutFit["pt-BR"] ?? 0) == 0 { failures.append("negative control: Portuguese is not clipped without the fit") }
for failure in failures { print("FAIL: \(failure)") }
exit(failures.isEmpty ? 0 : 1)
'''


def catalog(language):
    path = resources / f"{'en' if language == 'Base' else language}.lproj/Localizable.strings"
    return json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)]))


with tempfile.TemporaryDirectory(prefix='horos-wado-labels-') as name:
    directory = Path(name)
    cases = []
    for language in languages:
        xib = (pane if language in ('Base', 'ja-JP') else resources) / f'{language}.lproj/OSILocationsPreferencePanePref.xib'
        nib = directory / f'{language}.nib'
        subprocess.run(['xcrun', 'ibtool', '--compile', str(nib), '--flatten', 'YES', str(xib)], check=True,
                       stdout=subprocess.DEVNULL, timeout=300)
        strings = catalog(language)
        cases.append({'language': language, 'nib': str(nib), 'labels': [strings.get(k, k) for k in runtime_keys]})
    (directory / 'cases.json').write_text(json.dumps(cases))
    (directory / 'main.swift').write_text(DRIVER)
    build = subprocess.run(['xcrun', 'swiftc', '-O', '-swift-version', '5', str(pane / 'SheetLabelColumn.swift'),
                            str(directory / 'main.swift'), '-o', str(directory / 'check')], timeout=600)
    if build.returncode:
        print('FAIL: the label column does not build with the driver')
        raise SystemExit(1)
    arguments = [str(directory / 'check'), str(directory / 'cases.json')]
    if out:
        out.mkdir(parents=True, exist_ok=True)
        arguments.append(str(out))
    result = subprocess.run(arguments, timeout=300)
    raise SystemExit(result.returncode)
