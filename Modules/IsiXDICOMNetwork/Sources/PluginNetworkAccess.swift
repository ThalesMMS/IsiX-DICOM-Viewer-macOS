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

/// A DIMSE node of Locations as plugins see it: what the user configured,
/// named by an identifier made of its AE title, address and port.
public struct PluginNode: Equatable, Sendable {
    public var identifier: String
    public var name: String
    public var aeTitle: String
    public var host: String
    public var port: Int
    public var usesTLS: Bool
    /// Send is on: plugins may send to it.
    public var sends: Bool
    /// Query/Retrieve is on: plugins may query it, worklist included.
    public var queries: Bool
}

/// What plugins may reach on the network: only the DIMSE nodes the user
/// configured in Locations (the `SERVERS` preference), activated, and for
/// each service only those whose entry allows it. A node found by Bonjour, a
/// DICOMweb node, or an address a plugin makes up is never one of them.
public enum PluginNetworkAccess {
    public enum Service: Sendable {
        case send, query
    }

    /// "AETITLE@host:port", the host in lower case: the same node keeps it
    /// whatever its description, and two entries for one peer share it.
    public static func identifier(aeTitle: String, host: String, port: Int) -> String {
        "\(aeTitle.trimmingCharacters(in: .whitespaces))@\(host.trimmingCharacters(in: .whitespaces).lowercased()):\(port)"
    }

    /// The nodes of `servers`, an array of `SERVERS` entries, that plugins may
    /// use for something, in the order of Locations; an entry with the
    /// identifier of an earlier one is left out.
    public static func nodes(fromServers servers: [Any]) -> [PluginNode] {
        var seen = Set<String>()
        var nodes: [PluginNode] = []
        for case let entry as [String: Any] in servers {
            guard let node = node(of: entry), node.sends || node.queries, seen.insert(node.identifier).inserted else { continue }
            nodes.append(node)
        }
        return nodes
    }

    /// The entry of `servers` with this identifier, when it allows `service`;
    /// nil when the user configured no such node, turned it off, or does not
    /// let it be used for `service`.
    public static func entry(withIdentifier identifier: String, for service: Service, inServers servers: [Any]) -> [String: Any]? {
        for case let entry as [String: Any] in servers {
            guard let node = node(of: entry), node.identifier == identifier else { continue }
            switch service {
            case .send: return node.sends ? entry : nil
            case .query: return node.queries ? entry : nil
            }
        }
        return nil
    }

    /// The identifier of the configured node a legacy plugin names by its
    /// address: the same AE title, the same port, and the same host, compared
    /// without regard to case. nil when no node of `servers` matches.
    public static func identifier(matchingAETitle aeTitle: String?, host: String?, port: Int, for service: Service,
                                  inServers servers: [Any]) -> String? {
        guard let aeTitle, let host else { return nil }
        let wanted = identifier(aeTitle: aeTitle, host: host, port: port)
        return entry(withIdentifier: wanted, for: service, inServers: servers) != nil ? wanted : nil
    }

    /// The node an entry describes; nil for an entry that is not a DIMSE
    /// node with a title, an address and a port, or that is turned off.
    static func node(of entry: [String: Any]) -> PluginNode? {
        let title = (entry["AETitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let host = (entry["Address"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let port = int(entry["Port"])
        guard !title.isEmpty, !host.isEmpty, port > 0, port < 65536 else { return nil }
        if entry["retrieveMode"] != nil && int(entry["retrieveMode"]) == DICOMRetrieveMode.dicomWeb.rawValue { return nil }
        if entry["Activated"] != nil && !bool(entry["Activated"]) { return nil }
        return PluginNode(identifier: identifier(aeTitle: title, host: host, port: port),
                          name: (entry["Description"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? title,
                          aeTitle: title, host: host, port: port, usesTLS: bool(entry["TLSEnabled"]),
                          sends: entry["Send"] == nil || bool(entry["Send"]),
                          queries: entry["QR"] == nil || bool(entry["QR"]))
    }

    private static func bool(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? NSString { return string.boolValue }
        return false
    }

    private static func int(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? NSString { return string.integerValue }
        return 0
    }
}

/// The C-FIND identifiers of the plugin API: studies and series in the Study
/// Root model, and the scheduled procedure steps of a modality worklist.
public enum PluginQueryKeys {
    public enum Level: String, Sendable {
        case study, series, worklist
    }

    /// One attribute of an identifier: top level, or in the first item of the
    /// Scheduled Procedure Step Sequence. An empty value asks for it back.
    public struct Key: Equatable, Sendable {
        public var tag: DICOMTag
        public var keyword: String
        public var inScheduledStep: Bool
        public var value: String

        public init(_ tag: DICOMTag, _ keyword: String, inScheduledStep: Bool = false, value: String = "") {
            self.tag = tag
            self.keyword = keyword
            self.inScheduledStep = inScheduledStep
            self.value = value
        }
    }

    /// What a plugin filters on; nil asks for the attribute without matching on it.
    public struct Filters: Equatable, Sendable {
        public var patientName: String?
        public var patientID: String?
        public var accessionNumber: String?
        public var studyInstanceUID: String?
        public var modality: String?
        public var description: String?
        public var dateFrom: Date?
        public var dateTo: Date?
        public var scheduledStationAETitle: String?

        public init(patientName: String? = nil, patientID: String? = nil, accessionNumber: String? = nil,
                    studyInstanceUID: String? = nil, modality: String? = nil, description: String? = nil,
                    dateFrom: Date? = nil, dateTo: Date? = nil, scheduledStationAETitle: String? = nil) {
            self.patientName = patientName
            self.patientID = patientID
            self.accessionNumber = accessionNumber
            self.studyInstanceUID = studyInstanceUID
            self.modality = modality
            self.description = description
            self.dateFrom = dateFrom
            self.dateTo = dateTo
            self.scheduledStationAETitle = scheduledStationAETitle
        }
    }

    public enum Failure: Error, Equatable, Sendable {
        /// A series query names no study.
        case seriesNeedStudy
        /// A filter holds a backslash, which separates values in DICOM, or a control character.
        case invalidFilter(String)
    }

    /// Modality Worklist Information Model - FIND.
    public static let worklistAbstractSyntax = "1.2.840.10008.5.1.4.31"
    /// Study Root Query/Retrieve Information Model - FIND.
    public static let studyRootAbstractSyntax = QueryRetrieveService.findStudyRoot.rawValue

    public static let scheduledProcedureStepSequence = DICOMTag(0x0040, 0x0100)
    static let patientSex = DICOMTag(0x0010, 0x0040)
    static let scheduledStationAETitle = DICOMTag(0x0040, 0x0001)
    static let scheduledStartDate = DICOMTag(0x0040, 0x0002)
    static let scheduledStartTime = DICOMTag(0x0040, 0x0003)
    static let scheduledPerformingPhysician = DICOMTag(0x0040, 0x0006)
    static let scheduledStepDescription = DICOMTag(0x0040, 0x0007)
    static let scheduledStepID = DICOMTag(0x0040, 0x0009)
    static let requestedProcedureID = DICOMTag(0x0040, 0x1001)
    static let requestedProcedureDescription = DICOMTag(0x0032, 0x1060)

    public static func abstractSyntax(for level: Level) -> String {
        level == .worklist ? worklistAbstractSyntax : studyRootAbstractSyntax
    }

    /// The identifier: the keys of the level, each with its filter or empty.
    public static func identifier(level: Level, filters: Filters) throws(Failure) -> [Key] {
        for value in [filters.patientName, filters.patientID, filters.accessionNumber, filters.studyInstanceUID, filters.modality,
                      filters.description, filters.scheduledStationAETitle].compactMap({ $0 }) {
            if value.contains("\\") || value.unicodeScalars.contains(where: { $0.value < 0x20 }) { throw .invalidFilter(value) }
        }
        let range = dateRange(from: filters.dateFrom, to: filters.dateTo)
        switch level {
        case .study:
            return [
                Key(.queryRetrieveLevel, "QueryRetrieveLevel", value: "STUDY"),
                Key(.patientName, "PatientName", value: filters.patientName ?? ""),
                Key(.patientID, "PatientID", value: filters.patientID ?? ""),
                Key(.patientBirthDate, "PatientBirthDate"),
                Key(.accessionNumber, "AccessionNumber", value: filters.accessionNumber ?? ""),
                Key(.studyInstanceUID, "StudyInstanceUID", value: filters.studyInstanceUID ?? ""),
                Key(.studyID, "StudyID"),
                Key(.studyDate, "StudyDate", value: range),
                Key(.studyTime, "StudyTime"),
                Key(.studyDescription, "StudyDescription", value: filters.description ?? ""),
                Key(.modalitiesInStudy, "ModalitiesInStudy", value: filters.modality ?? ""),
                Key(.referringPhysicianName, "ReferringPhysicianName"),
                Key(.numberOfStudyRelatedInstances, "NumberOfStudyRelatedInstances"),
            ]
        case .series:
            guard let study = filters.studyInstanceUID, !study.isEmpty else { throw .seriesNeedStudy }
            return [
                Key(.queryRetrieveLevel, "QueryRetrieveLevel", value: "SERIES"),
                Key(.studyInstanceUID, "StudyInstanceUID", value: study),
                Key(.seriesInstanceUID, "SeriesInstanceUID"),
                Key(.seriesNumber, "SeriesNumber"),
                Key(.seriesDate, "SeriesDate", value: range),
                Key(.modality, "Modality", value: filters.modality ?? ""),
                Key(.seriesDescription, "SeriesDescription", value: filters.description ?? ""),
                Key(.numberOfSeriesRelatedInstances, "NumberOfSeriesRelatedInstances"),
            ]
        case .worklist:
            return [
                Key(.patientName, "PatientName", value: filters.patientName ?? ""),
                Key(.patientID, "PatientID", value: filters.patientID ?? ""),
                Key(.patientBirthDate, "PatientBirthDate"),
                Key(patientSex, "PatientSex"),
                Key(.accessionNumber, "AccessionNumber", value: filters.accessionNumber ?? ""),
                Key(.studyInstanceUID, "StudyInstanceUID", value: filters.studyInstanceUID ?? ""),
                Key(.referringPhysicianName, "ReferringPhysicianName"),
                Key(requestedProcedureID, "RequestedProcedureID"),
                Key(requestedProcedureDescription, "RequestedProcedureDescription"),
                Key(scheduledStationAETitle, "ScheduledStationAETitle", inScheduledStep: true, value: filters.scheduledStationAETitle ?? ""),
                Key(scheduledStartDate, "ScheduledProcedureStepStartDate", inScheduledStep: true, value: range),
                Key(scheduledStartTime, "ScheduledProcedureStepStartTime", inScheduledStep: true),
                Key(.modality, "Modality", inScheduledStep: true, value: filters.modality ?? ""),
                Key(scheduledPerformingPhysician, "ScheduledPerformingPhysicianName", inScheduledStep: true),
                Key(scheduledStepDescription, "ScheduledProcedureStepDescription", inScheduledStep: true, value: filters.description ?? ""),
                Key(scheduledStepID, "ScheduledProcedureStepID", inScheduledStep: true),
            ]
        }
    }

    /// Whether the identifier needs a character set other than the default
    /// repertoire: a filter outside ASCII is sent in UTF-8, declared as ISO_IR 192.
    public static func needsUTF8(_ keys: [Key]) -> Bool {
        keys.contains { !$0.value.allSatisfy(\.isASCII) }
    }

    /// A DICOM date range: "from-to", "from-", "-to", or empty for none.
    public static func dateRange(from: Date?, to: Date?) -> String {
        guard from != nil || to != nil else { return "" }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd"
        let start = from.map(formatter.string(from:)) ?? ""
        let end = to.map(formatter.string(from:)) ?? ""
        return start == end ? start : "\(start)-\(end)"
    }
}
