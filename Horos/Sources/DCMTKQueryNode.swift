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
import IsiXDICOMNetwork
import IsiXKeychain
import Synchronization
import IsiXDICOMFile

/// A value the threads of one operation share, read and changed under its own lock.
final class QueryNodeShared<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func read<T>(_ body: (Value) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(value)
    }

    @discardableResult
    func modify<T>(_ body: (inout Value) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }

    var current: Value { read { $0 } }
}

/// A node of the Query window's results: the root of a search, a study, a
/// series or an image of a DICOM or DICOMweb node, and what it takes to list
/// its children and to retrieve it.
///
/// What it was is split by responsibility: this file holds the node itself
/// (its attributes, children and settings); +Query the searches,
/// +Network the DIMSE associations, +Retrieve the retrieves,
/// +RetrieveInventory the record of what a retrieve expects, +WADO the
/// WADO-URI retrieve and +DICOMweb the DICOMweb one. DCMTK is reached only
/// through Adapters/DCMTK, and what does not depend on the app (the
/// identifiers, the DICOMweb search, the progress) is in IsiXDICOMNetwork.
///
/// The selectors and KVC keys are the Objective-C class's: the Query window,
/// the browser's comparative studies, the probes in tools/ and Locations
/// reach them by name.
@objc(DCMTKQueryNode)
class DCMTKQueryNode: NSObject, @unchecked Sendable {

    // MARK: The peer

    let callingAETitle: String?
    let calledAETitle: String?
    @objc let _hostname: String!
    @objc var _port: Int32
    @objc let transferSyntax: Int32
    @objc let compression: Float
    /// Replaced, never changed in place: a study adds its UID for its series.
    var extraParametersStorage: NSDictionary?
    let association: DICOMAssociationSettings

    private let abortFlag = Atomic<Bool>(false)
    /// Set to give up the association in progress, as the Query window's Stop does.
    @objc var _abortAssociation: Bool {
        get { abortFlag.load(ordering: .relaxed) }
        set { abortFlag.store(newValue, ordering: .relaxed) }
    }

    // MARK: Attributes, as the response gave them

    var uidValue: String?
    var descriptionValue: String?
    var nameValue: String?
    var patientIDValue: String?
    var referringPhysicianValue: String?
    var performingPhysicianValue: String?
    var institutionNameValue: String?
    var commentsValue: String?
    var interpretationStatusIDValue: String?
    var accessionNumberValue: String?
    var dateValue: DICOMCalendarDate?
    var birthdateValue: DICOMCalendarDate?
    var timeValue: DICOMCalendarDate?
    var modalityValue: String?
    var numberImagesValue: NSNumber?
    var specificCharacterSet: String?
    private var logEntryValue: NSManagedObject?

    // MARK: Children

    /// nil until a search ran: a series' images are searched for when it is nil.
    var childrenStorage: NSMutableArray?
    /// Guards childrenStorage, and keeps a level's own work on it in one piece.
    let childrenLock = NSRecursiveLock()

    // MARK: Operation state

    var showErrorMessageValue = true
    @objc var dontCatchExceptions = false
    @objc var isAutoRetrieve = false
    @objc var noSmartMode = false
    @objc var countOfSuboperations: UInt = 0
    @objc var countOfSuccessfulSuboperations: UInt = 0
    var lastQuerySucceededValue = false
    var imageInventoryConfirmedValue = false
    var lastQueryNotImplementedValue = false
    var listingNotImplemented = false
    var listingFailedOtherwise = false
    var seriesInstanceCountsStorage: NSMutableDictionary?
    var seriesNumbersStorage: NSMutableDictionary?
    var seriesDescriptionsStorage: NSMutableDictionary?
    var seriesDetailsStorage: NSMutableDictionary?
    /// Set by a retrieve of several studies, which tells their failures in one
    /// notice once all have ended, rather than one notice each.
    @objc var deferFailureNotice = false
    /// How the last retrieve ended: whether something is missing, and how many
    /// instances when that is known (-1 otherwise).
    @objc var lastRetrieveIncomplete = false
    @objc var lastRetrieveMissing: Int = -1
    @objc var retrievePlan: RetrievePlan?
    /// The retrieve thread replaces the inventory while the main thread paints
    /// it and the refresh queue reconciles it: a reader takes its own reference
    /// under this lock, so an inventory replaced meanwhile lives until the
    /// reader is done.
    let retrieveInventoryStorage = QueryNodeShared<RetrieveInventory?>(nil)
    var retrieveInventoryRefreshQueued = false
    var retrieveInventoryMissGeneration: UInt = 0
    var reportedDICOMwebError: NSError?
    var retrievePatient: String?

    // MARK: Making a node

    @objc(initWithDataset:callingAET:calledAET:hostname:port:transferSyntax:compression:extraParameters:)
    required init(dataset: IsiXDCMTKDataset?, callingAET: String?, calledAET: String?, hostname: String?, port: Int32,
                  transferSyntax: Int32, compression: Float, extraParameters: [AnyHashable: Any]?) {
        callingAETitle = callingAET
        calledAETitle = calledAET
        _hostname = hostname
        _port = port
        self.transferSyntax = transferSyntax
        self.compression = compression
        extraParametersStorage = extraParameters.map { NSDictionary(dictionary: $0) }
        association = DICOMAssociationSettings(extraParameters: extraParameters)
        super.init()
    }

    @objc(initWithCallingAET:calledAET:hostname:port:transferSyntax:compression:extraParameters:)
    convenience init(callingAET: String?, calledAET: String?, hostname: String?, port: Int32, transferSyntax: Int32,
                     compression: Float, extraParameters: [AnyHashable: Any]?) {
        self.init(dataset: nil, callingAET: callingAET, calledAET: calledAET, hostname: hostname, port: port,
                  transferSyntax: transferSyntax, compression: compression, extraParameters: extraParameters)
    }

    @objc(queryNodeWithDataset:callingAET:calledAET:hostname:port:transferSyntax:compression:extraParameters:)
    class func queryNode(dataset: IsiXDCMTKDataset?, callingAET: String?, calledAET: String?, hostname: String?, port: Int32,
                         transferSyntax: Int32, compression: Float, extraParameters: [AnyHashable: Any]?) -> Self {
        self.init(dataset: dataset, callingAET: callingAET, calledAET: calledAET, hostname: hostname, port: port,
                  transferSyntax: transferSyntax, compression: compression, extraParameters: extraParameters)
    }

    /// A node of this node's peer, made from `identifier`.
    func sibling<Node: DCMTKQueryNode>(_ type: Node.Type, from identifier: DICOMQueryIdentifier) -> Node {
        type.init(dataset: identifier.dataset(), callingAET: callingAETitle, calledAET: calledAETitle, hostname: _hostname,
                  port: _port, transferSyntax: transferSyntax, compression: compression,
                  extraParameters: extraParametersStorage as? [AnyHashable: Any])
    }

    /// A node of this node's peer, made from a response.
    func child<Node: DCMTKQueryNode>(_ type: Node.Type, from response: IsiXDCMTKDataset) -> Node {
        type.init(dataset: response, callingAET: callingAETitle, calledAET: calledAETitle, hostname: _hostname,
                  port: _port, transferSyntax: transferSyntax, compression: compression,
                  extraParameters: extraParametersStorage as? [AnyHashable: Any])
    }

    // MARK: The association settings a node reports

    @objc func calledAET() -> String! { calledAETitle }
    @objc func callingAET() -> String! { callingAETitle }
    @objc func extraParameters() -> [AnyHashable: Any]! { extraParametersStorage as? [AnyHashable: Any] }
    /// KVC: the Query window reads the node's peer by these keys.
    @objc var hostname: String! { _hostname }
    @objc var port: Int32 { _port }

    // MARK: Attributes

    private static var capitalized: Bool { UserDefaults.standard.bool(forKey: "CapitalizedString") }

    /// The value as shown: capitalized when the preference asks for it.
    static func displayed(_ value: String?) -> String? {
        capitalized ? value.map { ($0 as NSString).capitalized } : value
    }

    @objc func isDistant() -> Bool { true }
    @objc func comment() -> String! { "" }
    @objc func stateText() -> NSNumber! { nil }
    @objc func uid() -> String! { uidValue ?? "" }
    @objc func theDescription() -> String! { Self.displayed(descriptionValue) }
    @objc func name() -> String! { Self.displayed(nameValue) }
    @objc func accessionNumber() -> String! { accessionNumberValue }
    @objc func referringPhysician() -> String! { Self.displayed(referringPhysicianValue) }
    @objc func performingPhysician() -> String! { Self.displayed(performingPhysicianValue) }
    @objc func institutionName() -> String! { Self.displayed(institutionNameValue) }
    @objc func comments() -> String! { commentsValue }
    @objc func interpretationStatusID() -> String! { interpretationStatusIDValue }
    @objc func patientID() -> String! { patientIDValue }
    @objc func date() -> DICOMCalendarDate! { dateValue }
    @objc func birthdate() -> DICOMCalendarDate! { birthdateValue }
    @objc func yearOld() -> String! { DicomStudy.yearOld(fromDateOfBirth: birthdateValue as Date?) }
    @objc func yearOldAcquisition() -> String! {
        DicomStudy.yearOldAcquisition(dateValue as Date?, fromDateOfBirth: birthdateValue as Date?)
    }
    @objc func intervalSinceBirth() -> NSNumber! {
        guard let birth = birthdateValue as Date? else { return NSNumber(value: 0.0) }
        if UserDefaults.standard.integer(forKey: "yearOldDatabaseDisplay") == 0 {
            return NSNumber(value: Date().timeIntervalSince(birth))
        }
        guard let date = self.date() as Date? else { return NSNumber(value: 0.0) }
        return NSNumber(value: date.timeIntervalSince(birth))
    }
    @objc func time() -> DICOMCalendarDate! { timeValue }
    @objc func modality() -> String! { modalityValue }
    @objc func numberImages() -> NSNumber! { numberImagesValue }

    @objc func logEntry() -> NSManagedObject! { logEntryValue }
    @objc func setLogEntry(_ logEntry: NSManagedObject!) { logEntryValue = logEntry }

    @objc func setShowErrorMessage(_ show: Bool) { showErrorMessageValue = show }
    @objc func showErrorMessage() -> Bool { showErrorMessageValue }

    /// No patient name or accession number: this is what a node looks like in the log.
    override var description: String {
        "QueryNode: \(uidValue ?? "(null)") \(modalityValue ?? "(null)") \(calledAETitle ?? "(null)")"
    }

    // MARK: Children

    @objc func children() -> [Any]! {
        childrenLock.lock(); defer { childrenLock.unlock() }
        return childrenStorage.map { $0.mutableCopy() as? [Any] ?? [] }
    }

    @objc func setChildren(_ children: [Any]!) {
        childrenLock.lock(); defer { childrenLock.unlock() }
        childrenStorage = children.map { NSMutableArray(array: $0) }
    }

    @objc func purgeChildren() {
        childrenLock.lock(); defer { childrenLock.unlock() }
        childrenStorage = nil
    }

    @objc func childrenCount() -> UInt {
        childrenLock.lock(); defer { childrenLock.unlock() }
        return UInt(childrenStorage?.count ?? 0)
    }

    /// Adds `objects` to the children, making the list if there is none yet.
    func appendChildren(_ objects: [Any]) {
        guard !objects.isEmpty else { return }
        childrenLock.lock(); defer { childrenLock.unlock() }
        if childrenStorage == nil { childrenStorage = NSMutableArray() }
        childrenStorage?.addObjects(from: objects)
    }

    /// Takes the children a listing has added so far, emptying them.
    func drainChildren() -> [Any] {
        childrenLock.lock(); defer { childrenLock.unlock() }
        guard let storage = childrenStorage else { return [] }
        let taken = storage.copy() as? [Any] ?? []
        storage.removeAllObjects()
        return taken
    }

    /// A response of a search of this node, as a child of the level below.
    /// The root makes studies, a study series or images, a series images.
    func addChild(_ response: IsiXDCMTKDataset?) {}

    /// What a search of this node's children asks for.
    func queryPrototype() -> DICOMQueryIdentifier? { nil }

    /// What a retrieve of this node names.
    func moveIdentifier() -> DICOMQueryIdentifier? { nil }

    // MARK: Results of the last search and listing

    @objc var lastQuerySucceeded: Bool { lastQuerySucceededValue }
    @objc var imageInventoryConfirmed: Bool { imageInventoryConfirmedValue }
    @objc var lastQueryNotImplemented: Bool { lastQueryNotImplementedValue }
    @objc var imageListingNotImplemented: Bool {
        !imageInventoryConfirmedValue && listingNotImplemented && !listingFailedOtherwise
    }
    @objc var seriesInstanceCounts: [AnyHashable: Any] { seriesInstanceCountsStorage?.copy() as? [AnyHashable: Any] ?? [:] }
    @objc var seriesNumbers: [AnyHashable: Any] { seriesNumbersStorage?.copy() as? [AnyHashable: Any] ?? [:] }
    @objc var seriesDescriptions: [AnyHashable: Any] { seriesDescriptionsStorage?.copy() as? [AnyHashable: Any] ?? [:] }
    @objc var seriesDetails: [AnyHashable: Any] { seriesDetailsStorage?.copy() as? [AnyHashable: Any] ?? [:] }

    /// Sorts a failed search of a hierarchical walk: one the node said it does
    /// not implement, or any other failure, cancellation included.
    func noteFailedListing(notImplemented: Bool) {
        if notImplemented { listingNotImplemented = true } else { listingFailedOtherwise = true }
    }

    // MARK: Locking as @synchronized did

    /// Runs `body` holding the node's own lock, the one `@synchronized(node)`
    /// takes in Objective-C.
    @discardableResult
    func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        return try body()
    }

    // MARK: Notices

    /// A network failure is said in the notices panel. A modal alert held the
    /// main run loop in its modal mode until it was dismissed, and with it
    /// everything the import hands to the main thread.
    @objc(errorMessage:)
    class func errorMessage(_ message: [Any]) {
        let title = message.first.map { "\($0)" } ?? ""
        let text = message.count > 1 ? "\(message[1])" : ""
        NSLog("*** listener error: %@ %@", title, text)
        if !UserDefaults.standard.bool(forKey: "hideListenerError") {
            NetworkNotices.post(title: title, message: text)
        }
    }

    /// Posts a notice on the main thread through +errorMessage:, which the
    /// probes in tools/ replace to count the notices.
    static func postNotice(_ title: String, _ message: String) {
        let parts: NSArray = [title, message, NSLocalizedString("Continue", comment: "")]
        DCMTKQueryNode.performSelector(onMainThread: #selector(errorMessage(_:)), with: parts, waitUntilDone: false)
    }

    // MARK: Concurrent auto-retrieves of a node

    private static let semaphores = Mutex<[String: (semaphore: DispatchSemaphore, count: UInt)]>([:])

    /// The semaphore that limits the auto-retrieves of one node to
    /// MaxConcurrentPODRetrieves. It can wait, when the limit was lowered while
    /// retrieves were already past it.
    @objc(semaphoreForServerHostAndPort:)
    class func semaphore(forServerHostAndPort key: String) -> DispatchSemaphore {
        let limit = UInt(max(0, UserDefaults.standard.integer(forKey: "MaxConcurrentPODRetrieves")))
        return semaphores.withLock { table in
            guard var entry = table[key] else {
                let semaphore = DispatchSemaphore(value: Int(limit))
                table[key] = (semaphore, limit)
                return semaphore
            }
            while entry.count > limit {
                entry.semaphore.wait()
                entry.count -= 1
            }
            while entry.count < limit {
                entry.semaphore.signal()
                entry.count += 1
            }
            table[key] = entry
            return entry.semaphore
        }
    }

    // MARK: Inventory notification

    /// Posted on the main thread when a node's retrieve inventory changed.
    @objc static let retrieveInventoryDidRefreshNotification = "HorosRetrieveInventoryDidRefresh"
}

/// What an association of a query node is made with, from the node's entry in
/// Locations and the preferences.
struct DICOMAssociationSettings: Sendable {
    var acseTimeout: Int32
    var dimseTimeout: Int32
    var secureConnection = false
    var authenticate = false
    var certificateVerification: Int32 = 2
    var cipherSuites: [String] = []
    var dhParameterFile: String?
    var seedFile: String?

    /// TLS_SEED_FILE: the seed DCMTK's TLS layer reads, written again before each use.
    static var seedFilePath: String { (DICOMTLS.temporaryFolder() as NSString).appendingPathComponent("OsiriXTLSSeed") }

    init(extraParameters: [AnyHashable: Any]?) {
        let defaults = UserDefaults.standard
        if defaults.integer(forKey: "DICOMTimeout") <= 0 { defaults.set(20, forKey: "DICOMTimeout") }
        acseTimeout = Int32(truncatingIfNeeded: defaults.integer(forKey: "DICOMTimeout"))
        dimseTimeout = acseTimeout
        let parameters = extraParameters ?? [:]
        secureConnection = (parameters["TLSEnabled"] as AnyObject?)?.boolValue ?? false
        guard secureConnection else { return }
        authenticate = (parameters["TLSAuthenticated"] as AnyObject?)?.boolValue ?? false
        // An unrecognised value must not mean "do not check the peer".
        certificateVerification = Int32(TLSVerificationPolicy.normalise((parameters["TLSCertificateVerification"] as AnyObject?)?.intValue ?? 0))
        for suite in parameters["TLSCipherSuites"] as? [[String: Any]] ?? [] {
            if (suite["Supported"] as AnyObject?)?.boolValue == true, let cipher = suite["Cipher"] as? String { cipherSuites.append(cipher) }
        }
        if (parameters["TLSUseDHParameterFileURL"] as AnyObject?)?.boolValue == true {
            dhParameterFile = parameters["TLSDHParameterFileURL"] as? String
        }
        DICOMTLS.writePseudoRandomSeed(toPath: DICOMAssociationSettings.seedFilePath)
        seedFile = DICOMTLS.seedFilePath().map { String(cString: $0) }
    }

    /// Writes what DCMTK's TLS layer reads: the random seed, the trusted
    /// certificates of the Keychain and, to authenticate this end, its key and
    /// certificate, each under a name of this association; shared by the query
    /// nodes and the C-FINDs of plugins.
    func prepareSecureTransport(_ parameters: IsiXDCMTKAssociationParameters, host: String?, port: Int32, aeTitle: String?,
                                uniqueStringID: String) {
        parameters.secureConnection = true
        DICOMTLS.writePseudoRandomSeed(toPath: DICOMAssociationSettings.seedFilePath)
        parameters.seedFile = seedFile
        parameters.certificateVerification = certificateVerification
        parameters.cipherSuites = cipherSuites
        parameters.dhParameterFile = dhParameterFile
        if certificateVerification == 0 || certificateVerification == 1 {
            let directory = DICOMTLS.trustedCertificatesFolder(withStringID: uniqueStringID)
            KeychainExport.exportTrustedCertificates(toDirectory: directory)
            let certificates = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            parameters.trustedCertificateFiles = certificates.map { (directory as NSString).appendingPathComponent($0) }
        }
        if authenticate {
            parameters.privateKeyPassword = DICOMTLS.privateKeyPassword()
            // Exported from the Keychain to the disk for DCMTK.
            DICOMTLS.generateCertificateAndKey(forServerAddress: host, port: port, aeTitle: aeTitle, withStringID: uniqueStringID)
            parameters.privateKeyFile = DICOMTLS.keyPath(forServerAddress: host, port: port, aeTitle: aeTitle, withStringID: uniqueStringID)
            parameters.certificateFile = DICOMTLS.certificatePath(forServerAddress: host, port: port, aeTitle: aeTitle, withStringID: uniqueStringID)
        }
    }

    /// Removes what prepareSecureTransport wrote.
    static func removeSecureTransportFiles(host: String?, port: Int32, aeTitle: String?, uniqueStringID: String) {
        let files = FileManager.default
        try? files.removeItem(atPath: DICOMTLS.keyPath(forServerAddress: host, port: port, aeTitle: aeTitle, withStringID: uniqueStringID))
        try? files.removeItem(atPath: DICOMTLS.certificatePath(forServerAddress: host, port: port, aeTitle: aeTitle, withStringID: uniqueStringID))
        try? files.removeItem(atPath: DICOMTLS.trustedCertificatesFolder(withStringID: uniqueStringID))
    }
}

extension DICOMQueryIdentifier {
    /// The DCMTK dataset this identifier is sent as.
    func dataset() -> IsiXDCMTKDataset {
        let dataset = IsiXDCMTKDataset()
        for (tag, value) in elements {
            if value.isEmpty { try? dataset.insertEmptyElement(withTag: tag.rawValue) }
            else { try? dataset.putValue(Data(value), forTag: tag.rawValue) }
        }
        return dataset
    }
}

extension IsiXDCMTKDataset {
    /// The first value of `tag` read as UTF-8, as the code reading OFStrings did; nil when absent.
    func utf8Value(_ tag: DICOMTag) -> String? {
        stringValue(forTag: tag.rawValue).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Every value of `tag` read as UTF-8, separated by backslashes; nil when absent.
    func utf8Values(_ tag: DICOMTag) -> String? {
        stringArrayValue(forTag: tag.rawValue).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The value of `tag` as it is held, read as ISO Latin 1, as the levels
    /// read UIDs, dates and codes.
    func latin1Value(_ tag: DICOMTag) -> String? {
        rawValue(forTag: tag.rawValue).flatMap { String(data: $0, encoding: .isoLatin1) }
    }

    /// The value of `tag` read in the response's character sets, as
    /// +[DicomFile stringWithBytes:encodings:] reads a file's.
    func text(_ tag: DICOMTag, encodings: [UInt], replaceBadCharacters: Bool = true) -> String? {
        guard let value = rawValue(forTag: tag.rawValue) else { return nil }
        var bytes = [CChar](repeating: 0, count: value.count + 1)
        value.withUnsafeBytes { raw in
            for (index, byte) in raw.enumerated() { bytes[index] = CChar(bitPattern: byte) }
        }
        var table = encodings
        return bytes.withUnsafeMutableBufferPointer { text in
            table.withUnsafeMutableBufferPointer { list in
                DicomFile.string(withBytes: text.baseAddress, encodings: list.baseAddress,
                                 replaceBadCharacters: replaceBadCharacters).map { $0 as String }
            }
        }
    }

    /// The ten encodings of a response's Specific Character Set: the first is
    /// ISO Latin 1 when it names none, and a list shorter than ten repeats its last.
    func characterSetEncodings() -> (characterSet: String?, encodings: [UInt]) {
        var encodings = [UInt](repeating: 0, count: 10)
        encodings[0] = String.Encoding.isoLatin1.rawValue
        guard let characterSet = latin1Value(.specificCharacterSet) else { return (nil, encodings) }
        let names = characterSet.components(separatedBy: "\\")
        if names.count >= 10 { NSLog("Encoding number >= 10 ???") }
        if names.count < 10 {
            for index in 0..<10 {
                encodings[index] = NSString.encoding(forDICOMCharacterSet: index < names.count ? names[index] : names.last)
            }
        }
        return (characterSet, encodings)
    }
}
