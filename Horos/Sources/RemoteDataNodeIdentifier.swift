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

/// -[NSString isEqualToString:] of a string that may be nil (a message to nil
/// answered NO).
fileprivate func dataNodeIsEqual(_ string: String?, _ other: String?) -> Bool {
    guard let string = string, let other = other else { return false }
    return (string as NSString).isEqual(to: other)
}

/// -intValue of an object that may be nil, a string or a number.
fileprivate func dataNodeIntValue(_ object: Any?) -> Int32 {
    if let number = object as? NSNumber { return number.int32Value }
    if let string = object as? NSString { return string.intValue }
    return 0
}

/// The dictionary of a node as the Objective-C object it holds, without a
/// round trip through a Swift dictionary.
fileprivate func dataNodeDictionary(_ node: DataNodeIdentifier) -> NSDictionary? {
    return node.value(forKey: "dictionary") as? NSDictionary
}

/// The icon the node's dictionary names, if there is an image of that name.
fileprivate func dataNodeIcon(_ node: DataNodeIdentifier) -> NSImage? {
    guard let icon = dataNodeDictionary(node)?.value(forKey: "icon") as? String else { return nil }
    return NSImage(named: icon)
}

/// Where a DICOM node answers: its host, port and AE title.
fileprivate struct DicomNodeEndpoint: Equatable {
    let host: String
    let port: Int
    let aet: String
}

/// A host as two nodes should compare it, without asking DNS: a numeric
/// address in its canonical form (an IPv4-mapped IPv6 address as IPv4, without
/// brackets or zone), a name in lower case without its final dot. A name and
/// the address it resolves to stay different.
fileprivate func dicomNodeCanonicalHost(_ host: String) -> String {
    var host = host.trimmingCharacters(in: .whitespacesAndNewlines)
    if host.count >= 2 && host.hasPrefix("[") && host.hasSuffix("]") {
        host = String(host.dropFirst().dropLast())
    }

    var v4 = in_addr()
    if inet_pton(AF_INET, host, &v4) == 1 {
        return dicomNodeAddressString(AF_INET, &v4, INET_ADDRSTRLEN) ?? host
    }

    var numeric = host
    if let zone = numeric.firstIndex(of: "%") {
        numeric = String(numeric[..<zone])
    }
    var v6 = in6_addr()
    if inet_pton(AF_INET6, numeric, &v6) == 1 {
        let bytes = withUnsafeBytes(of: &v6) { Array($0) }
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
            return bytes[12..<16].map { String($0) }.joined(separator: ".")
        }
        return dicomNodeAddressString(AF_INET6, &v6, INET6_ADDRSTRLEN) ?? numeric.lowercased()
    }

    while host.hasSuffix(".") {
        host.removeLast()
    }
    return host.lowercased()
}

fileprivate func dicomNodeAddressString(_ family: Int32, _ address: UnsafeRawPointer, _ length: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(length))
    guard inet_ntop(family, address, &buffer, socklen_t(length)) != nil else { return nil }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// Where a DICOM node answers, as its own location, port and AE title give it.
/// A location in the former "AET@host" form carries the AE title before the
/// "@". No port is the DICOM default, 11112; spaces around the host and the AE
/// title do not count, and a host in brackets loses them. A node without a
/// location (a Bonjour service not yet resolved) has none.
fileprivate func dicomNodeAddress(location: String?, port: UInt, aetitle: String?) -> DicomNodeEndpoint? {
    guard var host = location, !host.isEmpty else { return nil }
    var aet = aetitle ?? ""
    if let at = host.firstIndex(of: "@") {
        aet = String(host[..<at])
        host = String(host[host.index(after: at)...])
    }

    host = host.trimmingCharacters(in: .whitespacesAndNewlines)
    if host.count >= 2 && host.hasPrefix("[") && host.hasSuffix("]") {
        host = String(host.dropFirst().dropLast())
    }
    guard !host.isEmpty else { return nil }

    let number = Int(bitPattern: port)
    return DicomNodeEndpoint(host: host, port: number != 0 ? number : 11112, aet: aet.trimmingCharacters(in: CharacterSet(charactersIn: " ")))
}

/// The endpoint of a DICOM node as two nodes compare it: its address with the
/// host in canonical form, so case, a final dot or the spelling of an IPv6
/// address do not count; its case does for the AE title.
fileprivate func dicomNodeEndpoint(location: String?, port: UInt, aetitle: String?) -> DicomNodeEndpoint? {
    guard let address = dicomNodeAddress(location: location, port: port, aetitle: aetitle) else { return nil }
    let host = dicomNodeCanonicalHost(address.host)
    guard !host.isEmpty else { return nil }
    return DicomNodeEndpoint(host: host, port: address.port, aet: address.aet)
}

fileprivate func dicomNodeEndpoint(_ node: DataNodeIdentifier) -> DicomNodeEndpoint? {
    return dicomNodeEndpoint(location: node.location, port: node.port, aetitle: node.aetitle)
}

// RemoteDataNodeIdentifier, RemoteDatabaseNodeIdentifier and
// DicomNodeIdentifier are implemented in Swift: the Objective-C
// names, the selectors and <Horos/DataNodeIdentifier.h> are those of the
// former classes. DataNodeIdentifier and LocalDatabaseNodeIdentifier stay in
// Objective-C (DataNodeIdentifier.m): BrowserController+Sources.m subclasses
// LocalDatabaseNodeIdentifier. -initWithLocation:… is not seen by Swift, so these
// classes answer it with the Objective-C initializer itself, and the
// dictionary a node is given stays the object it was.

/// A node reached over the network.
@objc(RemoteDataNodeIdentifier)
public class RemoteDataNodeIdentifier: DataNodeIdentifier {
    @objc(location:port:toAddress:port:defaultPort:)
    public class func location(_ location: String!, port: UInt, toAddress address: AutoreleasingUnsafeMutablePointer<NSString?>!, port outputPort: UnsafeMutablePointer<Int>!, defaultPort: Int) -> String! {
        var location = location

        if location == nil {
            DataNodeIdentifierLogStackTrace("---- warning: location == nil")
            location = "0.0.0.0"
        }

        let result = NSString(string: location!)
        if let address = address {
            address.pointee = result
        }

        if let outputPort = outputPort {
            if port != 0 { //IPv4 with port
                outputPort.pointee = Int(bitPattern: port)
            } else {
                outputPort.pointee = defaultPort
            }
        }

        return result as String
    }

    public override func willDisplay(_ cell: PrettyCell!) {
        super.willDisplay(cell)

        // The sources table asks while it draws, on the main thread.
        let icon = dataNodeIcon(self)
        MainActor.assumeIsolated {
            cell?.image = icon ?? NSImage(named: "Network.tif")
        }
    }
}

/// Another Horos, sharing its database.
@objc(RemoteDatabaseNodeIdentifier)
public final class RemoteDatabaseNodeIdentifier: RemoteDataNodeIdentifier {
    @objc(remoteDatabaseNodeIdentifierWithLocation:port:description:dictionary:)
    public class func remoteDatabaseNodeIdentifier(withLocation location: String!, port: UInt, description: String!, dictionary: NSDictionary!) -> Any! {
        return DataNodeIdentifierCreate(self, location, port, "", description, dictionary)
    }

    public override func isEqual(to dni: DataNodeIdentifier!) -> Bool {
        guard let dni = dni as? RemoteDatabaseNodeIdentifier else {
            return false
        }

        var selfHost: Host? = nil
        var selfPort = 0
        _ = Swift.type(of: self).location(self.location, port: self.port, to: &selfHost, port: &selfPort)

        var dniHost: Host? = nil
        var dniPort = 0
        _ = Swift.type(of: self).location(dni.location, port: self.port, to: &dniHost, port: &dniPort)

        if selfHost != nil && dniHost != nil && selfPort == dniPort && dataNodeIsEqual(selfHost?.address, dniHost?.address) {
            return true
        }

        return false
    }

    @objc(location:port:toAddress:port:)
    public class func location(_ location: String!, port: UInt, toAddress address: AutoreleasingUnsafeMutablePointer<NSString?>!, port outputPort: UnsafeMutablePointer<Int>!) -> String! {
        return self.location(location, port: port, toAddress: address, port: outputPort, defaultPort: 8780)
    }

    @objc(location:port:toHost:port:)
    public class func location(_ location: String!, port: UInt, to host: AutoreleasingUnsafeMutablePointer<Host?>!, port outputPort: UnsafeMutablePointer<Int>!) -> Host! {
        let address = self.location(location, port: port, toAddress: nil, port: outputPort)

        var localHost: Host? = nil
        if let address = address {
            localHost = Host.host(withAddressOrName: address as NSString)
        }
        if let host = host {
            if address != nil {
                host.pointee = localHost
            }
            return host.pointee
        }

        return localHost
    }
}

/// A DICOM node.
@objc(DicomNodeIdentifier)
public final class DicomNodeIdentifier: RemoteDataNodeIdentifier {
    @objc(dicomNodeIdentifierWithLocation:port:aetitle:description:dictionary:)
    public class func dicomNodeIdentifier(withLocation location: String!, port: UInt, aetitle: String!, description: String!, dictionary: NSDictionary!) -> Any! {
        return DataNodeIdentifierCreate(self, location, port, aetitle, description, dictionary)
    }

    public override func willDisplay(_ cell: PrettyCell!) {
        super.willDisplay(cell)

        // The sources table asks while it draws, on the main thread.
        let icon = dataNodeIcon(self)
        MainActor.assumeIsolated {
            cell?.image = icon ?? NSImage(named: "DICOMDestination.tif")
        }
    }

    public override func isEqual(to dni: DataNodeIdentifier!) -> Bool {
        guard let dni = dni as? DicomNodeIdentifier else {
            return false
        }

        // Each node answers for its own host, port and AE title, whether they
        // are separate fields (a node entered in the preferences or resolved
        // through Bonjour) or an "AET@host" location, and without a DNS lookup
        // on the main thread. The former code only read the "@" form, so every
        // other node, itself included, compared different, and it read the
        // other node with this one's port.
        if dni === self {
            return true
        }
        guard let mine = dicomNodeEndpoint(self), let theirs = dicomNodeEndpoint(dni) else {
            return false
        }
        return mine == theirs
    }

    /// Coherent with -isEqualToDataNodeIdentifier:, which -isEqual: sends: the
    /// endpoint the nodes compare. A node without one equals only itself; it
    /// shares the hash of DataNodeIdentifier.
    public override var hash: Int {
        guard let endpoint = dicomNodeEndpoint(self) else { return super.hash }
        var hasher = Hasher()
        hasher.combine(endpoint.host)
        hasher.combine(endpoint.port)
        hasher.combine(endpoint.aet)
        return hasher.finalize()
    }

    /// Where to send this node images: its own host, port and AE title, or
    /// those of an "AET@host" location, as a C-STORE needs them. The host is
    /// the one entered or resolved, not the canonical form nodes compare. None
    /// for a node Bonjour has not resolved.
    public func storeDestination() -> (address: String, port: Int, aet: String)? {
        guard let address = dicomNodeAddress(location: self.location, port: self.port, aetitle: self.aetitle) else { return nil }
        return (address.host, address.port, address.aet)
    }

    public override func isEqual(to d: [AnyHashable: Any]!) -> Bool {
        if super.isEqual(to: d) {
            return true
        }

        // A server of the preferences: the same host, port and AE title.
        guard let d, let mine = dicomNodeEndpoint(self),
              let theirs = dicomNodeEndpoint(location: d["Address"] as? String, port: UInt(bitPattern: Int(dataNodeIntValue(d["Port"]))), aetitle: d["AETitle"] as? String) else {
            return false
        }
        return mine == theirs
    }

    @objc(location:port:toAddress:port:aet:)
    public class func location(_ location: String!, port: UInt, toAddress address: AutoreleasingUnsafeMutablePointer<NSString?>!, port outputPort: UnsafeMutablePointer<Int>!, aet: AutoreleasingUnsafeMutablePointer<NSString?>!) -> String! {
        let parts = (location as NSString?)?.components(separatedBy: "@") as NSArray?

        if let aet = aet, (parts?.count ?? 0) > 0 {
            aet.pointee = parts?.object(at: 0) as? NSString
        }

        if let parts = parts, parts.count > 1 {
            return self.location((parts.subarray(with: NSMakeRange(1, parts.count - 1)) as NSArray).componentsJoined(by: "@"), port: port, toAddress: address, port: outputPort, defaultPort: 11112)
        }

        return nil
    }

    @objc(location:port:toHost:port:aet:)
    public class func location(_ location: String!, port: UInt, to host: AutoreleasingUnsafeMutablePointer<Host?>!, port outputPort: UnsafeMutablePointer<Int>!, aet: AutoreleasingUnsafeMutablePointer<NSString?>!) -> Host! {
        let address = self.location(location, port: port, toAddress: nil, port: outputPort, aet: aet)

        var localHost: Host? = nil
        if let address = address {
            localHost = Host.host(withAddressOrName: address as NSString)
        }
        if let host = host {
            if address != nil {
                host.pointee = localHost
            }
            return host.pointee
        }

        return localHost
    }
}
