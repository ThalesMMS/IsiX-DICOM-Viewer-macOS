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

import AppKit
import IsiXDatabase

// What the browser's selection holds: the children of a study or a series,
// the images a series or a study gives, and the files and objects of the
// rows selected in the outline, downloaded first from a remote database.
// The children of a row are DatabaseItemChildren's; which image of each series
// a study gives and what an empty study loses are IsiXDatabase's
// SelectionImages. The selectors are those of the former
// Objective-C methods, which the viewers, the plugins and the web portal
// call.

/// The toolbar item of the ROIs and key images.
private let OpenKeyImagesAndROIsToolbarItemIdentifier = "ROIsAndKeys.tif"

/// The files a remote database sends at a time.
private let BONJOURPACKETS = 50

/// [object valueForKey: @"type"] is `type`.
nonisolated private func isType(_ object: Any?, _ type: String) -> Bool {
    return BrowserObjC.literallyEqual((object as AnyObject?)?.value(forKey: "type") as? String, type)
}

/// [array addObject: object], which raises for nil.
nonisolated private func addObject(_ array: NSMutableArray, _ object: Any?) {
    guard let object else {
        NSException(name: .invalidArgumentException, reason: "*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil", userInfo: nil).raise()
        return
    }
    array.add(object)
}

extension BrowserController {

    // MARK: Children and images

    /// The series of a study or the sorted images of a series: DatabaseItemChildren's.
    @discardableResult
    @objc(childrenArray:onlyImages:)
    nonisolated func childrenArray(_ item: Any!, onlyImages: Bool) -> [Any]! {
        DatabaseItemChildren.children(of: item, onlyImages: onlyImages)
    }

    @discardableResult
    @objc(childrenArray:)
    nonisolated func childrenArray(_ item: Any!) -> [Any]! {
        DatabaseItemChildren.children(of: item)
    }

    /// The images of a series, or one image of each series of a study: any
    /// image, the middle one or the first, as `preferredObject` says (see
    /// SelectionImages.Walk).
    @discardableResult
    @objc(imagesArray:preferredObject:onlyImages:)
    nonisolated func imagesArray(_ item: Any!, preferredObject: Int32, onlyImages: Bool) -> [Any]! {
        guard let childrenArray = childrenArray(item, onlyImages: onlyImages) else { return nil }
        var imagesPathArray: NSMutableArray?

        if let raised = HorosObjCException.caught({
            if isType(item, "Series") {
                imagesPathArray = NSMutableArray(array: childrenArray)
            } else if isType(item, "Study") {
                let images = NSMutableArray(capacity: childrenArray.count)
                imagesPathArray = images
                var walk = SelectionImages.Walk(preferred: preferredObject)

                for i in childrenArray {
                    let whichObject = walk.next(hasThumbnail: {
                        (i as? NSManagedObject)?.primitiveValue(forKey: "thumbnail") != nil
                    })

                    switch whichObject {
                    case SelectionImages.any:
                        if let obj = ((i as AnyObject).value(forKey: "images") as? NSSet)?.anyObject() {
                            images.add(obj)
                        }
                    case SelectionImages.middle:
                        // Get the middle image of the series
                        let seriesArray = (self.childrenArray(i, onlyImages: onlyImages) ?? []) as NSArray
                        if let middle = SelectionImages.middleIndex(count: seriesArray.count) {
                            images.add(seriesArray.object(at: middle))
                        }
                    case SelectionImages.firstForFirst:
                        let seriesArray = (self.childrenArray(i, onlyImages: onlyImages) ?? []) as NSArray
                        if seriesArray.count > 0 {
                            images.add(seriesArray.object(at: 0))
                        }
                    default:
                        break
                    }
                }
            }
        }) {
            BrowserObjC.log(raised, stack: true, "-[BrowserController imagesArray:preferredObject:onlyImages:]")
        }

        return imagesPathArray as? [Any]
    }

    /// Any image of each series: the preferred object asked is not used, as
    /// it never was.
    @discardableResult
    @objc(imagesArray:preferredObject:)
    nonisolated func imagesArray(_ item: Any!, preferredObject: Int32) -> [Any]! {
        return imagesArray(item, preferredObject: SelectionImages.any, onlyImages: true)
    }

    @discardableResult
    @objc(imagesArray:onlyImages:)
    nonisolated func imagesArray(_ item: Any!, onlyImages: Bool) -> [Any]! {
        return imagesArray(item, preferredObject: SelectionImages.any, onlyImages: onlyImages)
    }

    @discardableResult
    @objc(imagesArray:)
    nonisolated func imagesArray(_ item: Any!) -> [Any]! {
        return imagesArray(item, preferredObject: SelectionImages.any)
    }

    @discardableResult
    @objc(imagesPathArray:)
    nonisolated func imagesPathArray(_ item: NSManagedObject!) -> [Any]! {
        return (imagesArray(item) as NSArray?)?.value(forKey: "completePath") as? [Any]
    }

    // MARK: The files of the selection

    /// An image of the row selected: of its first series for a study.
    @discardableResult
    func firstObjectForDatabaseOutlineSelection() -> NSManagedObject! {
        guard let databaseOutline = horos_databaseOutline else { return nil }
        var aFile = databaseOutline.item(atRow: databaseOutline.selectedRow) as AnyObject?

        if isType(aFile, "Study") {
            aFile = (aFile?.value(forKey: "series") as? NSSet)?.anyObject() as AnyObject?
        }
        if isType(aFile, "Series") {
            aFile = (aFile?.value(forKey: "images") as? NSSet)?.anyObject() as AnyObject?
        }
        return aFile as? NSManagedObject
    }

    /// The files of the rows selected in the outline, their image objects in
    /// `correspondingManagedObjects` and the rows' objects in
    /// `treeManagedObjects`. A selected study gives its images and loses its
    /// "No Autodeletion" series once it has some; asked for every object, an
    /// empty study without that series is deleted. The files of a remote
    /// database are downloaded first. The last selection of images is
    /// remembered and answered again while the rows stay the same.
    @discardableResult
    @objc(filesForDatabaseOutlineSelection:treeObjects:onlyImages:)
    func files(forDatabaseOutlineSelection correspondingManagedObjects: NSMutableArray!, treeObjects treeManagedObjects: NSMutableSet!,
                                          onlyImages: Bool) -> NSMutableArray! {
        let selectedFiles = NSMutableArray()
        let databaseOutline = horos_databaseOutline
        let rowEnumerator = databaseOutline?.selectedRowIndexes ?? IndexSet()

        if let cachedIndex = horos_cachedFilesForDatabaseOutlineSelectionIndex,
           let selected = databaseOutline?.selectedRowIndexes, selected == cachedIndex, onlyImages {
            selectedFiles.addObjects(from: (horos_cachedFilesForDatabaseOutlineSelectionSelectedFiles as? [Any]) ?? [])
            correspondingManagedObjects?.addObjects(from: (horos_cachedFilesForDatabaseOutlineSelectionCorrespondingObjects as? [Any]) ?? [])
            treeManagedObjects?.addObjects(from: horos_cachedFilesForDatabaseOutlineSelectionTreeObjects?.allObjects ?? [])
            return selectedFiles
        }

        let database = self.database
        let context = database?.managedObjectContext
        let correspondingManagedObjects = correspondingManagedObjects ?? NSMutableArray()
        let treeManagedObjects = treeManagedObjects ?? NSMutableSet()

        N2ManagedObjectContextPerformAndWait(context) {
            if let raised = HorosObjCException.caught({
                for row in rowEnumerator {
                    guard let curObj = databaseOutline?.item(atRow: row) as? NSManagedObject else { continue } // not a distant study

                    if isType(curObj, "Series") {
                        autoreleasepool {
                            correspondingManagedObjects.addObjects(from: self.imagesArray(curObj, onlyImages: onlyImages) ?? [])
                        }
                    }

                    if isType(curObj, "Study") {
                        autoreleasepool {
                            let seriesArray = self.childrenArray(curObj, onlyImages: onlyImages) ?? []
                            var totImage: Int32 = 0
                            var dontDelete: NSManagedObject?

                            for obj in seriesArray {
                                let imagesArray = self.imagesArray(obj, onlyImages: onlyImages) ?? []
                                totImage = totImage &+ Int32(truncatingIfNeeded: imagesArray.count)
                                correspondingManagedObjects.addObjects(from: imagesArray)

                                let series = obj as AnyObject
                                if SelectionImages.isNoAutodeletionSeries(name: series.value(forKey: "name") as? String,
                                                                          id: BrowserObjC.intValue(series.value(forKey: "id"))) {
                                    dontDelete = obj as? NSManagedObject
                                }
                            }

                            let cleanup = SelectionImages.studyCleanup(imageCount: Int(totImage), hasNoAutodeletionSeries: dontDelete != nil,
                                                                       onlyImages: onlyImages)
                            if cleanup.deleteSeries, let dontDelete { // there are images, remove the "No Autodeletion" series
                                context?.delete(dontDelete)
                            }
                            if cleanup.deleteStudy { // We don't want empty studies, unless the "No Autodeletion" series is there...
                                context?.delete(curObj)
                            }
                        }
                    }

                    if !curObj.isDeleted {
                        treeManagedObjects.add(curObj)
                    }
                }

                correspondingManagedObjects.removeDuplicatedObjects()

                if database?.isLocal() != true {
                    let splash = Wait(string: NSLocalizedString("Downloading files...", comment: ""))
                    splash?.showWindow(self)
                    splash?.setCancel(true)
                    splash?.progress()?.maxValue = Double(correspondingManagedObjects.count)

                    for obj in correspondingManagedObjects {
                        if splash?.aborted() != true {
                            autoreleasepool {
                                let p = self.getLocalDCMPath(obj as? NSManagedObject, BONJOURPACKETS)
                                addObject(selectedFiles, p)
                                splash?.increment(by: 1)
                            }
                        }
                    }

                    if splash?.aborted() == true {
                        selectedFiles.removeAllObjects()
                        correspondingManagedObjects.removeAllObjects()
                    }

                    splash?.close()
                } else {
                    selectedFiles.addObjects(from: (correspondingManagedObjects.value(forKey: "completePath") as? [Any]) ?? [])
                }

                if correspondingManagedObjects.count != selectedFiles.count {
                    NSLog("****** WARNING [correspondingManagedObjects count] != [selectedFiles count]")
                }
            }) {
                BrowserObjC.log(raised, stack: true, "-[BrowserController filesForDatabaseOutlineSelection:treeObjects:onlyImages:]")
            }

            try? context?.save()
        }

        if onlyImages {
            horos_cachedFilesForDatabaseOutlineSelectionIndex = databaseOutline?.selectedRowIndexes
            horos_cachedFilesForDatabaseOutlineSelectionSelectedFiles = selectedFiles.mutableCopy() as? NSMutableArray
            horos_cachedFilesForDatabaseOutlineSelectionTreeObjects = treeManagedObjects.mutableCopy() as? NSMutableSet
            horos_cachedFilesForDatabaseOutlineSelectionCorrespondingObjects = correspondingManagedObjects.mutableCopy() as? NSMutableArray
        }

        return selectedFiles
    }

    @discardableResult
    @objc(filesForDatabaseOutlineSelection:onlyImages:)
    func files(forDatabaseOutlineSelection correspondingManagedObjects: NSMutableArray!, onlyImages: Bool) -> NSMutableArray! {
        return files(forDatabaseOutlineSelection: correspondingManagedObjects, treeObjects: nil, onlyImages: onlyImages)
    }

    @discardableResult
    @objc(filesForDatabaseOutlineSelection:)
    func files(forDatabaseOutlineSelection correspondingManagedObjects: NSMutableArray!) -> NSMutableArray! {
        return files(forDatabaseOutlineSelection: correspondingManagedObjects, onlyImages: true)
    }

    // MARK: The ROIs and key images button

    /// Whether the toolbar's "ROIs and key images" button is available: on a
    /// local database, at once for five rows or more, otherwise when the
    /// selection has key images (Option), ROI images (Shift) or either.
    @objc(resetROIsAndKeysButton)
    func resetROIsAndKeysButton() {
        horos_ROIsAndKeyImagesButtonAvailable = false

        let identifiers = (horos_toolbar?.items ?? []).map { $0.itemIdentifier.rawValue }
        guard identifiers.contains(where: { BrowserObjC.literallyEqual($0, OpenKeyImagesAndROIsToolbarItemIdentifier) }),
              self.database?.isLocal() == true else { return }

        if (horos_databaseOutline?.selectedRowIndexes.count ?? 0) >= 5 {
            horos_ROIsAndKeyImagesButtonAvailable = true
        } else {
            let flags = NSApplication.shared.currentEvent?.modifierFlags ?? []
            if flags.contains(.option) {
                horos_ROIsAndKeyImagesButtonAvailable = (keyImages(nil) as NSArray?)?.count ?? 0 != 0
            } else if flags.contains(.shift) {
                horos_ROIsAndKeyImagesButtonAvailable = (roiImages(nil) as NSArray?)?.count ?? 0 != 0
            } else {
                horos_ROIsAndKeyImagesButtonAvailable = (roisAndKeyImages(nil) as NSArray?)?.count ?? 0 != 0
            }
        }
    }
}
