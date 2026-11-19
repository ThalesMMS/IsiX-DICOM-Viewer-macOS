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

/// Selectors of the former Horos/OsiriX plug-in SDK on the image view that
/// drew with OpenGL. The view draws with Metal: there is no OpenGL context,
/// texture or display list to give, so each answers a neutral value. Those
/// that take a `float[2][3]` are in DCMView+CAPI.m.
extension DCMView {
    private static let metal = "the image view draws with Metal"

    @objc(FindMinimumOpenGLCapabilities) func legacyFindMinimumOpenGLCapabilities() { FormerSDKFacade.inert("DCMView", "-FindMinimumOpenGLCapabilities", because: Self.metal) }
    @objc(drawRect:withContext:) func legacyDraw(_ rect: NSRect, withContext context: AnyObject?) { FormerSDKFacade.inert("DCMView", "-drawRect:withContext:", because: Self.metal) }
    @objc(drawRectIn:::::::) func legacyDrawRect(in size: NSRect, _ texture: UnsafeMutablePointer<UInt32>?, _ offset: NSPoint, _ tX: Int, _ tY: Int, _ tW: Int, _ tH: Int) { FormerSDKFacade.inert("DCMView", "-drawRectIn:::::::", because: Self.metal) }
    @objc(fontListGL) func legacyFontListGL() -> UInt32 { FormerSDKFacade.inert("DCMView", "-fontListGL", because: Self.metal); return 0 }
    @objc(loadTextureIn:blending:colorBuf:textureX:textureY:redTable:greenTable:blueTable:textureWidth:textureHeight:resampledBaseAddr:resampledBaseAddrSize:)
    func legacyLoadTexture(in texture: UnsafeMutablePointer<UInt32>?, blending: Bool, colorBuf: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, textureX: UnsafeMutablePointer<Int>?, textureY: UnsafeMutablePointer<Int>?, redTable: UnsafeMutablePointer<UInt8>?, greenTable: UnsafeMutablePointer<UInt8>?, blueTable: UnsafeMutablePointer<UInt8>?, textureWidth: UnsafeMutablePointer<Int>?, textureHeight: UnsafeMutablePointer<Int>?, resampledBaseAddr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, resampledBaseAddrSize: UnsafeMutablePointer<Int32>?) -> UnsafeMutablePointer<UInt32>? {
        FormerSDKFacade.inert("DCMView", "-loadTextureIn:blending:colorBuf:…", because: Self.metal)
        return nil
    }
    @objc(makeTextureFromImage:forTexture:buffer:textureUnit:) func legacyMakeTexture(from image: NSImage?, forTexture name: UnsafeMutablePointer<UInt32>?, buffer: UnsafeMutablePointer<UInt8>?, textureUnit: UInt32) { FormerSDKFacade.inert("DCMView", "-makeTextureFromImage:forTexture:buffer:textureUnit:", because: Self.metal) }

    /// The textures were loaded here under the drawing lock. The picture is
    /// uploaded when it is drawn: the view is asked to draw again.
    @objc(loadTexturesCompute) func legacyLoadTexturesCompute() { needsDisplay = true }
}
