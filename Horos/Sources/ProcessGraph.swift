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
import IsiXDatabase
import IsiXDICOMNetwork
import IsiXImaging
import IsiXPreferences
import Synchronization

/// The dependencies that the whole process shares, handed to the types that
/// use them instead of being fetched through global access.
///
/// The composition root of the application, one per process. For now it only
/// hands out what the singletons hand out today, and reads them when asked,
/// never at launch: a type that receives the graph sees exactly what the global
/// access it replaces would have returned at that moment.
///
/// A type receives the graph from whoever makes it:
/// - through its initializer, when it is made in code;
/// - through its `processGraph` property, set right after it is made, when a
///   nib loads its window or makes it.
/// The factories that make those types are the only places that read
/// `ProcessGraph.process`; everything below them uses the graph it was given.
///
/// Isolation is stated, not inferred. The browser, its window's graph, the
/// application controller, the arrangement of the viewers' windows and the
/// application's menus are main-actor objects, so the graph hands them out on
/// the main actor only. The default and the active local database, which
/// serialize their own creation, the preferences, which are thread-safe, the
/// browser's network-log switch and database, which the browser keeps for any
/// thread, the notifications and the DICOM listener's state are read from any
/// thread: code off the main thread reaches the browser's database only through
/// `browserDatabase`. The graph has no mutable state of its own but the members
/// it makes on first use, kept under a mutex, so it is Sendable and can be
/// passed anywhere; the things it makes itself, the send queue, the routing
/// queue and the scheduler of the incoming files and the conversion queue, are
/// actors.
nonisolated final class ProcessGraph: Sendable {

    /// The graph of this process: made once, on first use, from any thread.
    static let process = ProcessGraph()

    /// Only `process` makes a graph.
    private init() {}

    /// The database window, made once at launch; nil before it exists.
    @MainActor var currentBrowser: BrowserController? {
        browser
    }

    /// Whether the network log records anything: the browser's switch, which
    /// any thread may read; off before the browser exists.
    var networkLogsActive: Bool {
        browser?.isNetworkLogsActive() ?? false
    }

    /// The database the browser shows, which the browser keeps for any
    /// thread; nil before the browser exists and while a rebuild has none.
    var browserDatabase: DicomDatabase? {
        browser?.database
    }

    /// The application's delegate; nil before the application has made it.
    @MainActor var appController: AppController? {
        sharedAppController
    }

    /// The publisher of the shared database, which the application controller
    /// makes at launch and keeps under a lock; nil before. Any thread.
    var bonjourPublisher: BonjourPublisher? {
        sharedAppController?.bonjourPublisher
    }

    /// Whether the user's session is switched away: the DICOM listener's
    /// flag, which any thread may read.
    var isSessionInactive: Bool {
        dicomListener.isSessionInactive
    }

    /// The graph of the database window, which the application controller
    /// makes from its nib's browser; nil before.
    @MainActor var browserWindow: BrowserWindowGraph? {
        sharedAppController?.browserWindow
    }

    /// The DICOM listeners, their Bonjour advertisement and the session
    /// switch, made on first use. Their state, whether a listener receives and
    /// whether the session is switched away, is read from any thread; their
    /// life cycle runs on the main actor.
    var dicomListener: DICOMListenerController {
        madeDICOMListener { DICOMListenerController(processGraph: self) }
    }

    /// The notifications to the Notification Center. Any thread.
    let userNotifications = UserNotificationDelivery()

    /// The arrangement of the viewers' windows and their tiling, made on
    /// first use.
    @MainActor var windowArranger: ViewerWindowArranger {
        madeWindowArranger { ViewerWindowArranger(processGraph: self) }
    }

    /// The menus the application fills in, Recent Studies among them, made on
    /// first use. The Recent Studies menu is the application controller's
    /// outlet, read when needed: the nib sets it after the controller is made.
    @MainActor var applicationMenus: ApplicationMenus {
        madeApplicationMenus {
            ApplicationMenus(recentStudiesMenu: { [self] in appController?.recentStudiesMenu }, processGraph: self)
        }
    }

    private let madeDICOMListener = MadeOnFirstUse<DICOMListenerController>()
    private let madeWindowArranger = MadeOnFirstUse<ViewerWindowArranger>()
    private let madeApplicationMenus = MadeOnFirstUse<ApplicationMenus>()

    /// Whether a viewer is loading a series, which a viewer changes on the main actor.
    @MainActor var viewersAreLoading: Bool {
        ViewerController.areLoadingViewers()
    }

    /// Shows on the Dock that files are arriving, or stops showing it: the
    /// calling thread starts or ends a reception of the application
    /// controller's `ReceivingIndicator`. Any thread.
    func showReceiving(_ receiving: Bool) {
        sharedAppController?.receivingIndicator.showReceiving(receiving)
    }

    /// Queues a file for deletion in the browser's delete queue, which any
    /// thread reaches; nothing for nil and before the browser exists. Any thread.
    func queueForDeletion(_ file: String?) {
        guard let file else { return }
        browser?.addFile(toDeleteQueue: file)
    }

    /// The one read of the application controller's singleton. A main-actor
    /// object: only its members that answer from any thread are reached
    /// outside the main actor.
    private var sharedAppController: AppController? {
        AppController.shared()
    }

    /// The database in the default data folder, made on first use; nil while
    /// the first-use choice of a data folder is still pending.
    var defaultDatabase: DicomDatabase? {
        DicomDatabase.default()
    }

    /// The local database a retrieve or an import fills: the one the browser
    /// shows when it is local, the default one otherwise. Any thread.
    var activeLocalDatabase: DicomDatabase? {
        DicomDatabase.activeLocal()
    }

    /// The application's preferences.
    var preferences: UserDefaults {
        UserDefaults.standard
    }

    /// The DICOM sends of the process, which share its send slots. Any thread.
    let dicomSendQueue = DICOMSendQueue()

    /// The autorouting queue of the process: what the rules chose, waiting
    /// for its destination. Any thread.
    let routingQueue = RoutingQueue()

    /// When the queue of incoming files is imported. Any thread.
    let ingestScheduler = IngestScheduler()

    /// The files of the databases waiting to be converted. Any thread.
    let conversionQueue = ConversionQueue()

    /// The PACS On-Demand searches of the browser, and the nodes they ask,
    /// which the web portal asks too. Any thread.
    let pacsOnDemand = PACSOnDemandSearch(nodes: QueryControllerDistantStudies(preferences: .standard), preferences: .standard)

    /// The register of the 2D viewers. Any thread.
    let viewerRegistry = ViewerRegistry()

    /// The presets menus the 2D viewers' popups copy, one of each for the
    /// process. Made here from any thread, used on the main actor.
    let presetMenuCache = PresetMenuCache()

    /// The colour table the 2D viewers applied last, by its stored value. Made
    /// here from any thread, used on the main actor.
    let colourTableCache = ColourTableCache()

    /// The synchronization the 2D viewers share: the series lock, what the
    /// Sync button does and the viewer an image is dragged from. Made here
    /// from any thread, used on the main actor.
    let viewerSync = ViewerSyncState()

    /// The reslices of the 2D viewers, one at a time, each on every
    /// processor. Any thread.
    let seriesResliceWorker = SeriesResliceWorker()

    /// The single entry of every DICOM that comes in. Any thread.
    var databaseIngest: DatabaseIngest {
        DatabaseIngest(processGraph: self)
    }

    /// Which local database a reader of the local database reads. Each read
    /// asks again, so a reader follows the database that replaces another.
    enum LocalReadDatabase: Sendable {
        /// The database in the default data folder, which the listener serves.
        case defaultDatabase
        /// The active local database, which a retrieve fills.
        case activeLocal
        /// The database the browser shows.
        case browser
    }

    /// The reader of the studies, series and metadata of a local database, the
    /// adapter of `LocalStudyReading`, `LocalSeriesReading` and
    /// `LocalMetadataQuerying`. Any thread.
    func localStudyReader(reading database: LocalReadDatabase) -> LocalDatabaseStudyReader {
        switch database {
        case .defaultDatabase:
            return LocalDatabaseStudyReader { [self] in defaultDatabase }
        case .activeLocal:
            return LocalDatabaseStudyReader { [self] in activeLocalDatabase }
        case .browser:
            return LocalDatabaseStudyReader { [self] in browserDatabase }
        }
    }

    /// The ROI archives of `images`, which belong to `database`: the adapter
    /// of `ROIStoring` the 2D viewers read and write their ROIs through, made
    /// for each load and save, on the main thread where the images are read.
    @MainActor func roiArchives(of images: [DicomImage], in database: DicomDatabase) -> ViewerROIArchiveStore {
        ViewerROIArchiveStore(images: images, database: database, ingest: databaseIngest)
    }

    /// The browser singleton, which only the members above hand out: the
    /// browser itself on the main actor, its thread-safe switch, database and
    /// delete queue anywhere.
    private var browser: BrowserController? {
        BrowserController.currentBrowser()
    }
}

/// A member the graph makes the first time it is asked for, from any thread,
/// and then keeps: the members that receive the graph itself cannot be made
/// while the graph is being made. The mutex makes one, even when two threads
/// ask at the same time; making it does nothing but keep the graph.
private final class MadeOnFirstUse<Member: Sendable>: Sendable {
    private let kept = Mutex<Member?>(nil)

    func callAsFunction(_ make: () -> Member) -> Member {
        kept.withLock { kept in
            if let member = kept { return member }
            let member = make()
            kept = member
            return member
        }
    }
}
