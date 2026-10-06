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

// The "Plugins" block of BrowserController is implemented in Swift:
// a Swift extension of BrowserController, which stays Objective-C, with
// the selectors of the former methods. The instance variables it uses are
// read through BrowserController (SwiftIvars). The properties the header
// declared (searchString, isCurrentDatabaseBonjour, currentDatabasePath,
// documentsDirectory, fixedDocumentsDirectory, cfixed*) are @objc properties
// with the same getters, and searchString's setter.
//
// An @try is HorosObjCException.perform (objcTry), and the code of its
// @finally runs after it; an @synchronized is objcSynchronized. A plugin's
// filter is sent -prepareFilter: and -filterImage: as Objective-C sent them
// (objcSendLong), so that a filter that does not implement one raises inside
// the @try as before. The USEHOMEPHONE branch (not defined) is left out.

/// `@synchronized (object) { … }`: the same recursive lock, taken on nothing
/// when the object is nil, and left before an exception raised inside goes on.
@inline(__always)
fileprivate func objcSynchronized<T>(_ object: AnyObject?, _ body: () -> T) -> T {
    guard let object else { return body() }
    objc_sync_enter(object)
    var result: T?
    var raised: NSException?
    do {
        try HorosObjCException.perform { result = body() }
    } catch {
        raised = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
    }
    objc_sync_exit(object)
    if let raised { raised.raise() }
    return result!
}

/// Runs `body` as an @try block: the NSException it raises is returned.
@inline(__always)
fileprivate func objcTry(_ body: () -> Void) -> NSException? {
    do {
        try HorosObjCException.perform(body)
    } catch {
        return (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
    }
    return nil
}

/// A `%@` argument: the object, or "(null)" as Objective-C printed nil.
fileprivate func objcFormatArgument(_ object: Any?) -> CVarArg {
    if let object = object as? NSObject { return object }
    if let object { return String(describing: object) as NSString }
    return "(null)" as NSString
}

/// `[NSDictionary dictionaryWithObjectsAndKeys: …, nil]`: the list ends at the
/// first nil.
fileprivate func objcDictionary(_ pairs: Any?...) -> NSDictionary {
    let dictionary = NSMutableDictionary()
    var index = 0
    while index + 1 < pairs.count {
        guard let object = pairs[index], let key = pairs[index + 1] as? NSCopying else { break }
        dictionary.setObject(object, forKey: key)
        index += 2
    }
    return dictionary
}

/// `[target selector: argument]` of a method returning `long`, sent as
/// Objective-C sends it: a target that does not implement the method raises
/// (through the forwarding machinery).
fileprivate func objcSendLong(_ target: AnyObject, _ selectorName: String, _ argument: AnyObject?) -> Int {
    let selector = NSSelectorFromString(selectorName)
    guard let targetClass: AnyClass = object_getClass(target),
          let implementation = class_getMethodImplementation(targetClass, selector) else { return 0 }
    typealias Send = @convention(c) (AnyObject, Selector, AnyObject?) -> Int
    return unsafeBitCast(implementation, to: Send.self)(target, selector, argument)
}

/// `[object title]`, `[object label]`…: a string property of an `id`, nil for
/// nil; an object that does not answer it raises, as before.
fileprivate func objcStringProperty(_ object: Any?, _ selectorName: String) -> String? {
    guard let object else { return nil }
    return (object as AnyObject).perform(NSSelectorFromString(selectorName))?.takeUnretainedValue() as? String
}

/// A nil `%@` argument for a format taking a C variable argument list.
fileprivate struct ObjCNilArgument: CVarArg {
    var _cVarArgEncoding: [Int] { return [0] }
}

/// `[NSPredicate predicateWithFormat: format, …]` with object arguments, a nil
/// one passed as nil.
fileprivate func objcPredicate(_ format: String, _ arguments: Any?...) -> NSPredicate {
    let list: [CVarArg] = arguments.map { argument -> CVarArg in
        guard let argument else { return ObjCNilArgument() }
        return ((argument as AnyObject) as? NSObject) ?? ObjCNilArgument()
    }
    return withVaList(list) { NSPredicate(format: format, arguments: $0) }
}

/// `[a isEqualToString: b]`, NO when either is nil.
fileprivate func objcIsEqualToString(_ a: String?, _ b: String?) -> Bool {
    guard let a, let b else { return false }
    return (a as NSString).isEqual(to: b)
}

public extension BrowserController {

    // MARK: -
    // MARK: Plugins

    @objc(executeFilterFromString:)
    func executeFilter(from name: String!) {
        let filter: Any? = name.flatMap { PluginManager.plugins()?.object(forKey: $0) }
        guard let filter else {
            HorosAlertPanel.run(title: NSLocalizedString("Plugins Error", comment: ""),
                                message: String(format: NSLocalizedString("The plugin %@ is not loaded. Open Plugins Manager and inspect Loading Details.", comment: ""), objcFormatArgument(name)),
                                defaultButton: nil, alternateButton: nil, otherButton: nil)
            return
        }

        PluginManager.startProtectForCrash(withFilter: filter)
        // The USEHOMEPHONE branch (not defined) is left out.

        var stage = NSLocalizedString("preparation", comment: "")
        if let exception = objcTry({
            var result = objcSendLong(filter as AnyObject, "prepareFilter:", nil)
            if result != 0 {
                HorosAlertPanel.run(title: NSLocalizedString("Plugins Error", comment: ""),
                                    message: String(format: NSLocalizedString("Plugin %@ failed during %@ (error %ld).", comment: ""), objcFormatArgument(name), stage as NSString, result),
                                    defaultButton: nil, alternateButton: nil, otherButton: nil)
                return
            }
            stage = NSLocalizedString("processing", comment: "")
            result = objcSendLong(filter as AnyObject, "filterImage:", name as NSString?)
            if result != 0 {
                HorosAlertPanel.run(title: NSLocalizedString("Plugins Error", comment: ""),
                                    message: String(format: NSLocalizedString("Plugin %@ failed during %@ (error %ld).", comment: ""), objcFormatArgument(name), stage as NSString, result),
                                    defaultButton: nil, alternateButton: nil, otherButton: nil)
            }
        }) {
            _N2LogExceptionImpl(exception, true, "-[BrowserController executeFilterFromString:]")
            HorosAlertPanel.run(title: NSLocalizedString("Plugins Error", comment: ""),
                                message: String(format: NSLocalizedString("Plugin %@ failed during %@: %@ (%@).", comment: ""),
                                                objcFormatArgument(name), stage as NSString, (exception.reason ?? "") as NSString, exception.name.rawValue as NSString),
                                defaultButton: nil, alternateButton: nil, otherButton: nil)
        }
        // @finally
        PluginManager.endProtectForCrash()
    }

    @objc(executeFilterDB:)
    func executeFilterDB(_ sender: Any!) {
        executeFilter(from: objcStringProperty(sender, "title"))
    }

    @objc(executeFilterFromToolbar:)
    func executeFilterFromToolbar(_ sender: Any!) {
        executeFilter(from: objcStringProperty(sender, "label"))
    }

    @objc(setNetworkLogs)
    func setNetworkLogs() {
        horos_isNetworkLogsActive = UserDefaults.standard.bool(forKey: "NETWORKLOGS")
    }

    // The store and query threads ask (DCMTKStoreSCU.mm).
    @objc(isNetworkLogsActive)
    nonisolated func isNetworkLogsActive() -> Bool {
        return horos_isNetworkLogsActive
    }

    // #pragma deprecated (setFixedDocumentsDirectory)
    @available(*, deprecated)
    @objc(setFixedDocumentsDirectory)
    func setFixedDocumentsDirectory() -> String! {
        NSLog("%@ IS NOT AVAILABLE ANYMORE, moved to DicomDatabase.. This message should never appear!", "-[BrowserController setFixedDocumentsDirectory]" as NSString)
        return nil

        //	[fixedDocumentsDirectory release];
        //	fixedDocumentsDirectory = [[self documentsDirectory] retain];
        //
        //	if( fixedDocumentsDirectory == nil)
        //	{
        //		NSRunAlertPanel( NSLocalizedString(@"Database Location Error", nil), NSLocalizedString(@"Cannot locate Database path.", nil), nil, nil, nil);
        //		exit(0);
        //	}
        //
        //	strcpy( cfixedDocumentsDirectory, [fixedDocumentsDirectory UTF8String]);
        //
        //	if( [[NSUserDefaults standardUserDefaults] boolForKey: OsirixCanActivateDefaultDatabaseOnlyDefaultsKey])
        //	{
        //		NSString *defaultPath = [self documentsDirectoryFor: [[NSUserDefaults standardUserDefaults] integerForKey: @"DEFAULT_DATABASELOCATION"] url: [[NSUserDefaults standardUserDefaults] stringForKey: @"DEFAULT_DATABASELOCATIONURL"]];
        //
        //		strcpy( cfixedIncomingDirectory, [defaultPath UTF8String]);
        //	}
        //	else strcpy( cfixedIncomingDirectory, [fixedDocumentsDirectory UTF8String]);
        //
        //	NSString *r;
        //
        //	r = [[NSFileManager defaultManager] destinationOfSymbolicLinkAtPath: [NSString stringWithFormat:@"%s/%s", cfixedIncomingDirectory, "TEMP.noindex"] error: nil];
        //	if( r == nil)
        //		r = [NSString stringWithFormat:@"%s/%s", cfixedIncomingDirectory, "TEMP.noindex"];
        //	strcpy( cfixedTempNoIndexDirectory, [r UTF8String]);
        //
        //	r = [[NSFileManager defaultManager] destinationOfSymbolicLinkAtPath: [NSString stringWithFormat:@"%s/%s", cfixedIncomingDirectory, "INCOMING.noindex"] error: nil];
        //	if( r == nil)
        //	{
        //		r = [NSString stringWithFormat:@"%s/%s", cfixedIncomingDirectory, "INCOMING.noindex"];
        //		r = [self folderPathResolvingAliasAndSymLink: r];
        //	}
        //	strcpy( cfixedIncomingNoIndexDirectory, [r UTF8String]);
        //
        //	return fixedDocumentsDirectory;
    }

    @available(*, deprecated)
    @objc(localDocumentsDirectory)
    func localDocumentsDirectory() -> String! {
        return DicomDatabase.activeLocal()?.baseDirPath
    }

    @available(*, deprecated)
    @objc(fixedDocumentsDirectory)
    var fixedDocumentsDirectory: String! {
        return DicomDatabase.activeLocal()?.baseDirPath
    }

    @available(*, deprecated)
    @objc(cfixedDocumentsDirectory)
    var cfixedDocumentsDirectory: UnsafePointer<CChar>! { return DicomDatabase.activeLocal()?.baseDirPathC() }

    @available(*, deprecated)
    @objc(cfixedIncomingDirectory)
    var cfixedIncomingDirectory: UnsafePointer<CChar>! { return DicomDatabase.activeLocal()?.incomingDirPathC() }

    @available(*, deprecated)
    @objc(cfixedTempNoIndexDirectory)
    var cfixedTempNoIndexDirectory: UnsafePointer<CChar>! { return DicomDatabase.activeLocal()?.tempDirPathC() }

    @available(*, deprecated)
    @objc(cfixedIncomingNoIndexDirectory)
    var cfixedIncomingNoIndexDirectory: UnsafePointer<CChar>! { return DicomDatabase.activeLocal()?.incomingDirPathC() }

    @available(*, deprecated)
    @objc(INCOMINGPATH)
    nonisolated func incomingpath() -> String! {
        return self.database?.incomingDirPath()
    }

    @available(*, deprecated)
    @objc(defaultDocumentsDirectory)
    class func defaultDocumentsDirectory() -> String! {
        //	NSString *dir = documentsDirectory();
        return DicomDatabase.default()?.baseDirPath
    }

    @available(*, deprecated)
    @objc(TEMPPATH)
    func temppath() -> String! {
        return self.database?.tempDirPath()
    }

    @available(*, deprecated)
    @objc(documentsDirectory)
    var documentsDirectory: String! {
        return self.database?.baseDirPath
    }

    @available(*, deprecated)
    @objc(documentsDirectoryFor:url:)
    func documentsDirectory(for mode: Int32, url: String!) -> String! {
        let dir = DicomDatabase.baseDirPath(forMode: mode, path: url)
        return dir
    }

    @objc(showLogWindow:)
    func showLogWindow(_ sender: Any!) {
        if horos_logWindowController == nil {
            horos_logWindowController = LogWindowController()
        }
        horos_logWindowController?.showWindow(self)
    }

    @objc(resetLogWindowController)
    func resetLogWindowController() {
        horos_logWindowController?.close()
        horos_logWindowController = nil
    }

    // -searchString and -setSearchString:
    @objc(searchString)
    var searchString: String! {
        get {
            return horos_searchString
        }
        set(searchString) {
            if horos_searchType == 0 && UserDefaults.standard.bool(forKey: "HIDEPATIENTNAME") {
                horos_searchField?.textColor = NSColor.controlBackgroundColor
            } else {
                horos_searchField?.textColor = NSColor.controlTextColor
            }

            // The retain setter releases the former string and retains this one.
            horos_searchString = searchString

            self.distantSearchString = nil
            self.distantSearchType = horos_searchType

            setFilterPredicate(createFilterPredicate(), description: createFilterDescription())
            outlineViewRefresh()
            if let databaseOutline = horos_databaseOutline {
                databaseOutline.scrollRowToVisible(databaseOutline.selectedRow)
            }

            let length = (horos_searchString as NSString?)?.length ?? 0
            if length > 2 || (length >= 2 && horos_searchType == 5) {
                objcSynchronized(self) {
                    horos_distantSearchThread?.cancel()
                    horos_distantSearchThread = nil
                }

                Thread.detachNewThreadSelector(#selector(BrowserController.search(forSearchField:)), toTarget: self,
                                               with: objcDictionary(NSNumber(value: horos_searchType), "searchType", horos_searchString, "searchString", NSNumber(value: Int32(truncatingIfNeeded: horos_albumTable?.selectedRow ?? 0)), "selectedAlbumIndex"))
            } else if horos_timeIntervalStart != nil || horos_timeIntervalEnd != nil {
                objcSynchronized(self) {
                    horos_distantSearchThread?.cancel()
                    horos_distantSearchThread = nil
                }

                if (horos_albumTable?.selectedRow ?? 0) == 0 {
                    Thread.detachNewThreadSelector(#selector(BrowserController.searchForTimeIntervalFrom(to:)), toTarget: self,
                                                   with: objcDictionary(horos_timeIntervalStart, "from", horos_timeIntervalEnd, "to"))
                }
            } else {
                objcSynchronized(self) {
                    horos_distantSearchThread?.cancel()
                    horos_distantSearchThread = nil
                }
            }
        }
    }

    @objc(searchForCurrentPatient:)
    func searchForCurrentPatient(_ sender: Any!) {
        if (horos_databaseOutline?.selectedRow ?? 0) != -1 {
            let aFile = horos_databaseOutline?.item(atRow: horos_databaseOutline?.selectedRow ?? 0) as AnyObject?

            if let aFile {
                // A copy of the name (an Objective-C string becomes a Swift string by a copy).
                let patientName = ((aFile.value(forKey: "type") as? NSString)?.isEqual(to: "Study") == true
                    ? aFile.value(forKey: "name") : aFile.value(forKeyPath: "study.name")) as? String
                // The context command always supplies a name, regardless of the previous search field.
                // Capture it before changing the field, which refreshes the outline and its selection.
                setSearchType((horos_searchField?.cell as? NSSearchFieldCell)?.searchMenuTemplate?.item(withTag: 0))
                self.searchString = patientName
            }
        }
    }

    @objc(setFilterPredicate:description:)
    func setFilterPredicate(_ predicate: NSPredicate!, description desc: String!) {
        horos_filterPredicate = predicate

        horos_filterPredicateDescription = desc
    }

    @objc(createFilterDescription)
    func createFilterDescription() -> String! {
        var description: String? = nil

        if let searchString = horos_searchString, (searchString as NSString).length > 0 {
            let s = searchString as NSString
            switch horos_searchType {
            case 7:			// All fields
                description = String(format: NSLocalizedString(" / Search: All fields = %@", comment: ""), s)

            case 0:			// Patient Name
                description = String(format: NSLocalizedString(" / Search: Patient's name = %@", comment: ""), s)

            case 1:			// Patient ID
                description = String(format: " / Search: Patient's ID = %@", s)

            case 2:			// Study/Series ID
                description = String(format: " / Search: Study's ID = %@", s)

            case 3:			// Comments
                description = String(format: NSLocalizedString(" / Search: Comments = %@", comment: ""), s)

            case 4:			// Study Description
                description = String(format: NSLocalizedString(" / Search: Study Description = %@", comment: ""), s)

            case 11: // Series Description: preserve complete study context for review
                description = String(format: NSLocalizedString(" / Search: Series Description = %@ (matching studies; expand to review series)", comment: ""), s)

            case 5:			// Modality
                description = String(format: NSLocalizedString(" / Search: Modality = %@", comment: ""), s)

            case 6:			// Accession Number
                description = String(format: NSLocalizedString(" / Search: Accession Number = %@", comment: ""), s)

            case 8:			// Comments
                description = String(format: NSLocalizedString(" / Search: Comments 2 = %@", comment: ""), s)

            case 9:			// Comments
                description = String(format: NSLocalizedString(" / Search: Comments 3 = %@", comment: ""), s)

            case 10:			// Comments
                description = String(format: NSLocalizedString(" / Search: Comments 4 = %@", comment: ""), s)

            case 100:
                // Advanced
                break

            default:
                break
            }
        }
        if let current = description, ((horos_searchString as NSString?)?.length ?? 0) > 0 {
            let names = NSMutableArray()
            for case let source as NSDictionary in (type(of: self).federatedSourceCatalog() ?? []) {
                if ((source.object(forKey: "included") as? NSNumber)?.boolValue ?? false)
                    && FederatedSearch.pathsEqual(source.object(forKey: "path") as? String, self.database?.baseDirPath) == false {
                    let label = source.object(forKey: "name") as? String
                    if let label, (label as NSString).length > 0 {
                        names.add(label)
                    }
                }
            }
            if names.count > 0 {
                let combined = current.appendingFormat(NSLocalizedString(" / Federated: %@", comment: ""), names.componentsJoined(by: ", ") as NSString)
                description = combined
            }
        }
        return description
    }

    @objc(patientsnamePredicate:)
    func patientsnamePredicate(_ s: String!) -> NSPredicate! {
        return patientsnamePredicate(s, soundex: UserDefaults.standard.bool(forKey: "useSoundexForName"))
    }

    /// Each name component narrows the match: the first from the start of the
    /// name, the others anywhere in it. A component that is only `*` narrows
    /// nothing, so `*` alone, like an empty value, matches every name, as
    /// universal matching does in a C-FIND (PS3.4 C.2.2.2.3); a component with
    /// `*` or `?` inside is matched as a wildcard pattern (C.2.2.2.4). The
    /// listener's query threads call it too, so it touches no browser state.
    @objc(patientsnamePredicate:soundex:)
    nonisolated func patientsnamePredicate(_ s: String!, soundex: Bool) -> NSPredicate! {
        var s = s as NSString?
        s = s?.replacingOccurrences(of: "^", with: " ") as NSString?
        s = s?.replacingOccurrences(of: ", ", with: " ") as NSString?
        s = s?.replacingOccurrences(of: ",", with: " ") as NSString?

        let predicates = NSMutableArray()

        if let exception = objcTry({
            var firstComponent = true
            let nameComponents = s?.components(separatedBy: " ") ?? []

            for name in nameComponents {
                var component = name as NSString
                var p: NSPredicate? = nil

                while component.hasPrefix("*") {
                    component = component.substring(from: 1) as NSString
                    firstComponent = false
                }

                while component.hasSuffix("*") {
                    component = component.substring(to: component.length - 1) as NSString
                }

                if component.length == 0 {
                    // "*", or an empty component between separators: no condition.
                    // A CONTAINS/BEGINSWITH of "" never matches in the store.
                    firstComponent = false
                    continue
                }

                if component.contains("*") || component.contains("?") {
                    p = objcPredicate("name LIKE[cd] %@", (firstComponent ? "" : "*") + (component as String) + "*")
                } else if firstComponent == false {
                    if soundex && component.length >= 2 {
                        p = objcPredicate("(soundex CONTAINS[cd] %@) OR (name CONTAINS[cd] %@)", DicomStudy.soundex(component as String), component)
                    } else {
                        p = objcPredicate("name CONTAINS[cd] %@", component)
                    }
                } else {
                    if soundex && component.length >= 2 {
                        p = objcPredicate("(soundex BEGINSWITH[cd] %@) OR (name BEGINSWITH[cd] %@)", DicomStudy.soundex(component as String), component)
                    } else {
                        p = objcPredicate("name BEGINSWITH[cd] %@", component)
                    }
                }

                if let p {
                    predicates.add(p)
                }

                firstComponent = false
            }
        }) {
            _N2LogExceptionImpl(exception, false, "-[BrowserController patientsnamePredicate:soundex:]")
        }

        return NSCompoundPredicate(andPredicateWithSubpredicates: (predicates as? [NSPredicate]) ?? [])
    }

    @objc(federatedSourceCatalog)
    nonisolated class func federatedSourceCatalog() -> [Any]! {
        let defaultDB = DicomDatabase.default()
        return FederatedSearch.sources(fromLocalDatabasePaths: UserDefaults.standard.object(forKey: "localDatabasePaths") as? [[String: Any]],
                                       defaultPath: defaultDB?.baseDirPath,
                                       defaultName: defaultDB?.name,
                                       defaultIncluded: FederatedSearch.isDefaultDatabaseIncluded)
    }

    @objc(federatedStudiesMatchingPredicate:excludingDatabasePath:applyingUser:)
    nonisolated class func federatedStudies(matching predicate: NSPredicate!, excludingDatabasePath path: String!, applyingUser userObject: Any!) -> [Any]! {
        guard let predicate else {
            return []
        }

        let user = userObject as? WebPortalUser
        let localPaths = UserDefaults.standard.object(forKey: "localDatabasePaths") as? [[String: Any]]
        let defaultDB = DicomDatabase.default()
        let included = FederatedSearch.includedPaths(fromLocalDatabasePaths: localPaths,
                                                     defaultPath: defaultDB?.baseDirPath,
                                                     defaultIncluded: FederatedSearch.isDefaultDatabaseIncluded)
        let hits = NSMutableArray()
        let seen = NSMutableSet()
        var permission: NSPredicate? = nil
        if let user, FederatedSearch.isUnrestrictedPermission(user.studyPredicate) == false {
            permission = DicomDatabase.predicate(forSmartAlbumFilter: user.studyPredicate)
        }

        for sourcePath in included {
            if FederatedSearch.pathsEqual(sourcePath, path) {
                continue
            }
            if let e = objcTry({
                guard let db = DicomDatabase(atPath: sourcePath) else {
                    return
                }
                // On a web connection's thread, its database of that path,
                // inside its queue; the studies go back to the connection.
                let idb: DicomDatabase? = Thread.isMainThread ? db
                    : (WebPortalConnection.threadFederatedDatabase(atPath: sourcePath)
                       ?? db.privateQueueIndependentDatabase() as? DicomDatabase)
                let studies = idb?.objects(forEntity: idb?.studyEntity(), predicate: predicate) ?? []
                for case let study as DicomStudy in studies {
                    if let permission, permission.evaluate(with: study) == false {
                        var assigned = false
                        for case let specific as WebPortalStudy in (user?.studies ?? []) {
                            if objcIsEqualToString(specific.studyInstanceUID, study.studyInstanceUID)
                                && study.patientUID != nil
                                && specific.patientUID != nil
                                && (study.patientUID as NSString).range(of: specific.patientUID, options: [.caseInsensitive, .diacriticInsensitive]).location == 0 {
                                assigned = true
                                break
                            }
                        }
                        if assigned == false {
                            continue
                        }
                    }
                    let key = FederatedSearch.identityKey(patientUID: study.patientUID,
                                                          studyUID: study.studyInstanceUID,
                                                          originPath: db.baseDirPath)
                    if seen.contains(key) {
                        continue
                    }
                    seen.add(key)
                    hits.add(study)
                }
            }) {
                _N2LogExceptionImpl(e, false, "+[BrowserController federatedStudiesMatchingPredicate:excludingDatabasePath:applyingUser:]")
            }
        }
        return hits as? [Any]
    }

    @objc(createFilterPredicate)
    func createFilterPredicate() -> NSPredicate! {
        var predicate: NSPredicate? = nil
        var s: NSString? = nil

        if let searchString = horos_searchString as NSString?, searchString.length > 0 {
            switch horos_searchType {
            case 7:			// All Fields
                s = searchString

                if let s, s.length >= 3 {
                    predicate = NSPredicate(format: "(name CONTAINS[cd] %@) OR (patientID CONTAINS[cd] %@) OR (id CONTAINS[cd] %@) OR (comment CONTAINS[cd] %@) OR (comment2 CONTAINS[cd] %@) OR (comment3 CONTAINS[cd] %@) OR (comment4 CONTAINS[cd] %@) OR (studyName CONTAINS[cd] %@) OR (modality CONTAINS[cd] %@) OR (accessionNumber CONTAINS[cd] %@) OR (performingPhysician CONTAINS[cd] %@) OR (referringPhysician CONTAINS[cd] %@) OR (institutionName CONTAINS[cd] %@) OR (note CONTAINS[cd] %@)", s, s, s, s, s, s, s, s, s, s, s, s, s, s)
                } else if (s?.length ?? 0) >= 1 {
                    predicate = patientsnamePredicate(searchString as String)
                }

            case 0:			// Patient Name
                predicate = patientsnamePredicate(searchString as String)

            case 1:			// Patient ID
                predicate = NSPredicate(format: "patientID CONTAINS[cd] %@", searchString)

            case 2:			// Study/Series ID
                predicate = NSPredicate(format: "id CONTAINS[cd] %@", searchString)

            case 3:			// Comments
                predicate = NSPredicate(format: "comment CONTAINS[cd] %@", searchString)

            case 4:			// Study Description
                predicate = NSPredicate(format: "studyName CONTAINS[cd] %@", searchString)

            case 11: // Core Data relationship query; no synthetic result objects
                predicate = NSPredicate(format: "ANY series.name CONTAINS[cd] %@", searchString)

            case 5:			// Modality
                predicate = NSPredicate(format: "modality CONTAINS[cd] %@", searchString)

            case 6:			// Accession Number
                predicate = NSPredicate(format: "accessionNumber CONTAINS[cd] %@", searchString)

            case 8:			// Comments
                predicate = NSPredicate(format: "comment2 CONTAINS[cd] %@", searchString)

            case 9:			// Comments
                predicate = NSPredicate(format: "comment3 CONTAINS[cd] %@", searchString)

            case 10:			// Comments
                predicate = NSPredicate(format: "comment4 CONTAINS[cd] %@", searchString)

            case 100:		// Advanced
                break

            default:
                break
            }
        }
        return predicate
    }

    @objc(databaseSelection)
    func databaseSelection() -> [Any]! {
        let selectedItems = NSMutableArray()

        if let databaseOutline = horos_databaseOutline {
            let selectedRowIndexes = databaseOutline.selectedRowIndexes
            for index in selectedRowIndexes {
                if let item = databaseOutline.item(atRow: index) {
                    selectedItems.add(item)
                }
            }
        }
        return selectedItems as? [Any]
    }

    // Comparisons
    // Finding Comparisons
    @objc(relatedStudiesForStudy:)
    func relatedStudies(forStudy study: Any!) -> [Any]! {
        let model = self.database?.managedObjectModel
        let context = self.database?.managedObjectContext

        var studiesArray: NSArray? = nil
        var raised: NSException? = nil
        N2ManagedObjectContextPerformAndWait(context) {
        // FIND ALL STUDIES of this patient

        let predicate = objcPredicate("(patientUID BEGINSWITH[cd] %@)", (study as AnyObject?)?.value(forKey: "patientUID"))
        let dbRequest = NSFetchRequest<NSFetchRequestResult>()
        dbRequest.entity = model?.entitiesByName["Study"]
        dbRequest.predicate = predicate

        // The result stays alive until the synchronous queue operation ends;
        // an exception is raised on the caller after leaving the queue.
        raised = objcTry {
            studiesArray = (try? context?.fetch(dbRequest)) as NSArray?

            if let e = objcTry({
                if let current = studiesArray, current.count > 0, let study, current.index(of: study) != NSNotFound {
                    let sort = NSSortDescriptor(key: "date", ascending: false)
                    let sortDescriptors = [sort]
                    let s = NSMutableArray(array: current.sortedArray(using: sortDescriptors))
                    // remove original study from array
                    s.remove(study)

                    studiesArray = NSArray(array: s)
                }
            }) {
                _N2LogExceptionImpl(e, true, "-[BrowserController relatedStudiesForStudy:]")
            }
        }

        }

        if let raised { raised.raise() }

        return studiesArray as? [Any]
    }

    // DCMPix asks while it loads, on any thread.
    @objc(isCurrentDatabaseBonjour)
    nonisolated var isCurrentDatabaseBonjour: Bool {
        return !(self.database?.isLocal() ?? false)
    }

    @available(*, deprecated)
    @objc(currentDatabasePath)
    var currentDatabasePath: String! {
        return self.database?.baseDirPath
    }

    @available(*, deprecated)
    @objc(bonjourManagedObjectContext)
    func bonjourManagedObjectContext() -> NSManagedObjectContext! {
        if !(self.database?.isLocal() ?? false) {
            return self.database?.managedObjectContext
        }
        return nil
    }
}
