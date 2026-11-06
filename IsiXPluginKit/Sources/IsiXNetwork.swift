//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The DICOM network of a plugin: the nodes the user configured in Locations,
// sending to them, and querying them (studies, series and the modality
// worklist). A plugin names a node by its identifier, never by an address:
// the application opens the association itself, with the node's settings and
// TLS, and refuses a node the user did not configure.

import Foundation

/// A DICOM node the user configured in Locations, copied when it was read.
public struct IsiXDICOMNode: Hashable, Sendable {
    /// What a plugin names the node by: "AETITLE@host:port".
    public var id: String
    /// The node's description in Locations, or its AE title.
    public var name: String
    public var aeTitle: String
    public var host: String
    public var port: Int
    /// The application talks to it over TLS, with the node's TLS settings.
    public var usesTLS: Bool
    /// Send is on: `send(_:to:)` may use it.
    public var acceptsSend: Bool
    /// Query/Retrieve is on: `find(_:on:)` may use it.
    public var acceptsQuery: Bool

    @_spi(IsiXHost)
    public init(id: String, name: String, aeTitle: String, host: String, port: Int, usesTLS: Bool, acceptsSend: Bool, acceptsQuery: Bool) {
        self.id = id
        self.name = name
        self.aeTitle = aeTitle
        self.host = host
        self.port = port
        self.usesTLS = usesTLS
        self.acceptsSend = acceptsSend
        self.acceptsQuery = acceptsQuery
    }
}

/// What to send: images of the database, by study, series or SOP Instance
/// UID, and DICOM files the plugin wrote.
public struct IsiXSendRequest: Hashable, Sendable {
    public var studyInstanceUIDs: [String]
    public var seriesInstanceUIDs: [String]
    public var sopInstanceUIDs: [String]
    /// DICOM files outside the database, such as those the plugin wrote.
    public var files: [URL]

    public init(studyInstanceUIDs: [String] = [], seriesInstanceUIDs: [String] = [], sopInstanceUIDs: [String] = [], files: [URL] = []) {
        self.studyInstanceUIDs = studyInstanceUIDs
        self.seriesInstanceUIDs = seriesInstanceUIDs
        self.sopInstanceUIDs = sopInstanceUIDs
        self.files = files
    }

    public var isEmpty: Bool { studyInstanceUIDs.isEmpty && seriesInstanceUIDs.isEmpty && sopInstanceUIDs.isEmpty && files.isEmpty }
}

/// How a send ended. A send that could not start (no association, nothing
/// to send) throws instead.
public struct IsiXSendResult: Hashable, Sendable {
    public var sent: Int
    public var failed: Int
    /// What went wrong with the files that failed, as the network log says it.
    public var failureReason: String?

    @_spi(IsiXHost)
    public init(sent: Int, failed: Int, failureReason: String?) {
        self.sent = sent
        self.failed = failed
        self.failureReason = failureReason
    }
}

/// What a C-FIND asks for.
public enum IsiXQueryLevel: String, Hashable, Sendable {
    /// Studies, in the Study Root model.
    case study
    /// The series of one study, in the Study Root model.
    case series
    /// Scheduled procedure steps of the Modality Worklist.
    case worklist
}

/// A C-FIND. Text filters take the wildcards `*` and `?`; nil matches
/// everything. Dates filter the study date, the series date or the scheduled
/// start date, by day.
public struct IsiXNetworkQuery: Hashable, Sendable {
    public var level: IsiXQueryLevel
    public var patientName: String?
    public var patientID: String?
    public var accessionNumber: String?
    /// Needed for `.series`.
    public var studyInstanceUID: String?
    public var modality: String?
    /// The study, series or scheduled step description.
    public var description: String?
    public var dateFrom: Date?
    public var dateTo: Date?
    /// `.worklist`: the station the steps are scheduled on.
    public var scheduledStationAETitle: String?
    /// At most this many matches are returned; nil for all.
    public var limit: Int?

    public init(level: IsiXQueryLevel, patientName: String? = nil, patientID: String? = nil, accessionNumber: String? = nil,
                studyInstanceUID: String? = nil, modality: String? = nil, description: String? = nil, dateFrom: Date? = nil,
                dateTo: Date? = nil, scheduledStationAETitle: String? = nil, limit: Int? = nil) {
        self.level = level
        self.patientName = patientName
        self.patientID = patientID
        self.accessionNumber = accessionNumber
        self.studyInstanceUID = studyInstanceUID
        self.modality = modality
        self.description = description
        self.dateFrom = dateFrom
        self.dateTo = dateTo
        self.scheduledStationAETitle = scheduledStationAETitle
        self.limit = limit
    }
}

/// One match of a C-FIND: the attributes the node answered, by DICOM
/// keyword (`PatientName`, `StudyInstanceUID`, `ScheduledProcedureStepStartDate`...),
/// as text. A worklist's scheduled step attributes are those of its first step.
public struct IsiXQueryMatch: Hashable, Sendable {
    public var level: IsiXQueryLevel
    public var values: [String: String]

    @_spi(IsiXHost)
    public init(level: IsiXQueryLevel, values: [String: String]) {
        self.level = level
        self.values = values
    }

    public subscript(keyword: String) -> String? { values[keyword] }
}

/// The network as the host implements it. Its methods may be called on any
/// thread and block until the node answered.
@_spi(IsiXHost)
public protocol IsiXNetworkBackend: AnyObject, Sendable {
    func networkNodes() throws -> [IsiXDICOMNode]
    func send(_ request: IsiXSendRequest, toNode id: String) throws -> IsiXSendResult
    func find(_ query: IsiXNetworkQuery, onNode id: String) throws -> [IsiXQueryMatch]
}

/// The DICOM nodes of Locations, for sending (`network.send`) and querying
/// (`network.query`). Every call may be made from any thread; the forms
/// without `async` wait for the node, so on the main actor use the `async` ones.
public final class IsiXNetwork: Sendable {
    private let backend: any IsiXNetworkBackend
    private let capabilities: Set<IsiXCapability>

    init(backend: any IsiXNetworkBackend, capabilities: Set<IsiXCapability>) {
        self.backend = backend
        self.capabilities = capabilities
    }

    private func require(_ capability: IsiXCapability) throws {
        guard capabilities.contains(capability) else { throw IsiXPluginError.capabilityNotDeclared(capability) }
    }

    /// The nodes the plugin may use: with Send on when it declared
    /// `network.send`, with Query/Retrieve on when it declared `network.query`.
    public func nodes() throws -> [IsiXDICOMNode] {
        let send = capabilities.contains(.networkSend), query = capabilities.contains(.networkQuery)
        guard send || query else { throw IsiXPluginError.capabilityNotDeclared(.networkSend) }
        return try backend.networkNodes().filter { (send && $0.acceptsSend) || (query && $0.acceptsQuery) }
    }

    /// Sends to the node, in the transfer syntax its entry asks for, and
    /// returns when the node answered every file.
    public func send(_ request: IsiXSendRequest, to nodeID: String) throws -> IsiXSendResult {
        try require(.networkSend)
        guard !request.isEmpty else { throw IsiXPluginError.invalidValue("Nothing to send.") }
        return try backend.send(request, toNode: nodeID)
    }

    public func send(_ request: IsiXSendRequest, to nodeID: String) async throws -> IsiXSendResult {
        try require(.networkSend)
        guard !request.isEmpty else { throw IsiXPluginError.invalidValue("Nothing to send.") }
        let backend = self.backend
        return try await Task.detached { try backend.send(request, toNode: nodeID) }.value
    }

    /// The matches of a C-FIND on the node.
    public func find(_ query: IsiXNetworkQuery, on nodeID: String) throws -> [IsiXQueryMatch] {
        try require(.networkQuery)
        try Self.validate(query)
        return Self.limited(try backend.find(query, onNode: nodeID), query.limit)
    }

    public func find(_ query: IsiXNetworkQuery, on nodeID: String) async throws -> [IsiXQueryMatch] {
        try require(.networkQuery)
        try Self.validate(query)
        let backend = self.backend
        return Self.limited(try await Task.detached { try backend.find(query, onNode: nodeID) }.value, query.limit)
    }

    private static func validate(_ query: IsiXNetworkQuery) throws {
        if query.level == .series && (query.studyInstanceUID ?? "").isEmpty {
            throw IsiXPluginError.invalidValue("A query of series names their study.")
        }
        if let limit = query.limit, limit < 0 { throw IsiXPluginError.invalidValue("A query cannot ask for fewer than no matches.") }
    }

    private static func limited(_ matches: [IsiXQueryMatch], _ limit: Int?) -> [IsiXQueryMatch] {
        guard let limit else { return matches }
        return Array(matches.prefix(limit))
    }
}

public extension IsiXPluginContext {
    /// The DICOM nodes of Locations; needs `network.send` or `network.query`.
    func network() throws -> IsiXNetwork {
        try requireActive()
        guard info.capabilities.contains(.networkSend) || info.capabilities.contains(.networkQuery) else {
            throw IsiXPluginError.capabilityNotDeclared(.networkSend)
        }
        guard let backend = host as? any IsiXNetworkBackend else {
            throw IsiXPluginError.hostFailure("This application does not give plugins the DICOM network.")
        }
        return IsiXNetwork(backend: backend, capabilities: info.capabilities)
    }
}
