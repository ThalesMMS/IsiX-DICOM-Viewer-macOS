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

/// One instance a node listed for a retrieve, as the IMAGE level gave it.
public struct RetrieveListedInstance: Hashable, Sendable {
    /// Its SOP Instance UID; empty when the node gave none.
    public var sopInstanceUID: String
    /// Its Series Instance UID; empty when the node gave none.
    public var seriesInstanceUID: String
    /// Its SOP Class UID, when the node gave one.
    public var sopClassUID: String?
    /// Its Instance Number as the node wrote it, when it gave one.
    public var instanceNumber: String?
    /// False for an instance of a class this retrieve does not offer to
    /// receive: it cannot arrive.
    public var offered: Bool

    public init(sopInstanceUID: String, seriesInstanceUID: String, sopClassUID: String? = nil,
                instanceNumber: String? = nil, offered: Bool = true) {
        self.sopInstanceUID = sopInstanceUID
        self.seriesInstanceUID = seriesInstanceUID
        self.sopClassUID = sopClassUID
        self.instanceNumber = instanceNumber
        self.offered = offered
    }
}

/// What a retrieve inventory keeps on disk, in RetrieveManifests of the
/// database folder: the names and the shape of the manifests written before,
/// which are read back as they are. A field added later is optional, so an
/// older manifest still reads.
struct RetrieveInventoryRecord: Codable, Sendable, Equatable {
    var version = 1
    var study: String
    var series: String
    var expected: [String: String]
    var inventoryConfirmed: Bool
    var received: [String: Int] = [:]
    var rejected: [String: [Int]] = [:]
    var storageWarnings: [String: [Int]]? = [:]
    var httpRejected: Set<String>? = []
    /// Instances not fetched because the WADO server's certificate was not
    /// trusted, with the reason given. Cleared for an instance once it arrives.
    var tlsUntrusted: [String: String]? = [:]
    var peerResponses: [[String: String]]? = []
    var peerFailed: Set<String>? = []
    var imported: Set<String> = []
    var duplicateInventory: Set<String> = []
    var queried: Date? = Date()
    var updated = Date()
    /// What the peer said it holds when the inventory was queried: its
    /// NumberOf{Study,Series}RelatedInstances, 0 when it did not say.
    var reported: Int? = 0
    /// Per series, what the peer said it holds and how many instances it listed.
    var seriesReported: [String: Int]? = [:]
    var seriesListed: [String: Int]? = [:]
    /// Each listed instance's SOP class, when the IMAGE level gave it.
    var sopClasses: [String: String]? = [:]
    /// Listed instances of classes this retrieve does not offer to receive: they cannot
    /// arrive, and a retrieve that is not forced does not ask for them.
    var unoffered: Set<String>? = []
    /// Where the listing of the peer's instances stands when the transfer
    /// starts before it ends: in progress, confirmed, failed or cancelled;
    /// or not supported, when the node does not implement it and what was
    /// asked for was retrieved whole, without error.
    var discovery: String? = nil
    /// Series the node's rules left out of the last attempt, by UID: their
    /// description and the rule. An intentional exclusion, not a failure.
    var excluded: [String: [String]]? = nil
    /// Objects received under a SOP Instance UID the listing does not
    /// name, by UID: the SOP Instance UIDs their Source Image Sequence
    /// names. A server that converts an object to a lossy syntax may give
    /// the copy a new UID, as Orthanc does, and name the original there.
    var derived: [String: [String]]? = nil
    /// Each listed instance's Instance Number, when the IMAGE level gave one.
    var numbers: [String: Int]? = nil
    /// Objects received under a SOP Instance UID the listing does not
    /// name, in a lossy syntax that was asked for, with no Source Image
    /// Sequence, by UID: their series, SOP class and Instance Number. Not
    /// yet matched to a listed instance; once matched, they move to
    /// `derived`.
    var unreferenced: [String: [String]]? = nil
}
