"""What each title of a preference pane needs, in every language of the pane.

Each variant of the pane is copied with its controls tagged by their XIB ids,
compiled with ibtool and loaded; AppKit then says, for every visible checkbox,
radio button, push button and label, the room its title needs - on one line,
or, for a label that wraps, the height it needs at its width.
"""
from pathlib import Path
import json
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
LANGUAGES = ('ar', 'de', 'fr', 'hi', 'ko', 'pt-BR', 'ru', 'zh-Hans')


def variants(xib_name):
    """{language: path} of every variant of a pane: Base and ja-JP beside its sources, the others in Horos/Resources."""
    base = next((ROOT / 'Preference Panes').glob(f'*/Base.lproj/{xib_name}'))
    panes = {'Base': base}
    if (base.parent.parent / 'ja-JP.lproj' / xib_name).exists():
        panes['ja-JP'] = base.parent.parent / 'ja-JP.lproj' / xib_name
    panes.update({language: ROOT / 'Horos/Resources' / f'{language}.lproj' / xib_name for language in LANGUAGES
                  if (ROOT / 'Horos/Resources' / f'{language}.lproj' / xib_name).exists()})
    return panes


PANES = variants('OSIListenerPreferencePanePref.xib')
TAGGED = re.compile(r'<(button|textField|popUpButton|matrix|box) ([^>]*?)id="([^"]+)"')
# Bindings set values and states, not frames; some name value transformers that only the app
# registers, and a nib whose transformer is missing does not load.
BINDING = re.compile(r'<binding [^>]*/>|<binding [^>]*[^/]>.*?</binding>', re.S)

MEASURE = r'''
import AppKit
import Foundation

final class Owner: NSObject {
    @IBOutlet @objc var mainWindow: NSWindow?
    override func value(forUndefinedKey key: String) -> Any? { nil }
    override func setValue(_ value: Any?, forUndefinedKey key: String) {}
}
func controls(in view: NSView) -> [NSControl] {
    view.subviews.compactMap { $0 as? NSControl } + view.subviews.flatMap { controls(in: $0) }
}
var results: [[String: Any]] = []
for path in CommandLine.arguments.dropFirst() {
    let language = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    let owner = Owner()
    var objects: NSArray?
    let nib = NSNib(nibData: try! Data(contentsOf: URL(fileURLWithPath: path)), bundle: nil)
    guard nib.instantiate(withOwner: owner, topLevelObjects: &objects), let content = owner.mainWindow?.contentView else {
        results.append(["language": language, "error": "the pane did not load"]); continue
    }
    // A pane laid out by constraints has its frames only after a layout pass.
    content.layoutSubtreeIfNeeded()
    func record(_ id: String, _ title: String, _ cell: NSCell, _ frame: NSRect, oneLine: Bool = false) {
        // Buttons, checkboxes and radio buttons here are one line high; only a label wraps.
        let wraps = !oneLine && cell is NSTextFieldCell && (cell.wraps || cell.lineBreakMode == .byWordWrapping || cell.lineBreakMode == .byCharWrapping)
        // A wrapped title still needs its longest word on one line.
        let wrapped = wraps ? cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: frame.width, height: 10000)) : .zero
        results.append(["language": language, "id": id, "title": title, "width": frame.width, "height": frame.height,
                        "needed": cell.cellSize.width, "wraps": wraps, "wrappedWidth": wrapped.width, "wrappedHeight": wrapped.height,
                        "button": cell is NSButtonCell])
    }
    // Two visible controls of the same view whose frames cross: a widened one runs into its neighbour.
    // A button's frame may run past its title, and a pop-up's frame holds its bezel's margin: compare what they draw.
    func drawn(_ control: NSControl) -> NSRect {
        if let button = control as? NSButton, !(control is NSPopUpButton), !button.title.isEmpty, let cell = button.cell {
            var area = control.frame
            area.size.width = min(area.width, cell.cellSize.width)
            return area
        }
        return control is NSPopUpButton ? control.frame.insetBy(dx: 3, dy: 3) : control.frame
    }
    let visible = controls(in: content).filter {
        !$0.isHiddenOrHasHiddenAncestor && $0.identifier?.rawValue.hasPrefix("pane-title:") == true
    }
    for (index, first) in visible.enumerated() {
        for second in visible[(index + 1)...] where first.superview === second.superview {
            let crossing = drawn(first).intersection(drawn(second))
            if !crossing.isNull && crossing.width > 1 && crossing.height > 1 {
                results.append(["language": language, "overlap": [String(first.identifier!.rawValue.dropFirst(11)),
                                                                String(second.identifier!.rawValue.dropFirst(11))]])
            }
        }
    }
    // A box draws its title on its top edge, inside the frame less a margin on each side.
    func boxes(in view: NSView) -> [NSBox] {
        view.subviews.compactMap { $0 as? NSBox } + view.subviews.flatMap { boxes(in: $0) }
    }
    for box in boxes(in: content) where !box.isHiddenOrHasHiddenAncestor && box.titlePosition != .noTitle && !box.title.isEmpty {
        guard let tagged = box.identifier?.rawValue, tagged.hasPrefix("pane-title:"),
              let cell = box.titleCell as? NSCell else { continue }
        let id = String(tagged.dropFirst(11))
        record(id, box.title, cell, NSRect(x: 0, y: 0, width: box.frame.width - 10, height: box.frame.height), oneLine: true)
    }
    for control in controls(in: content) where !control.isHiddenOrHasHiddenAncestor && !(control is NSPopUpButton) {
        guard let tagged = control.identifier?.rawValue, tagged.hasPrefix("pane-title:") else { continue }
        let id = String(tagged.dropFirst(11))
        if let matrix = control as? NSMatrix {
            // A matrix's radio buttons are its cells, each in a frame of the matrix's cell size.
            for row in 0..<matrix.numberOfRows {
                for column in 0..<matrix.numberOfColumns {
                    guard let item = matrix.cell(atRow: row, column: column), item.title.isEmpty == false else { continue }
                    record("\(id)/\(row).\(column)", item.title, item, matrix.cellFrame(atRow: row, column: column))
                }
            }
            continue
        }
        guard let cell = control.cell else { continue }
        var title = ""
        if let button = control as? NSButton {
            if button.imagePosition == .imageOnly { continue }  // its title is never drawn
            title = button.title
        }
        else if let field = control as? NSTextField, !field.isEditable { title = field.stringValue }
        if title.isEmpty { continue }
        record(id, title, cell, control.frame)
    }
}
print(String(data: try! JSONSerialization.data(withJSONObject: results), encoding: .utf8)!)
'''


CONTROL = re.compile(r'<(button|textField|popUpButton|matrix) [^>]*?id="([^"]+)"')


def bound_titles(xib):
    """Ids of the controls whose shown text comes from a binding: their title in the XIB is a placeholder."""
    text = xib.read_text(encoding='utf-8')
    bound = set()
    for match in CONTROL.finditer(text):
        end = text.find(f'</{match.group(1)}>', match.end())
        # A label shows its value; a button's value is its state, and it shows its title.
        names = r'value|displayPatternValue\w*' if match.group(1) == 'textField' else r'title|displayPatternTitle\w*'
        if re.search(r'<binding [^>]*name="(%s)"' % names, text[match.end():end]):
            bound.add(match.group(2))
    return bound


def hidden_by_binding(xib):
    """Ids of the controls a binding shows or hides: two of them may share a place, one at a time."""
    text = xib.read_text(encoding='utf-8')
    hidden = set()
    for match in CONTROL.finditer(text):
        end = text.find(f'</{match.group(1)}>', match.end())
        if re.search(r'<binding [^>]*name="hidden\d*"', text[match.end():end]):
            hidden.add(match.group(2))
    return hidden


def measure(panes=PANES):
    """[{language, id, title, width, height, needed, wraps, wrappedWidth, wrappedHeight}] for every titled control
    and every titled cell of a matrix (id "matrix/row.column")."""
    with tempfile.TemporaryDirectory(prefix='horos-pane-titles-') as folder:
        folder = Path(folder)
        nibs = []
        for language, xib in panes.items():
            tagged = folder / f'{language}.xib'
            text = xib.read_text(encoding='utf-8')
            text = BINDING.sub('', text)
            tagged.write_text(TAGGED.sub(lambda m: f'<{m.group(1)} {m.group(2)}id="{m.group(3)}" identifier="pane-title:{m.group(3)}"', text),
                              encoding='utf-8')
            nib = folder / f'{language}.nib'
            built = subprocess.run(['xcrun', 'ibtool', '--compile', str(nib), str(tagged)], capture_output=True, text=True)
            if built.returncode or not nib.exists():
                raise RuntimeError(f'{language}: the pane does not compile\n{built.stdout[-800:]}{built.stderr[-800:]}')
            nibs.append(str(nib))
        (folder / 'main.swift').write_text(MEASURE)
        subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(folder / 'modules'), str(folder / 'main.swift'),
                        '-o', str(folder / 'measure')], check=True, capture_output=True)
        ran = subprocess.run([str(folder / 'measure'), *nibs], capture_output=True, text=True, timeout=300, check=True)
        bound = set().union(*(bound_titles(xib) for xib in panes.values()))
        hidden = set().union(*(hidden_by_binding(xib) for xib in panes.values()))
        return [item for item in json.loads(ran.stdout)
                if ('overlap' in item and not hidden.intersection(item['overlap']))
                or ('overlap' not in item and item.get('id', '').split('/')[0] not in bound)]


def available():
    return shutil.which('xcrun') is not None


def misfits(measured):
    """What does not fit, as messages - controls that overlap, and titles: a one-line label may need 3 points more than its frame, the padding
    AppKit counts in, while a button, checkbox or radio button truncates as soon as its title needs more than its frame; a wrapped label fits
    when its lines, and its longest word, fit the frame."""
    failures = []
    for item in measured:
        if 'error' in item:
            failures.append(f'{item["language"]}: {item["error"]}')
        elif 'overlap' in item:
            failures.append(f'{item["language"]}: controls {item["overlap"][0]} and {item["overlap"][1]} overlap')
        elif item['wraps'] and item['needed'] > item['width']:
            if item['wrappedWidth'] > item['width'] + 3 or item['wrappedHeight'] > item['height'] + 0.5:
                failures.append(f'{item["language"]}: "{item["title"]}" needs {item["wrappedWidth"]:.0f} x {item["wrappedHeight"]:.0f} '
                                f'points wrapped, its frame (id {item["id"]}) has {item["width"]:.0f} x {item["height"]:.0f}')
        elif item['needed'] > item['width'] + (0.5 if item.get('button') else 3):
            failures.append(f'{item["language"]}: "{item["title"]}" needs {item["needed"]:.0f} points, '
                            f'its frame (id {item["id"]}) has {item["width"]:.0f}')
    return failures
