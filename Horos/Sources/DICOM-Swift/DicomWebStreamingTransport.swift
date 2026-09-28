// Modified for Horos by Thales Matheus M Santos (ThalesMMS), 2026: the
// URLSession transport is left out. Horos supplies its own transport, which
// follows no redirect and streams response bodies through files it owns.
// Original: DICOM-Swift, DicomCore/DicomWebStreamingTransport.swift, revision 1947fefa46e6.
// Licensed under the Apache License, Version 2.0; see LICENSE in this folder.

import Foundation

public struct DicomWebHTTPStreamedResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: AsyncThrowingStream<Data, Error>
    /// Called before every WebSocket event. Throwing closes the connection before sending the event.
    public var authorizeNotification: (@Sendable (String) async throws -> Void)?
    public var cancel: @Sendable () -> Void

    public init(statusCode: Int, headers: [String: String] = [:], body: AsyncThrowingStream<Data, Error>,
                cancel: @escaping @Sendable () -> Void = {},
                authorizeNotification: (@Sendable (String) async throws -> Void)? = nil) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.authorizeNotification = authorizeNotification
        self.cancel = cancel
    }
}

extension DicomWebHTTPTransport {
    /// Compatibility adapter with the default STOW request limit for buffered file bodies.
    public func stream(_ request: DicomWebHTTPRequest) async throws -> DicomWebHTTPStreamedResponse {
        try await stream(request, bufferingLimit: DicomWebClientConfiguration.defaultMaximumSTOWRequestBodyBytes)
    }

    func stream(_ request: DicomWebHTTPRequest, bufferingLimit: Int) async throws -> DicomWebHTTPStreamedResponse {
        var buffered = request
        if let file = request.bodyFileURL {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let body = try handle.read(upToCount: bufferingLimit + 1) ?? Data()
            guard body.count <= bufferingLimit else { throw DicomWebError(kind: .tooLarge) }
            buffered.body = body
            buffered.bodyFileURL = nil
        }
        let response = try await send(buffered)
        return .init(statusCode: response.statusCode, headers: response.headers,
                     body: AsyncThrowingStream { continuation in
            continuation.yield(response.body)
            continuation.finish()
        })
    }
}
