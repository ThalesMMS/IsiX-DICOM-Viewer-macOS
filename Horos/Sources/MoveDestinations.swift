//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation
import IsiXDICOMNetwork

/// Where the listener sends what a C-MOVE asks for: the node of Locations (or
/// of Bonjour) whose AE title, or failing that whose name, is the move
/// destination. Asked by the move context of the DCMTK adapter, on the
/// association's thread, when the C-MOVE starts.
@objc(HorosMoveDestinations)
final class MoveDestinations: NSObject {
    @objc(destinationForAETitle:)
    static func destination(forAETitle title: String) -> IsiXDCMTKMoveDestination? {
        let servers = DICOMNodeService.nodes(sendOnly: false, queryRetrieveOnly: false).compactMap { $0 as? NSDictionary }
        guard let index = MoveDestinationRule.index(of: title, aeTitles: servers.map { $0.value(forKey: "AETitle") },
                                                     names: servers.map { $0.value(forKey: "name") }),
              let host = servers[index].object(forKey: "Address") as? String else { return nil }
        let server = servers[index]
        let syntaxes = MoveSubOperationSyntaxes.proposed(withoutJPEG: UserDefaults.standard.bool(forKey: "DontSupportJPEGForCSMove"))
        return IsiXDCMTKMoveDestination(host: host, port: Self.int(server.object(forKey: "Port")), transferSyntaxes: syntaxes)
    }

    /// -intValue of the Port entry, a number or a string.
    private static func int(_ value: Any?) -> Int32 {
        if let number = value as? NSNumber { return number.int32Value }
        if let string = value as? NSString { return string.intValue }
        return 0
    }
}
