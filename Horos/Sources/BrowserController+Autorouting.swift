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

// The autorouting functions of the browser: checking the routing filters of
// the preferences and sending the selection through a rule by hand. The rules
// themselves are applied by DicomDatabase.

extension BrowserController {

    /// Tries every routing filter of the preferences on the images of one
    /// study, and says which one has a syntax error.
    @objc(testAutorouting)
    func testAutorouting() {
        #if !OSIRIX_LIGHT
        guard UserDefaults.standard.bool(forKey: "AUTOROUTINGACTIVATED") else { return }
        let rules = UserDefaults.standard.array(forKey: "AUTOROUTINGDICTIONARY") ?? []
        guard let database = self.database, let context = database.managedObjectContext else { return }

        N2ManagedObjectContextPerformAndWait(context) {
            // A study to test the filters on.
            let request = NSFetchRequest<NSFetchRequestResult>()
            request.entity = database.managedObjectModel?.entitiesByName["Study"]
            request.predicate = NSPredicate(value: true)
            request.fetchLimit = 1
            guard let study = (try? context.fetch(request))?.first as? DicomStudy else { return }
            let images = (study.images() as NSSet?)?.allObjects ?? []

            for case let rule as NSDictionary in rules {
                if let exception = BrowserObjC.attempt({
                    guard BrowserObjC.intValue(rule["filterType"]) == 0 else { return }
                    // Tried on the first study; no predicate is an invalid argument there too.
                    guard let predicate = self.smartAlbumPredicateString(rule["filter"] as? String) else {
                        NSException(name: .invalidArgumentException, reason: "-[NSArray filteredArrayUsingPredicate:]: predicate cannot be nil",
                                    userInfo: nil).raise()
                        return
                    }
                    _ = (images as NSArray).filtered(using: predicate)
                }) {
                    let message = String(format: NSLocalizedString("Syntax error in this routing filter: %@\r\r%@\r\r%@", comment: ""),
                                         String(describing: rule["name"] ?? "(null)"), String(describing: rule["filter"] ?? "(null)"),
                                         exception.description)
                    _ = HorosAlertPanel.run(title: NSLocalizedString("Routing Filter Error", comment: ""), message: message,
                                            defaultButton: nil, alternateButton: nil, otherButton: nil)
                    BrowserObjC.log(exception, stack: true, "-[BrowserController testAutorouting]")
                }
            }
        }
        #endif
    }

    /// The study of the image last selected in the thumbnails, else in the list.
    @objc(selectedStudy)
    func selectedStudy() -> DicomStudy! {
        let objects = NSMutableArray()
        _ = files(forDatabaseMatrixSelection: objects, onlyImages: false)
        var image = objects.lastObject as? DicomImage
        if image == nil {
            _ = files(forDatabaseOutlineSelection: objects, onlyImages: false)
            image = objects.lastObject as? DicomImage
        }
        return image?.series?.study
    }

    /// Sends the selection through the menu item's rule, or through every
    /// rule without one: the database window's contextual menu.
    @objc(applyRoutingRule:)
    func applyRoutingRule(_ sender: Any!) {
        var matrixThumbnails = false
        if isThumbnailMenuItem(sender) || window?.firstResponder === horos_oMatrix {
            matrixThumbnails = true
            NSLog("applyRoutingRule from matrix")
        }

        let objects = NSMutableArray()
        if matrixThumbnails {
            _ = files(forDatabaseMatrixSelection: objects, onlyImages: false)
        } else {
            _ = files(forDatabaseOutlineSelection: objects, onlyImages: false)
        }

        if let rule = (sender as? NSMenuItem)?.representedObject ?? (sender as? NSCell)?.representedObject {
            NSLog(" Autorouting trigger: %d image(s) sent through one rule by hand, from the database window", Int32(objects.count))
            database?.applyRoutingRules([rule] as NSArray, toImages: objects)
        } else {
            NSLog(" Autorouting trigger: %d image(s) sent through every rule by hand, from the database window", Int32(objects.count))
            database?.applyRoutingRules(nil, toImages: objects)
        }
    }

    @available(*, deprecated)
    @objc(addFiles:withRule:)
    func addFiles(_ images: [Any]!, withRule routingRule: [AnyHashable: Any]!) {
        database?.addImages(images as NSArray?, toSendQueueForRoutingRule: routingRule as NSDictionary?)
    }
}
