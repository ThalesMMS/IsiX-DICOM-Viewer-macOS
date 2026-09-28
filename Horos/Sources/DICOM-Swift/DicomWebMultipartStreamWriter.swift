import Foundation

public typealias DicomWebByteSink = (Data) throws -> Void

/// Synchronous writes supply backpressure, including when the sink writes to a FileHandle.
public struct DicomWebMultipartStreamWriter {
    private let boundary: String
    private let maximumBytes: Int
    private var total = 0
    private var remaining: Int?
    private var inPart = false
    private var finished = false

    public init(boundary: String, maximumBytes: Int = 1024 * 1024 * 1024) throws {
        _ = try DicomWebMultipartStreamParser(boundary: boundary)
        self.boundary = boundary
        self.maximumBytes = maximumBytes
    }

    public mutating func beginPart(headers: [(String, String)], contentLength: Int?,
                                   sink: DicomWebByteSink) throws {
        guard !finished, !inPart, contentLength.map({ $0 >= 0 }) ?? true else {
            throw DicomWebMultipartStreamError.invalidState
        }
        guard headers.contains(where: { $0.0.lowercased() == "content-type" }),
              headers.allSatisfy({ !$0.0.contains(":") && !$0.0.contains(where: { $0.isWhitespace })
                  && !$0.1.utf8.contains(13) && !$0.1.utf8.contains(10)
                  && $0.0.lowercased() != "content-length" }) else {
            throw DicomWebMultipartStreamError.malformedHeaders
        }
        var header = "--\(boundary)\r\n"
        for (key, value) in headers { header += "\(key): \(value)\r\n" }
        if let contentLength { header += "Content-Length: \(contentLength)\r\n" }
        header += "\r\n"
        try write(Data(header.utf8), sink: sink)
        remaining = contentLength
        inPart = true
    }

    public mutating func payload(_ data: Data, sink: DicomWebByteSink) throws {
        guard inPart, !finished else { throw DicomWebMultipartStreamError.invalidState }
        if let remaining, data.count > remaining { throw DicomWebMultipartStreamError.invalidContentLength }
        for offset in stride(from: 0, to: data.count, by: 64 * 1024) {
            let start = data.index(data.startIndex, offsetBy: offset)
            try write(Data(data[start..<data.index(start, offsetBy: min(64 * 1024, data.count - offset))]), sink: sink)
        }
        if let remaining { self.remaining = remaining - data.count }
    }

    public mutating func payload(file: FileHandle, sink: DicomWebByteSink) throws {
        while true {
            try Task.checkCancellation()
            guard let chunk = try file.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
            try payload(chunk, sink: sink)
        }
    }

    public mutating func endPart(sink: DicomWebByteSink) throws {
        guard inPart, remaining == nil || remaining == 0 else { throw DicomWebMultipartStreamError.invalidContentLength }
        try write(Data("\r\n".utf8), sink: sink)
        inPart = false
    }

    public mutating func finish(sink: DicomWebByteSink) throws {
        guard !inPart, !finished else { throw DicomWebMultipartStreamError.invalidState }
        try write(Data("--\(boundary)--\r\n".utf8), sink: sink)
        finished = true
    }

    private mutating func write(_ data: Data, sink: DicomWebByteSink) throws {
        try Task.checkCancellation()
        guard total <= maximumBytes, data.count <= maximumBytes - total else {
            throw DicomWebMultipartStreamError.limitExceeded("maximumTotalBytes", limit: maximumBytes)
        }
        try sink(data)
        total += data.count
    }
}
