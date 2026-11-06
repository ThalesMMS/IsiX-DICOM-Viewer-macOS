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
import Testing
@testable import IsiXDICOMNetwork

// MARK: - Building requests as the client sends them

private func integer(_ value: Int32) -> Data {
    withUnsafeBytes(of: UInt32(bitPattern: value).bigEndian) { Data($0) }
}

private func text(_ value: String?) -> Data {
    guard let value else { return integer(0) }
    var bytes = Data(value.utf8)
    bytes.append(0)
    return integer(Int32(bytes.count)) + bytes
}

private func command(_ name: String) -> Data {
    Data(name.utf8) + Data([0])
}

private let open = SharedDatabaseAccess(isPasswordProtected: false, password: nil)
private let protected = SharedDatabaseAccess(isPasswordProtected: true, password: "synthetic-é")

/// What a server sees of one event: an uploaded file by its bytes, and the
/// paths one by one, whatever the bytes that brought them together.
private enum Seen: Equatable {
    case refused
    case rejected(String)
    case uploadedFile(Data)
    case requestedPath(String)
    case complete(SharedDatabaseRequest)
}

/// What a server reading `chunks` one after another hands over: the events up
/// to the first that ends the request, and the bytes consumed.
private struct Transcript: Equatable {
    var events: [Seen] = []
    var consumed = 0
}

private func read(_ chunks: [Data], access: SharedDatabaseAccess = open) -> Transcript {
    var parser = SharedDatabaseRequestParser()
    var buffer = Data()
    var transcript = Transcript()
    for chunk in chunks {
        buffer.append(chunk)
        while true {
            let unread = Data(buffer.dropFirst(transcript.consumed))
            let (event, consumed) = unread.withUnsafeBytes { parser.next($0, access: { access }) }
            transcript.consumed += consumed
            switch event {
            case .needsMoreData:
                break
            case .refused:
                transcript.events.append(.refused)
                return transcript
            case .rejected(let reason):
                transcript.events.append(.rejected(reason))
                return transcript
            case .complete(let request):
                transcript.events.append(.complete(request))
                return transcript
            case .uploadedFile(let range):
                transcript.events.append(.uploadedFile(unread.subdata(in: range)))
                continue
            case .requestedPaths(let paths):
                #expect(!paths.isEmpty, "an event without a path")
                transcript.events += paths.map(Seen.requestedPath)
                continue
            }
            break
        }
    }
    return transcript
}

/// `request` cut at every byte boundary gives the same events as whole.
private func expectFragmentationInvariant(_ request: Data, access: SharedDatabaseAccess = open,
                                          sourceLocation: SourceLocation = #_sourceLocation) {
    let whole = read([request], access: access)
    for cut in 1..<request.count {
        let split = read([request.prefix(cut), request.dropFirst(cut)], access: access)
        #expect(split == whole, "cut at \(cut)", sourceLocation: sourceLocation)
    }
    let bytewise = read(request.map { Data([$0]) }, access: access)
    #expect(bytewise == whole, "byte by byte", sourceLocation: sourceLocation)
}

// MARK: - Requests

@Test func commandsWithoutParametersCompleteAtOnce() {
    let expected: [(String, SharedDatabaseRequest)] = [
        ("DATAB", .database), ("DBSIZ", .databaseSize), ("GETDI", .destinationInfo), ("VERSI", .modificationTime),
        ("DBVER", .databaseVersion), ("ISPWD", .isPasswordProtected), ("AUTHV", .authorizationVersion),
    ]
    for (name, request) in expected {
        let transcript = read([command(name)])
        #expect(transcript.events == [.complete(request)], "\(name)")
        #expect(transcript.consumed == 6)
    }
    #expect(read([command("DATA")]).events.isEmpty, "five bytes are not a command yet")
}

@Test func unknownMalformedAndUnterminatedCommandsAreRefused() {
    #expect(read([command("XXXXX")]).events == [.refused])
    #expect(read([Data("DATABX".utf8)]).events == [.refused], "the sixth byte must be the terminator")
    #expect(read([Data([0xff, 0xfe, 0x41, 0x41, 0x41, 0])]).events == [.refused], "a command that is not UTF-8")
    // A terminator inside ends the C string: "DB" is no command.
    #expect(read([Data([0x44, 0x42, 0, 0x41, 0x41, 0])]).events == [.refused])
}

@Test func setAttributeKeepsNilApartFromEmptyAndResumesAnywhere() {
    let request = command("SETVA") + text("x-coredata://a/Study/p1") + text(nil) + text("comment")
    #expect(read([request]).events == [.complete(.setAttribute(objectID: "x-coredata://a/Study/p1", value: nil, key: "comment"))])
    let empty = command("SETVA") + text("x-coredata://a/Study/p1") + text("") + text("comment")
    #expect(read([empty]).events == [.complete(.setAttribute(objectID: "x-coredata://a/Study/p1", value: "", key: "comment"))])
    expectFragmentationInvariant(request)
    expectFragmentationInvariant(empty)
    #expect(read([command("SETVA") + text(nil) + text("v") + text("comment")]).events == [.rejected("missing object identifier")])
    #expect(read([command("SETVA") + text("o") + text("v") + text(nil)]).events == [.rejected("missing key")])
}

@Test func albumsFileDatesAndMessages() {
    #expect(read([command("ADDAL") + text("<plist/>")]).events == [.complete(.album(adding: true, parameters: "<plist/>"))])
    #expect(read([command("REMAL") + text("<plist/>")]).events == [.complete(.album(adding: false, parameters: "<plist/>"))])
    #expect(read([command("ADDAL") + text(nil)]).events == [.rejected("missing album parameters")])
    #expect(read([command("MFILE") + text("12.dcm")]).events == [.complete(.fileDate(path: "12.dcm"))])
    #expect(read([command("MFILE") + text(nil)]).events == [.rejected("missing path")])
    let message = command("NEWMS") + integer(3) + Data("abc".utf8)
    #expect(read([message]).events == [.complete(.message)])
    #expect(read([message]).consumed == message.count)
    expectFragmentationInvariant(message)
    #expect(read([command("NEWMS") + integer(0)]).events == [.complete(.message)])
    #expect(read([command("NEWMS") + integer(-1)]).events == [.rejected("invalid message length (-1)")])
}

@Test func uploadsHandOverEachFileAsItArrives() {
    let first = Data(repeating: 7, count: 1000), second = Data()
    let request = command("SENDD") + integer(2) + integer(Int32(first.count)) + first + integer(0) + second
    #expect(read([request]).events == [.uploadedFile(first), .uploadedFile(second),
                                       .complete(.upload(generatedByViewer: false, fileCount: 2))])
    expectFragmentationInvariant(request)
    let generated = command("SENDG") + integer(1) + integer(1) + Data([9])
    #expect(read([generated]).events == [.uploadedFile(Data([9])), .complete(.upload(generatedByViewer: true, fileCount: 1))])
    #expect(read([command("SENDD") + integer(0)]).events == [.complete(.upload(generatedByViewer: false, fileCount: 0))])
    // A file is handed over before the next one has arrived.
    let partial = read([command("SENDD") + integer(2) + integer(1) + Data([1]) + integer(5) + Data([1, 2])])
    #expect(partial.events == [.uploadedFile(Data([1]))])
    #expect(read([command("SENDD") + integer(-5)]).events == [.rejected("invalid count (-5)")])
    #expect(read([command("SENDD") + integer(Int32(SharedDatabaseWire.maximumCount) + 1)]).events
            == [.rejected("invalid count (\(SharedDatabaseWire.maximumCount + 1))")])
    #expect(read([command("SENDD") + integer(1) + integer(-1)]).events == [.rejected("invalid file length (-1)")])
}

@Test func sendsAndFetchesHandOverEachPath() {
    let send = command("DCMSE") + text("PEER") + text("10.0.0.9") + text("11112") + text("1")
        + integer(2) + text("1.dcm") + text("/linked/2.dcm")
    let order = SharedDatabaseSendOrder(aeTitle: "PEER", address: "10.0.0.9", port: "11112", transferSyntax: "1", files: [])
    #expect(read([send]).events == [.requestedPath("1.dcm"), .requestedPath("/linked/2.dcm"), .complete(.dicomSend(order))])
    expectFragmentationInvariant(send)
    #expect(read([command("DCMSE") + text("PEER") + text(nil)]).events == [.rejected("missing address")])
    #expect(read([command("DCMSE") + text("A") + text("B") + text("C") + text("D") + integer(1) + text(nil)]).events
            == [.rejected("missing path")])

    let fetch = command("DICOM") + integer(2) + text("1.dcm") + text("2.dcm") + text("/client/a") + text("/client/b")
    #expect(read([fetch]).events == [.requestedPath("1.dcm"), .requestedPath("2.dcm"),
                                     .complete(.fetch(destinations: ["/client/a", "/client/b"]))])
    expectFragmentationInvariant(fetch)
    #expect(read([command("DICOM") + integer(0)]).events == [.complete(.fetch(destinations: []))])
    #expect(read([command("DICOM") + integer(1) + text("1.dcm") + text(nil)]).events
            == [.requestedPath("1.dcm"), .rejected("missing destination path")])
}

@Test func stringsAreCheckedBeforeAnythingIsConsumed() {
    let prefix = command("MFILE")
    #expect(read([prefix + integer(-1)]).events == [.rejected("invalid string length (-1)")])
    #expect(read([prefix + integer(Int32(SharedDatabaseWire.maximumStringLength) + 1)]).events
            == [.rejected("invalid string length (\(SharedDatabaseWire.maximumStringLength + 1))")])
    #expect(read([prefix + integer(3) + Data("abc".utf8)]).events == [.rejected("string without its terminator")])
    #expect(read([prefix + integer(4) + Data([0x61, 0, 0x62, 0])]).events == [.rejected("string with an embedded terminator")])
    #expect(read([prefix + integer(3) + Data([0xc3, 0x28, 0])]).events == [.rejected("string that is not UTF-8")])
    // Waiting for a string consumes nothing of it.
    let waiting = read([prefix + integer(10) + Data("abc".utf8)])
    #expect(waiting.events.isEmpty && waiting.consumed == 6)
}

@Test func passwordsUseTheirOwnFraming() {
    func paswd(_ bytes: [UInt8]) -> Data { command("PASWD") + integer(Int32(bytes.count)) + Data(bytes) }
    #expect(read([paswd(Array("secret".utf8) + [0])]).events == [.complete(.password("secret"))])
    #expect(read([paswd([0xc3, 0x28, 0])]).events == [.complete(.password(nil))], "not UTF-8: no password")
    #expect(read([paswd(Array("secret".utf8))]).events == [.refused], "without its terminator")
    #expect(read([command("PASWD") + integer(0)]).events == [.refused])
    #expect(read([command("PASWD") + integer(4098)]).events == [.refused])
    #expect(read([command("PASWD") + integer(-1)]).events == [.refused], "read unsigned")
    expectFragmentationInvariant(paswd(Array("secret".utf8) + [0]))

    #expect(open.accepts(nil) && open.accepts("anything"))
    #expect(protected.accepts("synthetic-é"))
    #expect(!protected.accepts("synthetic-e\u{301}"), "compared literally, without normalization")
    #expect(!protected.accepts(nil) && !protected.accepts("incorrect"))
    #expect(!SharedDatabaseAccess(isPasswordProtected: true, password: "").accepts(""))
}

@Test func aPasswordGatesEverythingButThePublicCommands() {
    for name in ["DBVER", "ISPWD", "PASWD", "AUTHV", "GETDI"] {
        #expect(read([command(name) + integer(1) + Data([0])], access: protected).events.first != .refused, "\(name)")
    }
    for name in ["DATAB", "DBSIZ", "VERSI", "SENDD", "SENDG", "NEWMS", "ADDAL", "REMAL", "SETVA", "MFILE", "DCMSE", "DICOM"] {
        #expect(read([command(name)], access: protected).events == [.refused], "\(name)")
        let wrapped = SharedDatabaseEnvelope.authenticatedRequest(command(name), password: "synthetic-é")!
        let parser = read([wrapped], access: protected)
        #expect(parser.events != [.refused], "\(name) with the password")
        let wrong = SharedDatabaseEnvelope.authenticatedRequest(command(name), password: "incorrect")!
        #expect(read([wrong], access: protected).events == [.refused], "\(name) with another password")
    }
    let wrapped = SharedDatabaseEnvelope.authenticatedRequest(command("SETVA"), password: "synthetic-é")!
        + text("o") + text("v") + text("comment")
    expectFragmentationInvariant(wrapped, access: protected)
    #expect(read([wrapped], access: protected).events == [.complete(.setAttribute(objectID: "o", value: "v", key: "comment"))])
    // Without a password asked, an envelope is read and its password not checked.
    let any = SharedDatabaseEnvelope.authenticatedRequest(command("DATAB"), password: "whatever")!
    #expect(read([any]).events == [.complete(.database)])
}

@Test func theBufferLimitFollowsTheRequest() {
    var parser = SharedDatabaseRequestParser()
    #expect(parser.isAwaitingCommand)
    #expect(parser.maximumBufferedBytes == SharedDatabaseWire.maximumBufferedBytesAwaitingCommand)
    var asked = 0
    _ = (command("SENDD") + integer(1)).withUnsafeBytes { parser.next($0, access: { asked += 1; return open }) }
    #expect(asked == 1 && !parser.isAwaitingCommand)
    #expect(parser.maximumBufferedBytes == SharedDatabaseWire.maximumBufferedBytesForUpload)
    var other = SharedDatabaseRequestParser()
    _ = command("DICOM").withUnsafeBytes { other.next($0, access: { open }) }
    #expect(other.maximumBufferedBytes == SharedDatabaseWire.maximumBufferedBytesForOtherRequests)
    var waiting = SharedDatabaseRequestParser()
    _ = Data("DAT".utf8).withUnsafeBytes { waiting.next($0, access: { asked += 1; return open }) }
    #expect(asked == 1, "the access rules are read only once a command is there")
}

@Test func commandsThatUseTheIndex() {
    let index: Set<SharedDatabaseCommand> = [.database, .databaseSize, .modificationTime, .upload, .generatedUpload,
                                             .addToAlbum, .removeFromAlbum, .setAttribute]
    for each in SharedDatabaseCommand.allCases {
        #expect(each.usesIndex == index.contains(each), "\(each)")
    }
}

// MARK: - The envelope and the wire

@Test func envelopeFramingAndAuthorization() {
    let request = command("DATAB")
    let password = "synthetic-é"
    let frame = SharedDatabaseEnvelope.authenticatedRequest(request, password: password)!
    for count in 0..<frame.count {
        #expect(SharedDatabaseEnvelope.authorizedPrefixLength(Data(frame.prefix(count)), password: password, required: true) == 0)
    }
    let consumed = SharedDatabaseEnvelope.authorizedPrefixLength(frame, password: password, required: true)
    #expect(consumed > 0 && Data(frame.dropFirst(consumed)) == request)
    #expect(SharedDatabaseEnvelope.authorizedPrefixLength(frame, password: "incorrect", required: true) == -1)
    #expect(SharedDatabaseEnvelope.authorizedPrefixLength(frame, password: nil, required: true) == -1)
    #expect(SharedDatabaseEnvelope.authorizedPrefixLength(frame, password: nil, required: false) == consumed)
    var huge = frame
    huge.replaceSubrange(6..<10, with: [255, 255, 255, 255])
    #expect(SharedDatabaseEnvelope.authorizedPrefixLength(huge, password: password, required: true) == -1)
    var bad = frame
    bad[bad.count - 1] = 1
    #expect(SharedDatabaseEnvelope.authorizedPrefixLength(bad, password: password, required: true) == -1)
    #expect(SharedDatabaseEnvelope.authenticatedRequest(request, password: "") == nil)
    #expect(SharedDatabaseEnvelope.authenticatedRequest(request, password: String(repeating: "x", count: 4097)) == nil)
    #expect(SharedDatabaseEnvelope.authenticatedRequest(command("AUTHR"), password: password) == nil)
    let offset = (Data([0, 0]) + frame).dropFirst(2)
    #expect(SharedDatabaseEnvelope.authorizedPrefixLength(offset, password: password, required: true) == consumed)
    #expect(SharedDatabaseEnvelope.requestInsideEnvelope(frame) == request)
    #expect(SharedDatabaseEnvelope.requestInsideEnvelope(request) == request)
}

@Test func wireLengthsAndStrings() {
    #expect(SharedDatabaseWire.validated(UInt32(5).bigEndian, maximum: 10) == 5)
    #expect(SharedDatabaseWire.validated(UInt32(11).bigEndian, maximum: 10) == -1)
    #expect(SharedDatabaseWire.validated(UInt32.max.bigEndian, maximum: 10) == -1)
    func decode(_ bytes: [UInt8]) -> (String?, SharedDatabaseWire.StringStatus) {
        bytes.withUnsafeBytes { let result = SharedDatabaseWire.decodeString($0); return (result.value, result.status) }
    }
    #expect(decode([]) == (nil, .null))
    #expect(decode([0]) == ("", .value))
    #expect(decode([0x61, 0x62, 0]) == ("ab", .value))
    #expect(decode([0x61]) == (nil, .unterminated))
    #expect(decode([0, 0]) == (nil, .embeddedNull))
    #expect(decode([0xff, 0]) == (nil, .invalidUTF8))
}

// MARK: - Replies

@Test func repliesAreBigEndian() {
    #expect(SharedDatabaseReply.authorizationVersion == Data([0, 0, 0, 1]))
    #expect(SharedDatabaseReply.answer(true) == Data([0, 0, 0, 1]))
    #expect(SharedDatabaseReply.answer(false) == Data([0, 0, 0, 0]))
    #expect(SharedDatabaseReply.indexSize(0x0102_0304) == Data([1, 2, 3, 4]))
    #expect(SharedDatabaseReply.indexSize(UInt64(UInt32.max)) == Data([255, 255, 255, 255]))
    #expect(SharedDatabaseReply.indexSize(5 << 32) == Data([255, 255, 255, 255]))
    #expect(SharedDatabaseReply.modificationTime(1234.5) == withUnsafeBytes(of: (1234.5).bitPattern.bigEndian) { Data($0) })
    #expect(SharedDatabaseReply.upload(pathNumbers: [1, -1]) == Data([0, 0, 0, 2, 0, 0, 0, 1, 255, 255, 255, 255]))
    #expect(SharedDatabaseReply.fetchCount(3) == Data([0, 0, 0, 3]))
    let destination = SharedDatabaseReply.destinationPath("/a")
    #expect(destination.length == Data([0, 0, 0, 3]) && destination.path == Data([0x2f, 0x61, 0]))
    #expect(SharedDatabaseReply.databaseVersion("2.5") == Data("2.5".utf8))
    #expect(SharedDatabaseReply.databaseVersion(nil) == nil)
    #expect(SharedDatabaseReply.fileDate("d") == Data([0xff, 0xfe, 0x64, 0]), "UTF-16 with its byte order mark")
    #expect(SharedDatabaseReply.destinationInfo(aeTitle: "A", port: "1", transferSyntax: 5).map { [$0.key, $0.value] }
            == [["AETitle", "A"], ["Port", "1"], ["TransferSyntax", "5"]])
    #expect(SharedDatabaseReply.destinationInfo(aeTitle: "A", port: nil, transferSyntax: 5).map(\.key) == ["AETitle"],
            "stops at the first missing value")
    #expect(SharedDatabaseReply.destinationInfo(aeTitle: nil, port: "1", transferSyntax: 5).isEmpty)
}

@Test func sendOrdersReadTheirNumbersAsTextAndResolveLoopback() {
    let order = SharedDatabaseSendOrder(aeTitle: "A", address: "127.0.0.1", port: " 104abc", transferSyntax: "x", files: ["1"])
    #expect(order.portNumber == 104 && order.transferSyntaxNumber == 0)
    #expect(order.resolvingLoopback(peerAddress: "10.0.0.2").address == "10.0.0.2")
    var other = order
    other.address = "10.0.0.9"
    #expect(other.resolvingLoopback(peerAddress: "10.0.0.2") == other)
}
