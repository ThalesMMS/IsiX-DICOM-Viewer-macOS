/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import AppKit
import IsiXDatabase
import IsiXContracts
import IsiXDICOMNetwork
import IsiXPreferences

/// Where the server of a shared database is asked to send images on: an
/// address, a port, an AE title and a transfer syntax.
struct ForwardTarget: Sendable, Equatable {
    var address: String?
    var port = 0
    var aeTitle: String?
    var transferSyntax = 0

    /// Without an address, a port and an AE title the other IsiX would send
    /// the images nowhere.
    var isComplete: Bool {
        !(address ?? "").isEmpty && port != 0 && !(aeTitle ?? "").isEmpty
    }
}

/// `-integerValue` of a number or a text, 0 otherwise.
private func integerValue(_ value: Any?) -> Int {
    if let number = value as? NSNumber { return number.intValue }
    if let text = value as? String { return (text as NSString).integerValue }
    return 0
}

/// A message of a copy with its count of files: `format` takes N2LocalizedDecimal(count) and "file" or "files".
private func status(_ format: String, files count: Int) -> String {
    String(format: format, NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal),
           count == 1 ? NSLocalizedString("file", comment: "") : NSLocalizedString("files", comment: ""))
}

/// The images dropped on a source of the Sources list, copied there on a
/// thread of their own that the Activity window lists: into another local
/// database, uploaded to a shared database, fetched from a shared database, or
/// sent on by a shared database's server. A DICOM node is handed to the send
/// window instead.
///
/// The main thread reads what the copy needs into this value; the thread uses
/// the databases only through private-queue databases it makes of them, and
/// indexes what it copies through the single entry, as a source copy.
struct SourceCopyJob: Sendable {
    /// The destination of the copy, as the main thread read it.
    struct Destination: Sendable {
        var kind: SourceListRules.CopyDestination
        var location: String?
        var port: UInt
        var name: String?
        /// Where a DICOM node receives; for a shared database, what its entry
        /// stores, which its server completes.
        var target: ForwardTarget
    }

    /// The databases of the copy. `@unchecked Sendable`: the thread asks each
    /// only for a private-queue database of itself, its read-only flag, the
    /// cache of a shared database's files and the requests to its server.
    private struct Databases: @unchecked Sendable {
        let source: DicomDatabase?
        /// The destination's database, made on the main thread when it is local.
        let target: DicomDatabase?
    }

    let route: SourceListRules.CopyRoute
    let imageIDs: [NSManagedObjectID]?
    let destination: Destination
    private let databases: Databases
    private let ingest: DatabaseIngest

    // MARK: Starting a copy

    private static func kind(of destination: DataNodeIdentifier?) -> SourceListRules.CopyDestination? {
        if destination is LocalDatabaseNodeIdentifier { return .localDatabase }
        if destination is RemoteDatabaseNodeIdentifier { return .sharedDatabase }
        if destination is DicomNodeIdentifier { return .dicomNode }
        return nil
    }

    /// Where a shared database's server is asked to send to, from what the
    /// destination says of itself: the address of a shared database and the
    /// port and AE title its entry stores, or a DICOM node's own host, port,
    /// AE title and transfer syntax. A node entered in the preferences or
    /// resolved through Bonjour keeps them in separate fields, without the
    /// "AET@host" location they were once read from only.
    static func forwardTarget(of destination: DataNodeIdentifier?) -> ForwardTarget {
        var target = ForwardTarget()
        if let destination = destination as? RemoteDatabaseNodeIdentifier {
            var address: NSString?
            _ = RemoteDatabaseNodeIdentifier.location(destination.location, port: destination.port, toAddress: &address, port: nil)
            target.address = address as String?
            target.port = integerValue(destination.dictionary?["port"])
            target.aeTitle = destination.dictionary?["AETitle"] as? String
        } else if let destination = destination as? DicomNodeIdentifier {
            if let node = destination.storeDestination() {
                target.address = node.address
                target.port = node.port
                target.aeTitle = node.aet
            }
            target.transferSyntax = integerValue(destination.dictionary?["TransferSyntax"])
        }
        return target
    }

    /// Copies `images` of the browser's database to `destination`; false when
    /// there is no way to.
    @MainActor
    static func initiate(images: [Any]?, to destination: DataNodeIdentifier?, from browser: BrowserController,
                         preferences: any PreferenceStore) -> Bool {
        let database = browser.database
        guard let destination,
              let route = SourceListRules.copyRoute(fromLocalDatabase: database?.isLocal() == true, to: kind(of: destination)) else {
            return false
        }
        var target: DicomDatabase?
        switch route {
        case .localToNode:
            // The send window opens on this node.
            let nodes = DICOMNodeService.dicomNodes(sendOnly: true, queryRetrieveOnly: false)
            for (index, node) in nodes.enumerated() where destination.isEqual(to: node.propertyList) {
                preferences.set(index, for: NetworkPreferences.lastSendServer)
            }
            browser.selectServer(images)
            return true
        case .localToLocal:
            // The destination's main database is made on the main thread.
            target = DicomDatabase(atPath: destination.location)
        case .sharedToLocal:
            _ = DicomDatabase(atPath: destination.location)
        case .localToShared, .sharedToRemote:
            break
        }
        let job = SourceCopyJob(route: route,
                                imageIDs: images.map { $0.compactMap { ($0 as? NSManagedObject)?.objectID } },
                                destination: Destination(kind: kind(of: destination) ?? .dicomNode,
                                                         location: destination.location, port: destination.port,
                                                         name: destination.description, target: forwardTarget(of: destination)),
                                databases: Databases(source: database, target: target),
                                ingest: DatabaseIngest.process)
        ActivityThread.startListed(name: job.activityName) { job.run() }
        return true
    }

    private var activityName: String {
        switch route {
        case .localToLocal, .sharedToLocal: return NSLocalizedString("Copying images...", comment: "")
        case .localToShared: return NSLocalizedString("Sending images...", comment: "")
        case .sharedToRemote, .localToNode: return NSLocalizedString("Initiating image transfer...", comment: "")
        }
    }

    // MARK: The copy

    /// Runs the copy on the current thread, which shows its progress.
    func run() {
        autoreleasepool {
            switch route {
            case .localToLocal: copyToLocalDatabase()
            case .localToShared: uploadToSharedDatabase()
            case .sharedToLocal: fetchFromSharedDatabase()
            case .sharedToRemote: forwardFromSharedDatabase()
            case .localToNode: break
            }
        }
    }

    /// The images of `database` with the IDs of the copy, read on its queue.
    private func images(in database: DicomDatabase?) -> [DicomImage] {
        (database?.objects(withIDs: imageIDs) ?? []).compactMap { $0 as? DicomImage }
    }

    /// Each image whose file is not one of an image before it, with its file.
    private func distinctFiles(of images: [DicomImage]) -> [(image: DicomImage, path: String?)] {
        var seen = Set<String?>()
        return images.compactMap { image in
            let path = image.completePath()
            return seen.insert(path).inserted ? (image, path) : nil
        }
    }

    private func copyToLocalDatabase() {
        guard imageIDs != nil, let target = databases.target else {
            NSLog("******* copyImagesToLocalBrowserSource : the images or the destination are missing")
            return
        }
        let raised = HorosObjCException.caught {
            let thread = Thread.current
            let source = databases.source

            // The paths are read on a private-queue context of the source, on
            // its queue; only the paths leave it.
            var sourcePaths: [String] = []
            if let reader = source?.privateQueueIndependentDatabase() as? DicomDatabase {
                reader.performBlockAndWait {
                    sourcePaths = distinctFiles(of: images(in: reader)).compactMap { $0.path }
                }
            }

            thread.status = NSLocalizedString("Opening database...", comment: "")
            // The copies are indexed on a private-queue context of the destination, on its queue.
            let destination = target.privateQueueIndependentDatabase() as? DicomDatabase

            thread.status = status(NSLocalizedString("Copying %@ %@...", comment: ""), files: sourcePaths.count)
            var copied: [String] = []
            var nextIndexing = Date.timeIntervalSinceReferenceDate + 5
            var nextStatus = Date.timeIntervalSinceReferenceDate + 1

            for (index, sourcePath) in sourcePaths.enumerated() {
                thread.progress = CGFloat(Double(index) / Double(sourcePaths.count))
                ActivityProgressCount.set(done: index, total: sourcePaths.count, on: thread)
                if thread.isCancelled { break }

                if let copyPath = destination?.uniquePathForNewDataFile(withExtension: "dcm"), !copyPath.isEmpty {
                    HorosObjCException.synchronized(BrowserController.horos_oneCopyAtATimeLock()) {
                        copy(sourcePath, to: copyPath, readOnly: source?.isReadOnly == true)
                        if FileManager.default.fileExists(atPath: copyPath) {
                            if !DicomFile.isDICOMFile(copyPath) {
                                let renamed = ((copyPath as NSString).deletingPathExtension as NSString)
                                    .appendingPathExtension((sourcePath as NSString).pathExtension)
                                if let renamed { try? FileManager.default.moveItem(atPath: copyPath, toPath: renamed) }
                            }
                            copied.append(copyPath)
                        }
                    }
                }

                if nextIndexing < Date.timeIntervalSinceReferenceDate {
                    thread.status = status(NSLocalizedString("Indexing %@ %@...", comment: ""), files: copied.count)
                    indexCopies(copied, preset: .sourceCopyBatch, in: destination)
                    copied.removeAll()
                    nextIndexing = Date.timeIntervalSinceReferenceDate + 5
                }
                if nextStatus < Date.timeIntervalSinceReferenceDate {
                    thread.status = status(NSLocalizedString("Copying %@ %@...", comment: ""), files: sourcePaths.count - index)
                    nextStatus = Date.timeIntervalSinceReferenceDate + 1
                }
            }

            thread.status = status(NSLocalizedString("Indexing %@ %@...", comment: ""), files: copied.count)
            thread.progress = -1
            indexCopies(copied, preset: .sourceCopy, in: destination)
        }
        if let raised {
            BrowserObjC.log(raised, "-[BrowserController(SourcesCopy) copyImagesToLocalBrowserSource:]")
        }
    }

    /// A file of a read-only source (a disc) is copied by `cp`, which reads
    /// it as the user does; another through the file manager.
    private func copy(_ sourcePath: String, to copyPath: String, readOnly: Bool) {
        if readOnly {
            let copying = Process.launchedProcess(launchPath: "/bin/cp", arguments: [sourcePath, copyPath])
            copying.waitUntilExit()
        } else if (try? FileManager.default.copyItem(atPath: sourcePath, toPath: copyPath)) == nil {
            NSLog("**** copyItemAtPath failed: %@", copyPath)
        }
    }

    /// Indexes the copies through the single entry, on the queue of the
    /// destination's private-queue database.
    private func indexCopies(_ paths: [String], preset: IngestPreset, in database: DicomDatabase?) {
        guard let database else { return }
        database.performBlockAndWait { _ = ingest.index(paths, preset: preset, in: database) }
    }

    private func uploadToSharedDatabase() {
        let thread = Thread.current
        // The source's images are read on a private-queue context, on its
        // queue, for as long as they are used.
        let reader = databases.source?.privateQueueIndependentDatabase() as? DicomDatabase
        N2ManagedObjectContextPerformAndWait(reader?.managedObjectContext) {
            let paths = distinctFiles(of: images(in: reader)).compactMap { $0.path }
            thread.status = NSLocalizedString("Opening database...", comment: "")
            if let raised = HorosObjCException.caught({
                let server = RemoteDicomDatabase.database(forLocation: destination.location, port: destination.port,
                                                          name: destination.name, update: false)
                thread.status = status(NSLocalizedString("Sending %@ %@...", comment: ""), files: paths.count)
                server?.uploadFiles(atPaths: paths, imageObjects: nil)
            }) {
                thread.status = NSLocalizedString("Error: destination is unavailable", comment: "")
                BrowserObjC.log(raised, stack: true, "-[BrowserController(SourcesCopy) copyImagesToRemoteBrowserSource:]")
                Thread.sleep(forTimeInterval: 1)
            }
        }
    }

    private func fetchFromSharedDatabase() {
        let thread = Thread.current
        let server = databases.source as? RemoteDicomDatabase
        let reader = server?.privateQueueIndependentDatabase() as? DicomDatabase
        N2ManagedObjectContextPerformAndWait(reader?.managedObjectContext) {
            let fetched = distinctFiles(of: images(in: reader)).map { $0.image }
            thread.status = NSLocalizedString("Opening database...", comment: "")

            // Indexed on a private-queue context of the destination, on its queue.
            let local = DicomDatabase(atPath: destination.location, name: destination.name)?
                .privateQueueIndependentDatabase() as? DicomDatabase

            thread.status = status(NSLocalizedString("Fetching %@ %@...", comment: ""), files: fetched.count)
            var copied: [String] = []
            for (index, image) in fetched.enumerated() {
                if let raised = HorosObjCException.caught({
                    guard let cached = server?.cacheData(for: image, maxFiles: 0) else { return }
                    let ext = DicomFile.isDICOMFile(cached) ? "dcm" : (cached as NSString).pathExtension
                    if let copyPath = local?.uniquePathForNewDataFile(withExtension: ext), !copyPath.isEmpty,
                       (try? FileManager.default.moveItem(atPath: cached, toPath: copyPath)) != nil {
                        copied.append(copyPath)
                    }
                }) {
                    BrowserObjC.log(raised, stack: true, "-[BrowserController(SourcesCopy) copyRemoteImagesToLocalBrowserSource:]")
                }
                thread.progress = CGFloat(Double(index) / Double(fetched.count))
                if thread.isCancelled { break }
            }

            thread.status = NSLocalizedString("Indexing files...", comment: "")
            thread.progress = -1
            indexCopies(copied, preset: .sourceCopy, in: local)
        }
    }

    private func forwardFromSharedDatabase() {
        let thread = Thread.current
        let server = databases.source as? RemoteDicomDatabase
        let reader = server?.privateQueueIndependentDatabase() as? DicomDatabase
        N2ManagedObjectContextPerformAndWait(reader?.managedObjectContext) {
            let forwarded = distinctFiles(of: images(in: reader)).map { $0.image }
            var target = destination.target
            // A shared database says itself where its node receives.
            if destination.kind == .sharedDatabase && (target.aeTitle == nil || target.port == 0 || target.transferSyntax == 0) {
                thread.status = NSLocalizedString("Fetching destination information...", comment: "")
                var info: [String: Any]?
                if let raised = HorosObjCException.caught({
                    info = RemoteDicomDatabase.database(forLocation: destination.location, port: destination.port,
                                                        name: destination.name, update: false)?
                        .fetchDicomDestinationInfo() as? [String: Any]
                }) {
                    thread.status = NSLocalizedString("Error: destination is unavailable", comment: "")
                    BrowserObjC.log(raised, stack: true, "-[BrowserController(SourcesCopy) copyRemoteImagesToRemoteBrowserSource:]")
                    Thread.sleep(forTimeInterval: 1)
                }
                if let aeTitle = info?["AETitle"] { target.aeTitle = aeTitle as? String }
                if let port = info?["Port"] { target.port = integerValue(port) }
                if let syntax = info?["TransferSyntax"] { target.transferSyntax = integerValue(syntax) }
            }

            guard target.isComplete else {
                thread.status = NSLocalizedString("Error: destination is unavailable", comment: "")
                return
            }
            thread.status = NSLocalizedString("Sending SCU request...", comment: "")
            server?.storeScuImages(forwarded, toDestinationAETitle: target.aeTitle, address: target.address, port: target.port,
                                   transferSyntax: Int32(truncatingIfNeeded: target.transferSyntax))
        }
    }

}

// MARK: Routing by hand

extension SourceCopyJob {

    /// Tries the filter of every routing rule of the preferences on the images
    /// of one study of `database`, and says which one has a syntax error.
    @MainActor
    static func checkRoutingFilters(of database: DicomDatabase?, preferences: any PreferenceStore,
                                    predicate: (String?) -> NSPredicate?) {
#if !OSIRIX_LIGHT
        guard preferences[NetworkPreferences.autoroutingActivated] else { return }
        let rules = RoutingRule.rules(fromPropertyList: preferences.object(forKey: RoutingRule.preferenceKey))
        guard let context = database?.managedObjectContext else { return }

        N2ManagedObjectContextPerformAndWait(context) {
            // A study to try the filters on.
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: "Study")
            request.predicate = NSPredicate(value: true)
            request.fetchLimit = 1
            guard let study = (try? context.fetch(request))?.first as? DicomStudy else { return }
            let images = (study.images() as NSSet?)?.allObjects ?? []

            for rule in rules {
                if let exception = HorosObjCException.caught({
                    guard rule.filterType == 0 else { return }
                    // Tried on the first study; no predicate is an invalid argument there too.
                    guard let filter = predicate(rule.filter) else {
                        NSException(name: .invalidArgumentException, reason: "-[NSArray filteredArrayUsingPredicate:]: predicate cannot be nil",
                                    userInfo: nil).raise()
                        return
                    }
                    _ = images.filter { filter.evaluate(with: $0) }
                }) {
                    let message = String(format: NSLocalizedString("Syntax error in this routing filter: %@\r\r%@\r\r%@", comment: ""),
                                         rule[RoutingRule.Key.name]?.text ?? "(null)", rule[RoutingRule.Key.filter]?.text ?? "(null)",
                                         exception.description)
                    _ = HorosAlertPanel.run(title: NSLocalizedString("Routing Filter Error", comment: ""), message: message,
                                            defaultButton: nil, alternateButton: nil, otherButton: nil)
                    BrowserObjC.log(exception, stack: true, "-[BrowserController testAutorouting]")
                }
            }
        }
#endif
    }

    /// Sends `images` of `database` through the rule a menu item or a cell
    /// carries, or through every rule of the preferences when none: the
    /// contextual menu of the database window.
    @MainActor
    static func route(_ images: [Any], through representedRule: Any?, in database: DicomDatabase?) {
        if let representedRule {
            NSLog(" Autorouting trigger: %d image(s) sent through one rule by hand, from the database window", Int32(images.count))
            let rules = RoutingRule.rules(fromPropertyList: [representedRule])
            database?.applyRoutingRules(rules.map(\.propertyList), toImages: images)
        } else {
            NSLog(" Autorouting trigger: %d image(s) sent through every rule by hand, from the database window", Int32(images.count))
            database?.applyRoutingRules(nil, toImages: images)
        }
    }
}
