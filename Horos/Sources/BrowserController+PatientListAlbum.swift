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

// An album from a list of patients in an image: the window, the parsing and
// the decisions are PatientListAlbumWindow.swift and PatientListImport.swift;
// the browser answers as their host with the database and the Query/Retrieve.
// No name or identifier is logged.

extension BrowserController: @MainActor PatientListAlbumHost {

    @objc(createAlbumFromPatientListImage:)
    func createAlbumFromPatientListImage(_ sender: Any!) {
        guard self.database?.isLocal() ?? false else {
            NSSound.beep()
            return
        }
        PatientListAlbumWindowController.begin(host: self, parent: self.window)
    }

    /// The studies whose patient ID is the identifier or whose name has every
    /// word of the listed name, and the other studies of their patients.
    @discardableResult
    @objc(patientListCandidatesForIdentifier:name:)
    public func patientListCandidates(identifier: String?, name: String) -> [[String: Any]] {
        var predicates: [NSPredicate] = []
        if let identifier = PatientListLookup.identifier(identifier) {
            predicates.append(NSPredicate(format: "patientID ==[c] %@", identifier))
        }
        // The list may say "Given Family" where DICOM says "FAMILY^GIVEN".
        if let query = PatientListLookup.nameQuery(words: PatientListMatching.searchWords(name)),
           let predicate = patientsnamePredicate(query, soundex: false) {
            predicates.append(predicate)
        }
        guard !predicates.isEmpty, let database = self.database, let context = database.managedObjectContext else { return [] }

        var candidates: [[String: Any]] = []
        N2ManagedObjectContextPerformAndWait(context) {
            if let exception = BrowserObjC.attempt({
                let found = (database.objects(forEntity: database.studyEntity(),
                                              predicate: NSCompoundPredicate(orPredicateWithSubpredicates: predicates)) as NSArray?) ?? []
                let patients = NSMutableSet(), studies = NSMutableSet(array: found as? [Any] ?? [])
                for case let study as DicomStudy in found where ((study.patientUID as NSString?)?.length ?? 0) > 0 {
                    patients.add(study.patientUID as Any)
                }
                // The patient's other studies, as the browser gathers them.
                if patients.count > 0 {
                    studies.addObjects(from: (database.objects(forEntity: database.studyEntity(),
                                                               predicate: NSPredicate(format: "patientUID IN %@", patients)) as NSArray? as? [Any]) ?? [])
                }
                for case let study as DicomStudy in studies {
                    candidates.append(["objectID": study.objectID,
                                       "patientUID": study.patientUID ?? "",
                                       "patientID": study.patientID ?? "",
                                       "name": study.name ?? "",
                                       "dateOfBirth": study.dateOfBirth ?? NSNull(),
                                       "sex": study.patientSex ?? "",
                                       "date": study.date ?? NSNull()])
                }
            }) {
                BrowserObjC.log(exception, stack: true, "-[BrowserController patientListCandidatesForIdentifier:name:]")
            }
        }
        return candidates
    }

    /// Creates the album of the reviewed studies, under a name of its own,
    /// unless a study changed or went since the review.
    @objc(patientListCreateAlbumNamed:studies:expected:error:)
    public func patientListCreateAlbum(named name: String, studies studyIDs: [Any], expected: [[String: Any]]) throws -> String {
        var created: String?
        var problem: String?
        var album: DicomAlbum?
        if let database = self.database, let context = database.managedObjectContext {
            N2ManagedObjectContextPerformAndWait(context) {
                if let exception = BrowserObjC.attempt({
                    // What the user reviewed must still be what is stored: another
                    // import, a merge or an edit may have changed a study since.
                    var studies: [DicomStudy] = []
                    for (index, studyID) in studyIDs.enumerated() where problem == nil {
                        let study = (studyID as? NSManagedObjectID).flatMap { try? context.existingObject(with: $0) } as? DicomStudy
                        if let study { context.refresh(study, mergeChanges: true) }
                        let reviewed = index < expected.count ? expected[index] : nil
                        if let study, !study.isDeleted,
                           BrowserObjC.literallyEqual(study.patientID ?? "", reviewed?["patientID"] as? String ?? ""),
                           BrowserObjC.literallyEqual(study.name ?? "", reviewed?["name"] as? String ?? "") {
                            studies.append(study)
                        } else {
                            problem = NSLocalizedString("A study changed or was deleted after the list was reviewed. Review the list again.", comment: "")
                        }
                    }
                    guard problem == nil else { return }

                    let names = ((database.objects(forEntity: database.albumEntity()) as NSArray?)?.value(forKey: "name") as? [Any] ?? [])
                        .compactMap { $0 as? String }
                    let unique = AlbumNaming.uniqueName(for: name, existing: names)
                    let newAlbum = NSEntityDescription.insertNewObject(forEntityName: "Album", into: context) as? DicomAlbum
                    newAlbum?.name = unique
                    database.addStudies(studies, to: newAlbum)
                    _ = database.save()
                    album = newAlbum
                    created = unique
                }) {
                    BrowserObjC.log(exception, stack: true, "-[BrowserController patientListCreateAlbumNamed:studies:expected:error:]")
                    problem = exception.reason ?? NSLocalizedString("The album could not be saved.", comment: "")
                }
            }
        }
        guard let created else {
            throw NSError(domain: "HorosPatientListAlbum", code: 1, userInfo: [NSLocalizedDescriptionKey: problem ?? ""])
        }
        refreshAlbums()
        if let album {
            let index = ((albumArray() as NSArray?) ?? []).index(of: album)
            if index != NSNotFound {
                horos_albumTable?.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }
        }
        outlineViewRefresh()
        return created
    }

    /// The Query/Retrieve window on the patient: by identifier, else by name.
    @objc(patientListQueryPACSWithIdentifier:name:)
    public func patientListQueryPACS(identifier: String?, name: String) {
        if QueryController.current() == nil {
            // The controller keeps itself as the current one.
            _ = QueryController(autoQuery: false)
        }
        guard let query = QueryController.current() else { return }
        query.showWindow(self)
        if let identifier, (identifier as NSString).length > 0 {
            query.queryPatientID(identifier)
        } else if (name as NSString).length > 0 {
            query.queryPatientName(name)
        }
    }
}
