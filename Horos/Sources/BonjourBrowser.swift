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

/** \brief  Searches and retrieves Bonjour shared databases */
@objc(BonjourBrowser)
public final class BonjourBrowser: NSObject, NetServiceDelegate, NetServiceBrowserDelegate {
    private let browser: NetServiceBrowser
    private let _services: NSMutableArray
    // Not retained, as the Objective-C ivar was not.
    private weak var interfaceOsiriX: BrowserController?

    // The browser the last -initWithBrowserController: made. Not retained, as the
    // Objective-C static was not; weak, so it never answers a freed object.
    // nonisolated(unsafe): only -initWithBrowserController: writes it, when the
    // browser window builds its browser on the main thread, and the Swift
    // runtime loads and stores a weak reference atomically.
    nonisolated(unsafe) private static weak var _currentBrowser: BonjourBrowser?

    @objc(currentBrowser)
    public class func currentBrowser() -> BonjourBrowser? {
        return _currentBrowser
    }

    @objc(initWithBrowserController:)
    public init(browserController bC: BrowserController?) {
        browser = NetServiceBrowser()
        _services = NSMutableArray()

        super.init()

        Self._currentBrowser = self

        buildFixedIPList()
        buildLocalPathsList()
        buildDICOMDestinationsList()
        arrangeServices()

        interfaceOsiriX = bC

        //[browser setDelegate:self];

        //if ([[NSUserDefaults standardUserDefaults] boolForKey:@"DoNotSearchForBonjourServices"] == NO)
        //	[browser searchForServicesOfType:@"_osirixdb._tcp." inDomain:@""];

        //		[browser scheduleInRunLoop: [NSRunLoop currentRunLoop] forMode: NSDefaultRunLoopMode];

        NSUserDefaultsController.shared.addObserver(self, forValuesKey: "SERVERS", options: .initial, context: nil)

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(updateFixedList(_:)),
                                               name: NSNotification.Name("DCMNetServicesDidChange"),
                                               object: nil)
    }

    public override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if (object as AnyObject?) === NSUserDefaultsController.shared {
            if let keyPath, (keyPath as NSString).isEqual(to: "values.SERVERS") {
                updateFixedList(nil)
            }
        }
    }

    deinit {
        NSUserDefaultsController.shared.removeObserver(self, forValuesKey: "SERVERS")

        NotificationCenter.default.removeObserver(self)
    }

    @objc public func services() -> NSMutableArray {
        return _services
    }

    @objc(showErrorMessage:)
    public func showErrorMessage(_ s: String) {
        if UserDefaults.standard.bool(forKey: "hideListenerError") == false {
            onMainActorSync {
                let alert = NSAlert()
                alert.messageText = NSLocalizedString("Network Error", comment: "")
                alert.informativeText = s
                alert.runModal()
            }
        } else {
            NSLog("*** Bonjour Browser Error (not displayed - hideListenerError): %@", s)
        }
    }

    @objc public func syncOsiriXDBList() {
        autoreleasepool {
            let value = UserDefaults.standard.value(forKey: "syncOsiriXDBURL") as? String

            if let url = value.flatMap({ NSURL(string: $0) }) {
                if let r = NSArray(contentsOf: url as URL) {
                    UserDefaults.standard.set(r, forKey: "OSIRIXSERVERS")
                }
            }
        }
    }

    /// [[services objectAtIndex: i] valueForKey:@"type"] isEqualToString: type]
    private func service(_ i: Int, isOfType type: String) -> Bool {
        let value = (_services.object(at: i) as? NSObject)?.value(forKey: "type") as? NSString
        return value?.isEqual(to: type) ?? false
    }

    private func removeServices(ofType type: String) {
        var i = 0
        while i < _services.count {
            if service(i, isOfType: type) {
                _services.removeObject(at: i)
                i -= 1
            }
            i += 1
        }
    }

    @objc public func buildFixedIPList() {
        if UserDefaults.standard.bool(forKey: "syncOsiriXDB") {
            Thread.detachNewThreadSelector(#selector(syncOsiriXDBList), toTarget: self, with: nil)
        }

        let osirixServersArray = UserDefaults.standard.array(forKey: "OSIRIXSERVERS") ?? []

        removeServices(ofType: "fixedIP")

        for server in osirixServersArray {
            let dict = NSMutableDictionary(dictionary: server as! NSDictionary)
            dict.setValue("fixedIP", forKey: "type")

            _services.add(dict)
        }
    }

    @objc public func buildDICOMDestinationsList() {
        let dbArray = DCMNetServiceDelegate.dicomServersListSendOnly(true, qrOnly: false) ?? []

        removeServices(ofType: "dicomDestination")

        for server in dbArray {
            let dict = NSMutableDictionary(dictionary: server as! NSDictionary)

            dict.setValue("dicomDestination", forKey: "type")
            _services.add(dict)
        }
    }

    @objc public func buildLocalPathsList() {
        let dbArray = UserDefaults.standard.array(forKey: "localDatabasePaths") ?? []
        let defaultPath = DicomDatabase.baseDirPath(forMode: Int32(truncatingIfNeeded: UserDefaults.standard.integer(forKey: "DEFAULT_DATABASELOCATION")),
                                                    path: UserDefaults.standard.string(forKey: "DEFAULT_DATABASELOCATIONURL"))

        removeServices(ofType: "localPath")

        for entry in dbArray {
            let dict = NSMutableDictionary(dictionary: entry as! NSDictionary)

            let path = dict.value(forKey: "Path") as? NSString
            let isDefault = defaultPath.map { path?.isEqual(to: $0) ?? false } ?? false
            let isDefaultData = defaultPath.map { DatabaseLocation.isDataDirectoryName(($0 as NSString).lastPathComponent) && (path?.isEqual(to: ($0 as NSString).deletingLastPathComponent) ?? false) } ?? false
            if isDefault == false && isDefaultData == false {
                dict.setValue("localPath", forKey: "type")
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
        // Order them, first the localPath, fixedIP, and then bonjour

        let result = NSMutableArray()

        for type in ["localPath", "fixedIP", "bonjour", "dicomDestination"] {
            for i in 0..<_services.count where service(i, isOfType: type) {
                result.add(_services.object(at: i))
            }
        }

        _services.removeAllObjects()
        _services.addObjects(from: result as! [Any])
    }

    //———————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————

    public func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        sender.stop()
    }

    public func netServiceDidResolveAddress(_ sender: NetService) {
        do {
            try HorosObjCException.perform {
                if let addresses = sender.addresses, addresses.count > 0 {
                    var ipAddressString: String?
                    var portString: String?

                    // Iterate through addresses until we find an IPv4 address
                    var address = addresses[0]
                    for candidate in addresses {
                        address = candidate
                        if Self.family(of: address) == sa_family_t(AF_INET) { break }
                    }

                    address.withUnsafeBytes { bytes in
                        guard let socketAddress = bytes.baseAddress, bytes.count >= MemoryLayout<sockaddr>.size else { return }
                        var buffer = [CChar](repeating: 0, count: 256)

                        switch Int32(socketAddress.assumingMemoryBound(to: sockaddr.self).pointee.sa_family) {
                        case AF_INET:
                            var sin = socketAddress.loadUnaligned(as: sockaddr_in.self)
                            if inet_ntop(AF_INET, &sin.sin_addr, &buffer, socklen_t(buffer.count)) != nil {
                                ipAddressString = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                                portString = String(format: "%d", Int32(UInt16(bigEndian: sin.sin_port)))
                            }
                        case AF_INET6:
                            var sin6 = socketAddress.loadUnaligned(as: sockaddr_in6.self)
                            if inet_ntop(AF_INET6, &sin6.sin6_addr, &buffer, socklen_t(buffer.count)) != nil {
                                ipAddressString = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                                portString = String(format: "%d", Int32(UInt16(bigEndian: sin6.sin6_port)))
                            }
                        default:
                            break
                        }
                    }

                    if let ipAddressString, let portString {
                        for serviceDict in self._services {
                            let serviceDict = serviceDict as! NSDictionary
                            if (serviceDict.object(forKey: "service") as AnyObject?) === sender {
                                NSLog("netServiceDidResolveAddress: %@:%@", ipAddressString, portString)

                                serviceDict.setValue(ipAddressString, forKey: "Address")
                                serviceDict.setValue(portString, forKey: "OsiriXPort")
                            }
                        }
                    }
                }

                sender.stop()
            }
        } catch {
            if let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                _N2LogExceptionImpl(exception, false, "-[BonjourBrowser netServiceDidResolveAddress:]")
            }
        }
    }

    private static func family(of address: Data) -> sa_family_t? {
        return address.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress, bytes.count >= MemoryLayout<sockaddr>.size else { return nil }
            return base.assumingMemoryBound(to: sockaddr.self).pointee.sa_family
        }
    }
}
