#!/usr/bin/env python3
"""The Mouse button function palettes draw as framed segments (#903).

Every viewer's tool matrix is a radio matrix of bordered square bevel buttons.
Inside a macOS 26 toolbar such a button is drawn as a glass button: the
selected tool becomes an accent circle wider than its segment and the others
lose their frame. `ToolbarPolicy.prepare` makes those cells `ToolPaletteCell`,
which frames each tool as a segment, fills the selected one with the accent
colour over the whole segment, and keeps the icon the same size in every state.
"""
import re
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
sources = [
    root / 'Horos/Sources/ToolbarPolicy.swift',
    root / 'Horos/Sources/ToolbarImage.swift',
    root / 'Horos/Sources/ToolbarMenuBridge.swift',
]
for source in sources:
    assert source.is_file(), f'missing {source}'

# The tool palette each viewer puts in its toolbar, by matrix id. They must
# stay what ToolPaletteCell.isToolPalette recognises: a radio matrix (no
# `mode` attribute) whose cells are bordered square bevel buttons with an image.
tool_matrices = {
    'Viewer.xib': ('24',),
    'MPR.xib': ('700',),
    'VR.xib': ('243',),
    'Endoscopy.xib': ('41', '59'),
    'CPR.xib': ('700',),
    'OrthogonalMPR.xib': ('62',),
    'PETCT.xib': ('39',),
}
for name, ids in tool_matrices.items():
    for language in ('en', 'ja-JP'):
        xib = root / 'Horos/Resources' / f'{language}.lproj' / name
        text = xib.read_text(encoding='latin-1')
        for matrix_id in ids:
            at = text.index(f'id="{matrix_id}"')
            start = text.rfind('<matrix ', 0, at)
            end = text.index('</matrix>', at)
            matrix = text[start:end]
            head = matrix.split('>', 1)[0]
            assert f'id="{matrix_id}"' in head, f'{xib}: {matrix_id} is not a matrix'
            assert ' mode=' not in head, f'{xib}: tool matrix {matrix_id} is no longer a radio matrix'
            spacing = re.search(r'<size key="intercellSpacing" width="([-0-9.]+)"', matrix)
            assert spacing and float(spacing.group(1)) == -2, f'{xib}: tool matrix {matrix_id} spacing changed'
            cells = re.findall(r'<buttonCell (?!key="prototype")[^>]*>', matrix)
            assert cells, f'{xib}: tool matrix {matrix_id} has no cells'
            for cell in cells:
                assert 'bezelStyle="regularSquare"' in cell and 'borderStyle="border"' in cell and ' image="' in cell, \
                    f'{xib}: tool matrix {matrix_id} has a cell ToolPaletteCell would not adopt: {cell}'

code = r'''
import AppKit
import ObjectiveC

func check(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: \(message)"); exit(1) }
}

_ = NSApplication.shared

// #903: a tool palette as the xibs build it, next to the Left/Right radios.
let images = ["WLWW", "Move", "Zoom"].map { _ in NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
    NSColor.black.setFill(); rect.fill(); return true } }
let prototype = NSButtonCell()
prototype.setButtonType(.pushOnPushOff)
let tools = NSMatrix(frame: NSRect(x: 2, y: 2, width: 92, height: 33), mode: .radioModeMatrix, prototype: prototype, numberOfRows: 1, numberOfColumns: 3)
tools.cellSize = NSSize(width: 32, height: 33)
tools.intercellSpacing = NSSize(width: -2, height: 0)
for (column, image) in images.enumerated() {
    let cell = tools.cell(atRow: 0, column: column) as! NSButtonCell
    cell.bezelStyle = .regularSquare
    cell.isBordered = true
    cell.imagePosition = .imageOnly
    cell.image = image
    cell.tag = column
}
tools.selectCell(atRow: 0, column: 1)
let radios = NSMatrix(frame: NSRect(x: 2, y: 36, width: 154, height: 18), mode: .radioModeMatrix, prototype: NSButtonCell(), numberOfRows: 1, numberOfColumns: 2)
for case let cell as NSButtonCell in radios.cells { cell.setButtonType(.radio) }
let container = NSView(frame: NSRect(x: 0, y: 0, width: 199, height: 56))
container.addSubview(tools)
container.addSubview(radios)
let toolsItem = NSToolbarItem(itemIdentifier: .init("tools"))
toolsItem.view = container
ToolbarPolicy.prepare(toolsItem)
check(tools.cells.allSatisfy { $0 is ToolPaletteCell }, "every tool becomes a segment")
check(!radios.cells.contains { $0 is ToolPaletteCell }, "the Left/Right Button radios are not a tool palette")
check((tools.cell(withTag: 1) as? NSButtonCell)?.state == .on && tools.selectedTag() == 1, "adoption keeps the selection")
ToolbarPolicy.prepare(toolsItem)
check(tools.cells.allSatisfy { object_getClass($0) == ToolPaletteCell.self }, "a second prepare leaves the palette alone")

// Segments tile: each owns 30 pt, the separator is shared, nothing overlaps.
let segments = (0..<3).map { ToolPaletteCell.segmentRect(forCellFrame: tools.cellFrame(atRow: 0, column: $0), in: tools) }
for (index, segment) in segments.enumerated() {
    check(segment.width == 30 && segment.height == 33, "segment \(index) is \(segment)")
    if index > 0 { check(segments[index - 1].maxX == segment.minX, "segments \(index - 1) and \(index) must share an edge") }
}
// The icon box does not depend on the state.
let fitted = ToolPaletteCell.imageRect(for: NSSize(width: 64, height: 64), in: segments[1].insetBy(dx: 3, dy: 3))
check(fitted.width == 24 && fitted.height == 24, "a square icon fills the inset segment, got \(fitted)")
check(abs(fitted.midX - segments[1].midX) <= 0.5 && abs(fitted.midY - segments[1].midY) <= 0.5, "the icon is centred in its segment")

// Drawn, the selection covers its segment and only its segment, in both appearances.
func pixel(_ rep: NSBitmapImageRep, _ x: CGFloat, _ y: CGFloat) -> NSColor {
    rep.colorAt(x: Int(x * CGFloat(rep.pixelsWide) / tools.bounds.width),
                y: Int(y * CGFloat(rep.pixelsHigh) / tools.bounds.height))!.usingColorSpace(.deviceRGB)!
}
func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
    abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent) + abs(a.alphaComponent - b.alphaComponent)
}
for name in [NSAppearance.Name.aqua, .darkAqua] {
    let appearance = NSAppearance(named: name)!
    tools.appearance = appearance
    var rep: NSBitmapImageRep!
    appearance.performAsCurrentDrawingAppearance {
        rep = tools.bitmapImageRepForCachingDisplay(in: tools.bounds)!
        tools.cacheDisplay(in: tools.bounds, to: rep)
    }
    // Inside the segment, between its frame and the icon (flipped matrix: y from the top).
    let selectedCorner = pixel(rep, segments[1].minX + 2.5, 2.5)
    let otherCorner = pixel(rep, segments[2].minX + 2.5, 2.5)
    check(distance(selectedCorner, otherCorner) > 0.3, "\(name.rawValue): the selected tool is not evident (\(selectedCorner) vs \(otherCorner))")
    check(distance(pixel(rep, segments[0].minX + 2.5, 2.5), otherCorner) < 0.05, "\(name.rawValue): the selection spills out of its segment")
    let separator = pixel(rep, segments[2].minX + 0.5, 16)
    check(distance(separator, pixel(rep, segments[2].minX + 2.5, 16)) > 0.1, "\(name.rawValue): tools must be framed as segments")
}

print("PASS: tool palettes drawn as segments")
'''

with tempfile.TemporaryDirectory(prefix='horos-tool-palette-') as folder:
    folder = Path(folder)
    (folder / 'main.swift').write_text(code)
    subprocess.run([
        'xcrun', 'swiftc', '-swift-version', '5',
        *[str(s) for s in sources], str(folder / 'main.swift'),
        '-framework', 'AppKit',
        '-o', str(folder / 'test'),
    ], check=True)
    subprocess.run([str(folder / 'test')], check=True)

print('PASS: Mouse button function palettes draw as framed segments')
