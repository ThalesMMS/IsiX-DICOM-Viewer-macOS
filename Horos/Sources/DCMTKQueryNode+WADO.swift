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

/// The WADO-URI retrieve of a DIMSE node that has a WADO service: the
/// instances it lists by C-FIND, asked for one URL each.
extension DCMTKQueryNode {

    /// Locations' Test and the retrieve use exactly the same WADO-URI syntax.
    @objc(syntaxStringFor:imageQuality:)
    class func syntaxString(for syntax: Int32, imageQuality quality: UnsafeMutablePointer<Int32>) -> String {
        let (parameter, chosen) = WADOURITransferSyntax.parameter(forSetting: Int(syntax))
        quality.pointee = Int32(chosen)
        return parameter
    }

    @objc(syntaxStringFor:imageQuality:)
    func syntaxString(for syntax: Int32, imageQuality quality: UnsafeMutablePointer<Int32>) -> String {
        Self.syntaxString(for: syntax, imageQuality: quality)
    }

    /// A downloader with this node's limit, shared with its other retrieves.
    private func wadoDownloader(authorization: String?) -> WADODownload {
        let downloader = WADODownload()
        downloader.maximumConcurrentDownloads = NodeRequestLimiter.wadoLimit(forServer: extraParameters(), defaults: .standard)
        downloader.limiterNode = NodeRequestLimiter.wadoKey(forServer: extraParameters())
        downloader.authorization = authorization
        downloader.adaptiveRequests = NodeRequestLimiter.adaptive(forStoredValue: extraParameters()?[NodeRequestLimiter.wadoAdaptiveKey])
        downloader.showErrorMessage = showErrorMessageValue
        return downloader
    }

    /// `listing` maps the SOP Instance UIDs the operation listed to their
    /// series; nil lists them again here.
    @objc(WADORetrieve:listing:)
    func wadoRetrieve(study: DCMTKQueryNode?, listing: [String: String]?) {
        let parameters = extraParameters() ?? [:]
        let isSeries = self is DCMTKSeriesQueryNode, isStudy = self is DCMTKStudyQueryNode
        #if DEBUG
        NSLog("------ WADO download : starting... %@", (isSeries ? study?.uid() : uid()) ?? "(null)")
        #endif
        let `protocol` = Self.int32(parameters["WADOhttps"]) != 0 ? "https" : "http"
        var wadoSubURL = parameters["WADOUrl"] as? String ?? ""
        if wadoSubURL.hasPrefix("/") { wadoSubURL.removeFirst() }

        // The node's username and password go in each request's Authorization
        // header, read from the Keychain, never in the URL: the URL is logged,
        // and a password with '@', ':' or '/' would change it.
        var authorization: String?
        do {
            authorization = try WADOCredentials.authorization(forServer: parameters as NSDictionary)
        } catch {
            NSLog("------ WADO retrieve: the node's credentials could not be read: %@", error.localizedDescription)
            if showErrorMessageValue && !Thread.current.isCancelled {
                Self.postNotice(NSLocalizedString("WADO Retrieve Failed", comment: ""), error.localizedDescription)
            }
            return
        }
        if authorization?.isEmpty == true { authorization = nil }

        // An https server is trusted the way the system trusts it: a private
        // CA is added to the Keychain, not waived here.
        let baseURL = "\(`protocol`)://\(_hostname ?? "(null)"):\(Self.int32(parameters["WADOPort"]))/\(wadoSubURL)?requestType=WADO"
        var quality: Int32 = 100
        let syntax = syntaxString(for: Self.int32(parameters["WADOTransferSyntax"]), imageQuality: &quality)

        // What is here already.
        let localStudyUID: String? = isSeries ? study?.uid() : isStudy ? uid() : nil
        let localObjectUIDs = Set(localSOPInstanceUIDs(ofStudy: localStudyUID, series: nil))

        // The order the requests of a study start in, from the node's setting:
        // the series by UID, by number, or fewest instances first. A series the
        // operator chooses meanwhile goes first among those not started.
        let plan: RetrievePlan? = isStudy ? RetrievePlan(order: RetrievePlan.order(forStoredValue: parameters[RetrievePlan.wadoKey])) : nil
        let planEndpoint = inventoryEndpoint()
        // The node's rules leave out of a study the series whose description
        // matches one, unless this operation asks for everything again; a
        // series asked for by itself is retrieved whatever they say.
        let exclusionRules = noSmartMode ? [] : RetrievePlan.exclusionRules(forStoredValue: parameters[RetrievePlan.wadoExclusionKey])
        plan?.exclude(matching: exclusionRules)
        if isSeries && !exclusionRules.isEmpty,
           let rule = RetrievePlan.exclusionRule(for: theDescription() ?? "", rules: exclusionRules) {
            noteExplicitRetrieveOfSeriesExcluded(byRule: rule)
        }
        func url(study: String?, series: String?, object: String?) -> URL? {
            URL(string: baseURL + "&studyUID=\(study ?? "(null)")&seriesUID=\(series ?? "(null)")&objectUID=\(object ?? "(null)")&contentType=application/dicom\(syntax)")
        }

        if let listing, !listing.isEmpty {
            // The listing is this operation's: no second enumeration of the study.
            let studyUID = isSeries ? study?.uid() : uid()
            let onlySeries = isSeries ? uid() : nil
            var urlToDownload: [URL] = []
            var alreadyHere = 0
            let ordered = listing.keys.sorted { first, second in
                let bySeries = (listing[first] ?? "").compare(listing[second] ?? "")
                return bySeries != .orderedSame ? bySeries == .orderedAscending : first.compare(second) == .orderedAscending
            }
            for objectUID in ordered {
                let seriesUID = listing[objectUID]
                if let onlySeries, seriesUID != onlySeries { continue }
                if localObjectUIDs.contains(objectUID) { alreadyHere += 1; continue }
                if let address = url(study: studyUID, series: seriesUID, object: objectUID) { urlToDownload.append(address) }
            }
            if let plan {
                // What the listing gives: each series' instances, counted, and
                // the series numbers its walk was given.
                let counts = NSCountedSet(array: Array(listing.values))
                for case let seriesUID as String in (counts.allObjects as NSArray).sortedArray(using: #selector(NSString.compare(_:))) {
                    plan.add(series: seriesUID, number: seriesNumbersStorage?[seriesUID] as? NSNumber,
                             instances: NSNumber(value: counts.count(for: seriesUID)),
                             description: seriesDescriptionsStorage?[seriesUID] as? String)
                }
                plan.markSeriesListed()
                urlToDownload = plan.eligible(urls: plan.order(urls: urlToDownload))
                if !plan.excludedSeries.isEmpty { currentRetrieveInventory()?.exclude(series: plan.excludedSeries) }
                if plan.excludesEverything {
                    countOfSuboperations = 0
                    countOfSuccessfulSuboperations = 0
                    noteExcludedSeries(plan.excludedSeries, everything: true)
                    return
                }
                plan.begin(endpoint: planEndpoint, study: studyUID ?? "")
            }
            let downloader = wadoDownloader(authorization: authorization)
            downloader.retrievePlan = plan
            downloader.WADOBaseTotal = Int32(alreadyHere)
            downloader.WADOGrandTotal = Int32(alreadyHere + urlToDownload.count)
            downloader.WADODownload(urlToDownload)
            plan?.end(endpoint: planEndpoint, study: studyUID ?? "")
            if let manifest = downloader.manifest { recordWADOManifest(manifest) }
            countOfSuboperations = UInt(urlToDownload.count)
            countOfSuccessfulSuboperations = UInt(max(0, downloader.countOfSuccesses))
            if !Thread.current.isCancelled { noteExcludedSeries(plan?.excludedSeries ?? [:], everything: false) }
            return
        }

        if isStudy {
            // At the STUDY level, straight to the IMAGE level: the walk gives
            // the plan its series before their instances.
            let cFindThread = Thread { [self] in wadoCFind() }
            retrievePlan = plan
            plan?.begin(endpoint: planEndpoint, study: uid() ?? "")
            cFindThread.start()
            Thread.sleep(forTimeInterval: 0.1)

            let downloader = wadoDownloader(authorization: authorization)
            downloader.WADOBaseTotal = 0
            downloader.WADOGrandTotal = numberImagesValue?.int32Value ?? 0 // For the GUI progress bar
            downloader.retrievePlan = plan

            // isFinished, not isExecuting: the worker may not have begun
            // executing after the pause above, and the loop then never ran.
            while (!cFindThread.isFinished || childrenCount() > 0) && !Thread.current.isCancelled {
                if childrenCount() > 50 || cFindThread.isFinished {
                    var childrenArray = drainChildren()
                    var urlToDownload: [URL] = []
                    catchingExceptions {
                        childrenArray = (childrenArray as NSArray).sortedArray(using: [NSSortDescriptor(key: "seriesInstanceUID", ascending: true)])
                        for case let image as DCMTKImageQueryNode in childrenArray {
                            guard let objectUID = image.uid() else {
                                NSLog("****** no image uid !")
                                continue
                            }
                            if localObjectUIDs.contains(objectUID) {
                                downloader.WADOBaseTotal += 1
                            } else if let address = url(study: uid(), series: image.seriesInstanceUID(), object: objectUID) {
                                urlToDownload.append(address)
                            } else {
                                NSLog("****** no url : %@", baseURL + "&studyUID=\(uid() ?? "(null)")&seriesUID=\(image.seriesInstanceUID() ?? "(null)")&objectUID=\(objectUID)&contentType=application/dicom\(syntax)")
                            }
                        }
                    }
                    if let plan { urlToDownload = plan.eligible(urls: plan.order(urls: urlToDownload)) }
                    downloader.WADODownload(urlToDownload)
                    if let manifest = downloader.manifest { recordWADOManifest(manifest) }
                    downloader.WADOBaseTotal += Int32(urlToDownload.count) // For the GUI progress bar
                    countOfSuboperations += UInt(urlToDownload.count)
                    countOfSuccessfulSuboperations += UInt(max(0, downloader.countOfSuccesses))
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            if Thread.current.isCancelled {
                cFindThread.cancel()
                // The discovery worker owns the query until it exits. Do not
                // purge its children or report completion while it is still
                // updating them.
                while !cFindThread.isFinished { Thread.sleep(forTimeInterval: 0.05) }
            }
            plan?.end(endpoint: planEndpoint, study: uid() ?? "")
            retrievePlan = nil
            if let plan, !plan.excludedSeries.isEmpty { currentRetrieveInventory()?.exclude(series: plan.excludedSeries) }
            if !Thread.current.isCancelled { noteExcludedSeries(plan?.excludedSeries ?? [:], everything: plan?.excludesEverything ?? false) }
            purgeChildren()
        }

        if isSeries {
            var childrenArray: [Any] = []
            synchronized {
                // Its images are searched for when they were not.
                if children() == nil { query(withValues: nil) }
                childrenArray = children() ?? []
            }
            var urlToDownload: [URL] = []
            catchingExceptions {
                for case let image as DCMTKQueryNode in childrenArray {
                    guard let objectUID = image.uid() else {
                        NSLog("****** no image uid !")
                        continue
                    }
                    if localObjectUIDs.contains(objectUID) { continue }
                    if let address = url(study: study?.uid(), series: uid(), object: objectUID) {
                        urlToDownload.append(address)
                    } else {
                        NSLog("****** no url : %@", baseURL + "&studyUID=\(study?.uid() ?? "(null)")&seriesUID=\(uid() ?? "(null)")&objectUID=\(objectUID)&contentType=application/dicom\(syntax)")
                    }
                }
            }
            purgeChildren()
            let downloader = wadoDownloader(authorization: authorization)
            downloader.WADODownload(urlToDownload)
            if let manifest = downloader.manifest { recordWADOManifest(manifest) }
            countOfSuboperations = UInt(urlToDownload.count)
            countOfSuccessfulSuboperations = UInt(max(0, downloader.countOfSuccesses))
        }
    }

    @objc(WADORetrieve:)
    func wadoRetrieve(study: DCMTKQueryNode?) {
        wadoRetrieve(study: study, listing: nil)
    }
}
