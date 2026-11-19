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
import IsiXDICOMFile

/// What a selector of the plugin SDK of Horos and OsiriX does when the feature
/// behind it is gone from the application (the plugin catalogue, the OpenGL
/// drawing, the stereo views): a plugin built for that SDK is not rebuilt and
/// still sends it, so the method answers, with a neutral value, and says so in
/// the log the first time, instead of raising «unrecognized selector».
enum FormerSDKFacade {
    /// Says once for this process that `selector` of `type` does nothing now.
    nonisolated static func inert(_ type: String, _ selector: String, because reason: String) {
        FormerSDKNotice.inert(type, selector, because: reason)
    }
}

/// The same notice, for the selectors that only Objective-C can declare.
@objc(IsiXFormerSDKFacade) final class FormerSDKFacadeBridge: NSObject {
    /// `selector` as the log writes it, with its sign: «-drawRect:withContext:».
    @objc(inert:selector:because:) nonisolated static func inert(_ type: String, selector: String, because reason: String) {
        FormerSDKNotice.inert(type, selector, because: reason)
    }
}
