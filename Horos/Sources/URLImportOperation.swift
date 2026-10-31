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
import IsiXContracts

/// What became of one URL of an import.
@objc(HorosURLImportEntry)
public final class URLImportEntry: NSObject {
    @objc(HorosURLImportOutcome)
    public enum Outcome: Int {
        /// A DICOM object, published to the import folder and found in the
        /// database once the import that took it ended.
        case indexed
        /// An archive, handed to the import folder to be expanded there.
        case expanded
        /// Downloaded, and neither a DICOM object nor an archive: handed to the
        /// import folder, which names and keeps a file it cannot read.
        case refused
        /// Not downloaded, or not written: nothing of it is in the database.
        case failed
        /// A DICOM object in the import folder's hands and not in the database
        /// yet: the import stopped before it, or it went to be converted.
        case queued
    }

    @objc public let url: String
    @objc public let outcome: Outcome
    /// Where its bytes are, or nil: the file of the image for an indexed object,
    /// where the import kept a refused one, if it kept it, and the import folder
    /// otherwise.
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
/// Everything that arrives is published to the import folder. A DICOM object
/// is imported on the calling thread, once, so that the caller gets the answer:
/// what is in the database with the file that is really there, or what the
/// import refused, which is not counted as added. Anything else goes to the
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
    ///
    /// The reports of a second call and of a call on the main thread stay in
    /// English: the app makes a new operation for every import and runs it on a
    /// thread of its own, so only code that misuses the class reads them. A
    /// database that cannot be opened happens at run time, and its report
    /// reaches the URL Error alert and the AppleScript answer, so it follows the
    /// language of the interface.
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
            let report = NSLocalizedString("The database cannot be opened for this import.",
                                           comment: "URL import report: the database could not give the import a context of its own")
            return URLImportResult(entries: [], report: report, succeeded: false, cancelled: false)
        }
        return importURLs(into: independent)
    }

    private func importURLs(into database: DicomDatabase) -> URLImportResult {
        let ingest = DatabaseIngest.process
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
            var name = "url-" + UUID().uuidString
            if !fileExtension.isEmpty { name = (name as NSString).appendingPathExtension(fileExtension) ?? name }
            let draft = IngestDraft(folder: ingest.admissionFolder(of: database), name: name)
            do {
                try data.write(to: URL(fileURLWithPath: draft.path), options: .atomic)
            } catch {
                let reason = (error as NSError).localizedDescription
                report.recordFailed(url: url, reason: reason)
                entries[result.index] = URLImportEntry(url: url, outcome: .failed, path: nil, reason: reason)
                continue
            }
            if fileExtension == "dcm" {
                entries[result.index] = imported(ingest.publishAndImport(draft, preset: .url, in: database), url: url, report: report)
                continue
            }
            let publication = ingest.publish(draft, preset: .url)
            guard publication.succeeded else {
                ingest.discard(draft)
                entries[result.index] = notPublished(publication.errorNumber, url: url, report: report)
                continue
            }
            ingest.requestImport(of: database)
            let destination = draft.folder.path(named: name)
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

        let ordered = entries.keys.sorted().compactMap { entries[$0] }
        let summary = report.summary
        NSLog("---- url import: %@", summary.replacingOccurrences(of: "\n", with: "; "))
        return URLImportResult(entries: ordered, report: summary,
                               succeeded: report.everythingArrived && !urls.isEmpty && !cancelled, cancelled: cancelled)
    }

    /// The entry of a DICOM object after its import: only what the database
    /// took is recorded as added.
    private func imported(_ verdict: DatabaseIngest.Verdict, url: String, report: URLImportReport) -> URLImportEntry {
        switch verdict {
        case .indexed(let path):
            report.recordIndexed(url: url)
            return URLImportEntry(url: url, outcome: .indexed, path: path, reason: nil)
        case .refused(let name, let path):
            let reason = String(format: NSLocalizedString("%@ is not a DICOM file this database can index", comment: ""), name)
            report.recordRefused(url: url, reason: reason)
            return URLImportEntry(url: url, outcome: .refused, path: path, reason: reason)
        case .queued(let path):
            report.recordExpanded(url: url)
            return URLImportEntry(url: url, outcome: .queued, path: path, reason: nil)
        case .notPublished(let errorNumber):
            return notPublished(errorNumber, url: url, report: report)
        }
    }

    private func notPublished(_ errorNumber: Int32, url: String, report: URLImportReport) -> URLImportEntry {
        let reason = String(cString: strerror(errorNumber))
        report.recordFailed(url: url, reason: reason)
        return URLImportEntry(url: url, outcome: .failed, path: nil, reason: reason)
    }
}
