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

/// The nodes a RIS request (`horos://` link or XML-RPC call) can reach.
///
/// `DCMNetServiceDelegate.DICOMServersList` lists the DIMSE nodes of
/// Locations only; DICOMweb nodes are kept apart and the Query/Retrieve window
/// appends them itself. Requests that looked a node up in that list alone
/// could never name a DICOMweb node, so `Retrieve`, `CMove` and PACS On-Demand
/// answered "server not found" for a PACS configured as DICOMweb.
@objc(HorosRISRequestServers)
public final class RISRequestServers: NSObject {
    /// Every node a request may name: the DIMSE nodes, then the DICOMweb nodes
    /// with Q&R on, in the order the Query/Retrieve window lists them.
    @objc public static func candidates() -> [[String: Any]] {
        let dimse = (DCMNetServiceDelegate.dicomServersList() ?? []).compactMap { $0 as? [String: Any] }
        return candidates(dimse: dimse, dicomweb: DICOMwebSources.queryRetrieveServers())
    }

    static func candidates(dimse: [[String: Any]], dicomweb: [[String: Any]]) -> [[String: Any]] {
        // A SERVERS entry is never a DICOMweb node, whatever it carries.
        return dimse.filter { !DICOMwebSources.isDICOMwebServer($0) } + dicomweb
    }

    /// The node a request names, or `nil`.
    @objc(serverNamed:)
    public static func server(named name: String?) -> [String: Any]? {
        return server(named: name, in: candidates())
    }

    /// The node `name` designates among `servers`.
    ///
    /// The description shown in Locations is tried first, then the AE title of
    /// a DIMSE node: a RIS is often configured with the AE title of the PACS
    /// rather than with the label given to it on this machine. A DICOMweb node
    /// has no AE title of its own (every one shows "DICOMweb"), so only its
    /// name designates it. An exact match wins over one that differs only in
    /// case or surrounding spaces.
    static func server(named name: String?, in servers: [[String: Any]]) -> [String: Any]? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        let exact: (Any?) -> Bool = { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == name }
        let folded: (Any?) -> Bool = {
            guard let value = ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
            return value.caseInsensitiveCompare(name) == .orderedSame
        }
        for matches in [exact, folded] {
            if let server = servers.first(where: { matches($0["Description"]) }) { return server }
            if let server = servers.first(where: { !DICOMwebSources.isDICOMwebServer($0) && matches($0["AETitle"]) }) {
                return server
            }
        }
        return nil
    }

    /// The nodes chosen in the PACS On-Demand preferences, as they are now.
    @objc public static func pacsOnDemandServers() -> [[String: Any]] {
        let saved = (UserDefaults.standard.array(forKey: "comparativeSearchDICOMNodes") ?? [])
            .compactMap { $0 as? [String: Any] }
        return pacsOnDemandServers(saved: saved, in: candidates())
    }

    static func pacsOnDemandServers(saved: [[String: Any]], in servers: [[String: Any]]) -> [[String: Any]] {
        var chosen: [[String: Any]] = []
        for entry in saved {
            for server in servers where matches(saved: entry, server: server) {
                chosen.append(server)
            }
        }
        return chosen
    }

    /// What the PACS On-Demand preferences show and save as a node's address.
    /// A DICOMweb node has a URL and no DIMSE port.
    @objc(addressAndPortForServer:)
    public static func addressAndPort(for server: [AnyHashable: Any]?) -> String {
        if DICOMwebSources.isDICOMwebServer(server) { return describe(server?["Address"]) }
        return describe(server?["Address"]) + ":" + describe(server?["Port"])
    }

    /// Whether an entry saved by the PACS On-Demand preferences designates
    /// `server`. A DIMSE node is recognised, as before, by its AE title, name,
    /// address and port; a DICOMweb node by its identifier, which survives a
    /// change of name or address in Locations.
    @objc(savedEntry:matchesServer:)
    public static func matches(saved entry: [AnyHashable: Any]?, server: [AnyHashable: Any]?) -> Bool {
        guard let entry = entry, let server = server else { return false }
        let savedServer = entry["server"] as? [AnyHashable: Any]
        if DICOMwebSources.isDICOMwebServer(savedServer) || DICOMwebSources.isDICOMwebServer(server) {
            guard let saved = savedServer?[DICOMwebSources.nodeKey] as? String,
                  let current = server[DICOMwebSources.nodeKey] as? String else { return false }
            return saved == current
        }
        guard let aeTitle = entry["AETitle"] as? String, let name = entry["name"] as? String,
              let address = entry["AddressAndPort"] as? String else { return false }
        return aeTitle == server["AETitle"] as? String && name == server["Description"] as? String
            && address == addressAndPort(for: server)
    }

    /// What `%@` printed for a value: its description, "(null)" for nil.
    private static func describe(_ value: Any?) -> String {
        guard let value = value else { return "(null)" }
        return String(describing: value as AnyObject)
    }
}
