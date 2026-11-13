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

// The ratio of two lengths: an Evans index, an Insall-Salvati or a
// Caton-Deschamps ratio are one Length divided by another. The result is a
// text ROI, the label, that follows the two Lengths: it is written again when
// one of them changes. What ties them is kept in each ROI's archive, so the
// tie is there again when the study is opened.
//
// The rules are here: what ties a label to its Lengths and how it is
// archived, which two selected Lengths a command divides and in which order,
// which Length a label means when several carry the same identifier (copies
// do), the value and its text. The viewer finds the ROIs and writes the label.

/// What ties a ratio label to the two Lengths it divides.
///
/// A Length a ratio uses carries an identifier; the label carries the
/// identifiers of its numerator and of its denominator. A Length may be in
/// several ratios: it has one identifier, and every label that uses it names it.
public enum ROIRatioLink: Equatable, Sendable {
    /// A ROI no ratio uses, and that is no ratio.
    case none
    /// A Length a ratio divides or is divided by, with its identifier.
    case measure(String)
    /// The label of a ratio, with the identifiers of its two Lengths.
    case label(numerator: String, denominator: String)

    private static let measurePrefix = "isix-measure:"
    private static let labelPrefix = "isix-ratio:"

    /// An identifier no other Length has.
    public static func newIdentifier() -> String {
        UUID().uuidString
    }

    /// Whether `text` can be an identifier: letters, digits and hyphens, so
    /// that the separator of a label's two identifiers is never part of one.
    public static func isIdentifier(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 64 && text.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 45
        }
    }

    /// The link an archive holds as `archived`; none for nil, an empty string
    /// or any text that is not one this writes.
    public init(archived: String?) {
        guard let archived, !archived.isEmpty else {
            self = .none
            return
        }
        if archived.hasPrefix(Self.measurePrefix) {
            let identifier = String(archived.dropFirst(Self.measurePrefix.count))
            self = Self.isIdentifier(identifier) ? .measure(identifier) : .none
            return
        }
        if archived.hasPrefix(Self.labelPrefix) {
            let parts = archived.dropFirst(Self.labelPrefix.count).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if parts.count == 2, Self.isIdentifier(parts[0]), Self.isIdentifier(parts[1]) {
                self = .label(numerator: parts[0], denominator: parts[1])
                return
            }
        }
        self = .none
    }

    /// The text an archive holds for the link; empty for none.
    public var archived: String {
        switch self {
        case .none: return ""
        case let .measure(identifier): return Self.measurePrefix + identifier
        case let .label(numerator, denominator): return Self.labelPrefix + numerator + "/" + denominator
        }
    }

    /// The identifier of a Length a ratio uses; nil for any other ROI.
    public var measureIdentifier: String? {
        if case let .measure(identifier) = self { return identifier }
        return nil
    }

    /// Whether the ROI is the label of a ratio.
    public var isLabel: Bool {
        if case .label = self { return true }
        return false
    }

    /// Whether the ROI is a label that divides, or is divided by, the Length `identifier`.
    public func uses(_ identifier: String) -> Bool {
        if case let .label(numerator, denominator) = self { return numerator == identifier || denominator == identifier }
        return false
    }
}

public enum ROILengthRatio {

    // MARK: - Value

    /// A measured length and what it is in.
    public struct Length: Equatable, Sendable {
        public var value: Double
        public var unit: ROICSVExport.Unit

        public init(value: Double, unit: ROICSVExport.Unit) {
            self.value = value
            self.unit = unit
        }
    }

    /// `numerator` divided by `denominator`. nil when there is no ratio to
    /// give: the two are not in the same unit (one image has a pixel spacing
    /// and the other has none), a length is not finite or is negative, or the
    /// denominator is zero.
    public static func value(of numerator: Length, over denominator: Length) -> Double? {
        guard numerator.unit == denominator.unit,
              numerator.value.isFinite, denominator.value.isFinite,
              numerator.value >= 0, denominator.value > 0 else { return nil }
        let ratio = numerator.value / denominator.value
        return ratio.isFinite ? ratio : nil
    }

    private static let posix = Locale(identifier: "en_US_POSIX")

    /// The ratio as the label writes it: two decimals, three below 0.1, with
    /// a dot as the lengths beside it have; a dash when there is none.
    public static func text(of ratio: Double?) -> String {
        guard let ratio, ratio.isFinite else { return "\u{2013}" }
        return String(format: ratio < 0.0995 ? "%.3f" : "%.2f", locale: posix, ratio)
    }

    /// The text of the label: the two lengths as their own labels write them,
    /// the numerator first, then the ratio.
    public static func labelText(numerator: String, denominator: String, ratio: Double?) -> String {
        numerator + " / " + denominator + " = " + text(of: ratio)
    }

    // MARK: - Which two Lengths

    /// A selected Length of the time point shown.
    public struct Selected: Equatable, Sendable {
        /// Whether it is on the image shown.
        public var isShown: Bool
        /// When it was selected, counted from some start: a smaller number
        /// was selected earlier. nil when that is not known.
        public var order: Int?

        public init(isShown: Bool, order: Int?) {
            self.isShown = isShown
            self.order = order
        }
    }

    /// The indices of the numerator and of the denominator among the selected
    /// Lengths `selected`, given in the order of the images and, on each, of
    /// its list; nil when they do not name exactly two.
    ///
    /// Two selected Lengths on the image shown are the pair, whatever is still
    /// selected on images that are not shown, where a selection stays until
    /// the image is shown again. Otherwise the pair is the only two selected
    /// Lengths of the series, one of them on the image shown: the other was
    /// selected on another image. Three on the image shown, or one with two
    /// elsewhere, name no pair.
    ///
    /// The Length selected first is the numerator. When that is not known for
    /// both, the first in the order given is.
    public static func pair(of selected: [Selected]) -> (numerator: Int, denominator: Int)? {
        let shown = selected.indices.filter { selected[$0].isShown }
        let chosen: [Int]
        if shown.count == 2 {
            chosen = shown
        } else if shown.count == 1 && selected.count == 2 {
            chosen = [0, 1]
        } else {
            return nil
        }
        if let first = selected[chosen[0]].order, let second = selected[chosen[1]].order, second < first {
            return (chosen[1], chosen[0])
        }
        return (chosen[0], chosen[1])
    }

    // MARK: - Which Length a label means

    /// A Length that carries an identifier, and the index of its image.
    public struct Measure: Equatable, Sendable {
        public var identifier: String
        public var slice: Int

        public init(identifier: String, slice: Int) {
            self.identifier = identifier
            self.slice = slice
        }
    }

    /// The index among `measures` of the Length `identifier` names for a
    /// label on the image `slice`; nil when none carries it.
    ///
    /// A copy of a Length carries its identifier, so several may: the one on
    /// the label's own image is meant, otherwise the one on the nearest image,
    /// the first of them in the order given. A ratio copied whole to another
    /// image, label and Lengths, then divides its own copies.
    public static func resolve(_ identifier: String, from slice: Int, among measures: [Measure]) -> Int? {
        var best: Int?
        for (index, measure) in measures.enumerated() where measure.identifier == identifier {
            guard let current = best else {
                best = index
                continue
            }
            if abs(measure.slice - slice) < abs(measures[current].slice - slice) { best = index }
        }
        return best
    }
}
