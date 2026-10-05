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

import Cocoa
import AVFoundation
import CoreMedia
import Synchronization

// TODO: NSUserDefaults access for keys @"logWebServer", @"notificationsEmailsSender" and @"lastNotificationsDate" must be replaced with WebPortal properties

// The former static volatile ints. The loader threads decrement the first one
// while -generateMovie: polls it, so it is atomic here; the former
// @synchronized(self) around the increments and decrements is kept.
private let DCMPixLoadingThreads = Atomic<Int32>(0)
private let uniqueInc = Atomic<Int32>(1)
private let DCMPixLoadingLock = NSRecursiveLock()

// +tmpDirPath's former static: made, and its directory confirmed, on first use.
private let webServerTmpDirPath: String = {
    let path = (FileManager.default.tmpDirPath() as NSString).appendingPathComponent("WebServer")
    FileManager.default.confirmDirectory(atPath: path)
    return path
}()

private let GenerateMovieOutFileParamKey = "outFile"
private let GenerateMovieFileNameParamKey = "fileName"
private let GenerateMovieDicomImagesParamKey = "dicomImageArray"
//private let GenerateMovieIsIOSParamKey = "isiPhone"

private let TEXTHEIGHT: CGFloat = 15

private let WadoCacheSize = 1000 // __LP64__
private let WadoSOPInstanceUIDCacheSize = 5000
private let MAX_ThumbnailsCacheSize = 400

extension WebPortalConnection {

    @objc(tmpDirPath)
    class func tmpDirPath() -> String {
        return webServerTmpDirPath
    }

    @objc(MakeArray:)
    public class func makeArray(_ obj: Any?) -> NSArray {
        if let obj = obj, (obj as AnyObject).isKind(of: NSArray.self) {
            return unsafeDowncast(obj as AnyObject, to: NSArray.self)
        }

        guard let obj = obj else {
            return NSArray()
        }

        return NSArray(object: obj)
    }

    @objc(studyForStudyInstanceUID:server:)
    func studyForStudyInstanceUID(_ uid: NSString?, server ss: NSDictionary?) -> DicomStudy? {
        return raisingToCaller {
            var returnedStudy: DicomStudy? = nil

            objcTry({
                // First try to find it locally
                let db = self.independentDicomDatabase
                let r = NSFetchRequest<NSFetchRequestResult>(entityName: "Study")
                r.predicate = NSPredicate(format: "(studyInstanceUID == %@)", objcArg(uid))

                var studyArray: NSArray? = nil
                objcTry({
                    studyArray = (try? db?.managedObjectContext.fetch(r)) as NSArray?
                }, catch: { e in _N2LogExceptionImpl(e, true, "-[WebPortalConnection(Data) studyForStudyInstanceUID:server:]") })

                if (studyArray?.count ?? 0) > 1 {
                    NSLog("****** WADO Server : more than 1 study with same uid : %d", Int32(truncatingIfNeeded: studyArray?.count ?? 0))
                }

                if (studyArray?.count ?? 0) > 0 {
                    // return [studyArray lastObject], from inside the @try
                    returnedStudy = studyArray?.lastObject as? DicomStudy
                    return
                }

                // Find it on a distant server

                var studies: [Any]? = nil

                if let ss = ss {
                    studies = QueryController.queryStudyInstanceUID(uid as String?, server: ss as? [AnyHashable: Any], showErrors: false)
                } else {
                    studies = QueryController.queryStudies(forFilters: objcDictionary([(uid, "StudyInstanceUID")]) as? [AnyHashable: Any], servers: BrowserController.comparativeServers(), showErrors: false) as? [Any]
                }

                if let studies = studies, studies.count > 0 {
                    QueryController.retrieveStudies(studies, showErrors: false, checkForPreviousAutoRetrieve: true)

                    let dateStart = Date.timeIntervalSinceReferenceDate
                    var lastNumberOfImages = 0, currentNumberOfImages = 0
                    studyArray = nil

                    repeat {
                        var s = studyArray?.lastObject as? DicomStudy
                        lastNumberOfImages = s.map { objcSetCount($0, "images") } ?? 0
                        let db = self.independentDicomDatabase
                        Thread.sleep(forTimeInterval: 0.1)

//                        [[DicomDatabase activeLocalDatabase] initiateImportFilesFromIncomingDirUnlessAlreadyImporting];
//                        [NSThread sleepForTimeInterval: 0.3];
                        db?.importFilesFromIncomingDir()

                        // And find the study locally
                        let r = NSFetchRequest<NSFetchRequestResult>(entityName: "Study")
                        r.predicate = NSPredicate(format: "(studyInstanceUID == %@)", objcArg(uid))

                        objcTry({
                            studyArray = (try? db?.managedObjectContext.fetch(r)) as NSArray?
                        }, catch: { e in _N2LogExceptionImpl(e, true, "-[WebPortalConnection(Data) studyForStudyInstanceUID:server:]") })

                        s = studyArray?.lastObject as? DicomStudy
                        returnedStudy = s
                        currentNumberOfImages = s.map { objcSetCount($0, "images") } ?? 0
                    }
                    while ((studyArray?.count ?? 0) == 0 || lastNumberOfImages != currentNumberOfImages) && Date.timeIntervalSinceReferenceDate - dateStart < 20

                    if (studyArray?.count ?? 0) == 0 {
                        HorosWebPortalDataLogStackTrace("---- failed to retrieve distant study")
                    }
                }
                else {
                    HorosWebPortalDataLogStackTrace("---- study uid NOT found on distant servers")
                }
            }, catch: { e in
                _N2LogExceptionImpl(e, false, "-[WebPortalConnection(Data) studyForStudyInstanceUID:server:]")
            })

            return returnedStudy
        }
    }

    @objc(federatedUser:mayAccessStudy:)
    func federatedUser(_ user: WebPortalUser?, mayAccessStudy study: DicomStudy?) -> Bool {
        return raisingToCaller {
            if user == nil || FederatedSearch.isUnrestrictedPermission(user?.studyPredicate) {
                return true
            }
            let permission = DicomDatabase.predicate(forSmartAlbumFilter: user?.studyPredicate)
            if let permission = permission, permission.evaluate(with: study) {
                return true
            }
            for specific in objcSet(user!, "studies") {
                let specific = unsafeDowncast(specific as AnyObject, to: WebPortalStudy.self)
                if objcIsEqualToString(specific.studyInstanceUID, study?.studyInstanceUID)
                    && study?.patientUID != nil
                    && specific.patientUID != nil
                    && (study!.patientUID! as NSString).range(of: specific.patientUID!, options: [.caseInsensitive, .diacriticInsensitive]).location == 0 {
                    return true
                }
            }
            return false
        }
    }

    @objc(objectWithXID:)
    func objectWithXID(_ xid: NSString?) -> Any? {
        return raisingToCaller { () -> Any? in
            var o: NSManagedObject? = nil
            let user = self.user

            if FederatedSearch.isFederatedXID(xid as String?) {
                let origin = FederatedSearch.originPath(fromFederatedXID: xid as String?)
                let studyXID = FederatedSearch.studyXID(fromFederatedXID: xid as String?)
                // The origin comes from the request: only a database the federated search
                // includes may be opened, never an arbitrary path (#760).
                let localDatabasePaths = UserDefaults.standard.object(forKey: "localDatabasePaths") as? [[String: Any]]
                if !FederatedSearch.isPath(origin, includedIn: localDatabasePaths,
                                           defaultPath: DicomDatabase.default()?.baseDirPath,
                                           defaultIncluded: FederatedSearch.isDefaultDatabaseIncluded) {
                    return nil
                }
                if let origin = origin, (origin as NSString).length > 0, let studyXID = studyXID, (studyXID as NSString).length > 0 {
                    // The connection's database of that origin, inside its queue (#966).
                    let idb = WebPortalConnection.threadFederatedDatabase(atPath: origin) ?? DicomDatabase(atPath: origin)
                    o = idb?.object(withID: NSManagedObject.uid(forXid: studyXID)) as? NSManagedObject
                    if user != nil, let study = o as? DicomStudy, self.federatedUser(user, mayAccessStudy: study) == false {
                        return nil
                    }
                    if user != nil, let series = o as? DicomSeries, self.federatedUser(user, mayAccessStudy: series.study) == false {
                        return nil
                    }
                    if user != nil, let image = o as? DicomImage, self.federatedUser(user, mayAccessStudy: image.series?.study) == false {
                        return nil
                    }
                }
                return o
            }

            if xid?.hasPrefix("POD:") ?? false { // PACS On Demand object
                let axid = xid!.components(separatedBy: ":") as NSArray

                if axid.count == 5 {
                    // Example: POD:172.18.1.5:4096:STUDY:2.16.840.1.113669.632.20.121711.10000370559

                    //Find the server, and retrieve the object(s)

                    let serversArray = UserDefaults.standard.array(forKey: "SERVERS") as NSArray?
                    var s: NSDictionary? = nil

                    for aServer in serversArray ?? NSArray() {
                        let aServer = unsafeDowncast(aServer as AnyObject, to: NSDictionary.self)
                        if objcBoolValue(aServer.object(forKey: "Activated"))
                            && objcIsEqualToString(objcString(aServer.object(forKey: "Address")), axid.object(at: 1) as? NSString)
                            && objcIntValue(aServer.object(forKey: "Port")) == objcIntValue(axid.object(at: 2)) {
                            s = aServer
                            break
                        }
                    }

                    if let s = s {
                        if objcIsEqualToString(axid.object(at: 3) as? NSString, "STUDY") {
                            o = self.studyForStudyInstanceUID(axid.object(at: 4) as? NSString, server: s)
                        } else {
                            HorosWebPortalDataLogStackTrace("**** XID POD at non-study level??")
                        }
                    }
                }
            }
            else {
                let axid = (xid?.components(separatedBy: "/") as NSArray?) ?? NSArray()

                if axid.count != 3 {
                    HorosWebPortalDataLogStackTrace("****** ERROR: unexpected CoreData ID format, please contact dev team")
                    return nil
                }

                let axidEntityName = axid.object(at: 1) as? NSString

                var db: N2ManagedDatabase? = nil
                if objcIsEqualToString(axidEntityName, "User") {
                    db = self.independentWebDatabase
                } else {
                    db = self.independentDicomDatabase
                }

                o = db?.object(withID: NSManagedObject.uid(forXid: xid as String?)) as? NSManagedObject
            }

            // ensure that the user is allowed to access this object
            if user != nil, let o = o, o.isKind(of: DicomStudy.self) || o.isKind(of: DicomSeries.self) { // Too slow to check for DicomImage
                var s: DicomStudy? = nil

                if o.isKind(of: DicomStudy.self) {
                    s = unsafeDowncast(o, to: DicomStudy.self)
                }

                if o.isKind(of: DicomSeries.self) {
                    let series = unsafeDowncast(o, to: DicomSeries.self)
                    s = series.study
                }

                if o.isKind(of: DicomImage.self) {
                    let image = unsafeDowncast(o, to: DicomImage.self)
                    s = image.series?.study
                }

                let studies = WebPortalUser.studies(for: user, predicate: NSPredicate(format: "patientUID BEGINSWITH[cd] %@", objcArg(s?.patientUID))) as NSArray?

                if (studies?.filtered(using: NSPredicate(format: "studyInstanceUID == %@", objcArg(s?.studyInstanceUID))).count ?? 0) == 0 {
                    NSLog("**** study not found for this user (%@) : %@", objcArg(user), objcArg(s))
                    return nil
                }
            }

            // Distant study with more images?
            if let o = o, o.isKind(of: DicomStudy.self), UserDefaults.standard.bool(forKey: "searchForComparativeStudiesOnDICOMNodes"), UserDefaults.standard.bool(forKey: "automaticallyRetrievePartialStudies") {
                // Servers
                let servers = BrowserController.comparativeServers() as NSArray?
                let localStudy = unsafeDowncast(o, to: DicomStudy.self)

                if (servers?.count ?? 0) > 0 {
                    // Distant study
                    let distantStudy = (QueryController.queryStudies(forFilters: objcDictionary([(o.value(forKey: "studyInstanceUID"), "StudyInstanceUID")]) as? [AnyHashable: Any], servers: servers as? [Any], showErrors: false))?.lastObject as AnyObject?

                    if objcIntValue(localStudy.rawNoFiles()) < objcIntValue(objcSend(distantStudy, "noFiles")) {
                        QueryController.retrieveStudies(objcArrayWithObject(distantStudy) as? [Any], showErrors: false, checkForPreviousAutoRetrieve: true)

                        let dateStart = Date.timeIntervalSinceReferenceDate
                        var lastNumberOfImages = 0, currentNumberOfImages = 0
                        repeat {
                            let s = localStudy

                            lastNumberOfImages = objcSetCount(s, "images")
                            Thread.sleep(forTimeInterval: 0.1)

//                            [[DicomDatabase activeLocalDatabase] initiateImportFilesFromIncomingDirUnlessAlreadyImporting];
//                            [NSThread sleepForTimeInterval: 0.3];

                            if let importer = DicomDatabase.activeLocal()?.privateQueueIndependentDatabase() as? DicomDatabase {
                                importer.performBlockAndWait { _ = importer.importFilesFromIncomingDir() }
                            }

                            s.managedObjectContext?.refresh(s, mergeChanges: false)

                            currentNumberOfImages = objcSetCount(s, "images")
                        }
                        while Date.timeIntervalSinceReferenceDate - dateStart < 10 && lastNumberOfImages != currentNumberOfImages
                    }
                }
            }

            return o
        }
    }

    /// Whether the request names an album the database does not have: the
    /// study list answers 404 for it, where it failed with a 500 (#761).
    private func studyList_requestsUnknownAlbum() -> Bool {
        guard let name = self.stringParameter("album") as String?, !name.isEmpty else { return false }
        let albums = (self.independentDicomDatabase?.albums() as NSArray?) ?? NSArray()
        return !albums.contains { (($0 as? NSObject)?.value(forKey: "name") as? String) == name }
    }

    @objc(studyList_requestedStudies:)
    func studyList_requestedStudies(_ title: AutoreleasingUnsafeMutablePointer<NSString?>?) -> NSArray? {
        return raisingToCaller { () -> NSArray? in
            var ignore: NSString? = nil
            var result: NSArray? = nil
            let fetchLimitPerPage = Int32(truncatingIfNeeded: UserDefaults.standard.integer(forKey: "FetchLimitForWebPortal"))
            var numberOfStudies: Int32 = 0
            let page = objcIntValue(self.parameter("page"))
            let user = self.user

            // if (!title) title = &ignore;
            func setTitle(_ value: String) {
                if let title = title { title.pointee = value as NSString } else { ignore = value as NSString }
            }

            if let sortKey = self.parameter("sortKey") {
                if ((self.portal?.dicomDatabase?.entity(forName: "Study")?.attributesByName as NSDictionary?)?.object(forKey: sortKey)) != nil {
                    self.session?.setObject(sortKey, forKey: "StudiesSortKey")
                }
            }

            if self.session?.object(forKey: "StudiesSortKey") == nil {
                self.session?.setObject(HorosWebPortalDataLiteral("date"), forKey: "StudiesSortKey")
            }

            let albumReq = self.stringParameter("album")
            if (albumReq?.length ?? 0) > 0 {
                setTitle(String(format: NSLocalizedString("Album: %@", comment: "Web portal, study list, title format (%@ is album name)"), objcArg(albumReq)))
                result = WebPortalUser.studies(for: user, album: albumReq as String?, sortBy: self.session?.object(forKey: "StudiesSortKey") as? String, fetchLimit: fetchLimitPerPage, fetchOffset: page &* fetchLimitPerPage, numberOfStudies: &numberOfStudies) as NSArray?
            }
            else {
                let browseReq = self.stringParameter("browse")
                let browseParameterReq = self.stringParameter("browseParameter")
                let PODFilter = NSMutableDictionary()
                var browsePredicate: NSPredicate? = nil

                if objcIsEqualToString(browseReq, "newAddedStudies") && (browseParameterReq?.doubleValue ?? 0) > 0 {
                    setTitle(NSLocalizedString("New Studies", comment: "Web portal, study list, title"))
                    browsePredicate = NSPredicate(format: "dateAdded >= CAST(%lf, \"NSDate\")", browseParameterReq?.doubleValue ?? 0)

                    // No equivalence in PACS On Demand
                }
                else if objcIsEqualToString(browseReq, "today") {
                    setTitle(NSLocalizedString("Today", comment: "Web portal, study list, title"))
                    let ti = StartOfDay(calendarDateNow())
                    browsePredicate = NSPredicate(format: "date >= CAST(%lf, \"NSDate\")", ti)

                    PODFilter.setObject(NSNumber(value: Int32(after)), forKey: "date" as NSString)
                    PODFilter.setObject(Date(timeIntervalSinceReferenceDate: ti), forKey: "fromDate" as NSString)
                }
                else if objcIsEqualToString(browseReq, "6hours") {
                    setTitle(NSLocalizedString("Last 6 Hours", comment: "Web portal, study list, title"))
                    let now = calendarDateNow()
                    let ti = HorosWebPortalDataCalendarDate(now.year, UInt(bitPattern: now.month), UInt(bitPattern: now.day), UInt(bitPattern: now.hour &- 6), UInt(bitPattern: now.minute), UInt(bitPattern: now.second))?.timeIntervalSinceReferenceDate ?? 0
                    browsePredicate = NSPredicate(format: "date >= CAST(%lf, \"NSDate\")", ti)

                    PODFilter.setObject(NSNumber(value: Int32(after)), forKey: "date" as NSString)
                    PODFilter.setObject(Date(timeIntervalSinceReferenceDate: ti), forKey: "fromDate" as NSString)
                }
                else if self.parameter("search") != nil {
                    setTitle(NSLocalizedString("Search Results", comment: "Web portal, study list, title"))

                    let search = NSMutableString()
                    var searchString = self.stringParameter("search")!

                    let components = searchString.components(separatedBy: " ")
                    let newComponents = NSMutableArray()
                    for comp in components {
                        if !(comp as NSString).isEqual(to: "") {
                            newComponents.add(comp)
                        }
                    }

                    searchString = newComponents.componentsJoined(by: " ") as NSString
                    searchString = searchString.replacingOccurrences(of: "\"", with: "\'") as NSString
                    searchString = searchString.replacingOccurrences(of: "\'", with: "\\'") as NSString
                    searchString = searchString.replacingOccurrences(of: ", ", with: " ") as NSString
                    searchString = searchString.replacingOccurrences(of: ",", with: " ") as NSString

                    search.append(String(format: "name BEGINSWITH[cd] '%@'", searchString)) // [c] is for 'case INsensitive' and [d] is to ignore accents (diacritic)

                    if searchString.length >= 2 {
                        PODFilter.setObject(searchString.appending("*"), forKey: "PatientsName" as NSString)
                    }

                    //

                    browsePredicate = BrowserController.currentBrowser()?.patientsnamePredicate(self.stringParameter("search") as String?, soundex: false)
                }
                else if self.parameter("searchID") != nil {
                    setTitle(NSLocalizedString("Search Results", comment: "Web portal, study list, title"))
                    let search = NSMutableString()
                    var searchString = NSString(string: self.stringParameter("searchID")! as String)

                    let components = searchString.components(separatedBy: " ")
                    let newComponents = NSMutableArray()
                    for comp in components {
                        if !(comp as NSString).isEqual(to: "") {
                            newComponents.add(comp)
                        }
                    }

                    searchString = newComponents.componentsJoined(by: " ") as NSString

                    search.append(String(format: "patientID BEGINSWITH[cd] '%@'", searchString)) // [c] is for 'case INsensitive' and [d] is to ignore accents (diacritic)
                    browsePredicate = NSPredicate(format: search as String, argumentArray: nil)

                    if searchString.length >= 2 {
                        PODFilter.setObject(searchString.appending("*"), forKey: "PatientID" as NSString)
                    }
                }
                else if self.parameter("searchAccessionNumber") != nil {
                    setTitle(NSLocalizedString("Search Results", comment: "Web portal, study list, title"))
                    let search = NSMutableString()
                    var searchString = NSString(string: self.stringParameter("searchAccessionNumber")! as String)

                    let components = searchString.components(separatedBy: " ")
                    let newComponents = NSMutableArray()
                    for comp in components {
                        if !(comp as NSString).isEqual(to: "") {
                            newComponents.add(comp)
                        }
                    }

                    searchString = newComponents.componentsJoined(by: " ") as NSString

                    search.append(String(format: "accessionNumber BEGINSWITH[cd] '%@'", searchString)) // [c] is for 'case INsensitive' and [d] is to ignore accents (diacritic)
                    browsePredicate = NSPredicate(format: search as String, argumentArray: nil)

                    if searchString.length >= 2 {
                        PODFilter.setObject(searchString.appending("*"), forKey: "AccessionNumber" as NSString)
                    }
                }

                if browsePredicate == nil {
                    setTitle(NSLocalizedString("Study List", comment: "Web portal, study list, title"))
                    //browsePredicate = [NSPredicate predicateWithValue:YES];
                }

                result = WebPortalUser.studies(for: user, predicate: browsePredicate, sortBy: nil, fetchLimit: 0, fetchOffset: 0, numberOfStudies: nil) as NSArray? // Sort and FetchLimit is applied AFTER PACS On Demand

                // PACS On Demand
                var pred = user?.studyPredicate?.uppercased() as NSString?
                pred = pred?.replacingOccurrences(of: " ", with: "") as NSString?
                pred = pred?.replacingOccurrences(of: "(", with: "") as NSString?
                pred = pred?.replacingOccurrences(of: ")", with: "") as NSString?
                if user == nil || (pred?.length ?? 0) == 0 || objcIsEqualToString(pred, "YES==YES") {
                    if PODFilter.count >= 1 && UserDefaults.standard.bool(forKey: "searchForComparativeStudiesOnDICOMNodes") && UserDefaults.standard.bool(forKey: "ActivatePACSOnDemandForWebPortalSearch") {
//                        BOOL usePatientID = [[NSUserDefaults standardUserDefaults] boolForKey: @"UsePatientIDForUID"];
//                        BOOL usePatientBirthDate = [[NSUserDefaults standardUserDefaults] boolForKey: @"UsePatientBirthDateForUID"];
//                        BOOL usePatientName = [[NSUserDefaults standardUserDefaults] boolForKey: @"UsePatientNameForUID"];

                        // Servers
                        let servers = BrowserController.comparativeServers() as NSArray?

                        if (servers?.count ?? 0) > 0 {
                            var distantStudies = QueryController.queryStudies(forFilters: PODFilter as? [AnyHashable: Any], servers: servers as? [Any], showErrors: false) as NSArray?

                            if (objcString(PODFilter.value(forKey: "PatientsName"))?.components(separatedBy: " ").count ?? 0) > 1 { // For patient name, if several components, try with ^ separator, and add missing results
                                let s = objcString(PODFilter.value(forKey: "PatientsName"))!

                                // replace last occurence // fan siu hung
                                PODFilter.setValue(s.replacingCharacters(in: s.range(of: " ", options: .backwards), with: "^"), forKey: "PatientsName")

                                let subResult = QueryController.queryStudies(forFilters: PODFilter as? [AnyHashable: Any], servers: servers as? [Any], showErrors: false) as NSArray?

                                let resultUIDs = distantStudies?.value(forKey: "uid") as? NSArray

                                for n in subResult ?? NSArray() {
                                    let uid = objcSend(n as AnyObject, "uid")
                                    if !((uid != nil && (resultUIDs?.contains(uid!) ?? false))) {
                                        distantStudies = distantStudies.map { NSArray(array: $0.adding(n)) }
                                    }
                                }
                            }

                            if (distantStudies?.count ?? 0) > 0 {
                                let mutableStudiesArray = NSMutableArray(array: (result as? [Any]) ?? [])

                                // Merge local and distant studies
                                for distantStudy in distantStudies! {
                                    let distantStudy = distantStudy as AnyObject
                                    let distantUID = objcSend(distantStudy, "studyInstanceUID")
                                    if !(distantUID != nil && ((mutableStudiesArray.value(forKey: "studyInstanceUID") as? NSArray)?.contains(distantUID!) ?? false)) {
                                        mutableStudiesArray.add(distantStudy)
                                    }

                                    else if UserDefaults.standard.bool(forKey: "preferStudyWithMoreImages") {
                                        let index = (mutableStudiesArray.value(forKey: "studyInstanceUID") as? NSArray)?.index(of: distantUID!) ?? NSNotFound

                                        if index != NSNotFound && objcIntValue(objcSend(mutableStudiesArray.object(at: index) as AnyObject, "rawNoFiles")) < objcIntValue(objcSend(distantStudy, "noFiles")) {
                                            mutableStudiesArray.replaceObject(at: index, with: distantStudy)
                                        }
                                    }
                                }

                                result = mutableStudiesArray
                            }
                        }
                    }
                }

                if (self.parameter("search") != nil || self.parameter("searchID") != nil || self.parameter("searchAccessionNumber") != nil) && browsePredicate != nil {
                    let federated = BrowserController.federatedStudies(matching: browsePredicate,
                                                                       excludingDatabasePath: self.independentDicomDatabase?.baseDirPath,
                                                                       applyingUser: user) as NSArray?
                    if (federated?.count ?? 0) > 0 {
                        let merged = NSMutableArray(array: (result as? [Any]) ?? [])
                        let seen = NSMutableSet()
                        for study in merged {
                            let study = study as AnyObject
                            let origin: DicomDatabase? = study.isKind(of: NSManagedObject.self) ? DicomDatabase(for: unsafeDowncast(study, to: NSManagedObject.self).managedObjectContext) : nil
                            let key = FederatedSearch.identityKey(patientUID: study.value(forKey: "patientUID") as? String,
                                                                  studyUID: study.value(forKey: "studyInstanceUID") as? String,
                                                                  originPath: origin?.baseDirPath ?? self.independentDicomDatabase?.baseDirPath)
                            seen.add(key)
                        }
                        for study in federated! {
                            let study = study as AnyObject
                            let origin = DicomDatabase(for: unsafeDowncast(study, to: NSManagedObject.self).managedObjectContext)
                            let key = FederatedSearch.identityKey(patientUID: study.value(forKey: "patientUID") as? String,
                                                                  studyUID: study.value(forKey: "studyInstanceUID") as? String,
                                                                  originPath: origin?.baseDirPath)
                            if seen.contains(key) == false {
                                merged.add(study)
                                seen.add(key)
                            }
                        }
                        result = merged
                    }
                }

                let sortValue = self.session?.object(forKey: "StudiesSortKey") as? NSString

                if (sortValue?.length ?? 0) > 0 {
                    if sortValue!.range(of: "date").location == NSNotFound {
                        result = result?.sortedArray(using: [NSSortDescriptor(key: sortValue! as String, ascending: true, selector: #selector(NSString.caseInsensitiveCompare(_:)))]) as NSArray?
                    } else {
                        result = result?.sortedArray(using: [NSSortDescriptor(key: sortValue! as String, ascending: false)]) as NSArray?
                    }
                }

                numberOfStudies = Int32(truncatingIfNeeded: result?.count ?? 0)

                if fetchLimitPerPage != 0 {
                    // NSMakeRange(page*fetchLimitPerPage, fetchLimitPerPage), in NSUInteger
                    var location = UInt(bitPattern: Int(page &* fetchLimitPerPage))
                    var length = UInt(bitPattern: Int(fetchLimitPerPage))
                    let count = UInt(result?.count ?? 0)

                    if location > count {
                        location = count
                    }

                    if location &+ length > count {
                        length = count &- location
                    }

                    result = result?.subarray(with: NSRange(location: Int(bitPattern: location), length: Int(bitPattern: length))) as NSArray?
                }
            }

            if let pageParameter = self.parameter("page") {
                self.session?.setObject(pageParameter, forKey: "Page")
            } else {
                self.session?.setObject(NSNumber(value: Int32(0)), forKey: "Page")
            }

            self.session?.setObject(NSNumber(value: numberOfStudies), forKey: "NumberOfStudies")

            if cRemainder(numberOfStudies, fetchLimitPerPage) == 0 {
                self.session?.setObject(NSNumber(value: cQuotient(numberOfStudies, fetchLimitPerPage)), forKey: "NumberOfPages")
            } else {
                self.session?.setObject(NSNumber(value: 1 &+ cQuotient(numberOfStudies, fetchLimitPerPage)), forKey: "NumberOfPages")
            }

            self.session?.setObject(NSNumber(value: fetchLimitPerPage), forKey: "FetchLimitPerPage")

            _ = ignore
            return result
        }
    }

    @objc(sendImages:toDicomNode:)
    func sendImages(_ images: NSArray?, toDicomNode dicomNodeDescription: NSDictionary?) {
        raisingToCaller {
            self.portal?.updateLogEntry(forStudy: (images?.lastObject as AnyObject?)?.value(forKeyPath: "series.study") as? NSManagedObject, withMessage: String(format: "DICOM Send to: %@", objcArg(dicomNodeDescription?.object(forKey: "Address"))), forUser: self.user?.name, ip: self.asyncSocket?.connectedHost())

            objcTry({
                let todo = objcDictionary([(dicomNodeDescription?.object(forKey: "Address"), "Address"), (dicomNodeDescription?.object(forKey: "TransferSyntax"), "TransferSyntax"), (dicomNodeDescription?.object(forKey: "Port"), "Port"), (dicomNodeDescription?.object(forKey: "AETitle"), "AETitle"), (images?.value(forKey: "completePath"), "Files")])
                Thread.detachNewThreadSelector(#selector(self.sendImagesToDicomNodeThread(_:)), toTarget: self, with: todo)
            }, catch: { e in
                NSLog("Error: [WebPortalConnection sendImages:toDicomNode:] %@", e)
            })
        }
    }

    @objc(sendImagesToDicomNodeThread:)
    func sendImagesToDicomNodeThread(_ todo: NSDictionary?) {
        raisingToCaller {
            autoreleasepool {
                objcTry({
                    DCMTKStoreSCU(callingAET: UserDefaults.defaultAETitle(),
                                  calledAET: objcString(todo?.object(forKey: "AETitle")) as String?,
                                  hostname: objcString(todo?.object(forKey: "Address")) as String?,
                                  port: objcIntValue(todo?.object(forKey: "Port")),
                                  filesToSend: todo?.value(forKey: "Files") as? [Any],
                                  transferSyntax: objcIntValue(todo?.object(forKey: "TransferSyntax")),
                                  compression: 1.0,
                                  extraParameters: objcDictionaryWithObject(NSDictionary.self, self.portal?.dicomDatabase, forKey: "DicomDatabase") as? [AnyHashable: Any])?.run(nil)
                }, catch: { e in
                    NSLog("Error: [WebServiceConnection sendImagesToDicomNodeThread:] %@", e)
                })
            }
        }
    }

    @objc(getWidth:height:fromImagesArray:)
    public func getWidth(_ width: UnsafeMutablePointer<CGFloat>?, height: UnsafeMutablePointer<CGFloat>?, fromImagesArray images: NSArray?) {
        raisingToCaller {
            if (images?.count ?? 0) > 4 {
                self.getWidth(width, height: height, fromImagesArray: images, minSize: objcMakeSize(CGFloat(UserDefaults.standard.float(forKey: "WebServerMinWidthForMovie"))), maxSize: objcMakeSize(CGFloat(UserDefaults.standard.float(forKey: "WebServerMaxWidthForMovie"))))
            } else {
                self.getWidth(width, height: height, fromImagesArray: images, minSize: objcMakeSize(CGFloat(UserDefaults.standard.float(forKey: "WebServerMinWidthForMovie"))), maxSize: objcMakeSize(CGFloat(UserDefaults.standard.float(forKey: "WebServerMaxWidthForStillImage"))))
            }
        }
    }

    @objc(getWidth:height:fromImagesArray:minSize:maxSize:)
    public func getWidth(_ width: UnsafeMutablePointer<CGFloat>?, height: UnsafeMutablePointer<CGFloat>?, fromImagesArray imagesArray: NSArray?, minSize: NSSize, maxSize: NSSize) {
        raisingToCaller {
            let width = width!, height = height!
            width.pointee = 0
            height.pointee = 0

            for im in (imagesArray?.value(forKey: "width") as? NSArray) ?? NSArray() {
                if CGFloat(objcNumber(im).int32Value) > width.pointee { width.pointee = CGFloat(objcNumber(im).int32Value) }
            }
            for im in (imagesArray?.value(forKey: "height") as? NSArray) ?? NSArray() {
                if CGFloat(objcNumber(im).int32Value) > height.pointee { height.pointee = CGFloat(objcNumber(im).int32Value) }
            }

            if width.pointee > maxSize.width {
                height.pointee *= maxSize.width / width.pointee
                width.pointee = maxSize.width
            }

            if height.pointee > maxSize.height {
                width.pointee *= maxSize.height / height.pointee
                height.pointee = maxSize.height
            }

            if width.pointee < minSize.width {
                height.pointee *= minSize.width / width.pointee
                width.pointee = minSize.width
            }

            if height.pointee < minSize.height {
                width.pointee *= minSize.height / height.pointee
                height.pointee = minSize.height
            }
        }
    }

    @objc(drawText:atLocation:)
    func drawText(_ text: NSString?, atLocation loc: NSPoint) {
        raisingToCaller {
            var loc = loc
            text?.draw(at: loc, withAttributes: [.foregroundColor: NSColor.black])

            loc.x += 1
            loc.y += 1

            text?.draw(at: loc, withAttributes: [.foregroundColor: NSColor.white])
        }
    }

    @objc(movieDCMPixLoad:)
    func movieDCMPixLoad(_ dict: NSDictionary?) {
        raisingToCaller {
            autoreleasepool {
                // A database of this thread, read inside its queue (#966).
                let idd = self.portal?.dicomDatabase?.privateQueueIndependentDatabase() as? DicomDatabase
                N2ManagedObjectContextPerformAndWait(idd?.managedObjectContext) {
                let dicomImageArray = idd?.objects(withIDs: dict?.value(forKey: "DicomImageArray") as? [Any]) as NSArray?

                let location = Int32(bitPattern: objcNumber(dict?.value(forKey: "location")).uint32Value)
                let length = Int32(bitPattern: objcNumber(dict?.value(forKey: "length")).uint32Value)
                let width = cInt32(Double(objcNumber(dict?.value(forKey: "width")).floatValue))
                let height = cInt32(Double(objcNumber(dict?.value(forKey: "height")).floatValue))
                let fileName = dict?.value(forKey: "fileName") as? NSString
                let fpsP = (dict?.value(forKey: "fpsP") as? NSValue)?.pointerValue?.assumingMemoryBound(to: Int.self)

                let series = (dicomImageArray?.lastObject as? DicomImage)?.series
                let allImages = series?.sortedImages() as NSArray?
                let totalImages = Int32(truncatingIfNeeded: series.map { objcSetCount($0, "images") } ?? 0)

                var x = location
                while x < location &+ length {
                    autoreleasepool {
                        // Outside the @try, as it was: an index past the array raises to the thread.
                        let im = (dicomImageArray?.object(at: Int(x)) as AnyObject?).map { unsafeDowncast($0, to: DicomImage.self) }

                        objcTry({
                            var dcmPix = DCMPix(path: im?.completePathResolved(), 0, 1, nil, Int(im?.frameID?.int32Value ?? 0), Int(im?.series?.id?.int32Value ?? 0), isBonjour: false, imageObj: im)

                            if let dcmPix = dcmPix {
                                var curWW: Float = 0
                                var curWL: Float = 0

                                if im?.series?.windowWidth != nil {
                                    curWW = im?.series?.windowWidth?.floatValue ?? 0
                                    curWL = im?.series?.windowLevel?.floatValue ?? 0
                                }

                                if curWW != 0 {
                                    dcmPix.checkImageAvailble(curWW, curWL)
                                } else {
                                    dcmPix.checkImageAvailble(dcmPix.savedWW, dcmPix.savedWL)
                                }

                                if x == 0 && dcmPix.cineRate() != 0 {
                                    fpsP?.pointee = cInt(Double(dcmPix.cineRate()))
                                }
                            }
                            else {
                                NSLog("****** dcmPix creation failed for file : %@", objcArg(im?.value(forKey: "completePathResolved")))

                                let count = Int(width &* height)
                                let imPtr = malloc(count &* MemoryLayout<Float>.size)!.assumingMemoryBound(to: Float.self)
                                var i = 0
                                while i < count {
                                    imPtr[i] = Float(i)
                                    i += 1
                                }

                                dcmPix = DCMPix(data: imPtr, 32, Int(width), Int(height), 0, 0, 0, 0, 0)
                            }

                            var newImage: NSImage?

                            if ((dcmPix?.pwidth ?? 0) != Int(width) || (dcmPix?.pheight ?? 0) != Int(height)) && (dcmPix?.pheight ?? 0) > 0 && (dcmPix?.pwidth ?? 0) > 0 && width > 0 && height > 0 {
                                newImage = dcmPix?.image()?.imageByScalingProportionally(toSize: NSMakeSize(CGFloat(width), CGFloat(height)))
                            } else {
                                newImage = dcmPix?.image()
                            }

                            // The frame number is drawn over the frame in the frame's own
                            // colour space: an image made by a drawing handler is rendered in
                            // the screen's, which moves the grey levels of the window.
                            var numbered: NSBitmapImageRep?
                            if let source = newImage {
                                let index = allImages == nil ? 0 : (im.map { allImages!.index(of: $0) } ?? NSNotFound)
                                let text = String(format: "%d / %d", Int32(truncatingIfNeeded: index &+ 1), totalImages) as NSString
                                numbered = source.horosBitmapInOwnColorSpace { bounds in
                                    self.drawText(text, atLocation: NSMakePoint(1, bounds.height - TEXTHEIGHT))
                                }
                            }

                            let dir = objcAppending(fileName, " dir")
                            if let tiff = numbered?.tiffRepresentation(using: .lzw, factor: 1.0) ?? newImage?.tiffRepresentation(using: .lzw, factor: 1.0),
                               let path = objcAppendingPathComponent(dir, String(format: "%6.6d.tiff", x)) {
                                (tiff as NSData).write(toFile: path as String, atomically: true)
                            }
                        }, catch: { e in
                            _N2LogExceptionImpl(e, true, "-[WebPortalConnection(Data) movieDCMPixLoad:]")
                        })
                    }
                    x = x &+ 1
                }
                }

                objcSynchronized(self) {
                    DCMPixLoadingThreads.subtract(1, ordering: .sequentiallyConsistent)
                }
            }
        }
    }

    @objc(generateMovie:)
    func generateMovie(_ dict: NSMutableDictionary?) {
        raisingToCaller {
            autoreleasepool {
                let outFile = dict?.object(forKey: GenerateMovieOutFileParamKey) as? NSString
                let fileName = dict?.object(forKey: GenerateMovieFileNameParamKey) as? NSString
                var dicomImageArray = dict?.object(forKey: GenerateMovieDicomImagesParamKey) as? NSArray
                //BOOL isiPhone = [[dict objectForKey:GenerateMovieIsIOSParamKey] boolValue];

                let MaxNumberOfFramesForWebPortalMovies = Int32(truncatingIfNeeded: UserDefaults.standard.integer(forKey: "MaxNumberOfFramesForWebPortalMovies"))

                if MaxNumberOfFramesForWebPortalMovies > 2 && (dicomImageArray?.count ?? 0) >= Int(MaxNumberOfFramesForWebPortalMovies) {
                    repeat {
                        let newArray = NSMutableArray(capacity: (dicomImageArray?.count ?? 0) / 2)

                        var i = 0
                        while i < (dicomImageArray?.count ?? 0) {
                            newArray.add(dicomImageArray!.object(at: i))
                            i += 2
                        }

                        dicomImageArray = newArray
                    }
                    while (dicomImageArray?.count ?? 0) > Int(MaxNumberOfFramesForWebPortalMovies)
                }

                objcSynchronized(self.portal?.locks) {
                    if outFile == nil || self.portal?.locks?.object(forKey: outFile!) == nil {
                        objcSetObject(self.portal?.locks, NSRecursiveLock(), forKey: outFile)
                    }
                }

                (outFile.flatMap { self.portal?.locks?.object(forKey: $0) } as? NSRecursiveLock)?.lock()

                objcTry({
                    if outFile == nil || !FileManager.default.fileExists(atPath: outFile! as String) || (objcIntValue(dict?.object(forKey: "rows")) > 0 && objcIntValue(dict?.object(forKey: "columns")) > 0) {
                        var noOfThreads = Int32(truncatingIfNeeded: ProcessInfo.processInfo.processorCount)

                        if noOfThreads > 12 {
                            noOfThreads = 12
                        }

                        let count = UInt(dicomImageArray?.count ?? 0)
                        var rangeLocation: UInt = 0
                        var rangeLength: UInt = 1 &+ (count / UInt(bitPattern: Int(noOfThreads)))

                        DCMPixLoadingLock.lock()

//                        [self.portal.dicomDatabase lock];

                        NSLog("generateMovie: start dcmpix reading")

                        var width: CGFloat = 0, height: CGFloat = 0

                        if objcIntValue(dict?.object(forKey: "rows")) > 0 && objcIntValue(dict?.object(forKey: "columns")) > 0 {
                            width = CGFloat(objcIntValue(dict?.object(forKey: "columns")))
                            height = CGFloat(objcIntValue(dict?.object(forKey: "rows")))
                        } else {
                            self.getWidth(&width, height: &height, fromImagesArray: dicomImageArray /* isiPhone:.. */)
                        }

                        if let dir = objcAppending(fileName, " dir") {
                            try? FileManager.default.removeItem(atPath: dir as String)
                            try? FileManager.default.createDirectory(atPath: dir as String, withIntermediateDirectories: true, attributes: nil)
                        }

                        // The loader threads write the series' frame rate here, as they
                        // wrote it to a local through a pointer.
                        let fps = UnsafeMutablePointer<Int>.allocate(capacity: 1)
                        fps.pointee = 0
                        defer { fps.deallocate() }

                        objcTry({
                            DCMPixLoadingThreads.store(0, ordering: .sequentiallyConsistent)
                            var i: Int32 = 0
                            while i < noOfThreads {
                                if rangeLength > 0 {
                                    objcSynchronized(self) {
                                        DCMPixLoadingThreads.add(1, ordering: .sequentiallyConsistent)
                                    }
                                    Thread.detachNewThreadSelector(#selector(self.movieDCMPixLoad(_:)),
                                                                   toTarget: self,
                                                                   with: objcDictionary([
                                                                    (NSNumber(value: UInt32(truncatingIfNeeded: rangeLocation)), "location"),
                                                                    (NSNumber(value: UInt32(truncatingIfNeeded: rangeLength)), "length"),
                                                                    (NSNumber(value: Float(width)), "width"),
                                                                    (NSNumber(value: Float(height)), "height"),
                                                                    (outFile, "outFile"),
                                                                    (fileName, "fileName"),
                                                                    (dicomImageArray?.value(forKey: "objectID"), "DicomImageArray"),
                                                                    (NSValue(pointer: UnsafeRawPointer(fps)), "fpsP")]))
                                }

                                rangeLocation = rangeLocation &+ rangeLength
                                if rangeLocation &+ rangeLength > count {
                                    rangeLength = count &- rangeLocation
                                }
                                i += 1
                            }

                            while DCMPixLoadingThreads.load(ordering: .sequentiallyConsistent) > 0 {
                                Thread.sleep(forTimeInterval: 0.1)
                            }
                        }, catch: { e in
                            _N2LogExceptionImpl(e, true, "-[WebPortalConnection(Data) generateMovie:]")
                        })

//                        [self.portal.dicomDatabase unlock];

                        DCMPixLoadingLock.unlock()

                        var framesPerSecond = fps.pointee
                        if framesPerSecond <= 0 {
                            framesPerSecond = UserDefaults.standard.integer(forKey: "quicktimeExportRateValue")
                        }
                        if framesPerSecond <= 0 {
                            framesPerSecond = 10
                        }

                        NSLog("generateMovie: start writeMovie process")

                        objcTry({
                            let root = objcAppending(fileName, " dir")

                            // [NSURL fileURLWithPath:nil] raised.
                            guard let outFile = outFile else {
                                objcRaise(.invalidArgumentException, "*** -[NSURL initFileURLWithPath:]: nil string parameter")
                            }

                            let timeValue = CMTimeValue(600 / framesPerSecond)
                            let frameDuration = CMTimeMake(value: timeValue, timescale: 600)

                            var writer: AVAssetWriter? = nil
                            var error: Error? = nil
                            do {
                                writer = try AVAssetWriter(outputURL: URL(fileURLWithPath: outFile as String), fileType: .mov)
                            } catch let e {
                                error = e
                            }

                            if error == nil, let writer = writer {
                                let bitsPerSecond = Double(width * height) * Double(framesPerSecond) * 4

                                if bitsPerSecond > 0 {
                                    var videoSettings: [String: Any]? = nil

                                    if self.requestIsIOS() { // AVVideoCodecH264
                                        videoSettings = [
                                            AVVideoCodecKey: AVVideoCodecType.h264.rawValue,
                                            AVVideoCompressionPropertiesKey: [
                                                AVVideoAverageBitRateKey: NSNumber(value: bitsPerSecond),
                                                AVVideoMaxKeyFrameIntervalKey: NSNumber(value: 1)],
                                            AVVideoWidthKey: NSNumber(value: cInt32(Double(width))),
                                            AVVideoHeightKey: NSNumber(value: cInt32(Double(height)))]
                                    }
                                    else { // AVVideoCodecJPEG
                                        videoSettings = [
                                            AVVideoCodecKey: AVVideoCodecType.jpeg.rawValue,
                                            AVVideoCompressionPropertiesKey: [AVVideoQualityKey: NSNumber(value: Float(0.9))],
                                            AVVideoWidthKey: NSNumber(value: cInt32(Double(width))),
                                            AVVideoHeightKey: NSNumber(value: cInt32(Double(height)))]
                                    }

                                    // Instanciate the AVAssetWriterInput
                                    let writerInput: AVAssetWriterInput? = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)

                                    if writerInput == nil {
                                        HorosWebPortalDataLogStackTrace(String(format: "**** writerInput == nil : %@", objcArg(videoSettings)))
                                    }

                                    // Instanciate the AVAssetWriterInputPixelBufferAdaptor to be connected to the writer input
                                    let pixelBufferAdaptor = writerInput.map { AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: $0, sourcePixelBufferAttributes: nil) }
                                    // Add the writer input to the writer and begin writing
                                    if let writerInput = writerInput {
                                        writer.add(writerInput)
                                    }
                                    writer.startWriting()

                                    var nextPresentationTimeStamp: CMTime

                                    nextPresentationTimeStamp = .zero

                                    writer.startSession(atSourceTime: nextPresentationTimeStamp)

                                    for file in root.flatMap({ try? FileManager.default.contentsOfDirectory(atPath: $0 as String) }) ?? [] {
                                        var buffer: CVPixelBuffer? = nil

                                        autoreleasepool {
                                            let im = NSImage(contentsOfFile: root!.appendingPathComponent(file))
                                            if let im = im {
                                                buffer = objcPixelBuffer(from: im)
                                            }
                                        }

                                        if let pixelBuffer = buffer {
                                            CVPixelBufferLockBaseAddress(pixelBuffer, [])
                                            while let writerInput = writerInput, writerInput.isReadyForMoreMediaData == false {
                                                Thread.sleep(forTimeInterval: 0.1)
                                            }
                                            pixelBufferAdaptor?.append(pixelBuffer, withPresentationTime: nextPresentationTimeStamp)
                                            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
                                            buffer = nil

                                            nextPresentationTimeStamp = CMTimeAdd(nextPresentationTimeStamp, frameDuration)
                                        }
                                    }
                                    writerInput?.markAsFinished()
                                }
                                else {
                                    HorosWebPortalDataLogStackTrace("********** bitsPerSecond == 0")
                                }

                                // -finishWriting, which Swift only offers asynchronously
                                _ = writer.perform(NSSelectorFromString("finishWriting"))
                            }
                            if let root = root {
                                try? FileManager.default.removeItem(atPath: root as String)
                            }
                        }, catch: { e in
                            NSLog("***** writeMovie exception : %@", e)
                        })
                        NSLog("generateMovie: end")
                    }
                }, catch: { e in
                    NSLog("***** generate movie exception : %@", e)
                })

                (outFile.flatMap { self.portal?.locks?.object(forKey: $0) } as? NSRecursiveLock)?.unlock()

                objcSynchronized(self.portal?.locks) {
                    if let outFile = outFile, let lock = self.portal?.locks?.object(forKey: outFile) as? NSRecursiveLock, lock.try() {
                        lock.unlock()
                        self.portal?.locks?.removeObject(forKey: outFile)
                    }
                }
            }
        }
    }

    @objc(produceMovieForSeries:fileURL:)
    func produceMovieForSeries(_ series: DicomSeries?, fileURL: NSString?) -> Data? {
        return raisingToCaller { () -> Data? in
            let path = WebPortalConnection.tmpDirPath()
            FileManager.default.confirmDirectory(atPath: path)

            var dicomImageArray = (series?.value(forKey: "images") as? NSSet)?.allObjects as NSArray?

            var name = String(format: "%@", objcArg(self.parameter("xid"))) as NSString
            name = name.appendingFormat("-NBIM-%d", Int32(truncatingIfNeeded: dicomImageArray?.count ?? 0))

            var fileName = NSMutableString(string: name as String)
            objcReplaceNotAdmitted(fileName)
            fileName = NSMutableString(string: (path as NSString).appendingPathComponent(fileName as String))
            fileName.appendFormat(".%@", objcArg(fileURL?.pathExtension))

            let outFile: NSString

            if self.requestIsIOS() {
                outFile = String(format: "%@2.mp4", fileName.deletingPathExtension) as NSString
            } else {
                outFile = fileName
            }

            var data = NSData(contentsOfFile: outFile as String)

            if data == nil {
                if (dicomImageArray?.count ?? 0) > 1 {
                    objcTry({
                        // Sort images with "instanceNumber"
                        let sort = NSSortDescriptor(key: "instanceNumber", ascending: true)
                        let sortDescriptors = [sort]
                        dicomImageArray = dicomImageArray?.sortedArray(using: sortDescriptors) as NSArray?
                    }, catch: { e in
                        NSLog("%@", e.description)
                    })

                    let dict = objcMutableDictionary([/*[NSNumber numberWithBool: isiPhone], @"isiPhone", */(fileURL, "fileURL"), (fileName, "fileName"), (outFile, "outFile"), (self.parameters, "parameters"), (dicomImageArray, "dicomImageArray")])

//                    [self.portal.dicomDatabase unlock];

                    self.generateMovie(dict)

//                    [self.portal.dicomDatabase lock];

                    data = NSData(contentsOfFile: outFile as String)
                }
            }

            return data as Data?
        }
    }


    // MARK: HTML

    @objc(processLoginHtml)
    public func processLoginHtml() {
        raisingToCaller {
            self.response.templateString = self.portal?.string(forPath: "login.html")
            self.response.mimeType = "text/html"
        }
    }

    @objc(processIndexHtml)
    public func processIndexHtml() {
        raisingToCaller {
            self.response.templateString = self.portal?.string(forPath: "index.html")
            self.response.mimeType = "text/html"
        }
    }

    @objc(processMainHtml)
    public func processMainHtml() {
        raisingToCaller {
            let response = self.response!
            let user = self.user
//            if (!user || user.uploadDICOM.boolValue)
//                [self resetPOST];

//            [self.independentDicomDatabase.managedObjectContext reset]; //We want fresh data : from the persistentstore

            let albums = NSMutableArray()
            for album in (self.independentDicomDatabase?.albums() as NSArray?) ?? NSArray() {
                let album = unsafeDowncast(album as AnyObject, to: DicomAlbum.self)
                if !objcIsEqualToString(album.value(forKey: "name") as? NSString, NSLocalizedString("Database", comment: "") as NSString) {
                    autoreleasepool {
                        var numberOfStudies: Int32 = 0

                        _ = WebPortalUser.studies(for: user, album: album.name, sortBy: nil, fetchLimit: 1, fetchOffset: 0, numberOfStudies: &numberOfStudies)

                        if numberOfStudies >= 1 {
                            albums.add(album)
                        }

                        album.numberOfStudies = numberOfStudies
                    }
                }
            }
            response.tokens.setObject(albums, forKey: "Albums" as NSString)
            objcSetObject(response.tokens, WebPortalUser.studies(for: user, predicate: nil) as NSArray?, forKey: "Studies")

            response.templateString = self.portal?.string(forPath: "main.html")
            response.mimeType = "text/html"
        }
    }

    @objc(processDeleteObject:)
    func processDeleteObject(_ XID: NSString?) -> Bool {
        return raisingToCaller {
            let response = self.response!
            let user = self.user

            if XID?.hasPrefix("POD:") ?? false {
                NSLog("-- Cannot delete a distant study: %@", objcArg(XID))
                return false
            }

            let dbObject = self.objectWithXID(XID) as AnyObject?

            var study: DicomStudy? = nil
            var series: DicomSeries? = nil

            if dbObject?.isKind(of: DicomStudy.self) ?? false {
                study = unsafeDowncast(dbObject!, to: DicomStudy.self)
            }

            if dbObject?.isKind(of: DicomSeries.self) ?? false {
                study = dbObject!.value(forKey: "study").map { unsafeDowncast($0 as AnyObject, to: DicomStudy.self) }
                series = unsafeDowncast(dbObject!, to: DicomSeries.self)
            }

            if let study = study {
                response.tokens.addMessage(String(format: NSLocalizedString("Images successfully deleted.", comment: "")))
                self.portal?.updateLogEntry(forStudy: study, withMessage: String(format: "Images deleted"), forUser: user?.name, ip: self.asyncSocket?.connectedHost())

                if let series = series {
                    series.managedObjectContext?.delete(series)
                    if (study.imageSeries() as NSArray?)?.count ?? 0 == 0 {
                        study.managedObjectContext?.delete(study)
                    }
                } else {
                    study.managedObjectContext?.delete(study)
                }

                let isStudyDeleted = study.isDeleted

                _ = self.independentDicomDatabase?.save()

                return isStudyDeleted
            } else {
                self.response.tokens.addError(String(format: NSLocalizedString("Study not found", comment: "")))
            }

            return false
        }
    }

    @objc(processStudyHtml)
    public func processStudyHtml() {
        raisingToCaller {
            self.processStudyHtml(self.stringParameter("xid"))
        }
    }

    @objc(processStudyHtml:)
    public func processStudyHtml(_ xid: NSString?) {
        raisingToCaller {
            let response = self.response!
            let user = self.user

            // The former code typed whatever the XID names as a DicomStudy.
            var study = (self.objectWithXID(xid) as AnyObject?).map { unsafeDowncast($0, to: DicomStudy.self) }

            if study == nil {
                return
            }

            let selectedSeries = NSMutableArray()
            for selectedXID in WebPortalConnection.makeArray(self.parameter("selected")) {
                objcAddObject(selectedSeries, self.objectWithXID(objcString(selectedXID)))
            }

            if let study = study, let user = user {
                //save this study in recent studies list, if not already here
                var studyLink = (objcSet(user, "recentStudies").filtered(using: NSPredicate(format: "studyInstanceUID == %@", objcArg(study.studyInstanceUID))) as NSSet).anyObject().map { unsafeDowncast($0 as AnyObject, to: WebPortalStudy.self) }

                if studyLink == nil {
                    studyLink = unsafeDowncast(objcInsertNewObject("RecentStudy", user.managedObjectContext) as AnyObject, to: WebPortalStudy.self)

                    studyLink!.studyInstanceUID = objcCopy(study.value(forKey: "studyInstanceUID")) as? String
                    studyLink!.user = user
                }

                studyLink!.patientUID = objcCopy(study.value(forKey: "patientUID")) as? String
                studyLink!.dateAdded = Date()

                let recentStudies = user.mutableSetValue(forKey: "recentStudies")
                let maximum = UserDefaults.standard.integer(forKey: "WebPortalMaximumNumberOfRecentStudies")
                if UInt(recentStudies.count) > UInt(bitPattern: maximum) {
                    let array = NSMutableArray(array: recentStudies.allObjects)
                    array.sort(using: [NSSortDescriptor(key: "dateAdded", ascending: false)])

                    for s in array.subarray(with: NSRange(location: maximum, length: array.count &- maximum)) {
                        recentStudies.remove(s)
                    }
                }
                try? user.managedObjectContext?.save()
            }

            if self.parameter("dicomSend") != nil, let study = study {
                // The form decoded its outer layer. Split the colon-separated
                // destination before decoding each template subcomponent once.
                let dicomDestinationArray = self.stringParameter("dicomDestination")?.components(separatedBy: ":").map {
                    $0.removingPercentEncoding ?? $0
                } as NSArray?
                if (dicomDestinationArray?.count ?? 0) >= 4 {
                    let dicomDestinationArray = dicomDestinationArray!
                    let dicomDestination = NSMutableDictionary()
                    dicomDestination.setObject(dicomDestinationArray.object(at: dicomDestinationArray.count - 4), forKey: "Address" as NSString)
                    dicomDestination.setObject(dicomDestinationArray.object(at: dicomDestinationArray.count - 3), forKey: "Port" as NSString)
                    dicomDestination.setObject(dicomDestinationArray.object(at: dicomDestinationArray.count - 2), forKey: "AETitle" as NSString)
                    dicomDestination.setObject(dicomDestinationArray.object(at: dicomDestinationArray.count - 1), forKey: "TransferSyntax" as NSString)

                    let selectedImages = NSMutableArray()
                    if selectedSeries.count > 0 {
                        for s in selectedSeries {
                            if let sorted = unsafeDowncast(s as AnyObject, to: DicomSeries.self).sortedImages() { selectedImages.addObjects(from: sorted) }
                        }
                    } else {
                        for s in objcSet(study, "series") {
                            if let sorted = unsafeDowncast(s as AnyObject, to: DicomSeries.self).sortedImages() { selectedImages.addObjects(from: sorted) }
                        }
                    }

                    if selectedImages.count > 0 {
                        self.sendImages(selectedImages, toDicomNode: dicomDestination)
                        response.tokens.addMessage(String(format: NSLocalizedString("Dicom send to node %@ initiated.", comment: "Web Portal, study, dicom send, success"), objcArg(dicomDestination.object(forKey: "AETitle"))))
                    } else {
                        response.tokens.addError(NSLocalizedString("Dicom send failed: no images selected. Select one or more series.", comment: "Web Portal, study, dicom send, error"))
                    }
                } else {
                    response.tokens.addError(NSLocalizedString("Dicom send failed: cannot identify node.", comment: "Web Portal, study, dicom send, error"))
                }
            }

            if self.parameter("WADOURLsRetrieve") != nil && study != nil && UserDefaults.standard.bool(forKey: "wadoServer") {
                let selectedImages = NSMutableArray()
                for s in selectedSeries {
                    if let sorted = unsafeDowncast(s as AnyObject, to: DicomSeries.self).sortedImages() { selectedImages.addObjects(from: sorted) }
                }

                if selectedImages.count > 0 {
//                    NSString *protocol = [[NSUserDefaults standardUserDefaults] boolForKey:@"encryptedWebServer"] ? @"https" : @"http";
                    var wadoSubUrl: NSString = "wado" // See Web Server Preferences

                    if wadoSubUrl.hasPrefix("/") {
                        wadoSubUrl = wadoSubUrl.substring(from: 1) as NSString
                    }

                    let baseURL = String(format: "%@/%@?requestType=WADO", objcArg(self.portalURL()), wadoSubUrl) as NSString

                    let WADOURLs = NSMutableString()

                    objcTry({
                        for image in selectedImages {
                            let image = unsafeDowncast(image as AnyObject, to: DicomImage.self)
                            WADOURLs.append(baseURL.appendingFormat("&studyUID=%@&seriesUID=%@&objectUID=%@&contentType=application/dicom%@\r", objcArg(image.series?.study?.studyInstanceUID), objcArg(image.series?.seriesDICOMUID), objcArg(image.sopInstanceUID()), "&useOrig=true") as String)
                        }
                    }, catch: { e in
                        _N2LogExceptionImpl(e, true, "-[WebPortalConnection(Data) processStudyHtml:]")
                    })

                    response.data = WADOURLs.data(using: String.Encoding.utf8.rawValue)
                    response.mimeType = "application/dcmURLs"
                    response.mutableHTTPHeaders.setObject(String(format: "attachment; filename=%@.dcmURLs", objcArg((selectedSeries.lastObject as AnyObject?)?.value(forKeyPath: "study.name"))), forKey: "Content-Disposition" as NSString)
                    return
                }
                else {
                    response.tokens.addError(NSLocalizedString("WADO URL Retrieve failed: no images selected. Select one or more series.", comment: "Web Portal, study, dicom send, error"))
                }
            }

            if objcIsEqualToString(self.stringParameter("message"), "delete") && self.parameter("seriesToDelete") != nil && study != nil {
                if !(user?.isAdmin?.boolValue ?? false) {
                    response.setStatusCode(401)
                    self.portal?.updateLogEntry(forStudy: nil, withMessage: "Attempt to delete images without being an admin", forUser: user?.name, ip: self.asyncSocket?.connectedHost())
                }
                else {
                    if self.processDeleteObject(self.stringParameter("seriesToDelete")) {
                        study = nil
                    }
                }
            }

            if self.parameter("shareStudy") != nil, let study = study {
                if user == nil || (user?.shareStudyWithUser?.boolValue ?? false) {
                    let shareStudyDestination = self.stringParameter("shareStudyDestination")
                    var destUser: AnyObject? = nil

                    if objcIsEqualToString(shareStudyDestination, "NEW") {
                        if user == nil || (user?.createTemporaryUser?.boolValue ?? false) {
                            objcTry({
                                destUser = self.portal?.webPortalDataNewUser(withEmail: self.stringParameter("shareDestinationCreateTempEmail"))
                            }, catch: { e in
                                self.response.tokens.addError(String(format: NSLocalizedString("Couldn't create temporary user: %@", comment: ""), objcArg(e.reason)))
                            })
                        }
                        else {
                            response.tokens.addError(NSLocalizedString("Study share failed: not authorized.", comment: "Web Portal, study, share, error"))
                        }
                    }
                    else {
                        destUser = self.objectWithXID(shareStudyDestination) as AnyObject?
                    }

                    if let destUser = destUser, destUser.isKind(of: WebPortalUser.self) {
                        let destUser = unsafeDowncast(destUser, to: WebPortalUser.self)
                        // add study to specific study list for this user
                        let studyUID = study.studyInstanceUID
                        if !(studyUID != nil && ((objcSet(destUser, "studies").allObjects as NSArray).value(forKey: "studyInstanceUID") as? NSArray)?.contains(studyUID!) ?? false) {
                            let wpStudy = unsafeDowncast(objcInsertNewObject("Study", destUser.managedObjectContext) as AnyObject, to: WebPortalStudy.self)
                            wpStudy.user = destUser
                            wpStudy.patientUID = study.patientUID
                            wpStudy.studyInstanceUID = study.studyInstanceUID
                            wpStudy.dateAdded = Date(timeIntervalSinceReferenceDate: UserDefaults.standard.double(forKey: "lastNotificationsDate"))
                            try? destUser.managedObjectContext?.save()

                            response.tokens.addMessage(String(format: NSLocalizedString("This study is now shared with <b>%@</b>.", comment: "Web Portal, study, share, ok (%@ is destUser.name)"), objcArg(destUser.name)))
                        }
                        else {
                            response.tokens.addMessage(String(format: NSLocalizedString("This study is shared with <b>%@</b>.", comment: "Web Portal, study, share, ok (%@ is destUser.name)"), objcArg(destUser.name)))
                        }

                        // Send the email
                        _ = self.portal?.sendNotificationsEmails(to: [destUser], aboutStudies: [study], predicate: nil, customText: self.stringParameter("message") as String?, from: user)
                        self.portal?.updateLogEntry(forStudy: study, withMessage: String(format: "Share Study with User: %@", objcArg(destUser.name)), forUser: user?.name, ip: self.asyncSocket?.connectedHost())
                    } else {
                        response.tokens.addError(NSLocalizedString("Study share failed: cannot identify user.", comment: "Web Portal, study, share, error"))
                    }
                }
                else {
                    response.tokens.addError(NSLocalizedString("Study share failed: not authorized.", comment: "Web Portal, study, share, error"))
                }
            }

            if let study = study {
                objcSetObject(response.tokens, WebPortalProxy.create(with: study, transformer: DicomStudyTransformer.create()), forKey: "Study")
                response.tokens.setObject(String(format: NSLocalizedString("%@ - %@ - %@", comment: "Web Portal, study, title format (1st %@ is study.name, 2nd is study.studyName, 3rd date)"), objcArg(study.name), objcArg(study.studyName), objcArg(objcStringFromDate(UserDefaults.dateTimeFormatter(), study.date))), forKey: "PageTitle" as NSString)
            }
            else {
                response.tokens.setObject(String(format: NSLocalizedString("Study Deleted", comment: "")), forKey: "PageTitle" as NSString)
            }

            self.portal?.updateLogEntry(forStudy: study, withMessage: "Browsing Study", forUser: user?.name, ip: self.asyncSocket?.connectedHost())

            objcTry({
                let browse = self.stringParameter("browse")
                let search = self.stringParameter("search")
                let album = self.stringParameter("album")
                var studyListLinkLabel = NSLocalizedString("Study list", comment: "")
                if (search?.length ?? 0) > 0 {
                    studyListLinkLabel = String(format: NSLocalizedString("Search results for: %@", comment: ""), objcArg(search))
                } else if (album?.length ?? 0) > 0 {
                    studyListLinkLabel = String(format: NSLocalizedString("Album: %@", comment: ""), objcArg(album))
                } else if objcIsEqualToString(browse, "6hours") {
                    studyListLinkLabel = NSLocalizedString("Last 6 Hours", comment: "")
                } else if objcIsEqualToString(browse, "today") {
                    studyListLinkLabel = NSLocalizedString("Today", comment: "")
                }

                if objcIsEqualToString(self.stringParameter("back"), "main") {
                    studyListLinkLabel = NSLocalizedString("Home", comment: "")
                    response.tokens.setObject(HorosWebPortalDataLiteral("main")!, forKey: "backLink" as NSString)
                }
                else {
                    response.tokens.setObject(HorosWebPortalDataLiteral("studyList")!, forKey: "backLink" as NSString)
                }

                response.tokens.setObject(studyListLinkLabel, forKey: "BackLinkLabel" as NSString)

                // Series

                let seriesArray = NSMutableArray()
                for s in (study?.imageSeries() as NSArray?) ?? NSArray() {
                    objcAddObject(seriesArray, WebPortalProxy.create(with: s as? NSObject, transformer: DicomSeriesTransformer.create()))
                }
                response.tokens.setObject(seriesArray, forKey: "Series" as NSString)

                // DICOM destinations

                let dicomDestinations = NSMutableArray()
                if user == nil || (user?.sendDICOMtoSelfIP?.boolValue ?? false) {
                    dicomDestinations.add(objcDictionary([
                        (self.asyncSocket?.connectedHost(), "address"),
                        (self.dicomCStorePortString(), "port"),
                        ("This Computer", "aeTitle"),
                        ("1", "syntax"), // 1 == JPEG2000 Lossless
                        (self.requestIsIOS() ? NSLocalizedString("This Device", comment: "") : String(format: NSLocalizedString("This Computer [%@:%@]", comment: ""), objcArg(self.asyncSocket?.connectedHost()), objcArg(self.dicomCStorePortString())), "description")]))
                    if user == nil || (user?.sendDICOMtoAnyNodes?.boolValue ?? false) {
                        for node in (DCMNetServiceDelegate.dicomServersListSendOnly(true, qrOnly: false) as NSArray?) ?? NSArray() {
                            let node = unsafeDowncast(node as AnyObject, to: NSDictionary.self)
                            dicomDestinations.add(objcDictionary([
                                (node.object(forKey: "Address"), "address"),
                                (node.object(forKey: "Port"), "port"),
                                (node.object(forKey: "AETitle"), "aeTitle"),
                                (node.object(forKey: "TransferSyntax"), "syntax"),
                                (self.requestIsIOS() ? node.object(forKey: "Description") : (String(format: "%@ [%@:%@]", objcArg(node.object(forKey: "Description")), objcArg(node.object(forKey: "Address")), objcArg(node.object(forKey: "Port"))) as Any?), "description")]))
                        }
                    }
                }
                response.tokens.setObject(dicomDestinations, forKey: "DicomDestinations" as NSString)

                // Share

                let shareDestinations = NSMutableArray()
                if user == nil || (user?.shareStudyWithUser?.boolValue ?? false) {
                    let idatabase = self.independentWebDatabase
                    let users = (idatabase?.objects(forEntity: idatabase?.userEntity()) as NSArray?)?.sortedArray(using: [NSSortDescriptor(key: "name", ascending: true)]) as NSArray?

                    for u in users ?? NSArray() {
                        if (u as AnyObject) !== self.user {
                            objcAddObject(shareDestinations, WebPortalProxy.create(with: u as? NSObject, transformer: WebPortalUserTransformer.create()))
                        }
                    }
                }
                response.tokens.setObject(shareDestinations, forKey: "ShareDestinations" as NSString)

            }, catch: { e in
                NSLog("Error: [WebPortalResponse processStudyHtml:] %@", e)
            })

            response.templateString = self.portal?.string(forPath: "study.html")
            response.mimeType = "text/html"
        }
    }

    @objc(processLogsListHtml)
    public func processLogsListHtml() {
        raisingToCaller {
            let response = self.response!
            let user = self.user

            if !(user?.isAdmin?.boolValue ?? false) {
                response.setStatusCode(401)
                self.portal?.updateLogEntry(forStudy: nil, withMessage: "Attempt to see logs without being an admin", forUser: user?.name, ip: self.asyncSocket?.connectedHost())
                return
            }

            var logsArray: NSArray? = nil

            if self.parameter("externalIPs") != nil {
                response.tokens.setObject(NSLocalizedString("Logs - External IPs", comment: ""), forKey: "PageTitle" as NSString)

                logsArray = self.independentDicomDatabase?.objects(forEntity: "LogEntry", predicate: NSPredicate(format: "type == %@ AND NOT originName BEGINSWITH '172.' AND NOT originName BEGINSWITH '10.' AND NOT originName BEGINSWITH '192.168.' AND NOT originName BEGINSWITH '127.' AND NOT originName LIKE '::1'", "Web"), error: nil, fetchLimit: 2000, sortDescriptors: [NSSortDescriptor(key: "startTime", ascending: false)]) as NSArray?
            }
            else {
                response.tokens.setObject(NSLocalizedString("Logs", comment: ""), forKey: "PageTitle" as NSString)

                logsArray = self.independentDicomDatabase?.objects(forEntity: "LogEntry", predicate: NSPredicate(format: "type == %@", "Web"), error: nil, fetchLimit: 2000, sortDescriptors: [NSSortDescriptor(key: "startTime", ascending: false)]) as NSArray?
            }

            objcSetObject(response.tokens, logsArray, forKey: "Logs")

            response.templateString = self.portal?.string(forPath: "admin/logs.html")
            response.mimeType = "text/html"
        }
    }

    @objc(processStudyListHtml)
    public func processStudyListHtml() {
        raisingToCaller {
            let response = self.response!
            let user = self.user

            if self.parameter("delete") != nil {
                if !(user?.isAdmin?.boolValue ?? false) {
                    response.setStatusCode(401)
                    self.portal?.updateLogEntry(forStudy: nil, withMessage: "Attempt to delete images without being an admin", forUser: user?.name, ip: self.asyncSocket?.connectedHost())
                }
                else {
                    _ = self.processDeleteObject(self.stringParameter("delete"))
                }
            }

            if self.studyList_requestsUnknownAlbum() {
                response.setStatusCode(404)
                return
            }

            var title: NSString? = nil
            objcSetObject(response.tokens, self.studyList_requestedStudies(&title), forKey: "Studies")
            if let title = title { response.tokens.setObject(title, forKey: "PageTitle" as NSString) }
            response.templateString = self.portal?.string(forPath: "studyList.html")
            response.mimeType = "text/html"
        }
    }

    @objc(processKeyROIsImagesHtml)
    public func processKeyROIsImagesHtml() {
        raisingToCaller {
            let response = self.response!

            let oxid = self.objectWithXID(self.stringParameter("xid")) as AnyObject?
            if let oxid = oxid, oxid.isKind(of: DicomStudy.self) {
                let study = unsafeDowncast(oxid, to: DicomStudy.self)

                objcSetObject(response.tokens, WebPortalProxy.create(with: study, transformer: DicomStudyTransformer.create()), forKey: "Study")
                response.tokens.setObject(String(format: "%@ - %@", objcArg(study.name), NSLocalizedString("Key Images and ROI Images", comment: "")), forKey: "PageTitle" as NSString)
                response.tokens.setObject(String(format: "%@ - %@", objcArg(study.name), objcArg(study.studyName)), forKey: "BackLinkLabel" as NSString)
            }

            response.templateString = self.portal?.string(forPath: "keyroisimages.html")
            response.mimeType = "text/html"
        }
    }

    @objc(processSeriesHtml)
    public func processSeriesHtml() {
        raisingToCaller {
            let response = self.response!

            let oxid = self.objectWithXID(self.stringParameter("xid")) as AnyObject?
            if let oxid = oxid, oxid.isKind(of: DicomSeries.self) {
                let series = unsafeDowncast(oxid, to: DicomSeries.self)

                objcSetObject(response.tokens, WebPortalProxy.create(with: series, transformer: DicomSeriesTransformer.create()), forKey: "Series")
                response.tokens.setObject(String(format: "%@ - %@", objcArg(series.name), objcArg(series.id?.stringValue)), forKey: "PageTitle" as NSString)
                response.tokens.setObject(String(format: "%@ - %@", objcArg(series.study?.name), objcArg(series.study?.studyName)), forKey: "BackLinkLabel" as NSString)
            }

            response.templateString = self.portal?.string(forPath: "series.html")
            response.mimeType = "text/html"
        }
    }

    @objc(sendEmailOnMainThread:)
    func sendEmailOnMainThread(_ dict: NSDictionary?) {
        raisingToCaller {
            autoreleasepool {
                let ts = dict?.object(forKey: "template") as? NSString
                let messageHeaders = dict?.object(forKey: "headers") as? NSDictionary

                // [[CSMailMailClient mailClient] deliverMessage:ts headers:messageHeaders], by selector
                let client = (CSMailMailClient.self as AnyObject).perform(NSSelectorFromString("mailClient"))?.takeUnretainedValue()
                _ = client?.perform(NSSelectorFromString("deliverMessage:headers:"), with: ts, with: messageHeaders)
            }
        }
    }

    @objc(processPasswordForgottenHtml)
    public func processPasswordForgottenHtml() {
        raisingToCaller {
            let response = self.response!

            if !(self.portal?.passwordRestoreAllowed ?? false) {
                return
            }

            if objcIsEqualToString(objcString(self.parameterValue("action")), "restorePassword") {
                let email = objcString(self.parameterValue("email"))
                let username = objcString(self.parameterValue("username"))

                // TRY TO FIND THIS USER
                if (email?.length ?? 0) > 0 || (username?.length ?? 0) > 0 {
                    let db = self.independentWebDatabase

                    objcTry({
                        var predicate: NSPredicate? = nil
                        if (email?.length ?? 0) > (username?.length ?? 0) {
                            predicate = NSPredicate(format: "(email BEGINSWITH[cd] %@) AND (email ENDSWITH[cd] %@)", objcArg(email), objcArg(email))
                        } else {
                            predicate = NSPredicate(format: "(name BEGINSWITH[cd] %@) AND (name ENDSWITH[cd] %@)", objcArg(username), objcArg(username))
                        }

                        let users = db?.objects(forEntity: db?.userEntity(), predicate: predicate) as NSArray?

                        if (users?.count ?? 0) >= 1 {
                            for u in users! {
                                let u = unsafeDowncast(u as AnyObject, to: WebPortalUser.self)
                                var fromEmailAddress = UserDefaults.standard.value(forKey: "notificationsEmailsSender")

                                if fromEmailAddress == nil {
                                    fromEmailAddress = ""
                                }

                                let emailSubject = NSLocalizedString("Your password has been reset.", comment: "")
                                let emailMessage = NSMutableString(string: "")

                                u.generatePassword()

                                var webPortalDefaultTitle = UserDefaults.standard.string(forKey: "WebPortalTitle") as NSString?
                                if (webPortalDefaultTitle?.length ?? 0) == 0 {
                                    webPortalDefaultTitle = NSLocalizedString("IsiX DICOM Viewer Web Portal", comment: "Web Portal, general default title") as NSString
                                }

                                objcAppend(emailMessage, webPortalDefaultTitle)
                                emailMessage.append("<br><br>")
                                emailMessage.append("<br><br>")

                                emailMessage.append(NSLocalizedString("Username:<br><br>", comment: ""))
                                objcAppend(emailMessage, u.name as NSString?)
                                emailMessage.append("<br><br>")
                                emailMessage.append(NSLocalizedString("Password:<br><br>", comment: ""))
                                objcAppend(emailMessage, u.password as NSString?)
                                emailMessage.append("<br><br>")
                                emailMessage.append("<br><br>")
                                emailMessage.append(NSLocalizedString("Login here:<br>", comment: ""))
                                objcAppend(emailMessage, self.portal?.url() as NSString?)

                                self.portal?.updateLogEntry(forStudy: nil, withMessage: "Password reset for user", forUser: u.name, ip: nil)

                                let messageHeaders = objcDictionary([(u.email, "To"), (fromEmailAddress, "Sender"), (emailSubject, "Subject")])

                                // NSAttributedString initWithHTML is NOT thread-safe
                                self.performSelector(onMainThread: #selector(self.sendEmailOnMainThread(_:)), with: objcDictionary([(emailMessage, "template"), (messageHeaders, "headers")]), waitUntilDone: false)

                                response.tokens.addMessage(NSLocalizedString("You will shortly receive an email with your new password.", comment: ""))

                                _ = db?.save()
                            }
                        }
                        else {
                            // To avoid someone scanning for the username
                            Thread.sleep(forTimeInterval: 3)

                            self.portal?.updateLogEntry(forStudy: nil, withMessage: "Unknown user", forUser: String(format: "%@ %@", objcArg(username), objcArg(email)), ip: nil)

                            response.tokens.addError(NSLocalizedString("This username doesn't exist in our database.", comment: ""))
                        }
                    }, catch: { e in
                        NSLog("******* password_forgotten: %@", e)
                    })
                }
            }

            response.tokens.setObject(NSLocalizedString("Forgotten Password", comment: "Web portal, password forgotten, title"), forKey: "PageTitle" as NSString)
            response.templateString = self.portal?.string(forPath: "password_forgotten.html")
            response.mimeType = "text/html"
        }
    }


    @objc(processAccountHtml)
    public func processAccountHtml() {
        raisingToCaller {
            let response = self.response!

            guard let user = self.user else {
                return
            }

            if objcIsEqualToString(objcString(self.parameterValue("action")), "changePassword") {
                var password = objcString(self.parameterValue("password"))
                _ = self.stringParameter("sha1")

                user.convertPasswordToHashIfNeeded()

                let sha1internal = user.passwordHash as NSString?

                // A request without sha1 used to pass: [nil compare:] is 0, NSOrderedSame (#760).
                if (sha1internal?.length ?? 0) > 0,
                   let sha1 = self.parameter("sha1") as? String, sha1.isEmpty == false,
                   (sha1 as NSString).compare(sha1internal! as String, options: [.literal, .caseInsensitive]) == .orderedSame {
                    if objcIsEqualToString(objcString(self.parameterValue("password")), objcString(self.parameterValue("password2"))) {
                        var err: NSError? = nil
                        if !objcValidate({ try user.validatePassword(&password) }, &err) {
                            response.tokens.addError(err?.localizedDescription)
                        } else {
                            // We can update the user password

//                            if( [previouspassword isEqualToString: @"public"] && [self.user.name isEqualToString:@"public"])
//                            {
//                                // public / public demo account not editable
//                                [response.tokens addMessage:NSLocalizedString(@"Public account not editable!", nil)];
//                            }
//                            else
                            do {
                                user.password = password as String?

                                user.convertPasswordToHashIfNeeded()

                                try? user.managedObjectContext?.save()
                                response.tokens.addMessage(NSLocalizedString("Password updated successfully!", comment: ""))
                                self.portal?.updateLogEntry(forStudy: nil, withMessage: String(format: "User changed his password"), forUser: self.user?.name, ip: self.asyncSocket?.connectedHost())
                            }
                        }
                    }
                    else {
                        response.tokens.addError(NSLocalizedString("The new password wasn't repeated correctly.", comment: ""))
                    }
                }
                else {
                    response.tokens.addError(NSLocalizedString("Wrong current password.", comment: ""))
                }
            }

            if objcIsEqualToString(objcString(self.parameterValue("action")), "changeSettings") {
                objcSetProperty(user, "setEmail:", self.parameterValue("email"))
                objcSetProperty(user, "setAddress:", self.parameterValue("address"))
                objcSetProperty(user, "setPhone:", self.parameterValue("phone"))

                if objcIsEqualToString(objcString(self.parameterValue("emailNotification"))?.lowercased as NSString?, "on") {
                    user.emailNotification = NSNumber(value: true)
                } else {
                    user.emailNotification = NSNumber(value: false)
                }

                if objcIsEqualToString(objcString(self.parameterValue("showRecentPatients"))?.lowercased as NSString?, "on") {
                    user.showRecentPatients = NSNumber(value: true)
                } else {
                    user.showRecentPatients = NSNumber(value: false)
                }

                try? user.managedObjectContext?.save()

                response.tokens.addMessage(NSLocalizedString("Personal information updated successfully!", comment: ""))
            }

            response.tokens.setObject(String(format: NSLocalizedString("Account information for: %@", comment: "Web portal, account, title format (%@ is user.name)"), objcArg(user.name)), forKey: "PageTitle" as NSString)
            response.templateString = self.portal?.string(forPath: "account.html")
            response.mimeType = "text/html"
        }
    }

    // MARK: Administration HTML

    @objc(processAdminIndexHtml)
    public func processAdminIndexHtml() {
        raisingToCaller {
            let response = self.response!
            let user = self.user

            if !(user?.isAdmin?.boolValue ?? false) {
                response.setStatusCode(401)
                self.portal?.updateLogEntry(forStudy: nil, withMessage: "Attempt to access admin area without being an admin", forUser: user?.name, ip: self.asyncSocket?.connectedHost())
                return
            }

            response.tokens.setObject(NSLocalizedString("Administration", comment: "Web Portal, admin, index, title"), forKey: "PageTitle" as NSString)

            let idatabase = self.independentWebDatabase
            objcSetObject(response.tokens, (idatabase?.objects(forEntity: idatabase?.userEntity()) as NSArray?)?.sortedArray(using: [NSSortDescriptor(key: "name", ascending: true)]) as NSArray?, forKey: "Users")

            response.templateString = self.portal?.string(forPath: "admin/index.html")
            response.mimeType = "text/html"
        }
    }

    @objc(processAdminUserHtml)
    public func processAdminUserHtml() {
        raisingToCaller {
            let response = self.response!
            let user = self.user

            if !(user?.isAdmin?.boolValue ?? false) {
                response.setStatusCode(401)
                self.portal?.updateLogEntry(forStudy: nil, withMessage: "Attempt to access admin area without being an admin", forUser: user?.name, ip: self.asyncSocket?.connectedHost())
                return
            }

            var luser: NSObject? = nil
            var userRecycleParams = false
            let action = self.stringParameter("action")
            var originalName: NSString? = nil

            let idatabase = self.independentWebDatabase

            if objcIsEqualToString(action, "delete") {
                originalName = self.stringParameter("originalName")
                let tempUser = idatabase?.user(withName: originalName as String?)
                if tempUser == nil {
                    response.tokens.addError(String(format: NSLocalizedString("Couldn't delete user <b>%@</b> because he doesn't exist.", comment: "Web Portal, admin, user edition, delete error (%@ is user.name)"), objcArg(originalName)))
                } else {
                    idatabase?.managedObjectContext.delete(tempUser!)
                    _ = idatabase?.save()
                    response.tokens.addMessage(String(format: NSLocalizedString("User <b>%@</b> successfully deleted.", comment: "Web Portal, admin, user edition, delete ok (%@ is user.name)"), objcArg(originalName)))
                }
            }

            if objcIsEqualToString(action, "save") {
                originalName = self.stringParameter("originalName")
                let webUser = idatabase?.user(withName: originalName as String?)
                if webUser == nil {
                    response.tokens.addError(String(format: NSLocalizedString("Couldn't save changes for user <b>%@</b> because he doesn't exist.", comment: "Web Portal, admin, user edition, save error (%@ is user.name)"), objcArg(originalName)))
                    userRecycleParams = true
                } else {
                    let webUser = webUser!
                    // NSLog(@"SAVE params: %@", parameters.description);

                    var name = self.stringParameter("name")?.trimmingCharacters(in: .whitespacesAndNewlines) as NSString?
                    var newPassword = self.stringParameter("newPassword")?.trimmingCharacters(in: .whitespacesAndNewlines) as NSString?
                    let newPassword2 = self.stringParameter("newPassword2")?.trimmingCharacters(in: .whitespacesAndNewlines) as NSString?
                    var studyPredicate = self.stringParameter("studyPredicate")
                    var downloadZIP: NSNumber? = NSNumber(value: objcIsEqualToString(self.stringParameter("downloadZIP"), "on"))

                    var err: NSError? = nil

                    err = nil
                    if !objcValidate({ try webUser.validateName(&name) }, &err) {
                        response.tokens.addError(err?.localizedDescription)
                    }
                    err = nil

                    if (newPassword?.length ?? 0) > 0 && !objcValidate({ try webUser.validatePassword(&newPassword) }, &err) {
                        response.tokens.addError(err?.localizedDescription)
                    }
                    err = nil
                    if !objcValidate({ try webUser.validateStudyPredicate(&studyPredicate) }, &err) {
                        response.tokens.addError(err?.localizedDescription)
                    }
                    err = nil
                    if !objcValidate({ try webUser.validateDownloadZIP(&downloadZIP) }, &err) {
                        response.tokens.addError(err?.localizedDescription)
                    }

                    if (newPassword?.length ?? 0) > 0 && objcIsEqualToString(newPassword, newPassword2) == false {
                        response.tokens.addError(NSLocalizedString("Passwords are not identical.", comment: ""))
                    }

                    if (response.tokens.errors() as NSArray?)?.count ?? 0 == 0 {
                        if (newPassword?.length ?? 0) > 0 && objcIsEqualToString(newPassword, newPassword2) {
                            if objcIsEqualToString(webUser.name as NSString?, name) == false {
                                webUser.name = name as String?
                            }

                            webUser.password = newPassword as String?
                            webUser.convertPasswordToHashIfNeeded()
                        }
                        else {
                            if objcIsEqualToString(webUser.name as NSString?, name) == false {
                                webUser.name = name as String?
                                response.tokens.addMessage(String(format: NSLocalizedString("User's name has changed. The password has been reset to a new password: %@", comment: ""), objcArg(webUser.password)))
                                webUser.convertPasswordToHashIfNeeded()
                            }
                        }

                        objcSetProperty(webUser, "setEmail:", self.parameter("email"))
                        objcSetProperty(webUser, "setPhone:", self.parameter("phone"))
                        objcSetProperty(webUser, "setAddress:", self.parameter("address"))
                        webUser.studyPredicate = studyPredicate as String?

                        webUser.autoDelete = NSNumber(value: objcIsEqualToString(self.stringParameter("autoDelete"), "on"))
                        webUser.downloadZIP = downloadZIP
                        webUser.emailNotification = NSNumber(value: objcIsEqualToString(self.stringParameter("emailNotification"), "on"))
                        webUser.showRecentPatients = NSNumber(value: objcIsEqualToString(self.stringParameter("showRecentPatients"), "on"))
                        webUser.encryptedZIP = NSNumber(value: objcIsEqualToString(self.stringParameter("encryptedZIP"), "on"))
                        webUser.uploadDICOM = NSNumber(value: objcIsEqualToString(self.stringParameter("uploadDICOM"), "on"))
                        webUser.downloadReport = NSNumber(value: objcIsEqualToString(self.stringParameter("downloadReport"), "on"))
                        webUser.sendDICOMtoSelfIP = NSNumber(value: objcIsEqualToString(self.stringParameter("sendDICOMtoSelfIP"), "on"))
                        webUser.uploadDICOMAddToSpecificStudies = NSNumber(value: objcIsEqualToString(self.stringParameter("uploadDICOMAddToSpecificStudies"), "on"))
                        webUser.sendDICOMtoAnyNodes = NSNumber(value: objcIsEqualToString(self.stringParameter("sendDICOMtoAnyNodes"), "on"))
                        webUser.shareStudyWithUser = NSNumber(value: objcIsEqualToString(self.stringParameter("shareStudyWithUser"), "on"))
                        webUser.createTemporaryUser = NSNumber(value: objcIsEqualToString(self.stringParameter("createTemporaryUser"), "on"))
                        webUser.canAccessPatientsOtherStudies = NSNumber(value: objcIsEqualToString(self.stringParameter("canAccessPatientsOtherStudies"), "on"))
                        webUser.canSeeAlbums = NSNumber(value: objcIsEqualToString(self.stringParameter("canSeeAlbums"), "on"))

                        if webUser.autoDelete?.boolValue ?? false {
                            objcSetProperty(webUser, "setDeletionDate:", HorosWebPortalDataCalendarDate(objcIntegerValue(self.parameter("deletionDate_year")), UInt(bitPattern: objcIntegerValue(self.parameter("deletionDate_month")) &+ 1), UInt(bitPattern: objcIntegerValue(self.parameter("deletionDate_day"))), 0, 0, 0))
                        }

                        let remainingStudies = NSMutableArray()
                        for studyXid in self.stringParameter("remainingStudies")?.components(separatedBy: ",") ?? [] {
                            // admin/user's escape() encodes each list item; the
                            // form has already decoded the enclosing list.
                            let studyXid = (studyXid as NSString).stringByTrimmingStartAndEnd().removingPercentEncoding as NSString?

                            if (studyXid?.length ?? 0) > 0 {
                                var wpStudy: WebPortalStudy? = nil
                                // this is Mac OS X 10.6 SnowLeopard only // wpStudy = [webUser.managedObjectContext existingObjectWithID:[webUser.managedObjectContext.persistentStoreCoordinator managedObjectIDForURIRepresentation:[NSURL URLWithString:studyObjectID]] error:NULL];
                                for iwpStudy in objcSet(webUser, "studies") {
                                    let iwpStudy = unsafeDowncast(iwpStudy as AnyObject, to: WebPortalStudy.self)
                                    if objcIsEqualToString(iwpStudy.xid() as NSString?, studyXid) {
                                        wpStudy = iwpStudy
                                        break
                                    }
                                }

                                if let wpStudy = wpStudy {
                                    remainingStudies.add(wpStudy)
                                } else {
                                    NSLog("Warning: Web Portal user %@ is referencing a study with CoreData ID %@, which doesn't exist", objcArg(self.user?.name), objcArg(studyXid))
                                }
                            }
                        }
                        for iwpStudy in objcSet(webUser, "studies").allObjects {
                            if !remainingStudies.contains(iwpStudy) {
                                webUser.removeStudiesObject(unsafeDowncast(iwpStudy as AnyObject, to: WebPortalStudy.self))
                            }
                        }

                        _ = idatabase?.save()

                        response.tokens.addMessage(String(format: NSLocalizedString("Changes for user <b>%@</b> successfully saved.", comment: ""), objcArg(webUser.name)))
                        luser = webUser
                    } else {
                        userRecycleParams = true
                    }
                }
            }

            if objcIsEqualToString(action, "new") {
                luser = idatabase?.webPortalDataNewUser()
            }

            if action == nil { // edit
                originalName = self.stringParameter("name")
                luser = idatabase?.user(withName: originalName as String?)
                if luser == nil {
                    response.tokens.addError(String(format: NSLocalizedString("Couldn't find user with name <b>%@</b>.", comment: ""), objcArg(originalName)))
                }
            }

            response.tokens.setObject(String(format: NSLocalizedString("User Administration: %@", comment: ""), objcArg(luser != nil ? luser!.value(forKey: "name") : originalName)), forKey: "PageTitle" as NSString)
            if let luser = luser {
                objcSetObject(response.tokens, WebPortalProxy.create(with: luser, transformer: WebPortalUserTransformer.create()), forKey: "EditedUser")
            } else if userRecycleParams {
                objcSetObject(response.tokens, self.parameters, forKey: "EditedUser")
            }

            response.templateString = self.portal?.string(forPath: "admin/user.html")
            response.mimeType = "text/html"
        }
    }

    // MARK: JSON

    @objc(processStudyListJson)
    public func processStudyListJson() {
        raisingToCaller {
            let response = self.response!
            if self.studyList_requestsUnknownAlbum() {
                response.setStatusCode(404)
                return
            }
            let studies = self.studyList_requestedStudies(nil)

//            [self.portal.dicomDatabase.managedObjectContext lock];
            objcTry({
                let r = NSMutableArray()
                for study in studies ?? NSArray() {
                    // A distant study (PACS On Demand) is answered the DicomStudy messages too.
                    let study = unsafeDowncast(study as AnyObject, to: DicomStudy.self)
                    let s = NSMutableDictionary()

                    s.setObject(objcNonNull(study.name), forKey: "name" as NSString)
                    s.setObject(NSNumber(value: Int32(truncatingIfNeeded: objcSetCount(study, "series"))).stringValue, forKey: "seriesCount" as NSString)
                    // A study without a date (a DICOMDIR without StudyDate) is listed with an
                    // empty date, like the other fields; a nil raised and lost the whole list (#759).
                    s.setObject(objcNonNull(objcStringFromDate(UserDefaults.dateTimeFormatter(), study.date)), forKey: "date" as NSString)
                    s.setObject(objcNonNull(study.studyName), forKey: "studyName" as NSString)
                    s.setObject(objcNonNull(study.modality), forKey: "modality" as NSString)

                    // (NSString*)study.stateText: a number, replaced by its label when not zero
                    var stateText: AnyObject? = study.stateText
                    if objcIntValue(stateText) != 0 {
                        stateText = (BrowserController.statesArray() as NSArray?)?.object(at: Int(objcIntValue(stateText))) as AnyObject?
                    }
                    s.setObject(stateText ?? ("" as NSString), forKey: "stateText" as NSString)

                    s.setObject(objcNonNull(study.studyInstanceUID), forKey: "studyInstanceUID" as NSString)
                    let origin = DicomDatabase(for: study.managedObjectContext)
                    s.setObject(FederatedSearch.displayOrigin(name: origin?.name, path: origin?.baseDirPath), forKey: "origin" as NSString)
                    s.setObject(FederatedSearch.permissionLabel(forPredicate: self.user?.studyPredicate), forKey: "permission" as NSString)

                    r.add(s)
                }

                response.setDataWith(r.jsonRepresentation() as String?)
            }, catch: { e in
                NSLog("Error: [WebPortalResponse processStudyListJson:] %@", e)
            })
//            [self.portal.dicomDatabase.managedObjectContext unlock];
        }
    }

    @objc(processSeriesJson)
    public func processSeriesJson() {
        raisingToCaller {
            let response = self.response!
            let seriesObject = self.objectWithXID(self.stringParameter("xid")) as AnyObject?
            guard let series = seriesObject.map({ unsafeDowncast($0, to: DicomSeries.self) }) else {
                return
            }

            var imagesArray = objcSet(series, "images").allObjects as NSArray
            objcTry({ // Sort images with "instanceNumber"
                let sort = NSSortDescriptor(key: "instanceNumber", ascending: true)
                let sortDescriptors = [sort]
                imagesArray = imagesArray.sortedArray(using: sortDescriptors) as NSArray
            }, catch: { _ in /* ignore */ })


//            [self.portal.dicomDatabase.managedObjectContext lock];
            objcTry({
                let jsonImagesArray = NSMutableArray()
                for image in imagesArray {
                    let image = unsafeDowncast(image as AnyObject, to: DicomImage.self)
                    if let sopInstanceUID = image.sopInstanceUID() {
                        jsonImagesArray.add(sopInstanceUID)
                    }
                }
                response.setDataWith(jsonImagesArray.jsonRepresentation() as String?)
            }, catch: { e in
                NSLog("***** jsonImageListForImages exception: %@", e)
            })
//            [self.portal.dicomDatabase.managedObjectContext unlock];
        }
    }

    @objc(processAlbumsJson)
    public func processAlbumsJson() {
        raisingToCaller {
            let response = self.response!
            let jsonAlbumsArray = NSMutableArray()

            for album in (self.independentDicomDatabase?.albums() as NSArray?) ?? NSArray() {
                let album = unsafeDowncast(album as AnyObject, to: DicomAlbum.self)
                if !objcIsEqualToString(album.name as NSString?, NSLocalizedString("Database", comment: "") as NSString) {
                    let albumDictionary = NSMutableDictionary()

                    albumDictionary.setObject(objcNonNull(album.name), forKey: "name" as NSString)
                    let queryValueAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
                    albumDictionary.setObject(objcNonNull(album.name?.addingPercentEncoding(withAllowedCharacters: queryValueAllowed)), forKey: "nameURLSafe" as NSString)

                    if (album.smartAlbum?.int32Value ?? 0) == 1 {
                        albumDictionary.setObject("SmartAlbum", forKey: "type" as NSString)
                    } else {
                        albumDictionary.setObject("Album", forKey: "type" as NSString)
                    }

                    jsonAlbumsArray.add(albumDictionary)
                }
            }

            response.setDataWith(jsonAlbumsArray.jsonRepresentation() as String?)
        }
    }

    @objc(processSeriesListJson)
    public func processSeriesListJson() {
        raisingToCaller {
            let response = self.response!
            let studyObject = self.objectWithXID(self.stringParameter("xid")) as AnyObject?
            guard let study = studyObject.map({ unsafeDowncast($0, to: DicomStudy.self) }) else {
                return
            }

            let jsonSeriesArray = NSMutableArray()

//            [self.portal.dicomDatabase.managedObjectContext lock];
            objcTry({
                for s in (study.imageSeries() as NSArray?) ?? NSArray() {
                    let s = unsafeDowncast(s as AnyObject, to: DicomSeries.self)
                    let seriesDictionary = NSMutableDictionary()

                    objcSetObject(seriesDictionary, s.seriesInstanceUID, forKey: "seriesInstanceUID")
                    objcSetObject(seriesDictionary, s.seriesDICOMUID, forKey: "seriesDICOMUID")

                    let dicomImageArray = objcSet(s, "images").allObjects as NSArray
                    let imObject: Any? = dicomImageArray.count == 1 ? dicomImageArray.lastObject : dicomImageArray.object(at: dicomImageArray.count / 2)
                    let im = imObject.map { unsafeDowncast($0 as AnyObject, to: DicomImage.self) }

                    objcSetObject(seriesDictionary, im?.sopInstanceUID(), forKey: "keyInstanceUID")

                    jsonSeriesArray.add(seriesDictionary)
                }
            }, catch: { e in
                NSLog("******* jsonSeriesListForSeries exception: %@", e)
            })
//            [self.portal.dicomDatabase.managedObjectContext unlock];

            response.setDataWith(jsonSeriesArray.jsonRepresentation() as String?)
        }
    }


    // MARK: WADO

    @objc(wadoCache)
    func wadoCache() -> NSMutableDictionary? {
        return raisingToCaller {
            let WadoCacheKey = "WADO Cache"
            var dict: NSMutableDictionary? = nil
            objcSynchronized(self.portal?.cache) {
                dict = self.portal?.cache?.object(forKey: WadoCacheKey) as? NSMutableDictionary
                if dict == nil {
                    dict = NSMutableDictionary(capacity: WadoCacheSize)
                    self.portal?.cache?.setObject(dict!, forKey: WadoCacheKey as NSString)
                }
            }
            return dict
        }
    }

    @objc(wadoSOPInstanceUIDCache)
    func wadoSOPInstanceUIDCache() -> NSMutableDictionary? {
        return raisingToCaller {
            let WadoSOPInstanceUIDCacheKey = "WADO SOPInstanceUID Cache"
            var dict: NSMutableDictionary? = nil
            objcSynchronized(self.portal?.cache) {
                dict = self.portal?.cache?.object(forKey: WadoSOPInstanceUIDCacheKey) as? NSMutableDictionary
                if dict == nil {
                    dict = NSMutableDictionary(capacity: WadoSOPInstanceUIDCacheSize)
                    self.portal?.cache?.setObject(dict!, forKey: WadoSOPInstanceUIDCacheKey as NSString)
                }
            }
            return dict
        }
    }

    // wado?requestType=WADO&studyUID=XXXXXXXXXXX&seriesUID=XXXXXXXXXXX&objectUID=XXXXXXXXXXX
    // 127.0.0.1:3333/wado?requestType=WADO&frameNumber=1&studyUID=2.16.840.1.113669.632.20.1211.10000591592&seriesUID=1.3.6.1.4.1.19291.2.1.2.2867252960399100001&objectUID=1.3.6.1.4.1.19291.2.1.3.2867252960616100004
    @objc(processWado)
    public func processWado() {
        raisingToCaller {
            let response = self.response!
            let user = self.user

            if !(self.portal?.wadoEnabled ?? false) {
                self.response.setStatusCode(403)
                self.response.setDataWith(NSLocalizedString("IsiX DICOM Viewer cannot fulfill your request because the WADO service is disabled.", comment: ""))
                return
            }

            if !objcIsEqualToString(self.stringParameter("requestType")?.lowercased as NSString?, "wado") {
                self.response.setStatusCode(404)
                return
            }

            if UserDefaults.standard.bool(forKey: "wadoRequestRequireValidToken") {
                let token = self.stringParameter("token")

                var tokenFound = false

                for isession in (self.portal?.sessions as NSArray?) ?? NSArray() {
                    if unsafeDowncast(isession as AnyObject, to: WebPortalSession.self).containsToken(token as String?) {
                        tokenFound = true
                        break
                    }
                }

                if tokenFound == false {
                    if (self.stringParameter("studyUID")?.length ?? 0) == 0 || (self.stringParameter("seriesUID")?.length ?? 0) == 0 || (self.stringParameter("objectUID")?.length ?? 0) == 0 {
                        Thread.sleep(forTimeInterval: 1)
                        self.response.setStatusCode(401)
                        self.response.setDataWith(NSLocalizedString("Unauthorized WADO access - no valid token or incomplete request", comment: ""))
                        return
                    }
                }
            }

            let studyUID = self.stringParameter("studyUID")
            let seriesUID = self.stringParameter("seriesUID")
            let objectUID = self.stringParameter("objectUID")

            if objectUID == nil && ((seriesUID?.length ?? 0) > 0 || (studyUID?.length ?? 0) > 0) { // This is a 'special case', not officially supported by DICOM standard : we take all the series or study objects -> zip them -> send them
                let study = self.studyForStudyInstanceUID(studyUID, server: nil)

                var allSeries = (study?.value(forKey: "series") as? NSSet)?.allObjects as NSArray?

                if let seriesUID = seriesUID {
                    allSeries = allSeries?.filtered(using: NSPredicate(format: "seriesDICOMUID == %@", seriesUID)) as NSArray?
                }

                var allImages = NSArray()
                for series in allSeries ?? NSArray() {
                    allImages = allImages.addingObjects(from: (((series as AnyObject).value(forKey: "images") as? NSSet)?.allObjects) ?? []) as NSArray
                }

                if allImages.count > 0 {
                    // Zip them

                    // The portal's own temporary folder: in /tmp, named after the study,
                    // another user could put the folder or the archive in place (#801).
                    var srcFolder: NSString? = WebPortalConnection.tmpDirPath() as NSString
                    var destFile: NSString? = WebPortalConnection.tmpDirPath() as NSString

                    srcFolder = objcAppendingPathComponent(srcFolder, objcFilenameString((allImages.lastObject as AnyObject?)?.value(forKeyPath: "series.study.name")))
                    destFile = objcAppendingPathComponent(destFile, objcFilenameString((allImages.lastObject as AnyObject?)?.value(forKeyPath: "series.study.name")))

                    destFile = destFile?.appendingFormat("-%d", uniqueInc.wrappingAdd(1, ordering: .sequentiallyConsistent).oldValue) as NSString?

                    // The archive itself has always been a plain zip; only the label was
                    // application specific, and it was sent to every client.
                    let archiveFormat = WebPortalArchiveFormat.format(forRequestedPath: self.requestedPath, parameters: self.parameters as? [String: Any], clientIsMacOS: self.requestIsMacOS())
                    destFile = objcAppendingPathExtension(destFile, archiveFormat.pathExtension)

                    if let srcFolder = srcFolder {
                        try? FileManager.default.removeItem(atPath: srcFolder as String)
                    }
                    if let destFile = destFile {
                        try? FileManager.default.removeItem(atPath: destFile as String)
                    }

                    FileManager.default.confirmDirectory(atPath: srcFolder as String?)

                    BrowserController.encryptFiles(allImages.value(forKey: "completePath") as? [Any], inZIPFile: destFile as String?, password: (user?.encryptedZIP?.boolValue ?? false) ? user?.password : nil)

                    let archiveStudyName = (allImages.lastObject as AnyObject?)?.value(forKeyPath: "series.study.name")

                    self.response.data = destFile.flatMap { NSData(contentsOfFile: $0 as String) } as Data?
                    self.response.setStatusCode(0)
                    self.response.mimeType = archiveFormat.mimeType
                    // Without this the client saved the archive under the last path
                    // component of the URL, whatever the study is called.
                    self.response.mutableHTTPHeaders.setObject(archiveFormat.contentDisposition(forStudyName: archiveStudyName as? String), forKey: "Content-Disposition" as NSString)

                    if let srcFolder = srcFolder {
                        try? FileManager.default.removeItem(atPath: srcFolder as String)
                    }
                    if let destFile = destFile {
                        try? FileManager.default.removeItem(atPath: destFile as String)
                    }

                    self.portal?.updateLogEntry(forStudy: study, withMessage: "WADO Send", forUser: user?.name, ip: self.asyncSocket?.connectedHost())

                    return
                }
            }

            let contentType = (self.stringParameter("contentType")?.lowercased as NSString?)?.components(separatedBy: ",").first as NSString?
            let rows = objcIntValue(self.parameter("rows"))
            let columns = objcIntValue(self.parameter("columns"))
            let windowCenter = objcIntValue(self.parameter("windowCenter"))
            let windowWidth = objcIntValue(self.parameter("windowWidth"))
            let frameNumber = objcIntValue(self.parameter("frameNumber"))    // -> OsiriX stores frames as images
            var imageQuality = Int32(DCMLosslessQuality.rawValue)

            let imageQualityParam = self.stringParameter("imageQuality")
            if let imageQualityParam = imageQualityParam {
                let imageQualityParamInt = imageQualityParam.intValue
                if imageQualityParamInt > 80 {
                    imageQuality = Int32(DCMLosslessQuality.rawValue)
                } else if imageQualityParamInt > 60 {
                    imageQuality = Int32(DCMHighQuality.rawValue)
                } else if imageQualityParamInt > 30 {
                    imageQuality = Int32(DCMMediumQuality.rawValue)
                } else if imageQualityParamInt >= 0 {
                    imageQuality = Int32(DCMLowQuality.rawValue)
                }
            }

            let transferSyntax = self.stringParameter("transferSyntax")?.lowercased as NSString?
            let useOrig = self.stringParameter("useOrig")?.lowercased as NSString?

            let dbRequest = NSFetchRequest<NSFetchRequestResult>()
            dbRequest.entity = self.independentDicomDatabase?.studyEntity()

            objcTry({
                var imageCache: NSMutableDictionary? = nil
                var images: NSArray? = nil

                do { // @synchronized(nil) runs its block unlocked
                    let wadoCache = self.wadoCache()
                    objcSynchronized(wadoCache) {
                        if (self.wadoCache()?.count ?? 0) > WadoCacheSize {
                            self.wadoCache()?.removeAllObjects()
                        }
                    }
                }

                do { // @synchronized(nil) runs its block unlocked
                    let wadoSOPInstanceUIDCache = self.wadoSOPInstanceUIDCache()
                    objcSynchronized(wadoSOPInstanceUIDCache) {
                        if (self.wadoSOPInstanceUIDCache()?.count ?? 0) > WadoSOPInstanceUIDCacheSize {
                            self.wadoSOPInstanceUIDCache()?.removeAllObjects()
                        }
                    }
                }

                var cachedPathForSOPInstanceUID: NSString? = nil

                if (contentType?.length ?? 0) == 0 || objcIsEqualToString(contentType, "image/jpeg") || objcIsEqualToString(contentType, "image/png") || objcIsEqualToString(contentType, "image/gif") || objcIsEqualToString(contentType, "image/jp2") {
                    do { // @synchronized(nil) runs its block unlocked
                        let wadoCache = self.wadoCache()
                        objcSynchronized(wadoCache) {
                            imageCache = objectUID.flatMap { self.wadoCache()?.object(forKey: $0.appendingFormat("%d", frameNumber)) } as? NSMutableDictionary
                        }
                    }
                }
                else if objcIsEqualToString(contentType, "application/dicom") {
                    do { // @synchronized(nil) runs its block unlocked
                        let wadoSOPInstanceUIDCache = self.wadoSOPInstanceUIDCache()
                        objcSynchronized(wadoSOPInstanceUIDCache) {
                            cachedPathForSOPInstanceUID = objectUID.flatMap { self.wadoSOPInstanceUIDCache()?.object(forKey: $0) } as? NSString
                        }
                    }
                }

                if imageCache == nil && cachedPathForSOPInstanceUID == nil {
                    var predicate1: NSPredicate? = nil
                    if let studyUID = studyUID {
                        predicate1 = NSPredicate(format: "studyInstanceUID == %@", studyUID)
                    }

                    let studies = self.independentDicomDatabase?.objects(forEntity: self.independentDicomDatabase?.studyEntity(), predicate: predicate1) as NSArray?

                    if (studies?.count ?? 0) == 0 {
                        NSLog("****** WADO Server : study not found")
                    }

                    if (studies?.count ?? 0) > 1 {
                        NSLog("****** WADO Server : more than 1 study with same uid : %d", Int32(truncatingIfNeeded: studies?.count ?? 0))
                    }

                    var allSeries = NSArray()

                    for s in studies ?? NSArray() {
                        allSeries = allSeries.addingObjects(from: (((s as AnyObject).value(forKey: "series") as? NSSet)?.allObjects) ?? []) as NSArray
                    }

                    if let seriesUID = seriesUID, studyUID == nil { // If a studyUID is specified, take all seriesUID (OsiriX can merge multiple seriesUID: combine CR, for example...)
                        allSeries = allSeries.filtered(using: NSPredicate(format: "seriesDICOMUID == %@", seriesUID)) as NSArray
                    }

                    var allImages = NSArray()
                    for series in allSeries {
                        allImages = allImages.addingObjects(from: (((series as AnyObject).value(forKey: "images") as? NSSet)?.allObjects) ?? []) as NSArray
                    }

                    //We will cache all the paths for these sopInstanceUIDs

                    do { // @synchronized(nil) runs its block unlocked
                        let wadoSOPInstanceUIDCache = self.wadoSOPInstanceUIDCache()
                        objcSynchronized(wadoSOPInstanceUIDCache) {
                            for image in allImages {
                                let image = unsafeDowncast(image as AnyObject, to: DicomImage.self)
                                objcSetObject(self.wadoSOPInstanceUIDCache(), image.completePath(), forKey: image.sopInstanceUID())
                            }
                        }
                    }

                    let predicate = NSComparisonPredicate(leftExpression: NSExpression(forKeyPath: "compressedSopInstanceUID"), rightExpression: NSExpression(forConstantValue: DicomImage.sopInstanceUIDEncode(objectUID as String?)), customSelector: NSSelectorFromString("isEqualToSopInstanceUID:"))
                    let N2NonNullStringPredicate = NSPredicate(format: "compressedSopInstanceUID != NIL")

                    images = (allImages.filtered(using: N2NonNullStringPredicate) as NSArray).filtered(using: predicate) as NSArray

                    if (images?.count ?? 0) > 1 {
                        images = images?.sortedArray(using: [NSSortDescriptor(key: "instanceNumber", ascending: true)]) as NSArray?

                        if UInt(bitPattern: Int(frameNumber)) < UInt(images?.count ?? 0) {
                            images = NSArray(object: images!.object(at: Int(frameNumber)))
                        }
                    }

                    if (images?.count ?? 0) > 0 {
                        self.portal?.updateLogEntry(forStudy: studies?.lastObject as? NSManagedObject, withMessage: "WADO Send", forUser: self.user?.name, ip: self.asyncSocket?.connectedHost())
                    }

                    cachedPathForSOPInstanceUID = (images?.lastObject as AnyObject?)?.value(forKey: "completePath") as? NSString
                }

                if (images?.count ?? 0) > 0 || imageCache != nil || cachedPathForSOPInstanceUID != nil {
                    if objcIsEqualToString(contentType, "application/dicom") {
                        autoreleasepool {
                            var ts = DCMTransferSyntax(ts: transferSyntax as String?)

                            if (useOrig?.boolValue ?? false) == true || ts == nil || objcIsEqualToString(ts?.name as NSString?, "Unknown Syntax") {
                                response.data = cachedPathForSOPInstanceUID.flatMap { NSData(contentsOfFile: $0 as String) } as Data?
                            }
                            else {
                                if ts!.isEqual(to: objcTransferSyntax("JPEG2000LosslessTransferSyntax")) ||
                                    ts!.isEqual(to: objcTransferSyntax("JPEG2000LossyTransferSyntax")) ||
                                    ts!.isEqual(to: objcTransferSyntax("JPEGBaselineTransferSyntax")) ||
                                    ts!.isEqual(to: objcTransferSyntax("JPEGLossless14TransferSyntax")) ||
                                    ts!.isEqual(to: objcTransferSyntax("JPEGLSLosslessTransferSyntax")) ||
                                    ts!.isEqual(to: objcTransferSyntax("JPEGLSLossyTransferSyntax")) ||
                                    ts!.isEqual(to: objcTransferSyntax("JPEGBaselineTransferSyntax")) {

                                }
                                else { // Explicit VR Little Endian
                                    ts = objcTransferSyntax("ExplicitVRLittleEndianTransferSyntax")
                                }

                                response.data = BrowserController.currentBrowser()?.getDICOMFile(cachedPathForSOPInstanceUID as String?, inSyntax: ts?.transferSyntax, quality: imageQuality)
                            }
                        }
                        //err = NO;
                    }
                    else if objcIsEqualToString(contentType, "video/mpeg") {
                        let im = images?.lastObject as AnyObject?

                        var dicomImageArray = ((im?.value(forKey: "series") as AnyObject?)?.value(forKey: "images") as? NSSet)?.allObjects as NSArray?

                        objcTry({
                            // Sort images with "instanceNumber"
                            let sort = NSSortDescriptor(key: "instanceNumber", ascending: true)
                            let sortDescriptors = [sort]
                            dicomImageArray = dicomImageArray?.sortedArray(using: sortDescriptors) as NSArray?
                        }, catch: { e in
                            NSLog("%@", e.description)
                        })

                        if (dicomImageArray?.count ?? 0) > 1 {
                            let path = WebPortalConnection.tmpDirPath()
                            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)

                            // Named after the series and the size asked for: a WADO request has
                            // no xid, so every series wrote to the same "(null)" movie. Only the
                            // name loses what a file name cannot hold; over the whole path it
                            // lost the slashes too, and the movie went to the working directory
                            // (#761).
                            let series = (im?.value(forKey: "series") as AnyObject?)?.value(forKey: "seriesInstanceUID") as? String ?? ""
                            let name = NSMutableString(format: "%@-WADOMpeg-%d-%dx%d", series as NSString, Int32(truncatingIfNeeded: dicomImageArray?.count ?? 0), Int32(truncatingIfNeeded: rows), Int32(truncatingIfNeeded: columns))
                            objcReplaceNotAdmitted(name)

                            let fileName = NSMutableString(string: (path as NSString).appendingPathComponent(name as String))
                            fileName.append(".mov")

                            let outFile: NSString
                            if self.requestIsIOS() {
                                outFile = String(format: "%@2.mp4", fileName.deletingPathExtension) as NSString
                            } else {
                                outFile = fileName
                            }

                            let dict = objcMutableDictionary([/*[NSNumber numberWithBool: self.requestIsIOS], GenerateMovieIsIOSParamKey,*/ /*fileURL, @"fileURL",*/ (fileName, GenerateMovieFileNameParamKey), (outFile, GenerateMovieOutFileParamKey), (self.parameters, "parameters"), (dicomImageArray, GenerateMovieDicomImagesParamKey), (NSNumber(value: rows), "rows"), (NSNumber(value: columns), "columns")])

                            self.generateMovie(dict)

                            self.response.data = NSData(contentsOfFile: outFile as String) as Data?
                        }
                    }
                    else { // image/jpeg
                        var dcmPix = imageCache?.value(forKey: "dcmPix") as? DCMPix

                        if dcmPix != nil {
                            // It's in the cache
                        }
                        else if (images?.count ?? 0) > 0 {
                            let im = images!.lastObject as AnyObject

                            dcmPix = DCMPix(path: im.value(forKey: "completePathResolved") as? String, 0, 1, nil, Int(frameNumber), Int(objcIntValue(im.value(forKeyPath: "series.id"))), isBonjour: false, imageObj: im as? NSManagedObject)

                            if dcmPix == nil {
                                NSLog("****** dcmPix creation failed for file : %@", objcArg(im.value(forKey: "completePathResolved")))
                                let count = Int(objcIntValue(im.value(forKey: "width")) &* objcIntValue(im.value(forKey: "height")))
                                let imPtr = malloc(count &* MemoryLayout<Float>.size)!.assumingMemoryBound(to: Float.self)
                                var i: Int32 = 0
                                while i < objcIntValue(im.value(forKey: "width")) &* objcIntValue(im.value(forKey: "height")) {
                                    imPtr[Int(i)] = Float(i)
                                    i += 1
                                }

                                dcmPix = DCMPix(data: imPtr, 32, Int(objcIntValue(im.value(forKey: "width"))), Int(objcIntValue(im.value(forKey: "height"))), 0, 0, 0, 0, 0)
                            }

                            imageCache = objcDictionaryWithObject(NSMutableDictionary.self, dcmPix, forKey: "dcmPix") as? NSMutableDictionary

                            do { // @synchronized(nil) runs its block unlocked
                                let wadoCache = self.wadoCache()
                                objcSynchronized(wadoCache) {
                                    objcSetObject(self.wadoCache(), imageCache, forKey: objectUID?.appendingFormat("%d", frameNumber))
                                }
                            }
                        }

                        if let dcmPix = dcmPix {
                            var image: NSImage? = nil
                            let im = self.independentDicomDatabase?.object(withID: dcmPix.imageObjectID) as AnyObject?

                            var curWW = Float(windowWidth)
                            var curWL = Float(windowCenter)

                            if curWW == 0 && (im?.value(forKey: "series") as AnyObject?)?.value(forKey: "windowWidth") != nil {
                                curWW = objcNumber((im?.value(forKey: "series") as AnyObject?)?.value(forKey: "windowWidth")).floatValue
                                curWL = objcNumber((im?.value(forKey: "series") as AnyObject?)?.value(forKey: "windowLevel")).floatValue
                            }

                            if curWW == 0 {
                                curWW = dcmPix.savedWW
                                curWL = dcmPix.savedWL
                            }

                            self.response.data = imageCache?.object(forKey: String(format: "%@ %f %f %d %d %d", objcArg(contentType), Double(curWW), Double(curWL), columns, rows, frameNumber)) as? Data

                            if (self.response.data?.count ?? 0) == 0 {
                                // The DCMPix is shared by every request for this object and frame
                                // (wadoCache). Once it has an 8-bit representation,
                                // -checkImageAvailble:: only stores the window it is given, as it
                                // is: (0, 0), which a request without a window makes for a series
                                // without one, became a window of width zero, and the second
                                // rendering came out white wherever the first was not black.
                                // -changeWLWW:: reads (0, 0) as "choose the window", which is
                                // what the first rendering did through -allocate8bitRepresentation,
                                // and without a representation it is -checkImageAvailble:: itself.
                                dcmPix.changeWLWW(curWL, curWW)

                                image = dcmPix.image()
                                var width = Float(image?.size.width ?? 0)
                                var height = Float(image?.size.height ?? 0)

                                let maxWidth = columns
                                let maxHeight = rows

                                var resize = false

                                if width > Float(maxWidth) && maxWidth > 0 {
                                    height = height * Float(maxWidth) / width
                                    width = Float(maxWidth)
                                    resize = true
                                }

                                if height > Float(maxHeight) && maxHeight > 0 {
                                    width = width * Float(maxHeight) / height
                                    height = Float(maxHeight)
                                    resize = true
                                }

                                let newImage: NSImage?

                                if resize {
                                    newImage = image?.imageByScalingProportionally(toSize: NSMakeSize(CGFloat(width), CGFloat(height)))
                                } else {
                                    newImage = image
                                }

                                let imageRep = newImage?.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }
                                let imageProps: [NSBitmapImageRep.PropertyKey: Any] = [.compressionFactor: NSNumber(value: Float(0.8))]

                                if objcIsEqualToString(contentType, "image/gif") {
                                    self.response.data = imageRep?.representation(using: .gif, properties: imageProps)
                                } else if objcIsEqualToString(contentType, "image/png") {
                                    self.response.data = imageRep?.representation(using: .png, properties: imageProps)
                                } else if objcIsEqualToString(contentType, "image/jp2") {
                                    self.response.data = imageRep?.representation(using: .jpeg2000, properties: imageProps)
                                } else {
                                    self.response.data = imageRep?.representation(using: .jpeg, properties: imageProps)
                                }

                                objcSetObject(imageCache, self.response.data as NSData?, forKey: String(format: "%@ %f %f %d %d %d", objcArg(contentType), Double(curWW), Double(curWL), columns, rows, frameNumber))
                            }

                            if let contentType = contentType {
                                self.response.mimeType = contentType as String
                            }

                            // Alessandro: I'm not sure here, from Joris' code it seems WADO must always return HTTP 200, eventually with length 0..
//                            NSData *noData = self.response.data;
                            self.response.setStatusCode(0)
                        }
                    }
                }
                else {
                    NSLog("****** WADO Server : image uid not found ! %@", objcArg(objectUID))
                }

                if self.response.data == nil {
                    self.response.data = Data()
                }

            }, catch: { e in
                NSLog("Error: [WebPortalResponse processWado:] %@", e)
                self.response.setStatusCode(500)
            })
        }
    }

    // MARK: Weasis

    @objc(processWeasisJnlp)
    public func processWeasisJnlp() {
        raisingToCaller {
            let response = self.response!
            if !(self.portal?.weasisEnabled ?? false) {
                response.setStatusCode(404)
                return
            }

            response.templateString = self.portal?.string(forPath: "weasis.jnlp")
            response.mimeType = "application/x-java-jnlp-file"
        }
    }

    @objc(processWeasisXml)
    public func processWeasisXml() {
        raisingToCaller {
            let response = self.response!
            if !(self.portal?.weasisEnabled ?? false) {
                response.setStatusCode(404)
                return
            }

            // find requested core data objects

            let requestedStudies = NSMutableArray(capacity: 8)
            let requestedSeries = NSMutableArray(capacity: 64)

            let xid = self.parameter("xid")
            let selection = xid != nil ? NSArray(object: xid!) : WebPortalConnection.makeArray(self.parameter("selected"))
            for xid in selection {
                let oxid = self.objectWithXID(objcString(xid)) as AnyObject?
                if oxid?.isKind(of: DicomStudy.self) ?? false {
                    requestedStudies.add(oxid!)
                }
                if oxid?.isKind(of: DicomSeries.self) ?? false {
                    requestedSeries.add(oxid!)
                }
            }

            // extend arrays

            let studies = NSMutableArray(capacity: 8)
            let series = NSMutableArray(capacity: 64)

            for study in requestedStudies {
                if !studies.contains(study) {
                    studies.add(study)
                }
                for serie in objcSet(study as AnyObject, "series") {
                    if !series.contains(serie) {
                        series.add(serie)
                    }
                }
            }

            for serie in requestedSeries {
                let serie = unsafeDowncast(serie as AnyObject, to: DicomSeries.self)
                let serieStudy = serie.study
                if serieStudy == nil || !studies.contains(serieStudy!) {
                    objcAddObject(studies, serieStudy)
                }
                if !series.contains(serie) {
                    series.add(serie)
                }
            }

            // filter by user rights
            if let user = self.user {
                let authorizedStudies = WebPortalUser.studies(for: user, predicate: nil, sortBy: nil) as NSArray?

                var i = Int32(truncatingIfNeeded: studies.count &- 1)
                while i >= 0 {
                    var authorized = false
                    let currentStudy = studies.object(at: Int(i)) as AnyObject

                    for s in authorizedStudies ?? NSArray() {
                        if objcIsEqualToString(objcString(objcSend(s as AnyObject, "XID")), objcString(objcSend(currentStudy, "XID"))) {
                            authorized = true
                            break
                        }
                    }

                    if authorized == false {
                        NSLog("******** Trying to load a not authorized study through a Weasis JNLP request? %@", objcArg(studies.object(at: Int(i))))
                        studies.removeObject(at: Int(i))
                    }
                    i -= 1
                }
            }


            // We need the TRUE DICOM informations: re-parse the DICOM objects... if preferences such as Combine CR, split MG, ... are activated

            let imageObjects = NSMutableArray()

            for serie in series {
                imageObjects.addObjects(from: objcSet(serie as AnyObject, "images").allObjects)
            }

            let imagePaths = NSMutableArray(array: (imageObjects.value(forKey: "completePath") as? [Any]) ?? [])

            imagePaths.removeDuplicatedStrings()

            let patientDictionary = NSMutableDictionary()

            let dcmFiles = NSMutableArray()

            for path in imagePaths {
                let dcmFile = DicomFile(objcString(path) as String?, dicomOnly: true)

                if let dcmFile = dcmFile {
                    dcmFiles.add(dcmFile)

                    var patient: NSMutableDictionary? = nil
                    var study: NSMutableDictionary? = nil
                    var series: NSMutableDictionary? = nil

                    if let patientID = dcmFile.element(forKey: "patientID"), patientDictionary.object(forKey: patientID) == nil {
                        patientDictionary.setObject(NSMutableDictionary(), forKey: patientID as! NSCopying)
                    }

                    patient = dcmFile.element(forKey: "patientID").flatMap { patientDictionary.object(forKey: $0) } as? NSMutableDictionary

                    if let studyID = dcmFile.element(forKey: "studyID"), patient?.object(forKey: studyID) == nil {
                        patient?.setObject(NSMutableDictionary(), forKey: studyID as! NSCopying)
                    }

                    study = dcmFile.element(forKey: "studyID").flatMap { patient?.object(forKey: $0) } as? NSMutableDictionary

                    if let seriesDICOMUID = dcmFile.element(forKey: "seriesDICOMUID"), study?.object(forKey: seriesDICOMUID) == nil {
                        study?.setObject(NSMutableDictionary(), forKey: seriesDICOMUID as! NSCopying)
                    }

                    series = dcmFile.element(forKey: "seriesDICOMUID").flatMap { study?.object(forKey: $0) } as? NSMutableDictionary

                    if let SOPUID = dcmFile.element(forKey: "SOPUID") {
                        series?.setObject(dcmFile, forKey: SOPUID as! NSCopying)
                    }
                }
            }

            // produce XML
            var baseXML: String? = nil

            if UserDefaults.standard.bool(forKey: "wadoOnlyServer") {
                baseXML = String(format: "<?xml version=\"1.0\" encoding=\"utf-8\" standalone=\"yes\"?><wado_query xmlns=\"http://www.weasis.org/xsd\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" wadoURL=\"%@/wado\"></wado_query>", objcArg(WebPortal.wadoOnly()?.url()))
            } else {
                baseXML = String(format: "<?xml version=\"1.0\" encoding=\"utf-8\" standalone=\"yes\"?><wado_query xmlns=\"http://www.weasis.org/xsd\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" wadoURL=\"%@/wado\"></wado_query>", objcArg(self.portalURL()))
            }

            let doc = try? XMLDocument(xmlString: baseXML!, options: [.documentIncludeContentTypeDeclaration, .documentTidyXML])
            doc?.characterEncoding = "UTF-8"

            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyyMMdd"
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "HHmmss"

            for patientId in patientDictionary.allKeys {
                let patientNode = XMLNode.element(withName: "Patient") as! XMLElement
                patientNode.addAttribute(objcXMLAttribute("PatientID", patientId))
                let patientDataSet = false
                doc?.rootElement()?.addChild(patientNode)

                for studies in ((patientDictionary.value(forKey: objcString(patientId)! as String) as? NSDictionary)?.allValues as NSArray?) ?? NSArray() {
                    let studies = unsafeDowncast(studies as AnyObject, to: NSDictionary.self)
                    var dcmFile = ((studies.allValues as NSArray).lastObject as? NSDictionary).flatMap { ($0.allValues as NSArray).lastObject } as? DicomFile

                    objcTry({
                        let studyNode = XMLNode.element(withName: "Study") as! XMLElement
                        studyNode.addAttribute(objcXMLAttribute("StudyInstanceUID", dcmFile?.element(forKey: "studyID")))
                        studyNode.addAttribute(objcXMLAttribute("StudyDescription", dcmFile?.element(forKey: "studyDescription")))
                        if dcmFile?.element(forKey: "studyDate") != nil { studyNode.addAttribute(objcXMLAttribute("StudyDate", objcStringFromDate(dateFormatter, dcmFile?.element(forKey: "studyDate")))) }
                        if dcmFile?.element(forKey: "studyDate") != nil { studyNode.addAttribute(objcXMLAttribute("StudyTime", objcStringFromDate(timeFormatter, dcmFile?.element(forKey: "studyDate")))) }
                        studyNode.addAttribute(objcXMLAttribute("AccessionNumber", dcmFile?.element(forKey: "accessionNumber")))
                        studyNode.addAttribute(objcXMLAttribute("StudyID", dcmFile?.element(forKey: "studyID"))) // ?
                        studyNode.addAttribute(objcXMLAttribute("ReferringPhysicianName", dcmFile?.element(forKey: "referringPhysiciansName")))
                        patientNode.addChild(studyNode)

                        for serie in studies.allValues {
                            let serie = unsafeDowncast(serie as AnyObject, to: NSDictionary.self)
                            dcmFile = (serie.allValues as NSArray).lastObject as? DicomFile

                            let serieNode = XMLNode.element(withName: "Series") as! XMLElement
                            serieNode.addAttribute(objcXMLAttribute("SeriesInstanceUID", dcmFile?.element(forKey: "seriesDICOMUID")))
                            serieNode.addAttribute(objcXMLAttribute("SeriesDescription", dcmFile?.element(forKey: "seriesDescription")))
                            serieNode.addAttribute(objcXMLAttribute("SeriesNumber", objcNumberOrNil(dcmFile?.element(forKey: "seriesNumber"))?.stringValue))
                            serieNode.addAttribute(objcXMLAttribute("Modality", dcmFile?.element(forKey: "modality")))
                            studyNode.addChild(serieNode)

                            for dcmFile in serie.allValues {
                                let dcmFile = unsafeDowncast(dcmFile as AnyObject, to: DicomFile.self)
                                let instanceNode = XMLNode.element(withName: "Instance") as! XMLElement
                                instanceNode.addAttribute(objcXMLAttribute("SOPInstanceUID", dcmFile.element(forKey: "SOPUID")))
                                instanceNode.addAttribute(objcXMLAttribute("InstanceNumber", objcNumberOrNil(dcmFile.element(forKey: "imageID"))?.stringValue))
                                serieNode.addChild(instanceNode)
                            }
                        }

                        if !patientDataSet {
                            patientNode.addAttribute(objcXMLAttribute("PatientName", dcmFile?.element(forKey: "patientName")))
                            if dcmFile?.element(forKey: "patientBirthDate") != nil { patientNode.addAttribute(objcXMLAttribute("PatientBirthDate", objcStringFromDate(dateFormatter, dcmFile?.element(forKey: "patientBirthDate")))) }
                            if dcmFile?.element(forKey: "patientSex") != nil { patientNode.addAttribute(objcXMLAttribute("PatientSex", dcmFile?.element(forKey: "patientSex"))) }
                        }
                    }, catch: { exception in
                        _N2LogExceptionImpl(exception, false, "-[WebPortalConnection(Data) processWeasisXml]")
                    })
                }
            }

            response.setDataWith(doc?.xmlString)
            response.mimeType = "text/xml"
        }
    }

    // MARK: Other

    @objc(processReport)
    public func processReport() {
        raisingToCaller {
            let response = self.response!
            let studyObject = self.objectWithXID(self.stringParameter("xid")) as AnyObject?
            guard let study = studyObject.map({ unsafeDowncast($0, to: DicomStudy.self) }) else {
                return
            }

            self.portal?.updateLogEntry(forStudy: study, withMessage: "View Report", forUser: self.user?.name, ip: self.asyncSocket?.connectedHost())

//            NSString *reportFilePath = study.reportURL;

            let tmpFile = study.saveReportAsPdfInTmp()

            response.data = tmpFile.flatMap { NSData(contentsOfFile: $0) } as Data?

            if let tmpFile = tmpFile {
                try? FileManager.default.removeItem(atPath: tmpFile)
            }

//            NSString *reportType = [reportFilePath pathExtension];
//
//            if ([reportType isEqualToString: @"pages"])
//            {
//                NSString* zipFileName = [NSString stringWithFormat:@"%@.zip", [reportFilePath lastPathComponent]];
//                // zip the directory into a single archive file
//                NSTask *zipTask   = [[NSTask alloc] init];
//                [zipTask setLaunchPath:@"/usr/bin/zip"];
//                [zipTask setCurrentDirectoryPath:[[reportFilePath stringByDeletingLastPathComponent] stringByAppendingString:@"/"]];
//                if ([reportType isEqualToString:@"pages"])
//                    [zipTask setArguments:[NSArray arrayWithObjects: @"-q", @"-r" , zipFileName, [reportFilePath lastPathComponent], nil]];
//                else
//                    [zipTask setArguments:[NSArray arrayWithObjects: zipFileName, [reportFilePath lastPathComponent], nil]];
//                [zipTask launch];
//                while( [zipTask isRunning]) [NSThread sleepForTimeInterval: 0.01];
//                int result = [zipTask terminationStatus];
//                [zipTask release];
//
//                if (result==0)
//                    reportFilePath = [[reportFilePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:zipFileName];
//
//                response.data = [NSData dataWithContentsOfFile: reportFilePath];
//
//                [[NSFileManager defaultManager] removeItemAtPath:reportFilePath error:NULL];
//            }
//            else
//            {
//                response.data = [NSData dataWithContentsOfFile: reportFilePath];
//            }
        }
    }

    @objc(thumbnailsCache)
    func thumbnailsCache() -> NSMutableDictionary? {
        return raisingToCaller {
            return objcSynchronized(self.portal?.cache) { () -> NSMutableDictionary? in
                let ThumbsCacheKey = "Thumbnails Cache"
                var dict = self.portal?.cache?.object(forKey: ThumbsCacheKey) as? NSMutableDictionary
                if dict == nil {
                    dict = NSMutableDictionary()
                    self.portal?.cache?.setObject(dict!, forKey: ThumbsCacheKey as NSString)
                }

                return dict
            }
        }
    }

    @objc(processThumbnail)
    public func processThumbnail() {
        raisingToCaller {
            let response = self.response!
            let xid = self.parameter("xid")

            var data: Data? = nil
            do { // @synchronized(nil) runs its block unlocked
                let cache = self.portal?.cache
                var cached = false
                objcSynchronized(cache) {
                    // is cached?
                    data = xid.flatMap { self.thumbnailsCache()?.object(forKey: $0) } as? Data
                    if let data = data {
                        response.data = data
                        cached = true
                    }
                }
                if cached {
                    return
                }
            }

            // create it

            let object = self.objectWithXID(objcString(xid)) as AnyObject?
            guard let object = object else {
                return
            }

            if object.isKind(of: DicomSeries.self) {
                let imageRep = unsafeDowncast(object, to: DicomSeries.self).thumbnail.flatMap { NSBitmapImageRep(data: $0) }
                let imageProps: [NSBitmapImageRep.PropertyKey: Any] = [.compressionFactor: NSNumber(value: Float(1.0))]
                data = imageRep?.representation(using: .png, properties: imageProps)
                response.data = data
            } else if object.isKind(of: DicomImage.self) {
                let imageRep = unsafeDowncast(object, to: DicomImage.self).thumbnail()?.jpegRepresentation(withQuality: 0.3).flatMap { NSBitmapImageRep(data: $0) }
                let imageProps: [NSBitmapImageRep.PropertyKey: Any] = [.compressionFactor: NSNumber(value: Float(1.0))]
                data = imageRep?.representation(using: .png, properties: imageProps)
                response.data = data
            }

            response.mimeType = "image/png"

            do { // @synchronized(nil) runs its block unlocked
                let cache = self.portal?.cache
                objcSynchronized(cache) {
                    if let data = data {
                        if (self.thumbnailsCache()?.count ?? 0) > MAX_ThumbnailsCacheSize {
                            self.thumbnailsCache()?.removeAllObjects()
                        }

                        objcSetObject(self.thumbnailsCache(), data as NSData, forKey: xid)
                    }
                }
            }
        }
    }

    @objc(processSeriesPdf)
    public func processSeriesPdf() {
        raisingToCaller {
            let response = self.response!
            let seriesObject = self.objectWithXID(self.stringParameter("xid")) as AnyObject?
            guard let series = seriesObject.map({ unsafeDowncast($0, to: DicomSeries.self) }) else {
                return
            }

            if DCMAbstractSyntaxUID.isPDF(series.seriesSOPClassUID) {
                let dcmObject = HorosDCMTKObject(contentsOfFile: objcString((objcSet(series, "images").anyObject() as AnyObject?)?.value(forKey: "completePath")) as String? ?? "")
                if objcIsEqualToString(objcString(dcmObject?.attributeValue(withName: "SOPClassUID")), DCMAbstractSyntaxUID.pdfStorageClassUID() as NSString?) {
                    response.data = dcmObject?.attributeValue(withName: "EncapsulatedDocument") as? Data
                }
            }

            if DCMAbstractSyntaxUID.isStructuredReport(series.seriesSOPClassUID) {
                // In the portal's own temporary folder, not a /tmp folder shared by every user (#801).
                let path = FileManager.default.confirmDirectory(atPath: (WebPortalConnection.tmpDirPath() as NSString).appendingPathComponent("dicomsr_osirix"))
                let htmlpath = objcAppendingPathComponent(path as NSString?, (objcString((objcSet(series, "images").anyObject() as AnyObject?)?.value(forKey: "completePath"))?.lastPathComponent as NSString?).flatMap { objcAppendingPathExtension($0, "xml") } as String?).map { $0 as String } ?? ""
                // (never nil: -confirmDirectoryAtPath: returns the path it was given)

                if !FileManager.default.fileExists(atPath: htmlpath) {
                    let aTask = Process()
                    aTask.environment = ["DCMDICTPATH": ((Bundle.main.resourcePath ?? "") as NSString).appendingPathComponent("dicom.dic")]
                    aTask.launchPath = ((Bundle.main.resourcePath ?? "") as NSString).appendingPathComponent("dsr2html")
                    aTask.arguments = objcArrayOfStrings(["+X1", "--unknown-relationship", "--ignore-constraints", "--ignore-item-errors", "--skip-invalid-items", objcString((objcSet(series, "images").anyObject() as AnyObject?)?.value(forKey: "completePath")), htmlpath as NSString])
                    var taskError: NSError? = nil
                    if HorosRunTaskUntilExit(aTask, 60, &taskError) == false {
                        NSLog("****** dsr2html failed: %@", objcArg(taskError?.localizedDescription))
                    }
                }

                let pdfpath = (objcAppendingPathExtension(htmlpath as NSString, "pdf") as String?) ?? ""


                if FileManager.default.fileExists(atPath: pdfpath) == false {
                    let aTask = Process()
                    aTask.launchPath = ((Bundle.main.resourcePath ?? "") as NSString).appendingPathComponent("Decompress")
                    aTask.arguments = [htmlpath, "pdfFromURL"]
                    var taskError: NSError? = nil
                    if HorosRunTaskUntilExit(aTask, 10, &taskError) == false {
                        NSLog("****** Decompress pdfFromURL failed: %@", objcArg(taskError?.localizedDescription))
                    }
                }

                response.data = NSData(contentsOfFile: pdfpath) as Data?
            }
        }
    }


    @objc(processZip)
    public func processZip() {
        raisingToCaller {
            let response = self.response!
            let user = self.user
            let images = NSMutableArray()
            var study: DicomStudy? = nil

            let o = self.objectWithXID(self.stringParameter("xid")) as AnyObject?
            if let o = o, o.isKind(of: DicomStudy.self) {
                study = unsafeDowncast(o, to: DicomStudy.self)
                for s in objcSet(study!, "series") {
                    images.addObjects(from: objcSet(s as AnyObject, "images").allObjects)
                }
            } else if let o = o, o.isKind(of: DicomSeries.self) {
                study = unsafeDowncast(o, to: DicomSeries.self).study
                images.addObjects(from: objcSet(o, "images").allObjects)
            }

            if images.count == 0 {
                return
            }

            if user?.encryptedZIP?.boolValue ?? false {
                self.portal?.updateLogEntry(forStudy: study, withMessage: "Download encrypted DICOM ZIP", forUser: self.user?.name, ip: self.asyncSocket?.connectedHost())
            } else {
                self.portal?.updateLogEntry(forStudy: study, withMessage: "Download DICOM ZIP", forUser: self.user?.name, ip: self.asyncSocket?.connectedHost())
            }

            objcTry({
                // The portal's own temporary folder: in /tmp, named after the study,
                // another user could put the folder or the archive in place (#801).
                var srcFolder: NSString? = WebPortalConnection.tmpDirPath() as NSString
                var destFile: NSString? = WebPortalConnection.tmpDirPath() as NSString

                srcFolder = objcAppendingPathComponent(srcFolder, objcFilenameString((images.lastObject as AnyObject?)?.value(forKeyPath: "series.study.name")))
                destFile = objcAppendingPathComponent(destFile, objcFilenameString((images.lastObject as AnyObject?)?.value(forKeyPath: "series.study.name")))
                destFile = destFile?.appendingFormat("-%d", uniqueInc.wrappingAdd(1, ordering: .sequentiallyConsistent).oldValue) as NSString?

                // The requested path already says which archive the link asked for; the
                // user agent only decides when nothing else does.
                let archiveFormat = WebPortalArchiveFormat.format(forRequestedPath: self.requestedPath, parameters: self.parameters as? [String: Any], clientIsMacOS: self.requestIsMacOS())
                destFile = objcAppendingPathExtension(destFile, archiveFormat.pathExtension)

                if let srcFolder = srcFolder {
                    try? FileManager.default.removeItem(atPath: srcFolder as String)
                }
                if let destFile = destFile {
                    try? FileManager.default.removeItem(atPath: destFile as String)
                }

                FileManager.default.confirmDirectory(atPath: srcFolder as String?)

//                [self.portal.dicomDatabase.managedObjectContext unlock];
                BrowserController.encryptFiles(images.value(forKey: "completePath") as? [Any], inZIPFile: destFile as String?, password: (user?.encryptedZIP?.boolValue ?? false) ? user?.password : nil)
//                [self.portal.dicomDatabase.managedObjectContext lock];

                response.data = destFile.flatMap { NSData(contentsOfFile: $0 as String) } as Data?

                // This route sent no content type and no file name at all, so a client
                // had to guess both from the URL.
                response.mimeType = archiveFormat.mimeType
                response.mutableHTTPHeaders.setObject(archiveFormat.contentDisposition(forStudyName: (images.lastObject as AnyObject?)?.value(forKeyPath: "series.study.name") as? String), forKey: "Content-Disposition" as NSString)

                if let srcFolder = srcFolder {
                    try? FileManager.default.removeItem(atPath: srcFolder as String)
                }
                if let destFile = destFile {
                    try? FileManager.default.removeItem(atPath: destFile as String)
                }
            }, catch: { e in
                NSLog("**** web seriesAsZIP exception : %@", e)
            })
        }
    }

    @objc(saveImageAsScreenCapture:)
    func saveImageAsScreenCapture(_ XID: NSString?) {
        raisingToCaller {
            if Thread.isMainThread == false {
                NSLog("****** we should be on MAIN thread")
            }

            // The image whose XID is passed, not the request's xid: that one can name a
            // series, and -imageAsScreenCapture: sent to it raised on the main thread and
            // ended the application (#760).
            guard let dicomImage = self.objectWithXID(XID) as? DicomImage else {
                return
            }

            let savedSmartCropping = UserDefaults.standard.bool(forKey: "allowSmartCropping")

            objcTry({
                // Sent to the main thread by the request's thread.
                MainActor.assumeIsolated { DCMView.setCLUTBARS(CLUTBARS, annotations: Int32(annotGraphics)) }

                UserDefaults.standard.set(false, forKey: "allowSmartCropping")

                let image = dicomImage.image(asScreenCapture: NSMakeRect(0, 0, CGFloat(UserDefaults.standard.integer(forKey: "DicomImageScreenCaptureWidth")), CGFloat(UserDefaults.standard.integer(forKey: "DicomImageScreenCaptureHeight"))))

                MainActor.assumeIsolated { DCMView.setDefaults() }
                UserDefaults.standard.set(savedSmartCropping, forKey: "allowSmartCropping")

                let representations = image?.representations
                let bitmapData = representations.flatMap { NSBitmapImageRep.representationOfImageReps(in: $0, using: .jpeg, properties: [.compressionFactor: NSDecimalNumber(value: Float(0.8))]) }

                let path = objcAppendingPathExtension(objcAppendingPathComponent(WebPortalConnection.tmpDirPath() as NSString, dicomImage.xidFilename()), "jpg")! as String
                try? FileManager.default.removeItem(atPath: path)
                (bitmapData as NSData?)?.write(toFile: path, atomically: true)
            }, catch: { e in
                _N2LogExceptionImpl(e, true, "-[WebPortalConnection(Data) saveImageAsScreenCapture:]")
                MainActor.assumeIsolated { DCMView.setDefaults() }
                UserDefaults.standard.set(savedSmartCropping, forKey: "allowSmartCropping")
            })
        }
    }

    @objc(processImageAsScreenCapture:)
    public func processImageAsScreenCapture(_ asDisplayed: Bool) {
        raisingToCaller {
            let response = self.response!
            let object = self.objectWithXID(self.stringParameter("xid")) as AnyObject?
            guard let object = object else {
                return
            }

            var images: NSArray? = nil

            if object.isKind(of: DicomSeries.self) {
                images = objcSet(object, "images").allObjects as NSArray
            }
            else if object.isKind(of: DicomImage.self) {
                images = NSArray(object: object)
            }

            // [nil objectAtIndex:] was nil; an empty array raises.
            let dicomImage = (images?.count == 1 ? images?.lastObject : images?.object(at: (images?.count ?? 0) / 2)).map { unsafeDowncast($0 as AnyObject, to: DicomImage.self) }

            if asDisplayed {
                if objcIsEqualToString(self.requestedPath.map { ($0 as NSString).pathExtension as NSString }, "jpg") {
                    // waitUntileDone is very risky... cross lock possible ?!
                    self.performSelector(onMainThread: #selector(self.saveImageAsScreenCapture(_:)), with: dicomImage?.xid(), waitUntilDone: true)

                    let path = objcAppendingPathExtension(objcAppendingPathComponent(WebPortalConnection.tmpDirPath() as NSString, dicomImage?.xidFilename()), "jpg")! as String
                    response.data = NSData(contentsOfFile: path) as Data?
                    response.mimeType = "image/jpeg"
                    return
                }
                else {
                    HorosWebPortalDataLogStackTrace("*** only JPEG are supported")
                }
            }

            guard let dcmPix = DCMPix(path: dicomImage?.completePathResolved(), 0, 1, nil, Int(dicomImage?.frameID?.int32Value ?? 0), Int(dicomImage?.series?.id?.int32Value ?? 0), isBonjour: false, imageObj: dicomImage) else {
                return
            }

            var curWW: Float = 0
            var curWL: Float = 0

            if dicomImage?.series?.windowWidth != nil {
                curWW = dicomImage?.series?.windowWidth?.floatValue ?? 0
                curWL = dicomImage?.series?.windowLevel?.floatValue ?? 0
            }

            if curWW != 0 {
                dcmPix.checkImageAvailble(curWW, curWL)
            } else {
                dcmPix.checkImageAvailble(dcmPix.savedWW, dcmPix.savedWL)
            }

            var image = dcmPix.image()

            var size = image?.size ?? .zero
            self.getWidth(&size.width, height: &size.height, fromImagesArray: objcArrayWithObject(dicomImage))
            if size != (image?.size ?? .zero) {
                image = image?.imageByScalingProportionally(toSize: size)
            }

            // The play mark and the image number are drawn over the preview in the
            // preview's own colour space. An image made by a drawing handler is
            // rendered in the screen's: the greys of the window came out colour
            // matched, 102 as 121 and 153 as 169.
            var composed: NSBitmapImageRep?
            if let source = image {
                let overlay = self.parameter("previewForMovie") != nil ? NSImage(named: "PlayTemplate.png") : nil
                let seriesImages = asDisplayed ? nil : dicomImage?.series?.sortedImages() as NSArray?
                let index = seriesImages == nil ? 0 : (dicomImage.map { seriesImages!.index(of: $0) } ?? NSNotFound)
                let text = String(format: "%d / %d", Int32(truncatingIfNeeded: index) &+ 1, Int32(truncatingIfNeeded: seriesImages?.count ?? 0)) as NSString
                if overlay != nil || !asDisplayed {
                    composed = source.horosBitmapInOwnColorSpace { bounds in
                        if let overlay {
                            let overlaySize = overlay.size
                            let centered = NSMakeRect((bounds.width - overlaySize.width) / 2, (bounds.height - overlaySize.height) / 2, overlaySize.width, overlaySize.height)
                            overlay.draw(in: centered, from: .zero, operation: .sourceOver, fraction: 1)
                        }
                        if !asDisplayed { self.drawText(text, atLocation: NSMakePoint(1, bounds.height - TEXTHEIGHT)) }
                    }
                }
            }

            let imageRep = composed ?? image?.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }

            let imageProps: [NSBitmapImageRep.PropertyKey: Any] = [.compressionFactor: NSNumber(value: Float(0.8))]
            if objcIsEqualToString(self.requestedPath.map { ($0 as NSString).pathExtension as NSString }, "png") {
                response.data = imageRep?.representation(using: .png, properties: imageProps)
                response.mimeType = "image/png"

            }
            else if objcIsEqualToString(self.requestedPath.map { ($0 as NSString).pathExtension as NSString }, "jpg") {
                response.data = imageRep?.representation(using: .jpeg, properties: imageProps)
                response.mimeType = "image/jpeg"
            }
            // else NSLog( @"***** unknown path extension: %@", [fileURL pathExtension]);
        }
    }

    @objc(processImage)
    public func processImage() {
        raisingToCaller {
            return self.processImageAsScreenCapture(false)
        }
    }

    @objc(processMovie)
    public func processMovie() {
        raisingToCaller {
            let response = self.response!
            let seriesObject = self.objectWithXID(self.stringParameter("xid")) as AnyObject?
            guard let series = seriesObject.map({ unsafeDowncast($0, to: DicomSeries.self) }) else {
                return
            }

            response.data = self.produceMovieForSeries(series, fileURL: self.requestedPath as NSString?)

            //if (data == nil || [data length] == 0)
            //    NSLog( @"****** movie data == nil");
        }
    }

    // MARK: - The request's parameters, as the former code read them

    /// [parameters objectForKey:key]
    private func parameter(_ key: String) -> Any? {
        return (self.parameters as NSDictionary?)?.object(forKey: key)
    }

    /// [parameters valueForKey:key]
    private func parameterValue(_ key: String) -> Any? {
        return (self.parameters as NSDictionary?)?.value(forKey: key)
    }

    /// [parameters objectForKey:key], typed NSString* as the former code typed it.
    private func stringParameter(_ key: String) -> NSString? {
        return objcString(self.parameter(key))
    }
}

// MARK: - WebPortal (Data) helpers

extension WebPortal {
    fileprivate func webPortalDataNewUser(withEmail email: NSString?) -> AnyObject? {
        return self.newUser(withEmail: email as String?)
    }
}

extension WebPortalDatabase {
    fileprivate func webPortalDataNewUser() -> NSObject? {
        return self.newUser()
    }
}

// MARK: - The Objective-C semantics the former code relied on

/// Runs `body`. An NSException it raises reaches the Objective-C caller, as it did
/// when the method was Objective-C: -httpResponseForMethod:URI: answers 500.
@discardableResult
private func raisingToCaller<T>(_ body: () -> T) -> T {
    var result: T? = nil
    do {
        try HorosObjCException.perform { result = body() }
    } catch {
        if let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
            exception.raise()
        }
        fatalError("HorosObjCException returned an error without its exception")
    }
    return result!
}

/// @try { body } @catch (NSException* e) { handler(e) }
private func objcTry(_ body: () -> Void, catch handler: (NSException) -> Void) {
    do {
        try HorosObjCException.perform(body)
    } catch {
        if let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
            handler(exception)
        }
    }
}

/// @synchronized(object) { body }: the lock is released when an exception leaves
/// the block, and the exception goes on.
@discardableResult
private func objcSynchronized<T>(_ object: AnyObject?, _ body: () -> T) -> T {
    var result: T? = nil
    var raised: NSException? = nil
    // @synchronized(nil) runs the block without a lock.
    if let object = object { objc_sync_enter(object) }
    do {
        try HorosObjCException.perform { result = body() }
    } catch {
        raised = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
    }
    if let object = object { objc_sync_exit(object) }
    if let raised = raised {
        raised.raise()
    }
    return result!
}

private func objcRaise(_ name: NSExceptionName, _ reason: String) -> Never {
    NSException(name: name, reason: reason, userInfo: nil).raise()
    fatalError("unreachable")
}

/// An `id` the former code sent NSString messages to: whatever the object is, the
/// messages go to it and it answers them, or raises, as it did.
private func objcString(_ object: Any?) -> NSString? {
    guard let object = object else { return nil }
    return unsafeDowncast(object as AnyObject, to: NSString.self)
}

/// An `id` the former code sent NSNumber messages to; a message to nil answers 0.
private func objcNumber(_ object: Any?) -> NSNumber {
    guard let object = object else { return NSNumber(value: 0) }
    return unsafeDowncast(object as AnyObject, to: NSNumber.self)
}

private func objcNumberOrNil(_ object: Any?) -> NSNumber? {
    guard let object = object else { return nil }
    return unsafeDowncast(object as AnyObject, to: NSNumber.self)
}

/// [object intValue], 0 for nil.
private func objcIntValue(_ object: Any?) -> Int32 {
    return objcString(object)?.intValue ?? 0
}

/// [object integerValue], 0 for nil.
private func objcIntegerValue(_ object: Any?) -> Int {
    return objcString(object)?.integerValue ?? 0
}

/// [object boolValue], NO for nil.
private func objcBoolValue(_ object: Any?) -> Bool {
    return objcString(object)?.boolValue ?? false
}

/// [a isEqualToString:b], NO when a is nil.
private func objcIsEqualToString(_ a: NSString?, _ b: NSString?) -> Bool {
    guard let a = a, let b = b else { return false }
    return a.isEqual(to: b as String)
}

private func objcIsEqualToString(_ a: String?, _ b: String?) -> Bool {
    return objcIsEqualToString(a as NSString?, b as NSString?)
}

/// N2NonNullString
private func objcNonNull(_ s: String?) -> String {
    return s ?? ""
}

/// The object a selector returns, sent as the former code sent it (to an object
/// whose class the header did not name, or to keep an NSSet an NSSet).
private func objcSend(_ object: AnyObject?, _ selector: String) -> AnyObject? {
    return object?.perform(NSSelectorFromString(selector))?.takeUnretainedValue()
}

/// A to-many relationship as the NSSet it is.
private func objcSet(_ object: AnyObject, _ selector: String) -> NSSet {
    return (objcSend(object, selector) as? NSSet) ?? NSSet()
}

private func objcSetCount(_ object: AnyObject, _ selector: String) -> Int {
    return (objcSend(object, selector) as? NSSet)?.count ?? 0
}

/// A %@ argument: an object as it is, and nil as the null pointer the former code
/// passed, which prints "(null)" and compares as nil in a predicate.
private func objcArg(_ object: Any?) -> CVarArg {
    if let object = object, let nsObject = (object as AnyObject) as? NSObject {
        return nsObject
    }
    return Int(0)
}

/// [NSDictionary dictionaryWithObjectsAndKeys:…]: the list ends at the first nil.
private func objcDictionary(_ pairs: [(Any?, String)]) -> NSDictionary {
    return objcMutableDictionary(pairs).copy() as! NSDictionary
}

private func objcMutableDictionary(_ pairs: [(Any?, String)]) -> NSMutableDictionary {
    let dictionary = NSMutableDictionary()
    for (object, key) in pairs {
        guard let object = object else { break }
        dictionary.setObject(object, forKey: key as NSString)
    }
    return dictionary
}

/// [NSDictionary dictionaryWithObject:object forKey:key] (or NSMutableDictionary),
/// which raises for nil.
private func objcDictionaryWithObject(_ cls: NSDictionary.Type, _ object: Any?, forKey key: String) -> NSDictionary? {
    let factory = NSSelectorFromString("dictionaryWithObject:forKey:")
    return (cls as AnyObject).perform(factory, with: object, with: key)?.takeUnretainedValue() as? NSDictionary
}

/// [BrowserController replaceNotAdmitted:name], which edits a mutable string in
/// place; the imported String parameter would hand it a copy.
private func objcReplaceNotAdmitted(_ name: NSMutableString) {
    _ = (BrowserController.self as AnyObject).perform(NSSelectorFromString("replaceNotAdmitted:"), with: name)
}

/// A property set with the object as it came (the former code assigned the
/// request's `id` values to NSString properties without looking at them).
private func objcSetProperty(_ object: NSObject, _ setter: String, _ value: Any?) {
    _ = object.perform(NSSelectorFromString(setter), with: value)
}

/// [NSEntityDescription insertNewObjectForEntityForName:name inManagedObjectContext:context]
private func objcInsertNewObject(_ name: String, _ context: NSManagedObjectContext?) -> NSManagedObject {
    guard let context = context else {
        objcRaise(.invalidArgumentException, "+entityForName: nil is not a legal NSPersistentStoreCoordinator for searching for entity name '\(name)'")
    }
    return NSEntityDescription.insertNewObject(forEntityName: name, into: context)
}

/// [NSArray arrayWithObject:object], which raises for nil.
private func objcArrayWithObject(_ object: Any?) -> NSArray? {
    let factory = NSSelectorFromString("arrayWithObject:")
    return (NSArray.self as AnyObject).perform(factory, with: object)?.takeUnretainedValue() as? NSArray
}

/// [NSArray arrayWithObjects:…, nil]: the list ends at the first nil.
private func objcArrayOfStrings(_ objects: [NSString?]) -> [String] {
    var array: [String] = []
    for object in objects {
        guard let object = object else { break }
        array.append(object as String)
    }
    return array
}

/// [dictionary setObject:object forKey:key], which raises for a nil object or key;
/// a message to a nil dictionary does nothing.
private func objcSetObject(_ dictionary: NSMutableDictionary?, _ object: Any?, forKey key: Any?) {
    _ = dictionary?.perform(#selector(NSMutableDictionary.setObject(_:forKey:)), with: object, with: key)
}

/// [array addObject:object], which raises for nil.
private func objcAddObject(_ array: NSMutableArray, _ object: Any?) {
    _ = array.perform(#selector(NSMutableArray.add(_:)), with: object)
}

/// [string appendString:other], which raises for nil.
private func objcAppend(_ string: NSMutableString, _ other: NSString?) {
    _ = string.perform(#selector(NSMutableString.append(_:)), with: other)
}

/// [[object copy] autorelease]
private func objcCopy(_ object: Any?) -> Any? {
    guard let object = object as AnyObject? as? NSObject else { return nil }
    return object.copy()
}

/// [base stringByAppendingString:other], nil when base is nil.
private func objcAppending(_ base: NSString?, _ other: String) -> NSString? {
    return base?.appending(other) as NSString?
}

/// [base stringByAppendingPathComponent:component], nil when base is nil; a nil
/// component leaves base as it is.
private func objcAppendingPathComponent(_ base: NSString?, _ component: String?) -> NSString? {
    guard let base = base else { return nil }
    guard let component = component else { return base }
    return base.appendingPathComponent(component) as NSString
}

/// [base stringByAppendingPathExtension:ext], which raises for a nil extension.
private func objcAppendingPathExtension(_ base: NSString?, _ ext: String?) -> NSString? {
    return base?.perform(#selector(NSString.appendingPathExtension(_:)), with: ext)?.takeUnretainedValue() as? NSString
}

/// [name filenameString] (BrowserController.h), for a name that may be nil.
private func objcFilenameString(_ name: Any?) -> String? {
    return objcString(name)?.filenameString() as String?
}

/// [formatter stringFromDate:date], nil for nil, with whatever object date is.
private func objcStringFromDate(_ formatter: DateFormatter?, _ date: Any?) -> String? {
    guard let formatter = formatter, let date = date else { return nil }
    return formatter.perform(#selector(DateFormatter.string(from:)), with: date)?.takeUnretainedValue() as? String
}

/// [NSXMLNode attributeWithName:name stringValue:value], with whatever object value is.
private func objcXMLAttribute(_ name: String, _ value: Any?) -> XMLNode {
    let factory = NSSelectorFromString("attributeWithName:stringValue:")
    return (XMLNode.self as AnyObject).perform(factory, with: name, with: value).takeUnretainedValue() as! XMLNode
}

/// [object validateX:&value error:&err]: NO sets err.
private func objcValidate(_ validation: () throws -> Void, _ err: inout NSError?) -> Bool {
    do {
        try validation()
        return true
    } catch {
        err = error as NSError
        return false
    }
}

// A method passed where its result was meant (image.sopInstanceUID for
// image.sopInstanceUID()) would convert to Any silently; these make it an error.
@available(*, unavailable) private func objcArg<R>(_ method: () -> R) -> CVarArg { fatalError() }
@available(*, unavailable) private func objcString<R>(_ method: () -> R) -> NSString? { fatalError() }
@available(*, unavailable) private func objcNumber<R>(_ method: () -> R) -> NSNumber { fatalError() }
@available(*, unavailable) private func objcIntValue<R>(_ method: () -> R) -> Int32 { fatalError() }
@available(*, unavailable) private func objcSetObject<R>(_ dictionary: NSMutableDictionary?, _ method: () -> R, forKey key: Any?) { fatalError() }
@available(*, unavailable) private func objcAddObject<R>(_ array: NSMutableArray, _ method: () -> R) { fatalError() }
@available(*, unavailable) private func objcSetProperty<R>(_ object: NSObject, _ setter: String, _ method: () -> R) { fatalError() }

/// +[QuicktimeExport CVPixelBufferFromNSImage:], by its selector: a buffer at +1,
/// which the former code released with CVPixelBufferRelease.
private func objcPixelBuffer(from image: NSImage) -> CVPixelBuffer? {
    guard let buffer = (QuicktimeExport.self as AnyObject).perform(NSSelectorFromString("CVPixelBufferFromNSImage:"), with: image) else {
        return nil
    }
    return unsafeDowncast(buffer.takeRetainedValue(), to: CVPixelBuffer.self)
}

/// [DCMTransferSyntax JPEG2000LosslessTransferSyntax] and the like, which return id.
private func objcTransferSyntax(_ selector: String) -> DCMTransferSyntax? {
    return (DCMTransferSyntax.self as AnyObject).perform(NSSelectorFromString(selector))?.takeUnretainedValue() as? DCMTransferSyntax
}

/// NSMakeSize(wh) of N2Operators (a C++ overload): a square.
private func objcMakeSize(_ wh: CGFloat) -> NSSize {
    return NSMakeSize(wh, wh)
}

/// C conversions from floating point as arm64 makes them (fcvtzs): toward zero,
/// saturated, NaN as 0, where Swift's would trap.
private func cInt32(_ value: Double) -> Int32 {
    if value.isNaN { return 0 }
    if value >= Double(Int32.max) { return Int32.max }
    if value <= Double(Int32.min) { return Int32.min }
    return Int32(value)
}

private func cInt(_ value: Double) -> Int {
    if value.isNaN { return 0 }
    if value >= Double(Int.max) { return Int.max }
    if value <= Double(Int.min) { return Int.min }
    return Int(value)
}

/// int / and % as arm64 computes them (sdiv): a zero divisor gives a quotient of 0,
/// and INT_MIN / -1 wraps, where Swift's operators would trap.
private func cQuotient(_ a: Int32, _ b: Int32) -> Int32 {
    if b == 0 { return 0 }
    if b == -1 { return 0 &- a }
    return a / b
}

private func cRemainder(_ a: Int32, _ b: Int32) -> Int32 {
    return a &- cQuotient(a, b) &* b
}

/// NSCalendarDate.calendarDate's fields, from the Objective-C helper.
private struct CalendarDateFields {
    var year = 0, month = 0, day = 0, hour = 0, minute = 0, second = 0
}

private func calendarDateNow() -> CalendarDateFields {
    var fields = CalendarDateFields()
    HorosWebPortalDataCalendarNow(&fields.year, &fields.month, &fields.day, &fields.hour, &fields.minute, &fields.second)
    return fields
}

private func StartOfDay(_ day: CalendarDateFields) -> TimeInterval {
    let start = HorosWebPortalDataCalendarDate(day.year, UInt(bitPattern: day.month), UInt(bitPattern: day.day), 0, 0, 0)
    return start?.timeIntervalSinceReferenceDate ?? 0
}
