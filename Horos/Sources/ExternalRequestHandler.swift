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
import CoreData
import IsiXPreferences

// What arrives from outside the application: horos:// (and osirix://) links,
// files opened from the Finder or another application, and plugins to
// install. AppController keeps -getUrl:withReplyEvent:,
// -application:openFiles: and -installPlugins:, which AppKit and the former
// plugins send, and hands their work here.

/// The interface's methods run on the connection threads by design: each call
/// makes its own connection, and what has to happen on the main thread is sent
/// there. A link's request is handed to the queue of the links with it.
extension XMLRPCInterface: @unchecked Sendable {}

/// A link's XML-RPC call, as the queue of the links runs it.
struct LinkRequest: Sendable {
    let server: XMLRPCInterface?
    let methodName: String
    let parameters: [String: String]

    /// Runs the method, as the XML-RPC server would, and logs its answer: a
    /// link has no caller to answer.
    func run() {
        do {
            let response = try server?.methodCall(methodName, parameters: parameters)
            let code = (response as? [AnyHashable: Any])?["error"].map { "\($0)" } ?? "-"
            NSLog("horos URL %@ answered error %@", methodName as NSString, code as NSString)
        } catch {
            NSLog("horos URL %@ answered error %ld", methodName as NSString, (error as NSError).code)
        }
    }
}

/// The requests from outside the application, on the main actor. The
/// application controller makes it once and keeps it.
@MainActor final class ExternalRequestHandler {

    private unowned let controller: AppController
    private let processGraph: ProcessGraph
    private let preferences: any PreferenceStore

    /// The queue horos:// links run their XML-RPC method on, one at a time.
    private let linkQueue = DispatchQueue(label: "horos.url-request", qos: .userInitiated)

    init(controller: AppController, processGraph: ProcessGraph,
         preferences: any PreferenceStore = PreferencesSource.process.preferences) {
        self.controller = controller
        self.processGraph = processGraph
        self.preferences = preferences
    }

    /// The database window, from the application's nib.
    private var browser: BrowserController? {
        controller.browserWindow?.browser
    }

    // MARK: - Links

    /// A horos:// or osirix:// link. Parsing lives in HorosSchemeURL so a
    /// Chrome 94+ protocol block and a missing StudyInstanceUID are not the
    /// same diagnosis. LaunchServices is not rewritten here; the scheme is
    /// already in Info.plist.
    func open(link: String?) {
        if HorosSchemeURL.consumeDuplicate(link ?? "") {
            NSLog("horos URL ignored duplicate within 1s")
            return
        }

        let parsed = HorosSchemeURL.parse(link ?? "")

        if parsed.layer == "parser" {
            let fallback = link.flatMap { URL(string: $0) }
            if parsed.invocation == nil && fallback?.pathExtension == "xml" {
                BrowserController.asyncWADOXMLDownloadURL(fallback)
                return
            }
            NSLog("horos URL parser (%@): %@", parsed.code as NSString, parsed.message as NSString)
            return
        }

        guard let invocation = parsed.invocation else { return }

        if !preferences[NetworkPreferences.xmlrpcServer] {
            // The request is named, since it is dropped: a link from a RIS
            // otherwise only brings the app to the front.
            let request = RISRequestAlert.describe(method: invocation.methodName, parameters: invocation.parameters)
            NSLog("horos URL not carried out, URL support is off: %@", request as NSString)
            let message = NSLocalizedString("IsiX DICOM Viewer URL scheme [horos:// , osirix://] is currently not activated!\r\rShould I activate it now? Restart is necessary.", comment: "")
                + "\r\r" + RISRequestAlert.notCarriedOut(request)
            let result = HorosAlertPanel.runInformational(title: NSLocalizedString("URL scheme", comment: ""), message: message, defaultButton: NSLocalizedString("No", comment: ""), alternateButton: NSLocalizedString("Activate & Restart", comment: ""), otherButton: nil)

            if result == HorosAlertPanel.alternateResponse {
                preferences.set(true, for: NetworkPreferences.xmlrpcServer)
                processGraph.preferences.synchronize()
                NSApplication.shared.terminate(controller)
            }
            return
        }

        if let methodName = invocation.methodName, !methodName.isEmpty {
            // The methods tell the user about their failures, and the code is
            // logged. They run off the main thread, as the XML-RPC server runs
            // them: DisplayStudy and FindObject with PACS On-Demand query the
            // PACS and wait up to 20 s for the study, which froze the app, the
            // Activity panel and the Dock progress. One queue keeps the links
            // in the order they came.
            let request = LinkRequest(server: controller.xmlrpcServer, methodName: methodName, parameters: invocation.parameters)
            linkQueue.async { request.run() }
            return
        }

        if let imageSpecifier = invocation.imageSpecifier, !imageSpecifier.isEmpty {
            openImage(imageSpecifier)
        }
    }

    /// A link to one image, "SOPClassUID+SOPInstanceUID": found among the
    /// selected study's images, else among every series of its class, and
    /// opened; the reason is told when it is not.
    private func openImage(_ imageSpecifier: String) {
        let components = imageSpecifier.components(separatedBy: "+")
        guard components.count == 2 else { return }
        let sopClassUID = components[0], sopInstanceUID = components[1]
        let searchedUID = DicomImage.sopInstanceUIDEncode(sopInstanceUID)
        var succeeded = false
        browser?.lastStudyNotOpenedReason = nil

        // First, among the images of the selection.
        let selection = NSMutableArray()
        _ = browser?.files(forDatabaseOutlineSelection: selection)
        let context = browser?.database?.managedObjectContext

        N2ManagedObjectContextPerformAndWait(context) {
            if let exception = HorosObjCException.caught({
                let matching = selection.compactMap { $0 as? DicomImage }
                    .filter { ($0.compressedSopInstanceUID as NSData?)?.isEqual(toSopInstanceUID: searchedUID) ?? false }
                if let image = matching.last {
                    // A refusal here used to be recorded as a success: the link
                    // was answered, no viewer appeared, and the second search
                    // below was skipped because of it.
                    succeeded = self.browser?.display(image.series?.study, object: image, command: "Open") ?? false
                }
            }) {
                _N2LogExceptionImpl(exception, true, "-[AppController getUrl:withReplyEvent:]")
            }
        }

        // Then in the entire database.
        if !succeeded {
            let request = NSFetchRequest<NSFetchRequestResult>()
            request.entity = browser?.database?.seriesEntity()
            request.predicate = NSPredicate(format: "seriesSOPClassUID == %@", sopClassUID)

            N2ManagedObjectContextPerformAndWait(context) {
                let wait = WaitRendering(NSLocalizedString("Locating the image in the database...", comment: ""))
                wait?.showWindow(self.controller)
                wait?.setCancel(true)
                wait?.start()

                if let exception = HorosObjCException.caught({
                    // A failed fetch answers no series.
                    let series = ((try? context?.fetch(request)) ?? []).compactMap { $0 as? DicomSeries }
                    var found: DicomImage? = nil
                    search: for one in series {
                        for case let image as DicomImage in (one.images as NSSet?) ?? NSSet() {
                            if (image.compressedSopInstanceUID as NSData?)?.isEqual(toSopInstanceUID: searchedUID) ?? false {
                                found = image
                                break search
                            }
                            if wait?.run() == false { break search }
                        }
                    }
                    if let found {
                        succeeded = self.browser?.display(found.series?.study, object: found, command: "Open") ?? false
                    }
                }) {
                    _N2LogExceptionImpl(exception, true, "-[AppController getUrl:withReplyEvent:]")
                }
                wait?.end()
                wait?.close()
            }
        }

        // Somebody clicked a link and is waiting on a viewer. Saying nothing at
        // all is what made "the viewer never opened" a report with nothing in it.
        if !succeeded {
            var reason = browser?.lastStudyNotOpenedReason
            if (reason ?? "").isEmpty {
                reason = StudyNotOpenedReason.reasonForNoStudy()
            }
            // One line that is complete on its own: nothing matched here, so the
            // browser may never have been asked and may have logged nothing.
            NSLog("%@%@ - the link asked for image %@", StudyNotOpenedReason.logPrefix() as NSString, (reason ?? "(null)") as NSString, sopInstanceUID as NSString)
            _ = HorosAlertPanel.run(title: NSLocalizedString("Open Image", comment: ""), message: reason ?? "", defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }
    }

    // MARK: - Files

    /// Files opened from the Finder or another application: a file a viewer
    /// shows brings that viewer to the front; the others, less the plugins
    /// given with --LoadPlugin, are added to the database.
    func open(files filenames: [Any]) {
        if filenames.count == 1, let first = filenames.first as? String { // for iChat Theatre... (drag & drop a DICOM file on the video chat window)
            for viewer in processGraph.viewerRegistry.displayedViewers {
                for image in (viewer.fileList() as? [Any]) ?? [] {
                    if let shown = (image as? NSObject)?.perform(NSSelectorFromString("path"))?.takeUnretainedValue() as? String, shown == first {
                        viewer.window?.makeKey()
                        return
                    }
                }
            }
        }

        // exclude --LoadPlugin arguments
        let arguments = ProcessInfo.processInfo.arguments
        let loadedPlugins = Set(zip(arguments, arguments.dropFirst()).filter { $0.0 == "--LoadPlugin" }.map(\.1))
        let passed = filenames.filter { path in !((path as? String).map(loadedPlugins.contains) ?? false) }

        browser?.subSelectFilesAndFolders(toAdd: passed)
    }

    // MARK: - Plugins

    /// Plugins to install, after the user agreed: a bundle that cannot be
    /// installed, a former plugin among them, is refused with its reason
    /// before anything is asked or changed.
    func installPlugins(_ paths: [Any]) {
        #if !MACAPPSTORE
        var refusals: [String] = []
        let paths: [String] = paths.compactMap { pathObject in
            guard let path = pathObject as? String else { return nil }
            guard let refusal = PluginManager.pluginInstallRefusal(atPath: path) else { return path }
            refusals.append((path as NSString).lastPathComponent + ": " + refusal)
            return nil
        }
        if !refusals.isEmpty {
            HorosAlertPanel.runCritical(title: NSLocalizedString("Plugins Installation", comment: ""),
                                        message: String(format: NSLocalizedString("The plugin cannot be installed. The existing installation was preserved. %@", comment: ""), refusals.joined(separator: "\n\n") as NSString),
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }
        if paths.isEmpty { return }

        let replacing = NSLocalizedString(" will be replaced by ", comment: "")
        let strVersion = NSLocalizedString(" version ", comment: "")
        var replacingPlugins = ""

        /// -appendString: of the former code: a nil or non-string argument raises, as it did.
        func appendToReplacingPlugins(_ value: Any?) {
            guard let value = value as? String else {
                NSException(name: .invalidArgumentException, reason: "-[__NSCFString appendString:]: nil argument", userInfo: nil).raise()
                return
            }
            replacingPlugins += value
        }

        for path in paths {
            let pluginBundleName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension

            let bundleURL = URL(fileURLWithPath: (path as NSString).resolvingAlias())
            let bundleInfo = CFBundleCopyInfoDictionaryInDirectory(bundleURL as CFURL) as? [String: Any]
            let pluginBundleVersion: Any = bundleInfo?["CFBundleVersion"] ?? bundleInfo?["CFBundleShortVersionString"] ?? ""

            for case let plug as [String: Any] in PluginManager.pluginsList() ?? [] where pluginBundleName == (plug["name"] as? String) {
                appendToReplacingPlugins(plug["name"])
                appendToReplacingPlugins(strVersion)
                appendToReplacingPlugins(plug["version"])
                appendToReplacingPlugins(replacing)
                appendToReplacingPlugins(pluginBundleName)
                appendToReplacingPlugins(strVersion)
                appendToReplacingPlugins(pluginBundleVersion)
                appendToReplacingPlugins(".\n\n")
            }
        }

        let pluginNames = paths.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }.joined(separator: ", ")
        if !replacingPlugins.isEmpty { replacingPlugins = String(replacingPlugins.utf16.dropLast(2)) ?? replacingPlugins }

        let areYouSure = NSLocalizedString("Are you sure you want to install", comment: "")
        var message = paths.count == 1
            ? String(format: NSLocalizedString("%@ the plugin named : %@ ?", comment: ""), areYouSure as NSString, pluginNames as NSString)
            : String(format: NSLocalizedString("%@ the following plugins : %@ ?", comment: ""), areYouSure as NSString, pluginNames as NSString)
        if !replacingPlugins.isEmpty {
            message = message + "\n\n" + replacingPlugins
        }

        let answer = HorosAlertPanel.run(title: NSLocalizedString("Plugins Installation", comment: ""), message: message, defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: NSLocalizedString("Cancel", comment: ""), otherButton: nil)

        if answer != 0 {
            for path in paths {
                PluginManager.installPlugin(fromPath: path)
            }

            controller.installPluginMenus()

            // refresh the plugin manager window (if open)
            for window in NSApp.windows {
                (window.windowController as? PluginManagerController)?.refreshPluginList()
            }
        }
        #endif
    }
}
