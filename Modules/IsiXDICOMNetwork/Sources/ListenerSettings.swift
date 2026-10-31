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

/// The listener's preferences that the catalog of IsiXPreferences does not
/// declare. Their names are those the Listener pane binds and the former
/// application stored.
public enum ListenerPreferences {
    /// The TLS listener: on or off, its AE title and its port.
    public static let tlsListener = PreferenceKey<Bool>("STORESCPTLS")
    public static let tlsAETitle = PreferenceKey<String?>("TLSStoreSCPAETITLE")
    public static let tlsPort = PreferenceKey<String?>("TLSStoreSCPAEPORT")
    /// The listener answers to this computer's host name rather than to AETITLE.
    public static let usesHostNameForAETitle = PreferenceKey<Bool>("UseHostNameForAETitle")
    /// The Diffie-Hellman parameters of the TLS listener: whether a file gives
    /// them, and its path.
    public static let tlsUsesDHParameterFile = PreferenceKey<Bool>("TLSStoreSCPUseDHParameterFileURL")
    public static let tlsDHParameterFile = PreferenceKey<String?>("TLSStoreSCPDHParameterFileURL")
    /// hideListenerError as the user had it, kept while an abort of the
    /// incoming transfers hides the listener's errors: a launch that finds it
    /// puts it back.
    public static let savedHidesListenerErrors = PreferenceKey<Bool>("copyHideListenerError")
}

/// What the DICOM listeners are started from, read from the preferences at
/// once: the plain and the TLS listener, their titles, ports and timeouts, the
/// services they offer and the Bonjour advertisement that goes with them.
///
/// Each value is read as the listener reads it, so the number the defaults
/// registered as text ("0") and the same number a control stored (0) are one
/// value. Two readings are equal when the listeners would start the same from
/// them; the plain listener's AE title is compared as the listener uses it,
/// cut at 16 characters, and not at all while the listener takes the host's
/// name: neither is a change of the user's.
public struct ListenerSettings: Sendable, Equatable {
    public var storeSCP: Bool
    public var usesStoreSCP: Bool
    public var tlsListener: Bool
    /// The plain listener's title as stored, and the port it listens on.
    public var aeTitle: String?
    public var port: Int32
    public var storeSCPExtra: String?
    public var transferSyntax: String?
    public var timeout: Int
    public var connectionTimeout: Int
    public var usesHostNameForAETitle: Bool
    public var preferredSyntaxForIncoming: Int
    public var cgetSCP: Bool
    public var cfindSCP: Bool
    public var publishesBonjour: Bool
    /// The TLS listener's title as stored, and the port it listens on.
    public var tlsAETitle: String?
    public var tlsPort: Int32
    /// The TLS listener's verification of its peers, as text: the pane stores
    /// a number, the defaults may hold its text.
    public var tlsCertificateVerification: String?
    public var tlsCipherSuites: [PropertyListValue]?
    public var tlsUsesDHParameterFile: Bool
    public var tlsDHParameterFile: String?

    public init(preferences: any PreferenceStore) {
        storeSCP = preferences[NetworkPreferences.storeSCP]
        usesStoreSCP = preferences[NetworkPreferences.usesStoreSCP]
        tlsListener = preferences[ListenerPreferences.tlsListener]
        aeTitle = preferences[NetworkPreferences.aeTitle]
        port = Self.listeningPort(preferences[NetworkPreferences.aePort])
        storeSCPExtra = preferences[NetworkPreferences.storeSCPExtra]
        transferSyntax = preferences[NetworkPreferences.aeTransferSyntax]
        timeout = preferences[NetworkPreferences.dicomTimeout]
        connectionTimeout = preferences[NetworkPreferences.dicomConnectionTimeout]
        usesHostNameForAETitle = preferences[ListenerPreferences.usesHostNameForAETitle]
        preferredSyntaxForIncoming = preferences[NetworkPreferences.preferredSyntaxForIncoming]
        cgetSCP = preferences[NetworkPreferences.activateCGETSCP]
        cfindSCP = preferences[NetworkPreferences.activateCFINDSCP]
        publishesBonjour = preferences[NetworkPreferences.publishDICOMBonjour]
        tlsAETitle = preferences[ListenerPreferences.tlsAETitle]
        tlsPort = Self.listeningPort(preferences[ListenerPreferences.tlsPort])
        tlsCertificateVerification = preferences[NetworkPreferences.tlsListenerCertificateVerification]
            .flatMap { String.reading(present: $0.object) }
        tlsCipherSuites = preferences[NetworkPreferences.tlsListenerCipherSuites]
        tlsUsesDHParameterFile = preferences[ListenerPreferences.tlsUsesDHParameterFile]
        tlsDHParameterFile = preferences[ListenerPreferences.tlsDHParameterFile]
    }

    /// The port a listener opens for the stored `text`: its leading integer,
    /// as `intValue` reads it; 0 when there is none.
    public static func listeningPort(_ text: String?) -> Int32 {
        guard let text else { return 0 }
        return (text as NSString).intValue
    }

    /// The plain listener's title as it is compared: none while the listener
    /// takes the host's name, and its first 16 UTF-16 units otherwise, which
    /// is where the listener cuts it.
    public var comparedAETitle: String? {
        if usesHostNameForAETitle { return nil }
        guard let aeTitle, (aeTitle as NSString).length > 16 else { return aeTitle }
        return (aeTitle as NSString).substring(to: 16)
    }

    public static func == (lhs: ListenerSettings, rhs: ListenerSettings) -> Bool {
        lhs.storeSCP == rhs.storeSCP && lhs.usesStoreSCP == rhs.usesStoreSCP && lhs.tlsListener == rhs.tlsListener
            && lhs.comparedAETitle == rhs.comparedAETitle && lhs.port == rhs.port
            && lhs.storeSCPExtra == rhs.storeSCPExtra && lhs.transferSyntax == rhs.transferSyntax
            && lhs.timeout == rhs.timeout && lhs.connectionTimeout == rhs.connectionTimeout
            && lhs.usesHostNameForAETitle == rhs.usesHostNameForAETitle
            && lhs.preferredSyntaxForIncoming == rhs.preferredSyntaxForIncoming
            && lhs.cgetSCP == rhs.cgetSCP && lhs.cfindSCP == rhs.cfindSCP && lhs.publishesBonjour == rhs.publishesBonjour
            && lhs.tlsAETitle == rhs.tlsAETitle && lhs.tlsPort == rhs.tlsPort
            && lhs.tlsCertificateVerification == rhs.tlsCertificateVerification
            && lhs.tlsCipherSuites == rhs.tlsCipherSuites
            && lhs.tlsUsesDHParameterFile == rhs.tlsUsesDHParameterFile && lhs.tlsDHParameterFile == rhs.tlsDHParameterFile
    }
}
