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
import IsiXDICOMNetwork
import IsiXKeychain
import IsiXDICOMFile

/// The queries and retrieves other code asks of Query/Retrieve without its
/// window: the browser's distant studies and comparatives, the web portal,
/// XML-RPC and the routing rules. They run on the calling thread, often a
/// worker, and touch no window.
extension QueryController {
    /// The studies with Study Instance UID `an` on `aServer`, showing errors.
    @objc(queryStudyInstanceUID:server:)
    public nonisolated class func queryStudyInstanceUID(_ an: String!, server aServer: [AnyHashable: Any]!) -> [Any]! {
        return queryStudyInstanceUID(an, server: aServer, showErrors: true)
    }

    @objc(queryStudyInstanceUID:server:showErrors:)
    public nonisolated class func queryStudyInstanceUID(_ an: String!, server aServer: [AnyHashable: Any]!, showErrors: Bool) -> [Any]! {
        var array: NSArray?

        do {
            try HorosObjCException.perform {
                let qm = QueryArrayController(callingAET: UserDefaults.defaultAETitle(), distantServer: aServer as NSDictionary?)

                let filterValue = (an ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

                if (filterValue as NSString).length > 0 {
                    qm.addFilter(filterValue, forDescription: "StudyInstanceUID")
                    qm.performQuery(showErrors)
                    array = qm.queries()
                }

                for a in array ?? [] where type(of: a as AnyObject) != DCMTKStudyQueryNode.self {
                    NSLog("warning : [item isMemberOfClass:[DCMTKStudyQueryNode class]] == NO")
                }
            }
        } catch {
            NSLog("%@", describe(error))
        }

        return array as? [Any]
    }

    @objc(queryAndRetrieveAccessionNumber:server:)
    public nonisolated class func queryAndRetrieveAccessionNumber(_ an: String!, server aServer: [AnyHashable: Any]!) -> Int32 {
        return queryAndRetrieveAccessionNumber(an, server: aServer, showErrors: true)
    }

    /// Queries the accession number `an` on `aServer` and retrieves what it
    /// finds: 0, -3 when nothing was found, -2 when the query failed.
    @objc(queryAndRetrieveAccessionNumber:server:showErrors:)
    public nonisolated class func queryAndRetrieveAccessionNumber(_ an: String!, server aServer: [AnyHashable: Any]!, showErrors: Bool) -> Int32 {
        var status: Int32 = 0

        do {
            try HorosObjCException.perform {
                let qm = QueryArrayController(callingAET: UserDefaults.defaultAETitle(), distantServer: aServer as NSDictionary?)

                let filterValue = (an ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

                if (filterValue as NSString).length > 0 {
                    qm.addFilter(filterValue, forDescription: "AccessionNumber")

                    qm.performQuery(showErrors)

                    let array = qm.queries() ?? []

                    let dictionary = NSMutableDictionary(dictionary: (qm.parameters() as? [AnyHashable: Any]) ?? [:])

                    for case let object as DCMTKQueryNode in array {
                        object.setShowErrorMessage(showErrors)

                        dictionary["calledAET"] = object.value(forKey: "calledAET")
                        dictionary["hostname"] = object.value(forKey: "hostname")
                        dictionary["port"] = object.value(forKey: "port")
                        dictionary["transferSyntax"] = object.value(forKey: "transferSyntax")

                        if HorosDICOMGlobalAbortRequested() == 0 {
                            object.move(dictionary as? [AnyHashable: Any])
                        }
                    }

                    if array.count == 0 { status = -3 }
                }
            }
        } catch {
            NSLog("%@", describe(error))
            status = -2
        }

        return status
    }

    @objc(retrieveStudies:showErrors:)
    public nonisolated class func retrieveStudies(_ studies: [Any]!, showErrors: Bool) {
        retrieveStudies(studies, showErrors: showErrors, checkForPreviousAutoRetrieve: false)
    }

    /// Retrieves `studies` one after the other on the calling thread, which
    /// shows the progress. With `checkForPreviousAutoRetrieve`, a study is
    /// retrieved again only when its node reports another number of images
    /// than the last time.
    @objc(retrieveStudies:showErrors:checkForPreviousAutoRetrieve:)
    public nonisolated class func retrieveStudies(_ studies: [Any]!, showErrors: Bool, checkForPreviousAutoRetrieve: Bool) {
        let studies = studies ?? []
        let dictionary = NSMutableDictionary()

        var i = 0
        for case let object as DCMTKQueryNode in studies {
            let thread = Thread.current
            thread.progress = CGFloat(Float(i) / Float(studies.count))
            i += 1
            if let description = object.theDescription() {
                thread.status = String(format: "%@ - %@", object.name() ?? "(null)", description)
            } else {
                thread.status = String(format: "%@", object.name() ?? "(null)")
            }
            if thread.isCancelled {
                break
            }

            var proceedToDownload = true

            if checkForPreviousAutoRetrieve {
                RetrieveInTransfer.withLock { inTransfer in
                    let key = QueryController.stringID(forStudy: object)
                    let totalFiles = int32(object.value(forKey: "numberImages"))

                    // We only want to re-retrieve the study if they are new
                    // files compared to last time... we are maybe currently in
                    // the middle of a retrieve...
                    if (inTransfer[key] ?? 0) != totalFiles {
                        inTransfer[key] = totalFiles
                    } else {
                        proceedToDownload = false
                    }
                }
            }

            guard proceedToDownload else { continue }

            do {
                try HorosObjCException.perform {
                    object.setShowErrorMessage(showErrors)

                    dictionary["calledAET"] = object.value(forKey: "calledAET")
                    dictionary["hostname"] = object.value(forKey: "hostname")
                    dictionary["port"] = object.value(forKey: "port")
                    dictionary["transferSyntax"] = object.value(forKey: "transferSyntax")
                    let retrieveMode = (object.extraParameters() as NSDictionary?)?.value(forKey: "retrieveMode")
                    dictionary["retrieveMode"] = retrieveMode

                    if HorosDICOMGlobalAbortRequested() == 0 {
                        object.move(dictionary as? [AnyHashable: Any], retrieveMode: int32(retrieveMode))
                    }
                }
            } catch {
                log(error, "+[QueryController retrieveStudies:showErrors:checkForPreviousAutoRetrieve:]")
            }

            if checkForPreviousAutoRetrieve {
                RetrieveInTransfer.withLock { $0[stringID(forStudy: object)] = nil }
            }
        }
    }

    /// The same study can come back from more than one node, and now from more
    /// than one query; keep one copy, the one that reports the most images.
    @objc(mergeStudies:into:)
    nonisolated class func mergeStudies(_ found: [Any]?, into studies: NSMutableArray) {
        var merged = studies.map { $0 as AnyObject }
        QueryResultMerge.merge((found ?? []).map { $0 as AnyObject }, into: &merged, indexingAdditions: true,
                               uid: queryUID, images: queryImageCount)
        studies.setArray(merged)
    }

    /// The UID a query result is merged on: -[NSArray valueForKey:@"uid"].
    nonisolated static func queryUID(_ study: AnyObject) -> AnyHashable? {
        return study.value(forKey: "uid") as? NSObject
    }

    /// The number of images a query result reports, nil when it says none.
    nonisolated static func queryImageCount(_ study: AnyObject) -> Int32? {
        guard let count = study.value(forKey: "numberImages") else { return nil }
        return int32(count)
    }

    /// The studies matching `filters`, a dictionary of the keys of the web
    /// portal, XML-RPC and the browser, on every node of `serversList`.
    @objc(queryStudiesForFilters:servers:showErrors:)
    public nonisolated class func queryStudies(forFilters filters: [AnyHashable: Any]!, servers serversList: [Any]!,
                                               showErrors: Bool) -> NSMutableArray! {
        let filters = (filters ?? [:]) as NSDictionary

        // A field holding several patient identifiers is a list, not a value:
        // DICOM has no list, so it becomes one query per identifier and the
        // union of what they find.
        var patientIDFilter = filters.value(forKey: "PatientID") as? String
        var patientIDKey = "PatientID"
        if patientIDFilter == nil {
            patientIDFilter = filters.value(forKey: "patientID") as? String
            patientIDKey = "patientID"
        }

        if PatientIdentifierList.namesSeveral(patientIDFilter) {
            let identifiers = PatientIdentifierList.identifiers(in: patientIDFilter)
            let combined = NSMutableArray()

            NSLog("---- patient identifier list: %@", PatientIdentifierList.summary(forText: patientIDFilter))

            for (index, identifier) in identifiers.enumerated() {
                if Thread.current.isCancelled {
                    NSLog("---- patient identifier list: cancelled after %d of %d", Int32(index), Int32(identifiers.count))
                    break
                }

                let one = filters.mutableCopy() as! NSMutableDictionary
                one.removeObject(forKey: "PatientID")
                one.removeObject(forKey: "patientID")
                one.setObject(identifier, forKey: patientIDKey as NSString)

                let found = QueryController.queryStudies(forFilters: one as? [AnyHashable: Any], servers: serversList, showErrors: showErrors) ?? NSMutableArray()

                NSLog("---- patient identifier %d of %d: %d stud%@", Int32(index + 1), Int32(identifiers.count), Int32(found.count), found.count == 1 ? "y" : "ies")

                QueryController.mergeStudies(found as? [Any], into: combined)
            }

            return combined
        }

        let studies = NSMutableArray()

        do {
            try HorosObjCException.perform {
                for case let server as NSDictionary in serversList ?? [] {
                    Thread.current.status = server.value(forKey: "Description") as? String

                    let qm = QueryArrayController(callingAET: UserDefaults.defaultAETitle(), distantServer: server)

                    if let encoding = UserDefaults.standard.string(forKey: "STRINGENCODING"), encoding != "ISO_IR 100" {
                        // Specific Character Set
                        qm.addFilter(encoding, forDescription: "SpecificCharacterSet")
                    }

                    let built = QueryStudyFilters.build(filters as? [String: Any] ?? [:],
                                                        permissions: QueryStudyFilters.Permissions(defaults: .standard),
                                                        birthDate: { birth in
                                                            DICOMCalendarDate.queryDate(DICOMCalendarDate.string(from: birth, calendarFormat: "%Y%m%d"))
                                                        },
                                                        studyDateAndTime: { code, from, to in
                                                            let (date, time) = QueryController.dateAndTimeQueryFilters(tag: code, from: from as? Date,
                                                                                                                       to: to as? Date)
                                                            return (date.flatMap { DICOMCalendarDate.queryDate($0.filteredValue() as String?) },
                                                                    time.flatMap { DICOMCalendarDate.queryDate($0.filteredValue() as String?) })
                                                        })
                    for removal in built.removed {
                        switch removal {
                        case .tooShort(let key, let value):
                            NSLog("---- too small query -> removed: %@", QueryLog.term(key: key, value: value))
                        case .empty(let key):
                            NSLog("---- empty key (%@) -> removed", key)
                        }
                    }

                    qm.filters()?.addEntries(from: built.filters)

                    if (qm.filters()?.count ?? 0) == 0 || built.filters.isEmpty {
                        NSLog("***** no query parameters for queryStudiesForFilters: query not performed.")
                    } else {
                        Thread.current.supportsCancel = true

                        qm.performQuery(showErrors)

                        let studiesForThisNode = qm.queries()

                        if studiesForThisNode == nil {
                            NSLog("queryStudiesForFilters failed for this node: %@", (server.value(forKey: "Description") as? String) ?? "(null)")
                        }

                        QueryController.mergeStudies(studiesForThisNode as? [Any], into: studies)
                    }
                }
            }
        } catch {
            NSLog("%@", describe(error))
        }

        return studies
    }

    /// The studies of the patient of `study` on `serversList`, by the identity
    /// fields asked for; nil when they cannot identify the patient. What the
    /// nodes answer is checked against the same fields: a node can answer more
    /// broadly than it was asked, wildcards in an identifier included.
    @objc(queryStudiesForPatient:usePatientID:usePatientName:usePatientBirthDate:servers:showErrors:)
    public nonisolated class func queryStudies(forPatient study: DicomStudy!, usePatientID: Bool, usePatientName: Bool,
                                               usePatientBirthDate: Bool, servers serversList: [Any]!, showErrors: Bool) -> [Any]! {
        if !usePatientID && !usePatientName && !usePatientBirthDate {
            NSLog("****** QR: usePatientID == NO && usePatientName == NO && usePatientBirthDate == NO")
            return nil
        }

        if usePatientName && ((study?.name ?? "") as NSString).length == 0 {
            NSLog("****** QR: usePatientName == YES && study.name.length == 0 : %@", study?.studyInstanceUID ?? "(null)")
            return nil
        }

        if usePatientBirthDate && study?.dateOfBirth == nil {
            NSLog("****** QR: usePatientBirthDate == YES && study.dateOfBirth == 0 : %@", study?.studyInstanceUID ?? "(null)")
            return nil
        }

        if usePatientID && ((study?.patientID ?? "") as NSString).length == 0 {
            NSLog("****** QR: usePatientID && study.patientID.length == 0 : %@", study?.studyInstanceUID ?? "(null)")
            return nil
        }

        if usePatientName && !usePatientBirthDate && !usePatientID {
            NSLog("****** QR: cannot query history on patient's name only, patient birthdate or patient ID required !")
            return nil
        }

        #if DEBUG
        NSLog("------- queryStudiesForPatient: %@", study?.studyInstanceUID ?? "(null)")
        #endif

        let filters = NSMutableDictionary()

        if usePatientBirthDate, let birth = study?.dateOfBirth {
            filters["PatientBirthDate"] = birth
        }

        if usePatientID, let patientID = study?.patientID {
            filters["PatientID"] = patientID
        }

        let studies = QueryController.queryStudies(forFilters: filters as? [AnyHashable: Any], servers: serversList, showErrors: showErrors) ?? NSMutableArray()

        var birthDateCalendar: Calendar?
        if usePatientBirthDate {
            birthDateCalendar = Calendar(identifier: .gregorian)
            birthDateCalendar?.timeZone = NSTimeZone.default
        }
        // Validate returned identity as well as sending query filters. A PACS
        // can return broader results, including when an identifier contains
        // wildcards.
        for x in stride(from: studies.count - 1, through: 0, by: -1) {
            let s = studies[x] as? DCMTKStudyQueryNode
            var matchesPatient = true
            if usePatientID && s?.patientID() != study?.patientID {
                matchesPatient = false
            }
            if usePatientBirthDate {
                if let found = s?.dateOfBirth(), let wanted = study?.dateOfBirth, let calendar = birthDateCalendar,
                   calendar.isDate(found, inSameDayAs: wanted) {
                } else {
                    matchesPatient = false
                }
            }
            if usePatientName && DicomFile.nSreplaceBadCharacter(s?.name()) != study?.name {
                matchesPatient = false
            }
            if !matchesPatient {
                studies.removeObject(at: x)
            }
        }

        return studies as? [Any]
    }

    // MARK: Verification

    @objc(echo:port:AET:)
    public nonisolated class func echo(_ address: String!, port: Int32, aet: String!) -> Bool {
        return echoServer(["Address": address as Any, "Port": NSNumber(value: port), "AETitle": aet as Any,
                           "TLSEnabled": NSNumber(value: false)])
    }

    /// A C-ECHO of the node `serverParameters` with echoscu (DICOMweb: its
    /// verification request); YES when it answered, or when it cannot be asked.
    @objc(echoServer:)
    public nonisolated class func echoServer(_ serverParameters: [AnyHashable: Any]!) -> Bool {
        if DICOMwebSources.isDICOMwebServer(serverParameters) {
            return DCMTKQueryNode.verifyDICOMServer(serverParameters)
        }
        let parameters = (serverParameters ?? [:]) as NSDictionary
        var answered = true

        do {
            try HorosObjCException.perform {
                answered = echoWithEchoscu(parameters)
            }
        } catch {
            log(error, "+[QueryController echoServer:]")
            answered = true
        }

        return answered
    }

    private nonisolated class func echoWithEchoscu(_ serverParameters: NSDictionary) -> Bool {
        let address = serverParameters.object(forKey: "Address") as? String
        let port = int32(serverParameters.object(forKey: "Port"))
        let aet = serverParameters.object(forKey: "AETitle") as? String

        let uniqueStringID = String(format: "%d.%d.%d", getpid(), QueryController.nextEchoIdentifier(), Int32.random(in: 0...Int32.max))

        let resources = Bundle.main.resourcePath ?? ""
        let echoscu = (resources as NSString).appendingPathComponent("/echoscu")
        if !FileManager.default.fileExists(atPath: echoscu) {
            return true
        }

        let theTask = Process()
        theTask.executableURL = URL(fileURLWithPath: echoscu)
        theTask.environment = ["DCMDICTPATH": (resources as NSString).appendingPathComponent("/dicom.dic")]

        let timeout = UserDefaults.standard.string(forKey: "DICOMTimeout") ?? ""
        var args: [String] = [address ?? "", String(port),
                              "-aet", UserDefaults.defaultAETitle() ?? "", // set my calling AE title
                              "-aec", aet ?? "", // set called AE title of peer
                              "-to", timeout, // timeout for connection requests
                              "-ta", timeout, // timeout for ACSE messages
                              "-td", timeout] // timeout for DIMSE messages

        let tlsEnabled = bool(serverParameters.object(forKey: "TLSEnabled"))
        if tlsEnabled {
            // TLS support. Options listed here http://support.dcmtk.org/docs/echoscu.html

            if bool(serverParameters.object(forKey: "TLSAuthenticated")) {
                args.append("--enable-tls") // use authenticated secure TLS connection

                // export certificate/key from the Keychain to the disk
                DICOMTLS.generateCertificateAndKey(forServerAddress: address, port: port, aeTitle: aet, withStringID: uniqueStringID)
                args.append(DICOMTLS.keyPath(forServerAddress: address, port: port, aeTitle: aet, withStringID: uniqueStringID)) // [p]rivate key file
                args.append(DICOMTLS.certificatePath(forServerAddress: address, port: port, aeTitle: aet, withStringID: uniqueStringID)) // [c]ertificate file: string

                args.append("--use-passwd")
                args.append(DICOMTLS.privateKeyPassword())
            } else {
                args.append("--anonymous-tls") // use secure TLS connection without certificate
            }

            // key and certificate file format options:
            args.append("--pem-keys")

            // ciphersuite options:
            for case let suite as NSDictionary in serverParameters.object(forKey: "TLSCipherSuites") as? NSArray ?? [] {
                if bool(suite.object(forKey: "Supported")) {
                    args.append("--cipher") // add ciphersuite to list of negotiated suites
                    args.append((suite.object(forKey: "Cipher") as? String) ?? "")
                }
            }

            if bool(serverParameters.object(forKey: "TLSUseDHParameterFileURL")) {
                args.append("--dhparam") // read DH parameters for DH/DSS ciphersuites
                args.append((serverParameters.object(forKey: "TLSDHParameterFileURL") as? String) ?? "")
            }

            // peer authentication options:
            // An unrecognised value must not mean "do not check the peer".
            let verification = TLSVerificationPolicy.normalise(Int(int32(serverParameters.object(forKey: "TLSCertificateVerification"))))
            if verification == TLSVerificationPolicy.require {
                args.append("--require-peer-cert") // verify peer certificate, fail if absent (default)
            } else if verification == TLSVerificationPolicy.verify {
                args.append("--verify-peer-cert") // verify peer certificate if present
            } else { // IgnorePeerCertificate
                args.append("--ignore-peer-cert") // don't verify peer certificate
            }

            // certification authority options:
            if verification == TLSVerificationPolicy.require || verification == TLSVerificationPolicy.verify {
                let trustedCertificatesDir = trustedCertificatesDirectory(uniqueStringID)
                KeychainExport.exportTrustedCertificates(toDirectory: trustedCertificatesDir)
                let trustedCertificates = (try? FileManager.default.contentsOfDirectory(atPath: trustedCertificatesDir)) ?? []

                // Certificate-directory support would require OpenSSL-compatible certificate filenames.
                for cert in trustedCertificates {
                    args.append("--add-cert-file")
                    args.append((trustedCertificatesDir as NSString).appendingPathComponent(cert))
                }
            }

            // pseudo random generator options.
            // We initialize the pseudo-random number generator with the content
            // of the screen which is is hardly predictable for an attacker
            // see http://www.mevis-research.de/~meyer/dcmtk/docs_352/dcmtls/randseed.txt
            let seed = seedFile()
            DICOMTLS.writePseudoRandomSeed(toPath: seed)
            args.append("--seed") // seed random generator with contents of f
            args.append(seed)
        }

        theTask.arguments = args
        do {
            try theTask.run()
        } catch {
            NSLog("%@", (error as NSError).description)
            return true
        }

        var aborted = false
        if Thread.isMainThread {
            let nodeDescription = serverParameters.object(forKey: "Description") as? String
            aborted = MainActor.assumeIsolated {
                var description = nodeDescription
                if description == nil {
                    description = ""
                }

                let wait = WaitRendering(String(format: NSLocalizedString("DICOM Echo %@...", comment: ""), description ?? ""))
                wait?.setCancel(true)
                wait?.showWindow(self)
                wait?.start()

                while theTask.isRunning {
                    Thread.sleep(forTimeInterval: 0.1)

                    _ = wait?.run()
                    if wait?.aborted() == true {
                        break
                    }
                }

                wait?.end()
                return wait?.aborted() ?? false
            }
        } else {
            while theTask.isRunning {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }

        if tlsEnabled {
            try? FileManager.default.removeItem(atPath: DICOMTLS.keyPath(forServerAddress: address, port: port, aeTitle: aet,
                                                                         withStringID: uniqueStringID))
            try? FileManager.default.removeItem(atPath: DICOMTLS.certificatePath(forServerAddress: address, port: port, aeTitle: aet,
                                                                                 withStringID: uniqueStringID))
            try? FileManager.default.removeItem(atPath: DICOMTLS.trustedCertificatesFolder(withStringID: uniqueStringID))
        }

        if aborted {
            return false
        }

        return theTask.terminationStatus == 0
    }

    /// TLS_TRUSTED_CERTIFICATES_DIR followed by `identifier`.
    private nonisolated static func trustedCertificatesDirectory(_ identifier: String) -> String {
        return DICOMTLS.trustedCertificatesFolder(withStringID: identifier)
    }

    /// TLS_SEED_FILE.
    private nonisolated static func seedFile() -> String {
        return (DICOMTLS.temporaryFolder() as NSString).appendingPathComponent("OsiriXTLSSeed")
    }

    private nonisolated static let echoCounter = EchoCounter()

    /// The `inc++` of the former echo: one number per echo of the process.
    private nonisolated static func nextEchoIdentifier() -> Int32 {
        return echoCounter.next()
    }

    private final class EchoCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int32 = 0
        func next() -> Int32 {
            lock.lock()
            defer { lock.unlock() }
            let current = value
            value &+= 1
            return current
        }
    }

    /// The node's identity, for -dicomEcho: of the sources table.
    @objc(dicomEcho:)
    public func dicomEcho(_ aServer: [AnyHashable: Any]!) -> Int32 {
        return QueryController.echoServer(aServer) ? 1 : 0
    }

    /// What a study is known by while it is being retrieved: its name, patient
    /// ID, accession number, date, time and UID.
    @objc(stringIDForStudy:)
    public nonisolated class func stringID(forStudy item: Any!) -> String {
        let item = item as AnyObject
        let values = ["name", "patientID", "accessionNumber", "date", "time", "uid"].map { key -> String in
            guard let value = item.value(forKey: key) else { return "(null)" }
            return (value as? NSObject)?.description ?? String(describing: value)
        }
        return values.joined(separator: "-")
    }
}

/// The studies being retrieved, by -stringIDForStudy:, with the number of
/// images their node reported: a study is not asked for again while that
/// number stays the same. `previousAutoRetrieve` of the former class.
enum RetrieveInTransfer {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts: [String: Int32] = [:]

    static func withLock<T>(_ body: (inout [String: Int32]) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&counts)
    }
}
