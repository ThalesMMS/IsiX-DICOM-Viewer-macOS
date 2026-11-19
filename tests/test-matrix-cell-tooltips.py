#!/usr/bin/env python3
"""The cells of a matrix show the tooltips their nib gives them.

A nib keeps the tooltip of a matrix cell in a connection to the cell, which
the loader hands to the view the cell is in; a cell just read is in none, and
the tooltip was lost: the tools of the viewers and the radio buttons of the
panes never showed one. `TipMatrix` tells its cells where they are as it is
read. What is checked:

- every matrix of a nib that gives a tooltip to a cell is a `TipMatrix`, in
  the English nib and in each copy;
- a nib compiled and loaded beside `TipMatrix` answers the tooltip of each
  cell as the nib writes it, and the same nib with a plain matrix answers
  none, which is what the class is there for.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from xml.sax.saxutils import unescape

root = Path(__file__).resolve().parents[1]
CLASS = 'IsiXTipMatrix'
MATRIX = re.compile(r'<matrix\b([^>]*)>(.*?)</matrix>', re.S)
CELL_TIP = re.compile(r'<\w+Cell\b[^>]*\btoolTip="([^"]*)"')
failures = []


def matrices_with_tips(text):
    for match in MATRIX.finditer(text):
        cells = re.search(r'<cells>.*?</cells>', match.group(2), re.S)
        tips = CELL_TIP.findall(cells.group(0)) if cells else []
        if tips:
            yield match, tips


nibs = sorted(list((root / 'Preference Panes').glob('*/*.lproj/*.xib')) + list((root / 'Horos/Resources').glob('*.lproj/*.xib')))
count = cells = 0
for nib in nibs:
    for match, tips in matrices_with_tips(nib.read_text(encoding='utf-8')):
        count += 1
        cells += len(tips)
        if f'customClass="{CLASS}"' not in match.group(1):
            identifier = re.search(r'\bid="([^"]+)"', match.group(1))
            failures.append(f'{nib.relative_to(root)}: the matrix {identifier.group(1) if identifier else "?"} gives tooltips '
                            f'to {len(tips)} cells and is not a {CLASS}: they are lost when the nib loads')
if count < 100:
    sys.exit(f'the matrices with cell tooltips were not found: {count}')

MAIN = r'''
import AppKit
_ = NSApplication.shared
let nib = NSNib(nibData: try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])), bundle: nil)
var top: NSArray?
guard nib.instantiate(withOwner: nil, topLevelObjects: &top) else { fputs("the nib did not load\n", stderr); exit(1) }
var stack: [NSView] = []
for object in top ?? [] {
    if let window = object as? NSWindow, let content = window.contentView { stack.append(content) }
    if let view = object as? NSView { stack.append(view) }
}
while let view = stack.popLast() {
    stack.append(contentsOf: view.subviews)
    guard let matrix = view as? NSMatrix else { continue }
    for cell in matrix.cells { print("\(type(of: matrix))\t\(cell.title)\t\(matrix.toolTip(for: cell) ?? "")") }
}
'''
source = root / 'Preference Panes/OSICDPreferencePane/Base.lproj/OSICDPreferencePanePref.xib'
text = source.read_text(encoding='utf-8')
expected = {}
for match, _ in matrices_with_tips(text):
    for cell in re.finditer(r'<\w+Cell\b[^>]*>', re.search(r'<cells>.*?</cells>', match.group(2), re.S).group(0)):
        title = re.search(r'\btitle="([^"]*)"', cell.group(0))
        tip = re.search(r'\btoolTip="([^"]*)"', cell.group(0))
        if title and tip:
            expected[unescape(title.group(1), {'&quot;': '"'})] = unescape(tip.group(1), {'&quot;': '"'})
if len(expected) < 2:
    sys.exit(f'the cells with tooltips of the CD/DVD pane were not read: {expected}')

with tempfile.TemporaryDirectory(prefix='horos-matrix-tips-') as directory:
    path = Path(directory)
    (path / 'main.swift').write_text(MAIN)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', str(root / 'Horos/Sources/TipMatrix.swift'), str(path / 'main.swift'),
                    '-o', str(path / 'test')], check=True)

    def tips_of(name, xib_text):
        (path / f'{name}.xib').write_text(xib_text, encoding='utf-8')
        subprocess.run(['xcrun', 'ibtool', '--errors', '--compile', str(path / f'{name}.nib'), str(path / f'{name}.xib')],
                       check=True, capture_output=True)
        compiled = path / f'{name}.nib'
        if compiled.is_dir():
            compiled = compiled / 'keyedobjects.nib'
        out = subprocess.run([str(path / 'test'), str(compiled)], check=True, capture_output=True, text=True).stdout
        return {title: tip for _, title, tip in (line.split('\t') for line in out.splitlines())}

    with_class = tips_of('with', text)
    for title, tip in expected.items():
        if with_class.get(title) != tip:
            failures.append(f'the cell {title!r} answers the tooltip {with_class.get(title)!r}, and its nib gives {tip!r}')
    plain = tips_of('plain', text.replace(f' customClass="{CLASS}"', ''))
    if any(plain.get(title) for title in expected):
        print('NOTE: a plain matrix now keeps the tooltips of its cells: the class is no longer needed')

if failures:
    sys.exit('FAIL:\n' + '\n'.join(failures))
print(f'PASS: {count} matrices keep the tooltips of {cells} cells, and a loaded nib answers them')
