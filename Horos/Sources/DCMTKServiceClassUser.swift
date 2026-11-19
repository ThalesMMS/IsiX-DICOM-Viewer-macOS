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

/** \brief  Base Class for SCU classes such as verifySCU, storeSCU, moveSCU, findSCU

 The implementation of DCMTKServiceClassUser, declared in
 DCMTKServiceClassUser.h: the base class the Horos and OsiriX plugin SDK gave
 the query nodes and the print SCU. It keeps the peer and the abort flag,
 which the query nodes read here; the associations themselves are made by the
 classes that use them, through the DCMTK adapter.
 */
@objc @implementation extension DCMTKServiceClassUser {
    // The instance variables of the SDK, with its names and types: a plugin
    // built for it binds each name when it loads, and its subclass reads and
    // writes them directly, with no message. _port and _abortAssociation are
    // also the properties of those names; the host's name here is another
    // because the property _hostname answers a Swift string.

    /// The peer: the two AE titles, the host and port, the node's other
    /// settings (replaced, never changed in place), and the transfer syntax
    /// and the compression the user was made with.
    final var _callingAET: NSString?, _calledAET: NSString?
    var _port: Int32 = 0
    final var horos__hostname: NSString?
    final var _extraParameters: NSDictionary?
    final var _shouldAbort: Bool = false
    final var _transferSyntax: Int32 = 0
    final var _compression: Float = 0

    // The network settings of the association the SDK's class made itself;
    // _networkTransferSyntax was an E_TransferSyntax and _blockMode a
    // T_DIMSE_BlockingMode of DCMTK, each the size of an int. The classes
    // that make an association have their own: all zero, but the flag.
    final var _verbose: Bool = false, _debug: Bool = false
    /// Set to give up the association in progress: by one thread, the Query
    /// window's Stop for example, and read by the one that waits for the
    /// peer. One byte, read and written whole, as the SDK's BOOL was.
    var _abortAssociation: Bool = false
    final var _maxReceivePDULength: UInt = 0
    final var _repeatCount: Int32 = 0, _cancelAfterNResponses: Int32 = 0
    final var _networkTransferSyntax: Int32 = 0, _blockMode: Int32 = 0
    final var _dimse_timeout: Int32 = 0, _acse_timeout: Int32 = 0

    // The TLS settings of that association: zero and nil.
    final var _secureConnection: Bool = false, _doAuthenticate: Bool = false
    final var _keyFileFormat: Int32 = 0
    final var _cipherSuites: NSArray?
    final var _readSeedFile: UnsafePointer<CChar>?, _writeSeedFile: UnsafePointer<CChar>?
    final var certVerification: TLSCertificateVerificationType = RequirePeerCertificate
    final var _dhparam: UnsafePointer<CChar>?

    // The peer under the names the query nodes read it by.
    final var callingAETitle: String? { _callingAET as String? }
    final var calledAETitle: String? { _calledAET as String? }
    var _hostname: String! { horos__hostname as String? }
    final var givenTransferSyntax: Int32 { _transferSyntax }
    final var givenCompression: Float { _compression }
    final var givenExtraParameters: [AnyHashable: Any]? {
        get { _extraParameters as? [AnyHashable: Any] }
        set { _extraParameters = newValue as NSDictionary? }
    }

    /// A user of no peer, as -init of the SDK's class left it.
    override init() {
        super.init()
    }

    init!(callingAET myAET: String!, calledAET theirAET: String!, hostname: String!, port: Int32, transferSyntax: Int32,
          compression: Float, extraParameters: [AnyHashable: Any]!) {
        _callingAET = myAET as NSString?
        _calledAET = theirAET as NSString?
        horos__hostname = hostname as NSString?
        _port = port
        _transferSyntax = transferSyntax
        _compression = compression
        _extraParameters = extraParameters as NSDictionary?
        super.init()
    }

    func calledAET() -> String! { calledAETitle }
    func callingAET() -> String! { callingAETitle }
    func extraParameters() -> [AnyHashable: Any]! { givenExtraParameters }
}
