//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit

/// The DICOM nodes Bonjour finds (`_dicom._tcp`) while searchDICOMBonjour is on.
///
/// Discovery is Network.framework (`HorosBonjourBrowser`, one service per
/// name, type and domain whatever the interfaces) and resolution is DNS-SD
/// (`BonjourService`): numeric addresses, IPv4 first. The services found are
/// handed to `DICOMNodeService`, which lists them with the stored nodes; this
/// process's own advertisement is left out by its name. Main actor: the browser
/// and the resolutions run on the main queue.
@MainActor
final class DICOMBonjourDiscovery: NSObject, @MainActor HorosBonjourBrowserDelegate, @MainActor NetServiceDelegate {
    private let browser = HorosBonjourBrowser()
    private unowned let owner: DICOMNodeService

    init(owner: DICOMNodeService) {
        self.owner = owner
        super.init()
        browser.delegate = self
        NSUserDefaultsController.shared.addObserver(self, forKeyPath: "values.searchDICOMBonjour", options: .new, context: nil)
    }

    /// Searches while the preference is on; turning it off leaves the search
    /// running and only stops services from being added, as it always did.
    func update() {
        guard UserDefaults.standard.bool(forKey: "searchDICOMBonjour") else { return }
        NSLog("searchDICOMBonjour - searchForServicesOfType : _dicom._tcp")
        browser.searchForServices(ofType: "_dicom._tcp.", inDomain: "")
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        // The defaults controller tells its observers on the main thread.
        if keyPath == "values.searchDICOMBonjour" { MainActor.assumeIsolated { update() } }
    }

    func horosBonjourBrowserWillSearch(_ browser: HorosBonjourBrowser) {
        NSLog("Start bonjour DICOM search")
        owner.replaceServices(with: [])
    }

    func horosBonjourBrowserDidStopSearch(_ browser: HorosBonjourBrowser) {
        NSLog("Stopped DICOM bonjour search")
        owner.replaceServices(with: [])
    }

    func horosBonjourBrowser(_ browser: HorosBonjourBrowser, didNotSearch error: [String: Any]) {
        NSLog("netServiceBrowser didNotSearch")
    }

    func horosBonjourBrowser(_ browser: HorosBonjourBrowser, didFind service: BonjourService) {
        if let published = owner.publisher?.name, service.name == published { return }
        guard UserDefaults.standard.bool(forKey: "searchDICOMBonjour") else { return }
        owner.addService(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    /// The same peer, on other interfaces or with another TXT record: resolved
    /// again, so that the list gives its current address, port and settings.
    func horosBonjourBrowser(_ browser: HorosBonjourBrowser, didUpdate service: BonjourService) {
        guard owner.contains(service) else { return }
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func horosBonjourBrowser(_ browser: HorosBonjourBrowser, didRemove service: BonjourService) {
        service.stop()
        if owner.removeService(service) {
            DICOMNodeService.postServicesDidChange()
        }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        NSLog("DICOM Bonjour node detected: %@", sender)
        DICOMNodeService.postServicesDidChange()
        sender.stop()
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        NSLog("There was an error while attempting to resolve address for %@", sender.name)
        sender.stop()
    }
}
