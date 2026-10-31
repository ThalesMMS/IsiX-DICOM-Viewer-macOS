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

/// One DICOM send: where the files go, which files, one batch per patient,
/// and how they are sent. A value, made where the files were chosen and
/// handed to `DICOMSendQueue`, which never reaches back for anything else.
public struct DICOMSendRequest: Sendable, Hashable {
    /// The files of one patient, sent after the batch before it.
    public struct Batch: Sendable, Hashable {
        /// The patient's name, as the activity names the send; nil when the
        /// study has none.
        public var patientName: String?
        /// The files, in the order they are sent, each once.
        public var files: [String]

        public init(patientName: String?, files: [String]) {
            self.patientName = patientName
            self.files = files
        }
    }

    /// The node the files go to, its stored entry whole: a DIMSE node of
    /// Locations, or the entry the Send sheet lists for a DICOMweb node. The
    /// association reads its TLS settings from the same entry.
    public var destination: DICOMNode
    public var batches: [Batch]
    /// The transfer syntax setting of the send (the codes of the Send sheet,
    /// `StoreSendSyntax`).
    public var transferSyntax: Int
    /// The compression the association is given; the deflate level of a
    /// deflated syntax.
    public var compression: Float
    public var route: DICOMSendRoute
    public var options: DICOMSendOptions

    public init(destination: DICOMNode, batches: [Batch], transferSyntax: Int, compression: Float = 1,
                route: DICOMSendRoute = .cStore, options: DICOMSendOptions = DICOMSendOptions()) {
        self.destination = destination
        self.batches = batches
        self.transferSyntax = transferSyntax
        self.compression = compression
        self.route = route
        self.options = options
    }

    /// The files of every batch, in order.
    public var fileCount: Int {
        batches.reduce(0) { $0 + $1.files.count }
    }

    /// The files of every batch, in order, each once: what a send that is not
    /// made per patient (STOW-RS, the direct transfer of a peer) sends.
    public var allFiles: [String] {
        DICOMSendSelection.unique(batches.flatMap(\.files))
    }

    /// The associations a batch is sent over, each with a part of its files
    /// in order: as many parts as `options.associationsPerBatch`, the first
    /// ones of the same length (the count divided by the parts, rounded up)
    /// and the last with the rest. Fewer when the files run out first.
    public func parts(of batch: Batch) -> [DICOMStorePart] {
        let count = batch.files.count
        let associations = options.associationsPerBatch
        let length = Int(ceil(Double(Float(count) / Float(associations))))
        var parts: [DICOMStorePart] = []
        var location = 0
        repeat {
            var partLength = length
            if parts.count == Int(associations) - 1 {
                partLength = count - location
            }
            if location + partLength > count {
                partLength = count - location
            }
            if partLength > 0 {
                parts.append(DICOMStorePart(destination: destination, files: Array(batch.files[location..<location + partLength]),
                                            transferSyntax: transferSyntax, compression: compression,
                                            callingAETitle: options.callingAETitle, patientName: batch.patientName))
                location += partLength
            }
        } while location < count
        return parts
    }
}

/// How a send reaches its destination.
public enum DICOMSendRoute: Sendable, Hashable {
    /// C-STORE, each batch over its associations.
    case cStore
    /// STOW-RS of every file to a DICOMweb node, never C-STORE.
    case dicomweb
    /// The direct transfer of a Horos peer that gave this app its token, then
    /// C-STORE when the peer cannot be reached that way.
    case directTransferFirst
}

/// The settings a send is made with, read where the request is made.
public struct DICOMSendOptions: Sendable, Hashable {
    /// The AE title of this end.
    public var callingAETitle: String?
    /// The associations each batch is split over; at least one.
    public var associationsPerBatch: UInt32
    /// How many sends may run at once in the process: a send starts when none
    /// runs, or when it makes fewer than this many.
    public var mostConcurrentSends: Int

    public init(callingAETitle: String? = nil, associationsPerBatch: UInt32 = 1, mostConcurrentSends: Int = 4) {
        self.callingAETitle = callingAETitle
        self.associationsPerBatch = max(associationsPerBatch, 1)
        self.mostConcurrentSends = mostConcurrentSends
    }

    /// The associations per batch the send settings ask for: the requested
    /// number, as an unsigned 32-bit count, at most `maximum` when that is
    /// lower, and one when that leaves none.
    public static func associationsPerBatch(requested: Int, maximum: Int) -> UInt32 {
        var associations = UInt32(truncatingIfNeeded: requested)
        if Int(associations) > maximum {
            associations = UInt32(truncatingIfNeeded: maximum)
        }
        return associations == 0 ? 1 : associations
    }
}

/// What one association sends: part of a batch, to the request's destination.
public struct DICOMStorePart: Sendable, Hashable {
    public var destination: DICOMNode
    public var files: [String]
    public var transferSyntax: Int
    public var compression: Float
    public var callingAETitle: String?
    public var patientName: String?

    public init(destination: DICOMNode, files: [String], transferSyntax: Int, compression: Float,
                callingAETitle: String?, patientName: String?) {
        self.destination = destination
        self.files = files
        self.transferSyntax = transferSyntax
        self.compression = compression
        self.callingAETitle = callingAETitle
        self.patientName = patientName
    }

    /// The port of the destination as the association takes it.
    public var port: Int32 {
        destination.associationPort
    }
}
