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

import Cocoa

/// CPRTransverseViewNoneSectionType of CPRTransverseView.h, which Swift cannot
/// import: that header reaches VRController.h, which is C++.
private let CPRTransverseViewNoneSectionType = -1

// this class is used to separate display only related data from the real data in an MVC sense

/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/CPRDisplayInfo.h> are those of the former class.
@objc(CPRDisplayInfo)
public final class CPRDisplayInfo: NSObject, NSCopying {
    private var _draggedPositionHidden = true
    private var _hoverNodeHidden = true
    private var _mouseCursorHidden = true

    @objc public dynamic var draggedPositionHidden: Bool {
        @objc(isDraggedPositionHidden) get { return _draggedPositionHidden }
        set { _draggedPositionHidden = newValue }
    }
    @objc public dynamic var draggedPosition: CGFloat = 0 // as a relative position [0, 1]
    @objc public dynamic var hoverNodeHidden: Bool {
        @objc(isHoverNodeHidden) get { return _hoverNodeHidden }
        set { _hoverNodeHidden = newValue }
    }
    @objc public dynamic var hoverNodeIndex: Int = 0 // the node over which the mouse is currently hovering. This node should be drawn differently
    @objc public dynamic var mouseCursorHidden: Bool {
        @objc(isMouseCursorHidden) get { return _mouseCursorHidden }
        set { _mouseCursorHidden = newValue }
    }
    @objc public dynamic var mouseCursorPosition: CGFloat = 0
    /// A CPRTransverseViewSection (NSInteger).
    @objc public dynamic var mouseTransverseSection: Int = CPRTransverseViewNoneSectionType
    @objc public dynamic var mouseTransverseSectionDistance: CGFloat = 0

    // to handle tracking the mouse on intersections of the plane and the CPR
    @objc private(set) var planeIntersectionMouseCoordinates: NSMutableDictionary

    @objc public override init() {
        planeIntersectionMouseCoordinates = NSMutableDictionary()
        super.init()
    }

    private init(displayInfo: CPRDisplayInfo) {
        _draggedPositionHidden = displayInfo.draggedPositionHidden
        draggedPosition = displayInfo.draggedPosition
        _hoverNodeHidden = displayInfo.hoverNodeHidden
        hoverNodeIndex = displayInfo.hoverNodeIndex
        _mouseCursorHidden = displayInfo.mouseCursorHidden
        mouseCursorPosition = displayInfo.mouseCursorPosition
        mouseTransverseSection = displayInfo.mouseTransverseSection
        mouseTransverseSectionDistance = displayInfo.mouseTransverseSectionDistance
        planeIntersectionMouseCoordinates = displayInfo.planeIntersectionMouseCoordinates.mutableCopy() as! NSMutableDictionary
        super.init()
    }

    public func copy(with zone: NSZone? = nil) -> Any {
        return CPRDisplayInfo(displayInfo: self)
    }

    @objc(setMouseVector:forPlane:)
    public func setMouseVector(_ vector: N3Vector, forPlane planeName: String) {
        planeIntersectionMouseCoordinates.setObject(NSValue(n3Vector: vector)!, forKey: planeName as NSString)
    }

    @objc(clearMouseVectorForPlaneName:)
    public func clearMouseVector(forPlaneName planeName: String) {
        planeIntersectionMouseCoordinates.removeObject(forKey: planeName)
    }

    @objc public func clearAllMouseVectors() {
        planeIntersectionMouseCoordinates.removeAllObjects()
    }

    @objc public func planesWithMouseVectors() -> [Any] {
        return planeIntersectionMouseCoordinates.allKeys
    }

    @objc(mouseVectorForPlane:)
    public func mouseVector(forPlane planeName: String) -> N3Vector {
        return (planeIntersectionMouseCoordinates.object(forKey: planeName) as? NSValue)?.n3VectorValue() ?? N3Vector()
    }
}
