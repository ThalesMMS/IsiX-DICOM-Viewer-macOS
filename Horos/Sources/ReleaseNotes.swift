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

#if !MACAPPSTORE
import Foundation

/// The notes of the latest published release, as GitHub describes it, and
/// their rendering for the About window.
///
/// The notes are text from the network. They reach the page only as the
/// markup built here: every character of the release is escaped, the tags are
/// the few this file writes, and a link is kept only when it is http or https.
struct ReleaseNotes: Sendable, Equatable {
    let title: String
    let published: Date?
    /// The release's own text, in GitHub's Markdown.
    let body: String
    /// The release's page.
    let page: URL

    /// The latest published release that is neither a draft nor a pre-release.
    static let latestURL = URL(string: "https://api.github.com/repos/ThalesMMS/IsiX-DICOM-Viewer-macOS/releases/latest")!
    /// The same release, for a browser.
    static let latestPageURL = UpdateFeedClient.releaseNotesURL
    static let pagePrefix = "https://github.com/ThalesMMS/IsiX-DICOM-Viewer-macOS/releases/"
    static let maximumSize = 1_048_576

    init(title: String, published: Date?, body: String, page: URL) {
        self.title = title
        self.published = published
        self.body = body
        self.page = page
    }

    /// Nil unless the data is a published release with a name and some notes.
    init?(json data: Data) {
        guard data.count <= Self.maximumSize,
              let release = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              release["draft"] as? Bool != true, release["prerelease"] as? Bool != true,
              let body = release["body"] as? String,
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let names = [release["name"], release["tag_name"]].compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }
        guard let title = names.first(where: { !$0.isEmpty }) else { return nil }
        self.title = title
        self.body = body
        published = (release["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        // The link under the notes goes to this fork's releases or nowhere else.
        let address = release["html_url"] as? String ?? ""
        page = (address.hasPrefix(Self.pagePrefix) ? URL(string: address) : nil) ?? Self.latestPageURL
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: UpdateFeedClient.HTTPSRedirects(), delegateQueue: nil)
    }()

    /// `completion` runs once, on the main queue; nil when the notes could not be read.
    static func fetchLatest(completion: @escaping @MainActor @Sendable (ReleaseNotes?) -> Void) {
        fetch(url: latestURL, session: session, completion: completion)
    }

    // Session injection keeps the tests independent of the network.
    static func fetch(url: URL, session: URLSession, completion: @escaping @MainActor @Sendable (ReleaseNotes?) -> Void) {
        let finish: @Sendable (ReleaseNotes?) -> Void = { notes in
            DispatchQueue.main.async { completion(notes) }
        }
        guard url.scheme?.lowercased() == "https" else {
            finish(nil)
            return
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        session.dataTask(with: request) { data, response, _ in
            guard let response = response as? HTTPURLResponse, response.statusCode == 200, let data = data else {
                finish(nil)
                return
            }
            finish(ReleaseNotes(json: data))
        }.resume()
    }

    // MARK: - Rendering

    /// What replaces the content of the bundled release notes page.
    var html: String {
        var heading = "<div class=\"version\">" + Self.escape(title) + "</div>"
        if let published = published {
            let formatter = DateFormatter()
            formatter.dateStyle = .long
            formatter.timeStyle = .none
            heading += " <span class=\"release-date\">" + Self.escape(formatter.string(from: published)) + "</span>"
        }
        return "<div class=\"content-block\">\n" + heading + "\n" + Self.html(markdown: body)
            + "\n<p><a href=\"" + Self.escape(page.absoluteString) + "\">View this release on GitHub</a></p>\n</div>"
    }

    static func escape(_ text: String) -> String {
        var escaped = ""
        for character in text {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            default: escaped.append(character)
            }
        }
        return escaped
    }

    /// Code spans, bold text and links of one line; everything else is text.
    static func inline(_ text: String) -> String {
        var output = ""
        var rest = Substring(text)
        while let character = rest.first {
            if character == "`", let end = rest.dropFirst().firstIndex(of: "`") {
                output += "<code>" + escape(String(rest[rest.index(after: rest.startIndex)..<end])) + "</code>"
                rest = rest[rest.index(after: end)...]
            } else if rest.hasPrefix("**"), let end = rest.dropFirst(2).range(of: "**"), end.lowerBound > rest.index(rest.startIndex, offsetBy: 2) {
                output += "<strong>" + inline(String(rest[rest.index(rest.startIndex, offsetBy: 2)..<end.lowerBound])) + "</strong>"
                rest = rest[end.upperBound...]
            } else if character == "[", let middle = rest.range(of: "]("), let end = rest[middle.upperBound...].firstIndex(of: ")"),
                      let link = URL(string: String(rest[middle.upperBound..<end])),
                      let scheme = link.scheme?.lowercased(), scheme == "https" || scheme == "http" {
                output += "<a href=\"" + escape(link.absoluteString) + "\">"
                    + inline(String(rest[rest.index(after: rest.startIndex)..<middle.lowerBound])) + "</a>"
                rest = rest[rest.index(after: end)...]
            } else {
                output += escape(String(character))
                rest = rest.dropFirst()
            }
        }
        return output
    }

    /// The text after a list marker ("- ", "* ", "+ " or "1. "), and whether the list is numbered.
    private static func listItem(_ line: Substring) -> (text: Substring, numbered: Bool)? {
        if let marker = line.first, "-*+".contains(marker), line.dropFirst().first == " " {
            return (line.dropFirst(2), false)
        }
        let digits = line.prefix(while: { $0.isASCII && $0.isNumber })
        let after = line.dropFirst(digits.count)
        if !digits.isEmpty, digits.count <= 9, after.hasPrefix(". ") {
            return (after.dropFirst(2), true)
        }
        return nil
    }

    /// Headings, lists and paragraphs: the Markdown the releases are written in.
    static func html(markdown: String) -> String {
        var blocks: [String] = []
        var paragraph: [String] = []
        var items: [String] = []
        var numbered = false

        func flush() {
            if !paragraph.isEmpty {
                blocks.append("<p>" + inline(paragraph.joined(separator: " ")) + "</p>")
                paragraph = []
            }
            if !items.isEmpty {
                let tag = numbered ? "ol" : "ul"
                blocks.append("<\(tag)>\n" + items.map { "<li>" + inline($0) + "</li>" }.joined(separator: "\n") + "\n</\(tag)>")
                items = []
            }
        }

        for line in markdown.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            let level = trimmed.prefix(while: { $0 == "#" }).count
            if trimmed.isEmpty {
                flush()
            } else if (1...6).contains(level), trimmed.dropFirst(level).first == " " {
                flush()
                // The release's name is the page's second-level heading.
                blocks.append("<h3>" + inline(trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)) + "</h3>")
            } else if let item = listItem(trimmed) {
                if !paragraph.isEmpty || (!items.isEmpty && numbered != item.numbered) { flush() }
                numbered = item.numbered
                items.append(item.text.trimmingCharacters(in: .whitespaces))
            } else if !items.isEmpty, trimmed.startIndex != line.startIndex {
                // An indented line continues the item above it.
                items[items.count - 1] += " " + trimmed.trimmingCharacters(in: .whitespaces)
            } else {
                if !items.isEmpty { flush() }
                paragraph.append(trimmed.trimmingCharacters(in: .whitespaces))
            }
        }
        flush()
        return blocks.joined(separator: "\n")
    }
}

#endif
