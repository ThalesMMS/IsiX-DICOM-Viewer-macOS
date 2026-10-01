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
import UniformTypeIdentifiers

/// Where Pages is, when it is anywhere.
///
/// Horos asked for the bundle identifier `com.apple.iWork.Pages`, which is what
/// Pages '09 answered to. Pages 15.3.1, installed and signed by Apple, answers to
/// `com.apple.Pages`, and measured on a machine with it installed:
///
///     com.apple.iWork.Pages: nil
///     com.apple.Pages: /Applications/Pages.app
///
/// so the report generator said "Pages is not installed or could not be located"
/// with Pages sitting in the Applications folder. Both identifiers are asked for
/// now, and after them the application registered to open a Pages document,
/// which is the question that actually matters and does not have to be revisited
/// the next time the identifier changes.
@objc(HorosPagesApplication)
public final class PagesApplication: NSObject {

    /// The identifiers Pages has used, newest last so the older one still wins
    /// where both are installed - a Pages '09 template needs Pages '09.
    private static let identifiers = ["com.apple.iWork.Pages", "com.apple.Pages"]

    /// The document type a Pages file is, which is how the application is found
    /// when it answers to neither identifier.
    private static let documentType = "com.apple.iwork.pages.pages"

    @objc public static func url() -> URL? {
        let workspace = NSWorkspace.shared
        for identifier in identifiers {
            if let url = workspace.urlForApplication(withBundleIdentifier: identifier) {
                return url
            }
        }
        // Asking by document type needs macOS 12; below it the two identifiers
        // above are all there is, which is what every Pages before then used.
        guard #available(macOS 12.0, *),
              let type = UTType(documentType),
              let url = workspace.urlForApplication(toOpen: type) else { return nil }
        // Only Apple's own: everything Horos does with a Pages file afterwards -
        // the index.xml of a '09 template, the AppleScript it sends - is Pages
        // and nothing else, and handing that to another editor that merely
        // claims the document type would fail in a way nobody could read.
        guard let bundle = Bundle(url: url),
              let identifier = bundle.bundleIdentifier,
              identifier.hasPrefix("com.apple.") else { return nil }
        return url
    }

    /// Its Info.plist, which is where the version that decides where templates
    /// live is read from.
    @objc public static func information() -> [String: Any]? {
        guard let url = url() else { return nil }
        return Bundle(url: url)?.infoDictionary
    }
}


extension NSWorkspace {
    private static func documentOpeningFinished(_ opened: Bool, error: Error? = nil,
                                               completion: (@Sendable (Bool) -> Void)?) {
        if let completion {
            completion(opened)
        } else if !opened {
            let failure = error ?? CocoaError(.fileReadUnknown)
            DispatchQueue.main.async {
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

    @discardableResult
    func openDocument(atPath path: String, applicationIdentifiers: [String], fallbackToDefault: Bool = false,
                      completion: (@Sendable (Bool) -> Void)? = nil) -> Bool {
        openDocument(atPath: path, applicationURLs: applicationIdentifiers.compactMap {
            urlForApplication(withBundleIdentifier: $0)
        }, fallbackToDefault: fallbackToDefault, completion: completion)
    }
}
