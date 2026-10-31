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
import IsiXDatabase

/// The validation before importing. The Decompress service loads each file as
/// the viewer would; a file that cannot be read is refused, and only that file:
/// IsiXImportValidation tests a chunk again file by file when the service ended
/// without naming one.
enum ImportFileValidation {
    /// The files of `files` that cannot be read. On the main thread it shows a
    /// splash the user can cancel.
    static func refusedFiles(_ files: [Any]) -> [String] {
        guard let service = DecompressService.shared, !files.isEmpty else { return [] }

        var splash: WaitRendering? = nil
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                let shown = WaitRendering(NSLocalizedString("Validating files...", comment: ""))
                shown?.showWindow(nil)
                shown?.setCancel(true)
                shown?.start()
                splash = shown
            }
        }
        let shown = splash.map { UncheckedSendable($0) }

        var refused: [String] = []
        if let exception = HorosObjCException.caught({
            refused = ImportValidation.refusedFiles(files.map { "\($0)" }, tester: service,
                shouldStop: { shown.map { s in MainActor.assumeIsolated { s.value.aborted() } } ?? false },
                whileWaiting: { if let shown { MainActor.assumeIsolated { _ = shown.value.run() } } })
        }) {
            NSLog("***** testList exception : %@", exception)
        }
        if let shown {
            MainActor.assumeIsolated {
                shown.value.end()
                shown.value.close()
            }
        }

        if !refused.isEmpty {
            NSLog("******* test Files: %lu of %lu files cannot be read and are refused: %@",
                  refused.count, files.count, refused.joined(separator: ", "))
        }
        return refused
    }
}

/// A main-thread object carried through closures the validation calls on
/// the main thread only (the splash exists only when it runs there).
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
