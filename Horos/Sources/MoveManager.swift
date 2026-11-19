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
import IsiXDICOMNetwork

/// The moves a manager was given, each kept alive for as long as it is held:
/// the registry of the operations under way knows a node by its identity
/// alone, and the address of a node that was let go could be another node's.
private final class HeldMoves: @unchecked Sendable {
    private let lock = NSLock()
    private var moves: [ObjectIdentifier: AnyObject] = [:]

    func keep(_ move: AnyObject) {
        lock.withLock { moves[ObjectIdentifier(move)] = move }
    }

    /// Lets the move go once the lock is free again: the end of a node may
    /// send the manager a message.
    func release(_ move: AnyObject) {
        let held = lock.withLock { moves.removeValue(forKey: ObjectIdentifier(move)) }
        _ = held
    }
}

/** \brief move manager

 The implementation of MoveManager, declared in MoveManager.h: the class of
 the Horos and OsiriX plugin SDK that knows which query nodes are being
 retrieved. The nodes are those of RetrieveOperationsUnderWay (IsiXDICOMNetwork):
 the shared manager answers with the registry the application's own C-MOVE and
 C-GET operations claim their node in, and a manager made with -init with a
 registry of its own.
 */
@objc @implementation extension MoveManager {
    private static let shared = MoveManager(sharing: DCMTKQueryNode.retrieveOperations)

    /// Set while the manager is made, and never after.
    private final var operations: RetrieveOperationsUnderWay
    private final let held = HeldMoves()

    class func sharedManager() -> Any! {
        shared
    }

    /// An independent manager, as the SDK's -init made.
    override init() {
        operations = RetrieveOperationsUnderWay()
        super.init()
    }

    /// The manager of the operations the application runs.
    @nonobjc private convenience init(sharing operations: RetrieveOperationsUnderWay) {
        self.init()
        self.operations = operations
    }

    func addMove(_ move: Any!) {
        guard let move else { return }
        let node = move as AnyObject
        held.keep(node)
        operations.insert(node)
    }

    func removeMove(_ move: Any!) {
        guard let move else { return }
        let node = move as AnyObject
        operations.remove(node)
        held.release(node)
    }

    func containsMove(_ move: Any!) -> Bool {
        guard let move else { return false }
        return operations.contains(move as AnyObject)
    }
}
