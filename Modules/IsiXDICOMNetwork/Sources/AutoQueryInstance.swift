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

/// One instance of the automatic query: a preset of the Query window with its
/// name, the interval between its queries and what to retrieve of what it
/// finds.
///
/// It is kept in the preferences under `savedAutoDICOMQuerySettingsArray`, as
/// a dictionary with the keys the window has always written. Every value is
/// kept as it was read, with its type, and a key this version does not know
/// is kept as well: an instance read and written again comes out the same.
/// The properties read and write those values with their types; a value of
/// another type reads the way the window reads it (a number given as text
/// still counts).
///
/// The results of its last query are not part of it: they are the window's,
/// and never went to the preferences.
public struct AutoQueryInstance: Identifiable, Hashable, Sendable {
    /// The keys of an instance in the preferences.
    public enum Key: String, CaseIterable, Sendable {
        case instanceName
        case dicomNodes = "DICOMNodes"
        case dicomNodesAETitle = "DICOMNodesAETitle"
        case searchFieldName
        case searchFieldRefPhysician
        case searchInstitutionName
        case searchStatus
        case searchFieldID
        case searchFieldAN
        case searchFieldStudyDescription
        case searchFieldComments
        case searchCustomField
        case searchCustomFieldDICOM
        case dateFilterMatrix
        case birthdateFilterMatrix
        case modalityStrings
        case patientModeMatrix = "PatientModeMatrix"
        case fromDate
        case toDate
        case searchBirth
        case autoRefreshQueryResults
        case autoRetrieving
        case numberOfPreviousStudyToRetrieve = "NumberOfPreviousStudyToRetrieve"
        case retrieveSameModality
        case retrieveSameDescription
    }

    /// The key under which the preferences keep the instances, in order.
    public static let preferencesKey = NetworkPreferences.autoQueryInstances.name
    /// The single instance of the versions before several instances, read
    /// once into the list and then removed.
    public static let formerPreferencesKey = NetworkPreferences.formerAutoQueryInstance.name
    /// The key of the results a window keeps in an instance; never saved.
    public static let resultsKey = "resultArray"

    /// Who the instance is while the window runs: made when the instance is
    /// read or made, and never saved.
    public let id: UUID
    /// Every value of the instance, by its key in the preferences.
    public private(set) var values: [String: PropertyListValue]

    /// An instance with these values, by their key in the preferences.
    public init(id: UUID = UUID(), values: [String: PropertyListValue] = [:]) {
        self.id = id
        self.values = values
        self.values[Self.resultsKey] = nil
    }

    /// An instance read from a dictionary of the preferences or of the window;
    /// nil when it is not a dictionary. A value a property list cannot hold,
    /// such as the results the window kept in it, is left out.
    public init?(id: UUID = UUID(), propertyList object: Any?) {
        guard let dictionary = object as? [String: Any] else { return nil }
        var values: [String: PropertyListValue] = [:]
        for (key, element) in dictionary where key != Self.resultsKey {
            if let value = PropertyListValue(element) { values[key] = value }
        }
        self.init(id: id, values: values)
    }

    /// The dictionary to write in the preferences, with the same keys.
    public var propertyList: [String: Any] {
        values.mapValues(\.object)
    }

    /// This instance with the values of `propertyList` added over its own,
    /// as a save adds the filters of the window to the instance shown: what
    /// `propertyList` does not have stays as it was.
    public func adding(_ propertyList: [String: Any]) -> AutoQueryInstance {
        var merged = values
        for (key, element) in propertyList where key != Self.resultsKey {
            if let value = PropertyListValue(element) { merged[key] = value }
        }
        return AutoQueryInstance(id: id, values: merged)
    }

    public subscript(key: Key) -> PropertyListValue? {
        get { values[key.rawValue] }
        set { values[key.rawValue] = newValue }
    }

    // MARK: What the scheduler and the retrieve read

    /// The name the instance menu shows.
    public var name: String? {
        get { self[.instanceName]?.stringValue }
        set { self[.instanceName] = newValue.map(PropertyListValue.string) }
    }

    /// The interval between two queries as the window sets it: minutes when
    /// positive, seconds when negative, and no automatic query when 0.
    public var refreshSetting: Int {
        get { self[.autoRefreshQueryResults]?.intValue ?? 0 }
        set { self[.autoRefreshQueryResults] = .integer(newValue) }
    }

    /// The seconds between two queries; nil when the instance does not query
    /// by itself.
    public var refreshInterval: Int? {
        Self.seconds(ofRefreshSetting: refreshSetting)
    }

    /// The seconds of an interval set as the window sets it, nil for 0. The
    /// setting is first kept within one day either way (QueryRefreshSetting),
    /// as the window's own is: an instance saved with an absurd value, such as
    /// `Int.max` or `Int.min`, would otherwise overflow here and trap the
    /// scheduler.
    public static func seconds(ofRefreshSetting stored: Int) -> Int? {
        let setting = QueryRefreshSetting.clamped(stored)
        guard setting != 0 else { return nil }
        return setting > 0 ? 60 * setting : -setting
    }

    /// Whether what the query finds is retrieved.
    public var autoRetrieving: Bool {
        get { self[.autoRetrieving]?.boolValue ?? false }
        set { self[.autoRetrieving] = .boolean(newValue) }
    }

    /// How many earlier studies of each patient are retrieved with a study.
    public var numberOfPreviousStudiesToRetrieve: Int {
        get { self[.numberOfPreviousStudyToRetrieve]?.intValue ?? 0 }
        set { self[.numberOfPreviousStudyToRetrieve] = .integer(newValue) }
    }

    /// Whether an earlier study counts when it shares a modality.
    public var retrieveSameModality: Bool {
        get { self[.retrieveSameModality]?.boolValue ?? false }
        set { self[.retrieveSameModality] = .boolean(newValue) }
    }

    /// Whether an earlier study counts when its description holds this one's.
    public var retrieveSameDescription: Bool {
        get { self[.retrieveSameDescription]?.boolValue ?? false }
        set { self[.retrieveSameDescription] = .boolean(newValue) }
    }

    // MARK: The filters, which the window applies and queries with

    /// The nodes queried, as "address:port", and their AE titles, in order.
    public var dicomNodes: [String] { self[.dicomNodes]?.stringsValue ?? [] }
    public var dicomNodesAETitles: [String] { self[.dicomNodesAETitle]?.stringsValue ?? [] }
    /// The modalities chosen.
    public var modalities: [String] { self[.modalityStrings]?.stringsValue ?? [] }
    /// The search field shown, by its position.
    public var patientMode: Int { self[.patientModeMatrix]?.intValue ?? 0 }
    /// The date filter chosen, by the tag of its cell.
    public var dateFilter: Int { self[.dateFilterMatrix]?.intValue ?? 0 }

    /// The filters a run of this instance queries with.
    ///
    /// The instance the window shows queries with the window's two date
    /// pickers, `windowDates`: saving it just before its run wrote them into
    /// it. Any other instance queries with the dates it saved, so that two
    /// instances with different "between", "on" or "after" dates each ask for
    /// their own; a date it never saved is the window's, as every instance
    /// queried before. Relative choices ("today", "last 7 days") ignore these
    /// dates and are computed when the query is made.
    public func queryFilters(windowDates: (from: Date, to: Date), shown: Bool) -> QueryWindowFilters {
        var filters = QueryWindowFilters(propertyList: propertyList)
        if shown || self[.fromDate] == nil { filters.fromDate = windowDates.from }
        if shown || self[.toDate] == nil { filters.toDate = windowDates.to }
        return filters
    }
}

extension AutoQueryInstance: Codable {
    private struct CodingKey: Swift.CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// The instance from an encoded dictionary with the keys of the
    /// preferences; it gets a new `id`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKey.self)
        var values: [String: PropertyListValue] = [:]
        for key in container.allKeys where key.stringValue != Self.resultsKey {
            values[key.stringValue] = try container.decode(PropertyListValue.self, forKey: key)
        }
        self.init(values: values)
    }

    /// The instance as a dictionary with the keys of the preferences.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKey.self)
        for (key, value) in values {
            try container.encode(value, forKey: CodingKey(stringValue: key))
        }
    }
}

/// The instances as the preferences keep them, read and written through the
/// preferences store, under the keys of the catalog.
public enum AutoQueryInstanceStore {
    /// The instances in the preferences, in order, with the former single
    /// instance moved into the list under `defaultName`; the list is written
    /// back when that happens. An entry that is not a dictionary is skipped.
    public static func load(from preferences: any PreferenceStore, defaultName: String) -> [AutoQueryInstance] {
        let stored = preferences[NetworkPreferences.autoQueryInstances] ?? []
        var instances = stored.compactMap { AutoQueryInstance(propertyList: $0.object) }

        if let former = preferences[NetworkPreferences.formerAutoQueryInstance] {
            var instance = AutoQueryInstance(values: former)
            preferences.remove(NetworkPreferences.formerAutoQueryInstance)
            instance.name = defaultName
            instances.append(instance)
            save(instances, to: preferences)
        }
        return instances
    }

    /// Writes every instance, in order, without the results of its queries.
    public static func save(_ instances: [AutoQueryInstance], to preferences: any PreferenceStore) {
        preferences.set(instances.map(\.propertyList), forKey: NetworkPreferences.autoQueryInstances.name)
    }
}

extension PropertyListValue {
    /// The texts of an array; nil when it is not an array of texts only.
    var stringsValue: [String]? {
        guard case .array(let values) = self else { return nil }
        var strings: [String] = []
        for value in values {
            guard case .string(let string) = value else { return nil }
            strings.append(string)
        }
        return strings
    }
}
