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

/// A value kept in the preferences in a property-list form of its own. It
/// holds that form as it was read and gives typed views of it, so what is read
/// and written back stays exactly as stored, with the keys and the kinds of
/// number of whoever wrote it, also the keys this type does not know.
public protocol PropertyListRepresentable: PreferenceObject, Codable {
    /// The value of a stored property list; nil when it does not have this form.
    init?(propertyList: PropertyListValue)
    /// The property list stored for the value.
    var propertyList: PropertyListValue { get }
}

extension PropertyListRepresentable {
    public static func reading(present object: Any) -> Self? {
        guard let value = PropertyListValue(object) else { return nil }
        return Self(propertyList: value)
    }

    public var preferenceObject: Any { propertyList.object }

    public init(from decoder: Decoder) throws {
        let value = try PropertyListValue(from: decoder)
        guard let decoded = Self(propertyList: value) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "not the property-list form of \(Self.self)"))
        }
        self = decoded
    }

    public func encode(to encoder: Encoder) throws {
        try propertyList.encode(to: encoder)
    }
}

extension PropertyListValue {
    /// The value of a number as `doubleValue` of NSNumber reads it; nil for anything else.
    var numberValue: Double? {
        switch self {
        case .integer(let number): return Double(number)
        case .real(let number): return number
        case .boolean(let flag): return flag ? 1 : 0
        default: return nil
        }
    }

    /// The entries of a dictionary; nil for anything else.
    var dictionaryValue: [String: PropertyListValue]? {
        if case .dictionary(let entries) = self { return entries }
        return nil
    }

    /// The elements of an array; nil for anything else.
    var arrayValue: [PropertyListValue]? {
        if case .array(let elements) = self { return elements }
        return nil
    }

    /// The numbers of an array of numbers; nil when it is not one.
    var numbersValue: [Double]? {
        guard let elements = arrayValue else { return nil }
        var numbers: [Double] = []
        numbers.reserveCapacity(elements.count)
        for element in elements {
            guard let number = element.numberValue else { return nil }
            numbers.append(number)
        }
        return numbers
    }
}

/// A window level of the presets (`WLWW3`, by name): `[level, width]`.
public struct WindowLevelPreset: PropertyListRepresentable {
    public let propertyList: PropertyListValue

    /// A preset of single-precision numbers, as the viewers store one.
    public init(level: Float, width: Float) {
        propertyList = .array([.real(Double(level)), .real(Double(width))])
    }

    public init?(propertyList: PropertyListValue) {
        guard let numbers = propertyList.numbersValue, numbers.count >= 2 else { return nil }
        self.propertyList = propertyList
    }

    public var level: Double { propertyList.numbersValue?[0] ?? 0 }
    public var width: Double { propertyList.numbersValue?[1] ?? 0 }
}

/// A convolution kernel of the presets (`Convolution`, by name): its size, its
/// normalization and the matrix, row by row.
public struct ConvolutionPreset: PropertyListRepresentable {
    public let propertyList: PropertyListValue

    /// A kernel of `size` × `size` integers; the normalization is the sum of
    /// the matrix unless given.
    public init(size: Int, matrix: [Int], normalization: Int? = nil) {
        propertyList = .dictionary(["Size": .integer(size), "Normalization": .integer(normalization ?? matrix.reduce(0, +)),
                                    "Matrix": .array(matrix.map { .integer($0) })])
    }

    public init?(propertyList: PropertyListValue) {
        guard let entries = propertyList.dictionaryValue, entries["Size"]?.numberValue != nil,
              entries["Matrix"]?.numbersValue != nil else { return nil }
        self.propertyList = propertyList
    }

    public var size: Int { Int(propertyList.dictionaryValue?["Size"]?.numberValue ?? 0) }
    public var normalization: Int { Int(propertyList.dictionaryValue?["Normalization"]?.numberValue ?? 0) }
    public var matrix: [Int] { (propertyList.dictionaryValue?["Matrix"]?.numbersValue ?? []).map { Int($0) } }
}

/// An opacity table of the presets (`OPACITY`, by name): its points, each
/// written as NSStringFromPoint writes one.
public struct OpacityTablePreset: PropertyListRepresentable {
    public let propertyList: PropertyListValue

    public init(points: [CGPoint]) {
        propertyList = .dictionary(["Points": .array(points.map { .string(NSStringFromPoint($0)) })])
    }

    public init?(propertyList: PropertyListValue) {
        guard let entries = propertyList.dictionaryValue, entries["Points"]?.arrayValue != nil else { return nil }
        self.propertyList = propertyList
    }

    public var points: [CGPoint] {
        (propertyList.dictionaryValue?["Points"]?.arrayValue ?? []).compactMap { $0.stringValue.map(NSPointFromString) }
    }
}

/// A colour table of the presets (`CLUT`, by name): 256 levels of red, green
/// and blue, and, for the tables the editor made, its points and their colours.
public struct ColourTablePreset: PropertyListRepresentable {
    public let propertyList: PropertyListValue

    /// A table with the editor's points and colours (red, green and blue from 0 to 1).
    public init(red: [Int], green: [Int], blue: [Int], points: [Int], colours: [[Float]]) {
        func numbers(_ values: [Int]) -> PropertyListValue { .array(values.map { .integer($0) }) }
        propertyList = .dictionary(["Red": numbers(red), "Green": numbers(green), "Blue": numbers(blue), "Points": numbers(points),
                                    "Colors": .array(colours.map { colour in .array(colour.map { .real(Double($0)) }) })])
    }

    public init?(propertyList: PropertyListValue) {
        guard let entries = propertyList.dictionaryValue, entries["Red"]?.numbersValue != nil,
              entries["Green"]?.numbersValue != nil, entries["Blue"]?.numbersValue != nil else { return nil }
        self.propertyList = propertyList
    }

    public var red: [Int] { channel("Red") }
    public var green: [Int] { channel("Green") }
    public var blue: [Int] { channel("Blue") }
    /// The editor's points; empty for a table without them.
    public var points: [Int] { channel("Points") }
    /// The colour of each point; empty for a table without them.
    public var colours: [[Double]] {
        (propertyList.dictionaryValue?["Colors"]?.arrayValue ?? []).compactMap(\.numbersValue)
    }

    private func channel(_ key: String) -> [Int] {
        (propertyList.dictionaryValue?[key]?.numbersValue ?? []).map { Int($0) }
    }
}

/// A shading of the 3D viewers' menu (`shadingsPresets`, in order): its name
/// and its four parameters, each written as text.
public struct ShadingPreset: PropertyListRepresentable {
    public let propertyList: PropertyListValue

    public init(name: String, ambient: String, diffuse: String, specular: String, specularPower: String) {
        propertyList = .dictionary(["name": .string(name), "ambient": .string(ambient), "diffuse": .string(diffuse),
                                    "specular": .string(specular), "specularPower": .string(specularPower)])
    }

    public init?(propertyList: PropertyListValue) {
        guard propertyList.dictionaryValue != nil else { return nil }
        self.propertyList = propertyList
    }

    public var name: String? { text("name") }
    public var ambient: Float { number("ambient") }
    public var diffuse: Float { number("diffuse") }
    public var specular: Float { number("specular") }
    public var specularPower: Float { number("specularPower") }

    private func text(_ key: String) -> String? {
        propertyList.dictionaryValue?[key].flatMap { String.reading(present: $0.object) }
    }

    /// As `floatValue` of the text or the number.
    private func number(_ key: String) -> Float {
        Float.reading(propertyList.dictionaryValue?[key]?.object)
    }
}

extension ShadingPreset {
    /// The values the shading panel's sliders give and its fields accept: the
    /// ambient and diffuse coefficients from 0 to 1, the specular one from 0
    /// to 4 and the specular power from 0 to 50.
    public static let ranges: [(key: String, range: ClosedRange<Float>)] = [
        ("ambient", 0...1), ("diffuse", 0...1), ("specular", 0...4), ("specularPower", 0...50),
    ]

    /// The preset as the shading panel shows it: each of the four values that
    /// is outside `ranges` becomes the nearer end, in the kind it is stored in
    /// (a real, an integer or text); the rest stays as stored. A value typed
    /// before the fields had limits would be applied as it is, could make the
    /// text beside the Shading check box wider than its field, and, once the
    /// user edits its field, would be refused there, keeping the focus until
    /// it is corrected. A preset within the ranges is itself.
    public var withinRanges: ShadingPreset {
        guard var entries = propertyList.dictionaryValue else { return self }
        for (key, range) in Self.ranges {
            if let value = entries[key], let end = Self.end(of: value, outside: range) { entries[key] = end }
        }
        return Self(propertyList: .dictionary(entries)) ?? self
    }

    /// Ambient, diffuse, specular and specular power, in `ranges`' order, each
    /// brought within its range as `withinRanges` brings a stored value: the
    /// shading of a saved 3D state, applied as the panel would show it.
    public static func withinRanges(_ values: [Float]) -> [Float] {
        zip(values, ranges).map { value, entry in nearest(value, within: entry.range) }
    }

    /// The preset to store when the shading panel leaves `shown` where it was
    /// given this preset's `withinRanges`: this preset as it was read while the
    /// panel has not changed it, so the user's own values stay stored until
    /// the user edits the preset; otherwise `shown`. The panel's copy is
    /// compared by value, so an edit that leaves it as it was given (a value
    /// brought to its end and set to that end again) counts as no edit: a real
    /// stays stored beyond its range, while text, which the edited field
    /// writes back as a number, is stored as that number. Every reader brings
    /// the preset within the ranges again, so the user sees the same either way.
    public func stored(after shown: ShadingPreset) -> ShadingPreset {
        shown == withinRanges ? self : shown
    }

    /// `value`, or the end of `range` nearer to it when it is outside: the
    /// lower end for a value that is not a number. A negative zero is zero,
    /// which the text beside the Shading check box would otherwise write as
    /// «-0.00».
    static func nearest<Value: BinaryFloatingPoint>(_ value: Value, within range: ClosedRange<Float>) -> Value {
        let lower = Value(range.lowerBound), upper = Value(range.upperBound)
        if value.isNaN || value < lower { return lower }
        if value > upper { return upper }
        return value == 0 ? 0 : value
    }

    /// The stored `value` brought within `range`, in its own kind; nil when it
    /// is within already. It is compared in double precision, so a real just
    /// below zero is not rounded to a zero within the range first.
    private static func end(of value: PropertyListValue, outside range: ClosedRange<Float>) -> PropertyListValue? {
        let number = Double.reading(value.object)
        let end = nearest(number, within: range)
        if end == number && end.sign == number.sign { return nil }
        switch value {
        case .integer: return .integer(Int(end))
        case .real: return .real(end)
        default: return .string(String(format: "%g", end))
        }
    }
}

extension ShadingPreset: Equatable {
    public static func == (one: ShadingPreset, other: ShadingPreset) -> Bool { one.propertyList == other.propertyList }
}

extension ShadingPreset {
    /// The list to store when a table of the presets closes.
    ///
    /// Every 3D window has a table of its own, read when the window opens;
    /// each wrote its whole list when it closed, and the last one to close
    /// overwrote what the others had changed. A table now writes only what it
    /// did, over the list as it is stored at that moment:
    ///
    /// - a preset the table left as it read it stays as it is stored, changed
    ///   or removed by another table meanwhile or not;
    /// - one the table changed replaces the stored one it was read from; when
    ///   another table changed that one too, the stored preset of its name,
    ///   and with none of that name it is added at the end;
    /// - one the table removed goes, unless another table changed it;
    /// - one the table added is added at the end, unless the list has it;
    /// - what other tables added stays.
    ///
    /// - Parameters:
    ///   - read: the presets as the table read them.
    ///   - table: the table's rows when it closes: the index in `read` of the
    ///     preset the row was read from, nil for a row added, and the preset
    ///     to store for it.
    ///   - stored: the list as it is stored now.
    public static func merging(read: [ShadingPreset], table: [(read: Int?, preset: ShadingPreset)],
                               into stored: [ShadingPreset]) -> [ShadingPreset] {
        var result: [ShadingPreset?] = stored
        var taken = Set<Int>()
        func free(where matches: (ShadingPreset) -> Bool) -> Int? {
            stored.indices.first { !taken.contains($0) && matches(stored[$0]) }
        }
        // Where each preset read stands in the stored list, before any is replaced.
        let places: [Int?] = read.map { preset in
            let place = free { $0 == preset }
            if let place { taken.insert(place) }
            return place
        }
        var added: [ShadingPreset] = []
        for (index, preset) in read.enumerated() {
            guard let row = table.first(where: { $0.read == index }) else {
                if let place = places[index] { result[place] = nil }
                continue
            }
            guard row.preset != preset else { continue }
            if let place = places[index] {
                result[place] = row.preset
            } else if let place = free(where: { $0.name == preset.name }) {
                taken.insert(place)
                result[place] = row.preset
            } else {
                added.append(row.preset)
            }
        }
        added += table.filter { $0.read == nil || !read.indices.contains($0.read!) }.map(\.preset)
        var list = result.compactMap { $0 }
        for preset in added where !list.contains(preset) { list.append(preset) }
        return list
    }
}
