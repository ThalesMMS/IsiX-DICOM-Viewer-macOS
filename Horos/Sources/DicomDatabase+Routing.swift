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

import AppKit

// DicomDatabase (Routing) keeps the selectors of the former category, which
// <Horos/DicomDatabase+Routing.h> declares and plugins call. The routing
// itself is DatabaseRouting's; the rules, the choice of what each sends and
// the queue are IsiXDICOMNetwork's, and the queue is the process's, not a
// database's.

public extension DicomDatabase {

    /// Starts the drains of the routing queue, once for the process.
    @objc dynamic func initRouting() {
        DatabaseRouting.process.startDrains()
    }

    /// Nothing is the database's to let go: a drain reads the images it sends
    /// from the database again, and says when they have gone.
    @objc dynamic func deallocRouting() {}

    /// Starts a drain of the routing queue, unless one is running.
    @objc dynamic func initiateRoutingUnlessAlreadyRouting() {
        DatabaseRouting.process.drain()
    }

    /// Starts a drain of the routing queue, unless one is running.
    @objc dynamic func routing() {
        DatabaseRouting.process.drain()
    }

    /// Queues images for a rule, without applying its filter.
    @objc(addImages:toSendQueueForRoutingRule:)
    dynamic func addImages(_ images: [Any]!, toSendQueueForRoutingRule routingRule: [AnyHashable: Any]!) {
        DatabaseRouting.process.queue((images ?? []).compactMap { $0 as? DicomImage }, for: routingRule, in: self)
    }

    /// Applies the rules given, or those of the preferences, to images of
    /// this database, on its thread.
    @objc(applyRoutingRules:toImages:)
    dynamic func applyRoutingRules(_ autoroutingRules: [Any]!, toImages images: [Any]!) {
        DatabaseRouting.process.apply(autoroutingRules, to: (images ?? []).compactMap { $0 as? DicomImage }, in: self)
    }
}
