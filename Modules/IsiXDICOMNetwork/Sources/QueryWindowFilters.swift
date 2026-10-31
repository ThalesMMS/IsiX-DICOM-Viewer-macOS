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

/// The filters of the Query window as one value: what was typed and chosen in
/// it, the nodes to ask, and the retrieve settings a preset keeps with them.
///
/// The window's presets (`QRPresets`), its saved settings
/// (`savedDICOMQuerySettings`) and the instances of the automatic query keep
/// these filters as a dictionary with the keys the window has always written.
/// `init(propertyList:)` reads such a dictionary the way the window read it:
/// a number may also be given as text, and a value of the wrong type counts as
/// missing. `propertyList` writes the same keys. `query(settings:...)` turns the
/// filters into the filters of the C-FIND.
public struct QueryWindowFilters: Equatable, Sendable {
    /// The modalities chosen, as a preset gives them.
    public enum Modalities: Equatable, Sendable {
        /// None given.
        case none
        /// The titles of the modalities (`modalityStrings`).
        case titles([String])
        /// The cells of the former modality matrix, "row column " pairs
        /// (`modalityFilterMatrixString`), as presets of older versions keep them.
        case formerCells(String)
        /// The one cell of an older matrix (`modalityFilterMatrixRow` and
        /// `modalityFilterMatrixColumn`).
        case formerCell(row: Int32, column: Int32)
    }

    /// The keys of a preset that are not those of an automatic query's instance.
    public enum FormerKey {
        public static let modalityCells = "modalityFilterMatrixString"
        public static let modalityRow = "modalityFilterMatrixRow"
        public static let modalityColumn = "modalityFilterMatrixColumn"
    }

    /// The retrieve settings a preset keeps, as the preferences hold them.
    public static let retrieveSettingKeys: [AutoQueryInstance.Key] = [
        .autoRetrieving, .numberOfPreviousStudyToRetrieve, .retrieveSameModality, .retrieveSameDescription,
    ]

    /// The nodes to ask, as "address:port", in order; nil when the preset
    /// names none.
    public var nodes: [String]?
    /// The AE title of each of those nodes, by position.
    public var nodeAETitles: [String]?
    public var patientName: String?
    public var patientID: String?
    public var accessionNumber: String?
    public var studyDescription: String?
    public var referringPhysician: String?
    public var studyComments: String?
    public var institutionName: String?
    /// The value of the custom field, and the title of the attribute chosen
    /// for it in the window's menu.
    public var customField: String?
    public var customFieldAttribute: String?
    /// The tag of the State chosen; nil when the preset has none.
    public var interpretationStatus: Int32?
    /// The tab of the search field shown: a `QueryWindowField` when in range.
    public var fieldIndex: Int32 = 0
    /// The date choice, by the tag of its cell (`QueryDateFilter`).
    public var dateChoice: Int32 = 0
    /// The two date pickers.
    public var fromDate = Date(timeIntervalSinceReferenceDate: 0)
    public var toDate = Date(timeIntervalSinceReferenceDate: 0)
    /// The birth date, and how it matches: on (0), before (-1) or after (1).
    public var birthDate = Date(timeIntervalSinceReferenceDate: 0)
    public var birthDateChoice: Int32 = 0
    public var modalities = Modalities.none
    /// The refresh interval of the automatic query (`AutoQueryInstance.refreshSetting`);
    /// nil when the preset has none.
    public var refreshSetting: Int32?
    /// The retrieve settings, by their preference key, as they were read.
    public var retrieveSettings: [String: PropertyListValue] = [:]

    public init() {}

    /// The search field shown, nil when the tab is none of them.
    public var field: QueryWindowField? {
        QueryWindowField(rawValue: Int(fieldIndex))
    }

    /// What was typed in the text field `field`; nil for the birth date and the
    /// State, which are not texts.
    public func text(of field: QueryWindowField) -> String? {
        switch field {
        case .patientName: return patientName
        case .patientID: return patientID
        case .accessionNumber: return accessionNumber
        case .studyDescription: return studyDescription
        case .referringPhysician: return referringPhysician
        case .studyComments: return studyComments
        case .institutionName: return institutionName
        case .customField: return customField
        case .patientBirthDate, .interpretationStatus: return nil
        }
    }

    /// Sets what was typed in the text field `field`.
    public mutating func setText(_ text: String?, of field: QueryWindowField) {
        switch field {
        case .patientName: patientName = text
        case .patientID: patientID = text
        case .accessionNumber: accessionNumber = text
        case .studyDescription: studyDescription = text
        case .referringPhysician: referringPhysician = text
        case .studyComments: studyComments = text
        case .institutionName: institutionName = text
        case .customField: customField = text
        case .patientBirthDate, .interpretationStatus: break
        }
    }

    /// The key of a preset that holds what was typed in `field`.
    public static func presetKey(of field: QueryWindowField) -> AutoQueryInstance.Key {
        switch field {
        case .patientName: return .searchFieldName
        case .patientID: return .searchFieldID
        case .accessionNumber: return .searchFieldAN
        case .studyDescription: return .searchFieldStudyDescription
        case .referringPhysician: return .searchFieldRefPhysician
        case .studyComments: return .searchFieldComments
        case .institutionName: return .searchInstitutionName
        case .customField: return .searchCustomField
        case .patientBirthDate: return .searchBirth
        case .interpretationStatus: return .searchStatus
        }
    }

    /// The text fields of a preset, in the order the window writes them.
    private static let textFields: [QueryWindowField] = [
        .patientName, .referringPhysician, .institutionName, .patientID, .accessionNumber,
        .studyDescription, .studyComments, .customField,
    ]

    // MARK: The dictionary of a preset

    /// The filters of a preset dictionary.
    public init(propertyList dictionary: [String: Any]) {
        func value(_ key: AutoQueryInstance.Key) -> Any? { dictionary[key.rawValue] }

        nodes = value(.dicomNodes) as? [String]
        nodeAETitles = value(.dicomNodesAETitle) as? [String]
        for field in Self.textFields {
            setText(value(Self.presetKey(of: field)) as? String, of: field)
        }
        customFieldAttribute = value(.searchCustomFieldDICOM) as? String
        interpretationStatus = value(.searchStatus).map(Self.int32)
        fieldIndex = Self.int32(value(.patientModeMatrix))
        dateChoice = Self.int32(value(.dateFilterMatrix))
        birthDateChoice = Self.int32(value(.birthdateFilterMatrix))
        fromDate = Date(timeIntervalSinceReferenceDate: Self.double(value(.fromDate)))
        toDate = Date(timeIntervalSinceReferenceDate: Self.double(value(.toDate)))
        birthDate = Date(timeIntervalSinceReferenceDate: Self.double(value(.searchBirth)))
        refreshSetting = value(.autoRefreshQueryResults).map(Self.int32)

        if let titles = value(.modalityStrings) as? [String] {
            modalities = .titles(titles)
        } else if let cells = dictionary[FormerKey.modalityCells] as? String {
            modalities = .formerCells(cells)
        } else if let row = dictionary[FormerKey.modalityRow], let column = dictionary[FormerKey.modalityColumn] {
            modalities = .formerCell(row: Self.int32(row), column: Self.int32(column))
        }

        for key in Self.retrieveSettingKeys {
            if let object = value(key), let setting = PropertyListValue(object) {
                retrieveSettings[key.rawValue] = setting
            }
        }
    }

    /// The dictionary of the preset, with the keys the window writes.
    public var propertyList: [String: Any] {
        var list: [String: Any] = [:]
        func set(_ key: AutoQueryInstance.Key, _ object: Any?) { list[key.rawValue] = object }

        if let nodes {
            set(.dicomNodes, nodes)
            set(.dicomNodesAETitle, nodeAETitles ?? [])
        }
        for field in Self.textFields {
            set(Self.presetKey(of: field), text(of: field))
        }
        set(.searchCustomFieldDICOM, customFieldAttribute)
        set(.searchStatus, interpretationStatus.map { NSNumber(value: $0) })
        set(.dateFilterMatrix, NSNumber(value: dateChoice))
        set(.birthdateFilterMatrix, NSNumber(value: birthDateChoice))
        switch modalities {
        case .none: break
        case .titles(let titles): set(.modalityStrings, titles)
        case .formerCells(let cells): list[FormerKey.modalityCells] = cells
        case .formerCell(let row, let column):
            list[FormerKey.modalityRow] = NSNumber(value: row)
            list[FormerKey.modalityColumn] = NSNumber(value: column)
        }
        set(.patientModeMatrix, NSNumber(value: fieldIndex))
        set(.fromDate, NSNumber(value: fromDate.timeIntervalSinceReferenceDate))
        set(.toDate, NSNumber(value: toDate.timeIntervalSinceReferenceDate))
        set(.searchBirth, NSNumber(value: birthDate.timeIntervalSinceReferenceDate))
        set(.autoRefreshQueryResults, refreshSetting.map { NSNumber(value: $0) })
        for (key, setting) in retrieveSettings {
            list[key] = setting.object
        }
        return list
    }

    /// `-intValue` of a value that may be a number or a text; 0 otherwise.
    static func int32(_ value: Any?) -> Int32 {
        if let number = value as? NSNumber { return number.int32Value }
        if let text = value as? NSString { return text.intValue }
        return 0
    }

    /// `-doubleValue` of a value that may be a number or a text; 0 otherwise.
    static func double(_ value: Any?) -> Double {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? NSString { return text.doubleValue }
        return 0
    }
}

// MARK: - The query

/// The preferences that decide what a query of the window sends.
public struct QueryWindowQuerySettings: Equatable, Sendable {
    /// The search fields that may be queried (the `allow_qr_*` of each field).
    public var allowedFields: Set<QueryWindowField>
    /// `allow_qr_study_date`: the date choice is sent.
    public var allowsStudyDate: Bool
    /// `allow_qr_modality`: the modalities are sent even when nothing else is.
    public var allowsModality: Bool
    /// `SupportQRModalitiesinStudy`: the modalities go in ModalitiesInStudy.
    public var supportsModalitiesInStudy: Bool
    /// `DICOMQueryAllowFutureQuery`: a range of dates or times stays open at its end.
    public var allowsFutureQuery: Bool
    /// `STRINGENCODING`: the character set of the query.
    public var characterSet: String?

    public init(allowedFields: Set<QueryWindowField> = [], allowsStudyDate: Bool = false, allowsModality: Bool = false,
                supportsModalitiesInStudy: Bool = false, allowsFutureQuery: Bool = false, characterSet: String? = nil) {
        self.allowedFields = allowedFields
        self.allowsStudyDate = allowsStudyDate
        self.allowsModality = allowsModality
        self.supportsModalitiesInStudy = supportsModalitiesInStudy
        self.allowsFutureQuery = allowsFutureQuery
        self.characterSet = characterSet
    }

    /// The preferences as stored in `defaults`.
    public init(defaults: any PreferenceStore) {
        self.init(allowedFields: Set(QueryWindowField.allCases.filter { defaults[$0.preferenceKey] }),
                  allowsStudyDate: defaults[NetworkPreferences.allowsQueryByStudyDate],
                  allowsModality: defaults[NetworkPreferences.allowsQueryByModality],
                  supportsModalitiesInStudy: defaults[NetworkPreferences.supportsQRModalitiesInStudy],
                  allowsFutureQuery: defaults[NetworkPreferences.dicomQueryAllowsFutureQuery],
                  characterSet: defaults[NetworkPreferences.queryCharacterSet])
    }
}

/// What a query of the window sends to each node: the filters, by the names
/// the query manager reads, in the order it receives them.
public struct QueryWindowQuery: Equatable, Sendable {
    public struct Filter: Equatable, Sendable {
        /// Nil for a custom field whose attribute has no keyword: the query
        /// manager takes no filter without a name, and the query goes on.
        public var key: String?
        public var value: String

        public init(key: String?, value: String) {
            self.key = key
            self.value = value
        }
    }

    public var filters: [Filter] = []
    /// Whether a field, a date or a modality was asked for. A query that asks
    /// for nothing may take long: the window asks first, or refuses it.
    public var asksForSomething = false
    /// The search field queried, when its preference allows it.
    public var field: QueryWindowField?
    /// What was typed in that field (the State as its number), for the check
    /// that the character set can write it; nil for the birth date.
    public var typedValue: String?
    /// The patient's name as typed, without surrounding white space, when the
    /// name was sent: a node that finds nothing is asked again in other
    /// spellings of it.
    public var patientName: String?
    /// The date choice is none of the window's.
    public var unknownDateChoice = false

    public init() {}

    /// The filter named `key`, the last one sent with that name.
    public func value(of key: String) -> String? {
        filters.last { $0.key == key }?.value
    }
}

extension QueryWindowFilters {
    /// The filters of the C-FIND, as the window sends them to each node.
    ///
    /// `customFieldKeyword` is the keyword of the attribute chosen for the
    /// custom field. `now` is the instant of the query; dates are written in
    /// the Gregorian calendar of `timeZone`.
    public func query(settings: QueryWindowQuerySettings, customFieldKeyword: String?, now: Date,
                      timeZone: TimeZone) -> QueryWindowQuery {
        var query = QueryWindowQuery()
        func send(_ key: String?, _ value: String) {
            query.filters.append(QueryWindowQuery.Filter(key: key, value: value))
        }

        if let characterSet = settings.characterSet, characterSet != "ISO_IR 100" {
            send("SpecificCharacterSet", characterSet)
        }

        if let field, settings.allowedFields.contains(field) {
            query.field = field
            switch field {
            case .patientBirthDate:
                if let value = QueryDateFilter.birthDateValue(forTag: Int(birthDateChoice), date: birthDate, timeZone: timeZone) {
                    send(field.key, value)
                }
                query.asksForSomething = true
            default:
                let typed = field == .interpretationStatus ? String(interpretationStatus ?? 0) : text(of: field)
                query.typedValue = typed
                if let value = field.filterValue(typed) {
                    send(field == .customField ? customFieldKeyword : field.key, value)
                    query.asksForSomething = true
                    if field == .patientName {
                        query.patientName = (typed ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
        }

        let criteria = QueryDateFilter.criteria(tag: dateChoice, from: fromDate, to: toDate, now: now,
                                                allowFutureQuery: settings.allowsFutureQuery, timeZone: timeZone)
        query.unknownDateChoice = criteria.unknownTag
        if settings.allowsStudyDate {
            if let date = QueryDateFilter.studyDateValue(criteria.date, now: now, allowFutureQuery: settings.allowsFutureQuery,
                                                         timeZone: timeZone) {
                send("StudyDate", date)
                query.asksForSomething = true
            }
            if let time = criteria.time {
                send("StudyTime", time)
                query.asksForSomething = true
            }
        }

        if case .titles(let titles) = modalities, let value = QueryModalityFilter.value(titles),
           query.asksForSomething || settings.allowsModality {
            send(QueryModalityFilter.key(supportsModalitiesInStudy: settings.supportsModalitiesInStudy), value)
            query.asksForSomething = true
        }
        return query
    }
}
