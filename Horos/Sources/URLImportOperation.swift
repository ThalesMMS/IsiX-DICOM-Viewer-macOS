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

/// What became of one URL of an import.
@objc(HorosURLImportEntry)
public final class URLImportEntry: NSObject {
    @objc(HorosURLImportOutcome)
    public enum Outcome: Int {
        /// A DICOM object, written into the database and indexed.
        case indexed
        /// An archive, handed to the import folder to be expanded there.
        case expanded
        /// Downloaded, and neither a DICOM object nor an archive: handed to the
        /// import folder, which names and keeps a file it cannot read.
        case refused
        /// Not downloaded, or not written: nothing of it is in the database.
        case failed
    }

    @objc public let url: String
    @objc public let outcome: Outcome
    /// Where its bytes were written, or nil.
    @objc public let path: String?
    /// Why it was refused or failed, or nil.
    @objc public let reason: String?

    init(url: String, outcome: Outcome, path: String?, reason: String?) {
        self.url = url; self.outcome = outcome; self.path = path; self.reason = reason
        super.init()
    }
}

/// The result of an import: every URL's entry in the order it was given, the
/// files written in that order, the report for the person, and whether all of
/// it arrived.
@objc(HorosURLImportResult)
public final class URLImportResult: NSObject {
    @objc public let entries: [URLImportEntry]
    @objc public let files: [String]
    @objc public let report: String
    /// Everything was downloaded and taken, and there was something to import.
    @objc public let succeeded: Bool
    @objc public let cancelled: Bool

    init(entries: [URLImportEntry], report: String, succeeded: Bool, cancelled: Bool) {
        self.entries = entries
        files = entries.compactMap { $0.path }
        self.report = report; self.succeeded = succeeded; self.cancelled = cancelled
        super.init()
    }
}

/// One import of URLs into one database: wait for the downloads,
/// follow cancellation, decide by content where each payload goes, write it,
/// hand it to the database and compose the result.
///
/// The database is the one given at creation - the browser's at the moment the
/// import was asked for - so switching databases during the import does not
/// redirect its writes. The operation runs once, on the calling thread, which
/// must not be the main thread: it blocks until the downloads end. It is
/// cancelled through that thread's `cancel()`. What arrived before a
/// cancellation or a failure stays, and the result does not claim success.
///
/// A DICOM object goes straight into the database folder and is indexed, so
/// the caller gets a file that is really there. Anything else goes to the
/// import folder, where an archive is expanded and given its own verdict and
/// a file nothing can read is named and kept.
@objc(HorosURLImportOperation)
public final class URLImportOperation: NSObject {
    @objc(HorosURLImportOperationState)
    public enum State: Int { case ready, running, finished }

    @objc public let urls: [URL]
    private let database: DicomDatabase
    private let requestTimeout: TimeInterval, totalTimeout: TimeInterval
    private let lock = NSLock()
    private var stateValue: State = .ready

    /// `database` is the browser's; the operation imports into an independent
    /// context of it, made on the importing thread.
    @objc(initWithURLs:database:)
    public convenience init(urls: [URL], database: DicomDatabase) {
        self.init(urls: urls, database: database, requestTimeout: 15, totalTimeout: 60)
    }

    public init(urls: [URL], database: DicomDatabase, requestTimeout: TimeInterval, totalTimeout: TimeInterval) {
        self.urls = urls; self.database = database
        self.requestTimeout = requestTimeout; self.totalTimeout = totalTimeout
        super.init()
    }

    @objc public var state: State { lock.withLock { stateValue } }

    /// Runs the import on the calling thread and returns its result. A second
    /// call returns a failure without importing anything again.
    @objc public func run() -> URLImportResult {
        let first: Bool = lock.withLock {
            guard stateValue == .ready else { return false }
            stateValue = .running
            return true
        }
        guard first else {
            return URLImportResult(entries: [], report: "This import has already run.", succeeded: false, cancelled: false)
        }
        defer { lock.withLock { stateValue = .finished } }
        guard !Thread.isMainThread else {
            return URLImportResult(entries: [], report: "Use asynchronous URL import on the main thread.", succeeded: false, cancelled: false)
        }
        // A private-queue database; the indexing runs inside its queue.
        guard let independent = database.privateQueueIndependentDatabase() as? DicomDatabase else {
            return URLImportResult(entries: [], report: "The database cannot be opened for this import.", succeeded: false, cancelled: false)
        }
        return importURLs(into: independent)
    }

    private func importURLs(into database: DicomDatabase) -> URLImportResult {
        let report = URLImportReport()
        var entries = [Int: URLImportEntry]()
        let downloads = URLImportDownloads(urls: urls, requestTimeout: requestTimeout, totalTimeout: totalTimeout)
        let thread = Thread.current
        var cancelled = false

        while !downloads.finished {
            if thread.isCancelled && !cancelled {
                cancelled = true
                downloads.cancel()
            }
            guard let result = downloads.nextResult() else { continue }
            let url = result.url.absoluteString
            thread.status = result.url.host ?? NSLocalizedString("Importing URL", comment: "")
            guard let data = result.data, !data.isEmpty else {
                let reason = result.error?.localizedDescription ?? NSLocalizedString("nothing came back", comment: "")
                report.recordFailed(url: url, reason: reason)
                entries[result.index] = URLImportEntry(url: url, outcome: .failed, path: nil, reason: reason)
                continue
            }
            let fileExtension = URLImportReport.fileExtension(forPayload: data)
            let destination: String
            if fileExtension == "dcm" {
                destination = database.uniquePathForNewDataFile(withExtension: "dcm")
            } else {
                var name = "url-" + UUID().uuidString
                if !fileExtension.isEmpty { name = (name as NSString).appendingPathExtension(fileExtension) ?? name }
                destination = (database.incomingDirPath() as NSString).appendingPathComponent(name)
            }
            do {
                try data.write(to: URL(fileURLWithPath: destination), options: .atomic)
            } catch {
                let reason = (error as NSError).localizedDescription
                report.recordFailed(url: url, reason: reason)
                entries[result.index] = URLImportEntry(url: url, outcome: .failed, path: nil, reason: reason)
                continue
            }
            if fileExtension == "dcm" {
                database.performBlockAndWait { _ = database.addFiles(atPaths: [destination]) }
                report.recordIndexed(url: url)
                entries[result.index] = URLImportEntry(url: url, outcome: .indexed, path: destination, reason: nil)
            } else {
                database.initiateImportFilesFromIncomingDirUnlessAlreadyImporting()
                if fileExtension == "zip" {
                    report.recordExpanded(url: url)
                    entries[result.index] = URLImportEntry(url: url, outcome: .expanded, path: destination, reason: nil)
                } else {
                    let reason = String(format: NSLocalizedString("%d bytes that are neither a DICOM object nor an archive", comment: ""),
                                        Int32(truncatingIfNeeded: data.count))
                    report.recordRefused(url: url, reason: reason)
                    entries[result.index] = URLImportEntry(url: url, outcome: .refused, path: destination, reason: reason)
                }
            }
        }

        let ordered = entries.keys.sorted().compactMap { entries[$0] }
        let summary = report.summary
        NSLog("---- url import: %@", summary.replacingOccurrences(of: "\n", with: "; "))
        return URLImportResult(entries: ordered, report: summary,
                               succeeded: report.everythingArrived && !urls.isEmpty && !cancelled, cancelled: cancelled)
    }
}
