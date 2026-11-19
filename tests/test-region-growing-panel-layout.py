#!/usr/bin/env python3
"""The region growing panel shows every control whole and apart, in every language.

The Results box of the panel holds four checkboxes, the two choices of what a
result becomes and the options of each choice. Its constraints placed the
choices under the second checkbox and their options under the fourth, in a box
of a fixed height: the fourth checkbox was drawn over the first choice and the
name of the ROI over the second. The form of the parameters had no size of its
own and was placed by its frame, against the constraint of its leading edge,
which AppKit broke and reported each time the panel opened.

Checked here, for the nine copies of the nib compiled from source with ibtool
and for the English nib with its texts read from the Spanish, Italian and
Japanese catalogs (which have no copy), with the form at one field and at
three, the least and the most an algorithm has:

* no control overlaps another, none leaves the panel, and no title is cut;
* nothing in the panel has an ambiguous layout, and AppKit reports no
  constraint it could not satisfy;
* the form's height comes from the constraint of the nib, which the controller
  sets for the fields of the algorithm, and the panel is as high with one
  field as with three;
* the controller keeps the form under its constraints when the nib gives it a
  height;
* the check of overlaps itself reports two controls put one over the other.

An optional directory argument receives a PNG image of the panel in each language.
"""
from pathlib import Path
import json
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
out = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else None
resources = root / 'Horos/Resources'
COPIES = ['en', 'ar', 'de', 'fr', 'hi', 'ko', 'pt-BR', 'ru', 'zh-Hans']
# Languages without a copy of the nib: the English nib, its texts read from the catalog.
CATALOG_LANGUAGES = ['es', 'it-IT', 'ja-JP']

controller = (root / 'Horos/Sources/ITKSegmentation3DController+Algorithms.swift').read_text()
assert 'let height = params.heightConstraint' in controller, 'the controller does not read the height the nib gives the form'
assert 'if height == nil { params.translatesAutoresizingMaskIntoConstraints = true }' in controller, \
    'the controller takes the form out of its constraints in a nib that gives it a height'
assert 'height.constant = params.heightOfRows' in controller, 'the height of the form does not follow its fields'

DRIVER = r'''
import AppKit
let app = NSApplication.shared
app.appearance = NSAppearance(named: .aqua)
final class Owner: NSObject {
    @objc var params: HorosFormView?
    @objc var dataVolumic: Bool { true }
    override func value(forUndefinedKey key: String) -> Any? { nil }
    override func setValue(_ value: Any?, forUndefinedKey key: String) {}
    @objc func preview(_ sender: Any?) {}
}
struct Case: Decodable { let language: String; let nib: String; let catalog: [String: String]? }
let cases = try! JSONDecoder().decode([Case].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
let output = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
var failures: [String] = []

@MainActor func name(_ view: NSView) -> String {
    if let button = view as? NSButton { return button.title }
    if let field = view as? NSTextField { return field.stringValue }
    return String(describing: type(of: view))
}

/// The controls of the panel with their frames in the content view. A matrix
/// gives one entry for each cell, of the size the cell draws.
@MainActor func controls(of content: NSView, language: String) -> [(String, NSRect)] {
    var found: [(String, NSRect)] = []
    func walk(_ view: NSView) {
        if view.hasAmbiguousLayout { failures.append("\(language): the layout of \(name(view)) is ambiguous") }
        if let matrix = view as? NSMatrix {
            for row in 0 ..< matrix.numberOfRows { for column in 0 ..< matrix.numberOfColumns {
                guard let cell = matrix.cell(atRow: row, column: column) else { continue }
                let frame = matrix.cellFrame(atRow: row, column: column)
                var drawn = frame
                if let button = cell as? NSButtonCell {
                    let size = button.cellSize(forBounds: frame)
                    if size.width > frame.width + 0.5 { failures.append("\(language): the title \(cell.title) is cut") }
                    drawn = NSRect(x: frame.minX, y: frame.midY - size.height / 2, width: min(frame.width, size.width), height: size.height)
                }
                found.append((cell.title.isEmpty ? "a cell" : cell.title, matrix.convert(drawn, to: content)))
            } }
            return
        }
        if view is HorosFormView || view is NSControl {
            if let control = view as? NSControl, !name(view).isEmpty,
               control is NSButton || (control as? NSTextField)?.isEditable == false,
               let needed = control.cell?.cellSize.width, needed > view.frame.width + 0.5 {
                failures.append("\(language): the title \(name(view)) is cut: \(Int(view.frame.width)) points of \(Int(needed))")
            }
            found.append((name(view), view.convert(view.bounds, to: content)))
            return
        }
        view.subviews.forEach(walk)
    }
    walk(content)
    return found
}

func overlaps(_ list: [(String, NSRect)]) -> [String] {
    var result: [String] = []
    for (index, first) in list.enumerated() { for second in list[(index + 1)...] {
        let common = first.1.intersection(second.1)
        if common.width > 1.5 && common.height > 1.5 { result.append("\(first.0) and \(second.0) overlap") }
    } }
    return result
}

@MainActor func panel(_ c: Case, fields: Int) -> (NSWindow, [(String, NSRect)]) {
    let owner = Owner()
    var objects: NSArray?
    let nib = NSNib(nibData: try! Data(contentsOf: URL(fileURLWithPath: c.nib)), bundle: nil)
    nib.instantiate(withOwner: owner, topLevelObjects: &objects)
    if let catalog = c.catalog { CatalogTranslation.translate(Array(objects ?? []), with: { catalog[$0] ?? $0 }) }
    let window = (objects as! [Any]).compactMap { $0 as? NSWindow }.first!
    objc_setAssociatedObject(window, "owner", owner, .OBJC_ASSOCIATION_RETAIN)
    guard let form = owner.params, let height = form.heightConstraint else {
        failures.append("\(c.language): the nib gives the form of the parameters no height")
        return (window, [])
    }
    // As setNumberOfParameters does for a nib that gives the form a height.
    while form.numberOfRows != 0 { form.removeRow(0) }
    while form.numberOfRows != fields { form.addRow() }
    height.constant = form.heightOfRows
    window.layoutIfNeeded()
    let content = window.contentView!
    let found = controls(of: content, language: c.language)
    for overlap in overlaps(found) { failures.append("\(c.language), \(fields) fields: \(overlap)") }
    for (title, frame) in found where !content.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame) {
        failures.append("\(c.language), \(fields) fields: \(title) leaves the panel")
    }
    return (window, found)
}

MainActor.assumeIsolated {
for c in cases {
    let (one, _) = panel(c, fields: 1)
    let (three, found) = panel(c, fields: 3)
    if one.frame.size != three.frame.size { failures.append("\(c.language): the panel changes size with the fields of the algorithm") }
    if c.language == "en" {
        // The check itself: the first two controls, one put over the other.
        var moved = Array(found.prefix(2))
        if moved.count == 2 { moved[1].1 = moved[0].1 }
        if overlaps(moved).isEmpty { failures.append("the check of overlaps reports nothing for two controls at one place") }
    }
    if let output, let content = three.contentView {
        let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.windowBackgroundColor.setFill(); content.bounds.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { content.cacheDisplay(in: content.bounds, to: rep) }
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(output)/region-growing-\(c.language).png"))
    }
    print("\(c.language): \(Int(three.contentView!.bounds.width)) x \(Int(three.contentView!.bounds.height)), \(found.count) controls")
}
}
for failure in failures { print("FAIL: \(failure)") }
exit(failures.isEmpty ? 0 : 1)
'''

with tempfile.TemporaryDirectory(prefix='horos-region-growing-') as name:
    directory = Path(name)
    cases = []
    for language in COPIES + CATALOG_LANGUAGES:
        copy = 'en' if language in CATALOG_LANGUAGES else language
        nib = directory / f'{copy}.nib'
        if not nib.exists():
            subprocess.run(['xcrun', 'ibtool', '--compile', str(nib), '--flatten', 'YES',
                            str(resources / f'{copy}.lproj/ITKSegmentation.xib')], check=True,
                           stdout=subprocess.DEVNULL, timeout=300)
        catalog = None
        if language in CATALOG_LANGUAGES:
            catalog = json.loads(subprocess.check_output(
                ['plutil', '-convert', 'json', '-o', '-', str(resources / f'{language}.lproj/Localizable.strings')]))
        cases.append({'language': language, 'nib': str(nib), 'catalog': catalog})
    (directory / 'cases.json').write_text(json.dumps(cases))
    (directory / 'main.swift').write_text(DRIVER)
    build = subprocess.run(['xcrun', 'swiftc', '-O', '-swift-version', '5', str(root / 'Horos/Sources/HorosModernControls.swift'),
                            str(root / 'Preference Panes/PaneCatalogTranslation.swift'),
                            str(directory / 'main.swift'), '-o', str(directory / 'check')], timeout=600)
    if build.returncode:
        print('FAIL: the form of the parameters does not build with the driver')
        raise SystemExit(1)
    arguments = [str(directory / 'check'), str(directory / 'cases.json')]
    if out:
        out.mkdir(parents=True, exist_ok=True)
        arguments.append(str(out))
    result = subprocess.run(arguments, capture_output=True, text=True, timeout=300)
    sys.stdout.write(result.stdout)
    conflicts = result.stderr.count('Unable to simultaneously satisfy constraints')
    if conflicts:
        print(f'FAIL: AppKit reports {conflicts} sets of constraints it could not satisfy')
        sys.stdout.write(result.stderr[:4000])
    raise SystemExit(1 if result.returncode or conflicts else 0)
