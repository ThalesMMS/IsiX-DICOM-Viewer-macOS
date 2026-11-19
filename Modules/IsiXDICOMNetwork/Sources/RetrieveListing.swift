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

/// How the listing a DIMSE retrieve makes of a node's instances, before its
/// transfer, ended. The inventory keeps it, as it keeps where the listing of a
/// DICOMweb retrieve stands, and the manifest writes its raw value.
///
/// A node need not answer a C-FIND at the SERIES or IMAGE level to send a
/// study: some answer the STUDY level alone. A listing such a node refused, or
/// answered without naming anything, says nothing of what the study holds, and
/// nothing against the transfer either: the retrieve is then judged by what the
/// node counted of its own sub-operations. A listing that failed is another
/// matter: the node may well list its instances, and was not heard.
public enum RetrieveListing: String, Sendable, CaseIterable {
    /// Every level answered and named its instances.
    case confirmed
    /// The association, the network or the node failed, or an instance came
    /// without its UID or series: what the study holds is not known.
    case failed
    /// The node answered the C-FIND of a level with a status that refuses it.
    case notImplemented = "not implemented"
    /// Every C-FIND ended in success and none named an instance.
    case empty
    /// The retrieve was cancelled while it listed.
    case cancelled

    /// Whether the status a node ended a C-FIND with refuses the request
    /// itself, as a node that does not answer that level does, rather than
    /// reporting a failure of the moment:
    /// - 0x0122 SOP class not supported, 0x0118 no such SOP class, 0x0211
    ///   unrecognized operation, 0x0124 not authorized;
    /// - 0xA900 identifier does not match SOP class, which is what a node
    ///   answers to keys or to a level it does not take;
    /// - 0xC000 to 0xCFFF unable to process, the only other failure the Query
    ///   service defines, and the one a node gives when it has nothing that
    ///   handles the request.
    ///
    /// Out of resources (0xA700) is not one: the same request may be answered
    /// the next time. Neither is a cancellation (0xFE00), nor a status the
    /// service does not define.
    public static func refuses(findStatus status: UInt16) -> Bool {
        switch status {
        case 0x0122, 0x0118, 0x0211, 0x0124, 0xA900: true
        case 0xC000...0xCFFF: true
        default: false
        }
    }

    /// How a listing made before the transfer ended: `listed` instances with
    /// their UID and series, `confirmed` when no C-FIND failed and no instance
    /// lacked one, `refused` when a C-FIND ended in a status that refuses it,
    /// `failedOtherwise` when one failed in any other way.
    ///
    /// A failure of any other kind outweighs a refusal: the levels that did
    /// not answer might have named instances.
    public static func beforeTransfer(listed: Int, confirmed: Bool, refused: Bool, failedOtherwise: Bool,
                                      cancelled: Bool) -> RetrieveListing {
        if cancelled { return .cancelled }
        if failedOtherwise { return .failed }
        if refused { return .notImplemented }
        if listed == 0 { return .empty }
        return confirmed ? .confirmed : .failed
    }

    /// Whether the listing, having named no instance, leaves the retrieve to
    /// be judged by the node's own counters.
    var leavesTheCountersToJudge: Bool { self == .notImplemented || self == .empty }

    /// A DIMSE status as the log and the notices write it: 0xA900.
    public static func text(ofStatus status: Int) -> String {
        let digits = String(max(status, 0), radix: 16, uppercase: true)
        return "0x" + String(repeating: "0", count: max(0, 4 - digits.count)) + digits
    }
}

/// How a retrieve was judged when the node's listing named no instance: by
/// what the node counted of its sub-operations, all of which arrived here and
/// are in the index. Written in the manifest, so that who reads it knows the
/// completeness is the node's word and not an inventory.
struct RetrieveCountersVerdict: Codable, Sendable, Equatable {
    var judgedBy = "peer counters"
    /// The C-MOVE and C-GET operations of the attempt, all ended in success.
    var operations: Int
    /// The sub-operations the node counted as completed, over them all.
    var completed: Int
    /// The stores of the attempt that arrived here.
    var received: Int
    /// The instances of the study, or series, in the index when it was judged.
    var indexed: Int
    /// What the node said the study, or series, holds; 0 when it did not say.
    var reported: Int
}
