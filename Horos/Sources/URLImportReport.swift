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

/// What came back from a URL, and what became of it.
///
/// "Import URL…" wrote whatever the server answered into the database's own file
/// folder as a `.dcm`, whatever it was, and reported success as long as some
/// bytes had arrived. Measured against a local server: a DICOM object landed and
/// was indexed; a zip served without a file extension became a `.dcm` holding a
/// zip, in the folder the database keeps its images, expanded by nothing and
/// indexed by nothing; and an HTML sign-in page - which is what a proxy answers
/// with a 200 - became a 76-byte `.dcm` beside it. Both were reported as
/// successful downloads.
@objc(HorosURLImportReport)
public final class URLImportReport: NSObject {

    private var indexed: [String] = []
    private var expanded: [String] = []
    private var refused: [(String, String)] = []
    private var failed: [(String, String)] = []

    /// The extension the content itself asks for, whatever the URL was called.
    ///
    /// A URL path carries no reliable extension - the ones this exists for have
    /// none at all - so the first bytes decide. `dcm` for a DICOM object, `zip`
    /// for an archive the importer knows how to expand, and nothing for anything
    /// else, which is how it reaches the importer's own answer for a file it
    /// cannot read rather than being disguised as an image.
    @objc(fileExtensionForPayload:)
    public class func fileExtension(forPayload data: Data) -> String {
        if data.count > 132 {
            let magic = data.subdata(in: 128..<132)
            if magic == Data("DICM".utf8) { return "dcm" }
        }
        if data.count >= 4, data.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]) { return "zip" }
        return ""
    }

    @objc(recordIndexedURL:)
    public func recordIndexed(url: String) { indexed.append(url) }

    /// Handed to the import folder: an archive, to be expanded there, which gets
    /// its own verdict from the importer once it has been, or a DICOM object the
    /// import has not finished with.
    @objc(recordExpandedURL:)
    public func recordExpanded(url: String) { expanded.append(url) }

    /// Downloaded, and not something this database can take.
    @objc(recordRefusedURL:reason:)
    public func recordRefused(url: String, reason: String) { refused.append((url, reason)) }

    /// Not downloaded at all.
    @objc(recordFailedURL:reason:)
    public func recordFailed(url: String, reason: String) { failed.append((url, reason)) }

    @objc public var everythingArrived: Bool {
        return refused.isEmpty && failed.isEmpty
    }

    /// One sentence for the alert, naming what went wrong rather than only that
    /// something did, in the language of the interface.
    ///
    /// The same text is the error message of the AppleScript command: a message
    /// for the person who reads it, like the reasons it quotes, which are
    /// localized where they are made. A script decides by the error number and
    /// by the paths the command returns, not by these words.
    @objc public var summary: String {
        var parts: [String] = []
        if !indexed.isEmpty {
            parts.append(indexed.count == 1
                ? NSLocalizedString("1 added to the database", comment: "URL import report: one URL's object is in the database")
                : String(format: NSLocalizedString("%ld added to the database", comment: "URL import report: how many URLs' objects are in the database"),
                         indexed.count))
        }
        if !expanded.isEmpty {
            parts.append(expanded.count == 1
                ? NSLocalizedString("1 handed to the import folder", comment: "URL import report: one URL's payload waits in the import folder")
                : String(format: NSLocalizedString("%ld handed to the import folder", comment: "URL import report: how many URLs' payloads wait in the import folder"),
                         expanded.count))
        }
        for (url, reason) in failed {
            parts.append(String(format: NSLocalizedString("%1$@ could not be downloaded: %2$@", comment: "URL import report: the URL, then why nothing came of it"),
                                short(url), reason))
        }
        for (url, reason) in refused {
            parts.append(String(format: NSLocalizedString("%1$@ is not something this database can take: %2$@", comment: "URL import report: the URL, then what it answered with"),
                                short(url), reason))
        }
        return parts.isEmpty ? NSLocalizedString("Nothing was downloaded.", comment: "") : parts.joined(separator: "\n")
    }

    private func short(_ url: String) -> String {
        guard let components = URLComponents(string: url), let host = components.host else { return url }
        return components.path.isEmpty ? host : host + components.path
    }
}
