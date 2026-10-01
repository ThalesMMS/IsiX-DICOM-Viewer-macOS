/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import CryptoKit
import Foundation

// NSData (N2) is implemented in Swift since #710; the selectors and
// <Horos/NSData+N2.h> are those of the former category. N2XMLRPC writes
// <base64> values with -base64 and reads them with +dataWithBase64:, so both
// keep the bytes of the Objective-C exactly. The C functions hexchar2dec and
// hex2char stay in NSData+N2+CAPI.mm under their C++ names; the Swift below
// does what they did.

/// hexchar2dec: the value of a hexadecimal digit, -1 (as a char) otherwise.
@inline(__always)
private func hexCharToDec(_ hex: CChar) -> CChar {
    if hex >= 0x30 && hex <= 0x39 { // '0'...'9'
        return hex - 0x30
    }
    if hex >= 0x41 && hex <= 0x46 { // 'A'...'F'
        return hex - 0x41 + 10
    }
    if hex >= 0x61 && hex <= 0x66 { // 'a'...'f'
        return hex - 0x61 + 10
    }
    return -1
}

/// hex2char: `(hexchar2dec(hex[0])<<4)+hexchar2dec(hex[1])`, computed in int and
/// stored in a char, as the C did.
@inline(__always)
private func hexToChar(_ high: CChar, _ low: CChar) -> CChar {
    CChar(truncatingIfNeeded: (Int32(hexCharToDec(high)) << 4) + Int32(hexCharToDec(low)))
}

// base64 code from http://www.cocoadev.com/index.pl?BaseSixtyFour by MiloBird

private let base64EncodingTable: [UInt8] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)

/// CHAR_MAX for a character that is not in the table.
private let base64DecodingTable: [CChar] = {
    var table = [CChar](repeating: CChar.max, count: 256)
    for i in 0..<64 {
        table[Int(base64EncodingTable[i])] = CChar(i)
    }
    return table
}()

private let hexDigits: [UInt8] = Array("0123456789ABCDEF".utf8)

public extension NSData {

    @objc(dataWithHex:)
    static func data(withHex hex: String?) -> NSData? {
        guard let hex else { return nil }
        return NSData(hex: hex)
    }

    @objc(initWithHex:)
    convenience init(hex: String?) {
        let length = (hex as NSString?)?.length ?? 0
        let buffer = malloc(length / 2)!.assumingMemoryBound(to: CChar.self)
        let utf8 = (hex as NSString?)?.utf8String

        if let utf8 {
            //#pragma omp parallel for
            for i in 0..<(length / 2) {
                buffer[i] = hexToChar(utf8[i * 2], utf8[i * 2 + 1])
            }
        }

        self.init(bytesNoCopy: buffer, length: length / 2)
    }

    @objc(dataWithBase64:)
    static func data(withBase64 base64: String?) -> NSData? {
        guard let base64 else { return nil }
        return NSData(base64: base64)
    }

    @objc(initWithBase64:)
    convenience init?(base64: String?) {
        guard let base64 = base64 as NSString?, base64.length != 0 else {
            self.init()
            return
        }

        guard let characters = base64.cString(using: String.Encoding.ascii.rawValue) else { //  Not an ASCII string!
            return nil
        }
        guard let bytes = malloc(((base64.length + 3) / 4) * 3)?.assumingMemoryBound(to: UInt8.self) else {
            return nil
        }
        var length = 0

        var i = 0
        var buffer: (CChar, CChar, CChar, CChar) = (0, 0, 0, 0)
        while true {
            var bufferLength = 0
            while bufferLength < 4 {
                defer { i += 1 }
                let character = characters[i]
                if character == 0 {
                    i -= 1 // the C loop left on break, before its i++
                    break
                }
                if isspace(Int32(character)) != 0 || character == 0x3D { // '='
                    continue
                }
                let decoded = base64DecodingTable[Int(UInt8(bitPattern: character))]
                switch bufferLength {
                case 0: buffer.0 = decoded
                case 1: buffer.1 = decoded
                case 2: buffer.2 = decoded
                default: buffer.3 = decoded
                }
                bufferLength += 1
                if decoded == CChar.max { //  Illegal character!
                    free(bytes)
                    return nil
                }
            }

            if bufferLength == 0 {
                break
            }
            if bufferLength == 1 { //  At least two characters are needed to produce one byte!
                free(bytes)
                return nil
            }

            //  Decode the characters in the buffer to bytes.
            let b0 = UInt8(bitPattern: buffer.0), b1 = UInt8(bitPattern: buffer.1)
            let b2 = UInt8(bitPattern: buffer.2), b3 = UInt8(bitPattern: buffer.3)
            bytes[length] = (b0 << 2) | (b1 >> 4); length += 1
            if bufferLength > 2 {
                bytes[length] = (b1 << 4) | (b2 >> 2); length += 1
            }
            if bufferLength > 3 {
                bytes[length] = (b2 << 6) | b3; length += 1
            }
        }

        guard let result = realloc(bytes, length) else {
            // -initWithBytesNoCopy:NULL length:0, which was empty data.
            self.init()
            return
        }
        self.init(bytesNoCopy: result, length: length)
    }

    @objc func base64() -> String? {
        let count = self.length
        if count == 0 {
            return ""
        }

        guard let characters = malloc(((count + 2) / 3) * 4)?.assumingMemoryBound(to: UInt8.self) else {
            return nil
        }
        var length = 0

        let source = self.bytes.assumingMemoryBound(to: UInt8.self)
        var i = 0
        while i < count {
            var buffer: (UInt8, UInt8, UInt8) = (0, 0, 0)
            var bufferLength = 0
            while bufferLength < 3 && i < count {
                switch bufferLength {
                case 0: buffer.0 = source[i]
                case 1: buffer.1 = source[i]
                default: buffer.2 = source[i]
                }
                bufferLength += 1
                i += 1
            }

            //  Encode the bytes in the buffer to four characters, including padding "=" characters if necessary.
            characters[length] = base64EncodingTable[Int((buffer.0 & 0xFC) >> 2)]; length += 1
            characters[length] = base64EncodingTable[Int(((buffer.0 & 0x03) << 4) | ((buffer.1 & 0xF0) >> 4))]; length += 1
            if bufferLength > 1 {
                characters[length] = base64EncodingTable[Int(((buffer.1 & 0x0F) << 2) | ((buffer.2 & 0xC0) >> 6))]
            } else {
                characters[length] = 0x3D // '='
            }
            length += 1
            if bufferLength > 2 {
                characters[length] = base64EncodingTable[Int(buffer.2 & 0x3F)]
            } else {
                characters[length] = 0x3D // '='
            }
            length += 1
        }

        return NSString(bytesNoCopy: characters, length: length, encoding: String.Encoding.ascii.rawValue, freeWhenDone: true) as String?
    }

    @objc func hex() -> String {
        let count = self.length
        var characters = [UInt8](repeating: 0, count: count * 2)
        if count > 0 {
            let dataBuffer = self.bytes.assumingMemoryBound(to: UInt8.self)
            for i in 0..<count {
                characters[i * 2] = hexDigits[Int(dataBuffer[i] >> 4)]
                characters[i * 2 + 1] = hexDigits[Int(dataBuffer[i] & 0x0F)]
            }
        }
        return String(decoding: characters, as: UTF8.self)
    }

    /// Legacy 16-byte MD5 digest for SDK compatibility and SMTP CRAM-MD5 only.
    /// Do not use for security, new persistent identities or cache keys; use
    /// sha256() for new content hashes. This selector must continue to mean MD5.
    @objc func md5() -> NSData {
        Data(Insecure.MD5.hash(data: self as Data)) as NSData
    }

    /// SHA-256 content digest (32 bytes). Changing an existing persisted key
    /// requires an explicit version/migration at its consumer.
    @objc func sha256() -> NSData {
        Data(SHA256.hash(data: self as Data)) as NSData
    }
}
