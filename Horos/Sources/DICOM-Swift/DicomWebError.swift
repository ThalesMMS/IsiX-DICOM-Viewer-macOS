import Foundation

/// Shared, fixed diagnostics: never include response bodies, identifiers, URLs or query values.
public struct DicomWebError: Error, Equatable, Sendable, LocalizedError {
    public enum Kind: String, Sendable {
        case badRequest, unauthorized, forbidden, notFound, notAcceptable, conflict
        case unsupportedMediaType, tooLarge, server, invalidResponse, originDenied
    }
    public let kind: Kind
    public let statusCode: Int
    public let code: String?
    public var errorDescription: String? { "DICOMweb \(kind.rawValue) (HTTP \(statusCode))." }
    public init(kind: Kind, statusCode: Int? = nil, code: String? = nil) {
        self.kind = kind
        self.code = code
        self.statusCode = statusCode ?? Self.defaultStatus(kind)
    }
    public init(statusCode: Int, code: String? = nil) {
        let kind: Kind
        switch statusCode {
        case 400: kind = .badRequest
        case 401: kind = .unauthorized
        case 403: kind = .forbidden
        case 404: kind = .notFound
        case 406: kind = .notAcceptable
        case 409: kind = .conflict
        case 413: kind = .tooLarge
        case 415: kind = .unsupportedMediaType
        default: kind = .server
        }
        self.init(kind: kind, statusCode: statusCode, code: code)
    }
    private static func defaultStatus(_ kind: Kind) -> Int {
        switch kind {
        case .badRequest: 400
        case .unauthorized: 401
        case .forbidden, .originDenied: 403
        case .notFound: 404
        case .notAcceptable: 406
        case .conflict: 409
        case .tooLarge: 413
        case .unsupportedMediaType: 415
        case .server: 500
        case .invalidResponse: 502
        }
    }
}
