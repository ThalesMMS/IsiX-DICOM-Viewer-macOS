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

/// The target of Network > Modality Worklist…, an object of MainMenu.xib made
/// with -init and kept, like the nib's other top-level objects, for the life
/// of the process. The item is always enabled: with no worklist node in
/// Settings > Locations the window says where to mark one.
@MainActor @objc(IsiXNetworkWorklistCommands)
final class NetworkWorklistCommands: NSObject {

    /// Network > Modality Worklist…: the window of the scheduled procedure
    /// steps, which asks its nodes as it opens.
    @IBAction @objc(showModalityWorklist:)
    func showModalityWorklist(_ sender: Any?) {
        ModalityWorklistWindowController.show()
    }
}
