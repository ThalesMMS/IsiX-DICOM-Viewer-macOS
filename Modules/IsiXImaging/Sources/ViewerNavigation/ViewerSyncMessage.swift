/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, ?version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ?See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ?If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: ? OsiriX
 ?Copyright (c) OsiriX Team
 ?All rights reserved.
 ?Distributed under GNU - LGPL
 ?
 ?See http://www.osirix-viewer.com/copyright.html for details.
 ? ? This software is distributed WITHOUT ANY WARRANTY; without even
 ? ? the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 ? ? PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation

// The message a 2D view sends the others when it shows another slice or when
// the mouse places the patient crosshair: OsirixSyncNotification, whose user
// info the plugins of the former SDK read. The values are typed here; the
// dictionary of thirteen keys is made only where the notification is posted,
// and read back where it is received, with the three objects only the
// application knows (the view and the two images it sends).

/// The values of a sync message.
public struct ViewerSyncMessage: Sendable, Equatable {

    /// The keys of the notification's user info, as the plugins read them.
    public enum Key {
        public static let view = "view"
        public static let position = "Pos"
        public static let direction = "Direction"
        public static let location = "Location"
        public static let offset = "offsetsync"
        public static let frameOfReferenceUID = "frameofReferenceUID"
        public static let studyInstanceUID = "studyID"
        public static let image = "DCMPix"
        public static let farEndImage = "DCMPix2"
        public static let pointX = "point3DX"
        public static let pointY = "point3DY"
        public static let pointZ = "point3DZ"
        public static let patientCrosshair = "HorosPatientCrosshair"

        /// The thirteen keys, in the order the sender sets them.
        public static let all = [view, position, direction, location, offset, frameOfReferenceUID, studyInstanceUID,
                                 image, farEndImage, pointX, pointY, pointZ, patientCrosshair]
    }

    /// A point in patient coordinates, in millimetres.
    public struct PatientPoint: Sendable, Equatable {
        public var x: Float
        public var y: Float
        public var z: Float

        public init(x: Float, y: Float, z: Float) {
            self.x = x
            self.y = y
            self.z = z
        }
    }

    /// The sender's slice, counted from the end when its series is reversed.
    public var position: Int32
    /// How many slices the sender moved, in its series' own direction; the
    /// patient crosshair sends none.
    public var direction: Int32?
    /// The slice location of the sender's image.
    public var location: Float
    /// The sender's manual sync offset. A message without one is malformed.
    public var offset: Float?
    public var frameOfReferenceUID: String?
    public var studyInstanceUID: String?
    /// The point under the mouse, sent by the patient crosshair.
    public var patientPoint: PatientPoint?
    /// Whether the shared patient crosshair already moved the native viewers,
    /// so the receivers only draw it.
    public var sharesPatientCrosshair: Bool

    public init(position: Int32, direction: Int32?, location: Float, offset: Float?, frameOfReferenceUID: String?,
                studyInstanceUID: String?, patientPoint: PatientPoint? = nil, sharesPatientCrosshair: Bool = false) {
        self.position = position
        self.direction = direction
        self.location = location
        self.offset = offset
        self.frameOfReferenceUID = frameOfReferenceUID
        self.studyInstanceUID = studyInstanceUID
        self.patientPoint = patientPoint
        self.sharesPatientCrosshair = sharesPatientCrosshair
    }

    /// The values of a received message, `entry` answering the object under
    /// a key or nil: a number read as -intValue, -floatValue and -boolValue
    /// read it (0 when it is not one), the offset present whatever its object
    /// is, the point present when its x is.
    public init(entry: (String) -> Any?) {
        func number(_ key: String) -> NSNumber? { entry(key) as? NSNumber }
        self.position = number(Key.position)?.int32Value ?? 0
        self.direction = entry(Key.direction).map { ($0 as? NSNumber)?.int32Value ?? 0 }
        self.location = number(Key.location)?.floatValue ?? 0
        self.offset = entry(Key.offset).map { ($0 as? NSNumber)?.floatValue ?? 0 }
        self.frameOfReferenceUID = entry(Key.frameOfReferenceUID) as? String
        self.studyInstanceUID = entry(Key.studyInstanceUID) as? String
        if entry(Key.pointX) != nil {
            self.patientPoint = PatientPoint(x: number(Key.pointX)?.floatValue ?? 0, y: number(Key.pointY)?.floatValue ?? 0,
                                             z: number(Key.pointZ)?.floatValue ?? 0)
        } else {
            self.patientPoint = nil
        }
        self.sharesPatientCrosshair = number(Key.patientCrosshair)?.boolValue ?? false
    }

    /// The values as the objects the user info carries: numbers and strings,
    /// without the absent ones and without the crosshair flag when it is off.
    public func forEachEntry(_ body: (String, AnyObject) -> Void) {
        body(Key.position, NSNumber(value: position))
        if let direction { body(Key.direction, NSNumber(value: direction)) }
        body(Key.location, NSNumber(value: location))
        if let offset { body(Key.offset, NSNumber(value: offset)) }
        if let frameOfReferenceUID { body(Key.frameOfReferenceUID, frameOfReferenceUID as NSString) }
        if let studyInstanceUID { body(Key.studyInstanceUID, studyInstanceUID as NSString) }
        if let patientPoint {
            body(Key.pointX, NSNumber(value: patientPoint.x))
            body(Key.pointY, NSNumber(value: patientPoint.y))
            body(Key.pointZ, NSNumber(value: patientPoint.z))
        }
        if sharesPatientCrosshair { body(Key.patientCrosshair, NSNumber(value: true)) }
    }

    /// The sender's slice as the message gives it: counted from the end of a
    /// reversed series.
    public static func position(current: Int, count: Int, flippedData: Bool) -> Int32 {
        flippedData ? Int32(truncatingIfNeeded: count - 1 - current) : Int32(truncatingIfNeeded: current)
    }
}
