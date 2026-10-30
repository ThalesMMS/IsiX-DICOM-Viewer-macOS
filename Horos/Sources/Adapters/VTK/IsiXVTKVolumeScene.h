//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// One volume of a 3D view as VTK holds it - the renderer and its camera, the
// ray-cast mapper, the volume, its property and transfer functions, and the
// importer of its voxels - read and written as values. The Metal renderer of
// the 3D view (Swift) takes what it renders from here: VTK's state goes out as
// numbers and tables, and the picture Metal made goes back into the mapper's
// ray-cast image. Every call runs inside the adapter's guard: a C++ exception,
// or an error VTK reports for one of the scene's objects, comes back as an
// NSError of IsiXVTKErrorDomain. Objective-C and C types only.

#import <Foundation/Foundation.h>
#import "IsiXVTKError.h"

NS_ASSUME_NONNULL_BEGIN

/// Why the mapper refused to set up its ray-cast geometry, as
/// vtkHorosFixedPointVolumeRayCastMapper numbers them.
typedef NS_ENUM(NSInteger, IsiXVTKGeometryRefusal) {
    IsiXVTKGeometryRefusalAccepted = 0,
    IsiXVTKGeometryRefusalNoInput,
    IsiXVTKGeometryRefusalNoViewport,
    IsiXVTKGeometryRefusalClippingPlane,
    IsiXVTKGeometryRefusalNoRows,
};

/// The view's camera, in VTK's world frame.
typedef struct {
    double position[3], focalPoint[3], viewUp[3];
    BOOL parallelProjection;
    double parallelScale, viewAngle, eyeAngle;
    BOOL leftEye;
    double windowCenter[2];
    double clippingRange[2];
    /// The render window renders a stereo pair.
    BOOL stereoRender;
} IsiXVTKCameraState;

/// The mapper's ray-cast image: its memory, the viewport it covers and the
/// rectangle in use, in ray pixels, VTK's origin at the bottom left.
typedef struct {
    NSInteger memoryWidth, memoryHeight;
    NSInteger viewportWidth, viewportHeight;
    NSInteger originX, originY;
    NSInteger usedWidth, usedHeight;
} IsiXVTKRayCastImageInfo;

/// What the property and the mapper hold of the volume's sampling, shading
/// and cropping.
typedef struct {
    double sampleDistance, minimumImageSampleDistance;
    BOOL shade;
    double ambient, diffuse, specular, specularPower;
    /// The weights of the four components.
    double componentWeight[4];
    /// VTK's cropping regions: on, a single subvolume, and its six planes in
    /// the data's coordinates.
    BOOL cropping, croppingSubvolume;
    double croppingRegionPlanes[6];
    /// The mapper's input image, whose coordinates the cropping planes are in.
    BOOL hasInput;
    double inputOrigin[3], inputSpacing[3];
} IsiXVTKVolumeSampling;

/// The placement of the volume's voxels: the importer's output origin and
/// spacing, and the volume's matrix, row by row.
typedef struct {
    BOOL hasImporterOutput;
    double origin[3], spacing[3];
    double matrix[16];
} IsiXVTKVolumePlacement;

/// One component's lookup tables as the mapper last built them.
@interface IsiXVTKComponentTable : NSObject
@property (nonatomic, readonly) NSInteger component;
@property (nonatomic, readonly) double weight;
/// The mapper's shift and scale of the component's values into its tables.
@property (nonatomic, readonly) float shift, scale;
@property (nonatomic, readonly) NSInteger size;
/// size words of scalar opacity, size × 3 words of colour; nil when the
/// mapper has no table yet.
@property (nonatomic, readonly, nullable) NSData *opacity, *colour;
@end

/// One volume of a 3D view, read for one call: the scene borrows the view's
/// VTK objects and must not be kept past the call that asked for it.
@interface IsiXVTKVolumeScene : NSObject
- (instancetype)init NS_UNAVAILABLE;

/// Which of the scene's objects the view has.
@property (nonatomic, readonly) BOOL hasRenderer, hasCamera, hasMapper, hasVolume, hasProperty;
@property (nonatomic, readonly) BOOL hasColourFunction, hasOpacityFunction, hasImporter;

/// The view's camera, and whether its render window renders stereo.
- (BOOL)readCamera:(IsiXVTKCameraState *)camera error:(NSError **)error NS_SWIFT_NAME(readCamera(_:));
- (BOOL)readSampling:(IsiXVTKVolumeSampling *)sampling error:(NSError **)error NS_SWIFT_NAME(readSampling(_:));
- (BOOL)readPlacement:(IsiXVTKVolumePlacement *)placement error:(NSError **)error NS_SWIFT_NAME(readPlacement(_:));

/// Each light of the renderer: switched on, its intensity and its ambient
/// colour.
- (BOOL)enumerateLightsUsingBlock:(void (NS_NOESCAPE ^)(BOOL on, double intensity, const double *ambientColour))block
                            error:(NSError **)error;

/// Sets up the ray-cast image and its matrices as a render would, without
/// casting a ray (vtkHorosFixedPointVolumeRayCastMapper::PrepareMPRGeometry).
/// The refusal, Accepted when the geometry is ready; `accept` lets clipping
/// planes through for a caller that clips the rays itself.
- (IsiXVTKGeometryRefusal)prepareGeometryAcceptingClippingPlanes:(BOOL)accept error:(NSError **)error
    NS_SWIFT_NAME(prepareGeometry(acceptingClippingPlanes:)) __attribute__((swift_error(nonnull_error)));
/// Why the last preparation refused.
- (IsiXVTKGeometryRefusal)lastGeometryRefusal;

/// After the preparation: the clipping planes in voxel index coordinates,
/// four floats a plane, the kept side where a·x + b·y + c·z + d ≥ 0.
- (nullable NSData *)voxelClippingPlanesWithError:(NSError **)error;

/// After the preparation, during the volume pass: the opaque geometry's
/// distance along the camera, in millimetres, top row first; empty when there
/// is none to stop the rays.
- (nullable NSData *)geometryDepthWithWorldUnitsPerMillimetre:(double)factor error:(NSError **)error;

- (BOOL)readRayCastImage:(IsiXVTKRayCastImageInfo *)info error:(NSError **)error NS_SWIFT_NAME(readRayCastImage(_:));

/// The ray-cast image's words, premultiplied RGBA in 15 bits, its rows
/// `memoryWidth` pixels apart, bottom row first: read, or written in place.
- (BOOL)accessRayCastImage:(void (NS_NOESCAPE ^)(uint16_t *_Nullable pixels, IsiXVTKRayCastImageInfo info))block
                     error:(NSError **)error;

/// Brings the mapper's colour and opacity tables up to date for the
/// volume, as a render does before casting.
- (BOOL)initializeVolumeTablesWithError:(NSError **)error;

/// The four components' tables, as the mapper last built them.
- (nullable NSArray<IsiXVTKComponentTable *> *)componentTablesWithError:(NSError **)error;

/// `count` doubles evaluated evenly over [from, to]: the property's colour
/// function of `component` (three a value) or its scalar opacity (one).
- (nullable NSData *)componentColourTable:(NSInteger)component from:(double)from to:(double)to count:(NSInteger)count
                                    error:(NSError **)error;
- (nullable NSData *)componentOpacityTable:(NSInteger)component from:(double)from to:(double)to count:(NSInteger)count
                                     error:(NSError **)error;
/// The same for the view's own colour and opacity functions.
- (nullable NSData *)colourTableFrom:(double)from to:(double)to count:(NSInteger)count error:(NSError **)error;
- (nullable NSData *)opacityTableFrom:(double)from to:(double)to count:(NSInteger)count error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
