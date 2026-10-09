//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation

/// Filling in the placeholders of a modern Pages document's own header and
/// footer, in the file, before Pages opens it.
///
/// Everything else in a modern template is filled in by Pages over AppleScript,
/// but Pages' scripting dictionary has no header and no footer, and a letterhead
/// is very often made there: a template converted from Pages '09 keeps every
/// field of its letterhead in the header and footer, and its report came out
/// with all of them still written as placeholders.
///
/// A modern Pages document keeps its text in `Index/*.iwa`: a stream of
/// protocol buffer messages, cut in chunks that are each compressed with
/// Snappy. A header or a footer is a `TSWP.StorageArchive` (message type 2001)
/// of kind HEADER, which footers share: its text, and beside it tables that
/// say from which character on a paragraph style, a character style, a
/// placeholder field, a language and so on apply. A placeholder is replaced in
/// the text and every table index after it is moved by the difference in
/// length, so the styles stay where they were - measured with Pages 15.4 on a
/// template converted from Pages '09: it opened without a word and exported a
/// PDF with the header and footer filled in and laid out as before.
///
/// What is not understood is left alone, never guessed at: a text whose fields
/// are not those known shapes, a message Pages marked to be merged with another,
/// or a placeholder that runs across a paragraph break or an object anchored in
/// the text. A placeholder Pages itself made - its `«name»` shown as the
/// template's placeholder text - stays a placeholder around the value, which is
/// what the Pages '09 fill does too: it prints as text, and a click selects it
/// whole.
enum PagesHeaderFooterFill {

    enum Failure: Error {
        case malformed(String)
        case archive(String)
    }

    /// Fills in the headers and footers of the Pages document at `path`, a
    /// single file or a package, in place. `substitute` is given a placeholder,
    /// guillemets included, and answers it unchanged to leave it as written.
    /// false when the document could not be read or written, and then the file is
    /// as it was; a document with nothing to fill in is not rewritten at all.
    @discardableResult
    static func fill(documentAt path: String, substitute: (String) -> String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }
        do {
            if isDirectory.boolValue {
                try fillPackage(at: URL(fileURLWithPath: path), substitute)
            } else {
                try fillArchive(at: path, substitute)
            }
            return true
        } catch {
            NSLog("---- the header and footer of the Pages report could not be filled in: %@", String(describing: error))
            return false
        }
    }

    private static func isIndexFile(_ name: String) -> Bool {
        name.hasPrefix("Index/") && name.lowercased().hasSuffix(".iwa")
    }

    private static func fillPackage(at package: URL, _ substitute: (String) -> String) throws {
        let index = package.appendingPathComponent("Index")
        guard let files = FileManager.default.enumerator(at: index, includingPropertiesForKeys: nil) else { return }
        for case let file as URL in files where file.pathExtension.lowercased() == "iwa" {
            let data = [UInt8](try Data(contentsOf: file))
            if let filled = try fill(iwa: data, substitute: substitute) {
                try Data(filled).write(to: file, options: .atomic)
            }
        }
    }

    // MARK: the single-file document, a ZIP archive

    private struct Entry {
        let name: String
        let directory: Bool
        var data: [UInt8]
    }

    /// The archive is read whole, the index files are filled in, and it is
    /// written again, entry by entry in the same order and stored without
    /// compression, as Pages writes it, beside the original, which it then
    /// replaces in one rename.
    private static func fillArchive(at path: String, _ substitute: (String) -> String) throws {
        var entries = try readArchive(path)
        var changed = false
        for position in entries.indices where !entries[position].directory && isIndexFile(entries[position].name) {
            if let filled = try fill(iwa: entries[position].data, substitute: substitute) {
                entries[position].data = filled
                changed = true
            }
        }
        guard changed else { return }
        let output = path + ".filling"
        defer { try? FileManager.default.removeItem(atPath: output) }
        try writeArchive(entries, to: output)
        guard rename(output, path) == 0 else { throw Failure.archive("the filled-in report could not replace the copy") }
    }

    private static func readArchive(_ path: String) throws -> [Entry] {
        guard let reader = archive_read_new() else { throw Failure.archive("no reader") }
        defer { archive_read_free(reader) }
        guard archive_read_support_format_zip(reader) == ARCHIVE_OK,
              archive_read_open_filename(reader, path, 65536) == ARCHIVE_OK
        else { throw Failure.archive("not a ZIP archive") }
        var entries: [Entry] = []
        var header: OpaquePointer?
        while true {
            let status = archive_read_next_header(reader, &header)
            if status == ARCHIVE_EOF { break }
            guard status == ARCHIVE_OK, let header, let raw = archive_entry_pathname_utf8(header) else {
                throw Failure.archive("unreadable entry")
            }
            let name = String(cString: raw)
            switch archive_entry_filetype(header) {
            case 0o040000:
                entries.append(Entry(name: name, directory: true, data: []))
            case 0o100000:
                var data: [UInt8] = []
                var buffer = [UInt8](repeating: 0, count: 65536)
                while true {
                    let count = buffer.withUnsafeMutableBytes { archive_read_data(reader, $0.baseAddress, $0.count) }
                    if count == 0 { break }
                    guard count > 0 else { throw Failure.archive("unreadable data in \(name)") }
                    data.append(contentsOf: buffer[0..<count])
                }
                entries.append(Entry(name: name, directory: false, data: data))
            default:
                throw Failure.archive("\(name) is neither a file nor a folder")
            }
        }
        return entries
    }

    private static func writeArchive(_ entries: [Entry], to path: String) throws {
        guard let writer = archive_write_new() else { throw Failure.archive("no writer") }
        defer { archive_write_free(writer) }
        guard archive_write_set_format_zip(writer) == ARCHIVE_OK,
              archive_write_set_options(writer, "zip:compression=store") == ARCHIVE_OK,
              archive_write_open_filename(writer, path) == ARCHIVE_OK
        else { throw Failure.archive("the archive could not be created") }
        for entry in entries {
            guard let header = archive_entry_new() else { throw Failure.archive("no entry") }
            defer { archive_entry_free(header) }
            archive_entry_set_pathname(header, entry.name)
            archive_entry_set_filetype(header, entry.directory ? 0o040000 : 0o100000)
            archive_entry_set_perm(header, entry.directory ? 0o755 : 0o644)
            archive_entry_set_size(header, la_int64_t(entry.data.count))
            guard archive_write_header(writer, header) == ARCHIVE_OK else { throw Failure.archive("\(entry.name) could not be written") }
            var offset = 0
            while offset < entry.data.count {
                let count = entry.data[offset...].withUnsafeBytes { archive_write_data(writer, $0.baseAddress, $0.count) }
                guard count > 0 else { throw Failure.archive("\(entry.name) could not be written") }
                offset += count
            }
        }
        guard archive_write_close(writer) == ARCHIVE_OK else { throw Failure.archive("the archive could not be closed") }
    }

    // MARK: an IWA file

    /// The IWA file `data` with the placeholders of its headers and footers
    /// filled in; nil when it has none to fill in.
    static func fill(iwa data: [UInt8], substitute: (String) -> String) throws -> [UInt8]? {
        let stream = try decompress(data)
        var output: [UInt8] = []
        output.reserveCapacity(stream.count)
        var changed = false
        var offset = 0
        while offset < stream.count {
            let start = offset
            // An object: the length of its ArchiveInfo, the ArchiveInfo, and
            // then the messages it describes, one after the other.
            let infoLength = try Int(checking: varint(stream, &offset))
            guard infoLength <= stream.count - offset else { throw Failure.malformed("an ArchiveInfo runs past the end") }
            let info = try fields(stream[offset..<offset + infoLength])
            offset += infoLength
            var messages: [(info: [Field], payload: Range<Int>)] = []
            for field in info where field.number == 2 {
                guard case let .bytes(bytes) = field.value else { throw Failure.malformed("a MessageInfo is not a message") }
                let messageInfo = try fields(bytes[...])
                guard let length = messageInfo.first(where: { $0.number == 3 })?.integer,
                      let length = Int(exactly: length), length <= stream.count - offset
                else { throw Failure.malformed("a message runs past the end") }
                messages.append((messageInfo, offset..<offset + length))
                offset += length
            }
            // One message of the storage type, not one to be merged into
            // another, and described by nothing but what is known here.
            let merged = info.contains { $0.number == 3 && $0.integer != 0 }
            if messages.count == 1, !merged,
               messages[0].info.first(where: { $0.number == 1 })?.integer == 2001,
               messages[0].info.allSatisfy({ [1, 2, 3, 5, 6].contains($0.number) }),
               let filled = fill(storage: stream[messages[0].payload], substitute: substitute) {
                let messageInfo = messages[0].info.map { field in
                    field.number == 3 ? Field(number: 3, value: .varint(UInt64(filled.count))) : field
                }
                let newInfo = encode(info.map { field in
                    field.number == 2 ? Field(number: 2, value: .bytes(encode(messageInfo))) : field
                })
                output += encodeVarint(UInt64(newInfo.count)) + newInfo + filled
                changed = true
            } else {
                output += stream[start..<offset]
            }
        }
        return changed ? compress(output) : nil
    }

    /// The storage `payload` with its placeholders filled in, when it is a
    /// header or a footer, holds one to fill in, and is entirely understood.
    static func fill(storage payload: ArraySlice<UInt8>, substitute: (String) -> String) -> [UInt8]? {
        guard let storage = try? fields(payload) else { return nil }
        // Kind 1 is HEADER, which footers share; absent, the kind is a text box.
        guard storage.filter({ $0.number == 1 }).map(\.integer) == [1] else { return nil }
        var tables: [Int: [[Field]]] = [:]
        var pieces: [UInt8] = []
        for (position, field) in storage.enumerated() {
            switch (field.number, field.value) {
            case (1, .varint), (2, .bytes), (4, .varint), (10, .varint):
                continue
            case let (3, .bytes(bytes)):
                pieces += bytes
            case let (number, .bytes(bytes)) where number >= 5:
                // Every other field is a table of entries, each starting with
                // the character index it applies from.
                guard let entries = try? fields(bytes[...]),
                      entries.allSatisfy({ $0.number == 1 }) else { return nil }
                var parsed: [[Field]] = []
                for entry in entries {
                    guard case let .bytes(bytes) = entry.value, let entryFields = try? fields(bytes[...]),
                          entryFields.filter({ $0.number == 1 }).count == 1,
                          case .varint = entryFields.first(where: { $0.number == 1 })?.value
                    else { return nil }
                    parsed.append(entryFields)
                }
                tables[position] = parsed
            default:
                return nil
            }
        }
        guard let text = String(bytes: pieces, encoding: .utf8) else { return nil }

        // The indices are those of the text in UTF-16, as NSString counts.
        let string = text as NSString
        let tokens = try! NSRegularExpression(pattern: "«([^«»]*)»")
        var edits: [(start: Int, length: Int, value: String)] = []
        for match in tokens.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            let token = string.substring(with: match.range)
            if token.unicodeScalars.contains(where: isBreak) { continue }
            let filled = substitute(token)
            if filled == token { continue }
            edits.append((match.range.location, match.range.length, sanitized(filled)))
        }
        guard !edits.isEmpty else { return nil }

        let result = NSMutableString(string: string)
        for edit in edits.reversed() {
            result.replaceCharacters(in: NSRange(location: edit.start, length: edit.length), with: edit.value)
        }
        // Where an index lands once the text is filled in: moved by what the
        // replacements before it added or removed, or nil for one that started
        // inside a placeholder, which no longer has a character to start at.
        func moved(_ index: Int) -> Int? {
            var shift = 0
            for edit in edits {
                if index <= edit.start { break }
                if index < edit.start + edit.length { return nil }
                shift += (edit.value as NSString).length - edit.length
            }
            return index + shift
        }

        var filled: [Field] = []
        var wroteText = false
        for (position, field) in storage.enumerated() {
            if field.number == 3 {
                // The text in one piece where its first piece was.
                if !wroteText { filled.append(Field(number: 3, value: .bytes(Array((result as String).utf8)))) }
                wroteText = true
                continue
            }
            guard let entries = tables[position] else {
                filled.append(field)
                continue
            }
            var kept: [(index: Int, fields: [Field])] = []
            for entry in entries {
                guard let old = entry.first(where: { $0.number == 1 })?.integer,
                      let old = Int(exactly: old), let index = moved(old) else { continue }
                let entry = entry.map { $0.number == 1 ? Field(number: 1, value: .varint(UInt64(index))) : $0 }
                // A value left empty brings two entries to one index; what
                // applies from there is the later one.
                if kept.last?.index == index { kept.removeLast() }
                kept.append((index, entry))
            }
            filled.append(Field(number: field.number, value: .bytes(encode(kept.map {
                Field(number: 1, value: .bytes(encode($0.fields)))
            }))))
        }
        return encode(filled)
    }

    /// A paragraph or line break, an object anchored in the text, or another
    /// control character: none may be inside a placeholder, nor come from a value.
    private static func isBreak(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\u{FFFC}" || CharacterSet.newlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar)
    }

    /// A value on one line: a line break in it would be a paragraph the tables
    /// do not have. A tab stays a tab.
    static func sanitized(_ value: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            scalars.append(scalar != "\t" && isBreak(scalar) ? " " : scalar)
        }
        return String(scalars)
    }

    // MARK: protocol buffers, as far as the fields above need them

    struct Field {
        enum Value {
            case varint(UInt64)
            case bytes([UInt8])
            case fixed32([UInt8])
            case fixed64([UInt8])
        }
        let number: Int
        let value: Value

        var integer: UInt64? {
            if case let .varint(value) = value { return value }
            return nil
        }
    }

    static func varint(_ bytes: [UInt8], _ offset: inout Int) throws -> UInt64 {
        try varint(bytes[...], &offset)
    }

    static func varint(_ bytes: ArraySlice<UInt8>, _ offset: inout Int) throws -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard offset < bytes.endIndex, shift < 64 else { throw Failure.malformed("a varint runs past the end") }
            let byte = bytes[offset]
            offset += 1
            value |= UInt64(byte & 0x7f) << shift
            if byte < 0x80 { return value }
            shift += 7
        }
    }

    static func fields(_ bytes: ArraySlice<UInt8>) throws -> [Field] {
        var result: [Field] = []
        var offset = bytes.startIndex
        while offset < bytes.endIndex {
            let key = try varint(bytes, &offset)
            guard let number = Int(exactly: key >> 3), number > 0 else { throw Failure.malformed("a field number is 0") }
            switch key & 7 {
            case 0:
                result.append(Field(number: number, value: .varint(try varint(bytes, &offset))))
            case 1, 5:
                let size = key & 7 == 1 ? 8 : 4
                guard size <= bytes.endIndex - offset else { throw Failure.malformed("a fixed field runs past the end") }
                let value = Array(bytes[offset..<offset + size])
                result.append(Field(number: number, value: size == 8 ? .fixed64(value) : .fixed32(value)))
                offset += size
            case 2:
                let length = try Int(checking: varint(bytes, &offset))
                guard length <= bytes.endIndex - offset else { throw Failure.malformed("a field runs past the end") }
                result.append(Field(number: number, value: .bytes(Array(bytes[offset..<offset + length]))))
                offset += length
            default:
                throw Failure.malformed("a group or an unknown wire type")
            }
        }
        return result
    }

    static func encodeVarint(_ value: UInt64) -> [UInt8] {
        var value = value
        var bytes: [UInt8] = []
        while value >= 0x80 {
            bytes.append(UInt8(value & 0x7f) | 0x80)
            value >>= 7
        }
        bytes.append(UInt8(value))
        return bytes
    }

    static func encode(_ fields: [Field]) -> [UInt8] {
        var bytes: [UInt8] = []
        for field in fields {
            let number = UInt64(field.number) << 3
            switch field.value {
            case let .varint(value):
                bytes += encodeVarint(number) + encodeVarint(value)
            case let .bytes(value):
                bytes += encodeVarint(number | 2) + encodeVarint(UInt64(value.count)) + value
            case let .fixed32(value):
                bytes += encodeVarint(number | 5) + value
            case let .fixed64(value):
                bytes += encodeVarint(number | 1) + value
            }
        }
        return bytes
    }

    // MARK: IWA chunks, and Snappy

    /// The chunks of an IWA file decompressed and joined: each is a zero byte, a
    /// three-byte little-endian length and a Snappy block of its own, without the
    /// framing or the checksums of Snappy's stream format.
    static func decompress(_ data: [UInt8]) throws -> [UInt8] {
        var stream: [UInt8] = []
        var offset = 0
        while offset < data.count {
            guard data[offset] == 0, data.count - offset >= 4 else { throw Failure.malformed("not an IWA chunk") }
            let length = Int(data[offset + 1]) | Int(data[offset + 2]) << 8 | Int(data[offset + 3]) << 16
            offset += 4
            guard length <= data.count - offset else { throw Failure.malformed("an IWA chunk runs past the end") }
            try snappyDecompress(data[offset..<offset + length], into: &stream)
            offset += length
        }
        return stream
    }

    private static func snappyDecompress(_ block: ArraySlice<UInt8>, into output: inout [UInt8]) throws {
        var offset = block.startIndex
        let expected = try Int(checking: varint(block, &offset))
        let start = output.count
        func little(_ count: Int) throws -> Int {
            guard count <= block.endIndex - offset else { throw Failure.malformed("a Snappy element runs past the end") }
            var value = 0
            for position in 0..<count { value |= Int(block[offset + position]) << (8 * position) }
            offset += count
            return value
        }
        while offset < block.endIndex {
            let tag = Int(block[offset])
            offset += 1
            if tag & 3 == 0 {
                var length = tag >> 2
                if length >= 60 { length = try little(length - 59) }
                length += 1
                guard length <= block.endIndex - offset else { throw Failure.malformed("a Snappy literal runs past the end") }
                output += block[offset..<offset + length]
                offset += length
                continue
            }
            let length: Int, distance: Int
            switch tag & 3 {
            case 1:
                length = (tag >> 2 & 7) + 4
                let low = try little(1)
                distance = (tag >> 5) << 8 | low
            case 2:
                length = (tag >> 2) + 1
                distance = try little(2)
            default:
                length = (tag >> 2) + 1
                distance = try little(4)
            }
            guard distance > 0, distance <= output.count - start else { throw Failure.malformed("a Snappy copy reaches before its block") }
            for _ in 0..<length { output.append(output[output.count - distance]) }
        }
        guard output.count - start == expected else { throw Failure.malformed("a Snappy block is not the length it says") }
    }

    /// The stream in IWA chunks of at most 64 KiB, each one a single Snappy
    /// literal: valid Snappy, which Pages reads as it reads its own, and which it
    /// compresses again the next time it saves the document.
    static func compress(_ stream: [UInt8]) -> [UInt8] {
        var data: [UInt8] = []
        var offset = 0
        while offset < stream.count {
            let piece = stream[offset..<min(offset + 65536, stream.count)]
            var block = encodeVarint(UInt64(piece.count))
            let length = piece.count - 1
            if length < 60 {
                block.append(UInt8(length << 2))
            } else {
                let size = length < 1 << 8 ? 1 : length < 1 << 16 ? 2 : length < 1 << 24 ? 3 : 4
                block.append(UInt8((59 + size) << 2))
                for position in 0..<size { block.append(UInt8(truncatingIfNeeded: length >> (8 * position))) }
            }
            block += piece
            data += [0, UInt8(block.count & 0xff), UInt8(block.count >> 8 & 0xff), UInt8(block.count >> 16 & 0xff)] + block
            offset += piece.count
        }
        return data
    }
}

private extension Int {
    init(checking value: UInt64) throws {
        guard let value = Int(exactly: value), value >= 0 else { throw PagesHeaderFooterFill.Failure.malformed("a length out of range") }
        self = value
    }
}
