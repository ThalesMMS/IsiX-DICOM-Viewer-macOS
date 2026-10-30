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

/// What a crash report says, in a few lines: the version and architecture
/// that crashed, the exception and the top of the crashed thread.
///
/// Only names are kept: images by their file name, functions by their
/// symbol. Paths, the process's arguments and application-specific messages,
/// which can name a patient's files, are left out; the report itself, which
/// has them, only leaves the computer if the user attaches it.
public struct CrashSummary: Equatable, Sendable {
    public var version: String?
    public var build: String?
    public var architecture: String?
    public var operatingSystem: String?
    public var exception: String?
    public var termination: String?
    /// "image  symbol + offset", the crashed thread's first frames.
    public var frames: [String] = []

    /// At most this many frames of the crashed thread.
    public static let frameLimit = 15

    public init(version: String? = nil, build: String? = nil, architecture: String? = nil, operatingSystem: String? = nil,
                exception: String? = nil, termination: String? = nil, frames: [String] = []) {
        self.version = version
        self.build = build
        self.architecture = architecture
        self.operatingSystem = operatingSystem
        self.exception = exception
        self.termination = termination
        self.frames = frames
    }

    /// The summary of a report's contents, .ips or .crash text.
    public static func of(report data: Data) -> CrashSummary {
        if let parts = CrashReportFinder.parts(ofReport: data) {
            return of(header: parts.header, body: parts.body ?? [:])
        }
        return of(text: String(decoding: data, as: UTF8.self))
    }

    static func string(_ value: Any?) -> String? {
        if let number = value as? NSNumber { return number.stringValue }
        if let string = value as? String, !string.isEmpty { return string }
        return nil
    }

    static func of(header: [String: Any], body: [String: Any]) -> CrashSummary {
        var summary = CrashSummary()
        summary.version = string(header["app_version"])
        summary.build = string(header["build_version"])
        summary.operatingSystem = string(header["os_version"])
        if let cpu = string(body["cpuType"]) {
            let architecture = ["ARM-64": "arm64", "X86-64": "x86_64"][cpu] ?? cpu
            summary.architecture = (body["translated"] as? Bool) == true ? architecture + " (Rosetta)" : architecture
        }
        if let exception = body["exception"] as? [String: Any] {
            let type = string(exception["type"])
            let signal = string(exception["signal"])
            summary.exception = [type, signal.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
            if summary.exception?.isEmpty == true { summary.exception = nil }
        }
        if let termination = body["termination"] as? [String: Any] {
            summary.termination = string(termination["indicator"])
        }
        let threads = body["threads"] as? [Any] ?? []
        let images = body["usedImages"] as? [Any] ?? []
        if let faulting = (body["faultingThread"] as? NSNumber)?.intValue, faulting >= 0, faulting < threads.count,
           let frames = (threads[faulting] as? [String: Any])?["frames"] as? [Any] {
            for frame in frames.prefix(frameLimit) {
                guard let frame = frame as? [String: Any] else { continue }
                var image = "???"
                if let index = (frame["imageIndex"] as? NSNumber)?.intValue, index >= 0, index < images.count,
                   let name = string((images[index] as? [String: Any])?["name"]) {
                    image = name
                }
                let place: String
                if let symbol = string(frame["symbol"]) {
                    place = "\(symbol) + \(string(frame["symbolLocation"]) ?? "0")"
                } else {
                    place = "image offset \(string(frame["imageOffset"]) ?? "?")"
                }
                summary.frames.append("\(image)  \(place)")
            }
        }
        return summary
    }

    /// A .crash text report: the lines that say the same, and the crashed
    /// thread's frames without their addresses' images' paths.
    static func of(text: String) -> CrashSummary {
        var summary = CrashSummary()
        var inCrashedThread = false
        for line in text.components(separatedBy: .newlines) {
            if inCrashedThread {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || summary.frames.count == frameLimit {
                    inCrashedThread = false
                    continue
                }
                // "0   libsystem_kernel.dylib  0x00000001 __pthread_kill + 8": the
                // image and the symbol, without the frame number and address.
                let fields = trimmed.split(separator: " ", omittingEmptySubsequences: true)
                if fields.count >= 4 {
                    summary.frames.append("\(fields[1])  \(fields[3...].joined(separator: " "))")
                }
                continue
            }
            func value(_ label: String) -> String? {
                line.hasPrefix(label) ? line.dropFirst(label.count).trimmingCharacters(in: .whitespaces) : nil
            }
            if let version = value("Version:") {
                // "1.2.3 (456)"
                let parts = version.split(separator: " ", maxSplits: 1)
                summary.version = parts.first.map(String.init)
                summary.build = parts.count > 1 ? parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "()")) : nil
            } else if let code = value("Code Type:") {
                summary.architecture = code.hasPrefix("ARM-64") ? "arm64" : code.hasPrefix("X86-64") ? "x86_64" : code
                if code.contains("(Translated)") { summary.architecture! += " (Rosetta)" }
            } else if let os = value("OS Version:") {
                summary.operatingSystem = os
            } else if let exception = value("Exception Type:") {
                summary.exception = exception
            } else if let termination = value("Termination Reason:") {
                summary.termination = termination
            } else if line.hasPrefix("Thread "), line.contains("Crashed:") {
                inCrashedThread = true
            }
        }
        return summary
    }

    /// The summary's lines, as the mail and the issue show them.
    public var lines: [String] {
        var lines: [String] = []
        let version = [self.version, build.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        if !version.isEmpty { lines.append("Version: " + version) }
        if let architecture { lines.append("Architecture: " + architecture) }
        if let operatingSystem { lines.append("macOS: " + operatingSystem) }
        if let exception { lines.append("Exception: " + exception) }
        if let termination { lines.append("Termination: " + termination) }
        return lines
    }
}

/// The two ways a crash report reaches the developer, both of them opened
/// for the user to review and send: a mail with the report attached, and a
/// new issue on the public repository, filled in, to which the user attaches
/// the report.
public struct CrashReportDraft: Equatable, Sendable {
    public static let recipient = "thalesmmsradio@gmail.com"
    public static let repository = "ThalesMMS/IsiX-DICOM-Viewer-macOS"
    /// GitHub refuses longer new-issue addresses.
    public static let maximumIssueURLLength = 7500

    public var applicationName: String
    public var summary: CrashSummary
    public var report: URL

    public init(applicationName: String, summary: CrashSummary, report: URL) {
        self.applicationName = applicationName
        self.summary = summary
        self.report = report
    }

    public var mailRecipients: [String] { [CrashReportDraft.recipient] }

    public var mailSubject: String {
        var subject = "\(applicationName) crash report"
        let version = [summary.version, summary.build.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        if !version.isEmpty { subject += ": " + version }
        if let architecture = summary.architecture { subject += ", " + architecture }
        return subject
    }

    public var mailBody: String {
        var body = "\(applicationName) quit unexpectedly. The crash report is attached: \(report.lastPathComponent).\n\n"
        body += summary.lines.joined(separator: "\n")
        if !summary.frames.isEmpty {
            body += "\n\nCrashed thread:\n" + summary.frames.joined(separator: "\n")
        }
        return body + "\n\nWhat was I doing when it happened:\n\n"
    }

    public var issueTitle: String {
        "Crash: " + ([summary.exception, summary.version.map { "in \($0)" }].compactMap { $0 }.joined(separator: " ")
            .nonEmpty ?? "\(applicationName) quit unexpectedly")
    }

    public func issueBody(frameLimit: Int = CrashSummary.frameLimit) -> String {
        var body = "**What happened**\n\n\(applicationName) quit unexpectedly.\n\n**What I was doing**\n\n\n\n**Crash summary**\n\n"
        body += summary.lines.map { "- " + $0 }.joined(separator: "\n")
        let frames = summary.frames.prefix(frameLimit)
        if !frames.isEmpty {
            body += "\n\nCrashed thread:\n\n```\n" + frames.joined(separator: "\n") + "\n```"
        }
        body += "\n\n**Crash report**\n\nThe full report is \(report.lastPathComponent), in ~/Library/Logs/DiagnosticReports. "
            + "It can hold names of files and folders: check it before attaching it here."
        return body
    }

    /// The new-issue page of the public repository, filled in; frames are
    /// dropped from the end until it fits GitHub's limit.
    public var issueURL: URL {
        var limit = summary.frames.count
        while true {
            var components = URLComponents(string: "https://github.com/\(CrashReportDraft.repository)/issues/new")!
            components.queryItems = [URLQueryItem(name: "title", value: issueTitle),
                                     URLQueryItem(name: "body", value: issueBody(frameLimit: limit))]
            // "+" means a space in a query: spell it out.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            let url = components.url!
            if url.absoluteString.count <= CrashReportDraft.maximumIssueURLLength || limit == 0 { return url }
            limit -= 1
        }
    }
}

extension String {
    fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}
