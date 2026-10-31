//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit
import IsiXDICOMNetwork
import Synchronization

/// The autorouting of the local databases.
///
/// The rules (`RoutingRule`), the choice of what each sends
/// (`RoutingSelection`), their schedule and the queue (`RoutingQueue`, an
/// actor the process graph holds) are IsiXDICOMNetwork's. This type hands the
/// module what it decides on: the images of an import read into values on
/// the thread of their database (`DatabaseRoutingCatalog`), the rules of the
/// preferences, and, every ten seconds, a drain of the queue through
/// `DatabaseRoutingDelivery`, which sends through the process's send queue.
final class DatabaseRouting: Sendable {

    /// The routing of this process.
    static let process = DatabaseRouting(processGraph: ProcessGraph.process)

    private let processGraph: ProcessGraph
    /// Whether the timer of the drains was made: databases open on several
    /// threads, and each asks for it.
    private let drainsStarted = Atomic<Bool>(false)

    init(processGraph: ProcessGraph) {
        self.processGraph = processGraph
    }

    /// Drains the queue every ten seconds from now on; the first call makes
    /// the timer, kept by the main run loop and never invalidated.
    func startDrains() {
        guard drainsStarted.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged else {
            return
        }
        let timer = Timer(timeInterval: 10, repeats: true) { [self] _ in
            drain()
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        RunLoop.main.add(timer, forMode: .default)
    }

    /// Sends what is queued, unless a drain is running already.
    @discardableResult
    func drain() -> Task<Bool, Never> {
        let queue = processGraph.routingQueue
        let delivery = DatabaseRoutingDelivery(processGraph: processGraph)
        return Task { await queue.drain(through: delivery) }
    }

    /// Applies the rules to images of `database`, on its thread: those given
    /// (the database window's menu, a plugin), or else those of the
    /// preferences. A rule with a schedule is applied by itself when its time
    /// comes; the others now, together.
    func apply(_ propertyLists: [Any]?, to images: [DicomImage], in database: DicomDatabase) {
        let rules = RoutingRule.rules(fromPropertyList: propertyLists
                                        ?? processGraph.preferences.array(forKey: RoutingRule.preferenceKey))

        for rule in RoutingSchedule.scheduledRules(in: rules) {
            let delay = RoutingSchedule.delay(for: rule, at: Date())
            if delay.windowIsUnreadable {
                NSLog(" Autorouting rule \"%@\": its time window (%@ - %@) cannot be read; applied now",
                      rule.name ?? "(null)", rule.fromTime?.text ?? "(null)", rule.toTime?.text ?? "(null)")
            }
            schedule(rule, for: images, after: delay.seconds)
        }

        let immediate = RoutingSchedule.immediateRules(in: rules)
        if !immediate.isEmpty {
            applyNow(immediate, to: images, in: database)
        }
    }

    /// Queues images of `database` for one rule, as it is given, without
    /// applying its filter: the selectors plugins call.
    func queue(_ images: [DicomImage], for propertyList: Any?, in database: DicomDatabase) {
        guard let rule = propertyList.flatMap(RoutingRule.init(propertyList:)),
              let key = DatabaseRoutingDelivery.key(of: database) else { return }
        var files: [RoutedFile] = []
        if let exception = HorosObjCException.caught({ files = DatabaseRoutingCatalog(database: database).snapshots(of: images) }) {
            DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase(Routing) addImages:toSendQueueForRoutingRule:]")
            return
        }
        let queue = processGraph.routingQueue
        Task { await queue.add(files, for: rule, database: key) }
    }

    /// Applies `rules` now and queues what they chose.
    private func applyNow(_ rules: [RoutingRule], to images: [DicomImage], in database: DicomDatabase) {
        let catalog = DatabaseRoutingCatalog(database: database)
        var files: [RoutedFile] = []
        if let exception = HorosObjCException.caught({ files = catalog.snapshots(of: images) }) {
            DicomDatabaseObjC.log(exception, stack: true, "-[DicomDatabase(Routing) __applyRoutingRules:toImages:]")
            return
        }
        let picks = RoutingSelection.apply(rules, to: files, nodes: DICOMNodeService.store.dicomNodes(),
                                           databasePath: database.dataBaseDirPath ?? "", catalog: catalog)
        guard !picks.isEmpty else { return }
        guard let key = DatabaseRoutingDelivery.key(of: database) else {
            NSLog(" Autorouting: the images are not in a local database; nothing queued")
            return
        }
        let queue = processGraph.routingQueue
        Task { await queue.add(picks, database: key) }
    }

    /// Applies a rule with a schedule when its time comes. The images are
    /// objects of the context that imported them, which is gone or busy by
    /// then: their IDs are kept, and the rule is applied to them on a
    /// private-queue context of the active local database, on its queue.
    private func schedule(_ rule: RoutingRule, for images: [DicomImage], after seconds: Int64) {
        let imageIDs = images.map { $0.objectID.uriRepresentation().absoluteString }
        let deadline = DispatchTime.now() + .nanoseconds(Int(seconds &* Int64(bitPattern: NSEC_PER_SEC)))
        DispatchQueue.main.asyncAfter(deadline: deadline) { [self] in
            guard let database = DicomDatabase.activeLocal()?.privateQueueIndependentDatabase() as? DicomDatabase else { return }
            database.performBlockAndWait {
                let images = (database.objects(withIDs: imageIDs) ?? []).compactMap { $0 as? DicomImage }
                self.applyNow([rule], to: images, in: database)
            }
        }
    }
}
