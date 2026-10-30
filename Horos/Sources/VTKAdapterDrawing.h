//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// What the VTK adapter draws with, as the app provides it: the 3D views' Metal
// presenter is the frame the adapter's render window and renderer draw into,
// and the ROI canvas is where the crop box is drawn. The conformances are
// declared here, in Objective-C, rather than in Swift: the presenter's
// protocol passes NSData, which Swift would see as Data while the presenter
// caches its buffers on the NSData objects it is given, and the Swift tests
// that compile the canvas on its own do not see the adapter's protocols. The
// categories are implemented in VRView+CAPI.m.

#import "Horos-Swift.h"
#import "Adapters/VTK/IsiXVTKFramePresenter.h"

@interface HorosVRPresenter (IsiXVTKFramePresenter) <IsiXVTKFramePresenter>
@end

@interface HorosROICanvas (IsiXVTKLineCanvas) <IsiXVTKLineCanvas>
@end
