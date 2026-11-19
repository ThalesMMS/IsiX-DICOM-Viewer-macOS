/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, Êversion 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ÊSee the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ÊIf not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: Ê OsiriX
 ÊCopyright (c) OsiriX Team
 ÊAll rights reserved.
 ÊDistributed under GNU - LGPL
 Ê
 ÊSee http://www.osirix-viewer.com/copyright.html for details.
 Ê Ê This software is distributed WITHOUT ANY WARRANTY; without even
 Ê Ê the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 Ê Ê PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation

/** \brief The DICOM node list and DICOM Bonjour

 The implementation of DCMNetServiceDelegate, declared in
 DCMNetServiceDelegate.h: the class of the DCM framework a plugin built for
 the Horos or OsiriX SDK asks for the DICOM nodes. The stored nodes, their
 normalisation, the Bonjour search and the address helpers are
 DICOMNodeService's; each message here is answered by it.
 */
@objc @implementation extension DCMNetServiceDelegate {
    private static let shared = DCMNetServiceDelegate()

    // The instance variables of the SDK, which a plugin built for it binds
    // by name when it loads and reads and writes directly.

    /// The browser of the SDK's own search and the services it found. The
    /// search is the application's (DICOMNodeService): both stay nil.
    final var _dicomNetBrowser: NetServiceBrowser?
    final var _dicomServices: NSMutableArray?
    /// What -setPublisher: was given. The SDK kept it without retaining it,
    /// to leave the application's own advertisement out of the services it
    /// found; the application's search does that by itself now, and nothing
    /// here reads it. Not retained, as in the SDK: a plugin stores a service
    /// there with no retain.
    unowned(unsafe) final var publisher: NetService?

    override init() {
        super.init()
    }

    class func sharedNetServiceDelegate() -> Any! {
        shared
    }

    func setPublisher(_ p: NetService!) {
        publisher = p
    }

    func update() {
        DICOMNodeService.shared.update()
    }

    func dicomServices() -> [Any]! {
        DICOMNodeService.shared.dicomServices
    }

    @objc(portForNetService:) func port(for netService: NetService!) -> Int32 {
        guard let netService else { return 0 }
        return DICOMNodeService.shared.port(for: netService)
    }

    @objc(gethostnameAndPort:forService:) class func gethostnameAndPort(_ port: UnsafeMutablePointer<Int32>!, for sender: NetService!) -> String! {
        guard let sender else {
            port?.pointee = 0
            return nil
        }
        return DICOMNodeService.hostname(port: port, for: sender)
    }

    @objc(DICOMServersList) class func dicomServersList() -> [Any]! {
        dicomServersListSendOnly(false, qrOnly: false)
    }

    @objc(DICOMNodeInfoFromTXTRecordData:) class func dicomNodeInfo(fromTXTRecord data: Data!) -> NSMutableDictionary! {
        DICOMNodeService.nodeInfo(fromTXTRecordData: data)
    }

    @objc(DICOMServersListSendOnly:QROnly:) class func dicomServersListSendOnly(_ send: Bool, qrOnly QR: Bool) -> [Any]! {
        DICOMNodeService.serversList(sendOnly: send, queryRetrieveOnly: QR) as? [Any]
    }

    @objc(DICOMServersListSendOnly:QROnly:cached:) class func dicomServersListSendOnly(_ send: Bool, qrOnly QR: Bool, cached: Bool) -> [Any]! {
        dicomServersListSendOnly(send, qrOnly: QR)
    }

    class func getIPAddress(_ address: Any!) -> String! {
        DICOMNodeService.ipAddress(for: address)
    }
}
