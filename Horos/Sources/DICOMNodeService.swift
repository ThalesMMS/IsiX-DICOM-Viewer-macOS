//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit
import Darwin

/// The DICOM node list and DICOM Bonjour discovery behind `DCMNetServiceDelegate` (#737).
///
/// `DCMNetServiceDelegate` stays in DCM.framework under its public name, for the
/// plugins that link it, and forwards here: the nodes stored in SERVERS
/// (normalised, optionally synced from a URL), the `_dicom._tcp` services Bonjour
/// finds when searchDICOMBonjour is on, and the address helpers. Nothing here
/// parses DICOM.
// @unchecked Sendable: DCMNetServiceDelegate forwards to `shared` from the
// threads that list the nodes. The browser and `publisher` are used on the main
// thread, where the Bonjour callbacks arrive; `services`, which the listing
// threads read, is read and written only under `servicesLock`.
@objc(HorosDICOMNodeService)
public final class DICOMNodeService: NSObject, NetServiceBrowserDelegate, NetServiceDelegate, @unchecked Sendable {
    /// retrieveMode values stored with a node (`DCMNetServiceDelegate.h`).
    enum RetrieveMode: Int { case cMove = 0, cGet = 1, wado = 2, dicomWeb = 3 }
    /// TransferSyntax values stored with a node (`SendController.h`).
    enum SendSyntax: Int {
        case explicitLittleEndian = 0, jpeg2000Lossless = 1, jpeg2000Lossy10 = 2, jpegLossless = 5
        case implicitLittleEndian = 9, rle = 10, jpegLSLossless = 13, jpegLSLossy10 = 14
    }

    @objc(sharedService) public static let shared = DICOMNodeService()

    private let browser = NetServiceBrowser()
    private let servicesLock = NSLock()
    private var services: [NetService]?
    /// This process's own advertisement, which is not a node to list. Not retained, as before.
    @objc public weak var publisher: NetService?

    private override init() {
        super.init()
        browser.delegate = self
        NSUserDefaultsController.shared.addObserver(self, forKeyPath: "values.searchDICOMBonjour", options: .new, context: nil)
        update()
    }

    @objc public func update() {
        guard UserDefaults.standard.bool(forKey: "searchDICOMBonjour") else { return }
        NSLog("searchDICOMBonjour - searchForServicesOfType : _dicom._tcp")
        browser.searchForServices(ofType: "_dicom._tcp.", inDomain: "")
    }

    public override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                      change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "values.searchDICOMBonjour" { update() }
    }

    @objc public var dicomServices: [NetService] { servicesLock.withLock { services ?? [] } }

    @objc(portForNetService:) public func port(for service: NetService) -> Int32 {
        var port: Int32 = 0
        _ = DICOMNodeService.hostname(port: &port, for: service)
        return port
    }

    // MARK: Browsing

    public func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        NSLog("Start bonjour DICOM search")
        servicesLock.withLock { services = [] }
    }

    public func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        NSLog("Stopped DICOM bonjour search")
        servicesLock.withLock { services?.removeAll() }
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        NSLog("netServiceBrowser didNotSearch")
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        if service === publisher || service.name == publisher?.name { return }
        guard UserDefaults.standard.bool(forKey: "searchDICOMBonjour") else { return }
        servicesLock.withLock { services?.append(service) }
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        service.stop()
        let removed = servicesLock.withLock { () -> Bool in
            guard let index = services?.firstIndex(where: { $0 === service }) else { return false }
            services?.remove(at: index)
            return true
        }
        if removed {
            NotificationCenter.default.post(name: Notification.Name("DCMNetServicesDidChange"), object: nil)
        }
    }

    public func netServiceDidResolveAddress(_ sender: NetService) {
        NSLog("DICOM Bonjour node detected: %@", sender)
        NotificationCenter.default.post(name: Notification.Name("DCMNetServicesDidChange"), object: nil)
        sender.stop()
    }

    public func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        NSLog("There was an error while attempting to resolve address for %@", sender.name)
        sender.stop()
    }

    // MARK: The node list

    /// Whether SERVERS was given as an argument of the launch (`-SERVERS`).
    /// The argument domain holds it for that launch only, and hides the list
    /// of the preferences: a list written back from it would replace that one
    /// for good (#855).
    static func serversGivenAsArgument(_ defaults: UserDefaults) -> Bool {
        return defaults.volatileDomain(forName: UserDefaults.argumentDomain)["SERVERS"] != nil
    }

    // Publishing normalized defaults invokes KVO synchronously. Observers may
    // list the nodes again; they see the normalized value and do not republish.
    // Keep read/normalize/publish serialized while permitting that reentry.
    private static let listLock = NSRecursiveLock()
    private static let syncing = DispatchSemaphore(value: 1)

    /// Replaces SERVERS with the list at syncDICOMNodesURL. One sync at a time;
    /// a request while one runs is dropped. DICOMweb nodes have a list of their
    /// own (#799), so an entry of the former DICOMweb mode, or one without an
    /// AE title, is not taken into SERVERS.
    static func syncDICOMNodes() {
        guard syncing.wait(timeout: .now()) == .success else { return }
        defer { syncing.signal() }
        guard let text = UserDefaults.standard.string(forKey: "syncDICOMNodesURL"), let url = URL(string: text),
              let nodes = NSArray(contentsOf: url) else { return }
        UserDefaults.standard.set(nodes.filter { isDIMSEServer($0) }, forKey: "SERVERS")
    }

    /// The stored nodes, normalised, with the resolved Bonjour ones added; the
    /// deactivated ones left out, and those that cannot send or be queried left
    /// out when asked. Only DIMSE nodes are listed: an entry without an AE
    /// title, or of the former DICOMweb mode, is never given to the DIMSE code
    /// or to plugins; DICOMweb nodes are `DICOMwebNode`'s (#799).
    @objc(serversListSendOnly:queryRetrieveOnly:)
    public static func serversList(sendOnly send: Bool, queryRetrieveOnly queryRetrieve: Bool) -> NSMutableArray {
        listLock.lock()
        defer { listLock.unlock() }
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "syncDICOMNodes") {
            Thread.detachNewThread { syncDICOMNodes() }
        }
        let servers = NSMutableArray(array: defaults.array(forKey: "SERVERS") ?? [])
        var toBeSaved = false
        for index in 0..<servers.count {
            guard var node = servers[index] as? [String: Any] else { continue }
            var changed = false
            if node["Activated"] == nil {
                node["Activated"] = true
                changed = true
            }
            if node["retrieveMode"] == nil {
                node["retrieveMode"] = boolValue(node["CGET"]) ? RetrieveMode.cGet.rawValue : RetrieveMode.cMove.rawValue
                node["CGET"] = nil
                node["CMOVE"] = nil
                node["WADO"] = nil
                changed = true
            }
            if changed {
                servers[index] = node
                toBeSaved = true
            }
        }
        // A list given as an argument of the launch is normalised here, for
        // this launch, and never written: it would replace the nodes of the
        // preferences for good (#855).
        if toBeSaved && !serversGivenAsArgument(defaults) { defaults.set(servers, forKey: "SERVERS") }

        if defaults.bool(forKey: "searchDICOMBonjour") {
            for service in shared.dicomServices {
                var port: Int32 = 0
                guard let hostname = hostname(port: &port, for: service) else { continue }
                let node = bonjourNode(for: service, hostname: hostname, port: Int(port))
                if !endpointAlreadyConfigured(servers: servers as? [Any] ?? [], hostName: service.hostName,
                                               addresses: service.addresses, port: Int(port)) {
                    servers.add(node)
                }
            }
        }
        servers.filter(using: NSPredicate { node, _ in
            guard let node = node as? [String: Any] else { return true }
            if !isDIMSEServer(node) { return false }
            if node["Activated"] != nil && !boolValue(node["Activated"]) { return false }
            if send && node["Send"] != nil && !boolValue(node["Send"]) { return false }
            if queryRetrieve && node["QR"] != nil && !boolValue(node["QR"]) { return false }
            return true
        })
        return servers
    }

    /// Whether an entry of `SERVERS` is a DIMSE node: one with an AE title,
    /// not of the former DICOMweb mode, whose entries now move to
    /// `DICOMWEB_SERVERS` at launch (#799).
    @objc(isDIMSEServer:)
    public static func isDIMSEServer(_ entry: Any) -> Bool {
        guard let node = entry as? [String: Any] else { return false }
        if node["retrieveMode"] != nil && intValue(node["retrieveMode"]) == RetrieveMode.dicomWeb.rawValue { return false }
        let title = (node["AETitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !title.isEmpty
    }

    static func bonjourNode(for service: NetService, hostname: String, port: Int) -> NSMutableDictionary {
        let txt = service.txtRecordData().map { NetService.dictionary(fromTXTRecord: $0) } ?? [:]
        func text(_ key: String) -> String? { txt[key].flatMap { String(data: $0, encoding: .utf8) } }
        let syntaxes: [String: SendSyntax] = [
            "LittleEndianImplicit": .implicitLittleEndian, "LittleEndianExplicit": .explicitLittleEndian,
            "JPEGProcess14SV1TransferSyntax": .jpegLossless, "JPEG2000LosslessOnly": .jpeg2000Lossless,
            "JPEG2000": .jpeg2000Lossy10, "RLELossless": .rle, "JPEGLSLossy": .jpegLSLossy10, "JPEGLSLossless": .jpegLSLossless,
        ]
        let node = NSMutableDictionary(dictionary: [
            "Address": hostname, "AETitle": service.name, "Port": "\(port)", "QR": true,
            "retrieveMode": (txt["CGET"] != nil ? RetrieveMode.cGet : RetrieveMode.cMove).rawValue, "Send": true,
            "Description": text("serverDescription") ?? "\(service.hostName ?? "") (Bonjour)",
            "TransferSyntax": (text("preferredSyntax").flatMap { syntaxes[$0] } ?? .explicitLittleEndian).rawValue,
            "Activated": 1,
        ])
        // A Horos peer advertises its direct-transfer version and port; a token
        // is never taken from TXT, where anyone could read it.
        if let version = text("HorosDirectTransferVersion").flatMap({ Int($0) }), version > 0 {
            node["HorosDirectTransferVersion"] = version
        }
        if let directPort = text("HorosDirectTransferPort").flatMap({ Int($0) }), directPort > 0 {
            node["HorosDirectTransferPort"] = directPort
        }
        if let icon = text("icon") { node["icon"] = icon }
        return node
    }

    /// The node a Bonjour TXT record describes, before its address is known.
    @objc(nodeInfoFromTXTRecordData:)
    public static func nodeInfo(fromTXTRecordData data: Data) -> NSMutableDictionary {
        let txt = NetService.dictionary(fromTXTRecord: data)
        func text(_ key: String) -> String? { txt[key].flatMap { String(data: $0, encoding: .utf8) } }
        var syntax = SendSyntax.jpeg2000Lossy10
        switch text("preferredSyntax") {
        case "LittleEndianImplicit"?: syntax = .explicitLittleEndian
        case "JPEGProcess14SV1TransferSyntax"?: syntax = .jpegLossless
        case "JPEG2000LosslessOnly"?: syntax = .jpeg2000Lossless
        case "JPEG2000"?: syntax = .jpeg2000Lossy10
        case "RLELossless"?: syntax = .rle
        default: break
        }
        let node = NSMutableDictionary(dictionary: [
            "QR": true, "retrieveMode": (txt["CGET"] != nil ? RetrieveMode.cGet : RetrieveMode.cMove).rawValue,
            "Send": true, "TransferSyntax": syntax.rawValue, "Activated": true,
        ])
        if let description = text("serverDescription") { node["Description"] = description }
        if let icon = text("icon") { node["icon"] = icon }
        return node
    }

    // MARK: Addresses

    /// The IPv4 address of a host name or dotted address; a name is looked up.
    @objc(ipAddressFor:)
    public static func ipAddress(for address: Any?) -> String? {
        guard let address = address as? String, !address.isEmpty else { return nil }
        var value = in_addr()
        if let first = address.unicodeScalars.first, CharacterSet.letters.contains(first) {
            if let entry = gethostbyname(address), entry.pointee.h_length == Int32(MemoryLayout<in_addr>.size),
               let list = entry.pointee.h_addr_list, let first = list[0] {
                memcpy(&value, first, MemoryLayout<in_addr>.size)
            } else {
                value.s_addr = inet_addr(address)
            }
        } else {
            value.s_addr = inet_addr(address)
        }
        var buffer = [CChar](repeating: 0, count: 256)
        guard inet_ntop(AF_INET, &value, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The numeric address and port a resolved service answers at, IPv4 first.
    @objc(hostnameAndPort:forService:)
    public static func hostname(port: UnsafeMutablePointer<Int32>?, for service: NetService) -> String? {
        port?.pointee = 0
        for wantsIPv6 in [false, true] {
            for data in service.addresses ?? [] {
                var candidate = 0
                guard let address = socketAddress(data, port: &candidate), candidate >= 1 else { continue }
                if address.contains(":") != wantsIPv6 { continue }
                port?.pointee = Int32(candidate)
                return address
            }
        }
        return nil
    }

    /// Numeric host (IPv6 with its scope) and port of a sockaddr, never a lookup.
    @objc(socketAddress:port:)
    public static func socketAddress(_ data: Data, port: UnsafeMutablePointer<Int>?) -> String? {
        guard data.count >= MemoryLayout<sockaddr>.size else { return nil }
        var storage = sockaddr_storage()
        _ = withUnsafeMutableBytes(of: &storage) { data.copyBytes(to: $0.bindMemory(to: UInt8.self)) }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        switch Int32(storage.ss_family) {
        case AF_INET where data.count >= MemoryLayout<sockaddr_in>.size:
            return withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { value -> String? in
                    var address = value.pointee.sin_addr
                    guard inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
                    port?.pointee = Int(UInt16(bigEndian: value.pointee.sin_port))
                    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                }
            }
        case AF_INET6 where data.count >= MemoryLayout<sockaddr_in6>.size:
            return withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { value -> String? in
                    var address = value.pointee.sin6_addr
                    guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
                    port?.pointee = Int(UInt16(bigEndian: value.pointee.sin6_port))
                    let host = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    return value.pointee.sin6_scope_id != 0 ? "\(host)%\(value.pointee.sin6_scope_id)" : host
                }
            }
        default:
            return nil
        }
    }

    /// A comparison key for an address as a saved node or a service states it:
    /// numeric IPv4, numeric IPv6 with its scope as an index, or a lower-case
    /// host name. Comparison only; never resolves DNS while the list is built.
    @objc(addressKey:)
    public static func addressKey(_ value: Any?) -> String? {
        guard var address = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if address.hasPrefix("[") && address.hasSuffix("]") { address = String(address.dropFirst().dropLast()) }
        guard !address.isEmpty else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        var ipv4 = in_addr()
        if inet_pton(AF_INET, address, &ipv4) == 1 {
            inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(buffer.count))
            return "v4:" + String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        let parts = address.components(separatedBy: "%")
        var ipv6 = in6_addr()
        if parts.count <= 2 && inet_pton(AF_INET6, parts[0], &ipv6) == 1 {
            var zone = parts.count == 2 ? parts[1] : ""
            if parts.count == 2 && zone.isEmpty { return nil }
            let scope = if_nametoindex(zone)
            if scope != 0 { zone = "\(scope)" }
            if zone == "0" { zone = "" }
            let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
            if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff && zone.isEmpty {
                var mapped = in_addr()
                withUnsafeMutableBytes(of: &mapped) { $0.copyBytes(from: bytes[12..<16]) }
                inet_ntop(AF_INET, &mapped, &buffer, socklen_t(buffer.count))
                return "v4:" + String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
            inet_ntop(AF_INET6, &ipv6, &buffer, socklen_t(buffer.count))
            return "v6:" + String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) + "%" + zone
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._")
        guard address.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        address = address.lowercased()
        while address.hasSuffix(".") { address.removeLast() }
        return address.isEmpty ? nil : "dns:" + address
    }

    /// Whether a saved node already reaches the service's resolved endpoint:
    /// the same port and one of its addresses or its host name. Explicit
    /// settings are kept, and distinct endpoints are never merged.
    @objc(endpointAlreadyConfiguredInServers:hostName:addresses:port:)
    public static func endpointAlreadyConfigured(servers: [Any], hostName: Any?, addresses: [Any]?, port: Int) -> Bool {
        guard (1...65535).contains(port) else { return false }
        var keys = Set<String>()
        if let host = addressKey(hostName) { keys.insert(host) }
        for case let data as Data in addresses ?? [] {
            var candidate = 0
            if let key = addressKey(socketAddress(data, port: &candidate)), candidate == port { keys.insert(key) }
        }
        for case let server as [String: Any] in servers {
            let value = server["Port"]
            guard value is String || value is NSNumber else { continue }
            let scanner = Scanner(string: "\(value!)")
            guard let configured = scanner.scanInt(), scanner.isAtEnd, configured == port else { continue }
            if let key = addressKey(server["Address"]), keys.contains(key) { return true }
        }
        return false
    }

    static func boolValue(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? NSString { return text.boolValue }
        return false
    }

    static func intValue(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? NSString { return text.integerValue }
        return 0
    }
}
