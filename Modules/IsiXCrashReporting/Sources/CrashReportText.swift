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

/// The free text a crash report holds about an uncaught exception: where its
/// name and reason are, and what is taken out of them before they are shown
/// in a mail or an issue.
///
/// A reason is whatever the code that raised the exception wrote, and it can
/// quote a file, a folder or the user. What has the form of one of those is
/// replaced by a placeholder; a name written as plain words, outside quotes
/// and with no path or extension, cannot be told from the rest of a sentence
/// and stays, which is why the draft is shown to the user before it is sent.
public enum CrashReportText {
    /// A reason is cut at this many characters.
    public static let reasonLimit = 300
    /// An exception's name is cut at this many characters.
    public static let nameLimit = 80

    /// The names of who is logged in: the account, the home folder and the
    /// full name.
    public static var localUserNames: [String] {
        [NSUserName(), URL(fileURLWithPath: NSHomeDirectory()).lastPathComponent, NSFullUserName()]
    }

    /// The name and the reason of the exception in the lines a library left
    /// as application-specific information: "*** Terminating app due to
    /// uncaught exception 'Name', reason: 'Reason'", whose reason can go on
    /// in the next lines, or "Crashing on exception: Reason".
    static func exception(inApplicationInformation lines: [String]) -> (name: String?, reason: String?) {
        var name: String?
        var reason: String?
        for (index, line) in lines.enumerated() where reason == nil {
            if let start = line.range(of: "uncaught exception '") {
                let rest = line[start.upperBound...]
                if let end = rest.firstIndex(of: "'") { name = String(rest[..<end]) }
            }
            if let start = line.range(of: "reason: '") {
                var text = String(line[start.upperBound...])
                var next = index + 1
                while !text.hasSuffix("'"), next < lines.count {
                    text += " " + lines[next]
                    next += 1
                }
                if text.hasSuffix("'") { text.removeLast() }
                reason = text
            } else if let start = line.range(of: "Crashing on exception: ") {
                reason = String(line[start.upperBound...])
            }
        }
        return (name?.isEmpty == false ? name : nil, reason?.isEmpty == false ? reason : nil)
    }

    private static let closingQuotes: [Character: Character] = ["\"": "\"", "'": "'", "“": "”", "‘": "’"]
    private static let boundaries: Set<Character> = ["'", "\"", "“", "‘", "(", "<", "[", "=", ":", ",", ";"]

    /// `text` in one line, without what has the form of a path, an address,
    /// a quoted string, a file name, a DICOM person name or one of
    /// `userNames`, and cut at `limit` characters. Nil when nothing is left.
    public static func cleaned(_ text: String, userNames: [String] = [], limit: Int = reasonLimit) -> String? {
        var line = text.replacingOccurrences(of: "`", with: "'")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        // The longest name first, and a mark in place of each that no name
        // can match: an account called as a word of the placeholder would be
        // replaced again inside it.
        let mark = "\u{E000}"
        for name in Set(userNames).sorted(by: { ($0.count, $0) > ($1.count, $1) }) where name.count >= 3 {
            line = replacingWord(name, in: line, with: mark)
        }
        line = withoutPathsAndQuotes(line)
        line = line.split(separator: " ").map(cleanedToken).joined(separator: " ")
        line = line.replacingOccurrences(of: mark, with: "<user>")
        if line.count > limit { line = String(line.prefix(limit)) + "…" }
        return line.isEmpty ? nil : line
    }

    /// Every whole-word occurrence of `word`, in any case.
    private static func replacingWord(_ word: String, in text: String, with placeholder: String) -> String {
        var result = ""
        var rest = Substring(text)
        var previous: Character?
        while let found = rest.range(of: word, options: .caseInsensitive) {
            let before = found.lowerBound == rest.startIndex ? previous : rest[rest.index(before: found.lowerBound)]
            let after = found.upperBound == rest.endIndex ? nil : rest[found.upperBound]
            let whole = !(before?.isLetter == true || before?.isNumber == true) && !(after?.isLetter == true || after?.isNumber == true)
            result += rest[..<found.lowerBound] + (whole ? placeholder : String(rest[found]))
            previous = rest[rest.index(before: found.upperBound)]
            rest = rest[found.upperBound...]
        }
        return result + rest
    }

    /// Quoted strings lose their contents and an address is replaced. A path
    /// outside quotes can have spaces, so nothing says where it ends: the
    /// text stops there.
    private static func withoutPathsAndQuotes(_ text: String) -> String {
        let characters = Array(text)
        var result = ""
        var index = 0
        func isWordCharacter(_ position: Int) -> Bool {
            position < characters.count && (characters[position].isLetter || characters[position].isNumber)
        }
        func isBoundary(before position: Int) -> Bool {
            position == 0 || characters[position - 1].isWhitespace || boundaries.contains(characters[position - 1])
        }
        func has(_ prefix: String, at position: Int) -> Bool {
            let prefix = Array(prefix)
            return position + prefix.count <= characters.count
                && String(characters[position..<position + prefix.count]).lowercased() == String(prefix)
        }
        while index < characters.count {
            let character = characters[index]
            // An apostrophe opens a quotation only at the start of a word,
            // and none closes one inside a word.
            if let closing = closingQuotes[character], character != "'" || isBoundary(before: index),
               let end = (index + 1..<characters.count).first(where: { characters[$0] == closing && !isWordCharacter($0 + 1) }) {
                result += "\(character)<removed>\(closing)"
                index = end + 1
                continue
            }
            if isBoundary(before: index) {
                var scheme = index
                while scheme < characters.count, characters[scheme].isASCII,
                      characters[scheme].isLetter || characters[scheme].isNumber || "+.-".contains(characters[scheme]) {
                    scheme += 1
                }
                let isFile = has("file:/", at: index)
                if scheme > index, has("://", at: scheme), !isFile {
                    index = scheme
                    while index < characters.count, !characters[index].isWhitespace { index += 1 }
                    result += "<url>"
                    continue
                }
                let isHome = character == "~" && has("/", at: index + 1)
                let isRoot = character == "/" && index + 1 < characters.count && !characters[index + 1].isWhitespace
                if isFile || isHome || isRoot {
                    return result + "<path>"
                }
            }
            result.append(character)
            index += 1
        }
        return result
    }

    private static func isIdentifier(_ text: Substring) -> Bool {
        guard let first = text.first, first.isLetter || first == "_" else { return false }
        return text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// A word between spaces: one with a "^" is a DICOM person name, one
    /// with a "/" a relative path, one with an extension a file name. A
    /// module's type, `Module.TypeName`, has the form of a file name and is
    /// kept, as is a number.
    private static func cleanedToken(_ token: Substring) -> String {
        if token.contains("^") { return "<name>" }
        var core = token
        var prefix = ""
        var suffix = ""
        while let first = core.first, "([<{-+\"'“‘".contains(first) {
            prefix.append(first)
            core.removeFirst()
        }
        while let last = core.last, ".,;:!?)]>}\"'”’".contains(last) {
            suffix.insert(last, at: suffix.startIndex)
            core.removeLast()
        }
        // "Name.ext:12" is a file and a line.
        if let colon = core.firstIndex(of: ":") {
            suffix = core[colon...] + suffix
            core = core[..<colon]
        }
        if core.contains("/") {
            // "I/O" and "1/2" are not paths.
            let parts = core.split(separator: "/", omittingEmptySubsequences: false)
            if parts.allSatisfy({ $0.count <= 1 || $0.allSatisfy(\.isNumber) }) { return String(token) }
            return prefix + "<path>" + suffix
        }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count > 1, let last = parts.last, !parts[0].isEmpty,
              (1...10).contains(last.count), last.allSatisfy({ $0.isLetter || $0.isNumber }), last.contains(where: \.isLetter)
        else { return String(token) }
        let isTypeName = parts.allSatisfy(isIdentifier) && last.first?.isUppercase == true && last.contains(where: \.isLowercase)
        return isTypeName ? String(token) : prefix + "<file>" + suffix
    }
}
