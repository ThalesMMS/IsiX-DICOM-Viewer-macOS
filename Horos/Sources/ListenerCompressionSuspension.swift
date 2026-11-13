//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation
import IsiXPreferences

/// The files imported as they arrive, without compressing or decompressing
/// them (ListenerCompressionSettings read as 0), while retrievals that need
/// their images at once are running, whatever the Listener settings say.
///
/// Each retrieval used to store 0 under the setting and put back afterwards
/// the value it had read. Two at a time (the comparative retrievals run on up
/// to five threads, beside the ones the browser makes when it opens a study)
/// could then read the 0 set by the other and leave it for good, and so did an
/// application that ended during a retrieval. The retrievals hold `shared`
/// instead, counted, on their own threads; the import of the incoming folder,
/// the one reader of the setting, asks it, and the setting is not written.
enum ListenerCompressionSuspension {
    static let shared = ForcedPreference(NetworkPreferences.listenerCompressionSettings, to: 0)
}
