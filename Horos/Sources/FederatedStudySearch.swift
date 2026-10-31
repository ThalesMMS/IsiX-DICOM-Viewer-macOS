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
import IsiXPreferences

/// A search across the local databases the user has chosen, as the study list
/// and the web portal run it: the sources that may be asked, the studies of the
/// other databases that match the list's predicate, the names the list's
/// description gives the databases asked, and a study's name with the database
/// it comes from.
///
/// The catalogue, the opt-in flags and the identity rule are FederatedSearch's;
/// this type opens the other `DicomDatabase`s, and reads the preferences and
/// the default database of the source it is given. It holds no database and
/// may be made and used on any thread: off the main thread, the studies come
/// from a database private to that thread (a web connection's own one when
/// the portal asks).
struct FederatedStudySearch: Sendable {
    private let preferences: any PreferenceStore
    private let processGraph: ProcessGraph

    init(source: PreferencesSource) {
        self.preferences = source.preferences
        self.processGraph = source.processGraph
    }

    /// The extra local databases of the Sources list, as stored.
    private var localDatabasePaths: [[String: Any]]? {
        preferences.object(forKey: DatabasePreferences.localDatabaseSources.name) as? [[String: Any]]
    }

    /// Whether the default database is asked; it is until the user says no.
    private var includesDefaultDatabase: Bool {
        NetworkPreferences.isOn(NetworkPreferences.federatedSearchIncludesDefaultDatabase, in: preferences, whenAbsent: true)
    }

    /// The sources the user can opt into: the default database first, then
    /// the extra local databases, each with its path, name, choice and
    /// whether it is the default one.
    func sources() -> [[String: Any]] {
        let defaultDatabase = processGraph.defaultDatabase
        return FederatedSearch.sources(fromLocalDatabasePaths: localDatabasePaths, defaultPath: defaultDatabase?.baseDirPath,
                                       defaultName: defaultDatabase?.name, defaultIncluded: includesDefaultDatabase)
    }

    /// The names of the sources asked besides the database at `shownPath`, in
    /// the order of the sources; those without a name are left out.
    func includedSourceNames(besides shownPath: String?) -> [String] {
        sources().compactMap { source in
            guard (source["included"] as? NSNumber)?.boolValue ?? false,
                  FederatedSearch.pathsEqual(source["path"] as? String, shownPath) == false,
                  let name = source["name"] as? String, (name as NSString).length > 0 else { return nil }
            return name
        }
    }

    /// The studies of the sources asked, except the database at `excludedPath`,
    /// that match `predicate` and that `user` (a web portal user) may see:
    /// those its smart-album filter accepts, and those assigned to it. One
    /// patient's study is listed once per database; a source that cannot be
    /// opened or read is logged and skipped.
    func studies(matching predicate: NSPredicate, excludingDatabasePath excludedPath: String?, user: WebPortalUser?) -> [DicomStudy] {
        let included = FederatedSearch.includedPaths(fromLocalDatabasePaths: localDatabasePaths,
                                                     defaultPath: processGraph.defaultDatabase?.baseDirPath,
                                                     defaultIncluded: includesDefaultDatabase)
        var permission: NSPredicate?
        if let user, FederatedSearch.isUnrestrictedPermission(user.studyPredicate) == false {
            permission = DicomDatabase.predicate(forSmartAlbumFilter: user.studyPredicate)
        }

        var hits: [DicomStudy] = []
        // Keys compared code unit by code unit, as the set of strings did.
        var seen = Set<NSString>()
        for sourcePath in included where FederatedSearch.pathsEqual(sourcePath, excludedPath) == false {
            if let raised = HorosObjCException.caught({
                guard let database = DicomDatabase(atPath: sourcePath) else { return }
                // On a web connection's thread, its database of that path,
                // inside its queue; the studies go back to the connection.
                let reading: DicomDatabase? = Thread.isMainThread ? database
                    : (WebPortalConnection.threadFederatedDatabase(atPath: sourcePath)
                       ?? database.privateQueueIndependentDatabase() as? DicomDatabase)
                for case let study as DicomStudy in reading?.objects(forEntity: reading?.studyEntity(), predicate: predicate) ?? [] {
                    if let permission, permission.evaluate(with: study) == false, Self.isAssigned(study, to: user) == false {
                        continue
                    }
                    let key = FederatedSearch.identityKey(patientUID: study.patientUID, studyUID: study.studyInstanceUID,
                                                          originPath: database.baseDirPath) as NSString
                    if seen.insert(key).inserted {
                        hits.append(study)
                    }
                }
            }) {
                BrowserObjC.log(raised, stack: false, "+[BrowserController federatedStudiesMatchingPredicate:excludingDatabasePath:applyingUser:]")
            }
        }
        return hits
    }

    /// Whether `study` is one of the studies assigned to `user`: the same
    /// study of a patient whose identifier starts with the assigned one's.
    private static func isAssigned(_ study: DicomStudy, to user: WebPortalUser?) -> Bool {
        for case let assigned as WebPortalStudy in user?.studies ?? [] {
            if BrowserObjC.literallyEqual(assigned.studyInstanceUID, study.studyInstanceUID),
               let patientUID = study.patientUID, let assignedPatientUID = assigned.patientUID,
               (patientUID as NSString).range(of: assignedPatientUID, options: [.caseInsensitive, .diacriticInsensitive]).location == 0 {
                return true
            }
        }
        return false
    }

    /// A study's name as a federated list shows it: with the name of the
    /// database it comes from, when that is not `shown`, the database the
    /// list shows. Any other row keeps its name.
    @MainActor static func listName(_ name: Any?, of item: Any?, shown: DicomDatabase?) -> Any? {
        guard let object = item as? NSManagedObject, let shown,
              let origin = object.managedObjectContext.flatMap({ DicomDatabase(for: $0) }),
              origin !== shown,
              !BrowserObjC.literallyEqual(origin.baseDirPath, shown.baseDirPath),
              !FederatedSearch.pathsEqual(origin.baseDirPath, shown.baseDirPath) else { return name }
        return FederatedSearch.displayName(name as? String, origin: FederatedSearch.displayOrigin(name: origin.name, path: origin.baseDirPath),
                                           currentOrigin: shown.name)
    }
}
