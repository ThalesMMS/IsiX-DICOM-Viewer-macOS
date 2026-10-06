/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Cocoa

/// Lays out the views of an N2View in rows of cells aligned in columns, each
/// column described by an N2CellDescriptor.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// `<Horos/N2ColumnLayout.h>` are those of the former class.
// Main actor, as N2Layout.
@MainActor
@available(*, deprecated)
@objc(N2ColumnLayout)
public final class N2ColumnLayout: N2Layout {
    private let columnDescriptors: [Any]?
    private var rows: [[N2CellDescriptor]] = []

    @objc(initForView:columnDescriptors:controlSize:)
    public init(forView view: N2View?, columnDescriptors: [Any]?, controlSize: NSControl.ControlSize) {
        self.columnDescriptors = columnDescriptors
        super.init(view: view, controlSize: controlSize)
    }

    @objc(initForView:controlSize:)
    public convenience init(forView view: N2View?, controlSize: NSControl.ControlSize) {
        self.init(forView: view, columnDescriptors: nil, controlSize: controlSize)
    }

    /// The inherited initializer; its rows were nil before, they are empty now.
    @objc(initWithView:controlSize:)
    public override convenience init(view: N2View?, controlSize size: NSControl.ControlSize) {
        self.init(forView: view, columnDescriptors: nil, controlSize: size)
    }

    @objc(rowAtIndex:)
    public func row(at index: UInt) -> [Any] {
        rows[Int(index)]
    }

    @objc(appendRow:) @discardableResult
    public func appendRow(_ row: [Any]) -> UInt {
        let i = UInt(rows.count)
        insertRow(row, at: i)
        return i
    }

    @objc(insertRow:atIndex:)
    public func insertRow(_ row: [Any], at index: UInt) {
        // if (_columnDescriptors)
        //     if ([line count] != [_columnDescriptors count])
        //         [NSException raise:NSGenericException format:@"The number of views in a line must match the number of columns"];
        //     else if ([_lines count] && [[_lines lastObject] count] != [line count])
        //         [NSException raise:NSGenericException format:@"The number of views in a line must match the number of views in all other lines"];

        var colNumber = 0
        var cells: [N2CellDescriptor] = []
        cells.reserveCapacity(row.count)
        for element in row {
            let cell: N2CellDescriptor
            if let cellView = element as? NSView {
                let descriptor = columnDescriptors.map { ($0[colNumber] as! N2CellDescriptor).copy() as! N2CellDescriptor }
                    ?? N2CellDescriptor.descriptor()
                cell = descriptor.withView(cellView)
            } else {
                cell = element as! N2CellDescriptor
            }
            cells.append(cell)
            colNumber += Int(cell.colSpan)
            if let cellView = cell.view {
                view?.addSubview(cellView)
            }
        }

        rows.insert(cells, at: Int(index))

        layOut()
    }

    @objc(removeRowAtIndex:)
    public func removeRow(at index: UInt) {
        for cell in rows[Int(index)] {
            cell.view?.removeFromSuperview()
        }
        rows.remove(at: Int(index))
    }

    @objc public func removeAllRows() {
        for i in stride(from: rows.count - 1, through: 0, by: -1) {
            removeRow(at: UInt(i))
        }
    }

    /// Column widths, as NSNumber floats, and the cell sizes of each row, as
    /// NSValue sizes; nil without rows.
    @objc(computeSizesForWidth:)
    public func computeSizes(forWidth widthWithMarginAndSeparations: CGFloat) -> [Any]? {
        let rowsCount = rows.count
        let colsCount = columnDescriptors?.count ?? 0

        if rowsCount == 0 {
            return nil
        }

        let sep = separation

        // widths[span-1][from] constrains the cells that span `span` columns
        // from the column `from`.
        var widths = Array(repeating: Array(repeating: ConstrainedFloat(value: 0, constraint: makeMinMax()),
                                            count: colsCount),
                           count: colsCount)
        for row in rows {
            var colNumber = 0
            for cell in row {
                let span = Int(cell.colSpan)

                widths[span-1][colNumber].constraint = composeMinMax(widths[span-1][colNumber].constraint, cell.widthConstraints)
                widths[span-1][colNumber].value = max(widths[span-1][colNumber].value, cell.optimalSize().width)

                colNumber += span
            }
        }

        let widthWithSeparations = widthWithMarginAndSeparations - margin.size.width

        if !forcesSuperviewWidth && widthWithMarginAndSeparations != CGFloat.greatestFiniteMagnitude {
            widths[colsCount-1][0].constraint = N2MinMax(min: widthWithSeparations, max: widthWithSeparations)
            widths[colsCount-1][0].value = widthWithSeparations
        }

        for span in stride(from: 1, through: colsCount, by: 1) {
            for from in 0...(colsCount-span) where widths[span-1][from].value != 0 {
                while true {
                    // targetWidth is the sum of span 1 widths
                    var targetWidth = ConstrainedFloat(value: -sep.width, constraint: N2MinMax(min: -sep.width, max: -sep.width))
                    for i in from..<from+span {
                        targetWidth.value += widths[0][i].value + sep.width
                        targetWidth.constraint = addMinMax(addMinMax(targetWidth.constraint, widths[0][i].constraint), sep.width)
                    }

                    let currentWidth = targetWidth.value

                    targetWidth.value = max(widths[span-1][from].value, targetWidth.value)
                    targetWidth.constraint = composeMinMax(widths[span-1][from].constraint, targetWidth.constraint)
                    targetWidth.value = constrainedValue(targetWidth.constraint, targetWidth.value)
                    widths[span-1][from] = targetWidth

                    if span == 1 { break }

                    if (currentWidth+0.5).rounded(.down) == (targetWidth.value+0.5).rounded(.down) || targetWidth.value <= 0 {
                        break
                    }

                    let deltaWidth = targetWidth.value-currentWidth // if (deltaWidth > 0) increase
                    if deltaWidth*deltaWidth < 0.7 {
                        break
                    }

                    var colFixed = [Bool](repeating: false, count: colsCount)
                    var unfixedColsCount = 0
                    var unfixedRefWidth: CGFloat = 0, unfixedInvasivity: CGFloat = 0
                    for i in from..<from+span {
                        let width = widths[0][i]
                        colFixed[i] = !((deltaWidth > 0 && width.value < width.constraint.max) || (deltaWidth < 0 && width.value > width.constraint.min))
                        if !colFixed[i] {
                            unfixedColsCount += 1
                            unfixedRefWidth += width.value
                            unfixedInvasivity += invasivity(ofColumn: i)
                        }
                    }

                    if unfixedColsCount == 0 || unfixedRefWidth < 1 {
                        break
                    }

                    for i in from..<from+span where !colFixed[i] {
                        if unfixedInvasivity == 0 {
                            widths[0][i].value *= 1+deltaWidth/unfixedRefWidth
                        } else {
                            widths[0][i].value += deltaWidth*(invasivity(ofColumn: i)/unfixedInvasivity)
                        }
                    }
                }
            }
        }

        // get cell sizes and row heights
        var sizes = Array(repeating: Array(repeating: NSSize.zero, count: colsCount), count: rowsCount)
        for r in 0..<rowsCount {
            let row = rows[r]
            var colNumber = 0
            var rowHeight: CGFloat = 0
            for cell in row {
                let span = Int(cell.colSpan)

                var spannedWidth = -sep.width
                for i in colNumber..<colNumber+span {
                    spannedWidth += widths[0][i].value + sep.width
                }

                sizes[r][colNumber] = cell.filled
                    ? NSSize(width: spannedWidth, height: cell.optimalSize(forWidth: spannedWidth+cell.sizeAdjust().size.width).height)
                    : cell.optimalSize(forWidth: spannedWidth+cell.sizeAdjust().size.width)
                rowHeight = max(rowHeight, sizes[r][colNumber].height)

                colNumber += span
            }
            colNumber = 0
            for cell in row {
                let span = Int(cell.colSpan)
                if cell.filled {
                    sizes[r][colNumber].height = rowHeight
                }
                colNumber += span
            }
        }

        let resultSizes: [[NSValue]] = sizes.map { rowSizes in rowSizes.map { NSValue(size: $0) } }
        // Stored as float, and so rounded, as before.
        let resultColWidths: [NSNumber] = (0..<colsCount).map { NSNumber(value: Float(widths[0][$0].value)) }
        return [resultColWidths, resultSizes]
    }

    @objc(computeSizesForSize:)
    public func computeSizes(for sizeWithMarginAndSeparations: NSSize) -> [Any]? {
        var size = optimalSize(forWidth: sizeWithMarginAndSeparations.width)
        if !forcesSuperviewHeight && size.height > sizeWithMarginAndSeparations.height {
            var step = max(saturatingUInt(size.width/10), 1)
            size.width += CGFloat(step)
            repeat { // "decrease width until its height fits the height"
                size.width -= CGFloat(step)
                size = optimalSize(forWidth: size.width)
                if size.height <= sizeWithMarginAndSeparations.height && step > 1 {
                    size.width += CGFloat(step)
                    step = max(step/10, 1)
                    size.height = sizeWithMarginAndSeparations.height+1
                }
            } while size.height > sizeWithMarginAndSeparations.height && size.width > 20
        }

        return computeSizes(forWidth: size.width)
    }

    public override func layOutImpl() {
        let rowsCount = rows.count
        let colsCount = columnDescriptors?.count ?? 0

        let size = view?.frame.size ?? .zero

        let computed = unpack(computeSizes(for: size), rowsCount: rowsCount, colsCount: colsCount)
        let colWidth = computed.colWidths, sizes = computed.sizes, rowHeights = computed.rowHeights
        let sep = separation

        // apply computed column widths

        var y = margin.origin.y
        let x0 = margin.origin.x

        var maxX: CGFloat = 0
        for r in stride(from: rowsCount-1, through: 0, by: -1) {
            let row = rows[r]

            var x = x0
            var colNumber = 0
            for cell in row {
                let span = Int(cell.colSpan)
                var spannedWidth = -sep.width
                for i in colNumber..<colNumber+span {
                    spannedWidth += colWidth[i]+sep.width
                }

                var origin = NSPoint(x: x, y: y)
                var cellSize = sizes[r][colNumber]

                if cell.filled {
                    cellSize.width = spannedWidth
                }
                cellSize = NSSize(width: cellSize.width.rounded(.up), height: cellSize.height.rounded(.up))

                let extraSpace = NSSize(width: spannedWidth-cellSize.width, height: rowHeights[r]-cellSize.height)
                let alignment = cell.alignment
                if alignment&N2Top != 0 {
                    origin.y += extraSpace.height
                } else if alignment&N2Bottom != 0 {
                    origin.y += 0
                } else {
                    origin.y += extraSpace.height/2
                }
                if alignment&N2Right != 0 {
                    origin.x += extraSpace.width
                } else if alignment&N2Left != 0 {
                    origin.x += 0
                } else {
                    origin.x += extraSpace.width/2
                }

                if let cellView = cell.view {
                    let sizeAdjust = cellView.sizeAdjust()
                    cellView.frame = NSRect(x: origin.x+sizeAdjust.origin.x, y: origin.y+sizeAdjust.origin.y,
                                            width: cellSize.width+sizeAdjust.size.width, height: cellSize.height+sizeAdjust.size.height)
                }

                x += spannedWidth+sep.width
                colNumber += span
            }
            x += margin.size.width-margin.origin.x - sep.width

            maxX = max(maxX, x)
            y += rowHeights[r]+sep.height
        }
        y += margin.size.height-margin.origin.y - sep.height

        var bounds = view?.frame ?? .zero
        if !forcesSuperviewWidth {
            bounds.origin.x = -(bounds.size.width-maxX)/2
        }
        if !forcesSuperviewHeight {
            bounds.origin.y = -(bounds.size.height-y)/2
        }
        view?.bounds = bounds

        // superview size
        if forcesSuperviewWidth || forcesSuperviewHeight {
            // compute
            var newSize = size
            if forcesSuperviewWidth {
                newSize.width = maxX
            }
            if forcesSuperviewHeight {
                newSize.height = y
            }
            // apply
            if let view, let window = view.window, view === window.contentView {
                var frame = window.frame
                let oldFrameSize = frame.size
                frame.size = window.frameRect(forContentRect: NSRect(origin: .zero, size: newSize)).size
                frame.origin = NSPoint(x: frame.origin.x-(frame.size.width-oldFrameSize.width),
                                       y: frame.origin.y-(frame.size.height-oldFrameSize.height))
                window.setFrame(frame, display: true)
            } else {
                view?.setFrameSize(newSize)
            }
        }
    }

    public override func optimalSize(forWidth width: CGFloat) -> NSSize {
        if !enabled { return view?.frame.size ?? .zero }

        let rowsCount = rows.count
        let colsCount = columnDescriptors?.count ?? 0

        var widthWithMarginAndBorder = width
        if forcesSuperviewWidth && widthWithMarginAndBorder != CGFloat.greatestFiniteMagnitude {
            let optimalSize = self.optimalSize()
            widthWithMarginAndBorder = optimalSize.width
            if forcesSuperviewHeight {
                return optimalSize
            }
        }

        let computed = unpack(computeSizes(forWidth: widthWithMarginAndBorder), rowsCount: rowsCount, colsCount: colsCount)
        let colWidth = computed.colWidths, rowHeights = computed.rowHeights
        let sep = separation

        // sum up sizes

        var y = margin.origin.y
        var maxX: CGFloat = 0
        for r in stride(from: rowsCount-1, through: 0, by: -1) {
            let row = rows[r]

            var x = margin.origin.x
            var colNumber = 0
            for cell in row {
                let span = Int(cell.colSpan)
                var spannedWidth = -sep.width
                for i in colNumber..<colNumber+span {
                    spannedWidth += colWidth[i]+sep.width
                }

                x += spannedWidth+sep.width
                colNumber += span
            }
            x += margin.size.width-margin.origin.x - sep.width

            maxX = max(maxX, x)
            y += rowHeights[r]+sep.height
        }
        y += margin.size.height-margin.origin.y - sep.height

        return NSSize(width: maxX.rounded(.up), height: y.rounded(.up))
    }

    public override func optimalSize() -> NSSize {
        optimalSize(forWidth: CGFloat.greatestFiniteMagnitude)
    }

    // MARK: Deprecated

    @available(*, deprecated)
    @objc(lineAtIndex:)
    public func line(at index: UInt) -> [Any] {
        row(at: index)
    }

    @available(*, deprecated)
    @objc(appendLine:) @discardableResult
    public func appendLine(_ line: [Any]) -> UInt {
        appendRow(line)
    }

    @available(*, deprecated)
    @objc(insertLine:atIndex:)
    public func insertLine(_ line: [Any], at index: UInt) {
        insertRow(line, at: index)
    }

    @available(*, deprecated)
    @objc(removeLineAtIndex:)
    public func removeLine(at index: UInt) {
        removeRow(at: index)
    }

    @available(*, deprecated)
    @objc public func removeAllLines() {
        removeAllRows()
    }

    // MARK: Private

    private func invasivity(ofColumn i: Int) -> CGFloat {
        (columnDescriptors![i] as! N2CellDescriptor).invasivity
    }

    /// Reads back what -computeSizesForWidth: returned: the column widths, the
    /// cell sizes and the height of each row. Without rows (nil) the widths are
    /// zero, as the messages to nil gave before.
    private func unpack(_ sizesData: [Any]?, rowsCount: Int, colsCount: Int)
        -> (colWidths: [CGFloat], sizes: [[NSSize]], rowHeights: [CGFloat]) {
        let colWidthNumbers = sizesData.map { $0[0] as! [NSNumber] }
        let colWidths = (0..<colsCount).map { CGFloat(colWidthNumbers?[$0].floatValue ?? 0) }

        var sizes = Array(repeating: Array(repeating: NSSize.zero, count: colsCount), count: rowsCount)
        var rowHeights = [CGFloat](repeating: 0, count: rowsCount)
        if let sizesData {
            let rowSizes = sizesData[1] as! [[NSValue]]
            for r in 0..<rowsCount {
                for i in 0..<colsCount {
                    sizes[r][i] = rowSizes[r][i].sizeValue
                    rowHeights[r] = max(rowHeights[r], sizes[r][i].height)
                }
            }
        }
        return (colWidths, sizes, rowHeights)
    }
}

private struct ConstrainedFloat {
    var value: CGFloat
    var constraint: N2MinMax
}

// The N2MinMax functions and operators of N2MinMax.mm are C++, which Swift
// cannot call; these do the same arithmetic.

/// N2MakeMinMax()
private func makeMinMax() -> N2MinMax {
    N2MinMax(min: N2NoMin, max: N2NoMax)
}

/// N2ComposeMinMax
private func composeMinMax(_ mm1: N2MinMax, _ mm2: N2MinMax) -> N2MinMax {
    N2MinMax(min: max(mm1.min, mm2.min), max: min(mm1.max, mm2.max))
}

/// N2MinMaxConstrainedValue
private func constrainedValue(_ mm: N2MinMax, _ value: CGFloat) -> CGFloat {
    var val = value
    if val < mm.min { val = mm.min }
    if val > mm.max { val = mm.max }
    return val
}

/// N2InfinityAwareSum: CGFLOAT_MAX and CGFLOAT_MIN absorb the other term.
private func infinityAwareSum(_ f1: CGFloat, _ f2: CGFloat) -> CGFloat {
    if f1 == CGFloat.greatestFiniteMagnitude || f2 == CGFloat.greatestFiniteMagnitude { return CGFloat.greatestFiniteMagnitude }
    if f1 == CGFloat.leastNormalMagnitude || f2 == CGFloat.leastNormalMagnitude { return CGFloat.leastNormalMagnitude }
    return f1+f2
}

/// operator+(const N2MinMax&, const N2MinMax&)
private func addMinMax(_ mm1: N2MinMax, _ mm2: N2MinMax) -> N2MinMax {
    N2MinMax(min: infinityAwareSum(mm1.min, mm2.min), max: infinityAwareSum(mm1.max, mm2.max))
}

/// operator+(const N2MinMax&, const CGFloat&)
private func addMinMax(_ mm: N2MinMax, _ f: CGFloat) -> N2MinMax {
    N2MinMax(min: infinityAwareSum(mm.min, f), max: infinityAwareSum(mm.max, f))
}

/// The former `NSUInteger(value)` conversion, as arm64 performs it: NaN and
/// negative values give 0, values past the top give the top.
private func saturatingUInt(_ value: CGFloat) -> UInt {
    if !(value > 0) { return 0 }
    if value >= CGFloat(UInt.max) { return UInt.max }
    return UInt(value)
}
