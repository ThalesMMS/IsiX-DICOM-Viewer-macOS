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
import IsiXPreferences

/// What applying a state to a study does by itself. Only what neither
/// removes nor sends anything.
public enum StudyStateAction: String, Sendable, CaseIterable {
    case none
    /// Opens the study's images in a viewer.
    case openImages
    /// Converts the study's report to a PDF file, which replaces it as the report.
    case reportToPDF
    /// Stores the study's report in the study as a DICOM PDF.
    case reportToDICOMPDF
    /// Saves a PDF copy of the study's report in the reports export folder.
    case saveReportAsPDF
}

/// The colour a state shows in the lists, as red, green and blue from 0 to 1.
public struct StudyStateColor: Sendable, Equatable {
    public let red: Double, green: Double, blue: Double

    /// The components are kept as the 256 levels a stored colour has, so a
    /// colour is the same before and after it is written.
    public init(red: Double, green: Double, blue: Double) {
        func level(_ component: Double) -> Double { (min(max(component, 0), 1) * 255).rounded() / 255 }
        self.red = level(red)
        self.green = level(green)
        self.blue = level(blue)
    }

    /// From "#RRGGBB"; nil for anything else.
    public init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.utf8.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    public var hex: String {
        String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
}

/// A state a study can be given. Its number is its place in the list, which
/// is what the database stores.
public struct StudyState: Sendable, Equatable {
    /// The name the user gave it; nil for the name of its place.
    public var name: String?
    public var color: StudyStateColor?
    public var action: StudyStateAction

    public init(name: String? = nil, color: StudyStateColor? = nil, action: StudyStateAction = .none) {
        self.name = name
        self.color = color
        self.action = action
    }
}

/// The states a study can be given, in the order of their numbers.
///
/// The number of a state is stored in the database and in the studies' files,
/// and read by plugins as an index, so a state keeps its number for good: a
/// new state goes at the end, and only the last one can be removed. The first
/// five are the states every version has had, and stay.
public struct StudyStateList: Sendable, Equatable {
    /// The names of the first states, as keys the application localizes:
    /// 0 to 4 as they have always been, 5 to 7 as OsiriX names them.
    public static let builtInNames = ["empty", "unread", "reviewed", "dictated", "validated", "printed", "distributed", "archived"]
    /// The states that are never removed.
    public static let fixedCount = 5
    public static let maximumCount = 32
    /// The key the list is kept under in the preferences; absent, the list is `standard`.
    public static let preference = PreferenceKey<[PropertyListValue]?>("StudyStates")

    public private(set) var states: [StudyState]

    /// The eight states of a new installation, with no colour and no action.
    public static let standard = StudyStateList(states: Array(repeating: StudyState(), count: builtInNames.count))

    public init(states: [StudyState]) {
        var kept = Array(states.prefix(Self.maximumCount))
        while kept.count < Self.fixedCount { kept.append(StudyState()) }
        self.states = kept
    }

    // MARK: - Names

    /// The name of the state at `index`: the user's, else the name of its
    /// place through `localized`, else `numbered` given its number.
    public func name(at index: Int, localized: (String) -> String, numbered: (Int) -> String) -> String {
        guard states.indices.contains(index) else { return "" }
        if let name = states[index].name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        return index < Self.builtInNames.count ? localized(Self.builtInNames[index]) : numbered(index)
    }

    public func names(localized: (String) -> String, numbered: (Int) -> String) -> [String] {
        states.indices.map { name(at: $0, localized: localized, numbered: numbered) }
    }

    /// The place of a stored number in the list; nil for a number the list
    /// does not have, which is shown as no state at all.
    public func index(ofStored value: Int) -> Int? {
        states.indices.contains(value) ? value : nil
    }

    /// The digit that, with Option, gives the state at `index`: 1 to 9 for
    /// the states of those numbers. The empty state and those past 9 have none.
    public static func shortcutDigit(at index: Int) -> Int? {
        (1...9).contains(index) ? index : nil
    }

    // MARK: - Editing

    public var canAppend: Bool { states.count < Self.maximumCount }
    public var canRemoveLast: Bool { states.count > Self.fixedCount }

    public mutating func append() {
        if canAppend { states.append(StudyState()) }
    }

    public mutating func removeLast() {
        if canRemoveLast { states.removeLast() }
    }

    /// Changes the state at `index`; a name equal to the name of its place
    /// is the name of its place.
    public mutating func set(name: String?, at index: Int) {
        guard states.indices.contains(index) else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        states[index].name = trimmed.isEmpty ? nil : trimmed
    }

    public mutating func set(color: StudyStateColor?, at index: Int) {
        if states.indices.contains(index) { states[index].color = color }
    }

    public mutating func set(action: StudyStateAction, at index: Int) {
        if states.indices.contains(index) { states[index].action = action }
    }

    /// The action applying a state does: nothing when the state did not
    /// change, or for a number the list does not have.
    public func action(from previous: Int, to state: Int) -> StudyStateAction {
        guard previous != state, let index = index(ofStored: state) else { return .none }
        return states[index].action
    }

    // MARK: - Preferences

    /// The list as kept in the preferences: a dictionary per state, with only
    /// what the user chose.
    public var stored: [PropertyListValue] {
        states.map { state in
            var entry: [String: PropertyListValue] = [:]
            if let name = state.name { entry["name"] = .string(name) }
            if let color = state.color { entry["color"] = .string(color.hex) }
            if state.action != .none { entry["action"] = .string(state.action.rawValue) }
            return .dictionary(entry)
        }
    }

    /// The list a preference holds: `standard` when there is none or it is
    /// not a list of states; what cannot be read of a state is left out.
    public init(stored: [PropertyListValue]?) {
        guard let stored, !stored.isEmpty else {
            self = .standard
            return
        }
        var states: [StudyState] = []
        for value in stored {
            guard case .dictionary(let entry) = value else {
                self = .standard
                return
            }
            var state = StudyState()
            if case .string(let name)? = entry["name"], !name.isEmpty { state.name = name }
            if case .string(let hex)? = entry["color"] { state.color = StudyStateColor(hex: hex) }
            if case .string(let action)? = entry["action"] { state.action = StudyStateAction(rawValue: action) ?? .none }
            states.append(state)
        }
        self.init(states: states)
    }
}
