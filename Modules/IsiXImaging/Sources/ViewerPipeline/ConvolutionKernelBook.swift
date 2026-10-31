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

// The convolution filters of a 2D viewer, as the "Convolution" preference
// stores them by name: a dictionary of "Size" (3 or 5), "Normalization" and
// "Matrix", the weights. The filter editor is a 5 × 5 grid of cells, of which
// a 3 × 3 filter uses the nine in the middle. The app reads and writes the
// preference through its typed key and hands each entry over as the property
// list it is.

/// The stored convolution filters of the 2D viewers, entry by entry, and the
/// cells of their editor.
public struct ConvolutionKernelBook: Sendable {

    public static let sizeKey = "Size", normalizationKey = "Normalization", matrixKey = "Matrix"

    /// A filter as the slices take it.
    public struct Kernel: Sendable, Equatable {
        /// The side of the square of weights.
        public var size: Int
        /// The sum the weights are divided by; zero leaves them as they are.
        public var normalization: Float
        /// The weights, row by row, padded with zeros to at least 25.
        public var weights: [Float]

        public init(size: Int, normalization: Float, weights: [Float]) {
            self.size = size
            self.normalization = normalization
            self.weights = weights + [Float](repeating: 0, count: max(0, max(25, size &* size) - weights.count))
        }

        /// The filter of a stored entry; nil when it is not a dictionary. The
        /// normalization and the weights are read as -floatValue reads them,
        /// so a fractional value stays fractional, and the size as -longValue
        /// does; a missing weight is 0.
        public init?(stored: Any?) {
            guard let preset = stored as? [String: Any] else { return nil }
            let size = Self.longValue(preset[ConvolutionKernelBook.sizeKey])
            let matrix = preset[ConvolutionKernelBook.matrixKey] as? [Any] ?? []
            let count = max(0, size &* size)
            self.init(size: size, normalization: Self.floatValue(preset[ConvolutionKernelBook.normalizationKey]),
                      weights: (0..<count).map { $0 < matrix.count ? Self.floatValue(matrix[$0]) : 0 })
        }

        /// The stored form the filter editor writes: the size, the
        /// normalization and the weights the size uses, as numbers.
        public var storedForm: [String: Any] {
            [ConvolutionKernelBook.sizeKey: size,
             ConvolutionKernelBook.normalizationKey: normalization,
             ConvolutionKernelBook.matrixKey: Array(weights.prefix(max(0, size &* size)))]
        }

        private static func floatValue(_ value: Any?) -> Float {
            if let number = value as? NSNumber { return number.floatValue }
            if let text = value as? String { return (text as NSString).floatValue }
            return 0
        }

        private static func longValue(_ value: Any?) -> Int {
            if let number = value as? NSNumber { return number.intValue }
            if let text = value as? String { return (text as NSString).integerValue }
            return 0
        }
    }

    /// A cell of the editor's 5 × 5 grid.
    public struct Cell: Sendable, Equatable {
        public let row: Int
        public let column: Int

        public init(row: Int, column: Int) {
            self.row = row
            self.column = column
        }
    }

    /// The side of the editor's grid.
    public static let gridSide = 5

    /// Whether a filter of `size` uses the cell at `row`, `column`: a 3 × 3
    /// filter only the nine in the middle; nil for a size the editor does not
    /// have (only 3 and 5), whose grid is left as it is.
    public static func uses(row: Int, column: Int, size: Int) -> Bool? {
        switch size {
        case 3: return (1...3).contains(row) && (1...3).contains(column)
        case 5: return true
        default: return nil
        }
    }

    /// The cells a filter of `size` uses, in the order the editor reads its
    /// weights from them: column by column, top to bottom. Empty for a size
    /// the editor does not have.
    public static func readingOrder(size: Int) -> [Cell] {
        var cells: [Cell] = []
        for column in 0..<gridSide {
            for row in 0..<gridSide where uses(row: row, column: column, size: size) == true {
                cells.append(Cell(row: row, column: column))
            }
        }
        return cells
    }

    /// The cells the editor writes a stored filter's weights into, in the
    /// order of the weights. The editor fills them row by row, the transpose
    /// of the order it reads them in, as it always did: a filter that is not
    /// symmetric opens transposed.
    public static func writingOrder(size: Int) -> [Cell] {
        readingOrder(size: size).map { Cell(row: $0.column, column: $0.row) }
    }

    /// The sum of the 25 cells of the editor, each read as -floatValue reads
    /// its text: the normalization the "Sum" button proposes.
    public static func sum(of texts: [String]) -> Float {
        texts.reduce(0) { $0 + ($1 as NSString).floatValue }
    }
}
