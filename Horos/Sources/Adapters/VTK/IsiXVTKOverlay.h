//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The 2D layer of a 3D view without VTK drawing it: the text actors and the
// other 2D actors stay VTK objects that hold what to show; around each render
// of the view's renderer they are hidden from VTK and handed to the view,
// which draws them over the volume. Objective-C and C types only.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Made by +observerOfRenderer:draw:error: (IsiXVTKOverlay.hpp). Observes until it is
/// invalidated or released; the actors it hid are shown again either way.
@interface IsiXVTKOverlayObserver : NSObject
- (instancetype)init NS_UNAVAILABLE;
/// Stops observing the renderer.
- (void)invalidate;
@end

NS_ASSUME_NONNULL_END
