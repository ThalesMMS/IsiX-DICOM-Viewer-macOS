// Modified for Horos by Thales Matheus M Santos (ThalesMMS), 2026: reduced to
// the client Horos uses (QIDO-RS search pages, WADO-RS retrieval into a sink,
// STOW-RS from files) plus retrieve(pathComponents:accept:sink:). Everything
// that needs DicomData (data sets, the DICOM JSON codec, metadata, bulk data,
// Part 10 writing) and the buffered frame, rendered, thumbnail and WADO-URI
// retrievals are left out; search pages hold the DICOM JSON objects as
// JSONSerialization reads them. The URLSession transport is left out and the
// transport has no default: Horos supplies its own. Renamed from
// DicomWebClient.swift, which differs from Horos's DICOMwebClient.swift only by
// case, so the two would build into the same object file on a case-insensitive disk.
// Original: DICOM-Swift, DicomCore/DicomWebClient.swift, revision 1947fefa46e6.
// Licensed under the Apache License, Version 2.0; see LICENSE in this folder.

import Foundation

public enum DicomWebHTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
}

public struct DicomWebHTTPRequest: Sendable {
    public var method: DicomWebHTTPMethod
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    public var bodyFileURL: URL?
    public var originPolicy: DicomWebOriginPolicy?
    /// When set, a transport must connect to this numeric address while preserving the URL's Host and TLS identity,
    /// or reject the request. Resolving the URL's hostname again would invalidate the caller's address policy.
    public var connectAddress: String? = nil
    public var credentialHeaderNames: Set<String> = []
    public var timeout: TimeInterval

    public init(method: DicomWebHTTPMethod,
                url: URL,
                headers: [String: String] = [:],
                body: Data? = nil,
                timeout: TimeInterval = 30) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

public struct DicomWebHTTPResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public protocol DicomWebHTTPTransport: Sendable {
    func send(_ request: DicomWebHTTPRequest) async throws -> DicomWebHTTPResponse
    func stream(_ request: DicomWebHTTPRequest) async throws -> DicomWebHTTPStreamedResponse
}

public struct DicomWebClientConfiguration: Equatable, Sendable {
    /// Default maximum complete in-memory STOW multipart request size (128 MiB).
    public static let defaultMaximumSTOWRequestBodyBytes = 128 * 1_024 * 1_024

    public var allowedOrigins: Set<URL> = []
    public var multipartLimits = DicomWebMultipartLimits()
    public var maximumMetadataBytes = 64 * 1024 * 1024
    public var originPolicy: DicomWebOriginPolicy {
        .init(configuredURL: baseURL, allowedOrigins: allowedOrigins.union(allowedBulkDataOrigins))
    }
    public var baseURL: URL
    /// Headers scoped to the configured origin; foreign BulkDataURI hosts do not receive them.
    public var headers: [String: String]
    public var timeout: TimeInterval
    /// Maximum complete STOW multipart body size, including MIME framing and payloads.
    public var maximumSTOWRequestBodyBytes: Int
    /// Additional BulkDataURI origins. Scheme, host and effective port must match; headers stay on the base origin.
    public var allowedBulkDataOrigins: [URL]

    public init(baseURL: URL,
                headers: [String: String] = [:],
                timeout: TimeInterval = 30,
                maximumSTOWRequestBodyBytes: Int = Self.defaultMaximumSTOWRequestBodyBytes,
                allowedBulkDataOrigins: [URL] = []) {
        self.baseURL = baseURL
        self.headers = headers
        self.timeout = timeout
        self.maximumSTOWRequestBodyBytes = maximumSTOWRequestBodyBytes
        self.allowedBulkDataOrigins = allowedBulkDataOrigins
    }

    public init(baseURL: URL,
                bearerToken: String?,
                timeout: TimeInterval = 30,
                maximumSTOWRequestBodyBytes: Int = Self.defaultMaximumSTOWRequestBodyBytes,
                allowedBulkDataOrigins: [URL] = []) {
        var headers: [String: String] = [:]
        if let token = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            headers["Authorization"] = "Bearer \(token)"
        }
        self.init(baseURL: baseURL,
                  headers: headers,
                  timeout: timeout,
                  maximumSTOWRequestBodyBytes: maximumSTOWRequestBodyBytes,
                  allowedBulkDataOrigins: allowedBulkDataOrigins)
    }
}

public struct DicomWebMultipartPart: Equatable, Sendable {
    public var isRoot: Bool = false
    public var headers: [String: String]
    public var body: Data

    public var contentType: String? {
        headers.dicomWebHeaderValue("Content-Type")
    }

    public init(headers: [String: String] = [:], body: Data) {
        self.headers = headers
        self.body = body
    }
}

public struct DicomWebStoreInstance: Equatable, Sendable {
    public var data: Data
    public var contentType: String
    public var transferSyntax: String?

    /// Creates one STOW-RS multipart item. A `nil` transfer syntax is derived from
    /// Part 10 File Meta Information, or omitted when `data` is not a Part 10 file.
    public init(data: Data,
                contentType: String = "application/dicom",
                transferSyntax: String? = "1.2.840.10008.1.2.1" /* Explicit VR Little Endian */) {
        self.data = data
        self.contentType = contentType
        self.transferSyntax = transferSyntax
    }
}

public struct DicomWebStoreResult: Equatable, Sendable {
    public var statusCode: Int
    public var responseData: Data
    public var responseParts: [DicomWebMultipartPart]
    public var storeResponse: DicomWebStoreResponse?
    public var acceptedInstanceCount: Int { storeResponse?.acceptedInstanceCount ?? 0 }
    @available(*, deprecated, renamed: "acceptedInstanceCount")
    public var storedInstanceCount: Int {
        get { acceptedInstanceCount }
        set { /* A submitted count cannot establish storage outcomes. */ }
    }

    public init(statusCode: Int, responseData: Data, responseParts: [DicomWebMultipartPart] = [],
                storeResponse: DicomWebStoreResponse) {
        self.statusCode = statusCode
        self.responseData = responseData
        self.responseParts = responseParts
        self.storeResponse = storeResponse
    }

    @available(*, deprecated, message: "Use the initializer with decoded storeResponse; submitted counts cannot confirm storage.")
    public init(statusCode: Int,
                responseData: Data,
                responseParts: [DicomWebMultipartPart] = [],
                storedInstanceCount: Int) {
        self.statusCode = statusCode
        self.responseData = responseData
        self.responseParts = responseParts
        self.storeResponse = nil
    }
}

public enum DicomWebClientError: Error, Equatable, Sendable {
    case invalidHTTPResponse
    case invalidBaseURL(URL)
    /// The supplied DICOMweb `BulkDataURI` could not be resolved against the client base URL.
    case invalidBulkDataURI(String)
    case httpStatus(statusCode: Int, method: String, url: String, bodyPreview: String)
    case invalidJSONResponse
    case malformedDICOMJSONElement(String)
    case unsupportedDICOMJSONValue(tag: String, vr: String)
    case missingMultipartBoundary(contentType: String?)
    case malformedMultipartBody
    case emptyStoreRequest
    case invalidStoreContentType(instanceIndex: Int)
    case invalidStoreTransferSyntaxUID(instanceIndex: Int)
    case invalidStorePart10FileMeta(instanceIndex: Int)
    case storeTransferSyntaxMismatch(instanceIndex: Int)
    case storeRequestBodyTooLarge(byteCount: Int, limit: Int)
    case multipartBodyTooLarge
}

extension DicomWebClientError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidHTTPResponse:
            return "DICOMweb response was not an HTTP response."
        case .invalidBaseURL:
            return "Invalid DICOMweb base URL."
        case .invalidBulkDataURI:
            return "DICOMweb BulkDataURI is invalid or disallowed by the origin policy."
        case .httpStatus(let statusCode, let method, let url, let bodyPreview):
            let suffix = bodyPreview.isEmpty ? "" : " Body: \(bodyPreview)"
            return "DICOMweb \(method) \(url) failed with HTTP \(statusCode).\(suffix)"
        case .invalidJSONResponse:
            return "DICOMweb response did not contain valid DICOM JSON."
        case .malformedDICOMJSONElement(let tag):
            return "DICOMweb JSON element \(tag) is malformed."
        case .unsupportedDICOMJSONValue(let tag, let vr):
            return "DICOMweb JSON element \(tag) with VR \(vr) is not supported."
        case .missingMultipartBoundary(let contentType):
            return "DICOMweb multipart response is missing a boundary in Content-Type \(contentType ?? "<none>")."
        case .malformedMultipartBody:
            return "DICOMweb multipart response is malformed."
        case .emptyStoreRequest:
            return "DICOMweb STOW request must include at least one DICOM instance."
        case .invalidStoreContentType(let instanceIndex):
            return "DICOMweb STOW instance at index \(instanceIndex) has an invalid Content-Type."
        case .invalidStoreTransferSyntaxUID(let instanceIndex):
            return "DICOMweb STOW instance at index \(instanceIndex) has an invalid transfer syntax UID."
        case .invalidStorePart10FileMeta(let instanceIndex):
            return "DICOMweb STOW instance at index \(instanceIndex) has invalid Part 10 File Meta Information."
        case .storeTransferSyntaxMismatch(let instanceIndex):
            return "DICOMweb STOW instance at index \(instanceIndex) declares a transfer syntax that does not " +
                "match its Part 10 File Meta Information."
        case .storeRequestBodyTooLarge(let byteCount, let limit):
            return "DICOMweb STOW multipart body requires \(byteCount) bytes, exceeding the \(limit)-byte limit."
        case .multipartBodyTooLarge:
            return "DICOMweb STOW multipart body exceeds the addressable in-memory size."
        }
    }
}

public struct DicomWebClient: Sendable {
    public var configuration: DicomWebClientConfiguration
    private let transport: any DicomWebHTTPTransport

    public init(configuration: DicomWebClientConfiguration,
                transport: any DicomWebHTTPTransport) {
        self.configuration = configuration
        self.transport = transport
    }

    @discardableResult
    public func retrieveStudy(studyInstanceUID: String,
                                accept: DicomWebMediaType, sink: any DicomWebRetrieveSink) async throws -> Int {
        try await retrieve(url: endpoint(["studies", studyInstanceUID]), accept: accept.headerValue, sink: sink)
    }

    @discardableResult
    public func retrieveSeries(studyInstanceUID: String, seriesInstanceUID: String,
                                accept: DicomWebMediaType, sink: any DicomWebRetrieveSink) async throws -> Int {
        try await retrieve(url: endpoint(["studies", studyInstanceUID, "series", seriesInstanceUID]), accept: accept.headerValue, sink: sink)
    }

    @discardableResult
    public func retrieveInstance(studyInstanceUID: String, seriesInstanceUID: String, sopInstanceUID: String,
                                accept: DicomWebMediaType, sink: any DicomWebRetrieveSink) async throws -> Int {
        try await retrieve(url: endpoint(["studies", studyInstanceUID, "series", seriesInstanceUID, "instances", sopInstanceUID]), accept: accept.headerValue, sink: sink)
    }

    /// Streams the WADO-RS resource at `pathComponents` below the base URL with
    /// the Accept header exactly as given, such as one from
    /// `DicomWebMediaTypeNegotiator.instanceAcceptHeader(transferSyntaxUID:)`.
    @discardableResult
    public func retrieve(pathComponents: [String], accept: String,
                         sink: any DicomWebRetrieveSink) async throws -> Int {
        try await retrieve(url: endpoint(pathComponents), accept: accept, sink: sink)
    }

    public func search(parameters: DicomWebSearchParameters) async throws -> DicomWebSearchPage {
        let response = try await boundedResponse(url: parameters.url(relativeTo: configuration.baseURL),
                                                  accept: DicomWebMediaTypeNegotiator.acceptHeader(for: .metadata))
        let records = response.statusCode == 204 ? [] : try DicomWebJSONParser.records(from: response.body)
        return .init(records: records, statusCode: response.statusCode,
                     contentType: response.headers.dicomWebHeaderValue("Content-Type"),
                     warning: response.headers.dicomWebHeaderValue("Warning"),
                     offset: parameters.offset ?? 0, limit: parameters.limit)
    }

    public func searchPages(parameters: DicomWebSearchParameters, continuesOnFullPage: Bool = false) -> DicomWebSearchPager {
        .init(client: self, parameters: parameters, continuesOnFullPage: continuesOnFullPage)
    }

    public func searchSeries(studyInstanceUID: String? = nil,
                             matches: [DicomWebSearchParameters.Match] = [], limit: Int? = nil,
                             offset: Int? = nil) async throws -> DicomWebSearchPage {
        try await search(parameters: .init(level: .series, studyInstanceUID: studyInstanceUID,
                                           matches: matches, limit: limit, offset: offset))
    }

    public func searchInstances(studyInstanceUID: String? = nil, seriesInstanceUID: String? = nil,
                                matches: [DicomWebSearchParameters.Match] = [], limit: Int? = nil,
                                offset: Int? = nil) async throws -> DicomWebSearchPage {
        try await search(parameters: .init(level: .instance, studyInstanceUID: studyInstanceUID,
                                           seriesInstanceUID: seriesInstanceUID, matches: matches, limit: limit, offset: offset))
    }

    private func retrieve(url: URL, accept: String, sink: any DicomWebRetrieveSink) async throws -> Int {
        let response = try await streamRequest(.get, url: url, headers: ["Accept": accept])
        try await consume(response, sink: sink)
        return response.statusCode
    }

    private func consume(_ response: DicomWebHTTPStreamedResponse, sink: any DicomWebRetrieveSink) async throws {
        defer { response.cancel() }
        do {
            let contentType = response.headers.dicomWebHeaderValue("Content-Type") ?? "application/octet-stream"
            if contentType.lowercased().hasPrefix("multipart/") {
                var parser = try DicomWebMultipartStreamParser(contentType: contentType, limits: configuration.multipartLimits)
                for try await chunk in response.body {
                    try Task.checkCancellation()
                    // Bound event batches even when an injected transport yields a large Data value.
                    for offset in stride(from: 0, to: chunk.count, by: 16 * 1024) {
                        let start = chunk.index(chunk.startIndex, offsetBy: offset)
                        let end = chunk.index(start, offsetBy: min(16 * 1024, chunk.count - offset))
                        for event in try parser.feed(Data(chunk[start..<end])) { try await sink.receive(event) }
                    }
                }
                for event in try parser.finish() { try await sink.receive(event) }
            } else {
                try await sink.receive(.partHeaders(response.headers, isRoot: true))
                var total = 0
                let limit = min(configuration.multipartLimits.maximumPartBytes, configuration.multipartLimits.maximumTotalBytes)
                for try await chunk in response.body {
                    try Task.checkCancellation()
                    guard chunk.count <= limit - total else { throw DicomWebError(kind: .tooLarge) }
                    total += chunk.count
                    try await sink.receive(.payload(chunk))
                }
                try await sink.receive(.partEnd)
            }
        } catch {
            if let file = sink as? DicomWebFileRetrieveSink { await file.discardIncompletePart() }
            throw error
        }
    }

    private func streamRequest(_ method: DicomWebHTTPMethod, url: URL, headers: [String: String],
                               body: Data? = nil, bodyFileURL: URL? = nil,
                               acceptedStatuses: Set<Int> = []) async throws -> DicomWebHTTPStreamedResponse {
        try Task.checkCancellation()
        try configuration.originPolicy.validate(url)
        var allHeaders = configuration.originPolicy.forwardsCredentials(to: url) ? configuration.headers : [:]
        for (name, value) in headers { allHeaders[name] = value }
        var request = DicomWebHTTPRequest(method: method, url: url, headers: allHeaders, body: body, timeout: configuration.timeout)
        request.originPolicy = configuration.originPolicy
        request.credentialHeaderNames = Set(configuration.headers.keys.map { $0.lowercased() })
        request.bodyFileURL = bodyFileURL
        let response = try await transport.stream(request)
        guard (200..<300).contains(response.statusCode) || acceptedStatuses.contains(response.statusCode) else {
            response.cancel()
            throw DicomWebError(statusCode: response.statusCode, code: response.headers.dicomWebHeaderValue("X-DICOMweb-Error-Code"))
        }
        return response
    }

    private func boundedResponse(url: URL, accept: String) async throws -> DicomWebHTTPResponse {
        let response = try await streamRequest(.get, url: url, headers: ["Accept": accept])
        return try await collect(response, maximumBytes: configuration.maximumMetadataBytes)
    }

    private func collect(_ response: DicomWebHTTPStreamedResponse, maximumBytes: Int) async throws -> DicomWebHTTPResponse {
        defer { response.cancel() }
        var body = Data()
        for try await chunk in response.body {
            try Task.checkCancellation()
            guard chunk.count <= maximumBytes - body.count else { throw DicomWebError(kind: .tooLarge) }
            body.append(chunk)
        }
        return .init(statusCode: response.statusCode, headers: response.headers, body: body)
    }

    public func storeInstances(_ instances: [DicomWebStoreInstance],
                               studyInstanceUID: String? = nil) async throws -> DicomWebStoreResult {
        guard !instances.isEmpty else { throw DicomWebClientError.emptyStoreRequest }
        let boundary = "dicomweb-\(UUID().uuidString)"
        _ = try DicomWebSTOWMultipartBodyBuilder.serializedByteCount(
            instances: instances, boundary: boundary, maximumBytes: configuration.maximumSTOWRequestBodyBytes)
        let prepared = try DicomWebSTOWMultipartBodyBuilder.prepare(instances: instances)
        return try await storeMultipart(boundary: boundary, studyInstanceUID: studyInstanceUID) { writer, sink in
            for instance in prepared {
                let type = instance.contentType + (instance.transferSyntax.map { "; transfer-syntax=\($0)" } ?? "")
                try writer.beginPart(headers: [("Content-Type", type)], contentLength: instance.data.count, sink: sink)
                try writer.payload(instance.data, sink: sink)
                try writer.endPart(sink: sink)
            }
        }
    }

    public func storeInstances(files: [URL], studyInstanceUID: String? = nil) async throws -> DicomWebStoreResult {
        guard !files.isEmpty else { throw DicomWebClientError.emptyStoreRequest }
        let boundary = "dicomweb-\(UUID().uuidString)"
        return try await storeMultipart(boundary: boundary, studyInstanceUID: studyInstanceUID) { writer, sink in
            for (index, file) in files.enumerated() {
                try Task.checkCancellation()
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                let size = try handle.seekToEnd()
                guard let length = Int(exactly: size), length <= configuration.maximumSTOWRequestBodyBytes else {
                    throw DicomWebClientError.storeRequestBodyTooLarge(byteCount: Int(clamping: size),
                                                                     limit: configuration.maximumSTOWRequestBodyBytes)
                }
                try handle.seek(toOffset: 0)
                // Part 10 requires File Meta Information Group Length as the first element.
                // Read exactly that bounded group, plus the following header used by the shared parser.
                var prefix = try handle.read(upToCount: min(length, 144)) ?? Data()
                guard prefix.count == 144, DicomPart10FileMetaParser.hasPart10Prefix(prefix),
                      Array(prefix[132..<140]) == [2, 0, 0, 0, 85, 76, 4, 0] else {
                    throw DicomWebClientError.invalidStorePart10FileMeta(instanceIndex: index)
                }
                let groupLength = (0..<4).reduce(UInt32(0)) { $0 | UInt32(prefix[140 + $1]) << (8 * $1) }
                guard let metaLength = Int(exactly: groupLength), metaLength <= length - 144 else {
                    throw DicomWebClientError.invalidStorePart10FileMeta(instanceIndex: index)
                }
                let suffixLength = min(length - 144, metaLength + 8)
                prefix.append(try handle.read(upToCount: suffixLength) ?? Data())
                guard try DicomPart10FileMetaParser.parse(prefix).dataSetOffset == 144 + metaLength else {
                    throw DicomWebClientError.invalidStorePart10FileMeta(instanceIndex: index)
                }
                let prepared = try DicomWebSTOWMultipartBodyBuilder.prepare(instances: [.init(data: prefix, transferSyntax: nil)])
                let type = "application/dicom" + (prepared[0].transferSyntax.map { "; transfer-syntax=\($0)" } ?? "")
                try handle.seek(toOffset: 0)
                try writer.beginPart(headers: [("Content-Type", type)], contentLength: length, sink: sink)
                try writer.payload(file: handle, sink: sink)
                try writer.endPart(sink: sink)
            }
        }
    }

    private func storeMultipart(boundary: String, studyInstanceUID: String?,
                                write: (inout DicomWebMultipartStreamWriter, DicomWebByteSink) throws -> Void) async throws -> DicomWebStoreResult {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("dicomweb-stow-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: file.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else { throw DicomWebError(kind: .server) }
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var writer = try DicomWebMultipartStreamWriter(boundary: boundary, maximumBytes: configuration.maximumSTOWRequestBodyBytes)
        try write(&writer) { try handle.write(contentsOf: $0) }
        try writer.finish { try handle.write(contentsOf: $0) }
        let length = try handle.offset()
        try handle.close()
        let streamed = try await streamRequest(.post,
            url: endpoint(studyInstanceUID.map { ["studies", $0] } ?? ["studies"]),
            headers: ["Content-Type": "multipart/related; type=\"application/dicom\"; boundary=\(boundary)",
                      "Content-Length": String(length), "Accept": DicomWebMediaTypeNegotiator.storeResponseAcceptHeader],
            bodyFileURL: file, acceptedStatuses: [409])
        let response = try await collect(streamed, maximumBytes: configuration.maximumMetadataBytes)
        let contentType = response.headers.dicomWebHeaderValue("Content-Type")
        let parts = try multipartPartsIfNeeded(body: response.body, contentType: contentType)
        let decoded: DicomWebStoreResponse
        if let first = parts.first(where: \.isRoot) ?? parts.first {
            decoded = try DicomWebStoreResponse.decode(first.body, contentType: first.contentType)
        } else {
            decoded = try DicomWebStoreResponse.decode(response.body, contentType: contentType)
        }
        return DicomWebStoreResult(statusCode: response.statusCode, responseData: response.body,
                                   responseParts: parts, storeResponse: decoded)
    }

    private func multipartPartsIfNeeded(body: Data, contentType: String?) throws -> [DicomWebMultipartPart] {
        guard let contentType, contentType.lowercased().contains("multipart/related") else {
            return []
        }
        guard DicomWebMultipartParser.boundary(from: contentType) != nil else {
            throw DicomWebClientError.missingMultipartBoundary(contentType: contentType)
        }
        return try DicomWebMultipartStreamParser.parts(from: body, contentType: contentType, limits: configuration.multipartLimits)
    }

    private func endpoint(_ pathComponents: [String]) -> URL {
        var url = configuration.baseURL
        for component in pathComponents {
            url.appendPathComponent(component)
        }
        return url
    }
}

/// DICOM JSON responses are read with JSONSerialization; DicomData's codec is not vendored.
enum DicomWebJSONParser {
    static func records(from data: Data) throws -> [[String: Any]] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let records = object as? [[String: Any]] else { throw DicomWebClientError.invalidJSONResponse }
        return records
    }
}

enum DicomWebMultipartParser {
    static func boundary(from contentType: String) -> String? {
        for component in contentType.components(separatedBy: ";") {
            let pair = component.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard pair.count == 2, pair[0].lowercased() == "boundary" else { continue }
            return pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    static func parts(from data: Data, boundary: String) throws -> [DicomWebMultipartPart] {
        do {
            return try DicomWebMultipartStreamParser.parts(
                from: data, contentType: "multipart/related; boundary=\"\(boundary)\"")
        } catch is CancellationError { throw CancellationError() }
        catch { throw DicomWebClientError.malformedMultipartBody }
    }

    private static func headers(from text: String) -> [String: String] {
        text.components(separatedBy: "\r\n").reduce(into: [String: String]()) { result, line in
            let pair = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { return }
            result[pair[0].trimmingCharacters(in: .whitespacesAndNewlines)] =
                pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

extension Dictionary where Key == String, Value == String {
    func dicomWebHeaderValue(_ field: String) -> String? {
        first { $0.key.caseInsensitiveCompare(field) == .orderedSame }?.value
    }
}

private extension String {
    static func dicomWebPreview(_ data: Data) -> String {
        let prefix = data.prefix(512)
        return String(data: prefix, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

private extension Data {
    func hasBytes(_ bytes: [UInt8], at index: Data.Index) -> Bool {
        guard distance(from: index, to: endIndex) >= bytes.count else { return false }
        for (offset, byte) in bytes.enumerated() where self[index + offset] != byte {
            return false
        }
        return true
    }
}

private extension Data.SubSequence {
    func dicomWebStrippingTrailingCRLF() -> Data {
        guard distance(from: startIndex, to: endIndex) >= 2 else {
            return Data(self)
        }
        let previous = index(before: endIndex)
        let penultimate = index(before: previous)
        guard self[penultimate] == 13, self[previous] == 10 else {
            return Data(self)
        }
        return Data(self[startIndex..<penultimate])
    }
}
