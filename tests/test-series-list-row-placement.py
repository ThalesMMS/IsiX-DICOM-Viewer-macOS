#!/usr/bin/env python3
"""The series list across the top or the bottom shows and clicks every thumbnail.

A docked list on the top or bottom edge lays its thumbnails in one row. The
viewer's O2ViewerThumbnailsMatrix measured, drew and hit-tested its cells by
row only, so a row showed and clicked only its first cell, the study's; and
the viewer filled the cells by row, so after a rebuild the series cells of a
row stayed empty. Auto Layout sizes the matrix from its intrinsic size, which
has to follow the list when it changes length. The floating panel is a column at the side of the screen on
any edge, so its list stays a column. The real geometry of the matrix and the
real SeriesListLayout run on AppKit views; the viewer's fill and layout calls
are read from ViewerController.m.

`<git revision>` as an optional argument reads the three sources from that
revision, the negative control.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def read(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', revision + ':' + path]).decode('latin1')
    return (root / path).read_bytes().decode('latin1')


def fail(message):
    print('FAIL: ' + message, file=sys.stderr)
    sys.exit(1)


matrix = read('Horos/Sources/O2ViewerThumbnailsMatrix.swift')
geometry = matrix[matrix.index('    /// The frame of each cell'):matrix.index('    @objc(startDrag:)')]
geometry += matrix[matrix.index('    public override func cellFrame(atRow'):matrix.index('\n}\n\n/// What a thumbnail')]
layout = read('Horos/Sources/SeriesListLayout.swift')

driver = r'''
import AppKit

func check(_ value: Bool, _ message: String) {
    if !value { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

/// A thumbnail of the list: the study's cell is half as tall as a series'.
final class Cell: NSButtonCell {
    nonisolated(unsafe) static var drawn: [Int] = []
    override var cellSize: NSSize { NSSize(width: 100, height: tag == 0 ? 60 : 120) }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) { Cell.drawn.append(tag) }
}

/// The viewer's matrix, with the production geometry.
final class Matrix: NSMatrix {
GEOMETRY
}

/// SeriesListLayout's Objective-C entry points the viewer calls, looked up by
/// selector so an older SeriesListLayout still compiles.
@MainActor func classMethod<T>(_ name: String, as type: T.Type) -> T? {
    guard let method = class_getClassMethod(SeriesListLayout.self, NSSelectorFromString(name)) else { return nil }
    return unsafeBitCast(method_getImplementation(method), to: type)
}

@MainActor func layOutShown(_ m: NSMatrix, _ count: Int, _ placement: SeriesListPlacement, floating: Bool) {
    typealias F = @convention(c) (AnyObject, Selector, NSMatrix, Int, Int, Bool) -> Void
    guard let f = classMethod("layOutMatrix:count:placement:floating:", as: F.self) else {
        check(false, "the viewer can lay the list out for the floating panel"); return
    }
    f(SeriesListLayout.self, NSSelectorFromString("layOutMatrix:count:placement:floating:"), m, count, placement.rawValue, floating)
}

@MainActor func cellAt(_ m: NSMatrix, _ index: Int) -> NSCell? {
    typealias F = @convention(c) (AnyObject, Selector, NSMatrix, Int) -> Unmanaged<NSCell>?
    guard let f = classMethod("cellOfMatrix:atIndex:", as: F.self) else {
        check(false, "the viewer can fill a cell by its position in the list"); return nil
    }
    return f(SeriesListLayout.self, NSSelectorFromString("cellOfMatrix:atIndex:"), m, index)?.takeUnretainedValue()
}

@MainActor func scrollTo(_ m: NSMatrix, _ index: Int) {
    typealias F = @convention(c) (AnyObject, Selector, NSMatrix, Int) -> Void
    guard let f = classMethod("scrollMatrix:toCellAtIndex:", as: F.self) else {
        check(false, "the viewer can scroll to a cell by its position in the list"); return
    }
    f(SeriesListLayout.self, NSSelectorFromString("scrollMatrix:toCellAtIndex:"), m, index)
}

let count = 5

/// The whole list as the user sees it: every cell drawn, and a click at the
/// centre of each finds that cell.
@MainActor func checkList(_ m: Matrix, _ step: String, row: Bool) {
    for (i, cell) in m.cells.enumerated() { cell.tag = i }
    m.sizeToCells()
    let length = row ? m.frame.width : m.frame.height
    check(length >= CGFloat(count) * 99 - 40, "\(step): the matrix is as long as its \(count) thumbnails (\(length))")
    // The study's cell is shorter than a series': NSMatrix's own intrinsic
    // size, rows or columns times one cell size, is not the list's.
    check(m.intrinsicContentSize == m.frame.size,
          "\(step): Auto Layout sizes the matrix as the list (\(m.intrinsicContentSize) vs \(m.frame.size))")
    Cell.drawn = []
    m.draw(m.bounds)
    check(Cell.drawn == Array(0..<count), "\(step): every thumbnail is drawn, not only the study's (drawn \(Cell.drawn))")
    var expected = NSZeroPoint
    for i in 0..<count {
        let size = m.cells[i].cellSize
        let centre = NSPoint(x: expected.x + size.width / 2, y: expected.y + size.height / 2)
        var r = -1, c = -1
        check(m.getRow(&r, column: &c, for: centre), "\(step): a click on thumbnail \(i) finds a cell")
        check((row ? (r, c) == (0, i) : (r, c) == (i, 0)), "\(step): a click on thumbnail \(i) finds that thumbnail (row \(r), column \(c))")
        check(m.cell(atRow: r, column: c) === m.cells[i], "\(step): the cell found is thumbnail \(i)")
        check(NSPointInRect(centre, m.cellFrame(atRow: r, column: c)), "\(step): thumbnail \(i)'s frame is where it is drawn")
        check(cellAt(m, i) === m.cells[i], "\(step): the viewer fills thumbnail \(i) by its position")
        if row { expected.x += size.width + m.intercellSpacing.width } else { expected.y += size.height + m.intercellSpacing.height }
    }
    check(cellAt(m, count) == nil, "\(step): no cell past the end of the list")
    let clip = m.enclosingScrollView!.contentView
    scrollTo(m, count - 1)
    check(NSContainsRect(clip.documentVisibleRect.insetBy(dx: -1, dy: -1), m.cellFrame(atRow: row ? 0 : count - 1, column: row ? count - 1 : 0)),
          "\(step): the list scrolls to the current series")
    scrollTo(m, 0)
}

@main struct Check {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        // Shorter than the list either way, so reaching the last thumbnail scrolls.
        let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let dock = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 300))
        let image = NSView(frame: NSRect(x: 109, y: 0, width: 191, height: 300))
        split.isVertical = true
        split.addSubview(dock); split.addSubview(image)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 100, height: 600))
        dock.addSubview(scroll)
        let m = Matrix(frame: NSRect(x: 0, y: 0, width: 100, height: 600), mode: .radioModeMatrix,
                       cellClass: Cell.self, numberOfRows: 0, numberOfColumns: 0)
        m.intercellSpacing = NSSize(width: -1, height: -1)
        scroll.documentView = m

        for placement in [SeriesListPlacement.top, .bottom] {
            SeriesListLayout.place(scroll, in: split, floating: false, visible: true, thumbnailWidth: 120, placement: placement)
            // The study collapsed to its own cell, then opened again.
            SeriesListLayout.layOut(m, count: 1, placement: placement)
            SeriesListLayout.layOut(m, count: count, placement: placement)
            check(m.numberOfRows == 1 && m.numberOfColumns == count, "docked \(placement.name): one row")
            checkList(m, "docked \(placement.name)", row: true)
        }
        for placement in [SeriesListPlacement.top, .bottom] {
            SeriesListLayout.place(scroll, in: split, floating: true, visible: true, thumbnailWidth: 120, placement: placement)
            check(scroll.hasVerticalScroller && !scroll.hasHorizontalScroller, "floating \(placement.name): the panel's list scrolls down")
            // Lent to the panel, the list fills the panel's column.
            scroll.frame = NSRect(x: 0, y: 0, width: 120, height: 300)
            layOutShown(m, count, placement, floating: true)
            check(m.numberOfRows == count && m.numberOfColumns == 1, "floating \(placement.name): the panel shows a column")
            checkList(m, "floating \(placement.name)", row: false)
        }
        SeriesListLayout.place(scroll, in: split, floating: false, visible: true, thumbnailWidth: 120, placement: .bottom)
        layOutShown(m, count, .bottom, floating: false)
        check(m.numberOfRows == 1 && m.numberOfColumns == count, "docked bottom again: one row")
        checkList(m, "docked bottom again", row: true)
        SeriesListLayout.place(scroll, in: split, floating: false, visible: true, thumbnailWidth: 120, placement: .left)
        layOutShown(m, count, .left, floating: false)
        check(m.numberOfRows == count && m.numberOfColumns == 1, "docked left: one column")
        checkList(m, "docked left", row: false)
        print("PASS: docked top and bottom rows and the floating column draw and click all \(count) thumbnails")
    }
}
'''.replace('GEOMETRY', geometry)

with tempfile.TemporaryDirectory(prefix='horos-series-list-row-placement-') as folder:
    folder = Path(folder)
    (folder / 'SeriesListLayout.swift').write_text(layout)
    (folder / 'Check.swift').write_text(driver)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                    str(folder / 'SeriesListLayout.swift'), str(folder / 'Check.swift'),
                    '-o', str(folder / 'series-list-row-placement')], check=True)
    outcome = subprocess.run([str(folder / 'series-list-row-placement')])
    if outcome.returncode:
        sys.exit(outcome.returncode)

# The viewer builds the list through the same entry points: it lays the list
# out for where it is shown and fills and scrolls to cells by list position.
viewer = read('Horos/Sources/ViewerController.m')
start = viewer.index('- (void) buildMatrixPreview: (BOOL) showSelected')
build = viewer[start:viewer.index('\n- (void) buildMatrixPreview\n', start)]
code = '\n'.join(line for line in build.splitlines() if not line.lstrip().startswith('//'))
if re.search(r'\[previewMatrix\s+cellAtRow:', code) or re.search(r'\[previewMatrix\s+scrollCellToVisibleAtRow:', code):
    fail('buildMatrixPreview fills or scrolls to cells by row, which leaves a row of series empty')
if 'cellOfMatrix: previewMatrix atIndex: index' not in code:
    fail('buildMatrixPreview fills the cells by their position in the list')
if not re.search(r'layOutMatrix: previewMatrix count: i\+\[studiesArray count\]\s+placement:[^;]*floating:', code):
    fail('buildMatrixPreview lays the list out for the floating panel')
update = viewer[viewer.index('- (void) updateSeriesListMode'):]
update = update[:update.index('\n}\n')]
if 'placement: placement floating: floating]' not in update:
    fail('updateSeriesListMode lays the list out for the floating panel')
print('PASS: the viewer fills, scrolls and lays out its list by position and for the floating panel')
