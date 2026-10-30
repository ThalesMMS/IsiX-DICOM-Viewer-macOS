//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The VTK side of the volume rendering view: the render window and renderer
// that draw through the view's Metal presenter, the volume's importer, ray
// caster, property and transfer functions, a fused series' own, the camera,
// the crop box and its planes, the interactor, the 2D actors the overlay draws
// (texts, measurements, the scissors' outline) and the 3D points. The view
// keeps the rules and the state of the app (the series, the window level, the
// tools) and hands this object numbers; nothing of VTK reaches it.
//
// Every call into VTK runs inside the adapter's guard. A C++ exception comes
// back as IsiXVTKErrorCodeException; an error VTK reports for an object of the
// call as IsiXVTKErrorCodeLibrary, after the call has run on, as it did when
// VTK wrote it to its output window. The calls that cannot fail in a way the
// view acts on log their failure. Objective-C and C types only.
//
// The implementation is split by responsibility: IsiXVTKVolumeView.mm (the
// window, the render, the interactor, the overlay, the Metal hook),
// IsiXVTKVolumePipeline.mm (importers, ray casters, properties, transfer
// functions, fusion, full-depth capture, the preset previews),
// IsiXVTKVolumeCamera.mm (camera and coordinates), IsiXVTKVolumeCrop.mm (the
// crop box and planes) and IsiXVTKVolumeActors.mm (2D actors and 3D points).

#import <Foundation/Foundation.h>
#import "IsiXVTKError.h"
#import "IsiXVTKFramePresenter.h"
#import "IsiXVTKScene.h"
#import "IsiXVTKSceneOverlay.h"
#import "IsiXVTKVolumeScene.h"

NS_ASSUME_NONNULL_BEGIN

@class IsiXVTKVolumeView;

/// What a ray caster's image is: where it starts on the window, its size in
/// use and in memory, in samples, and the sample distance in pixels.
typedef struct {
    int origin[2];
    int inUseSize[2];
    int memorySize[2];
    double sampleDistance;
} IsiXVTKRayCastImageGeometry;

/// The opacity of a full-depth capture: the scalar range from 0 to 1.
typedef struct {
    float start, end;
} IsiXVTKScalarRange;

/// Renders a volume's ray-cast image with Metal (the view's hook): the scene of
/// the volume being cast and whether it is the fused series'. NO lets VTK cast
/// it on the CPU.
typedef BOOL (^IsiXVTKMetalImageRenderer)(IsiXVTKVolumeView *view, BOOL fused);

/// A user matrix of a volume as a vtkTransform: the transform VTK's scissors
/// and picking used, forward and inverse, in floats or doubles.
@interface IsiXVTKVolumeTransform : NSObject
- (instancetype)init NS_UNAVAILABLE;
/// `point` through the user matrix, in single precision as vtkTransform does it.
- (void)transformFloatPoint:(const float *)point into:(float *)result;
/// The inverse of the user matrix, applied by turning the transform round and
/// back, as the view did.
- (void)inverseTransformFloatPoint:(const float *)point into:(float *)result;
- (void)transformDoublePoint:(const double *)point into:(double *)result;
- (void)inverseTransformDoublePoint:(const double *)point into:(double *)result;
@end

@interface IsiXVTKVolumeView : NSObject

/// The renderer in the render window, as the view is made; nothing else yet.
+ (nullable instancetype)volumeViewWithError:(NSError **)error NS_SWIFT_NAME(make());
- (instancetype)init NS_UNAVAILABLE;

/// Puts back what the view made, in the view's order: the fused series, the
/// transfer functions, the property, the overlay's observers, the ray
/// caster, the volume, the outline, the crop box, the interactor, the texts,
/// the importer, the camera and the 2D actors. The window and renderer stay.
- (void)releasePipeline;
/// The window and its renderer, once the presenters are gone.
- (void)releasePresentation;

#pragma mark Handles

/// The VTK objects as the view's Objective-C API hands them out: a
/// vtkRenderer *, vtkRenderWindow *, vtkCamera *, vtkVolume *, the interactor.
@property (nonatomic, readonly) void *rendererHandle NS_RETURNS_INNER_POINTER;
@property (nonatomic, readonly) void *renderWindowHandle NS_RETURNS_INNER_POINTER;
@property (nonatomic, readonly, nullable) void *cameraHandle NS_RETURNS_INNER_POINTER;
@property (nonatomic, readonly, nullable) void *volumeHandle NS_RETURNS_INNER_POINTER;

@property (nonatomic, readonly) BOOL hasRenderer;
@property (nonatomic, readonly) BOOL hasCamera;
@property (nonatomic, readonly) BOOL hasVolume;
@property (nonatomic, readonly) BOOL hasVolumeMapper;
@property (nonatomic, readonly) BOOL volumeHasMapper;
@property (nonatomic, readonly) BOOL hasBlendingVolume;
@property (nonatomic, readonly) BOOL hasBlendingMapper;
@property (nonatomic, readonly) BOOL hasCropBox;
@property (nonatomic, readonly) BOOL hasProperty;
@property (nonatomic, readonly) BOOL hasColourFunction;
@property (nonatomic, readonly) BOOL hasOpacityFunction;
@property (nonatomic, readonly) BOOL hasWindowText;
@property (nonatomic, readonly) BOOL hasCornerText;

#pragma mark The window and the render (IsiXVTKVolumeView.mm)

/// The pipeline renders with the view's own renderer from now on.
- (void)useOwnRenderer;
/// Where the window draws its frames; nil to stop drawing.
- (void)setPresenter:(nullable id<IsiXVTKFramePresenter>)presenter;
/// A mode of the Stereo menu, the right eye drawn by `eye` for two pictures.
- (void)setStereoMode:(NSInteger)mode eyePresenter:(nullable id<IsiXVTKFramePresenter>)eye;
/// The window's size in pixels and its DPI, set when they changed.
- (void)setWindowWidth:(int)width height:(int)height dpi:(long)dpi;
/// The window's size in pixels.
- (void)getWindowWidth:(int *)width height:(int *)height;
/// The renderer draws, or not, when the window renders.
- (void)setRendererDraws:(BOOL)draws;
- (void)setBackgroundRed:(double)red green:(double)green blue:(double)blue;
/// Renders the window. NO when VTK threw; an error VTK reports is written to
/// its output window, as before, and the frame stands.
- (BOOL)renderWindowWithError:(NSError **)error;
/// Casts the volume's rays, or the fused series', into its mapper's image
/// without drawing anything (the renderer's drawing off).
- (void)castVolumeImageFused:(BOOL)fused;
/// The window's last frame, top-down packed RGB, malloc'd for the caller to
/// free; with `stereo`, both eyes side by side.
- (nullable unsigned char *)copyFrameRGBWidth:(long *)width height:(long *)height stereo:(BOOL)stereo;
/// The ray caster's switch: a render that casts no rays (the scissors and
/// measurements redraw the 2D layer only).
@property (class, nonatomic) BOOL volumeRenderingSuppressed;

/// Asks `renderer` before each ray cast of this view's volume or fused series.
- (void)setMetalImageRenderer:(nullable IsiXVTKMetalImageRenderer)renderer;
/// The scene of the volume, or of the fused series, being rendered: valid
/// while the Metal image renderer runs.
- (nullable IsiXVTKVolumeScene *)renderingScene;
/// The scene of the volume, or the fused series' (empty without one).
- (IsiXVTKVolumeScene *)volumeSceneFused:(BOOL)fused;

/// The 2D layer: around each render, the 2D actors are hidden from VTK and
/// `handler` is called to draw them. NO, with the error, when VTK refuses the
/// observers.
- (BOOL)observeOverlayWithHandler:(void (^)(IsiXVTKVolumeView *view))handler error:(NSError **)error;
- (void)forgetOverlay;
/// The 2D layer of the render being drawn: the visible 2D actors (without the
/// orientation letters when `hideLetters`), the cube, the crop box and the
/// outline of `picked` (a point actor handle). Valid in the overlay's handler.
- (nullable IsiXVTKOverlayFrame *)overlayFrameHidingOrientationLetters:(BOOL)hideLetters cube:(BOOL)cube
                                                                picked:(nullable void *)picked;

/// Runs `handler` when the renderer starts a render, before the overlay's.
- (void)observeRenderStartWithHandler:(void (^)(void))handler;

#pragma mark The interactor (IsiXVTKVolumeView.mm)

/// How a wheel step or a dolly drag is scaled; the interactor is made when
/// first needed.
- (void)setInteractorDeltaTransform:(double (*_Nullable)(double))transform;
/// Makes the interactor if there is none and gives it the renderer.
- (BOOL)prepareInteractor;
- (void)setInteractorEventX:(int)x y:(int)y control:(int)control shift:(int)shift;
- (void)setInteractorEventX:(int)x y:(int)y control:(int)control shift:(int)shift repeat:(int)repeat
                        alt:(BOOL)alt;
- (void)invokeInteractorEvent:(IsiXVTKMouseEvent)event;
- (void)setInteractorRotationPivot:(const double *)pivot;
- (void)clearInteractorRotationPivot;
/// The interactor's display ↔ world conversions on the renderer.
- (void)interactorWorldToDisplayX:(double)x y:(double)y z:(double)z display:(double *)display;
- (void)interactorDisplayToWorldX:(double)x y:(double)y z:(double)z world:(double *)world;
/// The lights follow the camera after a pan, as the interactor's did.
- (void)updateLightsAfterPan;

@end

// The pipeline (IsiXVTKVolumePipeline.mm)
@interface IsiXVTKVolumeView (IsiXVTKVolumePipeline)

/// The volume's ray caster, made over the importer when there is none, and
/// updated: what -[VRView mapper] gave.
- (nullable void *)mapperHandleCreatingIfNeeded NS_RETURNS_INNER_POINTER;
/// Takes `mapper`, a vtkVolumeMapper *, as the volume's ray caster, letting the
/// one it had go (-[VRView setMapper:]).
- (void)takeMapperHandle:(nullable void *)mapper;
/// Takes `volume`, a vtkVolume *, letting the one it had go.
- (void)takeVolumeHandle:(nullable void *)volume;

/// The volume's importer: `voxels` (16-bit or, for RGB, ARGB bytes) of
/// width × height × depth, which the view keeps.
- (BOOL)importVolume:(void *)voxels rgb:(BOOL)rgb width:(long)width height:(long)height depth:(long)depth
               error:(NSError **)error;
- (void)setImportSpacingX:(double)x y:(double)y z:(double)z;
/// A new pointer to the voxels the importer reads, its output marked modified.
- (void)setImportVoxels:(void *)voxels;
/// The voxels changed in place.
- (void)markImportModified;
- (BOOL)updateImportWithError:(NSError **)error;
/// The opacity (0 to `opacityAdapter`), colour, red, green and blue functions
/// and the property over them, for one component or for RGB.
- (BOOL)makeTransferFunctionsRGB:(BOOL)rgb invertedPolarity:(BOOL)inverted opacityAdapter:(float)adapter
                           error:(NSError **)error;
/// The volume, placed by the cosines and the origin, with its outline and,
/// unless `nearest`, linear interpolation.
- (BOOL)makeVolumeNearest:(BOOL)nearest cosines:(const float *)cosines factor:(float)factor
                  originX:(double)x y:(double)y z:(double)z error:(NSError **)error;
/// The crop box over the volume, with rotation, and its callback.
- (BOOL)makeCropBoxWithError:(NSError **)error;
/// The texts: the window level's, the corner's ("X ") when `corner`, the
/// gantry tilt's when given, and the five orientation texts.
- (BOOL)makeTextsWithWindowText:(const char *)windowText corner:(BOOL)corner tilt:(nullable NSString *)tilt
                          error:(NSError **)error;
/// The camera, parallel, rolled 180° and dollied, the volume added and the
/// camera reset.
- (BOOL)makeCameraWithError:(NSError **)error;

/// The volume's ray caster on the importer, its image drawn by the Metal
/// hook, updated and given to the volume.
- (void)allocateVolumeMapper;
/// The volume shows its ray caster.
- (void)attachVolumeMapper;
/// The ray caster goes, its graphics released first.
- (void)discardVolumeMapper;
/// The ray caster's distances: the minimum (level of detail), the sample and
/// the maximum image distance.
- (void)setVolumeMinimumImageSampleDistance:(float)minimum sampleDistance:(float)sample
                  maximumImageSampleDistance:(float)maximum;
- (void)setVolumeMinimumImageSampleDistance:(float)distance;
- (void)setVolumeSampleDistance:(float)distance;
- (void)setVolumeAutoAdjustSampleDistances:(BOOL)adjust;
- (void)setBlendingMinimumImageSampleDistance:(float)minimum sampleDistance:(float)sample
                    maximumImageSampleDistance:(float)maximum;
- (void)setBlendingMinimumImageSampleDistance:(float)distance;
- (void)setBlendingSampleDistance:(float)distance;
- (void)setBlendingAutoAdjustSampleDistances:(BOOL)adjust;
/// The minimum image sample distance of the volume's ray caster.
@property (nonatomic, readonly) float volumeMinimumImageSampleDistance;
/// The view's modes by tag: 0 composite, 1 maximum, 2 minimum, 3 mean.
- (void)setVolumeBlendMode:(long)mode;
- (void)setBlendingBlendMode:(long)mode;
/// The volume's ray caster blends by maximum intensity.
@property (nonatomic, readonly) BOOL volumeBlendModeIsMaximumIntensity;
- (IsiXVTKRayCastImageGeometry)rayCastImageInfoFused:(BOOL)fused;
/// The ray caster's image, four 16-bit components a sample.
- (nullable unsigned short *)rayCastImageFused:(BOOL)fused NS_RETURNS_INNER_POINTER;

/// Holds the crop in place on the volume's ray caster across an engine switch.
- (void)holdAppliedCrop;
/// Applies the held crop to every ray caster. NO when nothing was held.
- (BOOL)applyHeldCrop;
- (void)releaseHeldCrop;
/// Applies the crop in place on the volume's ray caster to every ray caster.
/// NO when there is none.
- (BOOL)reapplyAppliedCrop;

/// Lighting of the property.
- (void)setShadingAmbient:(float)ambient diffuse:(float)diffuse specular:(float)specular power:(float)power;
- (void)getShadingAmbient:(float *)ambient diffuse:(float *)diffuse specular:(float *)specular power:(float *)power;
@property (nonatomic) long shade;

/// The colour function from 256 entries of red, green and blue (`table`,
/// 257 × 3 doubles), between `start` and `end`.
- (void)buildColourFromTable:(const double *)table start:(double)start end:(double)end;
/// The RGB property's three colour components: the colour function, or the
/// red, green and blue ones.
- (void)setRGBComponentsToColourFunction:(BOOL)colourFunction;
- (void)removeAllOpacityPoints;
- (void)addOpacityPointAt:(double)x value:(double)value;
- (void)addOpacitySegmentFrom:(double)x1 value:(double)v1 to:(double)x2 value:(double)v2;
- (void)removeAllColourPoints;
- (void)addColourPointAt:(double)x red:(double)red green:(double)green blue:(double)blue;
- (double)opacityAt:(double)x;

/// The volume's placement.
- (void)getVolumeBounds:(double *)bounds;
- (void)getVolumeCenter:(double *)center;
- (void)getVolumePosition:(double *)position fused:(BOOL)fused;
- (void)setBlendingPickable:(BOOL)pickable;
/// The user matrix of the volume, or the fused series', as a transform.
- (nullable IsiXVTKVolumeTransform *)userTransformFused:(BOOL)fused;
/// The voxel → world transform for the MPR: sixteen numbers, column by column,
/// in millimetres; nil without an importer or volume.
- (nullable NSArray<NSNumber *> *)voxelToWorldTransformWithFactor:(float)factor;

/// The fused series: its importer on `voxels`, its functions, property,
/// volume and placement, added to the renderer.
- (BOOL)fuseVoxels:(void *)voxels rgb:(BOOL)rgb width:(long)width height:(long)height depth:(long)depth
          spacingX:(double)sx y:(double)sy z:(double)sz error:(NSError **)error;
- (BOOL)finishFusionWithCosines:(const float *)cosines factor:(float)factor originX:(double)x y:(double)y
                              z:(double)z error:(NSError **)error;
/// The fused series' property over the red, green and blue functions or the
/// colour function, made after its opacity table.
- (void)makeBlendingPropertyRGB:(BOOL)rgb;
/// The fused series' volume over its property, linearly interpolated.
- (void)makeBlendingVolume;
/// The fused series' ray caster, made when there is none.
- (void)attachBlendingMapper;
- (void)discardBlendingMapper;
/// The fused series' importer reads `voxels`, its output marked modified.
- (void)setBlendingImportVoxels:(void *)voxels;
- (void)updateBlendingImport;
/// The fused series' importer reads `voxels` now, and a new ray caster
/// (without the Metal hook) recomputes its range.
- (void)replaceBlendingVoxels:(void *)voxels minimumImageSampleDistance:(float)minimum;
- (void)releaseFusion;
- (void)buildBlendingOpacityFromTable:(const double *)table start:(double)start end:(double)end;
- (void)buildBlendingColourFromTable:(const double *)table start:(double)start end:(double)end;

/// Full-depth capture: each ray caster's opacity over its scalar range, its
/// capture switched on; and back.
- (void)prepareFullDepthWithRange:(IsiXVTKScalarRange)range blendingRange:(IsiXVTKScalarRange)blendingRange
                          volume:(BOOL *)volumeDone;
- (void)restoreFullDepth:(BOOL *)volumeDone;

/// A preset preview's pipeline over `voxels`, as the previews built theirs.
- (BOOL)makePreviewImport:(void *)voxels rgb:(BOOL)rgb width:(long)width height:(long)height depth:(long)depth
                    error:(NSError **)error;
- (BOOL)makePreviewTransferFunctionsRGB:(BOOL)rgb error:(NSError **)error;
- (BOOL)makePreviewVolumeNearest:(BOOL)nearest cosines:(const float *)cosines factor:(float)factor
                         originX:(double)x y:(double)y z:(double)z windowText:(const char *)windowText
                           error:(NSError **)error;
/// A preview's own ray caster over the input of `source` (a vtkVolumeMapper *),
/// with its blend mode and distances, drawn by this view's Metal hook when
/// `source` is drawn by one (YES then).
- (BOOL)adoptPreviewMapperOf:(void *)source;
- (void)showVolume:(BOOL)shown;

@end

// The camera (IsiXVTKVolumeCamera.mm)
@interface IsiXVTKVolumeView (IsiXVTKVolumeCamera)

- (void)getCameraPosition:(double *)position;
- (void)setCameraPosition:(const double *)position;
- (void)getCameraFocalPoint:(double *)focal;
- (void)setCameraFocalPoint:(const double *)focal;
- (void)getCameraViewUp:(double *)viewUp;
- (void)setCameraViewUp:(const double *)viewUp;
- (void)getCameraViewPlaneNormal:(double *)normal;
- (void)getCameraDirectionOfProjection:(double *)direction;
/// The view up and direction of projection in one read; NO without a camera.
- (BOOL)getCameraViewUp:(double *)viewUp directionOfProjection:(double *)direction;
- (void)getCameraWindowCenter:(double *)center;
- (void)setCameraWindowCenterX:(double)x y:(double)y;
- (void)getCameraClippingRange:(double *)range;
- (void)setCameraClippingRangeNear:(double)near far:(double)far;
/// The view transform, sixteen doubles row by row.
- (void)getCameraViewTransform:(double *)rowMajor;
@property (nonatomic) double cameraDistance;
@property (nonatomic) double cameraParallelScale;
@property (nonatomic) double cameraViewAngle;
@property (nonatomic) double cameraEyeAngle;
@property (nonatomic) BOOL cameraParallelProjection;
@property (nonatomic, readonly) double cameraRoll;
- (void)setCameraRoll:(double)degrees;
- (void)cameraAzimuth:(double)degrees;
- (void)cameraElevation:(double)degrees;
- (void)cameraYaw:(double)degrees;
- (void)cameraPitch:(double)degrees;
- (void)cameraRoll:(double)degrees;
- (void)cameraDolly:(double)factor;
- (void)cameraZoom:(double)factor;
- (void)cameraComputeViewPlaneNormal;
- (void)cameraOrthogonalizeViewUp;
/// Moves the camera by a translation (ApplyTransform).
- (void)cameraTranslateX:(double)x y:(double)y z:(double)z;
/// `point` (homogeneous) through the view transform, and back through its inverse.
- (void)cameraViewTransformPoint:(const double *)point into:(double *)result;
- (void)cameraInverseViewTransformPoint:(const double *)point into:(double *)result;
/// Copies `source`'s camera (a vtkCamera *) when it differs; YES when it did.
- (BOOL)copyCameraFromHandle:(void *)source;
- (void)resetCamera;
- (void)resetCameraClippingRange;
/// Resets the camera and keeps `chosenAngle` (when `keep`), the camera
/// dollied to frame the volume as at the reset's angle when `fit`.
- (void)resetCameraKeepingViewAngle:(double)chosenAngle keep:(BOOL)keep fit:(BOOL)fit;
- (void)updateLightsToFollowCamera;
/// The renderer's display → world conversion (homogeneous, four doubles) and
/// world → display (three).
- (void)worldPointOfDisplayX:(double)x y:(double)y z:(double)z into:(double *)world;
- (void)displayPointOfWorldX:(double)x y:(double)y z:(double)z w:(double)w into:(double *)display;
- (void)getViewport:(double *)viewport;

@end

// The crop box (IsiXVTKVolumeCrop.mm)
@interface IsiXVTKVolumeView (IsiXVTKVolumeCrop)

- (void)placeCropBox;
@property (nonatomic, readonly) BOOL cropBoxEnabled;
- (void)setCropBoxEnabled:(BOOL)enabled;
/// Turns the box off when it is on.
- (void)hideCropBox;
- (void)setCropBoxHandleSize:(double)size;
/// Runs the box's callback: its planes onto the ray casters.
- (void)executeCropCallback;
/// The box, in the volume's frame, min and max of each axis; NO without one.
- (BOOL)getCroppingBox:(double *)box;
/// The planes in place on the volume's ray caster, origins and normals three
/// doubles each, when there are six; and the volume's bounds.
- (BOOL)getAppliedCropOrigins:(double *)origins normals:(double *)normals bounds:(double *)bounds;
/// Puts the box at `matrix` (sixteen doubles) after placing it.
- (void)setCropBoxTransform:(const double *)matrix;
/// The six planes a camera keeps: the applied ones when there are six,
/// otherwise the box's; their count.
- (int)getCameraCropOrigins:(double *)origins normals:(double *)normals;
/// Six planes onto the volume's and the fused series' ray casters, and the box off.
- (void)setCropPlanesOrigins:(const double *)origins normals:(const double *)normals;

@end

// The 2D actors and the 3D points (IsiXVTKVolumeActors.mm)
@interface IsiXVTKVolumeView (IsiXVTKVolumeActors)

/// The scissors' outline, the oval, the line and angle measurements and the
/// notice of measurements hidden by another view.
- (BOOL)makeMeasurementActorsWithNotice:(NSString *)notice error:(NSError **)error;

- (void)setWindowText:(const char *)text;
/// The window level text's place, two pixels in and fifteen down from the top.
- (void)placeWindowTextBelowTop:(double)offset;
- (void)setOrientationText:(const char *)text atIndex:(int)index;
- (void)showOrientationTexts:(BOOL)shown;
- (void)showCornerText:(BOOL)shown;
- (void)removeOutline;
/// The texts in white on a dark background, in black on a light one.
- (void)setTextColourWhite:(BOOL)white;

/// The scissors' outline through `points` (display pixels), closed; empty
/// for no points.
- (void)setScissorsOutline:(nullable const double *)points count:(long)count;
@property (nonatomic, readonly) long scissorsPointCount;
/// The outline's points, two doubles each.
- (void)getScissorsPoints:(double *)points;

/// The oval's circle, shown.
- (void)showOvalWithCenterX:(double)x y:(double)y radius:(double)radius;
- (void)hideOval;
- (void)placeOvalText:(const char *)text x:(double)x y:(double)y;
- (void)removeOvalText;

/// The line being measured: its points in display pixels.
@property (nonatomic, readonly) long activeLinePointCount;
@property (nonatomic, readonly) BOOL activeLineVisible;
- (void)getActiveLinePoint:(long)index into:(double *)point;
/// Starts the line anew (no points).
- (void)clearActiveLine;
/// Adds a point at the end, as the click did, rebuilding the line's cells.
- (void)appendActiveLinePointX:(double)x y:(double)y;
/// The points appended are marked modified and set again on the line.
- (void)commitActiveLinePoints;
/// Moves the last point, as a drag did.
- (void)moveLastActiveLinePointX:(double)x y:(double)y;
/// Exchanges the two endpoints.
- (void)swapActiveLineEndpoints;
- (void)placeActiveLineText:(const char *)text x:(double)x y:(double)y;
- (void)removeActiveLineText;
/// The line's world points and direction now, for showing it again in this
/// parallel view only.
- (void)captureLineProjection;
/// Projects the line and the stored ones; NO when there is nothing to project.
/// `wasVisible` is the line's visibility before, `visible` after, `length`
/// its world length when visible.
- (BOOL)updateLineProjectionsWasVisible:(BOOL *)wasVisible visible:(BOOL *)visible length:(double *)length;
/// Keeps the line as a stored one; NO when it has no projection.
- (BOOL)storeActiveLine;
- (void)clearStoredLines;
@property (nonatomic, readonly) long storedLineCount;
/// A stored line's world length and its text.
- (double)storedLineLengthAtIndex:(long)index;
- (void)setStoredLineText:(const char *)text atIndex:(long)index;
- (BOOL)storedLineVisibleAtIndex:(long)index;
- (BOOL)getStoredLineAtIndex:(long)index first:(double *)first second:(double *)second;
/// Makes a stored line the one being measured again, the current one stored.
- (void)reactivateStoredLineAtIndex:(long)index;
/// Moves every line's points by `map` (display pixels), as a viewport resize does.
- (void)remapLinePoints:(CGPoint (^)(CGPoint point))map;

/// The angle: whether its actors exist; its points projected from patient
/// millimetres (× `factor`) to display; its points, polyline and text shown.
@property (nonatomic, readonly) BOOL hasAngleActors;
- (BOOL)projectPatientPoints:(const double *)patient count:(int)count factor:(double)factor into:(double *)display;
- (void)showAngleDisplayPoints:(const double *)display count:(int)count text:(nullable const char *)text
                       visible:(BOOL)visible;

/// A sphere for a 3D point; its handle (a vtkActor *), which the view keeps.
- (nullable void *)makePointSphereX:(double)x y:(double)y z:(double)z radius:(double)radius red:(double)red
                              green:(double)green blue:(double)blue NS_RETURNS_INNER_POINTER;
- (void)addPointActor:(void *)actor;
- (void)removePointActor:(void *)actor;
/// Removes and lets the actor go.
- (void)deletePointActor:(void *)actor;
- (void)setPointActor:(void *)actor red:(double)red green:(double)green blue:(double)blue;
- (void)setPointActor:(void *)actor centerX:(double)x y:(double)y z:(double)z radius:(double)radius;
/// The point the ray under (x, y) meets first among `actors` (handles in
/// NSValues), visible and pickable ones only; NULL for none.
- (nullable void *)pickPointAmong:(NSArray<NSValue *> *)actors x:(double)x y:(double)y;

@end

NS_ASSUME_NONNULL_END
