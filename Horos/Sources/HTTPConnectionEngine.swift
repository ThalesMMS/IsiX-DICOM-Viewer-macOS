//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import CFNetwork
import Foundation
import IsiXHTTPServer
import NIOCore
import NIOHTTP1

/// A response body the portal sends: a length (or chunks), read from an offset.
protocol HTTPServerResponse: AnyObject {
    /// The length of the body; not read for a chunked body.
    var contentLength: UInt64 { get }
    /// Where the next read starts; set to the start of each range of a Range request.
    var offset: UInt64 { get set }
    /// Up to `length` bytes from `offset`, which moves past them.
    func readData(ofLength length: Int) -> Data?
    /// Whether every byte has been read.
    var isDone: Bool { get }
    /// A body of unknown length, sent with Transfer-Encoding: chunked.
    var isChunked: Bool { get }
    /// The header fields the response adds to (and replaces in) the head.
    var responseHeaderFields: [(String, String)] { get }
    /// The connection is done with the response, or closed.
    func connectionDidClose()
}

/// What a connection's application code (the web portal's page code) does with
/// each step of a request. Everything here runs on the connection's worker
/// thread, one request at a time.
protocol HTTPConnectionEngineDelegate: AnyObject {
    /// Whether `method` is served at `path`.
    func supportsMethod(_ method: String!, atPath path: String!) -> Bool
    /// A piece of the request body: pieces of `HTTPServerLimits.portalRequestBodyPiece`
    /// bytes, the last one shorter.
    func processDataChunk(_ data: Data!)
    /// The request is complete: answer it, normally through `engine.replyWithResponse()`.
    func replyToHTTPRequest()
    func isPasswordProtected(_ path: String!) -> Bool
    func isAuthenticated() -> Bool
    /// Answers a request that needs authentication, through `engine.sendErrorResponse`.
    func handleAuthenticationFailed()
    /// The response to a request, nil when there is none.
    func httpServerResponse(forMethod method: String, uri path: String) -> HTTPServerResponse?
    /// Answers a request that has no response, through `engine.sendErrorResponse`.
    func handleResourceNotFound()
    /// The connection is closed; called once, last.
    func connectionDidDie()
}

/// The HTTP/1.1 exchange of one connection of the web portal: it validates
/// each request, hands its body over in pieces, asks the page code for the
/// answer and sends it, whole or by ranges, then waits for the next request on
/// the same connection.
///
/// It lives on the connection's worker thread; its channel handler does the
/// network side on the connection's event loop.
final class HTTPConnectionEngine: @unchecked Sendable {
    let worker: HTTPServerWorker
    /// The peer's IP address, as the log and the access rules show it.
    let remoteHost: String?
    private let channel: Channel
    private let handler: NIOLoopBound<HTTPConnectionChannelHandler>
    private var delegate: HTTPConnectionEngineDelegate?
    private let onDie: (HTTPConnectionEngine) -> Void

    /// The request being answered.
    private(set) var request: CFHTTPMessage?
    private var method = ""
    private var path = ""
    private var rejected = false

    // The response being sent.
    private var response: HTTPServerResponse?
    private var ranges: [HTTPByteRange]?
    private var multipart: HTTPMultipartByteRanges?
    private var rangeIndex = 0
    private var isChunked = false
    private var bytesInFlight = 0
    private var bodyFinished = false
    private var dead = false

    init(channel: Channel, handler: HTTPConnectionChannelHandler, worker: HTTPServerWorker,
         delegate: HTTPConnectionEngineDelegate, onDie: @escaping (HTTPConnectionEngine) -> Void) {
        self.channel = channel
        self.handler = NIOLoopBound(handler, eventLoop: channel.eventLoop)
        self.worker = worker
        self.delegate = delegate
        self.remoteHost = channel.remoteAddress?.ipAddress
        self.onDie = onDie
    }

    // MARK: Requests (worker thread)

    func receiveHead(_ head: HTTPRequestHead) {
        guard !dead else { return }
        request = Self.message(for: head)
        method = head.method.rawValue
        let url = request.flatMap { CFHTTPMessageCopyRequestURL($0)?.takeRetainedValue() } as NSURL?
        path = url?.relativeString ?? ""
        rejected = false
        let supported = delegate?.supportsMethod(method, atPath: path) ?? false
        switch HTTPRequestRules.decision(method: method, contentLength: head.headers.first(name: "Content-Length"),
                                         isSupported: supported) {
        case .badRequest:
            rejected = true
            NSLog("HTTP Server: Error 400 - Bad Request")
            sendErrorResponse(status: 400, headers: [("Content-Length", "0"), ("Connection", "close")], body: nil, closeAfter: true)
        case .methodNotAllowed:
            rejected = true
            NSLog("HTTP Server: Error 405 - Method Not Allowed: %@", method)
            sendErrorResponse(status: 405, headers: [("Content-Length", "0"), ("Connection", "close")], body: nil, closeAfter: true)
        case .noBody, .readBody:
            break
        }
    }

    func receiveBodyPiece(_ piece: Data) {
        guard !dead, !rejected else { return }
        delegate?.processDataChunk(piece)
    }

    func receiveEnd() {
        guard !dead, !rejected else { return }
        delegate?.replyToHTTPRequest()
    }

    /// The header of the former parser for this request: the portal reads its
    /// method, URL and fields from it.
    static func message(for head: HTTPRequestHead) -> CFHTTPMessage? {
        var text = "\(head.method.rawValue) \(head.uri) HTTP/\(head.version.major).\(head.version.minor)\r\n"
        for (name, value) in head.headers {
            text += "\(name): \(value)\r\n"
        }
        text += "\r\n"
        let message = CFHTTPMessageCreateEmpty(kCFAllocatorDefault, true).takeRetainedValue()
        let bytes = Array(text.utf8)
        guard CFHTTPMessageAppendBytes(message, bytes, bytes.count), CFHTTPMessageIsHeaderComplete(message) else {
            return nil
        }
        return message
    }

    // MARK: Answers (worker thread)

    /// The usual answer: version, authentication, then the response the
    /// delegate gives, whole or by the ranges asked.
    func replyWithResponse() {
        guard let request, let delegate else { return }
        let version = CFHTTPMessageCopyVersion(request).takeRetainedValue() as String
        guard version == (kCFHTTPVersion1_1 as String) else {
            NSLog("HTTP Server: Error 505 - Version Not Supported: %@", version)
            sendErrorResponse(status: 505, headers: [("Content-Length", "0")], body: nil, closeAfter: false)
            return
        }
        if delegate.isPasswordProtected(path) && !delegate.isAuthenticated() {
            delegate.handleAuthenticationFailed()
            return
        }
        guard let response = delegate.httpServerResponse(forMethod: method, uri: path) else {
            delegate.handleResourceNotFound()
            return
        }
        send(response)
    }

    /// An answer whose body is already known, headed with the date.
    func sendErrorResponse(status: Int, headers: [(String, String)], body: Data?, closeAfter: Bool) {
        guard !dead else { return }
        let message = CFHTTPMessageCreateResponse(kCFAllocatorDefault, status, nil, kCFHTTPVersion1_1).takeRetainedValue()
        for (name, value) in headers {
            CFHTTPMessageSetHeaderFieldValue(message, name as CFString, value as CFString)
        }
        addStandardFields(to: message)
        if let body {
            CFHTTPMessageSetBody(message, body as CFData)
        }
        let data = CFHTTPMessageCopySerializedMessage(message)?.takeRetainedValue() as Data? ?? Data()
        write(data, deadline: true) { [self] in
            if closeAfter {
                closeConnection()
            } else {
                requestDone()
            }
        }
    }

    private func addStandardFields(to message: CFHTTPMessage) {
        CFHTTPMessageSetHeaderFieldValue(message, "Date" as CFString, HTTPDateHeader.string() as CFString)
        CFHTTPMessageSetHeaderFieldValue(message, "Accept-Ranges" as CFString, "bytes" as CFString)
        for (name, value) in response?.responseHeaderFields ?? [] {
            CFHTTPMessageSetHeaderFieldValue(message, name as CFString, value as CFString)
        }
    }

    private func send(_ response: HTTPServerResponse) {
        self.response = response
        isChunked = response.isChunked
        let contentLength = isChunked ? 0 : response.contentLength
        let rangeHeader = request.flatMap { CFHTTPMessageCopyHeaderFieldValue($0, "Range" as CFString)?.takeRetainedValue() } as String?
        ranges = nil
        multipart = nil
        rangeIndex = 0
        if !isChunked, let rangeHeader {
            ranges = HTTPByteRangeRequest.ranges(fromHeader: rangeHeader, contentLength: contentLength)
        }

        let message: CFHTTPMessage
        if let ranges {
            message = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 206, nil, kCFHTTPVersion1_1).takeRetainedValue()
            if ranges.count == 1 {
                CFHTTPMessageSetHeaderFieldValue(message, "Content-Length" as CFString, "\(ranges[0].length)" as CFString)
                CFHTTPMessageSetHeaderFieldValue(message, "Content-Range" as CFString,
                                                 "bytes \(ranges[0].firstLastDescription)/\(contentLength)" as CFString)
            } else {
                let framing = HTTPMultipartByteRanges(ranges: ranges, contentLength: contentLength)
                multipart = framing
                CFHTTPMessageSetHeaderFieldValue(message, "Content-Length" as CFString, "\(framing.bodyLength)" as CFString)
                CFHTTPMessageSetHeaderFieldValue(message, "Content-Type" as CFString, framing.contentType as CFString)
            }
        } else {
            message = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 200, nil, kCFHTTPVersion1_1).takeRetainedValue()
            if isChunked {
                CFHTTPMessageSetHeaderFieldValue(message, "Transfer-Encoding" as CFString, "chunked" as CFString)
            } else {
                CFHTTPMessageSetHeaderFieldValue(message, "Content-Length" as CFString, "\(contentLength)" as CFString)
            }
        }
        addStandardFields(to: message)
        let head = CFHTTPMessageCopySerializedMessage(message)?.takeRetainedValue() as Data? ?? Data()

        let headOnly = method == "HEAD" || (!isChunked && contentLength == 0)
        bodyFinished = headOnly
        write(head, deadline: true) { [self] in
            if headOnly { responseDone() }
        }
        if headOnly { return }
        if let ranges, ranges.count > 1, let multipart {
            write(multipart.partHeader(0), deadline: true)
            response.offset = ranges[0].location
        } else if let ranges {
            response.offset = ranges[0].location
        }
        continueSending()
    }

    /// Reads more of the body while less than `responseReadAhead` bytes are
    /// waiting to leave, and sends it.
    private func continueSending() {
        guard let response, !dead else { return }
        while !bodyFinished && bytesInFlight < HTTPServerLimits.responseReadAhead {
            let available = HTTPServerLimits.responseReadAhead - bytesInFlight
            if let ranges {
                let range = ranges[rangeIndex]
                let read = response.offset &- range.location
                let left = range.length &- read
                if left == 0 {
                    // This range is sent: the next one, or the end of the body.
                    if ranges.count > 1, let multipart {
                        rangeIndex += 1
                        if rangeIndex < ranges.count {
                            write(multipart.partHeader(rangeIndex), deadline: true)
                            response.offset = ranges[rangeIndex].location
                            continue
                        }
                        finishBody(with: multipart.closingBoundary, deadline: true)
                    } else {
                        finishBody(with: nil, deadline: false)
                    }
                    return
                }
                guard let data = response.readData(ofLength: Int(min(left, UInt64(available)))), !data.isEmpty else {
                    abandonResponse()
                    return
                }
                writeBody(data)
            } else {
                if response.isDone && !isChunked {
                    finishBody(with: nil, deadline: false)
                    return
                }
                guard let data = response.readData(ofLength: available), !data.isEmpty else {
                    if isChunked && response.isDone {
                        finishBody(with: Data(HTTPChunkedFraming.footer.dropFirst(2)), deadline: true)
                    } else {
                        abandonResponse()
                    }
                    return
                }
                if isChunked {
                    write(HTTPChunkedFraming.sizeLine(data.count), deadline: true)
                    writeBody(data)
                    if response.isDone {
                        finishBody(with: HTTPChunkedFraming.footer, deadline: true)
                        return
                    }
                    write(HTTPChunkedFraming.chunkEnd, deadline: true)
                } else {
                    writeBody(data)
                }
            }
        }
    }

    private func writeBody(_ data: Data) {
        bytesInFlight += data.count
        write(data, deadline: false) { [self] in
            bytesInFlight -= data.count
            continueSending()
        }
    }

    /// The last bytes of the body: once they and those before them have left,
    /// the response is done.
    private func finishBody(with trailer: Data?, deadline: Bool) {
        bodyFinished = true
        write(trailer ?? Data(), deadline: deadline) { [self] in
            responseDone()
        }
    }

    /// A response that stops giving the bytes it announced cannot end; the
    /// connection is closed rather than left waiting.
    private func abandonResponse() {
        bodyFinished = true
        closeConnection()
    }

    private func responseDone() {
        response?.connectionDidClose()
        response = nil
        ranges = nil
        multipart = nil
        requestDone()
    }

    private func requestDone() {
        request = nil
        let handler = self.handler
        channel.eventLoop.execute {
            handler.value.readyForNextRequest()
        }
    }

    // MARK: Network (any thread)

    private func write(_ data: Data, deadline: Bool, completion: (() -> Void)? = nil) {
        let handler = self.handler
        let worker = self.worker
        let done: (@Sendable () -> Void)? = completion.map { completion in
            let box = UncheckedSendableBox(completion)
            return { worker.perform { box.value() } }
        }
        let payload = UncheckedSendableBox(data)
        channel.eventLoop.execute {
            handler.value.write(payload.value, deadline: deadline, completion: done)
        }
    }

    func closeConnection() {
        let handler = self.handler
        channel.eventLoop.execute {
            handler.value.closeAfterWrites()
        }
    }

    /// The bytes of a piece were handed over; the handler may read the next.
    func pieceConsumed() {
        let handler = self.handler
        channel.eventLoop.execute {
            handler.value.pieceConsumed()
        }
    }

    // MARK: End (worker thread)

    func die() {
        guard !dead else { return }
        dead = true
        response?.connectionDidClose()
        response = nil
        let delegate = self.delegate
        self.delegate = nil
        delegate?.connectionDidDie()
        onDie(self)
    }
}

/// A value handed between threads that only one of them uses at a time.
struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// The network side of a portal connection, on its event loop: it reads
/// requests through the HTTP/1.1 decoder, hands each to the engine, gathers
/// upload bodies into pieces, writes what the engine sends with the portal's
/// header deadline, and reads the next request only once the answer is out.
final class HTTPConnectionChannelHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = ByteBuffer

    private enum Phase {
        case waitingForHead
        case receiving
        case answering
        case closing
    }

    private let makeEngine: (Channel, HTTPConnectionChannelHandler) -> HTTPConnectionEngine?
    private var engine: HTTPConnectionEngine?
    private var context: ChannelHandlerContext?
    private var phase = Phase.waitingForHead
    private var queued: [HTTPServerRequestPart] = []
    private var piece = Data()
    private var pieceLength = 0
    private var bodyRemaining: UInt64 = 0
    private var waitingForEngine = false
    private var pendingWrites = 0
    private var reading = false
    private let headerDeadline: TimeAmount

    init(headerDeadline: TimeInterval = HTTPServerLimits.portalHeaderWriteDeadline,
         makeEngine: @escaping (Channel, HTTPConnectionChannelHandler) -> HTTPConnectionEngine?) {
        self.headerDeadline = .milliseconds(Int64(headerDeadline * 1000))
        self.makeEngine = makeEngine
    }

    /// What reads this handler's requests: the portal's header limits, then
    /// the HTTP/1.1 decoder. Add them before the handler, in this order.
    static func decoders() -> [ChannelHandler] {
        [HTTPRequestHeadLimiter(), ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .dropBytes))]
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func channelActive(context: ChannelHandlerContext) {
        engine = makeEngine(context.channel, self)
        if engine == nil {
            context.close(promise: nil)
            return
        }
        readIfWanted()
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        phase = .closing
        if let engine {
            engine.worker.perform { engine.die() }
        }
        engine = nil
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        if !queued.isEmpty || !accepts(part) {
            queued.append(part)
            return
        }
        handle(part)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        reading = false
        readIfWanted()
        context.fireChannelReadComplete()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if let parserError = error as? HTTPParserError {
            if case .headerOverflow = parserError {
                // A header line or a header too long: the connection is
                // dropped without an answer, as it always was.
                context.close(promise: nil)
                return
            }
            if phase == .waitingForHead || phase == .receiving, let engine {
                phase = .closing
                engine.worker.perform {
                    NSLog("HTTP Server: Error 400 - Bad Request")
                    engine.sendErrorResponse(status: 400, headers: [("Content-Length", "0"), ("Connection", "close")],
                                             body: nil, closeAfter: true)
                }
                return
            }
        }
        context.close(promise: nil)
    }

    private func accepts(_ part: HTTPServerRequestPart) -> Bool {
        switch part {
        case .head: return phase == .waitingForHead
        case .body: return phase == .receiving && !waitingForEngine
        case .end: return phase == .receiving && !waitingForEngine
        }
    }

    private func handle(_ part: HTTPServerRequestPart) {
        guard let engine else { return }
        switch part {
        case .head(let head):
            phase = .receiving
            piece = Data()
            let declared = head.headers.first(name: "Content-Length").flatMap { HTTPByteRangeRequest.parseUInt64($0) } ?? 0
            bodyRemaining = HTTPRequestRules.expectsBody(method: head.method.rawValue) ? declared : 0
            pieceLength = Int(min(bodyRemaining, UInt64(HTTPServerLimits.portalRequestBodyPiece)))
            let box = UncheckedSendableBox(head)
            engine.worker.perform { engine.receiveHead(box.value) }
        case .body(var buffer):
            while buffer.readableBytes > 0 && bodyRemaining > 0 {
                let take = min(buffer.readableBytes, pieceLength - piece.count)
                piece.append(contentsOf: buffer.readBytes(length: take) ?? [])
                if piece.count == pieceLength {
                    handOverPiece()
                    if buffer.readableBytes > 0 {
                        // The rest waits until the engine has taken this piece.
                        queued.insert(.body(buffer), at: 0)
                        return
                    }
                }
            }
        case .end(let trailers):
            if !piece.isEmpty {
                // The last piece first; the end waits until the engine has it.
                handOverPiece()
                queued.insert(.end(trailers), at: 0)
                return
            }
            phase = .answering
            engine.worker.perform { engine.receiveEnd() }
        }
    }

    private func handOverPiece() {
        guard let engine else { return }
        let data = UncheckedSendableBox(piece)
        bodyRemaining -= UInt64(piece.count)
        pieceLength = Int(min(bodyRemaining, UInt64(HTTPServerLimits.portalRequestBodyPiece)))
        piece = Data()
        waitingForEngine = true
        engine.worker.perform {
            engine.receiveBodyPiece(data.value)
            engine.pieceConsumed()
        }
    }

    /// The engine has taken the last piece.
    func pieceConsumed() {
        waitingForEngine = false
        drainQueue()
        readIfWanted()
    }

    /// The answer is out: the next request may be read.
    func readyForNextRequest() {
        guard phase != .closing else { return }
        phase = .waitingForHead
        drainQueue()
        readIfWanted()
    }

    private func drainQueue() {
        while let part = queued.first, accepts(part) {
            queued.removeFirst()
            handle(part)
            if waitingForEngine { break }
        }
    }

    private func readIfWanted() {
        guard let context, !reading, queued.isEmpty, context.channel.isActive else { return }
        let wanted: Bool
        switch phase {
        case .waitingForHead: wanted = true
        case .receiving: wanted = !waitingForEngine
        case .answering, .closing: wanted = false
        }
        if wanted {
            reading = true
            context.read()
        }
    }

    /// Writes `data`; with a deadline, a write still pending after the
    /// portal's header deadline closes the connection.
    func write(_ data: Data, deadline: Bool, completion: (@Sendable () -> Void)?) {
        guard let context, context.channel.isActive else { return }
        var buffer = context.channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        let promise = context.eventLoop.makePromise(of: Void.self)
        pendingWrites += 1
        if deadline {
            let channel = context.channel
            let timeout = context.eventLoop.scheduleTask(in: headerDeadline) {
                channel.close(promise: nil)
            }
            promise.futureResult.whenComplete { _ in timeout.cancel() }
        }
        let bound = NIOLoopBound(self, eventLoop: context.eventLoop)
        promise.futureResult.whenComplete { result in
            bound.value.writeCompleted()
            if case .success = result {
                completion?()
            }
        }
        context.writeAndFlush(wrapOutboundOut(buffer), promise: promise)
    }

    private func writeCompleted() {
        pendingWrites -= 1
        if phase == .closing && pendingWrites == 0 {
            context?.close(promise: nil)
        }
    }

    /// Closes the connection once what was written has left.
    func closeAfterWrites() {
        phase = .closing
        if pendingWrites == 0 {
            context?.close(promise: nil)
        }
    }
}

/// Holds a connection's request headers to the portal's limits before the
/// decoder buffers them (HTTPRequestHeadScanner): a connection whose header has
/// a line too long, or too many lines, is closed without an answer.
final class HTTPRequestHeadLimiter: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private var scanner = HTTPRequestHeadScanner()
    private var closed = false

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !closed else { return }
        let buffer = unwrapInboundIn(data)
        let verdict = buffer.withUnsafeReadableBytes { scanner.scan($0) }
        guard verdict == .withinLimits else {
            closed = true
            context.close(promise: nil)
            return
        }
        context.fireChannelRead(data)
    }
}
