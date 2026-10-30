//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit

/// The loading of the images and the life of the window as the loading and post-processing threads see it: the load thread, a cancel request, whether everything is loaded, whether the window is closing, whether the series was post-processed.
final class ViewerLoadingState: @unchecked Sendable {
    /// Retained when replaced, never released by the holder (as the instance variable was).
    @ManuallyRetained var loadingThread: Thread?
    var requestLoadingCancel: Bool = false
    var checkEverythingLoaded: Bool = false
    var windowWillClose: Bool = false
    var postprocessed: Bool = false
}

extension ViewerController {
    nonisolated var horos_loadingThread: Thread? {
        get { loadingState.loadingThread }
        set { loadingState.loadingThread = newValue }
    }
    nonisolated func horos_assignLoading(_ value: Thread?) { loadingState.$loadingThread.assign(value) }
    var horos_requestLoadingCancel: Bool {
        get { loadingState.requestLoadingCancel }
        set { loadingState.requestLoadingCancel = newValue }
    }
    var horos_checkEverythingLoadedFlag: Bool {
        get { loadingState.checkEverythingLoaded }
        set { loadingState.checkEverythingLoaded = newValue }
    }
    nonisolated var horos_windowWillClose: Bool {
        get { loadingState.windowWillClose }
        set { loadingState.windowWillClose = newValue }
    }
    nonisolated var horos_postprocessed: Bool {
        get { loadingState.postprocessed }
        set { loadingState.postprocessed = newValue }
    }
}
