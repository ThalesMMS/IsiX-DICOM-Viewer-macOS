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

// Selectors of the plugin SDK of Horos and OsiriX that drew with OpenGL in
// views that draw with Metal now, or kept an OpenGL texture: a plugin built
// for that SDK may still send them. They answer with nothing drawn and no
// texture. The conversion of a point of the navigator is still made.
extension ROI {
    @objc(deleteTexture:) func legacyDeleteTexture(_ context: AnyObject?) {
        FormerSDKFacade.inert("ROI", "-deleteTexture:", because: "a ROI keeps no OpenGL texture")
    }

    @objc(loadLayerImageTexture) func legacyLoadLayerImageTexture() -> GLuint {
        FormerSDKFacade.inert("ROI", "-loadLayerImageTexture", because: "a ROI keeps no OpenGL texture")
        return 0
    }
}

extension OSIROI {
    @objc(drawSlab:inCGLContext:pixelFormat:dicomToPixTransform:)
    func legacyDrawSlab(_ slab: OSISlab, inCGLContext context: UnsafeMutablePointer<_CGLContextObject>?, pixelFormat: CGLPixelFormatObj?,
                        dicomToPixTransform: N3AffineTransform) {
        FormerSDKFacade.inert("OSIROI", "-drawSlab:inCGLContext:pixelFormat:dicomToPixTransform:", because: "ROIs are not drawn with OpenGL")
    }
}

extension NavigatorView {
    /// A point of the window in the pixels of what the view shows, counted
    /// from the top of the visible part.
    @objc(convertPointFromWindowToOpenGL:) func legacyConvertPointFromWindowToOpenGL(_ pointInWindow: NSPoint) -> NSPoint {
        var point = convert(pointInWindow, from: nil)
        let visible = enclosingScrollView?.contentView.documentVisibleRect ?? .zero
        point.x -= visible.origin.x
        point.y = visible.size.height - (point.y - visible.origin.y)
        return convertToBacking(point)
    }

    @objc(generateTextureForSlice:movieIndex:arrayIndex:)
    func legacyGenerateTexture(forSlice z: Int32, movieIndex t: Int32, arrayIndex i: Int32) -> GLuint {
        FormerSDKFacade.inert("NavigatorView", "-generateTextureForSlice:movieIndex:arrayIndex:", because: "the navigator keeps no OpenGL texture")
        return 0
    }
}

extension Window3DController {
    @objc(enableFullScreen) func legacyEnableFullScreen() {
        FormerSDKFacade.inert("Window3DController", "-enableFullScreen", because: "the 3D windows use the system's full screen")
    }

    @objc(disableFullScreen) func legacyDisableFullScreen() {
        FormerSDKFacade.inert("Window3DController", "-disableFullScreen", because: "the 3D windows use the system's full screen")
    }
}

extension WebPortalConnection {
    /// The socket of the former HTTP server. The portal's connections are not AsyncSocket's: there is none to hand out.
    @objc(asyncSocket) nonisolated func legacyAsyncSocket() -> AnyObject? { nil }
}
