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

import Foundation

/// One line of a server reply: "250-AUTH PLAIN" is code 250, separator "-"
/// (more lines follow) and text "AUTH PLAIN".
public struct SMTPReplyLine: Equatable, Sendable {
    public var code: Int
    /// "-" on a line that more lines of the same reply follow, " " on the
    /// last one, nil when the code stands alone.
    public var separator: Character?
    public var text: String?

    public var continues: Bool { separator == "-" }

    /// The line split at its first space or hyphen; the code is read the way
    /// -[NSString integerValue] reads it. A line without a code is an error.
    public static func parse(_ line: String?) throws(SMTPError) -> SMTPReplyLine {
        guard let line else { throw .unparsableLine }
        let head: Substring
        let separator: Character?
        let text: String?
        if let index = line.firstIndex(where: { $0 == " " || $0 == "-" }) {
            head = line[..<index]
            separator = line[index]
            text = String(line[line.index(after: index)...])
        } else {
            head = Substring(line)
            separator = nil
            text = nil
        }
        let code = leadingInteger(head)
        if code == 0 { throw .unparsableLine }
        return SMTPReplyLine(code: code, separator: separator, text: text)
    }

    /// -[NSString integerValue]: leading white space, a sign, then digits;
    /// 0 when there are none.
    static func leadingInteger(_ string: Substring) -> Int {
        let scanner = Scanner(string: String(string))
        scanner.charactersToBeSkipped = .whitespaces
        return scanner.scanInt() ?? 0
    }
}

/// The bytes a server sent, cut into CRLF-terminated lines.
public struct SMTPLineBuffer: Sendable {
    private var pending: [UInt8] = []

    public init() {}

    /// The complete lines the bytes finish, without their CRLF. Empty lines
    /// are left out; a line that is not UTF-8 is nil, which no reply parses.
    /// A NUL byte stops the search for the end of a line, as strnstr did.
    public mutating func append<Bytes: Sequence>(_ bytes: Bytes) -> [String?] where Bytes.Element == UInt8 {
        pending.append(contentsOf: bytes)
        var lines: [String?] = []
        var start = 0
        var i = 0
        scan: while i + 1 < pending.count {
            switch (pending[i], pending[i + 1]) {
            case (0, _):
                break scan
            case (13, 10):
                if i > start {
                    lines.append(String(validating: pending[start..<i], as: UTF8.self))
                }
                i += 2
                start = i
            default:
                i += 1
            }
        }
        pending.removeFirst(start)
        return lines
    }
}
