//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation
import Testing
@testable import IsiXImaging

// The colour, opacity and convolution books against what the 2D viewer did
// with the stored presets before them: the former reads and writes are copied
// below from the viewer's colour-table and convolution extensions.

private func channel(_ shift: Int) -> [Int] {
    (0..<256).map { ($0 * 3 + shift * 41) % 300 }
}

@Test func colourTableEntryIsTheFormerTableAndBlackIndex() {
    let stored: [String: Any] = ["Red": channel(0), "Green": channel(1), "Blue": channel(2), "Points": [1, 2], "Colors": ["c1"]]
    let entry = ColourTableBook.Entry(stored: stored)
    // Former: ColorLookupTable(preset:) and its darkest index.
    let former = ColorLookupTable(preset: stored as NSDictionary)!
    #expect(entry?.table == former)
    #expect(entry?.blackIndex == Int32(former.darkestIndex))

    // A channel short of 256 numbers, or not a dictionary: no table, as before.
    #expect(ColourTableBook.Entry(stored: ["Red": channel(0), "Green": Array(channel(1).prefix(200)), "Blue": channel(2)]) == nil)
    #expect(ColourTableBook.Entry(stored: ["Red": channel(0), "Green": channel(1)]) == nil)
    #expect(ColourTableBook.Entry(stored: "Ramp") == nil)
    #expect(ColourTableBook.Entry(stored: nil) == nil)
}

@Test func colourTableEditorContentAndStoredForm() {
    #expect(ColourTableBook.opensInEditor(["Red": channel(0), "Points": [] as [Any]]))
    #expect(!ColourTableBook.opensInEditor(["Red": channel(0)]))
    #expect(!ColourTableBook.opensInEditor(nil))
    let content = ColourTableBook.editorContent(of: ["Points": [3, 9], "Colors": [[0.5, 1, 0], [1, 1, 1]]])
    #expect(content.points as? [Int] == [3, 9])
    #expect(content.colours.count == 2)

    let table = ColorLookupTable(red: channel(0).map { UInt8($0 & 255) }, green: channel(1).map { UInt8($0 & 255) },
                                 blue: channel(2).map { UInt8($0 & 255) })
    let points: [Any] = [0, 128, 255], colours: [Any] = [[0.0, 0.0, 0.0], [0.25, 0.5, 1.0], [1.0, 1.0, 1.0]]
    let stored = ColourTableBook.storedForm(of: table, points: points, colours: colours) as NSDictionary
    // Former: the dictionary ColorLookupTable.preset(points:colors:) made for the user defaults.
    let former = table.preset(points: points, colors: colours)
    #expect(stored.isEqual(former))
    let plist = { (value: Any) in try! PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0) }
    #expect(plist(stored) == plist(former))
}

@Test func opacityEntryIsTheFormerPoints() {
    let stored: [String: Any] = ["Points": ["{1000, 0}", "{1100, 0.5}", "{1256, 1}"]]
    #expect(OpacityTableBook.Entry(stored: stored)?.points == OpacityTablePreset.points(of: stored as NSDictionary) as? [String])
    #expect(OpacityTableBook.Entry(stored: stored)?.givesSlicesATable == true)
    #expect(OpacityTableBook.Entry(stored: ["Points": [] as [Any]])?.givesSlicesATable == false)
    // A table without points is still a table, with no points, as before.
    #expect(OpacityTableBook.Entry(stored: [String: Any]())?.points == nil)
    #expect(OpacityTableBook.Entry(stored: nil) == nil)
    #expect((OpacityTableBook.storedForm(points: ["{1000, 0}"]) as NSDictionary).isEqual(OpacityTablePreset.preset(points: ["{1000, 0}"])))
}

/// The former -ApplyConvString: read of a stored filter.
private func formerKernel(_ aConv: NSDictionary) -> (size: Int, normalization: Float, matrix: [Float]) {
    let normalization = (aConv.object(forKey: "Normalization") as? NSNumber)?.floatValue ?? 0
    let size = (aConv.object(forKey: "Size") as? NSNumber)?.intValue ?? 0
    let array = aConv.object(forKey: "Matrix") as? NSArray
    var matrix = [Float](repeating: 0, count: max(25, size &* size))
    for i in 0..<(size * size) { matrix[i] = (array?.object(at: i) as? NSNumber)?.floatValue ?? 0 }
    return (size, normalization, matrix)
}

@Test func convolutionKernelIsTheFormerRead() {
    for stored: [String: Any] in [["Size": 3, "Normalization": 7.25, "Matrix": [0.5, 1, 0.5, 1, 2.25, 1, 0.5, 1, 0.5]],
                                  ["Size": 5, "Normalization": 16, "Matrix": (0..<25).map { $0 % 4 }],
                                  ["Size": 3, "Normalization": 0, "Matrix": [-1, -1, -1, -1, 8, -1, -1, -1, -1]]] {
        let kernel = ConvolutionKernelBook.Kernel(stored: stored)
        let former = formerKernel(stored as NSDictionary)
        #expect(kernel?.size == former.size)
        #expect(kernel?.normalization == former.normalization)
        #expect(kernel?.weights == former.matrix)
    }
    #expect(ConvolutionKernelBook.Kernel(stored: nil) == nil)
    #expect(ConvolutionKernelBook.Kernel(stored: [1, 2]) == nil)
}

@Test func convolutionStoredFormIsTheFormerEditorWrite() {
    let weights: [Float] = [0.5, 1, 0.5, 1, 2.25, 1, 0.5, 1, 0.5]
    let kernel = ConvolutionKernelBook.Kernel(size: 3, normalization: 7.25, weights: weights)
    // Former -endConv: Size from the size matrix's tag, the normalization and the weights as float numbers.
    let former = NSMutableDictionary()
    former.setObject(NSNumber(value: 3), forKey: "Size" as NSString)
    former.setObject(NSNumber(value: Float(7.25)), forKey: "Normalization" as NSString)
    former.setObject(weights.map { NSNumber(value: $0) } as NSArray, forKey: "Matrix" as NSString)
    #expect((kernel.storedForm as NSDictionary).isEqual(former))
    #expect(ConvolutionKernelBook.Kernel(stored: kernel.storedForm) == kernel)
}

/// The former loops of the editor: -getMatrix: read the cells (row y, column
/// x), x outer; the Option click wrote weight `inc` to the cell (row x, column y).
private func formerCells(size: Int, reading: Bool) -> [ConvolutionKernelBook.Cell] {
    var cells: [ConvolutionKernelBook.Cell] = []
    for x in 0..<5 {
        for y in 0..<5 {
            if size == 3 && (x < 1 || x > 3 || y < 1 || y > 3) { continue }
            if size != 3 && size != 5 { continue }
            cells.append(reading ? .init(row: y, column: x) : .init(row: x, column: y))
        }
    }
    return cells
}

@Test func editorCellsAreTheFormerOrders() {
    for size in [3, 5, 4, 0] {
        #expect(ConvolutionKernelBook.readingOrder(size: size) == formerCells(size: size, reading: true))
        #expect(ConvolutionKernelBook.writingOrder(size: size) == formerCells(size: size, reading: false))
    }
    #expect(ConvolutionKernelBook.uses(row: 0, column: 2, size: 3) == false)
    #expect(ConvolutionKernelBook.uses(row: 2, column: 2, size: 3) == true)
    #expect(ConvolutionKernelBook.uses(row: 0, column: 0, size: 5) == true)
    #expect(ConvolutionKernelBook.uses(row: 0, column: 0, size: 4) == nil)
    #expect(ConvolutionKernelBook.sum(of: ["1", "2.5", "", "x", "-0.5"]) == 3)
}
