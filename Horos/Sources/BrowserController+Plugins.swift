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
import IsiXPreferences
import IsiXStorage

// The "Plugins" block of BrowserController: the entry points the former
// plugin SDK and the rest of the app call, with the selectors of the former
// methods. The state it uses is read through the class's accessors
// (BrowserController+StateAccess.swift). The properties the header
// declared (searchString, isCurrentDatabaseBonjour, currentDatabasePath,
// documentsDirectory, fixedDocumentsDirectory, cfixed*) are @objc properties
// with the same getters, and searchString's setter.
//
// The search field's predicate is IsiXDatabase's StudySearchRules, the
// federated search FederatedStudySearch's, and the folders of the database
// IsiXStorage's DocumentsLocation; these methods hand over to them.
//
// An @try is HorosObjCException.caught, and the code of its
// @finally runs after it. A plugin's filter is sent -prepareFilter: and
// -filterImage: as Objective-C sent them (objcSendLong), so that a filter
// that does not implement one raises inside the @try as before. The
// USEHOMEPHONE branch (not defined) is left out.

/// A `%@` argument: the object, or "(null)" as Objective-C printed nil.
fileprivate func objcFormatArgument(_ object: Any?) -> CVarArg {
    if let object = object as? NSObject { return object }
    if let object { return String(describing: object) as NSString }
    return "(null)" as NSString
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

public extension BrowserController {

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

        var stage = NSLocalizedString("preparation", comment: "")
        if let exception = HorosObjCException.caught({
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
        horos_isNetworkLogsActive = PreferencesSource.process.preferences[NetworkPreferences.networkLogs]
    }

    // The sends ask, for their network log entry (DCMTKStoreSCU.swift).
    @objc(isNetworkLogsActive)
    nonisolated func isNetworkLogsActive() -> Bool {
        return horos_isNetworkLogsActive
    }

    @available(*, deprecated)
    @objc(setFixedDocumentsDirectory)
    func setFixedDocumentsDirectory() -> String! {
        NSLog("%@ IS NOT AVAILABLE ANYMORE, moved to DicomDatabase.. This message should never appear!", "-[BrowserController setFixedDocumentsDirectory]" as NSString)
        return nil
    }

    /// The folders of the database shown.
    nonisolated private var documentsLocation: DocumentsLocation {
        let database = self.database
        return DocumentsLocation(documentsDirectory: database?.baseDirPath, dataDirectory: database?.dataBaseDirPath)
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
    var cfixedDocumentsDirectory: UnsafePointer<CChar>! { return DicomDatabase.activeLocal()?.baseDirPathC() }

    @available(*, deprecated)
    @objc(cfixedIncomingDirectory)
    var cfixedIncomingDirectory: UnsafePointer<CChar>! { return DicomDatabase.activeLocal()?.incomingDirPathC() }

    @available(*, deprecated)
    var cfixedTempNoIndexDirectory: UnsafePointer<CChar>! { return DicomDatabase.activeLocal()?.tempDirPathC() }

    @available(*, deprecated)
    @objc(cfixedIncomingNoIndexDirectory)
    var cfixedIncomingNoIndexDirectory: UnsafePointer<CChar>! { return DicomDatabase.activeLocal()?.incomingDirPathC() }

    @available(*, deprecated)
    @objc(INCOMINGPATH)
    nonisolated func incomingpath() -> String! {
        return documentsLocation.incomingDirectory
    }

    @available(*, deprecated)
    @objc(defaultDocumentsDirectory)
    class func defaultDocumentsDirectory() -> String! {
        return DicomDatabase.default()?.baseDirPath
    }

    @available(*, deprecated)
    @objc(TEMPPATH)
    func temppath() -> String! {
        return documentsLocation.temporaryDirectory
    }

    @available(*, deprecated)
    @objc(documentsDirectory)
    var documentsDirectory: String! {
        return documentsLocation.documentsDirectory
    }

    @available(*, deprecated)
    @objc(documentsDirectoryFor:url:)
    func documentsDirectory(for mode: Int32, url: String!) -> String! {
        return DicomDatabase.baseDirPath(forMode: mode, path: url)
    }

    /// Plugins built for Horos and OsiriX index the files they wrote by this selector (LegacyPluginIngest).
    @objc(addFiles:toContext:toDatabase:onlyDICOM:notifyAddedFiles:parseExistingObject:dbFolder:generatedByOsiriX:)
    class func legacyPluginAdd(_ files: [Any]!, toContext context: NSManagedObjectContext!, toDatabase browser: BrowserController!, onlyDICOM: Bool, notifyAddedFiles: Bool, parseExistingObject: Bool, dbFolder: String!, generatedByOsiriX: Bool) -> [Any]! {
        LegacyPluginIngest.add(files, context: context, browser: browser, folder: dbFolder, onlyDICOM: onlyDICOM, notify: notifyAddedFiles, reread: parseExistingObject, generatedByOsiriX: generatedByOsiriX)
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
            applySearchFieldTextColour()

            // The retain setter releases the former string and retains this one.
            horos_searchString = searchString

            self.distantSearchString = nil
            self.distantSearchType = horos_searchType

            setFilterPredicate(createFilterPredicate(), description: createFilterDescription())
            outlineViewRefresh()
            if let databaseOutline = horos_databaseOutline {
                databaseOutline.scrollRowToVisible(databaseOutline.selectedRow)
            }

            askDistantNodesForSearch()
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
        guard let searchString = horos_searchString,
              let field = StudySearchRules.field(searchType: Int(horos_searchType), searchString: searchString),
              let format = searchDescriptionFormat(field) else { return nil }
        let description = String(format: format, searchString as NSString)

        let federated = FederatedStudySearch(source: .process)
        let names = federated.includedSourceNames(besides: self.database?.baseDirPath)
        guard !names.isEmpty else { return description }
        return description.appendingFormat(NSLocalizedString(" / Federated: %@", comment: ""), names.joined(separator: ", ") as NSString)
    }

    @objc(patientsnamePredicate:)
    func patientsnamePredicate(_ s: String!) -> NSPredicate! {
        return patientsnamePredicate(s, soundex: PreferencesSource.process.preferences[DatabasePreferences.useSoundexForName])
    }

    /// The patient name search of the database (PatientNameMatching), with
    /// the names that sound alike when `soundex` is set. Any thread may call it.
    @objc(patientsnamePredicate:soundex:)
    nonisolated func patientsnamePredicate(_ s: String!, soundex: Bool) -> NSPredicate! {
        PatientNameMatching.namePredicate(s, soundex: soundex ? { DicomStudy.soundex($0) } : nil)
    }

    /// The local databases a federated search can ask (FederatedStudySearch).
    @objc(federatedSourceCatalog)
    nonisolated class func federatedSourceCatalog() -> [Any]! {
        FederatedStudySearch(source: .process).sources()
    }

    /// The studies of the other local databases asked that match `predicate`
    /// and that the web portal user may see (FederatedStudySearch).
    @objc(federatedStudiesMatchingPredicate:excludingDatabasePath:applyingUser:)
    nonisolated class func federatedStudies(matching predicate: NSPredicate!, excludingDatabasePath path: String!, applyingUser userObject: Any!) -> [Any]! {
        guard let predicate else { return [] }
        return FederatedStudySearch(source: .process)
            .studies(matching: predicate, excludingDatabasePath: path, user: userObject as? WebPortalUser)
    }

    /// The predicate of the search field's string (StudySearchRules).
    @objc(createFilterPredicate)
    func createFilterPredicate() -> NSPredicate! {
        StudySearchRules.filterPredicate(searchString: horos_searchString, searchType: Int(horos_searchType),
                                         namePredicate: { self.patientsnamePredicate($0) })
    }

    @objc(databaseSelection)
    func databaseSelection() -> [Any]! {
        guard let databaseOutline = horos_databaseOutline else { return [] }
        return databaseOutline.selectedRowIndexes.compactMap { databaseOutline.item(atRow: $0) }
    }

    // Finding Comparisons
    @objc(relatedStudiesForStudy:)
    func relatedStudies(forStudy study: Any!) -> [Any]! {
        let context = self.database?.managedObjectContext

        var studiesArray: NSArray? = nil
        var raised: NSException? = nil
        N2ManagedObjectContextPerformAndWait(context) {
        // FIND ALL STUDIES of this patient

        let predicate = objcPredicate("(patientUID BEGINSWITH[cd] %@)", (study as AnyObject?)?.value(forKey: "patientUID"))
        let dbRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "Study")
        dbRequest.predicate = predicate

        // The result stays alive until the synchronous queue operation ends;
        // an exception is raised on the caller after leaving the queue.
        raised = HorosObjCException.caught {
            studiesArray = (try? context?.fetch(dbRequest)) as NSArray?

            if let e = HorosObjCException.caught({
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

    // Of the database shown, asked on any thread; an object's own database
    // answers for it (RemoteDicomDatabase.database(of:)).
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

/// The description of a search, by the field searched, with %@ for the string.
private func searchDescriptionFormat(_ field: StudySearchRules.Field) -> String? {
    switch field {
    case .allFields: return NSLocalizedString(" / Search: All fields = %@", comment: "")
    case .patientName: return NSLocalizedString(" / Search: Patient's name = %@", comment: "")
    case .patientID: return " / Search: Patient's ID = %@"
    case .studyID: return " / Search: Study's ID = %@"
    case .comments: return NSLocalizedString(" / Search: Comments = %@", comment: "")
    case .studyDescription: return NSLocalizedString(" / Search: Study Description = %@", comment: "")
    // Series Description: preserve complete study context for review
    case .seriesDescription:
        return NSLocalizedString(" / Search: Series Description = %@ (matching studies; expand to review series)", comment: "")
    case .modality: return NSLocalizedString(" / Search: Modality = %@", comment: "")
    case .accessionNumber: return NSLocalizedString(" / Search: Accession Number = %@", comment: "")
    case .comments2: return NSLocalizedString(" / Search: Comments 2 = %@", comment: "")
    case .comments3: return NSLocalizedString(" / Search: Comments 3 = %@", comment: "")
    case .comments4: return NSLocalizedString(" / Search: Comments 4 = %@", comment: "")
    case .advanced: return nil
    }
}
