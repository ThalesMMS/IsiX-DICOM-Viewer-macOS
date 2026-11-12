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

/// An autorouting rule: one entry of the `AUTOROUTINGDICTIONARY` preference.
///
/// The entry is kept whole, every key with the value and the kind it was
/// stored with: the routing preference pane writes some numbers as text
/// ("20", "0") and others as numbers, older rules lack keys newer ones have,
/// and the database window hands a rule back as it found it. The typed
/// properties read the keys the way the routing has always read them, with
/// `-intValue`, `-integerValue` and `-boolValue`, and the defaults it gave a
/// missing key.
public struct RoutingRule: Sendable, Hashable {
    /// The preference that holds the rules, in their order.
    public static let preferenceKey = "AUTOROUTINGDICTIONARY"
    /// Whether the rules are applied to what is imported.
    public static let activatedPreferenceKey = "AUTOROUTINGACTIVATED"

    /// The keys of a stored rule.
    public enum Key {
        public static let name = "name"
        public static let description = "description"
        public static let activated = "activated"
        /// The smart-album filter the images must match.
        public static let filter = "filter"
        /// The `Description` of the DICOM node the images go to.
        public static let destination = "server"
        /// 1 from the version that cleared the filter of a rule whose filter
        /// type is not 0; older rules have none.
        public static let version = "version"
        /// 0: every image; 1: images the app generated; 2: imported files.
        public static let filterType = "filterType"
        public static let imagesOnly = "imagesOnly"
        /// How many earlier studies of the patient go with each study.
        public static let previousStudies = "previousStudies"
        public static let previousModality = "previousModality"
        public static let previousDescription = "previousDescription"
        /// How many times a send that failed is tried again.
        public static let failureRetry = "failureRetry"
        /// Whether the node is asked first whether it has the study already.
        public static let cfindTest = "cfindTest"
        /// 0: now; 1: after `delayTime` hours; 2: between `fromTime` and `toTime`.
        public static let scheduleType = "scheduleType"
        public static let delayTime = "delayTime"
        public static let fromTime = "fromTime"
        public static let toTime = "toTime"
    }

    /// The entry as stored, every key included.
    public var entry: [String: PropertyListValue]

    public init(entry: [String: PropertyListValue] = [:]) {
        self.entry = entry
    }

    /// The rule an entry of `AUTOROUTINGDICTIONARY` describes; nil for an
    /// entry that is not a dictionary of property-list values.
    public init?(propertyList: Any) {
        guard let dictionary = propertyList as? [String: Any],
              let entry = PropertyListValue.dictionary(dictionary) else { return nil }
        self.entry = entry
    }

    /// The rules of the preference, in their order; an entry that is not a
    /// rule is left out.
    public static func rules(fromPropertyList propertyList: Any?) -> [RoutingRule] {
        (propertyList as? [Any] ?? []).compactMap(RoutingRule.init(propertyList:))
    }

    /// The entry as the preferences store it.
    public var propertyList: [String: Any] {
        entry.mapValues(\.object)
    }

    public subscript(key: String) -> PropertyListValue? {
        get { entry[key] }
        set { entry[key] = newValue }
    }

    // MARK: Typed settings

    /// The name, when stored as text.
    public var name: String? {
        entry[Key.name]?.stringValue
    }

    /// The name as a log line prints it: "(null)" when missing.
    public var loggedName: String {
        entry[Key.name]?.text ?? "(null)"
    }

    /// The `Description` of the node the images go to, when stored as text.
    public var destinationName: String? {
        entry[Key.destination]?.stringValue
    }

    /// The smart-album filter, when stored as text.
    public var filter: String? {
        entry[Key.filter]?.stringValue
    }

    /// Whether the rule is applied. A rule without the key is. A number is
    /// read with `-boolValue`; text must be neither "0" nor empty, and
    /// `-boolValue` must read it as true.
    public var isActivated: Bool {
        switch entry[Key.activated] {
        case nil:
            return true
        case .string(let text)?:
            return text != "0" && !text.isEmpty && (text as NSString).boolValue
        case let value? where value.isNumber:
            return value.boolValue
        default:
            return false
        }
    }

    public var version: Int32 { RoutingRule.intValue(entry[Key.version]) }
    public var filterType: Int32 { RoutingRule.intValue(entry[Key.filterType]) }
    public var imagesOnly: Bool { entry[Key.imagesOnly]?.boolValue ?? false }
    public var previousStudies: Int { entry[Key.previousStudies]?.intValue ?? 0 }
    public var previousModality: Bool { entry[Key.previousModality]?.boolValue ?? false }
    public var previousDescription: Bool { entry[Key.previousDescription]?.boolValue ?? false }
    public var failureRetry: Int32 { RoutingRule.intValue(entry[Key.failureRetry]) }
    public var cfindTest: Bool { entry[Key.cfindTest]?.boolValue ?? false }
    public var delayTime: Int { entry[Key.delayTime]?.intValue ?? 0 }
    public var fromTime: PropertyListValue? { entry[Key.fromTime] }
    public var toTime: PropertyListValue? { entry[Key.toTime] }

    /// The schedule: a number's integer value, or text that is an integer;
    /// 0 for a missing key and anything else.
    public var scheduleType: Int {
        switch entry[Key.scheduleType] {
        case .string(let text)?: return Int(text) ?? 0
        case let value? where value.isNumber: return value.intValue
        default: return 0
        }
    }

    /// The filter the images are matched against. A rule written before
    /// version 1 kept a filter it no longer showed when its filter type was
    /// not 0; that filter is not applied.
    public var effectiveFilter: String? {
        version < 1 && filterType != 0 ? "" : filter
    }

    /// `-intValue` of a stored value: the 32-bit value of a number, the
    /// leading integer of text, 0 for a missing key.
    static func intValue(_ value: PropertyListValue?) -> Int32 {
        switch value {
        case .string(let text)?: return (text as NSString).intValue
        case .integer(let number)?: return NSNumber(value: number).int32Value
        case .real(let number)?: return NSNumber(value: number).int32Value
        case .boolean(let flag)?: return flag ? 1 : 0
        default: return 0
        }
    }
}

/// Encoded as the stored entry: a rule encoded with PropertyListEncoder is the
/// dictionary `AUTOROUTINGDICTIONARY` holds.
extension RoutingRule: Codable {
    public init(from decoder: Decoder) throws {
        entry = try decoder.singleValueContainer().decode([String: PropertyListValue].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(entry)
    }
}
