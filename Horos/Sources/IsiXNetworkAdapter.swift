//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit
import IsiXDICOMNetwork
import IsiXHTTPServer
@_spi(IsiXHost) import IsiXPluginKit

/// The network of the plugin API version 1, and its XML-RPC methods and
/// database events.
///
/// A plugin names a node by its identifier; the node must be one the user
/// configured in Locations (`SERVERS`), activated, with Send or
/// Query/Retrieve on for what is asked (PluginNetworkAccess). The send goes
/// through DCMTKStoreSCU and the C-FIND through the DCMTK adapter, each with
/// the node's entry, so the node's transfer syntax and TLS settings apply as
/// they do to the application's own sends and queries. Both block the calling
/// thread; the plugin API runs its `async` forms on a thread of their own.
extension IsiXPluginHost: IsiXXMLRPCBackend {

    // MARK: nodes

    /// The nodes of Locations as the preferences hold them: a node Bonjour
    /// found is not among them.
    nonisolated private static var configuredServers: [Any] {
        UserDefaults.standard.array(forKey: "SERVERS") ?? []
    }

    nonisolated func networkNodes() throws -> [IsiXDICOMNode] {
        PluginNetworkAccess.nodes(fromServers: Self.configuredServers).map {
            IsiXDICOMNode(id: $0.identifier, name: $0.name, aeTitle: $0.aeTitle, host: $0.host, port: $0.port, usesTLS: $0.usesTLS,
                          acceptsSend: $0.sends, acceptsQuery: $0.queries)
        }
    }

    nonisolated private static func entry(_ id: String, for service: PluginNetworkAccess.Service) throws -> [String: Any] {
        guard let entry = PluginNetworkAccess.entry(withIdentifier: id, for: service, inServers: configuredServers) else {
            NSLog("IsiX plugin refused: %@ is not a configured node for %@", id, service == .send ? "sending" : "querying")
            throw IsiXPluginError.nodeNotConfigured(id)
        }
        return entry
    }

    nonisolated private static func int(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? NSString { return string.integerValue }
        return 0
    }

    // MARK: send

    nonisolated func send(_ request: IsiXSendRequest, toNode id: String) throws -> IsiXSendResult {
        if UserDefaults.standard.object(forKey: "DICOMSENDALLOWED") != nil && !UserDefaults.standard.bool(forKey: "DICOMSENDALLOWED") {
            throw IsiXPluginError.networkFailure("DICOM sending is not activated. Contact your PACS manager for more information about DICOM Send.")
        }
        let entry = try Self.entry(id, for: .send)
        var paths = try onMainActorSync { try self.databaseFilePaths(for: request) }
        for file in request.files {
            guard FileManager.default.isReadableFile(atPath: file.path) else {
                throw IsiXPluginError.invalidValue("The file \(file.path) cannot be read.")
            }
            paths.append(file.path)
        }
        var seen = Set<String>()
        paths = paths.filter { seen.insert($0).inserted }
        guard !paths.isEmpty else { throw IsiXPluginError.notFound("image to send") }

        let syntax = entry["TransferSyntax"] != nil ? Int32(truncatingIfNeeded: Self.int(entry["TransferSyntax"]))
            : Int32(SendExplicitLittleEndian.rawValue)
        let store = DCMTKStoreSCU(callingAET: UserDefaults.defaultAETitle(), calledAET: entry["AETitle"] as? String,
                                  hostname: entry["Address"] as? String, port: Int32(truncatingIfNeeded: Self.int(entry["Port"])),
                                  filesToSend: paths, transferSyntax: syntax, compression: 1.0, extraParameters: entry)
        NSLog("IsiX plugin send: %lu files to %@", UInt(paths.count), id)
        var reason: String?
        do {
            try HorosObjCException.perform { store.run(nil) }
        } catch {
            let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
            reason = exception?.reason ?? error.localizedDescription
        }
        let sent = store.report.sentCount
        if sent == 0, let reason { throw IsiXPluginError.networkFailure(reason) }
        return IsiXSendResult(sent: sent, failed: paths.count - sent, failureReason: reason)
    }

    /// The files of the studies, series and images of the request, each once;
    /// one that is not in the database throws `notFound`.
    private func databaseFilePaths(for request: IsiXSendRequest) throws -> [String] {
        var images: [IsiXDatabaseImage] = []
        for study in request.studyInstanceUIDs {
            let series = try seriesRecords(inStudy: study)
            guard !series.isEmpty else { throw IsiXPluginError.notFound("study \(study)") }
            for each in series { images += try self.images(inSeries: each.seriesInstanceUID) }
        }
        for series in request.seriesInstanceUIDs {
            let found = try self.images(inSeries: series)
            guard !found.isEmpty else { throw IsiXPluginError.notFound("series \(series)") }
            images += found
        }
        for sop in request.sopInstanceUIDs {
            let found = try self.images(withSOPInstanceUID: sop)
            guard !found.isEmpty else { throw IsiXPluginError.notFound("image \(sop)") }
            images += found
        }
        return images.compactMap { $0.file?.path }
    }

    // MARK: C-FIND

    nonisolated func find(_ query: IsiXNetworkQuery, onNode id: String) throws -> [IsiXQueryMatch] {
        let entry = try Self.entry(id, for: .query)
        let level: PluginQueryKeys.Level = switch query.level {
        case .study: .study
        case .series: .series
        case .worklist: .worklist
        @unknown default: throw IsiXPluginError.invalidValue("This application does not know the query level \(query.level.rawValue).")
        }
        let keys: [PluginQueryKeys.Key]
        do {
            keys = try PluginQueryKeys.identifier(level: level, filters: .init(
                patientName: query.patientName, patientID: query.patientID, accessionNumber: query.accessionNumber,
                studyInstanceUID: query.studyInstanceUID, modality: query.modality, description: query.description,
                dateFrom: query.dateFrom, dateTo: query.dateTo, scheduledStationAETitle: query.scheduledStationAETitle))
        } catch .seriesNeedStudy {
            throw IsiXPluginError.invalidValue("A query of series names their study.")
        } catch .invalidFilter(let value) {
            throw IsiXPluginError.invalidValue("\"\(value)\" cannot be a query filter: it holds a backslash or a control character.")
        }
        let identifier = IsiXDCMTKDataset()
        let sequence = PluginQueryKeys.scheduledProcedureStepSequence.rawValue
        do {
            if PluginQueryKeys.needsUTF8(keys) {
                try identifier.putValue(Data("ISO_IR 192".utf8), forTag: DICOMTag.specificCharacterSet.rawValue)
            }
            for key in keys {
                let value = key.value.isEmpty ? nil : Data(key.value.utf8)
                if key.inScheduledStep {
                    try identifier.putValue(value, forTag: key.tag.rawValue, inItemOfSequence: sequence)
                } else if let value {
                    try identifier.putValue(value, forTag: key.tag.rawValue)
                } else {
                    try identifier.insertEmptyElement(withTag: key.tag.rawValue)
                }
            }
        } catch {
            throw IsiXPluginError.hostFailure("The query could not be written: \(error.localizedDescription)")
        }
        let matches = try PluginCFind.run(entry: entry, abstractSyntax: PluginQueryKeys.abstractSyntax(for: level), identifier: identifier)
        return matches.map { dataset in
            let encoding = PluginCFind.encoding(of: dataset)
            var values: [String: String] = [:]
            for key in keys {
                let raw = key.inScheduledStep ? dataset.stringValues(forTag: key.tag.rawValue, inItemsOfSequence: sequence).first
                    : dataset.stringArrayValue(forTag: key.tag.rawValue)
                guard let raw else { continue }
                let text = String(data: raw, encoding: encoding) ?? String(decoding: raw, as: UTF8.self)
                if !text.isEmpty { values[key.keyword] = text }
            }
            return IsiXQueryMatch(level: query.level, values: values)
        }
    }

    // MARK: XML-RPC

    func xmlRPCMethodNameIsAvailable(_ name: String) -> Bool {
        guard XMLRPCMethodTable.selector(forMethodName: name) == nil else { return false }
        return !runtimes.contains { $0.xmlRPCMethodNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
    }

    /// What a plugin answered for an XML-RPC call.
    enum XMLRPCOutcome: Sendable {
        case answer(IsiXXMLRPCValue)
        case fault(String)
    }

    /// The answer of the plugin that registered `methodName`, on the main
    /// thread; nil when no plugin did. Called by the XML-RPC interface on its
    /// connection's thread, after the access settings let the request in.
    nonisolated static func answerXMLRPC(_ methodName: String, parameters: [Any]) -> XMLRPCOutcome? {
        let values = parameters.map(IsiXXMLRPCCoding.value(of:))
        return onMainActorSync {
            for runtime in IsiXPluginHost.shared.runtimes where runtime.xmlRPCMethodNames.contains(methodName) {
                // Inside the exception guard, as a command: an exception that
                // escapes the plugin is the caller's fault, not a crash.
                var answer: IsiXXMLRPCValue?
                var thrown: (any Error)?
                do {
                    try IsiXPluginExceptionGuard.perform {
                        do { answer = try runtime.callXMLRPCMethod(named: methodName, parameters: values) } catch { thrown = error }
                    }
                } catch {
                    thrown = IsiXPluginException(error as NSError)
                }
                if let thrown {
                    NSLog("IsiX plugin %@ XML-RPC method %@ failed: %@", runtime.info.identifier, methodName, String(describing: thrown))
                    return .fault(thrown is IsiXPluginException ? "The plugin raised \(thrown)." : IsiXUserMessage(for: thrown))
                }
                if let answer { return .answer(answer) }
            }
            return nil
        }
    }

    // MARK: database events

    /// OsirixAddToDB and OsirixAddToDBComplete of the main database, as
    /// `imagesAdded`; the images are copied, never handed out. An independent
    /// database's notifications are posted again by the main one.
    func deliverImagesAdded(_ note: Notification, complete: Bool) {
        guard let database = note.object as? DicomDatabase, database.isMainDatabase() else { return }
        let images = ((note.userInfo?[OsirixAddToDBNotificationImagesArray] as? NSArray) ?? []).compactMap { $0 as? DicomImage }
        guard !images.isEmpty else { return }
        var byTitle: [String: [String]] = [:]
        for case let (title as String, objects as NSArray) in (note.userInfo?[OsirixAddToDBNotificationImagesPerAETDictionary] as? NSDictionary) ?? [:] {
            byTitle[title] = objects.compactMap { ($0 as? DicomImage)?.sopInstanceUID() }
        }
        let added = IsiXImagesAdded(images: images.compactMap(Self.image), sopInstanceUIDsByCallingAETitle: byTitle, isComplete: complete)
        for runtime in runtimes { runtime.deliver(.imagesAdded(added)) }
    }
}

/// XML-RPC values between the interface's Cocoa objects and the plugin API.
enum IsiXXMLRPCCoding {
    static func value(of object: Any) -> IsiXXMLRPCValue {
        switch object {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            let type = String(cString: number.objCType)
            return type == "d" || type == "f" ? .double(number.doubleValue) : .int(number.intValue)
        case let string as String: return .string(string)
        case let date as Date: return .date(date)
        case let data as Data: return .data(data)
        case let array as [Any]: return .array(array.map(value(of:)))
        case let dictionary as [AnyHashable: Any]:
            return .structure(Dictionary(dictionary.map { ("\($0.key)", value(of: $0.value)) }, uniquingKeysWith: { first, _ in first }))
        default: return .string(String(describing: object))
        }
    }

    static func object(of value: IsiXXMLRPCValue) -> Any {
        switch value {
        case .string(let string): return string as NSString
        case .int(let int): return NSNumber(value: int)
        case .double(let double): return NSNumber(value: double)
        case .bool(let bool): return NSNumber(value: bool)
        case .date(let date): return date as NSDate
        case .data(let data): return data as NSData
        case .array(let array): return array.map(object(of:)) as NSArray
        case .structure(let members): return members.mapValues(object(of:)) as NSDictionary
        @unknown default: return NSNull()
        }
    }
}

/// One C-FIND of a plugin: an association with the node of `entry`, with its
/// TLS settings, the request, and the release.
enum PluginCFind {
    static func run(entry: [String: Any], abstractSyntax: String, identifier: IsiXDCMTKDataset) throws -> [IsiXDCMTKDataset] {
        let settings = DICOMAssociationSettings(extraParameters: entry)
        let host = (entry["Address"] as? String) ?? ""
        let called = (entry["AETitle"] as? String) ?? ""
        let port = Int32(truncatingIfNeeded: (entry["Port"] as? NSNumber)?.intValue ?? ((entry["Port"] as? NSString)?.integerValue ?? 0))
        let uniqueStringID = "\(getpid()).plugin.\(UUID().uuidString)"
        let parameters = IsiXDCMTKAssociationParameters()
        parameters.callingAETitle = UserDefaults.defaultAETitle()
        parameters.calledAETitle = called
        parameters.peerHost = host
        parameters.peerPort = port
        parameters.abstractSyntax = abstractSyntax
        parameters.acseTimeout = settings.acseTimeout
        parameters.dimseTimeout = settings.dimseTimeout
        parameters.connectionTimeout = UserDefaults.standard.integer(forKey: "DICOMConnectionTimeout")
        parameters.reportsFailures = true
        if settings.secureConnection {
            settings.prepareSecureTransport(parameters, host: host, port: port, aeTitle: called, uniqueStringID: uniqueStringID)
        }
        defer {
            if settings.secureConnection {
                DICOMAssociationSettings.removeSecureTransportFiles(host: host, port: port, aeTitle: called, uniqueStringID: uniqueStringID)
            }
        }
        let association: IsiXDCMTKAssociation
        do {
            association = try IsiXDCMTKAssociation(parameters: parameters)
        } catch {
            throw IsiXPluginError.networkFailure("The association with \(called) could not be prepared: \(error.localizedDescription)")
        }
        defer { _ = association.invalidate() }
        var condition = association.request()
        if condition == nil && !association.hasAssociation { condition = IsiXDCMTKError.error(for: .illegalParameter) }
        if let failure = condition {
            let what = failure.conditionKind == .associationRejected ? "Association Rejected : " : "Association Request Failed : "
            throw IsiXPluginError.networkFailure(NetworkDiagnosis.explainFailure(toHost: host, port: Int(port),
                                                                                 condition: what + failure.conditionDescription))
        }
        guard association.acceptsAbstractSyntax(abstractSyntax) else {
            _ = association.releaseAssociation()
            let service = abstractSyntax == PluginQueryKeys.worklistAbstractSyntax ? "the modality worklist" : "queries"
            throw IsiXPluginError.networkFailure("\(called) does not answer \(service): it accepted no presentation context for it.")
        }
        var matches: [IsiXDCMTKDataset] = []
        let result = association.find(withIdentifier: identifier, abstractSyntax: abstractSyntax) { matches.append($0) }
        if let failure = result.condition {
            _ = association.closeTransportConnection()
            throw IsiXPluginError.networkFailure("The C-FIND on \(called) failed: \(failure.conditionDescription)")
        }
        _ = association.releaseAssociation()
        guard result.status == 0x0000 else {
            throw IsiXPluginError.networkFailure("\(called) answered the C-FIND with \(result.statusText)"
                                                 + (result.statusDetail.map { ": \($0)" } ?? "."))
        }
        return matches
    }

    /// The encoding of a match's text, from its Specific Character Set: the
    /// first one named, Latin-1 when none is.
    static func encoding(of dataset: IsiXDCMTKDataset) -> String.Encoding {
        guard let raw = dataset.stringArrayValue(forTag: DICOMTag.specificCharacterSet.rawValue),
              let name = String(decoding: raw, as: UTF8.self).components(separatedBy: "\\").first(where: { !$0.isEmpty }) else {
            return .isoLatin1
        }
        return String.Encoding(rawValue: NSString.encoding(forDICOMCharacterSet: name))
    }
}
