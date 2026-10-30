/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, �version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. �See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. �If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: � OsiriX
 �Copyright (c) OsiriX Team
 �All rights reserved.
 �Distributed under GNU - LGPL
 �
 �See http://www.osirix-viewer.com/copyright.html for details.
 � � This software is distributed WITHOUT ANY WARRANTY; without even
 � � the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 � � PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation
import Synchronization

/// What every DCMPix reads from the preferences, once and again on request
/// (+checkUserDefaults:), the protected mode in which no image is loaded, and
/// the count of decoded frames. The Objective-C kept these in globals of
/// DCMPix.m; they are read and set from the loading threads as they were.
enum DCMPixSettings {
    nonisolated(unsafe) static var isRead = false
    nonisolated(unsafe) static var useShutter = false
    nonisolated(unsafe) static var displayDICOMOverlays = true
    nonisolated(unsafe) static var useVOILUT = false
    nonisolated(unsafe) static var suvAcquisitionTimeField: Int32 = 0
    /// The annotation templates by modality, from the preferences; locked by itself.
    nonisolated(unsafe) static var customImageAnnotations: NSMutableDictionary?
    nonisolated(unsafe) static var protectedMode = false

    /// The preferences, read the first time and when `update` asks: reading
    /// the defaults is slow away from the main thread.
    static func read(update: Bool) {
        if update { isRead = false }
        guard !isRead else { return }
        isRead = true

        let defaults = UserDefaults.standard
        useShutter = defaults.bool(forKey: "UseShutter")
        displayDICOMOverlays = defaults.bool(forKey: "DisplayDICOMOverlays")
        useVOILUT = defaults.bool(forKey: "UseVOILUT")
        suvAcquisitionTimeField = Int32(truncatingIfNeeded: defaults.integer(forKey: "SUVAcquisitionTimeField"))

        if customImageAnnotations == nil { customImageAnnotations = NSMutableDictionary() }
        if let templates = customImageAnnotations {
            objc_sync_enter(templates)
            templates.removeAllObjects()
            if let stored = defaults.dictionary(forKey: "CUSTOM_IMAGE_ANNOTATIONS") { templates.addEntries(from: stored) }
            objc_sync_exit(templates)
        }
    }

    /// The threads a computation over an image is split into: the processors, up to 12.
    static var maxProcessors: Int32 { Int32(min(ProcessInfo.processInfo.processorCount, 12)) }

    private static let decoded = Atomic<UInt64>(0)

    /// How many frames this process has decoded, over every DCMPix.
    static var decodedFrames: UInt64 { decoded.load(ordering: .relaxed) }
    static func countDecodedFrame() { decoded.add(1, ordering: .relaxed) }
    static func resetDecodedFrames() { decoded.store(0, ordering: .relaxed) }
}
