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

import AppKit
import Synchronization
import UniformTypeIdentifiers

/// Where Pages is, when it is anywhere, and the name it is addressed by.
///
/// Horos asked for the bundle identifier `com.apple.iWork.Pages` alone. Pages
/// 15.3.1, installed and signed by Apple, answers to `com.apple.Pages`, and
/// measured on a machine with it installed:
///
///     com.apple.iWork.Pages: nil
///     com.apple.Pages: /Applications/Pages.app
///
/// so the report generator said "Pages is not installed or could not be located"
/// with Pages sitting in the Applications folder. Both identifiers are asked for
/// now, and after them the application registered to open a Pages document,
/// which is the question that actually matters and does not have to be revisited
/// the next time the identifier changes.
///
/// Everything that is done with Pages goes to the one found here: the report is
/// opened in it and every script is addressed to its identifier. macOS grants
/// Automation for a pair of applications, and a script addressed to another
/// Pages than the one holding the document both asks the user for a second
/// permission and waits for a document that never appears there.
@objc(HorosPagesApplication)
public final class PagesApplication: NSObject {

    /// The Pages everything is done with: where it is, and the bundle
    /// identifier scripts address it by.
    struct Target: Equatable, Sendable {
        let url: URL
        let identifier: String

        /// `source` with this Pages named wherever it says `__PAGES_BUNDLE_ID__`.
        /// A script names Pages in its source and not in a variable: `tell
        /// application id` and `using terms from` are where the compiler gets
        /// Pages' terminology, and it reads them before anything runs.
        func script(_ source: String) -> String {
            source.replacingOccurrences(of: "__PAGES_BUNDLE_ID__", with: identifier)
        }
    }

    /// The identifiers Pages has on the Mac, the current one first.
    /// `com.apple.iWork.Pages` is every Pages up to 14, and `com.apple.Pages`
    /// the one that came after it as a separate application, so a Mac can
    /// have both. The newer one wins: it opens what the older one saved, which
    /// the older one does not do for what the newer one saved, and it is the
    /// one the scripts were written against.
    ///
    /// Pages '09 has the older identifier too. It is not a reason to ask for
    /// that one first: its executable is 32-bit only, and measured on macOS 27
    /// the workspace does not answer with such an application at all.
    private static let identifiers = ["com.apple.Pages", "com.apple.iWork.Pages"]

    /// The document type a Pages file is, which is how the application is found
    /// when it answers to neither identifier.
    private static let documentType = "com.apple.iwork.pages.pages"

    /// The last answer of `target()`, once there is one. Each lookup asks
    /// LaunchServices, and the browser asks after every import, for the
    /// report toolbar item: with no LaunchServices context alive, that made
    /// it copy its database (about 45 MiB) on top of the import's memory peak.
    private static let answer = Mutex<(known: Bool, target: Target?)>((false, nil))

    /// Pages installed, removed or updated is seen once an application launches
    /// or quits: the answer is then asked again.
    private static let forgetting: Void = {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: nil) { _ in
                PagesApplication.answer.withLock { $0 = (false, nil) }
            }
        }
    }()

    @objc public static func url() -> URL? {
        target()?.url
    }

    /// Where Pages is and what it is addressed by, in one answer: a report
    /// opened in one Pages and a script sent to another is the mistake this
    /// type is here to prevent.
    static func target() -> Target? {
        _ = forgetting
        if let known = answer.withLock({ $0.known ? Optional($0.target) : nil }) {
            return known
        }
        let workspace = NSWorkspace.shared
        let found = lookUp(installed: { workspace.urlForApplication(withBundleIdentifier: $0) },
                           registered: {
            // Asking by document type needs macOS 12; below it the two
            // identifiers are all there is, which is what every Pages before
            // then used.
            guard #available(macOS 12.0, *), let type = UTType(documentType) else { return nil }
            return workspace.urlForApplication(toOpen: type)
        })
        answer.withLock { $0 = (true, found) }
        return found
    }

    /// The lookup, apart from the workspace it asks: `installed` answers where
    /// the application of a bundle identifier is, and `registered` which
    /// application opens a Pages document.
    static func lookUp(installed: (String) -> URL?, registered: () -> URL?) -> Target? {
        for identifier in identifiers {
            if let url = installed(identifier) {
                return Target(url: url, identifier: identifier)
            }
        }
        // Only Apple's own: everything Horos does with a Pages file afterwards -
        // the index.xml of a '09 template, the AppleScript it sends - is Pages
        // and nothing else, and handing that to another editor that merely
        // claims the document type would fail in a way nobody could read.
        guard let url = registered(),
              let bundle = Bundle(url: url),
              let identifier = bundle.bundleIdentifier,
              identifier.hasPrefix("com.apple."),
              // It is written into the source of every script.
              identifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") })
        else { return nil }
        return Target(url: url, identifier: identifier)
    }

    /// The application a report that already exists is opened with, when that
    /// is not the user's own choice: a Pages document goes to the Pages every
    /// script is addressed to. Opened in another Pages, the report would not be
    /// found there when its PDF is made, and the PDF would miss what had not
    /// been saved. Anything else, and a Pages document with no Pages found,
    /// is nil: the application the user opens such files with.
    static func application(forReportAt path: String, pages: Target? = target()) -> URL? {
        guard (path as NSString).pathExtension.lowercased() == "pages" else { return nil }
        return pages?.url
    }

    /// Its Info.plist, which is where the version that decides where templates
    /// live is read from.
    @objc public static func information() -> [String: Any]? {
        guard let url = url() else { return nil }
        return Bundle(url: url)?.infoDictionary
    }
}


/// Which of the documents Pages has open is a given file.
///
/// A document handed to Pages is not looked for by its name: `report.pages` is
/// the name of the copy a template is filled in on, and may as well be the
/// name of a document of the user's that is open - a script that took the
/// first document of that name read and rewrote that one. The file is what
/// tells them apart, and once the document is known, everything is addressed
/// to it by its id.
extension PagesApplication.Target {

    /// What a conversation with Pages sends: the source of a script and the
    /// arguments of its run handler, answered with what the script returned,
    /// or nil when it failed.
    typealias Send = (String, [String]) -> NSAppleEventDescriptor?

    /// The documents Pages has open that have a file, each as its id and its
    /// file. Pages is not started to be asked: one that is not running has
    /// no documents. Its argument is the bundle identifier.
    ///
    /// `POSIX path of (file of d)` inside the tell is sent to Pages, which
    /// answers -1700; taken from a variable it is coerced here.
    static let documentsScript = """
    on run argv
      set bundleId to item 1 of argv
      set inventory to {}
      if application id "__PAGES_BUNDLE_ID__" is not running then return inventory
      with timeout of 60 seconds
      using terms from application id "__PAGES_BUNDLE_ID__"
      tell application id bundleId
        repeat with candidate in documents
          set documentFile to file of candidate
          if documentFile is not missing value then
            try
              set documentPath to POSIX path of documentFile
            on error
              set documentPath to documentFile as text
            end try
            set end of inventory to {(id of candidate) as text, documentPath}
          end if
        end repeat
      end tell
      end using terms from
      end timeout
      return inventory
    end run
    """

    /// The file of an open document, as Pages gives it: a POSIX path or a file
    /// URL. Anything else is not a file this code can compare.
    static func fileURL(_ value: String) -> URL? {
        let url: URL
        if value.hasPrefix("/") {
            url = URL(fileURLWithPath: value)
        } else if let parsed = URL(string: value), parsed.isFileURL {
            url = parsed
        } else {
            return nil
        }
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// The id of the document whose file is `path`, in what the documents
    /// script answered; nil when no open document is that file. The two are
    /// compared with their symbolic links resolved: a temporary folder is
    /// `/var/folders` to one and `/private/var/folders` to another. A document
    /// whose file cannot be read is not the one.
    static func documentID(forFile path: String, in inventory: NSAppleEventDescriptor) -> String? {
        guard inventory.numberOfItems > 0 else { return nil }
        let wanted = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        for index in 1...inventory.numberOfItems {
            guard let item = inventory.atIndex(index),
                  let document = item.atIndex(1)?.stringValue,
                  let file = item.atIndex(2)?.stringValue.flatMap(Self.fileURL) else { continue }
            if file.path == wanted { return document }
        }
        return nil
    }

    /// The id of the document Pages opened from `path`, waited for: Pages was
    /// handed the file through LaunchServices, which does not say when the
    /// document is there. Half a minute by default, as the scripts waited.
    /// nil when the document did not appear, and at once when Pages could not
    /// be asked - asking again would not change the answer.
    func documentID(openedFrom path: String, attempts: Int = 60, pause: TimeInterval = 0.5, send: Send) -> String? {
        for attempt in 1...max(attempts, 1) {
            guard let inventory = send(script(Self.documentsScript), [identifier]) else { return nil }
            if let document = Self.documentID(forFile: path, in: inventory) { return document }
            if attempt < attempts { Thread.sleep(forTimeInterval: pause) }
        }
        return nil
    }
}


extension NSWorkspace {
    private static func documentOpeningFinished(_ opened: Bool, error: Error? = nil,
                                               completion: (@Sendable (Bool) -> Void)?) {
        if let completion {
            completion(opened)
        } else if !opened {
            let failure = error ?? CocoaError(.fileReadUnknown)
            onMainRunLoop {
                NSAlert(error: failure).runModal()
            }
        }
    }

    /// The result says whether a launch was submitted; completion reports the
    /// actual launch result. Never wait for an application on the main thread.
    @discardableResult
    func openDocument(atPath path: String, applicationURLs: [URL], fallbackToDefault: Bool = false,
                      completion: (@Sendable (Bool) -> Void)? = nil) -> Bool {
        let document = URL(fileURLWithPath: path)
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            Self.documentOpeningFinished(false, error: CocoaError(.fileNoSuchFile), completion: completion)
            return false
        }
        guard let application = applicationURLs.first else {
            let opened = fallbackToDefault && open(document)
            Self.documentOpeningFinished(opened, completion: completion)
            return opened
        }
        let configuration = NSWorkspace.OpenConfiguration()
        open([document], withApplicationAt: application, configuration: configuration) { _, error in
            if let error {
                NSLog("Unable to open document: %@", error.localizedDescription)
                if applicationURLs.count > 1 || fallbackToDefault {
                    _ = NSWorkspace.shared.openDocument(atPath: path, applicationURLs: Array(applicationURLs.dropFirst()),
                                                       fallbackToDefault: fallbackToDefault, completion: completion)
                } else {
                    NSWorkspace.documentOpeningFinished(false, error: error, completion: completion)
                }
            } else {
                NSWorkspace.documentOpeningFinished(true, completion: completion)
            }
        }
        return true
    }

    /// Opens a report that already exists: a Pages document in the Pages the
    /// scripts are addressed to, anything else as the user opens it. Should
    /// that Pages not start, the document still opens as the user opens it.
    @discardableResult
    func openReport(atPath path: String) -> Bool {
        guard let pages = PagesApplication.application(forReportAt: path) else {
            return open(URL(fileURLWithPath: path))
        }
        // The completion says a failure is not one to interrupt with: opening
        // a report never put up an alert of its own.
        return openDocument(atPath: path, applicationURLs: [pages], fallbackToDefault: true, completion: { _ in })
    }

    @discardableResult
    func openDocument(atPath path: String, applicationIdentifiers: [String], fallbackToDefault: Bool = false,
                      completion: (@Sendable (Bool) -> Void)? = nil) -> Bool {
        openDocument(atPath: path, applicationURLs: applicationIdentifiers.compactMap {
            urlForApplication(withBundleIdentifier: $0)
        }, fallbackToDefault: fallbackToDefault, completion: completion)
    }
}
