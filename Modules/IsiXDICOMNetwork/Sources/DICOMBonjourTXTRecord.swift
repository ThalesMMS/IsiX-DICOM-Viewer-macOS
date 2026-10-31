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
import IsiXPreferences

/// What the DICOM listener announces over Bonjour (`_dicom._tcp`), in the form
/// released Horos and OsiriX instances read. A TXT record holds only text, so
/// switches are "YES" or "NO" and numbers are written out.
public struct DICOMBonjourTXTRecord: Sendable, Equatable {

    /// The service type of a DICOM listener.
    public static let serviceType = "_dicom._tcp."

    /// The sharing name of this computer; announced only when not empty.
    public var serverDescription: String?
    /// The listener's AE title (`AETITLE`); left out when unset.
    public var aeTitle: String?
    /// The identifier of this installation; left out when unset.
    public var uid: String?
    /// Whether the listener answers C-GET.
    public var cget: Bool
    /// The port of the web portal's WADO service while the portal and WADO are
    /// both on; nil otherwise, and nothing about WADO is announced.
    public var wadoPort: Int32?
    /// Whether the portal answers over HTTPS.
    public var wadoUsesHTTPS: Bool
    /// The transfer syntax the listener prefers for what it receives, as the
    /// tag the Listener pane stores (`preferredSyntaxForIncoming`).
    public var preferredSyntax: Int

    public init(serverDescription: String?, aeTitle: String?, uid: String?, cget: Bool, wadoPort: Int32?,
                wadoUsesHTTPS: Bool, preferredSyntax: Int) {
        self.serverDescription = serverDescription
        self.aeTitle = aeTitle
        self.uid = uid
        self.cget = cget
        self.wadoPort = wadoPort
        self.wadoUsesHTTPS = wadoUsesHTTPS
        self.preferredSyntax = preferredSyntax
    }

    /// The record the preferences give, with the sharing name, the identifier
    /// and the web portal's port, which the application works out.
    public init(preferences: any PreferenceStore, serverDescription: String?, uid: String?, webPortalPort: Int) {
        let wado = preferences[NetworkPreferences.webServer] && preferences[NetworkPreferences.wadoServer]
        self.init(serverDescription: serverDescription,
                  aeTitle: preferences[NetworkPreferences.aeTitle],
                  uid: uid,
                  cget: preferences[NetworkPreferences.activateCGETSCP],
                  wadoPort: wado ? Int32(truncatingIfNeeded: webPortalPort) : nil,
                  wadoUsesHTTPS: preferences[WebPortalPreferences.usesSSL],
                  preferredSyntax: preferences[NetworkPreferences.preferredSyntaxForIncoming])
    }

    /// The name a peer reads for the transfer syntax tag `tag`; Explicit
    /// Little Endian for a tag it has no name for.
    public static func syntaxName(_ tag: Int) -> String {
        switch tag {
        case 0: return "LittleEndianImplicit"
        case 21: return "JPEGProcess14SV1TransferSyntax"
        case 26: return "JPEG2000LosslessOnly"
        case 27: return "JPEG2000"
        case 22: return "RLELossless"
        case 23: return "JPEGLSLossless"
        case 24: return "JPEGLSLossy"
        default: return "LittleEndianExplicit"
        }
    }

    /// The TXT record: its keys and their texts.
    public var entries: [String: String] {
        var record = ["CGET": cget ? "YES" : "NO", "preferredSyntax": Self.syntaxName(preferredSyntax)]
        if let serverDescription, !serverDescription.isEmpty {
            record["serverDescription"] = serverDescription
        }
        if let aeTitle {
            record["AETitle"] = aeTitle
        }
        if let uid {
            record["UID"] = uid
        }
        if let wadoPort {
            record["WADO"] = "YES"
            record["WADOPort"] = String(wadoPort)
            record["WADOURL"] = "/wado"
            record["WADOProtocol"] = wadoUsesHTTPS ? "https" : "http"
        }
        return record
    }
}
