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

/// The commands of the shared-database protocol, by the six bytes (five
/// letters and a terminator) that start a request.
public enum SharedDatabaseCommand: String, Sendable, CaseIterable {
    /// The version of the authorization envelope the server speaks.
    case authorizationVersion = "AUTHV"
    /// The index file itself.
    case database = "DATAB"
    /// The size of the index file.
    case databaseSize = "DBSIZ"
    /// Where and how to send DICOM to this server.
    case destinationInfo = "GETDI"
    /// When the index last changed.
    case modificationTime = "VERSI"
    /// The version of the index's model.
    case databaseVersion = "DBVER"
    /// Whether the server asks for a password.
    case isPasswordProtected = "ISPWD"
    /// Whether a password is the right one.
    case password = "PASWD"
    /// Files to add to the index.
    case upload = "SENDD"
    /// Files to add to the index, made by a viewer (reports, key images, ROIs).
    case generatedUpload = "SENDG"
    /// A message, read and dropped.
    case message = "NEWMS"
    /// Studies to add to an album.
    case addToAlbum = "ADDAL"
    /// Studies to remove from an album.
    case removeFromAlbum = "REMAL"
    /// One attribute of one object of the index.
    case setAttribute = "SETVA"
    /// When a file of the database last changed.
    case fileDate = "MFILE"
    /// Images to send to a DICOM node.
    case dicomSend = "DCMSE"
    /// Images to fetch, each with the path the client keeps it at.
    case fetch = "DICOM"

    /// Whether the request reads or changes the index: it runs inside the
    /// queue of the index's context.
    public var usesIndex: Bool {
        switch self {
        case .database, .databaseSize, .modificationTime, .upload, .generatedUpload,
             .addToAlbum, .removeFromAlbum, .setAttribute:
            return true
        default:
            return false
        }
    }

    /// What may sit unconsumed in the receive buffer while this request is
    /// parsed.
    public var maximumBufferedBytes: Int {
        switch self {
        case .upload, .generatedUpload: return SharedDatabaseWire.maximumBufferedBytesForUpload
        default: return SharedDatabaseWire.maximumBufferedBytesForOtherRequests
        }
    }
}

/// Whether the server asks for a password, and which one: what decides an
/// envelope, a command sent without one, and a `PASWD` request.
public struct SharedDatabaseAccess: Sendable, Equatable {
    public var isPasswordProtected: Bool
    public var password: String?

    public init(isPasswordProtected: Bool, password: String?) {
        self.isPasswordProtected = isPasswordProtected
        self.password = password
    }

    /// The answer to `PASWD`: yes when no password is asked, or when `offered`
    /// is the password, compared literally (as -isEqualToString: does, without
    /// Unicode normalization).
    public func accepts(_ offered: String?) -> Bool {
        if !isPasswordProtected { return true }
        guard let password, !password.isEmpty, let offered else { return false }
        return (offered as NSString).isEqual(to: password)
    }
}

/// A DICOM send a client orders (`DCMSE`): the node, and the files, which the
/// server resolves as it reads them.
public struct SharedDatabaseSendOrder: Sendable, Equatable {
    public var aeTitle: String
    public var address: String
    public var port: String
    public var transferSyntax: String
    public var files: [String]

    public init(aeTitle: String, address: String, port: String, transferSyntax: String, files: [String]) {
        self.aeTitle = aeTitle
        self.address = address
        self.port = port
        self.transferSyntax = transferSyntax
        self.files = files
    }

    /// The port as the send reads it: the leading integer of the text, as
    /// -[NSString intValue] reads it.
    public var portNumber: Int32 { (port as NSString).intValue }

    /// The transfer syntax as the send reads it, the same way.
    public var transferSyntaxNumber: Int32 { (transferSyntax as NSString).intValue }

    /// A client that names its own loopback address means itself: the send
    /// goes to the address the request came from.
    public func resolvingLoopback(peerAddress: String) -> SharedDatabaseSendOrder {
        guard (address as NSString).isEqual(to: "127.0.0.1") else { return self }
        var order = self
        order.address = peerAddress
        return order
    }
}

/// A complete request of the shared-database protocol, with its parameters.
public enum SharedDatabaseRequest: Sendable, Equatable {
    case authorizationVersion
    case database
    case databaseSize
    case destinationInfo
    case modificationTime
    case databaseVersion
    case isPasswordProtected
    /// The password offered; nil when it is not UTF-8.
    case password(String?)
    /// The files came as `uploadedFile` events.
    case upload(generatedByViewer: Bool, fileCount: Int)
    case message
    /// The album's property list, as the client sent it.
    case album(adding: Bool, parameters: String)
    /// nil `value` clears the attribute.
    case setAttribute(objectID: String, value: String?, key: String)
    case fileDate(path: String)
    /// The files came as `requestedPaths` events; `order.files` is empty.
    case dicomSend(SharedDatabaseSendOrder)
    /// The files came as `requestedPaths` events, and `destinations` holds the
    /// path the client keeps each at.
    case fetch(destinations: [String])
}

/// Reads one request of the shared-database protocol from the bytes as they
/// arrive, whatever their fragmentation.
///
/// Every length, count and string is checked against the wire's rules before
/// anything is consumed or allocated for it. A field is consumed only once it
/// is complete; a request cut anywhere resumes from the same place when more
/// bytes come. Uploaded files and requested paths are handed over as soon as
/// each is complete, so a file is written, and a path refused, without waiting
/// for the rest of the request: a file where it lies in the caller's buffer,
/// without a copy, and the paths that arrived together in one event, which
/// costs less per path than an event each for the thousands a request names.
///
/// A value: the server keeps one per connection and feeds it the unread part
/// of its buffer.
public struct SharedDatabaseRequestParser: Sendable {

    /// What one step of reading found.
    public enum Event: Sendable, Equatable {
        /// The bytes end before the next field.
        case needsMoreData
        /// The request is refused: the connection closes without an answer.
        case refused
        /// The request breaks the protocol: the connection closes without an
        /// answer, and the reason is logged.
        case rejected(String)
        /// One uploaded file, complete: where its bytes are in the bytes this
        /// step was given. They stay the caller's to read until it consumes them.
        case uploadedFile(Range<Int>)
        /// The paths a fetch or a send names, complete, in their order: those
        /// that the bytes of this step hold, never none.
        case requestedPaths([String])
        /// The request is complete.
        case complete(SharedDatabaseRequest)
    }

    private enum Field: Equatable {
        case header
        case strings(needed: Int, optional: Set<Int>)
        case count
        case fileLength
        case fileBody(Int)
        case messageLength
        case messageBody(Int)
        case paths
        case destinations
        case password
        case finished
    }

    public private(set) var command: SharedDatabaseCommand?
    public private(set) var isAuthorized = false
    private var field = Field.header
    private var strings: [String?] = []
    private var count = 0
    private var done = 0
    private var destinations: [String] = []

    public init() {}

    /// Whether the command is still to come: only then does reading need the
    /// access rules.
    public var isAwaitingCommand: Bool { field == .header }

    /// What may sit unconsumed in the receive buffer at this point of the request.
    public var maximumBufferedBytes: Int {
        command?.maximumBufferedBytes ?? SharedDatabaseWire.maximumBufferedBytesAwaitingCommand
    }

    /// Reads the next event from `bytes`, the unread part of the request, and
    /// how many of them it consumed. `access` is asked only while the command
    /// is still to come, once its six bytes are there.
    public mutating func next(_ bytes: UnsafeRawBufferPointer, access: () -> SharedDatabaseAccess) -> (event: Event, consumed: Int) {
        switch field {
        case .header:
            return readHeader(bytes, access: access)
        case .finished:
            // A complete request: anything more the client sends is not part of it.
            return (.needsMoreData, bytes.count)
        default:
            return readField(bytes, from: 0)
        }
    }

    // MARK: - The command

    private mutating func readHeader(_ bytes: UnsafeRawBufferPointer, access: () -> SharedDatabaseAccess) -> (event: Event, consumed: Int) {
        guard bytes.count >= 6 else { return (.needsMoreData, 0) }
        let rules = access()
        var offset = 0
        if bytes.prefix(6).elementsEqual(SharedDatabaseEnvelope.header) {
            let length = SharedDatabaseEnvelope.authorizedPrefixLength(bytes, password: rules.password,
                                                                       required: rules.isPasswordProtected)
            if length == 0 { return (.needsMoreData, 0) }
            if length < 0 { return (.refused, 0) }
            offset = length
            isAuthorized = true
        }
        let name = UnsafeRawBufferPointer(rebasing: bytes[offset..<offset + 6])
        offset += 6
        guard name[5] == 0 else { return (.refused, offset) }
        // The command up to its first terminator, as a C string.
        guard let text = NSString(utf8String: name.baseAddress!.assumingMemoryBound(to: CChar.self)) else {
            return (.refused, offset)
        }
        let command = text as String
        if rules.isPasswordProtected && !isAuthorized && !SharedDatabaseEnvelope.isPublicCommand(command) {
            return (.refused, offset)
        }
        guard let known = SharedDatabaseCommand(rawValue: command) else { return (.refused, offset) }
        self.command = known
        switch known {
        case .authorizationVersion, .database, .databaseSize, .destinationInfo, .modificationTime,
             .databaseVersion, .isPasswordProtected:
            field = .finished
            return (.complete(Self.request(without: known)), offset)
        case .password:
            field = .password
        case .upload, .generatedUpload, .fetch:
            field = .count
        case .message:
            field = .messageLength
        case .addToAlbum, .removeFromAlbum, .fileDate:
            field = .strings(needed: 1, optional: [])
        case .setAttribute:
            // The value may be nil: it clears the attribute.
            field = .strings(needed: 3, optional: [1])
        case .dicomSend:
            field = .strings(needed: 4, optional: [])
        }
        // The parameters may already be there.
        return readField(bytes, from: offset)
    }

    private static func request(without command: SharedDatabaseCommand) -> SharedDatabaseRequest {
        switch command {
        case .authorizationVersion: return .authorizationVersion
        case .database: return .database
        case .databaseSize: return .databaseSize
        case .destinationInfo: return .destinationInfo
        case .modificationTime: return .modificationTime
        case .databaseVersion: return .databaseVersion
        default: return .isPasswordProtected
        }
    }

    // MARK: - The parameters

    /// The names of the required strings of each command, as a rejection says them.
    private static func names(of command: SharedDatabaseCommand?) -> [String] {
        switch command {
        case .addToAlbum, .removeFromAlbum: return ["album parameters"]
        case .setAttribute: return ["object identifier", "value", "key"]
        case .fileDate: return ["path"]
        case .dicomSend: return ["AE title", "address", "port", "transfer syntax"]
        default: return []
        }
    }

    /// Reads the parameters from `start` in `bytes`; the bytes consumed count from the start of `bytes`.
    private mutating func readField(_ bytes: UnsafeRawBufferPointer, from start: Int) -> (event: Event, consumed: Int) {
        var offset = start
        while true {
            let rest = Self.part(of: bytes, from: offset)
            switch field {
            case .header, .finished:
                return (.needsMoreData, offset)

            case .strings(let needed, let optional):
                let index = strings.count
                switch Self.readString(rest) {
                case .needsMore: return (.needsMoreData, offset)
                case .rejected(let reason): return (.rejected(reason), offset)
                case .string(let value, let length):
                    if value == nil && !optional.contains(index) {
                        return (.rejected("missing \(Self.names(of: command)[index])"), offset)
                    }
                    offset += length
                    strings.append(value)
                    if strings.count == needed {
                        if command == .dicomSend {
                            field = .count
                        } else {
                            field = .finished
                            return (.complete(finishedStrings()), offset)
                        }
                    }
                }

            case .count:
                switch Self.readLength(rest, maximum: SharedDatabaseWire.maximumCount, what: "count") {
                case .needsMore: return (.needsMoreData, offset)
                case .rejected(let reason): return (.rejected(reason), offset)
                case .value(let value):
                    offset += 4
                    count = value
                    switch command {
                    case .upload, .generatedUpload: field = .fileLength
                    default: field = .paths
                    }
                }

            case .fileLength:
                if done == count {
                    field = .finished
                    return (.complete(.upload(generatedByViewer: command == .generatedUpload, fileCount: count)), offset)
                }
                switch Self.readLength(rest, maximum: SharedDatabaseWire.maximumFileLength, what: "file length") {
                case .needsMore: return (.needsMoreData, offset)
                case .rejected(let reason): return (.rejected(reason), offset)
                case .value(let value):
                    offset += 4
                    field = .fileBody(value)
                }

            case .fileBody(let length):
                // A file arrives in thousands of blocks: waiting for the rest is the usual state here.
                guard rest.count >= length else { return (.needsMoreData, offset) }
                let file = offset..<offset + length
                offset += length
                done += 1
                field = .fileLength
                return (.uploadedFile(file), offset)

            case .messageLength:
                switch Self.readLength(rest, maximum: SharedDatabaseWire.maximumStringLength, what: "message length") {
                case .needsMore: return (.needsMoreData, offset)
                case .rejected(let reason): return (.rejected(reason), offset)
                case .value(let value):
                    offset += 4
                    field = .messageBody(value)
                }

            case .messageBody(let length):
                guard rest.count >= length else { return (.needsMoreData, offset) }
                offset += length
                field = .finished
                return (.complete(.message), offset)

            case .paths:
                if done == count {
                    if command == .fetch {
                        field = .destinations
                        continue
                    }
                    field = .finished
                    return (.complete(.dicomSend(sendOrder())), offset)
                }
                // Every path these bytes hold, in one event; a field that stops
                // them (incomplete, refused) is read again by the next step.
                var paths: [String] = []
                reading: while done < count {
                    switch Self.readString(Self.part(of: bytes, from: offset)) {
                    case .needsMore:
                        break reading
                    case .rejected(let reason):
                        if paths.isEmpty { return (.rejected(reason), offset) }
                        break reading
                    case .string(let value, let length):
                        guard let value else {
                            if paths.isEmpty { return (.rejected("missing path"), offset) }
                            break reading
                        }
                        offset += length
                        done += 1
                        paths.append(value)
                    }
                }
                if paths.isEmpty { return (.needsMoreData, offset) }
                return (.requestedPaths(paths), offset)

            case .destinations:
                if destinations.count == count {
                    field = .finished
                    return (.complete(.fetch(destinations: destinations)), offset)
                }
                switch Self.readString(rest) {
                case .needsMore: return (.needsMoreData, offset)
                case .rejected(let reason): return (.rejected(reason), offset)
                case .string(let value, let length):
                    guard let value else { return (.rejected("missing destination path"), offset) }
                    offset += length
                    destinations.append(value)
                }

            case .password:
                // Its own framing, which older clients send: a length of 1 to
                // 4097 counting the terminator, read unsigned.
                guard rest.count >= 4 else { return (.needsMoreData, offset) }
                let length = Int(UInt32(bigEndian: rest.loadUnaligned(as: UInt32.self)))
                if length == 0 || length > SharedDatabaseEnvelope.maximumPasswordLength + 1 {
                    return (.refused, offset)
                }
                guard rest.count >= length + 4 else { return (.needsMoreData, offset) }
                offset += 4 + length
                guard rest[4 + length - 1] == 0 else { return (.refused, offset) }
                let password = NSString(bytes: rest.baseAddress! + 4, length: length - 1,
                                        encoding: String.Encoding.utf8.rawValue)
                field = .finished
                return (.complete(.password(password as String?)), offset)
            }
        }
    }

    private func finishedStrings() -> SharedDatabaseRequest {
        switch command {
        case .addToAlbum: return .album(adding: true, parameters: strings[0]!)
        case .removeFromAlbum: return .album(adding: false, parameters: strings[0]!)
        case .setAttribute: return .setAttribute(objectID: strings[0]!, value: strings[1], key: strings[2]!)
        default: return .fileDate(path: strings[0]!)
        }
    }

    private func sendOrder() -> SharedDatabaseSendOrder {
        SharedDatabaseSendOrder(aeTitle: strings[0]!, address: strings[1]!, port: strings[2]!,
                                transferSyntax: strings[3]!, files: [])
    }

    // MARK: - Fields

    /// `count` bytes of `bytes` from `offset` (all the rest by default), by
    /// address: thousands of fields are read per request, and a slice costs
    /// more than the field in an unoptimized build.
    @inline(__always)
    private static func part(of bytes: UnsafeRawBufferPointer, from offset: Int, count: Int? = nil) -> UnsafeRawBufferPointer {
        guard let base = bytes.baseAddress else { return bytes }
        return UnsafeRawBufferPointer(start: base + offset, count: count ?? bytes.count - offset)
    }

    private enum Length {
        case needsMore
        case rejected(String)
        case value(Int)
    }

    /// A 32-bit length or count, validated before anything is consumed: a
    /// negative value, or one above what the command can really carry, rejects
    /// the request.
    private static func readLength(_ bytes: UnsafeRawBufferPointer, maximum: Int, what: String) -> Length {
        guard bytes.count >= 4 else { return .needsMore }
        let raw = bytes.loadUnaligned(as: UInt32.self)
        let value = SharedDatabaseWire.validated(raw, maximum: maximum)
        if value < 0 {
            return .rejected("invalid \(what) (\(SharedDatabaseWire.signedValue(raw)))")
        }
        return .value(value)
    }

    private enum StringField {
        case needsMore
        case rejected(String)
        /// `length` counts the length field too.
        case string(String?, length: Int)
    }

    /// Zero length is how the client sends nil, so nil and "" stay distinct.
    /// Nothing is consumed until the whole string has arrived: a fragment
    /// boundary anywhere inside it resumes from the same place.
    private static func readString(_ bytes: UnsafeRawBufferPointer) -> StringField {
        guard bytes.count >= 4 else { return .needsMore }
        let raw = bytes.loadUnaligned(as: UInt32.self)
        let length = SharedDatabaseWire.validated(raw, maximum: SharedDatabaseWire.maximumStringLength)
        if length < 0 {
            return .rejected("invalid string length (\(SharedDatabaseWire.signedValue(raw)))")
        }
        guard bytes.count >= length + 4 else { return .needsMore }
        let (value, status) = SharedDatabaseWire.decodeString(part(of: bytes, from: 4, count: length))
        switch status {
        case .unterminated: return .rejected("string without its terminator")
        case .embeddedNull: return .rejected("string with an embedded terminator")
        case .invalidUTF8: return .rejected("string that is not UTF-8")
        case .value, .null: return .string(value, length: length + 4)
        }
    }
}
