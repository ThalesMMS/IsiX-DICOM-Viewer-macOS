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

/// The transfer syntax a WADO-URI request asks for, from the node's WADO
/// Transfer Syntax setting. Locations' Test and the retrieve use the same one.
public enum WADOURITransferSyntax {
    /// The query parameter for the setting `code` (a TransferSyntaxCodes value
    /// of the Send sheet), and the image quality that goes with it.
    public static func parameter(forSetting code: Int) -> (parameter: String, quality: Int) {
        let explicitLittleEndian = "1.2.840.10008.1.2.1", implicitLittleEndian = "1.2.840.10008.1.2"
        let explicitBigEndian = "1.2.840.10008.1.2.2", rle = "1.2.840.10008.1.2.5"
        let jpegLossless = "1.2.840.10008.1.2.4.70", jpegExtended = "1.2.840.10008.1.2.4.51"
        let jpeg2000Lossless = "1.2.840.10008.1.2.4.90", jpeg2000 = "1.2.840.10008.1.2.4.91"
        let jpegLSLossless = "1.2.840.10008.1.2.4.80", jpegLSLossy = "1.2.840.10008.1.2.4.81"
        let syntax: (String, Int)?
        switch code {
        case 0: syntax = (explicitLittleEndian, 100)
        case 1: syntax = (jpeg2000Lossless, 100)
        case 2: syntax = (jpeg2000, 90)
        case 3: syntax = (jpeg2000, 70)
        case 4: syntax = (jpeg2000, 50)
        case 13: syntax = (jpegLSLossless, 100)
        case 14: syntax = (jpegLSLossy, 90)
        case 15: syntax = (jpegLSLossy, 70)
        case 16: syntax = (jpegLSLossy, 50)
        case 5: syntax = (jpegLossless, 100)
        case 6: syntax = (jpegExtended, 90)
        case 7: syntax = (jpegExtended, 70)
        case 8: syntax = (jpegExtended, 50)
        case 9: syntax = (implicitLittleEndian, 100)
        case 10: syntax = (rle, 100)
        case 11: syntax = (explicitBigEndian, 100)
        default: syntax = nil
        }
        if let (uid, quality) = syntax { return ("&transferSyntax=" + uid, quality) }
        // dcm4chee-arc-light 5.24.2 recognizes *; without transferSyntax it
        // chooses Explicit VR Little Endian. useOrig stays for legacy endpoints
        // that ignore unknown query parameters. A server that reads * as a
        // syntax it lacks (400, 404, 406) is asked again with useOrig=true
        // alone: see WADOOriginalSyntax in WADODownload.swift.
        return ("&transferSyntax=*&useOrig=true", 100)
    }
}

/// The progress bar of a C-MOVE or C-GET. Pending responses and the counts
/// they carry are optional: until the peer counts its sub-operations, a
/// confirmed listing gives the fraction, of what this operation asked for, how
/// much has arrived, and the bar then never steps back.
public struct RetrieveProgress: Sendable {
    public private(set) var peerCounts = false
    public private(set) var listingShown = false
    public private(set) var shown = 0.0

    public init() {}

    /// What to show after a response (`counted`, with the peer's counts) or
    /// after a wait that brought none, or an arrival on this association
    /// (`counted` false, counts 0): the sub-operations accounted for and
    /// finished, or nil to leave the bar as it is. `arrivals` gives, when the
    /// listing is confirmed, how many of the instances asked for have arrived
    /// and how many were asked for.
    public mutating func update(counted: Bool, accounted: UInt, finished: UInt,
                                arrivals: () -> (received: UInt, asked: UInt)?) -> (accounted: UInt, finished: UInt)? {
        var accounted = accounted, finished = finished
        if accounted > 0 {
            peerCounts = true
        } else if !peerCounts, let arrived = arrivals(), arrived.received > 0, arrived.asked > 0 {
            accounted = arrived.asked
            finished = min(arrived.received, arrived.asked)
            listingShown = true
        }
        if !counted && accounted == 0 { return nil }
        let fraction = accounted > 0 ? Double(finished) / Double(accounted) : 0
        if listingShown && fraction < shown { return nil }
        shown = fraction
        return (accounted, finished)
    }

    /// The fraction a report shows: a peer that accounts for none of its
    /// sub-operations gives 0, not a division by zero.
    public static func fraction(accounted: UInt, finished: UInt) -> Double {
        accounted > 0 ? Double(finished) / Double(accounted) : 0
    }
}
