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
import IsiXPreferences
import os

/// The sources the database window lists besides its own database: other local
/// folders, shared databases entered by address and DICOM destinations.
/// Confined to the main actor, with the browser window that makes and reads it;
/// a preference or a notification that arrives on another thread is handled
/// there. The order of the sources is a rule of IsiXDICOMNetwork.
///
/// Despite the name, it browses for nothing: the shared databases and DICOM
/// nodes that Bonjour finds come to the Sources list through the browser
/// window's own Network.framework browsers (BrowserSourcesHelper).
@MainActor
@objc(BonjourBrowser)
public final class BonjourBrowser: NSObject {
    private let processGraph: ProcessGraph
    private let _services: NSMutableArray
    // Not retained, as the Objective-C ivar was not.
    private weak var interfaceOsiriX: BrowserController?

    /// The browser the last -initWithBrowserController: made. Not retained, as
    /// the Objective-C static was not; weak, so it never answers a freed object.
    private struct Latest: Sendable {
        weak var browser: BonjourBrowser?
    }

    private nonisolated static let latest = OSAllocatedUnfairLock(initialState: Latest())

    @objc(currentBrowser)
    public nonisolated class func currentBrowser() -> BonjourBrowser? {
        return latest.withLock { $0.browser }
    }

    @objc(initWithBrowserController:)
    public convenience init(browserController bC: BrowserController?) {
        self.init(browserController: bC, processGraph: ProcessGraph.process)
    }

    init(browserController bC: BrowserController?, processGraph: ProcessGraph) {
        self.processGraph = processGraph
        _services = NSMutableArray()

        super.init()

        Self.latest.withLock { $0.browser = self }

        buildFixedIPList()
        buildLocalPathsList()
        buildDICOMDestinationsList()
        arrangeServices()

        interfaceOsiriX = bC

        NSUserDefaultsController.shared.addObserver(self, forValuesKey: NetworkPreferences.dicomNodes.name, options: .initial, context: nil)

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(servicesDidChange(_:)),
                                               name: NSNotification.Name("DCMNetServicesDidChange"),
                                               object: nil)
    }

    // The shared user defaults controller reports a preference on the thread
    // that wrote it: the list is rebuilt on the main actor.
    public nonisolated override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if object is NSUserDefaultsController {
            if keyPath == NetworkPreferences.controllerKeyPath(NetworkPreferences.dicomNodes) {
                onMainActor { self.updateFixedList(nil) }
            }
        }
    }

    // Posted by whoever changed the DICOM nodes, on its own thread.
    @objc private nonisolated func servicesDidChange(_ note: Notification) {
        onMainActor { self.updateFixedList(nil) }
    }

    isolated deinit {
        NSUserDefaultsController.shared.removeObserver(self, forValuesKey: NetworkPreferences.dicomNodes.name)

        NotificationCenter.default.removeObserver(self)
    }

    @objc public func services() -> NSMutableArray {
        return _services
    }

    @objc(showErrorMessage:)
    public nonisolated func showErrorMessage(_ s: String) {
        if processGraph.preferences[NetworkPreferences.hidesListenerErrors] == false {
            // From the main run loop: the main queue goes on while it is open.
            onMainRunLoopSync {
                let alert = NSAlert()
                alert.messageText = NSLocalizedString("Network Error", comment: "")
                alert.informativeText = s
                alert.runModal()
            }
        } else {
            // The text is whatever the caller was told, which the log is not.
            NSLog("*** Bonjour Browser Error (not displayed - hideListenerError): %@", LogText.notice(title: "Network Error", text: s))
        }
    }

    /// Replaces the shared databases entered by address with the list the
    /// `syncOsiriXDBURL` preference points to, and returns once it is read.
    @objc public nonisolated func syncOsiriXDBList() {
        autoreleasepool {
            guard let url = Self.serverListURL(processGraph.preferences) else { return }
            Self.storeServerList(try? Data(contentsOf: url), in: processGraph.preferences)
        }
    }

    /// The same, without holding a thread while the list downloads.
    private nonisolated static func syncServerList(_ processGraph: ProcessGraph) async {
        guard let url = serverListURL(processGraph.preferences),
              let response = try? await URLSession.shared.data(from: url) else { return }
        storeServerList(response.0, in: processGraph.preferences)
    }

    private nonisolated static func serverListURL(_ preferences: UserDefaults) -> URL? {
        // Text only, as `object(forKey:) as? String` took it.
        preferences[NetworkPreferences.syncOsiriXDBURL.reading(as: PropertyListValue?.self)]?.stringValue.flatMap { NSURL(string: $0) as URL? }
            .flatMap { RemoteConfigurationURL.isAcceptable($0) ? $0 : nil }
    }

    /// A property list whose root is a list, as -[NSArray initWithContentsOfURL:] read it.
    private nonisolated static func storeServerList(_ data: Data?, in preferences: UserDefaults) {
        guard let data,
              let list = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [Any] else { return }
        preferences.set(list.compactMap(PropertyListValue.init), for: NetworkPreferences.osirixServers)
    }

    /// The `type` of an entry of the list.
    private static func type(of entry: Any) -> String? {
        (entry as? NSDictionary)?.object(forKey: "type") as? String
    }

    private func removeServices(ofType type: String) {
        let kept = _services.filter { Self.type(of: $0) != type }
        _services.setArray(kept)
    }

    @objc public func buildFixedIPList() {
        let preferences = processGraph.preferences
        if preferences[NetworkPreferences.syncsOsiriXDB] {
            let processGraph = processGraph
            Task.detached(priority: .utility) { await Self.syncServerList(processGraph) }
        }

        let osirixServersArray = preferences[NetworkPreferences.osirixServers]?.map(\.object) ?? []

        removeServices(ofType: DatabaseSourceKind.fixedIP.rawValue)

        for case let server as [String: Any] in osirixServersArray {
            let dict = NSMutableDictionary(dictionary: server)
            dict["type"] = DatabaseSourceKind.fixedIP.rawValue

            _services.add(dict)
        }
    }

    @objc public func buildDICOMDestinationsList() {
        let nodes = DICOMNodeService.dicomNodes(sendOnly: true, queryRetrieveOnly: false)

        removeServices(ofType: DatabaseSourceKind.dicomDestination.rawValue)

        for node in nodes {
            let dict = NSMutableDictionary(dictionary: node.propertyList)

            dict["type"] = DatabaseSourceKind.dicomDestination.rawValue
            _services.add(dict)
        }
    }

    @objc public func buildLocalPathsList() {
        let preferences = processGraph.preferences
        let dbArray = preferences[DatabasePreferences.localDatabaseSources.reading(as: [PropertyListValue]?.self)]?.map(\.object) ?? []
        let defaultPath = DicomDatabase.baseDirPath(forMode: Int32(truncatingIfNeeded: preferences[DatabasePreferences.defaultDatabaseLocation]),
                                                    path: preferences[DatabasePreferences.defaultDatabaseLocationURL])

        removeServices(ofType: DatabaseSourceKind.localPath.rawValue)

        for case let entry as [String: Any] in dbArray {
            let path = entry["Path"] as? NSString
            let isDefault = defaultPath.map { path?.isEqual(to: $0) ?? false } ?? false
            let isDefaultData = defaultPath.map { DatabaseLocation.isDataDirectoryName(($0 as NSString).lastPathComponent) && (path?.isEqual(to: ($0 as NSString).deletingLastPathComponent) ?? false) } ?? false
            if isDefault == false && isDefaultData == false {
                let dict = NSMutableDictionary(dictionary: entry)
                dict["type"] = DatabaseSourceKind.localPath.rawValue
                _services.add(dict)
            }
        }
    }

    //———————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————

    @objc(updateFixedList:)
    public func updateFixedList(_ note: Notification?) {
        buildFixedIPList()
        buildLocalPathsList()
        buildDICOMDestinationsList()
        arrangeServices()
    }

    @objc public func arrangeServices() {
        // Order them: the local paths, the fixed addresses, then the DICOM destinations.
        let arranged = DatabaseSourceKind.arranged(Array(_services)) { Self.type(of: $0) }
        _services.setArray(arranged)
    }
}
