/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, ?version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ?See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ?If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: ? OsiriX
 ?Copyright (c) OsiriX Team
 ?All rights reserved.
 ?Distributed under GNU - LGPL
 ?
 ?See http://www.osirix-viewer.com/copyright.html for details.
 ? ? This software is distributed WITHOUT ANY WARRANTY; without even
 ? ? the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 ? ? PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation

/// Counts the studies of a database and of its albums, for the albums table.
///
/// Declared here so that the scheduler, which decides when a count runs,
/// does not reach the app; the app's adapter reads the database on a
/// private-queue context, on a thread the Activity window lists.
public protocol AlbumStudyCounting: Sendable {
    /// The number of studies of the database, then of each of its albums in
    /// the order of the albums table, read when the count starts; nil for a
    /// count that failed. `progress` receives the counts so far while it runs.
    /// Answers nil when the database shown changed meanwhile: the counts no
    /// longer belong to it.
    func countStudies(progress: @escaping @Sendable ([Int?]) -> Void) async -> [Int?]?
}

/// What a request for a count did.
public enum AlbumCountRequest: Sendable, Equatable {
    /// A count started.
    case started
    /// A count runs already: the request is asked again later.
    case deferred
}

/// When the studies of the albums are counted: one count at a time. A
/// request while a count runs asks again a while later, and a later such
/// request replaces it, so that the requests of an import that arrive
/// together end in one more count. A count interrupted because the database
/// shown changed asks again later too.
public actor AlbumCountScheduler<Counter: AlbumStudyCounting> {

    /// How long after a deferred request it is asked again.
    public nonisolated let retryDelay: Duration
    private let sleep: @Sendable (Duration) async throws -> Void

    private var counting: Task<Void, Never>?
    private var retry: Task<Void, Never>?

    public init(retryDelay: Duration = .seconds(20),
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.retryDelay = retryDelay
        self.sleep = sleep
    }

    /// Whether a count runs.
    public var isCounting: Bool { counting != nil }

    /// Whether a deferred request waits to be asked again.
    public var hasPendingRetry: Bool { retry != nil }

    /// Asks for the counts. With no count running, `counter` counts and
    /// `deliver` receives the counts, or nil when the database changed
    /// meanwhile; otherwise `again`, which asks again with what is then
    /// current, runs after the delay.
    @discardableResult
    public func request(_ counter: Counter,
                        progress: @escaping @Sendable ([Int?]) -> Void,
                        deliver: @escaping @Sendable ([Int?]?) async -> Void,
                        again: @escaping @Sendable () async -> Void) -> AlbumCountRequest {
        guard counting == nil else {
            askLater(again)
            return .deferred
        }
        counting = Task {
            let counts = await counter.countStudies(progress: progress)
            await deliver(counts)
            self.finished(interrupted: counts == nil, again: again)
        }
        return .started
    }

    /// Waits for the count that runs, if any.
    public func waitForCount() async {
        await counting?.value
    }

    /// Cancels the count that runs and the request waiting to be asked again.
    public func cancel() {
        counting?.cancel()
        retry?.cancel()
        retry = nil
    }

    private func finished(interrupted: Bool, again: @escaping @Sendable () async -> Void) {
        counting = nil
        if interrupted { askLater(again) }
    }

    /// Asks `again` after the delay, replacing a request that waits.
    private func askLater(_ again: @escaping @Sendable () async -> Void) {
        retry?.cancel()
        let sleep = self.sleep, delay = retryDelay
        retry = Task {
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled else { return }
            self.retryStarted()
            await again()
        }
    }

    private func retryStarted() {
        retry = nil
    }
}
