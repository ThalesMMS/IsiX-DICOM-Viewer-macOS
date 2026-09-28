import Foundation

/// Returning from receive supplies backpressure. A sink may write to disk or enforce its own memory budget.
public protocol DicomWebRetrieveSink: Sendable {
    func receive(_ event: DicomWebMultipartEvent) async throws
}

public actor DicomWebMemoryRetrieveSink: DicomWebRetrieveSink {
    private var parts: [DicomWebMultipartPart] = []
    private var total = 0
    private let maximumBytes: Int
    public init(maximumBytes: Int = 128 * 1024 * 1024) { self.maximumBytes = maximumBytes }
    public func receive(_ event: DicomWebMultipartEvent) throws {
        try Task.checkCancellation()
        switch event {
        case .partHeaders(let headers, let isRoot):
            var part = DicomWebMultipartPart(headers: headers, body: Data())
            part.isRoot = isRoot
            parts.append(part)
        case .payload(let data):
            guard !parts.isEmpty else { throw DicomWebMultipartStreamError.invalidState }
            guard data.count <= maximumBytes - total else { throw DicomWebError(kind: .tooLarge) }
            total += data.count
            parts[parts.count - 1].body.append(data)
        default: break
        }
    }
    public func result() -> [DicomWebMultipartPart] { parts }
}

/// Files have generated local names; untrusted Content-Location is retained only as metadata.
public actor DicomWebFileRetrieveSink: DicomWebRetrieveSink {
    public struct Part: Sendable {
        public let url: URL
        public let headers: [String: String]
        public var contentLocation: String? { headers.dicomWebHeaderValue("Content-Location") }
    }
    private let directory: URL
    private var handle: FileHandle?
    private var current: Part?
    private var completed: [Part] = []
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { try? handle?.close() }
    public func receive(_ event: DicomWebMultipartEvent) throws {
        try Task.checkCancellation()
        switch event {
        case .partHeaders(let headers, _):
            guard handle == nil else { throw DicomWebMultipartStreamError.invalidState }
            let url = directory.appendingPathComponent(UUID().uuidString + ".dcm")
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw DicomWebError(kind: .server) }
            handle = try FileHandle(forWritingTo: url)
            current = .init(url: url, headers: headers)
        case .payload(let data):
            guard let handle else { throw DicomWebMultipartStreamError.invalidState }
            try handle.write(contentsOf: data)
        case .partEnd:
            try handle?.close()
            handle = nil
            if let current { completed.append(current) }
            current = nil
        case .epilogue: break
        }
    }
    /// Removes only the incomplete part after a failed or cancelled retrieval.
    public func discardIncompletePart() {
        try? handle?.close()
        handle = nil
        if let current { try? FileManager.default.removeItem(at: current.url) }
        current = nil
    }
    public func result() -> [Part] { completed }
}
