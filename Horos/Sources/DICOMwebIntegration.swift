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

// MARK: - Sources and destinations

/// DICOMweb nodes where the Query/Retrieve window and the Send sheet list
/// DICOM nodes (#799).
///
/// Those windows work with server dictionaries, as `DCMNetServiceDelegate`
/// gives them for the DIMSE nodes in `SERVERS`. A DICOMweb node is given to
/// them as a dictionary of the same shape, made here from `DICOMWEB_SERVERS`
/// and never stored in `SERVERS`: `DICOMwebNode` names the node by its
/// identifier, `Description` is its name, `Address` its address, `AETitle`
/// says "DICOMweb" in the AE Title column, and `retrieveMode` is the former
/// DICOMweb mode, which needs no listener. Everything else a request needs,
/// paths, syntaxes and credential, is read from the node when the request is
/// made, so an edit in Locations applies to the next one.
@objc(HorosDICOMwebSources)
public final class DICOMwebSources: NSObject {
    /// The key that marks a server dictionary as a DICOMweb node's.
    @objc public static let nodeKey = "DICOMwebNode"
    /// What the AE Title column and the Send sheet show for a DICOMweb node.
    @objc public static let title = "DICOMweb"
    /// The retrieve mode of DCMNetServiceDelegate.h that a DICOMweb node is given.
    static let retrieveMode = 3

    /// The server dictionary of a node.
    @objc(serverForNode:)
    public static func server(for node: DICOMwebNode) -> [String: Any] {
        [nodeKey: node.identifier, "Description": node.name, "AETitle": title, "Address": node.address,
         "QR": node.queryRetrieve, "Send": node.send, "Activated": true, "retrieveMode": retrieveMode]
    }

    /// The valid nodes with Q&R on, as the Query/Retrieve window lists its sources.
    public static func queryRetrieveServers(in defaults: UserDefaults) -> [[String: Any]] {
        DICOMwebNode.queryRetrieveNodes(in: defaults).map(server(for:))
    }

    @objc public static func queryRetrieveServers() -> [[String: Any]] { queryRetrieveServers(in: .standard) }

    /// The valid nodes with Send on, as the Send sheet lists its destinations.
    public static func sendDestinations(in defaults: UserDefaults) -> [[String: Any]] {
        DICOMwebNode.sendNodes(in: defaults).map(server(for:))
    }

    @objc public static func sendDestinations() -> [[String: Any]] { sendDestinations(in: .standard) }

    /// Whether a server dictionary is a DICOMweb node's. A `SERVERS` entry
    /// is never one, whatever its retrieve mode says.
    @objc(isDICOMwebServer:)
    public static func isDICOMwebServer(_ server: [AnyHashable: Any]?) -> Bool {
        guard let identifier = server?[nodeKey] as? String else { return false }
        return !identifier.isEmpty
    }

    /// The node a server dictionary names, as it is stored now.
    public static func node(forServer server: [AnyHashable: Any]?, in defaults: UserDefaults) -> DICOMwebNode? {
        guard isDICOMwebServer(server), let identifier = server?[nodeKey] as? String else { return nil }
        return DICOMwebNode.node(withIdentifier: identifier, in: defaults)
    }

    @objc(nodeForServer:)
    public static func node(forServer server: [AnyHashable: Any]?) -> DICOMwebNode? { node(forServer: server, in: .standard) }

    /// Where the client sends a node's requests: its address, QIDO and WADO
    /// paths, credential and Retrieve Syntax.
    @objc(configurationForNode:error:)
    public static func configuration(for node: DICOMwebNode) throws -> DICOMwebNodeConfiguration {
        do { try node.validate() } catch {
            throw DICOMwebClient.failure(1, (error as NSError).localizedDescription, kind: .configuration)
        }
        return try DICOMwebNodeConfiguration(address: node.address, qidoPath: node.qidoPath, wadoPath: node.wadoPath,
                                             credentialIdentifier: node.credentialIdentifier,
                                             retrieveTransferSyntax: node.retrieveSyntax)
    }

    /// A client for the node a server dictionary names.
    public static func client(forServer server: [AnyHashable: Any]?, timeout: TimeInterval,
                              in defaults: UserDefaults) throws -> DICOMwebClient {
        guard let node = node(forServer: server, in: defaults) else {
            throw DICOMwebClient.failure(1, NSLocalizedString("This DICOMweb node is no longer in Locations.", comment: ""),
                                         kind: .configuration)
        }
        return DICOMwebClient(node: try configuration(for: node), timeout: timeout)
    }

    @objc(clientForServer:timeout:error:)
    public static func client(forServer server: [AnyHashable: Any]?, timeout: TimeInterval) throws -> DICOMwebClient {
        try client(forServer: server, timeout: timeout, in: .standard)
    }

    /// What the Query/Retrieve window shows in its Address column: the node's address.
    @objc(addressForServer:)
    public static func address(forServer server: [AnyHashable: Any]?) -> String {
        (server?["Address"] as? String) ?? title
    }

    /// The endpoint a retrieve inventory is kept under: the WADO-RS base URL,
    /// the node's address for a node without a WADO path, as the pilot kept it.
    public static func inventoryEndpoint(forServer server: [AnyHashable: Any]?, in defaults: UserDefaults) -> String {
        if let node = node(forServer: server, in: defaults), !node.wadoEndpoint.isEmpty { return node.wadoEndpoint }
        return address(forServer: server)
    }

    @objc(inventoryEndpointForServer:)
    public static func inventoryEndpoint(forServer server: [AnyHashable: Any]?) -> String {
        inventoryEndpoint(forServer: server, in: .standard)
    }

    /// Where the Send sheet says the files go: {address}/studies.
    public static func storeURL(forServer server: [AnyHashable: Any]?, in defaults: UserDefaults) -> String {
        guard let node = node(forServer: server, in: defaults), !node.stowEndpoint.isEmpty else { return address(forServer: server) }
        return node.stowEndpoint + "/studies"
    }

    @objc(storeURLForServer:)
    public static func storeURL(forServer server: [AnyHashable: Any]?) -> String { storeURL(forServer: server, in: .standard) }
}

// MARK: - Verification messages

/// What Locations' Test says when a DICOMweb node does not answer (#799): a
/// message per kind of failure, so a wrong path, a refused credential, a
/// certificate and a network problem are told apart.
@objc(HorosDICOMwebVerification)
public final class DICOMwebVerification: NSObject {
    @objc(messageForError:)
    public static func message(for error: NSError?) -> String {
        guard let error else { return "" }
        switch DICOMwebClient.errorKind(for: error) {
        case .none:
            return ""
        case .network:
            return NSLocalizedString("The DICOMweb node could not be reached. Check the address, that the server is running and the network.", comment: "")
        case .authentication:
            return String(format: NSLocalizedString("The DICOMweb node refused the credentials (HTTP %ld). Check the node's authentication.", comment: ""),
                          error.code == 403 ? 403 : 401)
        case .notFound:
            return NSLocalizedString("The DICOMweb node has nothing at the QIDO path (HTTP 404). Check the address and the QIDO path.", comment: "")
        case .tls:
            return NSLocalizedString("The secure connection to the DICOMweb node failed. Check its HTTPS certificate.", comment: "")
        case .timeout:
            return NSLocalizedString("The DICOMweb node did not answer in time.", comment: "")
        case .redirect:
            return NSLocalizedString("The DICOMweb node answered with a redirect, which is not followed. Enter the address it redirects to.", comment: "")
        case .credentials:
            return NSLocalizedString("The node's credential could not be read from the Keychain. Set its authentication again.", comment: "")
        case .http:
            return String(format: NSLocalizedString("The DICOMweb node answered HTTP %ld to the test query.", comment: ""), error.code)
        case .invalidResponse:
            return NSLocalizedString("The DICOMweb node did not answer as a QIDO-RS service. Check the address and the QIDO path.", comment: "")
        case .configuration:
            return error.localizedDescription
        case .cancelled:
            return NSLocalizedString("The test was cancelled.", comment: "")
        }
    }
}

// MARK: - Send

/// What a STOW-RS send did, per instance.
@objc(HorosDICOMwebSendReport)
public final class DICOMwebSendReport: NSObject {
    /// One per file given to the send, in its order, with the file's own path.
    @objc public let results: [DICOMwebStoreResult]
    /// The send stopped because it was cancelled.
    @objc public let cancelled: Bool

    init(results: [DICOMwebStoreResult], cancelled: Bool) {
        self.results = results
        self.cancelled = cancelled
        super.init()
    }

    @objc public var sentCount: Int { results.filter { $0.status != .failure }.count }
    @objc public var warningCount: Int { results.filter { $0.status == .warning }.count }
    @objc public var failedCount: Int { results.filter { $0.status == .failure }.count }
    @objc public var isComplete: Bool { !cancelled && failedCount == 0 }

    /// One line: how many were stored, with warnings, and not stored.
    @objc public var summary: String {
        var text = String(format: NSLocalizedString("%ld of %ld instances stored.", comment: "DICOMweb send"), sentCount, results.count)
        if warningCount > 0 {
            text += " " + String(format: NSLocalizedString("%ld with warnings.", comment: "DICOMweb send"), warningCount)
        }
        if failedCount > 0 {
            text += " " + String(format: NSLocalizedString("%ld not stored.", comment: "DICOMweb send"), failedCount)
        }
        if cancelled { text += " " + NSLocalizedString("The send was cancelled.", comment: "") }
        return text
    }

    /// The summary, then a line per instance that was not stored or was
    /// stored with a warning: its SOP Instance UID (or file name) and why.
    @objc(detailWithLimit:)
    public func detail(limit: Int) -> String {
        let notable = results.filter { $0.status != .success }
        let shown = notable.prefix(max(limit, 0))
        var lines = [summary]
        for result in shown {
            let name = result.sopInstanceUID.isEmpty ? (result.path as NSString).lastPathComponent : result.sopInstanceUID
            let reason = result.reason.isEmpty ? NSLocalizedString("stored with a warning", comment: "DICOMweb send") : result.reason
            lines.append("  " + name + ": " + reason)
        }
        if notable.count > shown.count {
            lines.append("  " + String(format: NSLocalizedString("… and %ld more", comment: "DICOMweb send"), notable.count - shown.count))
        }
        return lines.joined(separator: "\n")
    }
}

/// Sends files to a DICOMweb node by STOW-RS (#799), off the main thread.
///
/// With a Send Syntax other than "As stored", each file whose transfer syntax
/// differs is first written in that syntax by `transcoder` (DCMTK in the
/// application) into a temporary folder of this send's own, removed when it
/// ends whatever happened. A file that cannot be converted is not sent and is
/// reported as not stored; the others go on. The client sends in batches
/// streamed from disk, and reports each instance.
@objc(HorosDICOMwebSender)
public final class DICOMwebSender: NSObject {
    /// Writes `source` in `transferSyntax` at `destination`, or throws.
    public typealias Transcoder = (_ source: String, _ destination: String, _ transferSyntax: String) throws -> Void

    @objc public let node: DICOMwebNode
    private let transcoder: Transcoder
    /// Called on the sending thread with a status line and the fraction done.
    public var progress: ((String, Double) -> Void)?
    /// The seconds a request may wait for an answer.
    public var timeout: TimeInterval = 60
    /// Where the temporary folders go; the system's temporary folder by default.
    var temporaryRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

    public init(node: DICOMwebNode, transcoder: @escaping Transcoder) {
        self.node = node
        self.transcoder = transcoder
        super.init()
    }

    /// Whether a file in `original` must be converted before it is sent to a
    /// node whose Send Syntax is `target`. "As stored" never converts; a file
    /// whose syntax cannot be read is converted, and DCMTK decides.
    @objc(needsTranscodingFromSyntax:toSyntax:)
    public static func needsTranscoding(from original: String?, to target: String) -> Bool {
        let wanted = target.trimmingCharacters(in: .whitespaces)
        if wanted.isEmpty || wanted == DICOMwebNode.asStored { return false }
        guard let original, !original.isEmpty else { return true }
        return original != wanted
    }

    /// The transfer syntax a Part 10 file declares, or nil.
    static func transferSyntax(ofFile path: String) -> String? {
        DICOMwebClient.fileMeta(URL(fileURLWithPath: path))?.meta.transferSyntaxUID
    }

    /// Sends `files` and reports every one of them. Throws only when nothing
    /// could be tried: an invalid node, or no files.
    public func send(files: [String], cancelled: () -> Bool) throws -> DICOMwebSendReport {
        let client = DICOMwebClient(node: try DICOMwebSources.configuration(for: node), timeout: timeout)
        guard !files.isEmpty else { throw DICOMwebClient.failure(1, "No files to send.", kind: .configuration) }
        let syntax = node.sendSyntax
        let converting = syntax != DICOMwebNode.asStored
        var results = [DICOMwebStoreResult?](repeating: nil, count: files.count)
        var sent: [(index: Int, path: String)] = []

        var folder: URL?
        defer { if let folder { try? FileManager.default.removeItem(at: folder) } }
        if converting {
            let made = temporaryRoot.appendingPathComponent("horos-dicomweb-send-" + UUID().uuidString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            } catch {
                throw DICOMwebClient.failure(5, NSLocalizedString("A temporary folder for the converted files could not be created.", comment: ""),
                                             kind: .configuration)
            }
            folder = made
        }
        let target = DICOMwebNode.title(forTransferSyntax: syntax)
        for (index, path) in files.enumerated() {
            if cancelled() { break }
            guard let folder, DICOMwebSender.needsTranscoding(from: DICOMwebSender.transferSyntax(ofFile: path), to: syntax) else {
                sent.append((index, path)); continue
            }
            progress?(String(format: NSLocalizedString("Converting to %@: %ld of %ld", comment: "DICOMweb send"), target, index + 1, files.count),
                      Double(index) / Double(files.count) * 0.5)
            let converted = folder.appendingPathComponent("\(index).dcm").path
            do {
                try autoreleasepool { try transcoder(path, converted, syntax) }
                guard DICOMwebSender.transferSyntax(ofFile: converted) == syntax else {
                    throw DICOMwebClient.failure(4, "The converted file does not declare the Send Syntax.")
                }
                sent.append((index, converted))
            } catch {
                try? FileManager.default.removeItem(atPath: converted)
                let uid = DICOMwebClient.fileMeta(URL(fileURLWithPath: path))?.meta.mediaStorageSOPInstanceUID ?? ""
                results[index] = DICOMwebStoreResult(path: path, sopInstanceUID: uid, status: .failure,
                    reason: String(format: NSLocalizedString("Not sent: it could not be converted to %@.", comment: "DICOMweb send"), target))
            }
        }
        var stopped = cancelled()
        if !sent.isEmpty && !stopped {
            let total = files.count
            let before = files.count - sent.count
            let share = converting ? 0.5 : 0.0
            client.storeProgress = { [weak self] done, count in
                let fraction = share + (1 - share) * Double(done) / Double(max(count, 1))
                self?.progress?(String(format: NSLocalizedString("DICOMweb: %ld of %ld instances sent", comment: ""), before + done, total), fraction)
            }
            progress?(String(format: NSLocalizedString("DICOMweb: %ld of %ld instances sent", comment: ""), before, total), share)
            let stored = try client.store(files: sent.map(\.path), cancelled: cancelled)
            for (position, item) in sent.enumerated() {
                let result = stored[position]
                results[item.index] = DICOMwebStoreResult(path: files[item.index], sopInstanceUID: result.sopInstanceUID,
                    status: result.status, reason: result.reason, reasonCode: result.reasonCode, httpStatus: result.httpStatus)
            }
            stopped = cancelled()
        }
        // Whatever was not tried because the send was cancelled.
        for index in files.indices where results[index] == nil {
            results[index] = DICOMwebStoreResult(path: files[index], sopInstanceUID: "", status: .failure,
                                                 reason: NSLocalizedString("Not sent: the send was cancelled.", comment: ""))
        }
        return DICOMwebSendReport(results: results.map { $0! }, cancelled: stopped)
    }
}
