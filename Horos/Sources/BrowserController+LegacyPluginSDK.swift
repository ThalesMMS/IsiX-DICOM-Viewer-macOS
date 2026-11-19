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
import IsiXContracts
import IsiXPreferences

// Selectors of BrowserController in the Horos and OsiriX plugin SDK that the
// application itself no longer sends. A plugin built for either is not
// rebuilt: it sends them by name, from any thread, and an absent one raises
// "unrecognized selector" in the middle of the plugin's work. Each one hands
// over to the type that does the work today (LegacyPluginIngest).
public extension BrowserController {
    @objc(getNewFileDatabasePath:)
    nonisolated func legacyNewFilePath(_ fileExtension: String!) -> String! { LegacyPluginIngest.newFilePath(extension: fileExtension, in: database) }
    @objc(getNewFileDatabasePath:dbFolder:)
    nonisolated func legacyNewFilePath(_ fileExtension: String!, dbFolder: String!) -> String! { LegacyPluginIngest.newFilePath(extension: fileExtension, in: dbFolder.flatMap { DicomDatabase(atPath: $0) }) }
    @objc(addFilesToDatabase:)
    nonisolated func legacyAdd(_ files: [Any]!) -> [Any]! { LegacyPluginIngest.add(files, to: database, dicomOnly: .preference, notify: true, reread: false, generatedByOsiriX: false) }
    @objc(addFilesToDatabase:onlyDICOM:produceAddedFiles:)
    nonisolated func legacyAdd(_ files: [Any]!, onlyDICOM: Bool, produceAddedFiles: Bool) -> [Any]! { legacyAdd(files, onlyDICOM: onlyDICOM, produceAddedFiles: produceAddedFiles, parseExistingObject: false) }
    @objc(addFilesToDatabase:onlyDICOM:produceAddedFiles:parseExistingObject:)
    nonisolated func legacyAdd(_ files: [Any]!, onlyDICOM: Bool, produceAddedFiles: Bool, parseExistingObject: Bool) -> [Any]! {
        legacyAdd(files, onlyDICOM: onlyDICOM, produceAddedFiles: produceAddedFiles, parseExistingObject: parseExistingObject, context: nil, dbFolder: nil)
    }
    @objc(addFilesToDatabase:onlyDICOM:produceAddedFiles:parseExistingObject:context:dbFolder:)
    nonisolated func legacyAdd(_ files: [Any]!, onlyDICOM: Bool, produceAddedFiles: Bool, parseExistingObject: Bool, context: NSManagedObjectContext!, dbFolder: String!) -> [Any]! {
        LegacyPluginIngest.add(files, to: LegacyPluginIngest.database(context: context, browser: self, folder: dbFolder, browserFirst: false), dicomOnly: onlyDICOM ? .always : .never, notify: produceAddedFiles, reread: parseExistingObject, generatedByOsiriX: false)
    }
    @objc(addFilesToDatabase:onlyDICOM:safeRebuild:produceAddedFiles:)
    nonisolated func legacyAdd(_ files: [Any]!, onlyDICOM: Bool, safeRebuild: Bool, produceAddedFiles: Bool) -> [Any]! { legacyAdd(files, onlyDICOM: onlyDICOM, produceAddedFiles: produceAddedFiles, parseExistingObject: false) }
    @objc(addFiles:toContext:onlyDICOM:notifyAddedFiles:parseExistingObject:dbFolder:)
    nonisolated class func legacyAdd(_ files: [Any]!, toContext context: NSManagedObjectContext!, onlyDICOM: Bool, notifyAddedFiles: Bool, parseExistingObject: Bool, dbFolder: String!) -> [Any]! {
        legacyAdd(files, toContext: context, toDatabase: nil, onlyDICOM: onlyDICOM, notifyAddedFiles: notifyAddedFiles, parseExistingObject: parseExistingObject, dbFolder: dbFolder, generatedByOsiriX: false)
    }
    @objc(addFiles:toContext:toDatabase:onlyDICOM:notifyAddedFiles:parseExistingObject:dbFolder:)
    nonisolated class func legacyAdd(_ files: [Any]!, toContext context: NSManagedObjectContext!, toDatabase browser: BrowserController!, onlyDICOM: Bool, notifyAddedFiles: Bool, parseExistingObject: Bool, dbFolder: String!) -> [Any]! {
        legacyAdd(files, toContext: context, toDatabase: browser, onlyDICOM: onlyDICOM, notifyAddedFiles: notifyAddedFiles, parseExistingObject: parseExistingObject, dbFolder: dbFolder, generatedByOsiriX: false)
    }
    @objc(addFiles:toContext:toDatabase:onlyDICOM:notifyAddedFiles:parseExistingObject:dbFolder:generatedByOsiriX:)
    nonisolated class func legacyAdd(_ files: [Any]!, toContext context: NSManagedObjectContext!, toDatabase browser: BrowserController!, onlyDICOM: Bool, notifyAddedFiles: Bool, parseExistingObject: Bool, dbFolder: String!, generatedByOsiriX: Bool) -> [Any]! {
        LegacyPluginIngest.add(files, to: LegacyPluginIngest.database(context: context, browser: browser, folder: dbFolder), dicomOnly: onlyDICOM ? .always : .never, notify: notifyAddedFiles, reread: parseExistingObject, generatedByOsiriX: generatedByOsiriX)
    }
    @objc(addFiles:toContext:toDatabase:onlyDICOM:notifyAddedFiles:parseExistingObject:dbFolder:generatedByOsiriX:mountedVolume:)
    nonisolated class func legacyAdd(_ files: [Any]!, toContext context: NSManagedObjectContext!, toDatabase browser: BrowserController!, onlyDICOM: Bool, notifyAddedFiles: Bool, parseExistingObject: Bool, dbFolder: String!, generatedByOsiriX: Bool, mountedVolume: Bool) -> [Any]! {
        legacyAdd(files, toContext: context, toDatabase: browser, onlyDICOM: onlyDICOM, notifyAddedFiles: notifyAddedFiles, parseExistingObject: parseExistingObject, dbFolder: dbFolder, generatedByOsiriX: generatedByOsiriX)
    }
    @objc(checkIncoming:)
    nonisolated func legacyCheckIncoming(_ sender: Any!) { LegacyPluginIngest.checkIncoming(waiting: false) }
    @objc(checkIncomingNow:)
    nonisolated func legacyCheckIncomingNow(_ sender: Any!) { LegacyPluginIngest.checkIncoming(waiting: false) }
    @objc(checkIncomingThread:)
    nonisolated func legacyCheckIncomingThread(_ sender: Any!) { LegacyPluginIngest.checkIncoming(waiting: true) }
}

// The other selectors of the SDK on the database window. Those a plugin sent
// from its own threads are nonisolated.
extension BrowserController {
    @objc(ROIsAndKeyImages:sameSeries:) func legacyROIsAndKeyImages(_ sender: Any?, sameSeries: UnsafeMutablePointer<ObjCBool>?) -> [Any]? {
        let marked = markedImages.roisAndKeyImages(sender)
        sameSeries?.pointee = ObjCBool(marked.sameSeries)
        return marked.images
    }
    @objc(addFiles:withRule:) nonisolated func legacyAddFiles(_ images: [Any]?, withRule rule: [AnyHashable: Any]?) { database?.addImages(images, toSendQueueForRoutingRule: rule) }
    @IBAction @objc(buildAllThumbnails:) func legacyBuildAllThumbnails(_ sender: Any?) { StoredThumbnailBacklog(browser: self, preferences: PreferencesSource.process.preferences).build() }
    @objc(localDatabasePath) nonisolated func legacyLocalDatabasePath() -> String? { DicomDatabase.activeLocal()?.sqlFilePath }
    @objc(cfixedDocumentsDirectory) nonisolated func legacyCFixedDocumentsDirectory() -> UnsafePointer<CChar>? { DicomDatabase.activeLocal()?.baseDirPathC() }
    @objc(cfixedTempNoIndexDirectory) nonisolated func legacyCFixedTempNoIndexDirectory() -> UnsafePointer<CChar>? { DicomDatabase.activeLocal()?.tempDirPathC() }
    @objc(checkReportsDICOMSRConsistency) nonisolated func legacyCheckReportsDICOMSRConsistency() { database?.checkReportsConsistencyWithDICOMSR() }
    @objc(compressDICOMJPEG:) nonisolated func legacyCompressDICOMJPEG(_ paths: [Any]?) { LegacyBrowserSDK.convert(paths, mode: .compress, in: database) }
    @objc(decompressDICOMJPEG:) nonisolated func legacyDecompressDICOMJPEG(_ paths: [Any]?) { LegacyBrowserSDK.convert(paths, mode: .decompress, in: database) }
    @objc(decompressArrayOfFiles:work:) nonisolated func legacyDecompress(_ paths: [Any]?, work: NSNumber?) { LegacyBrowserSDK.transcode(paths, work: work, in: database) }
    @objc(distantStudiesForSmartAlbum:) nonisolated func legacyDistantStudies(forSmartAlbum album: String?) -> [Any]? { LegacyBrowserSDK.distantStudies(forSmartAlbum: album, in: database) }
    @objc(findDBPath:dbFolder:) func legacyFindDBPath(_ path: String?, dbFolder: String?) -> Int32 {
        let row = row(forSourceIdentifier: LocalDatabaseNodeIdentifier.localDatabaseNodeIdentifier(withPath: path) as? DataNodeIdentifier)
        return row >= 0 ? row : self.row(forSourceIdentifier: LocalDatabaseNodeIdentifier.localDatabaseNodeIdentifier(withPath: dbFolder) as? DataNodeIdentifier)
    }
    @objc(findStudyUID:) nonisolated func legacyFindStudy(uid: String?) -> NSManagedObject? { LegacyBrowserSDK.object(ofEntity: database?.studyEntity(), where: "studyInstanceUID", is: uid, in: database) }
    @objc(findSeriesUID:) nonisolated func legacyFindSeries(uid: String?) -> NSManagedObject? { LegacyBrowserSDK.object(ofEntity: database?.seriesEntity(), where: "seriesDICOMUID", is: uid, in: database) }
    /// The former body of the preview's thread: the preview of the selection is loaded again, and the call returns.
    @objc(matrixLoadIcons:) nonisolated func legacyMatrixLoadIcons(_ request: [AnyHashable: Any]?) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.refreshMatrix(self) } }
    }
    @objc(sendFilesToCurrentBonjourDB:) nonisolated func legacySendFilesToRemoteDatabase(_ paths: [Any]?) { (database as? RemoteDicomDatabase)?.uploadFiles(atPaths: paths, imageObjects: nil, generatedByOsiriX: false) }
    @objc(setBonjourDatabaseValue:value:forKey:) nonisolated func legacySetRemoteValue(_ object: NSManagedObject?, value: Any?, forKey key: String?) { LegacyBrowserSDK.set(value, forKey: key, of: object, in: database) }
    @objc(switchToDefaultDBIfNeeded) func legacySwitchToDefaultDatabase() { resetToDefaultDatabaseIfNecessary() }
    // The toolbar's delegate is `BrowserToolbar`.
    @objc(toolbar:itemForItemIdentifier:willBeInsertedIntoToolbar:) func legacyToolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? { browserToolbar.toolbar(toolbar, itemForItemIdentifier: identifier, willBeInsertedIntoToolbar: flag) }
    @objc(toolbarDefaultItemIdentifiers:) func legacyToolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { browserToolbar.toolbarDefaultItemIdentifiers(toolbar) }
    @objc(toolbarAllowedItemIdentifiers:) func legacyToolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { browserToolbar.toolbarAllowedItemIdentifiers(toolbar) }
}
