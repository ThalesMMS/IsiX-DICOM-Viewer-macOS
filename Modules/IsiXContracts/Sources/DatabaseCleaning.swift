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

/// One line of the preview of the automatic cleanup: a study it would delete.
public struct CleanupPreviewRow: Hashable, Sendable {
    /// The rule that takes the study, as the window shows it.
    public let rule: String
    public let patient: String
    public let study: String
    public let studyInstanceUID: String
    public let date: Date?

    public init(rule: String, patient: String, study: String, studyInstanceUID: String, date: Date?) {
        self.rule = rule
        self.patient = patient
        self.study = study
        self.studyInstanceUID = studyInstanceUID
        self.date = date
    }
}

/// What the automatic cleanup would do now, read once. Nothing was changed.
public struct CleanupPreview: Hashable, Sendable {
    /// The rules in force and what they found, as the window shows it.
    public let summary: String
    /// The studies it would delete, in order, rule by rule.
    public let rows: [CleanupPreviewRow]
    /// The preview could not be read, and `summary` says so.
    public let failed: Bool

    public init(summary: String, rows: [CleanupPreviewRow], failed: Bool) {
        self.summary = summary
        self.rows = rows
        self.failed = failed
    }
}

/// The automatic cleanup of a local database, by date and by free space.
///
/// A port over the database: the app implements it over its Core Data objects,
/// and a remote database cleans nothing through it.
public protocol DatabaseCleaning: Sendable {
    /// What names the database. A database and its independent databases share it.
    var cleaningIdentifier: String { get }

    /// Whether nothing is cleaning this database at this moment. Never waits.
    func isIdleForCleaning() -> Bool

    /// One pass: the date rule, then the space rule, on a thread of its own.
    /// Returns when the pass has ended.
    func runCleanupPass() async

    /// What a pass would delete now, read on a thread of its own.
    func previewCleanup() async -> CleanupPreview

    /// The space rule, on the calling thread: it returns when the rule has
    /// ended, having read the free space again after each deletion, so that
    /// an import can go on with what is free then. It never waits for anything
    /// but the database's own cleaning lock.
    func cleanForFreeSpace()
}
