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

// MARK: The location of the database and the local sources

/// Where the database is, as a pair of keys holds it: in the Documents folder
/// (mode 0) or in the folder the user chose (mode 1). The mode is stored as an
/// integer and the folder as text, as the preference pane and first use write
/// them; a mode of another value is kept as it is.
public struct DatabaseLocationSetting: Codable, Sendable, Hashable {
    /// 0 for the Documents folder, 1 for `folder`.
    public var mode: Int
    /// The folder the user chose; nil or empty while none was.
    public var folder: String?

    public init(mode: Int, folder: String?) {
        self.mode = mode
        self.folder = folder
    }

    /// The folder `path`, chosen by the user.
    public static func folder(_ path: String) -> DatabaseLocationSetting {
        DatabaseLocationSetting(mode: 1, folder: path)
    }

    /// Whether the location is a folder the user chose rather than Documents.
    public var usesFolder: Bool { mode == 1 }
}

/// The two keys of a database location: the one the application opens
/// (`DATABASELOCATION`, `DATABASELOCATIONURL`) or the one the user chose
/// (`DEFAULT_DATABASELOCATION`, `DEFAULT_DATABASELOCATIONURL`).
public struct DatabaseLocationKeys: Sendable {
    public let mode: PreferenceKey<Int>
    public let folder: PreferenceKey<String?>

    public init(mode: PreferenceKey<Int>, folder: PreferenceKey<String?>) {
        self.mode = mode
        self.folder = folder
    }

    /// Whether either key was given as an argument of the launch.
    public func isGivenAsLaunchArgument(in store: any PreferenceStore) -> Bool {
        store.isGivenAsLaunchArgument(mode) || store.isGivenAsLaunchArgument(folder)
    }
}

extension PreferenceStore {
    /// The location the two keys hold, each read as its accessor read it.
    public subscript(location: DatabaseLocationKeys) -> DatabaseLocationSetting {
        DatabaseLocationSetting(mode: self[location.mode], folder: self[location.folder])
    }

    /// Stores `value` under the two keys, the folder first and then the mode,
    /// in that order as the panes and first use did; a nil folder removes the
    /// user's own.
    public func set(_ value: DatabaseLocationSetting, for location: DatabaseLocationKeys) {
        set(value.folder, for: location.folder)
        set(value.mode, for: location.mode)
    }
}

/// One local database the browser lists beside the default one: a dictionary
/// of the Locations pane's table, with its "Path", its "Description" and the
/// switches the panes add, kept as stored.
public struct LocalDatabaseSource: PropertyListRepresentable {
    public let propertyList: PropertyListValue

    public init?(propertyList: PropertyListValue) {
        guard propertyList.dictionaryValue != nil else { return nil }
        self.propertyList = propertyList
    }

    /// A source at `path`, named `name` when given.
    public init(path: String, name: String?) {
        var entries: [String: PropertyListValue] = ["Path": .string(path)]
        if let name { entries["Description"] = .string(name) }
        propertyList = .dictionary(entries)
    }

    /// The folder of the source, when its "Path" is text.
    public var path: String? { propertyList.dictionaryValue?["Path"]?.stringValue }
    /// The name the browser shows, when its "Description" is text.
    public var name: String? { propertyList.dictionaryValue?["Description"]?.stringValue }
}

/// The local databases (`localDatabasePaths`): the list as the Locations pane's
/// table and the browser store it. An element that is not a dictionary is
/// kept where it is, but is no source.
public struct LocalDatabaseSources: PropertyListRepresentable {
    public let propertyList: PropertyListValue

    public init?(propertyList: PropertyListValue) {
        guard propertyList.arrayValue != nil else { return nil }
        self.propertyList = propertyList
    }

    public init(_ sources: [LocalDatabaseSource]) {
        propertyList = .array(sources.map(\.propertyList))
    }

    /// The sources, in the order of the list.
    public var sources: [LocalDatabaseSource] {
        (propertyList.arrayValue ?? []).compactMap(LocalDatabaseSource.init(propertyList:))
    }

    /// The folders of the sources whose path is text, in order.
    public var paths: [String] { sources.compactMap(\.path) }
}

// MARK: The fields of the anonymization

/// The fields an anonymization replaces, each with its value: what the
/// anonymization panel saves (`AnonymizationFields`) and what each template
/// of `anonymizeTemplate` holds. The key is the DICOM name of the tag or its
/// "gggg,eeee" text; the value is what replaces it, text, a date or a number as
/// the field read it, or "" for a field emptied. Kept as stored, also the
/// names no tag has.
public struct AnonymizationFieldValues: PropertyListRepresentable {
    public let propertyList: PropertyListValue

    public init?(propertyList: PropertyListValue) {
        guard propertyList.dictionaryValue != nil else { return nil }
        self.propertyList = propertyList
    }

    public init(_ values: [String: PropertyListValue]) {
        propertyList = .dictionary(values)
    }

    /// The replacement of each field, by the name it is stored under.
    public var values: [String: PropertyListValue] { propertyList.dictionaryValue ?? [:] }
}

/// The fields the anonymization panel shows (`AnonymizationFieldsAll`): the
/// "gggg,eeee" text of each tag, in the order of the panel. An element that is
/// not text is kept where it is, but names no field.
public struct AnonymizationFieldList: PropertyListRepresentable {
    public let propertyList: PropertyListValue

    public init?(propertyList: PropertyListValue) {
        guard propertyList.arrayValue != nil else { return nil }
        self.propertyList = propertyList
    }

    public init(_ tags: [String]) {
        propertyList = .array(tags.map { .string($0) })
    }

    /// The text of each tag, in order.
    public var tags: [String] { (propertyList.arrayValue ?? []).compactMap(\.stringValue) }
}

/// The saved templates of the anonymization (`anonymizeTemplate`), by name.
/// A template that is not a dictionary is kept as stored, but is no template.
public struct AnonymizationTemplates: PropertyListRepresentable {
    public let propertyList: PropertyListValue

    public init?(propertyList: PropertyListValue) {
        guard propertyList.dictionaryValue != nil else { return nil }
        self.propertyList = propertyList
    }

    public init(_ templates: [String: AnonymizationFieldValues] = [:]) {
        propertyList = .dictionary(templates.mapValues(\.propertyList))
    }

    /// Every name stored, a template or not.
    public var names: [String] { Array((propertyList.dictionaryValue ?? [:]).keys) }

    /// The templates, by name.
    public var templates: [String: AnonymizationFieldValues] {
        (propertyList.dictionaryValue ?? [:]).compactMapValues(AnonymizationFieldValues.init(propertyList:))
    }

    /// The template named `name`; nil when there is none.
    public subscript(name: String) -> AnonymizationFieldValues? {
        propertyList.dictionaryValue?[name].flatMap(AnonymizationFieldValues.init(propertyList:))
    }

    /// The same templates, with `template` saved under `name` in place of any.
    public func setting(_ template: AnonymizationFieldValues, named name: String) -> AnonymizationTemplates {
        var entries = propertyList.dictionaryValue ?? [:]
        entries[name] = template.propertyList
        return AnonymizationTemplates(entries: entries)
    }

    /// The same templates without the one named `name`.
    public func removing(named name: String) -> AnonymizationTemplates {
        var entries = propertyList.dictionaryValue ?? [:]
        entries[name] = nil
        return AnonymizationTemplates(entries: entries)
    }

    private init(entries: [String: PropertyListValue]) {
        propertyList = .dictionary(entries)
    }
}
