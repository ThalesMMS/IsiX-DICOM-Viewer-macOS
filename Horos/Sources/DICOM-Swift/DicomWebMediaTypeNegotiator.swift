// Modified for Horos by Thales Matheus M Santos (ThalesMMS), 2026: only the
// client side is kept (the Accept headers a client sends and the
// Representation type); the server-side selection, which needs DicomData's
// transfer syntaxes and codec capabilities, is left out. The store response is
// asked for as DICOM JSON only, and instanceAcceptHeader(transferSyntaxUID:)
// is added so a retrieve can name the transfer syntax it wants.
// Original: DICOM-Swift, DicomCore/DicomWebMediaTypeNegotiator.swift, revision 1947fefa46e6.
// Licensed under the Apache License, Version 2.0; see LICENSE in this folder.

import Foundation

public enum DicomWebMediaTypeNegotiator {}

extension DicomWebMediaTypeNegotiator {
    public enum ResourceKind: Sendable { case instance, metadata, frames, rendered, thumbnail, bulkdata }
    public struct Representation: Equatable, Sendable {
        public let mediaType: String
        public let transferSyntaxUID: String?
        public let multipart: Bool
        public init(_ mediaType: String, transferSyntaxUID: String? = nil, multipart: Bool = false) {
            self.mediaType = mediaType
            self.transferSyntaxUID = transferSyntaxUID
            self.multipart = multipart
        }
        /// Multipart callers append their generated boundary to this value.
        public var contentType: String {
            let type = multipart ? "multipart/related; type=\"\(mediaType)\"" : mediaType
            return type + (transferSyntaxUID.map { "; transfer-syntax=\($0)" } ?? "")
        }
    }

    public static var storeResponseAcceptHeader: String {
        "application/dicom+json"
    }

    public static func renderedFrameAcceptHeader(representationCount: Int) -> String {
        representationCount == 1 ? "image/png, image/jpeg" : "multipart/related; type=\"image/png\""
    }

    public static func acceptHeader(for resource: ResourceKind) -> String {
        switch resource {
        case .instance: return "multipart/related; type=\"application/dicom\"; transfer-syntax=*"
        case .metadata: return "application/dicom+json"
        case .frames: return "multipart/related; type=\"application/octet-stream\"; transfer-syntax=*"
        case .rendered, .thumbnail: return "image/jpeg, image/png, image/gif"
        case .bulkdata: return "application/octet-stream, multipart/related; type=\"application/octet-stream\""
        }
    }

    /// The Accept header of a WADO-RS instance retrieve: `nil` or `*` asks for
    /// the objects as stored, a UID asks the origin server to send that
    /// transfer syntax (PS3.18 8.7.3). A UID that is not a valid UID is refused.
    public static func instanceAcceptHeader(transferSyntaxUID: String?) throws -> String {
        guard let uid = transferSyntaxUID?.trimmingCharacters(in: .whitespaces), !uid.isEmpty, uid != "*" else {
            return acceptHeader(for: .instance)
        }
        let bytes = Array(uid.utf8)
        guard bytes.count <= 64, bytes.allSatisfy({ (48...57).contains($0) || $0 == 46 }),
              !uid.hasPrefix("."), !uid.hasSuffix("."), !uid.contains("..") else {
            throw DicomWebError(kind: .badRequest)
        }
        return "multipart/related; type=\"application/dicom\"; transfer-syntax=\(uid)"
    }
}
