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

import Foundation

/// A transfer syntax: its UID, its name and how it encodes a dataset.
///
/// DCMTK answers for every syntax it knows (the host's
/// HorosDICOMTransferSyntaxes); the table here is used only where no host
/// provides it. A UID neither knows is an encapsulated, explicit little-endian
/// "Unknown Syntax".
@objc(IsiXDCMTransferSyntax)
public final class DCMTransferSyntax: NSObject, NSCopying {

    @objc public let transferSyntax: String!
    @objc public let name: String!
    @objc public let isEncapsulated: Bool
    @objc public let isLittleEndian: Bool
    @objc public let isExplicit: Bool

    // MARK: The syntaxes the model names

    @objc public static let explicitVRBigEndianUID = "1.2.840.10008.1.2.2"
    @objc public static let explicitVRLittleEndianUID = "1.2.840.10008.1.2.1"
    @objc public static let implicitVRLittleEndianUID = "1.2.840.10008.1.2"

    @objc(ExplicitVRLittleEndianTransferSyntax)
    public class func explicitVRLittleEndianTransferSyntax() -> DCMTransferSyntax { named(explicitVRLittleEndianUID) }
    @objc(ImplicitVRLittleEndianTransferSyntax)
    public class func implicitVRLittleEndianTransferSyntax() -> DCMTransferSyntax { named(implicitVRLittleEndianUID) }
    @objc(ExplicitVRBigEndianTransferSyntax)
    public class func explicitVRBigEndianTransferSyntax() -> DCMTransferSyntax { named(explicitVRBigEndianUID) }
    @objc(JPEG2000LosslessTransferSyntax)
    public class func jpeg2000LosslessTransferSyntax() -> DCMTransferSyntax { named("1.2.840.10008.1.2.4.90") }
    @objc(JPEG2000LossyTransferSyntax)
    public class func jpeg2000LossyTransferSyntax() -> DCMTransferSyntax { named("1.2.840.10008.1.2.4.91") }
    @objc(JPEGBaselineTransferSyntax)
    public class func jpegBaselineTransferSyntax() -> DCMTransferSyntax { named("1.2.840.10008.1.2.4.50") }
    @objc(JPEGExtendedTransferSyntax)
    public class func jpegExtendedTransferSyntax() -> DCMTransferSyntax { named("1.2.840.10008.1.2.4.51") }
    @objc(JPEGLosslessTransferSyntax)
    public class func jpegLosslessTransferSyntax() -> DCMTransferSyntax { named("1.2.840.10008.1.2.4.70") }
    @objc(JPEGLossless14TransferSyntax)
    public class func jpegLossless14TransferSyntax() -> DCMTransferSyntax { named("1.2.840.10008.1.2.4.57") }
    @objc(JPEGLSLosslessTransferSyntax)
    public class func jpeglsLosslessTransferSyntax() -> DCMTransferSyntax { named("1.2.840.10008.1.2.4.80") }
    @objc(JPEGLSLossyTransferSyntax)
    public class func jpeglsLossyTransferSyntax() -> DCMTransferSyntax { named("1.2.840.10008.1.2.4.81") }
    @objc(RLELosslessTransferSyntax)
    public class func rleLosslessTransferSyntax() -> DCMTransferSyntax { named("1.2.840.10008.1.2.5") }
    @objc(MPEG2TransferSyntax)
    public class func mpeg2TransferSyntax() -> DCMTransferSyntax { named("1.2.840.10008.1.2.4.100") }

    private class func named(_ uid: String) -> DCMTransferSyntax {
        // Never nil: the UID is not empty.
        DCMTransferSyntax(ts: uid)!
    }

    // MARK: Making one

    /// Nil for an empty UID.
    @objc(initWithTS:)
    public init?(ts: String?) {
        guard let ts, !ts.isEmpty else { return nil }
        let properties = DCMHost.transferSyntaxProperties(ts) ?? Self.table[ts]
        transferSyntax = ts
        if let properties {
            isEncapsulated = (properties["isEncapsulated"] as? NSNumber)?.boolValue ?? false
            isLittleEndian = (properties["isLittleEndian"] as? NSNumber)?.boolValue ?? false
            isExplicit = (properties["isExplicit"] as? NSNumber)?.boolValue ?? false
            name = properties["Name"] as? String
        } else {
            isEncapsulated = true
            isLittleEndian = true
            isExplicit = true
            name = "Unknown Syntax"
        }
        super.init()
    }

    @objc(initWithTransferSyntax:)
    public convenience init?(transferSyntax ts: DCMTransferSyntax?) {
        self.init(ts: ts?.transferSyntax)
    }

    public func copy(with zone: NSZone? = nil) -> Any {
        DCMTransferSyntax(transferSyntax: self) as Any
    }

    @objc(isEqualToTransferSyntax:)
    public func isEqual(to ts: DCMTransferSyntax?) -> Bool {
        transferSyntax == ts?.transferSyntax
    }

    public override func isEqual(_ object: Any?) -> Bool {
        isEqual(to: object as? DCMTransferSyntax)
    }

    public override var hash: Int { transferSyntax.hash }

    public override var description: String { name ?? "" }

    // MARK: The syntaxes the model knows without DCMTK

    nonisolated(unsafe) private static let table: [String: [String: Any]] = {
        let syntaxes: [(String, String)] = [
            (explicitVRBigEndianUID, "ExplicitVRBigEndian"),
            (explicitVRLittleEndianUID, "ExplicitVRLittleEndian"),
            (implicitVRLittleEndianUID, "ImplicitVRLittleEndian"),
            ("1.2.840.10008.1.2.4.55", "JPEG1012Retired"),
            ("1.2.840.10008.1.2.4.56", "JPEG1113Retired"),
            ("1.2.840.10008.1.2.4.59", "JPEG1618Retired"),
            ("1.2.840.10008.1.2.4.60", "JPEG1719Retired"),
            ("1.2.840.10008.1.2.4.90", "JPEG2000Lossless"),
            ("1.2.840.10008.1.2.4.91", "JPEG2000Lossy"),
            ("1.2.840.10008.1.2.4.61", "JPEG2022Retired"),
            ("1.2.840.10008.1.2.4.62", "JPEG2123Retired"),
            ("1.2.840.10008.1.2.4.63", "JPEG2426Retired"),
            ("1.2.840.10008.1.2.4.64", "JPEG2527Retired"),
            ("1.2.840.10008.1.2.4.66", "JPEG29Retired"),
            ("1.2.840.10008.1.2.4.53", "JPEG68Retired"),
            ("1.2.840.10008.1.2.4.54", "JPEG79Retired"),
            ("1.2.840.10008.1.2.4.50", "JPEGBaseline"),
            ("1.2.840.10008.1.2.4.51", "JPEGExtended"),
            ("1.2.840.10008.1.2.4.52", "JPEGExtended35Retired"),
            ("1.2.840.10008.1.2.4.65", "JPEGLoRetired"),
            ("1.2.840.10008.1.2.4.70", "JPEGLossless"),
            ("1.2.840.10008.1.2.4.57", "JPEGLossless14"),
            ("1.2.840.10008.1.2.4.58", "JPEGLossless15Retired"),
            ("1.2.840.10008.1.2.4.80", "JPEGLSLossless"),
            ("1.2.840.10008.1.2.4.81", "JPEGLSLossy"),
            ("1.2.840.10008.1.2.5", "RLELossless"),
        ]
        var table: [String: [String: Any]] = [:]
        for (uid, name) in syntaxes {
            // Only Explicit VR Big Endian is big endian; the three native
            // syntaxes are not encapsulated, and only Implicit VR is implicit.
            let native = [explicitVRBigEndianUID, explicitVRLittleEndianUID, implicitVRLittleEndianUID].contains(uid)
            table[uid] = ["isEncapsulated": NSNumber(value: !native),
                          "isLittleEndian": NSNumber(value: uid != explicitVRBigEndianUID),
                          "isExplicit": NSNumber(value: uid != implicitVRLittleEndianUID),
                          "TransferSyntax": uid, "Name": name]
        }
        return table
    }()
}
