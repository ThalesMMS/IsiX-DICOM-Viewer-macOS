//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// What the VTK adapters draw with, as the app gives it to them: the frame a
// 3D view's render window and renderer draw into (the app's Metal presenter),
// and the 2D canvas the crop box is drawn on (the app's ROI canvas). The
// adapters know these objects only by these protocols. Objective-C and C
// types only.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// One frame of a 3D view: surfaces, then the volumes' ray-cast images, then
/// the finished picture to the screen. Rows of pixels and depth count from the
/// bottom, as VTK's window reads them.
@protocol IsiXVTKFramePresenter <NSObject>
/// Starts a frame `width` × `height` pixels on the background colour; NO
/// when there is nothing to draw into.
- (BOOL)beginWithWidth:(NSInteger)width height:(NSInteger)height red:(double)red green:(double)green blue:(double)blue
    NS_SWIFT_NAME(begin(width:height:red:green:blue:));
/// A surface: vertices of `vertexFloats` floats each, triangle indices, and
/// `meshUniformFloats` floats of uniforms.
- (void)drawMeshWithVertices:(NSData *)vertices indices:(NSData *)indices uniforms:(NSData *)uniforms
                     texture:(nullable NSData *)texture textureWidth:(NSInteger)textureWidth
               textureHeight:(NSInteger)textureHeight translucent:(BOOL)translucent cull:(NSInteger)cull
                   wireframe:(BOOL)wireframe
    NS_SWIFT_NAME(drawMesh(vertices:indices:uniforms:texture:textureWidth:textureHeight:translucent:cull:wireframe:));
- (void)drawLinesWithVertices:(NSData *)vertices indices:(NSData *)indices uniforms:(NSData *)uniforms translucent:(BOOL)translucent
    NS_SWIFT_NAME(drawLines(vertices:indices:uniforms:translucent:));
/// Blends the translucent surfaces drawn so far into the frame.
- (void)compositeTranslucent;
/// A ray-cast image, premultiplied RGBA words, drawn over the surfaces.
- (void)drawImageWithPixels:(const void *)pixels memoryWidth:(NSInteger)memoryWidth memoryHeight:(NSInteger)memoryHeight
                  usedWidth:(NSInteger)usedWidth usedHeight:(NSInteger)usedHeight originX:(NSInteger)originX
                    originY:(NSInteger)originY viewportWidth:(NSInteger)viewportWidth viewportHeight:(NSInteger)viewportHeight
                      depth:(double)depth scale:(double)scale
    NS_SWIFT_NAME(drawImage(pixels:memoryWidth:memoryHeight:usedWidth:usedHeight:originX:originY:viewportWidth:viewportHeight:depth:scale:));
/// Ends the frame's drawing.
- (void)finish;
/// Shows the finished frame.
- (void)present;
/// Two-buffer stereo: keeps a copy of this frame in `other`, or swaps the two.
- (BOOL)copyFrameInto:(id<IsiXVTKFramePresenter>)other NS_SWIFT_NAME(copyFrame(into:));
- (void)exchangeFrameWith:(id<IsiXVTKFramePresenter>)other NS_SWIFT_NAME(exchangeFrame(with:));
/// The frame's depth (0 to 1, 1 where nothing drew) and pixels.
- (BOOL)readDepthWithX:(NSInteger)x y:(NSInteger)y width:(NSInteger)width height:(NSInteger)height into:(float *)values
    NS_SWIFT_NAME(readDepth(x:y:width:height:into:));
- (nullable NSData *)readPixelsWithX:(NSInteger)x y:(NSInteger)y width:(NSInteger)width height:(NSInteger)height alpha:(BOOL)alpha
    NS_SWIFT_NAME(readPixels(x:y:width:height:alpha:));
- (BOOL)writePixels:(NSData *)data x:(NSInteger)x y:(NSInteger)y width:(NSInteger)width height:(NSInteger)height alpha:(BOOL)alpha
    NS_SWIFT_NAME(writePixels(_:x:y:width:height:alpha:));
@end

/// The 2D canvas of a view's overlay, in display pixels from the bottom left,
/// with the modes and capabilities numbered as OpenGL numbered them.
@protocol IsiXVTKLineCanvas <NSObject>
- (void)begin:(uint32_t)mode NS_SWIFT_NAME(begin(_:));
- (void)end;
- (void)vertexX:(CGFloat)x y:(CGFloat)y NS_SWIFT_NAME(vertex(x:y:));
- (void)colorR:(CGFloat)r g:(CGFloat)g b:(CGFloat)b a:(CGFloat)a NS_SWIFT_NAME(color(r:g:b:a:));
- (void)lineWidth:(CGFloat)width NS_SWIFT_NAME(lineWidth(_:));
- (void)pointSize:(CGFloat)size NS_SWIFT_NAME(pointSize(_:));
- (void)enable:(uint32_t)capability NS_SWIFT_NAME(enable(_:));
- (void)disable:(uint32_t)capability NS_SWIFT_NAME(disable(_:));
- (void)blendSource:(uint32_t)source destination:(uint32_t)destination NS_SWIFT_NAME(blend(source:destination:));
@end

NS_ASSUME_NONNULL_END
