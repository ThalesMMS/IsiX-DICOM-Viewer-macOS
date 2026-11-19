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
/// that crashed, the exception and the top of the crashed thread. When an
/// Objective-C exception nobody caught ended the application, the crashed
/// thread only says that; what raised it is the exception's own name, reason
/// and backtrace, which are kept too.
///
/// Only names are kept: images by their file name, functions by their
/// symbol. Paths, the process's arguments and application-specific messages,
/// which can name a patient's files, are left out; the report itself, which
/// has them, only leaves the computer if the user attaches it. The one
/// message kept is the reason of the exception, after `CrashReportText` took
/// out of it what can name a file, a folder or the user.
public struct CrashSummary: Equatable, Sendable {
    public var version: String?
    public var build: String?
    public var architecture: String?
    public var operatingSystem: String?
    public var exception: String?
    public var termination: String?
    /// "image  symbol + offset", the crashed thread's first frames.
    public var frames: [String] = []
    /// The name of the Objective-C exception that ended the application.
    public var exceptionName: String?
    /// What the exception said, cleaned of paths, file names and user names.
    public var exceptionReason: String?
    /// The first frames of where the exception was raised, as `frames`.
    public var exceptionFrames: [String] = []

    /// At most this many frames of the crashed thread, and as many of the
    /// exception's backtrace.
    public static let frameLimit = 15

    public init(version: String? = nil, build: String? = nil, architecture: String? = nil, operatingSystem: String? = nil,
                exception: String? = nil, termination: String? = nil, frames: [String] = [],
                exceptionName: String? = nil, exceptionReason: String? = nil, exceptionFrames: [String] = []) {
        self.version = version
        self.build = build
        self.architecture = architecture
        self.operatingSystem = operatingSystem
        self.exception = exception
        self.termination = termination
        self.frames = frames
        self.exceptionName = exceptionName
        self.exceptionReason = exceptionReason
        self.exceptionFrames = exceptionFrames
    }

    /// The summary of a report's contents, .ips or .crash text. `userNames`
    /// are taken out of the exception's reason wherever they appear.
    public static func of(report data: Data, userNames: [String] = CrashReportText.localUserNames) -> CrashSummary {
        if let parts = CrashReportFinder.parts(ofReport: data) {
            return of(header: parts.header, body: parts.body ?? [:], userNames: userNames)
        }
        return of(text: String(decoding: data, as: UTF8.self), userNames: userNames)
    }

    static func string(_ value: Any?) -> String? {
        if let number = value as? NSNumber { return number.stringValue }
        if let string = value as? String, !string.isEmpty { return string }
        return nil
    }

    /// "image  symbol + offset" of the first frames of a thread or of an
    /// exception's backtrace of an .ips report.
    static func frameLines(_ frames: [Any], images: [Any]) -> [String] {
        var lines: [String] = []
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
            lines.append("\(image)  \(place)")
        }
        return lines
    }

    /// The image and the symbol of a frame's line of a text report,
    /// "0   libsystem_kernel.dylib  0x00000001 __pthread_kill + 8", without
    /// the frame number and the address. An image's name can have spaces: it
    /// ends where the address begins, after spaces or tabs.
    static func frameLine(ofTextLine line: String) -> String? {
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count >= 4 else { return nil }
        func isAddress(_ field: Substring) -> Bool {
            field.hasPrefix("0x") && field.count > 2 && field.dropFirst(2).allSatisfy(\.isHexDigit)
        }
        if let address = fields.indices.dropFirst(2).first(where: { isAddress(fields[$0]) }), address + 1 < fields.count {
            return "\(fields[1..<address].joined(separator: " "))  \(fields[(address + 1)...].joined(separator: " "))"
        }
        return "\(fields[1])  \(fields[3...].joined(separator: " "))"
    }

    private mutating func setException(name: String?, reason: String?, userNames: [String]) {
        exceptionName = name.flatMap { CrashReportText.cleaned($0, userNames: userNames, limit: CrashReportText.nameLimit) }
        exceptionReason = reason.flatMap { CrashReportText.cleaned($0, userNames: userNames) }
    }

    static func of(header: [String: Any], body: [String: Any], userNames: [String] = []) -> CrashSummary {
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
            summary.frames = frameLines(frames, images: images)
        }
        // An exception nobody caught: its backtrace, and its name and reason
        // from the fields of their own or, in reports without them, from the
        // line a library left in the application-specific information.
        summary.exceptionFrames = frameLines(body["lastExceptionBacktrace"] as? [Any] ?? [], images: images)
        // An exception the application framework ends the application on
        // leaves no such backtrace, and neither name nor reason: where it
        // was raised is the first of the backtraces kept as text.
        if summary.exceptionFrames.isEmpty, let backtrace = (body["asiBacktraces"] as? [Any])?.first as? String {
            summary.exceptionFrames = Array(backtrace.components(separatedBy: .newlines)
                .compactMap { frameLine(ofTextLine: $0.trimmingCharacters(in: .whitespaces)) }.prefix(frameLimit))
        }
        let described = body["exceptionReason"] as? [String: Any] ?? [:]
        var information: [String] = []
        if let asi = body["asi"] as? [String: Any] {
            for library in asi.keys.sorted() {
                for text in asi[library] as? [Any] ?? [] {
                    information += (text as? String ?? "").components(separatedBy: .newlines)
                }
            }
        }
        let said = CrashReportText.exception(inApplicationInformation: information)
        summary.setException(name: string(described["name"]) ?? said.name,
                             reason: string(described["composed_message"]) ?? said.reason, userNames: userNames)
        return summary
    }

    /// A .crash text report: the lines that say the same, and the crashed
    /// thread's frames without their addresses' images' paths.
    static func of(text: String, userNames: [String] = []) -> CrashSummary {
        enum Section { case none, crashedThread, information, exceptionBacktrace }
        var summary = CrashSummary()
        var section = Section.none
        var information: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            switch section {
            case .crashedThread, .exceptionBacktrace:
                let count = section == .crashedThread ? summary.frames.count : summary.exceptionFrames.count
                if trimmed.isEmpty || count == frameLimit {
                    section = .none
                } else if let frame = frameLine(ofTextLine: trimmed) {
                    if section == .crashedThread { summary.frames.append(frame) } else { summary.exceptionFrames.append(frame) }
                }
                continue
            case .information:
                if trimmed.isEmpty { section = .none } else { information.append(trimmed) }
                continue
            case .none:
                break
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
                section = .crashedThread
            } else if line.hasPrefix("Application Specific Information:") {
                section = .information
            } else if line.hasPrefix("Application Specific Backtrace") || line.hasPrefix("Last Exception Backtrace:") {
                section = summary.exceptionFrames.isEmpty ? .exceptionBacktrace : .none
            }
        }
        let said = CrashReportText.exception(inApplicationInformation: information)
        summary.setException(name: said.name, reason: said.reason, userNames: userNames)
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

    /// The exception nobody caught, as the mail and the issue show it: its
    /// name and reason in one line, then the first frames of its backtrace.
    /// Empty when the report has no such exception.
    public func exceptionLines(frameLimit: Int = CrashSummary.frameLimit) -> [String] {
        let title = [exceptionName, exceptionReason].compactMap { $0 }.joined(separator: ": ")
        return (title.isEmpty ? [] : [title]) + exceptionFrames.prefix(max(frameLimit, 0))
    }

    /// The whole summary as plain text, as the window and the mail show it:
    /// its lines, the exception nobody caught and then the crashed thread.
    public var text: String {
        var text = lines.joined(separator: "\n")
        let exception = exceptionLines()
        if !exception.isEmpty {
            text += "\n\nUncaught exception:\n" + exception.joined(separator: "\n")
        }
        if !frames.isEmpty {
            text += "\n\nCrashed thread:\n" + frames.joined(separator: "\n")
        }
        return text
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
        body += summary.text
        return body + "\n\nWhat was I doing when it happened:\n\n"
    }

    /// The title of the issue: the kind of crash and the version. Every
    /// exception nobody caught ends the application the same way, so the
    /// exception's name tells one from another; its reason, which can say
    /// anything, stays in the body.
    public var issueTitle: String {
        let what = [summary.exception, exceptionTypeName].compactMap { $0 }.joined(separator: ", ").nonEmpty
        return "Crash: " + ([what, summary.version.map { "in \($0)" }].compactMap { $0 }.joined(separator: " ")
            .nonEmpty ?? "\(applicationName) quit unexpectedly")
    }

    /// The exception's name when it is the name of a type: one word of
    /// ASCII letters, digits, "_" and ".", as NSRangeException. Whoever
    /// raises an exception names it freely, and a name that is a sentence
    /// can carry what the reason carries: that one stays out of the title.
    private var exceptionTypeName: String? {
        guard let name = summary.exceptionName, let first = name.unicodeScalars.first,
              first == "_" || (first.isASCII && first.properties.isAlphabetic) else { return nil }
        let isWord = name.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "_" || scalar == ".")
        }
        return isWord ? name : nil
    }

    public func issueBody(frameLimit: Int = CrashSummary.frameLimit) -> String {
        var body = "**What happened**\n\n\(applicationName) quit unexpectedly.\n\n**What I was doing**\n\n\n\n**Crash summary**\n\n"
        body += summary.lines.map { "- " + $0 }.joined(separator: "\n")
        // What raised the exception comes first: the crashed thread of such
        // a report only shows the frameworks ending the application.
        let exception = summary.exceptionLines(frameLimit: frameLimit)
        if !exception.isEmpty {
            body += "\n\nUncaught exception:\n\n```\n" + exception.joined(separator: "\n") + "\n```"
        }
        let frames = summary.frames.prefix(frameLimit)
        if !frames.isEmpty {
            body += "\n\nCrashed thread:\n\n```\n" + frames.joined(separator: "\n") + "\n```"
        }
        body += "\n\n**Crash report**\n\nThe full report is \(report.lastPathComponent), in ~/Library/Logs/DiagnosticReports. "
            + "It can hold names of files and folders: check it before attaching it here."
        return body
    }

    /// The new-issue page of the public repository, filled in; frames are
    /// dropped from the end, of the crashed thread and of the exception
    /// alike, until it fits GitHub's limit.
    public var issueURL: URL {
        var limit = max(summary.frames.count, summary.exceptionFrames.count)
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
