//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Synchronization

/// What an image view presents: its viewport (scale, pan, rotation, flips)
/// and the window it keeps.
public struct ViewPresentation: Sendable, Equatable {
    public var viewport: ViewportState
    public var windowLevel: WindowLevelState

    public init(viewport: ViewportState = ViewportState(), windowLevel: WindowLevelState = WindowLevelState()) {
        self.viewport = viewport
        self.windowLevel = windowLevel
    }
}

/// The presentation of an image view as the main actor last wrote it, behind
/// a lock, for readers on any thread.
///
/// The view's state lives on the main actor; the view publishes it here at
/// each write, so a plugin or an export thread reads the scale, the rotation,
/// the flips or the window without the main actor, and always reads a value
/// the view had (never half of one write).
public final class ViewPresentationSnapshot: Sendable {
    private let state: Mutex<ViewPresentation>

    public init(_ presentation: ViewPresentation = ViewPresentation()) {
        state = Mutex(presentation)
    }

    /// The presentation last published.
    public var presentation: ViewPresentation {
        state.withLock { $0 }
    }

    public func publish(viewport: ViewportState) {
        state.withLock { $0.viewport = viewport }
    }

    public func publish(windowLevel: WindowLevelState) {
        state.withLock { $0.windowLevel = windowLevel }
    }
}
