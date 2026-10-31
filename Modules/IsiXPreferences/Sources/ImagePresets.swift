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
