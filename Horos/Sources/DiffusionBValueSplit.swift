//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation

/// The b-values of a diffusion series and the images of each, so that a
/// series that stacks every b-value one after the other can be shown as one
/// viewer per b-value.
public enum DiffusionBValueSplit {

    /// The tags a b-value is read from, in the order they are tried: the
    /// standard Diffusion b-value, then the private ones of Siemens, GE and
    /// Philips, then Siemens' sequence name ("*ep_b800t").
    public static let tags = ["0018,9087", "0019,100C", "0043,1039", "2001,1003", "0018,0024"]

    /// The b-value of one image, from the values of `tags` in that order
    /// (nil where the image has none).
    public static func bValue(_ values: [Any?]) -> Double? {
        for (index, value) in values.enumerated() where index < tags.count {
            let found: Double?
            switch tags[index] {
            case "0018,0024": found = sequenceNameBValue(value)
            case "0043,1039": found = number(value).map(geBValue)
            case "2001,1003": found = number(value, floatData: true)
            default: found = number(value)
            }
            if let found, found.isFinite, found >= 0 { return found }
        }
        return nil
    }

    /// GE adds 10^9 (or a multiple of it) to the b-value in its private tag.
    static func geBValue(_ value: Double) -> Double {
        value >= 1e9 ? value.truncatingRemainder(dividingBy: 1e9) : value
    }

    /// The first number of a value: a number, a string ("800", or the first
    /// of "1000000800\8\0\0"), an array of either, or bytes read without a
    /// dictionary - text, or a little-endian float for Philips' FL tag.
    static func number(_ value: Any?, floatData: Bool = false) -> Double? {
        switch value {
        case let n as NSNumber:
            return n.doubleValue
        case let s as String:
            let first = s.split(whereSeparator: { $0 == "\\" }).first.map(String.init) ?? s
            return Double(first.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0"))))
        case let a as [Any]:
            return a.first.flatMap { number($0, floatData: floatData) }
        case let a as NSArray:
            return a.firstObject.flatMap { number($0, floatData: floatData) }
        case let d as Data:
            if floatData && d.count == 4 {
                let bits = d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
                return Double(Float(bitPattern: UInt32(littleEndian: bits)))
            }
            if floatData && d.count == 8 {
                let bits = d.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
                return Double(bitPattern: UInt64(littleEndian: bits))
            }
            return String(data: d, encoding: .ascii).flatMap { number($0) }
        default:
            return nil
        }
    }

    /// Siemens names a diffusion sequence with its b-value: "*ep_b800t",
    /// "ep_b0".
    static func sequenceNameBValue(_ value: Any?) -> Double? {
        guard let name = value as? String,
              let range = name.range(of: #"_b(\d+)"#, options: .regularExpression) else { return nil }
        return Double(name[range].dropFirst(2))
    }

    /// One b-value and the indices of its images, in the series' order.
    public struct Group: Equatable {
        public let bValue: Double?
        public let indices: [Int]
    }

    /// The images by b-value, lowest first; images without one come last.
    /// Fewer than two groups is nothing to split.
    public static func groups(_ bValues: [Double?]) -> [Group] {
        var order: [Double] = []
        var byValue: [Double: [Int]] = [:]
        var unknown: [Int] = []
        for (index, value) in bValues.enumerated() {
            guard let value else { unknown.append(index); continue }
            let key = value.rounded()
            if byValue[key] == nil { order.append(key) }
            byValue[key, default: []].append(index)
        }
        var result = order.sorted().map { Group(bValue: $0, indices: byValue[$0] ?? []) }
        if !unknown.isEmpty { result.append(Group(bValue: nil, indices: unknown)) }
        return result.count >= 2 ? result : []
    }
}
