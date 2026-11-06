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

/// The crash reports the system wrote for this application since it last
/// looked, in the DiagnosticReports folders.
///
/// A report is `<name>_<date>.crash`, the text the system wrote before
/// macOS 12, or `<name>-<date>.ips` (once `<name>_<date>.ips`), two JSON
/// objects: a header on the first line, which names the process, and the
/// report. An .ips file is taken only when it is a crash of this application:
/// its name, its bundle identifier when the header gives one, and a crash bug
/// type. Another application whose name starts the same way is left out.
public enum CrashReportFinder {
    /// Where the date of the last look is kept. It is the key FeedbackReporter
    /// kept it under, so a crash it already showed is not shown again.
    public static let lastCheckKey = "FRFeedbackReporter.lastCrashCheckDate"

    /// The system's bug types of a crash: 309 today, 109 on the first
    /// systems that wrote .ips files.
    static let crashBugTypes: Set<String> = ["309", "109"]

    public enum Kind: Sendable, Equatable {
        case crash, ips
    }

    /// The kind of report a file name is, for an application named `baseName`.
    public static func kind(ofFileName name: String, baseName: String) -> Kind? {
        let crashPrefix = baseName + "_"
        let ipsPrefix = baseName + "-"
        switch (name as NSString).pathExtension {
        case "crash" where name.hasPrefix(crashPrefix):
            return .crash
        case "ips" where name.hasPrefix(ipsPrefix) || name.hasPrefix(crashPrefix):
            return .ips
        default:
            return nil
        }
    }

    /// The two JSON objects of an .ips report: the header line, and the
    /// report after it when it parses.
    public static func parts(ofReport data: Data) -> (header: [String: Any], body: [String: Any]?)? {
        let newline = data.firstIndex(of: UInt8(ascii: "\n"))
        let headerData = data[data.startIndex..<(newline ?? data.endIndex)]
        guard let header = (try? JSONSerialization.jsonObject(with: headerData)) as? [String: Any] else { return nil }
        var body: [String: Any]?
        if let newline {
            body = (try? JSONSerialization.jsonObject(with: data[data.index(after: newline)...])) as? [String: Any]
        }
        return (header, body)
    }

    /// Whether the header is that of a crash of the application.
    public static func isCrash(header: [String: Any], baseName: String, bundleIdentifier: String?) -> Bool {
        guard let name = (header["app_name"] ?? header["name"]) as? String, name == baseName else { return false }
        if let identifier = bundleIdentifier, !identifier.isEmpty,
           let reported = header["bundleID"] as? String, reported != identifier {
            return false
        }
        guard let type = header["bug_type"] else { return true }
        if let number = type as? NSNumber { return crashBugTypes.contains(number.stringValue) }
        if let string = type as? String { return crashBugTypes.contains(string) }
        return false
    }

    /// The folders the system writes reports to: the computer's, the user's,
    /// and the real home's when a sandbox gives the app a home of its own.
    public static func directories(localLibrary: URL?, userLibrary: URL?, realHome: String?) -> [URL] {
        let reports = "Logs/DiagnosticReports"
        var directories: [URL] = []
        if let localLibrary { directories.append(localLibrary.appendingPathComponent(reports, isDirectory: true)) }
        let user = userLibrary?.appendingPathComponent(reports, isDirectory: true)
        if let user { directories.append(user) }
        if let realHome {
            let real = URL(fileURLWithPath: realHome).appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent(reports, isDirectory: true)
            if real.standardizedFileURL != user?.standardizedFileURL { directories.append(real) }
        }
        return directories
    }

    /// The crash reports of the application in `directories` changed after
    /// `since` (all of them without a date), the oldest first.
    public static func reports(in directories: [URL], since: Date?, baseName: String, bundleIdentifier: String?,
                               fileManager: FileManager = .default) -> [URL] {
        var found: [(date: Date, url: URL)] = []
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        for directory in directories {
            guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                                   options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for file in files {
                guard let kind = kind(ofFileName: file.lastPathComponent, baseName: baseName),
                      let values = try? file.resourceValues(forKeys: Set(keys)),
                      let date = values.contentModificationDate, values.isRegularFile == true else { continue }
                if let since, date <= since { continue }
                if kind == .ips {
                    guard let data = try? Data(contentsOf: file, options: .mappedIfSafe),
                          let header = parts(ofReport: data)?.header,
                          isCrash(header: header, baseName: baseName, bundleIdentifier: bundleIdentifier) else { continue }
                }
                found.append((date, file))
            }
        }
        return found.sorted { $0.date < $1.date }.map(\.url)
    }
}

/// Whether to show the crash report window, and for which report.
public enum CrashReportOffer {
    /// The newest new report, outside the App Store and TestFlight, where
    /// crashes reach the developer through Xcode's Organizer instead.
    public static func reportToOffer(isAppStore: Bool, newReports: [URL]) -> URL? {
        isAppStore ? nil : newReports.last
    }
}
