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
import IsiXPreferences

/// Where the listener sends what a C-MOVE asks for: the node of Locations (or
/// of Bonjour) whose AE title, or failing that whose name, is the move
/// destination. Asked by the move context of the DCMTK adapter, on the
/// association's thread, when the C-MOVE starts.
@objc(HorosMoveDestinations)
final class MoveDestinations: NSObject {
    @objc(destinationForAETitle:)
    static func destination(forAETitle title: String) -> IsiXDCMTKMoveDestination? {
        let nodes = DICOMNodeService.dicomNodes(sendOnly: false, queryRetrieveOnly: false)
        guard let index = MoveDestinationRule.index(of: title, aeTitles: nodes.map(\.aeTitle),
                                                     names: nodes.map { $0["name"]?.stringValue }),
              let host = nodes[index].address else { return nil }
        let syntaxes = MoveSubOperationSyntaxes.proposed(withoutJPEG: PreferencesSource.process.preferences[NetworkPreferences.moveWithoutJPEG])
        return IsiXDCMTKMoveDestination(host: host, port: Int32(truncatingIfNeeded: nodes[index].port), transferSyntaxes: syntaxes)
    }
}
