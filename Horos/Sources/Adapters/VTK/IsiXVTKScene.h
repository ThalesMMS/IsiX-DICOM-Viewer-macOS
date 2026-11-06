//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// A VTK scene of surfaces, presented by Metal: the renderer, the render window
// and the interactor of the surface and ROI volume views, their camera, and the
// actors they show. VTK keeps the camera and the props and renders through the
// adapter's HorosVRRenderWindow and HorosVRRenderer, which draw with the view's
// frame presenter (IsiXVTKFramePresenter); the mouse moves the camera through
// HorosVRInteractor. The views (Swift) hold these objects and never see VTK.
//
// Every call into VTK runs inside the adapter's guard. A call that can fail
// (a render, a pick, a pipeline, an export) gives its failure back as an
// NSError of IsiXVTKErrorDomain; a setter that cannot fail in a way the caller
// could act on logs it. Objective-C and C types only.

#import <Foundation/Foundation.h>
#import "IsiXVTKError.h"
#import "IsiXVTKFramePresenter.h"

NS_ASSUME_NONNULL_BEGIN

@class IsiXVTKCamera;
@class IsiXVTKScene;
@class IsiXVTKTexture;
@class IsiXVTKOverlayFrame;

/// A point or a vector in VTK's world.
typedef struct {
    double x, y, z;
} IsiXVTKPoint;

/// An axis-aligned box: xmin, xmax, ymin, ymax, zmin, zmax.
typedef struct {
    double xmin, xmax, ymin, ymax, zmin, zmax;
} IsiXVTKBounds;

/// The mouse events the interactor takes, as VTK names them.
typedef NS_ENUM(NSInteger, IsiXVTKMouseEvent) {
    IsiXVTKMouseEventLeftButtonPress = 0,
    IsiXVTKMouseEventLeftButtonRelease,
    IsiXVTKMouseEventRightButtonPress,
    IsiXVTKMouseEventRightButtonRelease,
    IsiXVTKMouseEventMiddleButtonPress,
    IsiXVTKMouseEventMiddleButtonRelease,
    IsiXVTKMouseEventMove,
    IsiXVTKMouseEventWheelForward,
    IsiXVTKMouseEventWheelBackward,
};

/// The scene file formats VTK's exporters write from a render window.
typedef NS_ENUM(NSInteger, IsiXVTKSceneFormat) {
    /// RenderMan: the path's extension is replaced by the exporter's.
    IsiXVTKSceneFormatRIB = 1,
    IsiXVTKSceneFormatVRML = 2,
    IsiXVTKSceneFormatInventor = 3,
    /// Wavefront OBJ: the path's extension is replaced by the exporter's.
    IsiXVTKSceneFormatOBJ = 4,
};

/// A vtkActor, its mapper and whatever builds the mapper's input. Retains them
/// while it lives.
@interface IsiXVTKActor : NSObject
- (instancetype)init NS_UNAVAILABLE;

/// The vtkActor * itself, for the Objective-C++ that still hands VTK pointers
/// around (an ROI volume's actor in the volume rendering view).
@property (nonatomic, readonly) void *vtkActor NS_RETURNS_INNER_POINTER;

@property (nonatomic) BOOL visible;
@property (nonatomic) BOOL pickable;
@property (nonatomic) BOOL dragable;
/// The property's opacity.
@property (nonatomic) double opacity;

/// The property's colour (ambient, diffuse and specular).
- (void)setColorRed:(double)red green:(double)green blue:(double)blue NS_SWIFT_NAME(setColor(red:green:blue:));
/// The property's diffuse colour alone.
- (void)setDiffuseColorRed:(double)red green:(double)green blue:(double)blue NS_SWIFT_NAME(setDiffuseColor(red:green:blue:));
/// The property's lighting coefficients.
- (void)setSpecular:(double)specular power:(double)power NS_SWIFT_NAME(setSpecular(_:power:));
- (void)setAmbient:(double)ambient diffuse:(double)diffuse NS_SWIFT_NAME(setAmbient(_:diffuse:));
- (void)setFrontfaceCulling:(BOOL)front backfaceCulling:(BOOL)back NS_SWIFT_NAME(setCulling(front:back:));
/// Wireframe, or surface, representation.
- (void)setWireframe:(BOOL)wireframe;

/// The actor's placement: VTK applies the user matrix about the origin, then
/// moves the result to the position.
- (void)setOrigin:(IsiXVTKPoint)origin;
@property (nonatomic) IsiXVTKPoint position;
- (void)setUniformScale:(double)scale;
/// Sixteen doubles, row by row; NULL for none.
- (void)setUserMatrix:(nullable const double *)rowMajor;
@property (nonatomic, readonly) IsiXVTKBounds bounds;

/// The texture drawn on the surface, or none.
- (void)setTexture:(nullable IsiXVTKTexture *)texture;

/// An actor of no mapper, which shows nothing.
+ (nullable instancetype)emptyActorWithError:(NSError **)error NS_SWIFT_NAME(empty());

/// A sphere of VTK's default resolution, as the surface view's 3D points are.
+ (nullable instancetype)sphereAt:(IsiXVTKPoint)centre radius:(double)radius error:(NSError **)error
    NS_SWIFT_NAME(sphere(at:radius:));
/// Rebuilds the sphere of an actor made by +sphereAt:radius:error:.
- (BOOL)setSphereCentre:(IsiXVTKPoint)centre radius:(double)radius error:(NSError **)error
    NS_SWIFT_NAME(setSphere(centre:radius:));

/// A vtkFollower of vtkVectorText: 3D text that turns to face a camera.
+ (nullable instancetype)followerWithText:(NSString *)text error:(NSError **)error NS_SWIFT_NAME(follower(text:));
/// The camera a follower faces: `scene`'s active one.
- (void)followCameraOfScene:(IsiXVTKScene *)scene NS_SWIFT_NAME(followCamera(of:));

/// A triangle mesh: `vertices` holds three doubles a vertex, `triangles`
/// three uint64 vertex indices a face. An empty mesh when the data is
/// malformed (a length that is no multiple, an index out of range, a
/// degenerate face or a vertex that is not finite), as nothing is repaired.
+ (nullable instancetype)meshWithVertices:(NSData *)vertices triangles:(NSData *)triangles error:(NSError **)error
    NS_SWIFT_NAME(mesh(vertices:triangles:));
/// The same mesh with texture coordinates mapped onto a sphere around it
/// (vtkTextureMapToSphere, without a seam), as the Delaunay hull has them: a
/// texture shows only on a surface with coordinates.
+ (nullable instancetype)sphereMappedMeshWithVertices:(NSData *)vertices triangles:(NSData *)triangles error:(NSError **)error
    NS_SWIFT_NAME(sphereMappedMesh(vertices:triangles:));

/// The closed hull of `points` (three doubles each) that vtkDelaunay3D finds
/// with an alpha of 20 and a tolerance of 0.001, without the bounding
/// triangulation, its texture coordinates mapped onto a sphere: its outer
/// faces, as polygonal data.
+ (nullable instancetype)delaunayHullOfPoints:(NSData *)points error:(NSError **)error
    NS_SWIFT_NAME(delaunayHull(points:));

/// The lines where the plane through `origin` with `normal` cuts the actor's
/// mapper input (vtkCutter), each three doubles a point, in the input's own
/// coordinates. The plane is moved 1e-4 along its normal first: a mesh of
/// voxel faces has every face on a half-voxel plane, and a plane through a
/// face yields no line. Empty for a normal of no length.
- (nullable NSArray<NSData *> *)sectionsByPlaneThrough:(IsiXVTKPoint)origin normal:(IsiXVTKPoint)normal
                                                  error:(NSError **)error NS_SWIFT_NAME(sections(planeThrough:normal:));

/// Another actor drawing the same mapper input as this one (a new mapper,
/// scalar visibility off), as the same mesh is shown in several views.
- (nullable IsiXVTKActor *)actorSharingInputWithError:(NSError **)error NS_SWIFT_NAME(actorSharingInput());
@end

/// A vtkTexture of the TIFF at a path, read by vtkTIFFReader.
@interface IsiXVTKTexture : NSObject
- (instancetype)init NS_UNAVAILABLE;
/// The reader reads the file first, and the texture takes its output port.
/// With `connected`, the texture interpolates; without, it interpolates,
/// repeats and updates itself: the two ways the ROI volume and its view
/// always built theirs.
+ (nullable instancetype)textureWithTIFFAtPath:(NSString *)path connected:(BOOL)connected error:(NSError **)error
    NS_SWIFT_NAME(texture(tiffAt:connected:));
@end

/// A vtkTextActor: a string at a position of the view.
@interface IsiXVTKTextActor : NSObject
/// A text actor holding `text`, not scaled with the view.
- (instancetype)initWithText:(NSString *)text;
- (instancetype)init NS_UNAVAILABLE;
- (void)setText:(NSString *)text;
/// The position in viewport pixels, or, normalized, as fractions of the viewport.
- (void)setPositionX:(double)x y:(double)y normalized:(BOOL)normalized NS_SWIFT_NAME(setPosition(x:y:normalized:));
- (void)setFontSize:(int)size bold:(BOOL)bold shadowOffset:(int)shadow NS_SWIFT_NAME(setFont(size:bold:shadowOffset:));
/// VTK's justifications: 0 left (bottom), 1 centred, 2 right (top).
- (void)setJustification:(int)horizontal vertical:(int)vertical NS_SWIFT_NAME(setJustification(_:vertical:));
@end

/// A surface iso-contoured from a volume of float voxels: vtkContourFilter,
/// optionally after vtkImageResample in the slice plane, then vtkDecimatePro,
/// vtkSmoothPolyDataFilter and vtkPolyDataNormals, as the surface rendering
/// built its surfaces.
@interface IsiXVTKIsoSurfaceSource : NSObject
- (instancetype)init NS_UNAVAILABLE;

/// Imports `voxels` (width × height × depth floats, x fastest), which the
/// caller keeps alive while the source lives, with the spacing; `flip` turns
/// the slices over about the origin, as a negative slice interval needs.
- (nullable instancetype)initWithVoxels:(const float *)voxels width:(NSInteger)width height:(NSInteger)height
                                  depth:(NSInteger)depth spacingX:(double)spacingX spacingY:(double)spacingY
                               spacingZ:(double)spacingZ flip:(BOOL)flip error:(NSError **)error;

/// A surface at `isoValue`. A resolution other than 1 resamples the slices
/// (in x and y) by it first; the resampled volume is kept for the next
/// surface, and its factor changed when another resolution asks for it.
/// `decimation` is the target reduction (with `decimate`), `iterations` the
/// smoothing passes (with `smooth`). The surface is not pickable. A
/// resolution that is not a positive number is InvalidArgument.
- (nullable IsiXVTKActor *)surfaceAtValue:(double)isoValue resolution:(double)resolution decimate:(BOOL)decimate
                                reduction:(double)reduction smooth:(BOOL)smooth iterations:(NSInteger)iterations
                                    error:(NSError **)error
    NS_SWIFT_NAME(surface(at:resolution:decimate:reduction:smooth:iterations:));

/// The volume's outline box, green and half transparent, not pickable.
- (nullable IsiXVTKActor *)outlineWithError:(NSError **)error NS_SWIFT_NAME(outline());
@end

/// A camera of a scene, borrowed: the scene's active camera when it was asked.
@interface IsiXVTKCamera : NSObject
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic) IsiXVTKPoint position;
@property (nonatomic) IsiXVTKPoint focalPoint;
@property (nonatomic) IsiXVTKPoint viewUp;
@property (nonatomic, readonly) IsiXVTKPoint viewPlaneNormal;
@property (nonatomic) double distance;
@property (nonatomic) double viewAngle;
@property (nonatomic) double eyeAngle;
@property (nonatomic) double parallelScale;
@property (nonatomic) BOOL parallelProjection;
/// The near and far clipping planes.
- (void)getClippingRangeNear:(double *)near far:(double *)far NS_SWIFT_NAME(getClippingRange(near:far:));
/// The view transform, sixteen doubles row by row.
- (void)getViewTransform:(double *)rowMajor NS_SWIFT_NAME(getViewTransform(_:));

- (void)azimuth:(double)degrees;
- (void)elevation:(double)degrees;
- (void)yaw:(double)degrees;
- (void)pitch:(double)degrees;
- (void)roll:(double)degrees;
- (void)setRoll:(double)degrees;
- (void)dolly:(double)factor;
- (void)zoom:(double)factor;
- (void)computeViewPlaneNormal;
- (void)orthogonalizeViewUp;
@end

/// The renderer, the render window and the interactor of a surface view, or,
/// borrowed, the renderer of another 3D view.
@interface IsiXVTKScene : NSObject

/// A scene of its own: a HorosVRRenderer in a HorosVRRenderWindow, with a
/// HorosVRInteractor on the renderer, drawing nothing until it has a presenter.
- (nullable instancetype)initWithError:(NSError **)error;
/// The same scene, for Swift, which cannot call an initializer whose plain
/// -init is unavailable.
+ (nullable instancetype)sceneWithError:(NSError **)error NS_SWIFT_NAME(make());
- (instancetype)init NS_UNAVAILABLE;

/// The renderer of another 3D view, which answers -renderer with a
/// vtkRenderer * (the volume rendering view): its actors can be added and
/// removed here. Nil when the view has none. The renderer is retained.
+ (nullable instancetype)sceneOfView:(id)view NS_SWIFT_NAME(init(borrowingRendererOf:));

/// The vtkRenderer *, for comparing two scenes' renderers; not to be used.
@property (nonatomic, readonly) const void *rendererIdentity;
/// The vtkRenderer * and vtkRenderWindow *, for the Objective-C++ callers of a
/// view's -renderer and -renderWindow.
@property (nonatomic, readonly) void *vtkRenderer NS_RETURNS_INNER_POINTER;
@property (nonatomic, readonly, nullable) void *vtkRenderWindow NS_RETURNS_INNER_POINTER;

/// Where the window draws its frames; nil to stop drawing.
- (void)setPresenter:(nullable id<IsiXVTKFramePresenter>)presenter;
/// A mode of the Stereo menu (the tags of its items), with the presenter of
/// the right eye for two pictures.
- (void)setStereoMode:(NSInteger)mode eyePresenter:(nullable id<IsiXVTKFramePresenter>)eye;
@property (nonatomic, readonly) BOOL stereoRender;

/// Called after each render of the renderer, as VTK drew its 2D actors last.
- (void)setRenderEndHandler:(nullable void (^)(void))handler;
/// How a wheel step or a dolly drag is scaled before it moves the camera.
- (void)setDeltaTransform:(double (*_Nullable)(double))transform;

/// The window's size in pixels and its DPI, for text actors.
@property (nonatomic, readonly) NSInteger width, height;
- (void)setWidth:(NSInteger)width height:(NSInteger)height;
@property (nonatomic) NSInteger dpi;

/// Renders the scene into the presenter's frame.
- (BOOL)renderWithError:(NSError **)error NS_SWIFT_NAME(render());

- (void)addActor:(IsiXVTKActor *)actor NS_SWIFT_NAME(addActor(_:));
- (void)removeActor:(IsiXVTKActor *)actor NS_SWIFT_NAME(removeActor(_:));
- (BOOL)containsActor:(IsiXVTKActor *)actor NS_SWIFT_NAME(contains(_:));
/// The vtkActor * of an actor made elsewhere (IsiXVTKActor.vtkActor).
- (void)addActorPointer:(void *)actor NS_SWIFT_NAME(addActor(pointer:));
- (void)removeActorPointer:(void *)actor NS_SWIFT_NAME(removeActor(pointer:));
- (void)addText:(IsiXVTKTextActor *)text NS_SWIFT_NAME(addText(_:));
- (void)removeText:(IsiXVTKTextActor *)text NS_SWIFT_NAME(removeText(_:));
- (void)removeAllViewProps;
- (void)setBackgroundRed:(double)red green:(double)green blue:(double)blue NS_SWIFT_NAME(setBackground(red:green:blue:));

/// The active camera.
@property (nonatomic, readonly) IsiXVTKCamera *camera;
/// Gives the renderer a camera of its own, VTK's defaults.
- (void)useNewCamera;
- (void)resetCamera;
- (void)resetCameraClippingRange;
- (void)updateLightsToFollowCamera;

/// A mouse event for the interactor: its position in display pixels from the
/// bottom left and its keys (control and shift; the repeat count is the
/// clicks after the first).
- (void)setEventX:(int)x y:(int)y control:(BOOL)control shift:(BOOL)shift repeat:(int)repeat
    NS_SWIFT_NAME(setEvent(x:y:control:shift:repeat:));
- (void)setAltKey:(BOOL)alt;
- (void)invokeEvent:(IsiXVTKMouseEvent)event;
@property (nonatomic, readonly) BOOL lightFollowsCamera;

/// The display position of a world point (z its depth), and the world point
/// (homogeneous, w divided out) at a display position and depth.
- (IsiXVTKPoint)displayPointOfWorld:(IsiXVTKPoint)world NS_SWIFT_NAME(displayPoint(ofWorld:));
- (IsiXVTKPoint)worldPointOfDisplayX:(double)x y:(double)y z:(double)z NS_SWIFT_NAME(worldPoint(ofDisplayX:y:z:));

/// The point of `actors` vtkCellPicker finds at a display position with
/// `tolerance`, the actors made pickable for the pick and set back after it.
/// NO when the pick hits nothing; `world` holds the pick position either way.
- (BOOL)pickActors:(NSArray<IsiXVTKActor *> *)actors x:(double)x y:(double)y tolerance:(double)tolerance
             world:(IsiXVTKPoint *)world NS_SWIFT_NAME(pick(_:x:y:tolerance:world:));

/// What the overlay draws over this render: the renderer's visible 2D actors,
/// the orientation cube's rotation with `cube`, and the outline of `picked`.
- (nullable IsiXVTKOverlayFrame *)overlayFrameWithCube:(BOOL)cube picked:(nullable IsiXVTKActor *)picked
                                                 error:(NSError **)error
    NS_SWIFT_NAME(overlayFrame(cube:picked:));

/// The last frame, tightly packed top-down RGB, malloc'd for the caller to
/// free; with `stereo`, the two eyes side by side, left first.
- (nullable uint8_t *)copyFrameRGBWidth:(long *)width height:(long *)height stereo:(BOOL)stereo
    NS_SWIFT_NAME(copyFrameRGB(width:height:stereo:));

/// Writes the scene in `format` to `path`.
- (BOOL)exportFormat:(IsiXVTKSceneFormat)format toPath:(NSString *)path error:(NSError **)error
    NS_SWIFT_NAME(export(_:to:));
/// Writes the visible `actors`' surfaces to an STL file at `path`, in world
/// coordinates: STL has no actor transform, so each actor's matrix is applied
/// to its mapper's input, as the OBJ exporter places them.
+ (BOOL)writeSTLOfActors:(NSArray<IsiXVTKActor *> *)actors toPath:(NSString *)path error:(NSError **)error
    NS_SWIFT_NAME(writeSTL(of:to:));
@end

NS_ASSUME_NONNULL_END
