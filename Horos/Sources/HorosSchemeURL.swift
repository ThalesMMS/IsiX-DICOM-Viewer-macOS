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
import CoreServices
import Foundation
import IsiXHTTPServer
import Synchronization

/// An `isix://`, `horos://` or `osirix://` invocation, parsed on its own.
///
/// LaunchServices decides which application receives the Apple Event. Chrome
/// decides whether a page is allowed to hand the URL to LaunchServices
/// at all. The handler in `AppController` used to fold those two questions into
/// the query parser, so a blocked external-protocol prompt and a missing
/// StudyInstanceUID looked the same. They are not.
@objc(HorosSchemeURL)
public final class HorosSchemeURL: NSObject {
    @objc public let scheme: String
    @objc public let methodName: String?
    @objc public let parameters: [String: String]
    @objc public let imageSpecifier: String?

    @objc public init(scheme: String, methodName: String?,
                      parameters: [String: String], imageSpecifier: String?) {
        self.scheme = scheme
        self.methodName = methodName
        self.parameters = parameters
        self.imageSpecifier = imageSpecifier
        super.init()
    }

    /// The last URL that arrived, and when.
    private static let last = Mutex<(url: String?, at: TimeInterval)>((nil, 0))

    private static let displayStudyKeys = [
        "patientid", "studyinstanceuid", "accessionnumber", "studyid",
    ]

    /// Parse only. LaunchServices and the browser are a different layer.
    @objc(parseString:)
    public static func parse(_ string: String) -> HorosSchemeDiagnosis {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = trimmed.firstIndex(of: ":") else {
            return HorosSchemeDiagnosis.parser(code: "unsupported-scheme",
                                               message: "not an isix://, horos:// or osirix:// URL")
        }
        // The schemes the application declares, each read the same way.
        let scheme = String(trimmed[..<colon]).lowercased()
        guard LinkSchemeHandlers.isDeclared(scheme) else {
            return HorosSchemeDiagnosis.parser(code: "unsupported-scheme",
                                               message: "not an isix://, horos:// or osirix:// URL")
        }

        let specifier = String(trimmed[trimmed.index(after: colon)...])
        guard let query = query(fromSpecifier: specifier) else {
            return HorosSchemeDiagnosis.parser(code: "missing-query",
                                               message: "the URL has no query")
        }
        if query.isEmpty {
            return HorosSchemeDiagnosis.parser(code: "missing-query",
                                               message: "the URL has no query")
        }

        var parameters: [String: String] = [:]
        for pair in splitUnquoted(query, separator: "&") {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            let rawKey = String(pair[..<equals])
            let rawValue = String(pair[pair.index(after: equals)...])
            guard let key = decode(rawKey), let value = decode(rawValue) else {
                return HorosSchemeDiagnosis.parser(code: "invalid-encoding",
                                                   message: "a parameter is not valid percent-encoding")
            }
            if key.isEmpty { continue }
            parameters[key] = stripMatchingQuotes(value)
        }

        let methodName = parameters["methodName"]
        let image = parameters["image"]
        if let method = methodName, method.lowercased() == "displaystudy",
           !hasDisplayStudyIdentifier(parameters) {
            let invocation = HorosSchemeURL(scheme: scheme, methodName: method,
                                            parameters: parameters, imageSpecifier: image)
            return HorosSchemeDiagnosis(layer: "parser", code: "invalid-parameters",
                                        message: "DisplayStudy needs PatientID, StudyInstanceUID, AccessionNumber or StudyID",
                                        invocation: invocation)
        }

        if (methodName == nil || methodName?.isEmpty == true) && (image == nil || image?.isEmpty == true) {
            return HorosSchemeDiagnosis.parser(code: "missing-query",
                                               message: "the URL has no methodName or image parameter")
        }

        let invocation = HorosSchemeURL(scheme: scheme, methodName: methodName,
                                        parameters: parameters, imageSpecifier: image)
        return HorosSchemeDiagnosis(layer: "accepted", code: "ok",
                                    message: "ok", invocation: invocation)
    }

    /// Parser first; only then LaunchServices; only then the browser.
    @objc(diagnoseString:snapshot:)
    public static func diagnose(_ string: String,
                                snapshot: HorosSchemeLaunchSnapshot) -> HorosSchemeDiagnosis {
        let parsed = parse(string)
        if parsed.layer == "parser" {
            return parsed
        }
        if snapshot.appleEventDelivered {
            return HorosSchemeDiagnosis(layer: "accepted", code: "ok",
                                        message: "LaunchServices delivered the Apple Event",
                                        invocation: parsed.invocation)
        }

        let scheme = snapshot.scheme.isEmpty ? (parsed.invocation?.scheme ?? "horos") : snapshot.scheme
        if snapshot.candidateBundleIDs.isEmpty {
            return HorosSchemeDiagnosis(layer: "launchServices", code: "no-handler",
                                        message: "LaunchServices has no application for \(scheme)://",
                                        invocation: parsed.invocation)
        }
        if snapshot.chosenBundleID != nil || snapshot.chosenPath != nil, !snapshot.chosenIsRunningApplication {
            let chosen = [snapshot.chosenBundleID, snapshot.chosenPath].compactMap { $0 }.joined(separator: " at ")
            return HorosSchemeDiagnosis(layer: "launchServices", code: "other-handler",
                                        message: "LaunchServices would open \(chosen)",
                                        invocation: parsed.invocation)
        }

        if snapshot.chromeExcludedSchemes[scheme] == true {
            return HorosSchemeDiagnosis(layer: "browser", code: "chrome-excluded-scheme",
                                        message: "Chrome protocol_handler.excluded_schemes.\(scheme) is true",
                                        invocation: parsed.invocation)
        }
        if snapshot.chromeMajorVersion >= 94 && snapshot.externalProtocolPromptObserved {
            return HorosSchemeDiagnosis(layer: "browser", code: "chrome-external-protocol-prompt",
                                        message: "Chrome's external protocol prompt was observed; no Apple Event arrived",
                                        invocation: parsed.invocation)
        }
        if snapshot.chromeMajorVersion >= 94 {
            // Browser-initiated navigation can show the prompt even when the
            // page has no activation. A gesture flag alone cannot prove either
            // that Chrome blocked the URL or that its prompt appeared.
            return HorosSchemeDiagnosis(layer: "browser", code: "chrome-navigation-unconfirmed",
                                        message: "No Apple Event was observed. Check Chrome's external protocol prompt and navigation policy; a page gesture alone does not establish delivery or blocking",
                                        invocation: parsed.invocation)
        }

        return HorosSchemeDiagnosis(layer: "accepted", code: "ok",
                                    message: "ok", invocation: parsed.invocation)
    }

    /// Read-only: who LaunchServices picks, the application that is running
    /// to compare it with, and Chrome's recorded protocol policy.
    @objc(liveSnapshotForScheme:)
    public static func liveSnapshot(forScheme scheme: String) -> HorosSchemeLaunchSnapshot {
        let snapshot = HorosSchemeLaunchSnapshot()
        snapshot.scheme = scheme
        if let url = URL(string: "\(scheme)://example") {
            snapshot.candidateBundleIDs = Self.handlerURLs(for: url)
                .compactMap { Bundle(url: $0)?.bundleIdentifier }
            if let chosen = NSWorkspace.shared.urlForApplication(toOpen: url) {
                snapshot.chosenBundleID = Bundle(url: chosen)?.bundleIdentifier
                snapshot.chosenPath = chosen.resolvingSymlinksInPath().path
            }
        }
        snapshot.runningBundleID = Bundle.main.bundleIdentifier
        snapshot.runningPath = runningBundlePath()
        snapshot.applyChromePreferencesIfPresent()
        snapshot.navigationHadUserGesture = false
        snapshot.appleEventDelivered = false
        return snapshot
    }

    /// Every application LaunchServices would offer for this URL. The plural
    /// NSWorkspace query arrived in macOS 12 and this target still builds for
    /// earlier systems, so the older LaunchServices call answers there; both
    /// report the same registrations, which is what the diagnosis reads.
    private static func handlerURLs(for url: URL) -> [URL] {
        if #available(macOS 12.0, *) {
            return NSWorkspace.shared.urlsForApplications(toOpen: url)
        }
        guard let copied = LSCopyApplicationURLsForURL(url as CFURL, .all) else { return [] }
        return copied.takeRetainedValue() as? [URL] ?? []
    }

    /// True when this exact URL already arrived within the last second.
    @objc(consumeDuplicate:)
    public static func consumeDuplicate(_ string: String) -> Bool {
        let now = Date.timeIntervalSinceReferenceDate
        return last.withLock { last in
            if last.url == string && now - last.at < 1 {
                return true
            }
            last = (string, now)
            return false
        }
    }

    /// Where the bundle that is running is, with its links resolved, to
    /// compare with the application LaunchServices picks. Unknown for a copy
    /// the system runs from a randomized place of its own, which LaunchServices
    /// knows by the place the user put it in: that copy is told by its
    /// identifier alone.
    static func runningBundlePath() -> String? {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        return path.contains("/AppTranslocation/") ? nil : path
    }

    static func hasDisplayStudyIdentifier(_ parameters: [String: String]) -> Bool {
        for (key, value) in parameters {
            if displayStudyKeys.contains(key.lowercased()),
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
        }
        return false
    }

    static func query(fromSpecifier specifier: String) -> String? {
        let parts = splitUnquoted(specifier, separator: "?")
        if parts.count < 2 {
            return nil
        }
        return parts.dropFirst().joined(separator: "?")
    }

    static func splitUnquoted(_ text: String, separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var quoted = false
        for character in text {
            if character == "'" {
                quoted.toggle()
                current.append(character)
            } else if character == separator && !quoted {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts
    }

    /// Decode percent-escapes. `+` stays `+`: `image=` uses it as the SOP separator.
    static func decode(_ raw: String) -> String? {
        if raw.contains("%") {
            return raw.removingPercentEncoding
        }
        return raw
    }

    static func stripMatchingQuotes(_ value: String) -> String {
        guard value.count >= 2,
              let first = value.first, first == "'" || first == "\"",
              value.last == first else { return value }
        return String(value.dropFirst().dropLast())
    }
}

@objc(HorosSchemeDiagnosis)
public final class HorosSchemeDiagnosis: NSObject {
    @objc public let layer: String
    @objc public let code: String
    @objc public let message: String
    @objc public let invocation: HorosSchemeURL?

    @objc public init(layer: String, code: String, message: String, invocation: HorosSchemeURL?) {
        self.layer = layer
        self.code = code
        self.message = message
        self.invocation = invocation
        super.init()
    }

    static func parser(code: String, message: String) -> HorosSchemeDiagnosis {
        return HorosSchemeDiagnosis(layer: "parser", code: code, message: message, invocation: nil)
    }
}

/// Evidence for the two layers that are not the parser. Nothing here is written
/// back to LaunchServices or to a browser profile.
@objc(HorosSchemeLaunchSnapshot)
public final class HorosSchemeLaunchSnapshot: NSObject {
    @objc public var scheme: String = ""
    @objc public var candidateBundleIDs: [String] = []
    @objc public var chosenBundleID: String?
    /// Where the chosen application is, when LaunchServices was asked.
    @objc public var chosenPath: String?
    /// The application the choice is compared with: the one that is running.
    /// No fixed identifier is the application's own: each build has its own,
    /// and an earlier copy with another one is another application.
    @objc public var runningBundleID: String?
    @objc public var runningPath: String?
    @objc public var chromeExcludedSchemes: [String: Bool] = [:]
    @objc public var chromeMajorVersion: Int = 0
    @objc public var navigationHadUserGesture: Bool = false
    @objc public var externalProtocolPromptObserved: Bool = false
    @objc public var appleEventDelivered: Bool = false

    @objc(chromeSnapshotFromPreferencesJSON:majorVersion:)
    public static func chromeSnapshot(fromPreferencesJSON json: String,
                                      majorVersion: Int) -> HorosSchemeLaunchSnapshot {
        let snapshot = HorosSchemeLaunchSnapshot()
        snapshot.chromeMajorVersion = majorVersion
        snapshot.chromeExcludedSchemes = excludedSchemes(fromPreferencesJSON: json)
        return snapshot
    }

    /// Whether LaunchServices picks the application that is running.
    var chosenIsRunningApplication: Bool {
        LinkSchemeHandlers.isRunningApplication(
            LinkSchemeHandlers.Application(identifier: chosenBundleID, path: chosenPath),
            running: LinkSchemeHandlers.Application(identifier: runningBundleID, path: runningPath))
    }

    func applyChromePreferencesIfPresent() {
        chromeMajorVersion = Self.readChromeMajorVersion()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let preferences = home
            .appendingPathComponent("Library/Application Support/Google/Chrome/Default/Preferences")
        guard let data = try? Data(contentsOf: preferences),
              let text = String(data: data, encoding: .utf8) else { return }
        chromeExcludedSchemes = Self.excludedSchemes(fromPreferencesJSON: text)
    }

    static func excludedSchemes(fromPreferencesJSON json: String) -> [String: Bool] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let handler = object["protocol_handler"] as? [String: Any],
              let excluded = handler["excluded_schemes"] as? [String: Any] else {
            return [:]
        }
        var result: [String: Bool] = [:]
        for (scheme, value) in excluded {
            if let flag = value as? Bool {
                result[scheme] = flag
            } else if let number = value as? NSNumber {
                result[scheme] = number.boolValue
            }
        }
        return result
    }

    static func readChromeMajorVersion() -> Int {
        let chrome = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        guard FileManager.default.isExecutableFile(atPath: chrome.path) else { return 0 }
        let task = Process()
        task.executableURL = chrome
        task.arguments = ["--version"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return 0 }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        let digits = text.split(whereSeparator: { !$0.isNumber && $0 != "." }).first
        if let major = digits?.split(separator: ".").first, let value = Int(major) {
            return value
        }
        return 0
    }
}
