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

/// The text of the large description an image view shows over its image: what
/// tells its series apart from those of the other open viewers.
public enum DescriptionInLarge {
    /// The most lines a comment takes: one that needs more ends in an ellipsis.
    public static let commentLineLimit = 4

    /// One line per item, separated by carriage returns: the patient's name
    /// when the open studies are not all of the same name, the series' date,
    /// the study's name when the open studies are not all of the same name,
    /// and the series' name. The date's line is begun after a name even when
    /// the series has no date. The lines of the comments of the study and of
    /// the series follow (`commentLines`); without a comment the text is the
    /// one of the identification alone.
    public static func text(patientName: String?, studyName: String?, seriesName: String?, date: String?,
                            openPatientNames: [String?], openStudyNames: [String?],
                            studyComment: String? = nil, seriesComment: String? = nil,
                            commentLineLimit limit: Int = commentLineLimit, commentFits fits: (String) -> Bool = { _ in true }) -> String {
        var text = ""
        if !allIdentical(openPatientNames), let patientName {
            if !text.isEmpty { text += "\r" }
            text += patientName
        }
        if !text.isEmpty { text += "\r" }
        if let date { text += date }
        if !allIdentical(openStudyNames), let studyName {
            if !text.isEmpty { text += "\r" }
            text += studyName
        }
        if let seriesName {
            if !text.isEmpty { text += "\r" }
            text += seriesName
        }
        let comments = commentLines(study: studyComment, series: seriesComment, limit: limit, fits: fits)
        if !comments.isEmpty {
            if !text.isEmpty { text += "\r" }
            text += comments.joined(separator: "\r")
        }
        return text
    }

    /// The lines of the comment of the study, then those of the comment of the
    /// series when it is not the same text. A comment without text (none,
    /// empty, or only white space) has no line. `fits` tells whether a line is
    /// narrow enough to be shown: a comment is broken between words where it
    /// stops fitting, and inside a word that does not fit alone. Its own line
    /// breaks are kept, its blank lines are not. Each comment takes at most
    /// `limit` lines, the last one ending in an ellipsis when text is left out.
    public static func commentLines(study: String?, series: String?, limit: Int = commentLineLimit,
                                    fits: (String) -> Bool = { _ in true }) -> [String] {
        let study = trimmed(study), series = trimmed(series)
        var lines: [String] = []
        if let study { lines += wrapped(study, limit: limit, fits: fits) }
        if let series, series != study { lines += wrapped(series, limit: limit, fits: fits) }
        return lines
    }

    /// The comment without the white space around it, or nil when nothing is left.
    private static func trimmed(_ comment: String?) -> String? {
        guard let text = comment?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private static func wrapped(_ comment: String, limit: Int, fits: (String) -> Bool) -> [String] {
        guard limit > 0 else { return [] }
        var lines: [String] = []
        // One line beyond the limit is enough to know that text is left out.
        paragraphs: for paragraph in comment.split(whereSeparator: \.isNewline) {
            var line = ""
            for word in paragraph.split(whereSeparator: \.isWhitespace) {
                let longer = line.isEmpty ? String(word) : line + " " + word
                if fits(longer) {
                    line = longer
                    continue
                }
                if !line.isEmpty { lines.append(line) }
                var rest = word
                while !fits(String(rest)), rest.count > 1 {
                    if lines.count > limit { break paragraphs }
                    let head = longestFittingPrefix(of: rest, fits: fits)
                    lines.append(String(head))
                    rest = rest.dropFirst(head.count)
                }
                line = String(rest)
                if lines.count > limit { break paragraphs }
            }
            if !line.isEmpty { lines.append(line) }
            if lines.count > limit { break }
        }
        guard lines.count > limit else { return lines }
        var last = lines[limit - 1]
        while !last.isEmpty, !fits(last + "…") { last.removeLast() }
        return lines.prefix(limit - 1) + [last.trimmingCharacters(in: .whitespaces) + "…"]
    }

    /// The longest beginning of `word` that fits, of one character at least
    /// and never the whole word.
    private static func longestFittingPrefix(of word: Substring, fits: (String) -> Bool) -> Substring {
        var low = 1, high = word.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if fits(String(word.prefix(middle))) { low = middle } else { high = middle - 1 }
        }
        return word.prefix(low)
    }

    /// Whether every value is the same text: false for no value, or when one has no text.
    public static func allIdentical(_ values: [String?]) -> Bool {
        guard let first = values.first, let first else { return false }
        let text = first as NSString
        return values.allSatisfy { value in value.map { text.isEqual(to: $0) } ?? false }
    }
}
