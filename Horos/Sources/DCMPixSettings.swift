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
import IsiXPreferences
import Synchronization

/// What every DCMPix reads from the preferences, once and again on request
/// (+checkUserDefaults:), the protected mode in which no image is loaded, and
/// the count of decoded frames. The loading threads read them, the main thread
/// reads the preferences again when they change: the preferences are a
/// snapshot replaced whole, the protected mode an atomic flag.
enum DCMPixSettings {
    /// What was read of the preferences, with the annotation templates as the
    /// images look them up.
    struct Reading: @unchecked Sendable {
        // @unchecked: `templates` is an immutable dictionary made once at the
        // read and never changed, which Foundation lets any thread read.
        var settings = ImageLoadingSettings()
        /// The annotation templates by modality, from the preferences.
        var templates: NSDictionary?
        /// False until the preferences are read, and again when +resetUserDefaults asks.
        var isRead = false

        init() {}

        init(preferences store: any PreferenceStore) {
            settings = ImageLoadingSettings(preferences: store)
            // Read, the templates are a dictionary, empty when the preferences have none.
            templates = .init(dictionary: (settings.customImageAnnotations ?? [:]).mapValues(\.object))
            isRead = true
        }
    }

    private static let snapshot = PreferenceSnapshot(Reading())
    private static let protectedModeFlag = Atomic<Bool>(false)

    /// The preferences, read the first time and when `update` asks: reading
    /// the defaults is slow away from the main thread.
    static func read(update: Bool, from source: PreferencesSource = .process) {
        if update { isRead = false }
        guard !isRead else { return }
        snapshot.replace(Reading(preferences: source.preferences))
    }

    /// Whether the preferences were read; set to false, the next read reads them again.
    static var isRead: Bool {
        get { snapshot.read { $0.isRead } }
        set { snapshot.update { $0.isRead = newValue } }
    }

    static var useShutter: Bool { snapshot.read { $0.settings.usesShutter } }
    static var displayDICOMOverlays: Bool { snapshot.read { $0.settings.displaysDICOMOverlays } }
    static var useVOILUT: Bool { snapshot.read { $0.settings.usesVOILUT } }
    static var suvAcquisitionTimeField: Int32 { Int32(truncatingIfNeeded: snapshot.read { $0.settings.suvAcquisitionTimeField }) }
    /// The annotation templates by modality, from the preferences.
    static var customImageAnnotations: NSDictionary? { snapshot.value.templates }

    /// Turns the VOI LUT off, for every image from now on and in the preferences:
    /// what an image whose table is corrupted does.
    static func turnOffVOILUT(in source: PreferencesSource = .process) {
        snapshot.update { $0.settings.usesVOILUT = false }
        source.preferences.set(false, for: ViewerPreferences.useVOILUT)
    }

    /// No image is loaded in the protected mode.
    static var protectedMode: Bool {
        get { protectedModeFlag.load(ordering: .relaxed) }
        set { protectedModeFlag.store(newValue, ordering: .relaxed) }
    }

    /// The threads a computation over an image is split into: the processors, up to 12.
    static var maxProcessors: Int32 { Int32(min(ProcessInfo.processInfo.processorCount, 12)) }

    private static let decoded = Atomic<UInt64>(0)

    /// How many frames this process has decoded, over every DCMPix.
    static var decodedFrames: UInt64 { decoded.load(ordering: .relaxed) }
    static func countDecodedFrame() { decoded.add(1, ordering: .relaxed) }
    static func resetDecodedFrames() { decoded.store(0, ordering: .relaxed) }
}
