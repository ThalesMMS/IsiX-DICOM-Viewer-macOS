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

/// Files queued for one rule's destination.
public struct RoutingOrder: Sendable, Hashable {
    public var files: [RoutedFile]
    /// The `Description` of the node they go to; nil when the rule names none.
    public var destinationName: String?
    /// The rule that queued them; nil when it names no destination.
    public var rule: RoutingRule?
    /// How many more times a batch that fails is tried again.
    public var failureRetry: Int32
    /// Which of the app's databases the files are in; opaque here.
    public var database: String

    public init(files: [RoutedFile], destinationName: String?, rule: RoutingRule?, failureRetry: Int32, database: String) {
        self.files = files
        self.destinationName = destinationName
        self.rule = rule
        self.failureRetry = failureRetry
        self.database = database
    }
}

/// Why the files of a send did not all arrive.
public struct RoutingSendFailure: Sendable, Hashable {
    public var name: String
    public var reason: String

    public init(name: String, reason: String) {
        self.name = name
        self.reason = reason
    }
}

/// How a routed send went.
public enum RoutingSendResult: Sendable, Hashable {
    case sent
    case failed(RoutingSendFailure)
    /// Stopped from the activity that showed it.
    case cancelled
}

/// What the routing queue needs of the app to send what it holds. Declared
/// here so that the queue does not reach the app; the app implements it over
/// its databases, the send queue and its alerts. A stand-in records.
public protocol RoutingDelivery: Sendable {
    /// The DIMSE nodes of Locations, as stored now.
    func nodes() async -> [DICOMNode]
    /// The files of `order` that are still in its database, read again now,
    /// in their order.
    func currentFiles(of order: RoutingOrder) async -> [RoutedFile]
    /// Whether there is a file at `path`.
    func fileExists(atPath path: String) -> Bool
    /// The settings a routed send is made with: the AE title of this end and
    /// the sends allowed at once in the process.
    func sendOptions() async -> DICOMSendOptions
    /// Sends one patient's files, through the process's send queue.
    func send(_ request: DICOMSendRequest) async -> RoutingSendResult
    /// Tells the user that a rule cannot say where its studies go; asked
    /// once per rule and problem.
    func reportUnresolvedDestination(_ problem: String) async
    /// Tells the user that a send to `node` failed; asked once per
    /// destination and problem, until it answers again.
    func reportFailedSend(_ failure: RoutingSendFailure, to node: DICOMNode) async
}

/// The autorouting queue of the process: the files the rules chose, waiting
/// for their destination, and the batches that failed, waiting to be tried
/// again.
///
/// The files are queued as the rules choose them, merged into the files
/// already queued for the same rule. A drain, which the app starts every ten
/// seconds, takes everything queued, resolves each destination, and sends the
/// files of each patient in turn through the process's send queue; a batch
/// that fails goes back in the queue for the next drain while its rule allows
/// more tries. One drain runs at a time.
public actor RoutingQueue {
    private var orders: [RoutingOrder] = []
    private var gate = RoutingProblemGate()
    private var draining = false
    private let retryPause: Duration

    /// `retryPause` is how long a drain waits after a failed batch.
    public init(retryPause: Duration = .seconds(4)) {
        self.retryPause = retryPause
    }

    /// What is queued, in order.
    public var queued: [RoutingOrder] {
        orders
    }

    /// Whether a drain is running.
    public var isDraining: Bool {
        draining
    }

    /// The problems that keep rules and destinations quiet.
    public var problems: RoutingProblemGate {
        gate
    }

    /// Queues what the rules chose, in their order.
    public func add(_ picks: [RoutingSelection.Pick], database: String) {
        for pick in picks {
            add(pick.files, for: pick.rule, database: database)
        }
    }

    /// Queues `files` for `rule`. When files are already queued for the same
    /// rule, those of `files` already among them are left out and the rest
    /// join them; otherwise they make a new order.
    public func add(_ files: [RoutedFile], for rule: RoutingRule, database: String) {
        var remaining = files
        if let index = orders.firstIndex(where: { $0.rule == rule }) {
            var queuedPaths = Set<[UInt16]>()
            for file in orders[index].files {
                if let path = file.path { queuedPaths.insert(Array(path.utf16)) }
            }
            remaining = files.filter { file in
                guard let path = file.path else { return true }
                return !queuedPaths.contains(Array(path.utf16))
            }
            orders[index].files += remaining
            if remaining.count < files.count {
                NSLog(" Autorouting rule \"%@\": %d image(s) already queued for it, not queued again",
                      rule.loggedName, Int32(truncatingIfNeeded: files.count - remaining.count))
            }
            return
        }

        if !remaining.isEmpty {
            let destination = rule.destinationName
            orders.append(RoutingOrder(files: remaining, destinationName: destination,
                                       rule: destination == nil ? nil : rule,
                                       failureRetry: destination == nil ? 0 : rule.failureRetry,
                                       database: database))
        }
    }

    /// Sends everything queued, unless a drain is already running; returns
    /// whether this call drained.
    @discardableResult
    public func drain(through delivery: some RoutingDelivery) async -> Bool {
        guard !draining else { return false }
        draining = true
        defer { draining = false }

        let taken = orders
        orders.removeAll()
        guard !taken.isEmpty else { return true }

        let nodes = await delivery.nodes()
        var total = 0
        for order in taken where destination(of: order, in: nodes).isResolved {
            total += order.files.count
        }

        NSLog("______________________________________________")
        NSLog(" Autorouting Queue START: %@, %@", Self.count(taken.count, "list", "lists"), Self.count(total, "item", "items"))
        for order in taken {
            NSLog("   list: rule \"%@\" -> %@, %d item(s)", order.rule?.loggedName ?? "(null)",
                  order.destinationName ?? "(null)", Int32(truncatingIfNeeded: order.files.count))
        }

        orders: for order in taken {
            let files = await delivery.currentFiles(of: order)
            // A row that has gone from the database between queueing and
            // sending: sending fewer images than were queued, unsaid, is how
            // "only part of the study reached the PACS" looks.
            if files.count != order.files.count {
                NSLog(" Autorouting: %d of %d queued image(s) are no longer in the database",
                      Int32(truncatingIfNeeded: order.files.count - files.count), Int32(truncatingIfNeeded: order.files.count))
            }

            let ruleName = order.rule?.name
            let resolved = destination(of: order, in: nodes)
            guard let node = resolved.node else {
                // Said once: the same question comes back on every import
                // until the nodes are fixed.
                if gate.suspend(rule: ruleName, because: resolved.problem ?? "") {
                    await delivery.reportUnresolvedDestination(resolved.problem ?? "")
                }
                NSLog(" Autorouting destination unresolved: %@", resolved.problem ?? "(null)")
                continue
            }
            NSLog(" Autorouting destination: %@ - %@", node[DICOMNode.Key.description]?.text ?? "(null)",
                  node[DICOMNode.Key.address]?.text ?? "(null)")
            gate.resume(rule: ruleName)

            let (batches, missing) = Self.batches(of: files, fileExists: delivery.fileExists(atPath:))
            for batch in batches {
                if await send(batch, to: node, for: order, through: delivery) == .cancelled {
                    NSLog(" Autorouting: stopped from its activity")
                    break orders
                }
            }
            if missing != 0 {
                NSLog(" Autorouting: %d of %d image(s) were not sent because their files are not there",
                      Int32(truncatingIfNeeded: missing), Int32(truncatingIfNeeded: files.count))
            }
        }

        NSLog("______________________________________________")
        return true
    }

    private func destination(of order: RoutingOrder, in nodes: [DICOMNode]) -> RoutingDestination {
        RoutingDestination.resolve(named: order.destinationName, in: nodes, ruleName: order.rule?.name)
    }

    /// The files of each patient, in the order of their Patient ID (a
    /// `-compare:` of the texts, those without one first, keeping their order
    /// otherwise), consecutive files of the same Patient ID in one batch; a
    /// file without a Patient ID makes a batch of its own. A file that is not
    /// on disk is left out and counted; the first ten are logged.
    static func batches(of files: [RoutedFile], fileExists: (String) -> Bool) -> (batches: [[RoutedFile]], missing: Int) {
        let sorted = files.enumerated().sorted { left, right in
            switch comparePatientIDs(left.element.study.patientID, right.element.study.patientID) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return left.offset < right.offset
            }
        }.map(\.element)

        var batches: [[RoutedFile]] = []
        var current: [RoutedFile] = []
        var previousPatientID: String?
        var missing = 0
        for file in sorted {
            guard let path = file.path, fileExists(path) else {
                missing += 1
                if missing <= 10 {
                    NSLog(" Autorouting: not sending %@ - the file is not there", file.path ?? "(null)")
                }
                continue
            }
            if let previous = previousPatientID, let patientID = file.study.patientID,
               (previous as NSString).isEqual(to: patientID) {
                current.append(file)
            } else {
                if !current.isEmpty { batches.append(current) }
                current = [file]
                previousPatientID = file.study.patientID
            }
        }
        if !current.isEmpty { batches.append(current) }
        return (batches, missing)
    }

    private static func comparePatientIDs(_ left: String?, _ right: String?) -> ComparisonResult {
        switch (left, right) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedAscending
        case (_, nil): return .orderedDescending
        case let (left?, right?): return (left as NSString).compare(right)
        }
    }

    /// Sends one batch; a failure is reported once per destination and
    /// problem, and the batch queued again while its rule allows more tries.
    private func send(_ batch: [RoutedFile], to node: DICOMNode, for order: RoutingOrder,
                      through delivery: some RoutingDelivery) async -> RoutingSendResult {
        guard let first = batch.first else { return .sent }
        NSLog(" Autorouting: %@ - %@", first.study.studyName ?? "(null)", Self.count(batch.count, "object", "objects"))

        let request = DICOMSendRequest(destination: node,
                                       batches: [DICOMSendRequest.Batch(patientName: first.study.patientName,
                                                                        files: batch.compactMap(\.path))],
                                       transferSyntax: Int(RoutingRule.intValue(node[DICOMNode.Key.transferSyntax])),
                                       compression: 1, route: .cStore, options: await delivery.sendOptions())
        let destination = "\(node[DICOMNode.Key.aeTitle]?.text ?? "(null)")@\(node[DICOMNode.Key.address]?.text ?? "(null)"):"
            + (node[DICOMNode.Key.port]?.text ?? "(null)")

        let result = await delivery.send(request)
        switch result {
        case .sent:
            gate.clearProblems(forDestination: destination)
        case .cancelled:
            break
        case .failed(let failure):
            NSLog("Autorouting FAILED : %@ - %@", failure.reason, batch.compactMap(\.path).joined(separator: ", "))
            // A destination that is down fails every batch; the first failure
            // is shown, the repeats are in the log above.
            if gate.shouldReport(problem: failure.reason, forDestination: destination) {
                await delivery.reportFailedSend(failure, to: node)
            }
            try? await Task.sleep(for: retryPause)

            if order.failureRetry > 0 {
                NSLog("Autorouting for %@ : failure count: %d", first.study.patientName ?? "(null)", order.failureRetry)
                orders.append(RoutingOrder(files: batch, destinationName: node[DICOMNode.Key.description]?.stringValue,
                                           rule: order.rule, failureRetry: order.rule == nil ? 0 : order.failureRetry &- 1,
                                           database: order.database))
            }
        }
        return result
    }

    /// N2SingularPluralCount.
    static func count(_ count: Int, _ singular: String, _ plural: String) -> String {
        "\(Int32(truncatingIfNeeded: count)) \(count == 1 ? singular : plural)"
    }
}
