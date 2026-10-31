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
import Synchronization

/// One request of a DICOMweb retrieve: a study, a series or an instance.
public struct DICOMwebRetrieveRequest: Sendable {
    public var path: String
    /// The instance asked for, when it is one.
    public var uid: String?
    /// The series it is for, if one.
    public var series: String?
    /// Asked for in the fallback syntax alone.
    public var fallback = false
    public var attempts = 0
    /// The failure a request cut after some objects ended on.
    public var failure: DICOMwebRequestFailure?

    public init(path: String, uid: String? = nil, series: String? = nil, fallback: Bool = false) {
        self.path = path
        self.uid = uid
        self.series = series
        self.fallback = fallback
    }

    /// The WADO-RS resource of a study, of one of its series, or of an instance.
    public static func path(study: String, series: String? = nil, instance: String? = nil) -> String {
        var path = "studies/\(study)"
        if let series, !series.isEmpty { path += "/series/\(series)" }
        if let instance, series != nil { path += "/instances/\(instance)" }
        return path
    }
}

/// The requests of one DICOMweb retrieve and what it decides about them: the
/// order they start in, how one that failed recovers, and the objects
/// already taken. The threads that run the requests, and the node's slots
/// they hold, are the application's; any thread may call these.
///
/// A request that fails recovers as `DICOMwebRecovery` says: asked again,
/// resumed with what is still missing, or left missing while the others go
/// on; only a failure no request can get past (authentication, TLS, the
/// node's settings) stops the requests not yet sent.
public final class DICOMwebRetrieveQueue: Sendable {
    struct State {
        /// The first failure nothing made up for (it stops the requests not yet sent).
        var firstFailure: DICOMwebRequestFailure?
        /// A failure left missing while the others went on.
        var unresolved: DICOMwebRequestFailure?
        /// Study and series requests cut after some objects, with their
        /// failure, resumed once the listing has ended.
        var interrupted: [DICOMwebRetrieveRequest] = []
        /// The requests that ended without error.
        var completedPaths = Set<String>()
        var pending: [DICOMwebRetrieveRequest] = []
        var running = 0
        /// Every object this retrieve has queued for import, whichever
        /// request brought it.
        var taken = Set<String>()
        /// Set once a response in the node's own syntax was cut.
        var fallbackOnly = false
    }

    /// In the automatic mode, a busy or transient request that brought nothing
    /// is asked again once the node's wait is over, at most this many times.
    public static let adaptiveRepeats = 3

    /// The node's limit of requests at once.
    public let limit: Int
    /// The order the series of a study start in; nil keeps the order of queueing.
    private let orderedSeries: @Sendable () -> [String]?
    private let state = Mutex(State())

    public init(limit: Int, orderedSeries: @escaping @Sendable () -> [String]? = { nil }) {
        self.limit = limit
        self.orderedSeries = orderedSeries
    }

    // MARK: Requests

    /// Queues `request`. True when a worker is to start for it: fewer than
    /// `limit` are running; that worker now counts as running.
    @discardableResult
    public func enqueue(_ request: DICOMwebRetrieveRequest) -> Bool {
        state.withLock { state in
            state.pending.append(request)
            if state.running >= limit { return false }
            state.running += 1
            return true
        }
    }

    /// Queues a request for `path`, in the fallback syntax alone once a cut
    /// asked for it. True when a worker is to start for it.
    @discardableResult
    public func enqueue(path: String, uid: String? = nil, series: String? = nil) -> Bool {
        enqueue(DICOMwebRetrieveRequest(path: path, uid: uid, series: series, fallback: fallbackOnly))
    }

    /// Queues a request again, without starting a worker: one that is
    /// running takes it.
    public func requeue(_ request: DICOMwebRetrieveRequest) {
        state.withLock { $0.pending.append(request) }
    }

    /// The next request a worker runs: the first of the series order, a
    /// request for the whole study before any. Nil ends the worker - nothing
    /// is left, a failure stopped the retrieve, or it was `cancelled` - and
    /// then drops what is pending.
    public func next(cancelled: Bool) -> DICOMwebRetrieveRequest? {
        let ordered = orderedSeries()
        return state.withLock { state in
            guard !state.pending.isEmpty, state.firstFailure == nil, !cancelled else {
                state.pending.removeAll()
                state.running -= 1
                return nil
            }
            return state.pending.remove(at: Self.nextIndex(of: state.pending, orderedSeries: ordered))
        }
    }

    /// Which pending request starts first: the lowest rank, a request for
    /// the whole study (rank 0) before any series, a series by its place in
    /// `orderedSeries`, one not in it last; the first queued among equals.
    public static func nextIndex(of pending: [DICOMwebRetrieveRequest], orderedSeries: [String]?) -> Int {
        var index = 0, best = Int.max
        if pending.count > 1, let ordered = orderedSeries {
            for (position, request) in pending.enumerated() {
                let rank: Int
                if let seriesUID = request.series {
                    rank = ordered.firstIndex(of: seriesUID).map { $0 + 1 } ?? ordered.count + 1
                } else {
                    rank = 0
                }
                if rank < best { best = rank; index = position }
            }
        }
        return index
    }

    /// The request ended without error.
    public func complete(_ request: DICOMwebRetrieveRequest) {
        state.withLock { _ = $0.completedPaths.insert(request.path) }
    }

    /// Runs `request` through `client`, handing each object to `handler`;
    /// the failure it ended on, nil when it ended without one.
    public func perform(_ request: DICOMwebRetrieveRequest, with client: any DICOMwebRetrieving, stagingDirectory: String,
                        handler: @escaping (String) -> String?) -> DICOMwebRequestFailure? {
        do throws(DICOMwebRequestFailure) {
            _ = try client.retrieveObjects(path: request.path, stagingDirectory: stagingDirectory,
                                           fallbackOnly: request.fallback, handler: handler)
            return nil
        } catch {
            return error
        }
    }

    /// Whether, in the automatic mode, a request whose outcome was busy or
    /// transient is asked again as it was: only one that brought nothing,
    /// and at most `adaptiveRepeats` more times.
    public static func repeatsAdaptively(_ request: DICOMwebRetrieveRequest, failure: DICOMwebRequestFailure?,
                                         busyOrTransient: Bool) -> Bool {
        busyOrTransient && request.attempts < adaptiveRepeats && (failure?.objectsHandedOver ?? 0) == 0
    }

    /// What a request that failed leads to. An instance that arrived before
    /// its answer failed needs nothing more (nil); a study or series request
    /// that is left missing ends the retrieve, as asking for each of its
    /// instances would fail as it did.
    public func recovery(of request: DICOMwebRetrieveRequest, failure: DICOMwebRequestFailure) -> DICOMwebRecovery.Action? {
        var action = DICOMwebRecovery.action(for: failure, attempts: request.attempts + 1)
        if action == .resume, let uid = request.uid {
            if isTaken(uid) { return nil }
            action = .retry
        }
        if action == .skip && request.uid == nil { action = .stop }
        return action
    }

    /// Keeps what `action` asks of a failed request: queued again (retry), or
    /// kept to be resumed, or remembered as the failure that is left missing
    /// or that stops the retrieve.
    public func apply(_ action: DICOMwebRecovery.Action, to request: DICOMwebRetrieveRequest, failure: DICOMwebRequestFailure) {
        var again = request
        again.attempts += 1
        state.withLock { state in
            switch action {
            case .retry:
                state.pending.append(again)
            case .resume:
                again.failure = failure
                state.interrupted.append(again)
            case .skip:
                if state.unresolved == nil { state.unresolved = failure }
            case .stop:
                if state.firstFailure == nil { state.firstFailure = failure }
            }
        }
    }

    /// The study and series requests cut after some objects since the last
    /// call, their failure cleared, to be queued again.
    public func takeInterrupted() -> [DICOMwebRetrieveRequest] {
        state.withLock { state in
            defer { state.interrupted.removeAll() }
            return state.interrupted.map { var request = $0; request.failure = nil; return request }
        }
    }

    /// The failure the first request cut after some objects ended on.
    public var firstCut: DICOMwebRequestFailure? { state.withLock { $0.interrupted.first?.failure } }

    // MARK: State

    /// A failure stopped the retrieve.
    public var failed: Bool { state.withLock { $0.firstFailure != nil } }
    /// The failure that stopped it, else the first one left missing.
    public var failure: DICOMwebRequestFailure? { state.withLock { $0.firstFailure ?? $0.unresolved } }
    public var hasUnresolvedFailure: Bool { state.withLock { $0.unresolved != nil } }
    public var running: Int { state.withLock { $0.running } }
    public var completedPaths: Set<String> { state.withLock { $0.completedPaths } }

    /// Ask in the fallback syntax alone from now on.
    public var fallbackOnly: Bool { state.withLock { $0.fallbackOnly } }
    public func useFallbackOnly() { state.withLock { $0.fallbackOnly = true } }

    // MARK: Objects

    /// Whether an object was already queued for import by this retrieve.
    public func isTaken(_ uid: String) -> Bool { state.withLock { $0.taken.contains(uid) } }
    public func take(_ uid: String) { state.withLock { _ = $0.taken.insert(uid) } }

    /// Whether an object belongs to `request` of the retrieve of `study`
    /// (`series`: empty for a whole study): its identifiers are all there,
    /// they are the ones asked for, an instance asked for is it or is named
    /// by its Source Image Sequence (`sources`), and the request did not
    /// bring it already (`seen`).
    public static func belongs(study: String, series: String, request: DICOMwebRetrieveRequest,
                               actualStudy: String?, actualSeries: String?, objectUID: String?,
                               sources: [String], seen: Set<String>) -> Bool {
        guard let actualStudy, let actualSeries, let objectUID else { return false }
        return actualStudy == study && (series.isEmpty || actualSeries == series)
            && (request.series == nil || actualSeries == request.series) && !objectUID.isEmpty
            && (request.uid == nil || request.uid == objectUID || sources.contains(request.uid ?? ""))
            && !seen.contains(objectUID)
    }
}
