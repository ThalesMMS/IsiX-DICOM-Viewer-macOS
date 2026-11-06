//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The codecs DCMTK decodes and encodes pixel data with in the application:
// JPEG, JPEG-LS, RLE and JPEG 2000. The Decompress service registers the same
// ones through this adapter. Objective-C and C types only, for the bridging headers.

#import <Foundation/Foundation.h>
#import "IsiXDCMTKError.h"

NS_ASSUME_NONNULL_BEGIN

@interface IsiXDCMTKCodecs : NSObject

- (instancetype)init NS_UNAVAILABLE;

/// Registers the decoders and encoders with DCMTK's global codec list.
/// Registering again is a no-op: a plugin may need them before the
/// application has finished launching.
+ (BOOL)registerCodecs:(NSError **)error NS_SWIFT_NAME(registerCodecs());

/// Removes them again, when the application quits.
+ (BOOL)cleanupCodecs:(NSError **)error NS_SWIFT_NAME(cleanupCodecs());

/// Whether a lossy JPEG whose JFIF or Adobe marker contradicts its Photometric
/// Interpretation is decoded by the marker. On until it is set.
@property (class) BOOL markersDecideColour;

@end

NS_ASSUME_NONNULL_END
