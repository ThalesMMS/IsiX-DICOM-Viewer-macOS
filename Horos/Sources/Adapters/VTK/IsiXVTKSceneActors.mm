//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The actors of the surface and ROI volume views and what builds them
// (IsiXVTKScene.h): spheres, 3D text, meshes, the Delaunay hull of an ROI's
// points, textures, text actors and the iso-surfaces of a volume.

#import "IsiXVTKSceneInternal.hpp"
#include "IsiXVTKSEGSurface.hpp"

#include <vtkActor.h>
#include <vtkCellArray.h>
#include <vtkCutter.h>
#include <vtkDataSetSurfaceFilter.h>
#include <vtkDecimatePro.h>
#include <vtkDelaunay3D.h>
#include <vtkContourFilter.h>
#include <vtkFollower.h>
#include <vtkImageData.h>
#include <vtkImageFlip.h>
#include <vtkImageImport.h>
#include <vtkImageResample.h>
#include <vtkOutlineFilter.h>
#include <vtkPlane.h>
#include <vtkPoints.h>
#include <vtkPolyData.h>
#include <vtkPolyDataMapper.h>
#include <vtkPolyDataNormals.h>
#include <vtkProperty.h>
#include <vtkRenderer.h>
#include <vtkSmoothPolyDataFilter.h>
#include <vtkSphereSource.h>
#include <vtkTIFFReader.h>
#include <vtkTextActor.h>
#include <vtkTextProperty.h>
#include <vtkTexture.h>
#include <vtkTextureMapToSphere.h>
#include <vtkUnstructuredGrid.h>
#include <vtkVectorText.h>
#include <vtkCoordinate.h>
#include <vtkMatrix4x4.h>

#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>

void IsiXVTKLogFailure(NSError *error)
{
    if (error) NSLog(@"---- VTK adapter: %@", error.localizedDescription);
}

/// Runs a setter's `body` in the guard, logging a failure.
template <typename Body>
static inline void IsiXVTKSet(const char *operation, std::initializer_list<vtkObject *> objects, Body &&body)
{
    NSError *error = nil;
    if (!IsiXVTKGuard(&error, operation, objects, [&]() -> NSError * { body(); return nil; }))
        IsiXVTKLogFailure(error);
}

@implementation IsiXVTKActor
{
    vtkActor *_actor;
    std::vector<vtkSmartPointer<vtkObject>> _pipeline;
}

- (instancetype)initWithActor:(vtkActor *)actor pipeline:(std::vector<vtkSmartPointer<vtkObject>>)pipeline
{
    if ((self = [super init])) {
        _actor = actor;
        _actor->Register(nullptr);
        _pipeline = std::move(pipeline);
    }
    return self;
}

- (void)dealloc
{
    _pipeline.clear();
    if (_actor) _actor->UnRegister(nullptr);
}

- (vtkActor *)actor { return _actor; }
- (void *)vtkActor { return _actor; }

- (BOOL)visible
{
    BOOL visible = NO;
    IsiXVTKSet("visible", {_actor}, [&] { visible = _actor->GetVisibility() != 0; });
    return visible;
}

- (void)setVisible:(BOOL)visible { IsiXVTKSet("setVisible", {_actor}, [&] { _actor->SetVisibility(visible); }); }

- (BOOL)pickable
{
    BOOL pickable = NO;
    IsiXVTKSet("pickable", {_actor}, [&] { pickable = _actor->GetPickable() != 0; });
    return pickable;
}

- (void)setPickable:(BOOL)pickable { IsiXVTKSet("setPickable", {_actor}, [&] { _actor->SetPickable(pickable); }); }

- (BOOL)dragable
{
    BOOL dragable = NO;
    IsiXVTKSet("dragable", {_actor}, [&] { dragable = _actor->GetDragable() != 0; });
    return dragable;
}

- (void)setDragable:(BOOL)dragable { IsiXVTKSet("setDragable", {_actor}, [&] { _actor->SetDragable(dragable); }); }

- (double)opacity
{
    double opacity = 1;
    IsiXVTKSet("opacity", {_actor}, [&] { opacity = _actor->GetProperty()->GetOpacity(); });
    return opacity;
}

- (void)setOpacity:(double)opacity
{
    IsiXVTKSet("setOpacity", {_actor}, [&] { _actor->GetProperty()->SetOpacity(opacity); });
}

- (void)setColorRed:(double)red green:(double)green blue:(double)blue
{
    IsiXVTKSet("setColor", {_actor}, [&] { _actor->GetProperty()->SetColor(red, green, blue); });
}

- (void)setDiffuseColorRed:(double)red green:(double)green blue:(double)blue
{
    IsiXVTKSet("setDiffuseColor", {_actor}, [&] { _actor->GetProperty()->SetDiffuseColor(red, green, blue); });
}

- (void)setSpecular:(double)specular power:(double)power
{
    IsiXVTKSet("setSpecular", {_actor}, [&] {
        _actor->GetProperty()->SetSpecular(specular);
        _actor->GetProperty()->SetSpecularPower(power);
    });
}

- (void)setAmbient:(double)ambient diffuse:(double)diffuse
{
    IsiXVTKSet("setAmbient", {_actor}, [&] {
        _actor->GetProperty()->SetAmbient(ambient);
        _actor->GetProperty()->SetDiffuse(diffuse);
    });
}

- (void)setFrontfaceCulling:(BOOL)front backfaceCulling:(BOOL)back
{
    IsiXVTKSet("setCulling", {_actor}, [&] {
        _actor->GetProperty()->SetFrontfaceCulling(front);
        _actor->GetProperty()->SetBackfaceCulling(back);
    });
}

- (void)setWireframe:(BOOL)wireframe
{
    IsiXVTKSet("setWireframe", {_actor}, [&] {
        if (wireframe) _actor->GetProperty()->SetRepresentationToWireframe();
        else _actor->GetProperty()->SetRepresentationToSurface();
    });
}

- (void)setOrigin:(IsiXVTKPoint)origin
{
    IsiXVTKSet("setOrigin", {_actor}, [&] { _actor->SetOrigin(origin.x, origin.y, origin.z); });
}

- (IsiXVTKPoint)position
{
    IsiXVTKPoint position = {0, 0, 0};
    IsiXVTKSet("position", {_actor}, [&] {
        double p[3];
        _actor->GetPosition(p);
        position = {p[0], p[1], p[2]};
    });
    return position;
}

- (void)setPosition:(IsiXVTKPoint)position
{
    IsiXVTKSet("setPosition", {_actor}, [&] { _actor->SetPosition(position.x, position.y, position.z); });
}

- (void)setUniformScale:(double)scale
{
    IsiXVTKSet("setScale", {_actor}, [&] { _actor->SetScale(scale); });
}

- (void)setUserMatrix:(const double *)rowMajor
{
    IsiXVTKSet("setUserMatrix", {_actor}, [&] {
        if (!rowMajor) {
            _actor->SetUserMatrix(nullptr);
            return;
        }
        vtkSmartPointer<vtkMatrix4x4> matrix = vtkSmartPointer<vtkMatrix4x4>::New();
        matrix->DeepCopy(rowMajor);
        _actor->SetUserMatrix(matrix);
    });
}

- (IsiXVTKBounds)bounds
{
    IsiXVTKBounds bounds = {0, 0, 0, 0, 0, 0};
    IsiXVTKSet("bounds", {_actor}, [&] {
        double *b = _actor->GetBounds();
        if (b) bounds = {b[0], b[1], b[2], b[3], b[4], b[5]};
    });
    return bounds;
}

- (void)setTexture:(IsiXVTKTexture *)texture
{
    IsiXVTKSet("setTexture", {_actor}, [&] { _actor->SetTexture(texture ? [texture texture] : nullptr); });
}

/// An actor of a mapper made by `make`, which returns the mapper (owned by
/// the caller) and fills the pipeline that builds its input.
template <typename Make>
static IsiXVTKActor *IsiXVTKMakeActor(NSError **error, const char *operation, Make &&make)
{
    IsiXVTKActor *made = nil;
    IsiXVTKGuard(error, operation, {}, [&]() -> NSError * {
        std::vector<vtkSmartPointer<vtkObject>> pipeline;
        vtkSmartPointer<vtkMapper> mapper = make(pipeline);
        vtkSmartPointer<vtkActor> actor = vtkSmartPointer<vtkActor>::New();
        actor->SetMapper(mapper);
        made = [[IsiXVTKActor alloc] initWithActor:actor pipeline:std::move(pipeline)];
        return nil;
    });
    return made;
}

+ (instancetype)emptyActorWithError:(NSError **)error
{
    IsiXVTKActor *made = nil;
    IsiXVTKGuard(error, "emptyActor", {}, [&]() -> NSError * {
        made = [[IsiXVTKActor alloc] initWithActor:vtkSmartPointer<vtkActor>::New() pipeline:{}];
        return nil;
    });
    return made;
}

+ (instancetype)sphereAt:(IsiXVTKPoint)centre radius:(double)radius error:(NSError **)error
{
    return IsiXVTKMakeActor(error, "sphere", [&](std::vector<vtkSmartPointer<vtkObject>> &) -> vtkSmartPointer<vtkMapper> {
        auto source = vtkSmartPointer<vtkSphereSource>::New();
        source->SetRadius(radius);
        source->SetCenter(centre.x, centre.y, centre.z);
        auto mapper = vtkSmartPointer<vtkPolyDataMapper>::New();
        mapper->SetInputConnection(source->GetOutputPort());
        mapper->Update();
        return mapper;
    });
}

- (BOOL)setSphereCentre:(IsiXVTKPoint)centre radius:(double)radius error:(NSError **)error
{
    return IsiXVTKGuard(error, "setSphere", {_actor}, [&]() -> NSError * {
        auto source = vtkSmartPointer<vtkSphereSource>::New();
        source->SetRadius(radius);
        source->SetCenter(centre.x, centre.y, centre.z);
        auto mapper = vtkSmartPointer<vtkPolyDataMapper>::New();
        mapper->SetInputConnection(source->GetOutputPort());
        mapper->Update();
        _actor->SetMapper(mapper);
        return nil;
    });
}

+ (instancetype)followerWithText:(NSString *)text error:(NSError **)error
{
    IsiXVTKActor *made = nil;
    IsiXVTKGuard(error, "follower", {}, [&]() -> NSError * {
        auto vector = vtkSmartPointer<vtkVectorText>::New();
        vector->SetText(text.UTF8String ?: "");
        // Connected by its port, the text is built whenever the mapper
        // updates: a mapper given the output object alone never runs it.
        auto mapper = vtkSmartPointer<vtkPolyDataMapper>::New();
        mapper->SetInputConnection(vector->GetOutputPort());
        auto follower = vtkSmartPointer<vtkFollower>::New();
        follower->SetMapper(mapper);
        made = [[IsiXVTKActor alloc] initWithActor:follower pipeline:{vector}];
        return nil;
    });
    return made;
}

- (void)followCameraOfScene:(IsiXVTKScene *)scene
{
    vtkRenderer *renderer = static_cast<vtkRenderer *>(scene.vtkRenderer);
    IsiXVTKSet("followCamera", {_actor}, [&] {
        if (vtkFollower *follower = vtkFollower::SafeDownCast(_actor))
            follower->SetCamera(renderer ? renderer->GetActiveCamera() : nullptr);
    });
}

+ (instancetype)meshWithVertices:(NSData *)vertices triangles:(NSData *)triangles error:(NSError **)error
{
    return IsiXVTKMakeActor(error, "mesh", [&](std::vector<vtkSmartPointer<vtkObject>> &) -> vtkSmartPointer<vtkMapper> {
        auto mapper = vtkSmartPointer<vtkPolyDataMapper>::New();
        mapper->SetInputData(HorosSEGSurfacePolyData(vertices, triangles));
        mapper->ScalarVisibilityOff();
        return mapper;
    });
}

+ (instancetype)sphereMappedMeshWithVertices:(NSData *)vertices triangles:(NSData *)triangles error:(NSError **)error
{
    return IsiXVTKMakeActor(error, "sphereMappedMesh", [&](std::vector<vtkSmartPointer<vtkObject>> &) -> vtkSmartPointer<vtkMapper> {
        vtkSmartPointer<vtkPolyData> mesh = HorosSEGSurfacePolyData(vertices, triangles);
        auto mapper = vtkSmartPointer<vtkPolyDataMapper>::New();
        mapper->ScalarVisibilityOff();
        // The filter refuses a mesh without points; an empty mesh stays as it is.
        if (mesh->GetNumberOfPoints() == 0) {
            mapper->SetInputData(mesh);
            return mapper;
        }
        auto texture = vtkSmartPointer<vtkTextureMapToSphere>::New();
        texture->SetInputData(mesh);
        texture->PreventSeamOn();
        texture->Update();
        mapper->SetInputConnection(texture->GetOutputPort());
        return mapper;
    });
}

+ (instancetype)delaunayHullOfPoints:(NSData *)points error:(NSError **)error
{
    return IsiXVTKMakeActor(error, "delaunayHull", [&](std::vector<vtkSmartPointer<vtkObject>> &) -> vtkSmartPointer<vtkMapper> {
        auto vertices = vtkSmartPointer<vtkPoints>::New();
        const double *xyz = static_cast<const double *>(points.bytes);
        const NSUInteger count = points.length / (3 * sizeof(double));
        for (NSUInteger i = 0; i < count; i++)
            vertices->InsertPoint(static_cast<vtkIdType>(i), xyz[3 * i], xyz[3 * i + 1], xyz[3 * i + 2]);
        auto profile = vtkSmartPointer<vtkPolyData>::New();
        profile->SetPoints(vertices);

        auto triangulator = vtkSmartPointer<vtkDelaunay3D>::New();
        triangulator->SetInputData(profile);
        triangulator->SetTolerance(0.001);
        triangulator->SetAlpha(20);
        triangulator->BoundingTriangulationOff();
        triangulator->Update();

        auto texture = vtkSmartPointer<vtkTextureMapToSphere>::New();
        texture->SetInputData(static_cast<vtkDataSet *>(triangulator->GetOutput()));
        texture->PreventSeamOn();
        texture->Update();

        // The hull's outer faces as polygons, their texture coordinates kept:
        // the scene draws a mapper's input only when it is polygonal data, so
        // the tetrahedra themselves behind a vtkDataSetMapper drew nothing.
        auto faces = vtkSmartPointer<vtkDataSetSurfaceFilter>::New();
        faces->SetInputConnection(texture->GetOutputPort());
        faces->Update();

        auto mapper = vtkSmartPointer<vtkPolyDataMapper>::New();
        mapper->SetInputConnection(faces->GetOutputPort());
        mapper->ScalarVisibilityOff();
        mapper->Update();
        return mapper;
    });
}

- (NSArray<NSData *> *)sectionsByPlaneThrough:(IsiXVTKPoint)origin normal:(IsiXVTKPoint)normal error:(NSError **)error
{
    NSMutableArray<NSData *> *sections = [NSMutableArray array];
    BOOL cut = IsiXVTKGuard(error, "sections", {_actor}, [&]() -> NSError * {
        vtkMapper *mapper = _actor->GetMapper();
        vtkPolyData *mesh = mapper ? vtkPolyData::SafeDownCast(mapper->GetInputDataObject(0, 0)) : nullptr;
        if (!mesh) return nil;
        const double point[3] = {origin.x, origin.y, origin.z}, direction[3] = {normal.x, normal.y, normal.z};
        vtkSmartPointer<vtkPolyData> cutOutput = HorosSEGSurfaceCut(mesh, point, direction);
        vtkPolyData *output = cutOutput;
        vtkIdType count;
        const vtkIdType *ids;
        std::vector<double> line;
        vtkCellArray *lines = output->GetLines();
        if (!lines) return nil;
        for (lines->InitTraversal(); lines->GetNextCell(count, ids);) {
            line.clear();
            for (vtkIdType index = 0; index < count; ++index) {
                double p[3];
                output->GetPoint(ids[index], p);
                line.insert(line.end(), p, p + 3);
            }
            [sections addObject:[NSData dataWithBytes:line.data() length:line.size() * sizeof(double)]];
        }
        return nil;
    });
    return cut ? sections : nil;
}

- (IsiXVTKActor *)actorSharingInputWithError:(NSError **)error
{
    vtkMapper *source = _actor->GetMapper();
    return IsiXVTKMakeActor(error, "actorSharingInput", [&](std::vector<vtkSmartPointer<vtkObject>> &) -> vtkSmartPointer<vtkMapper> {
        auto mapper = vtkSmartPointer<vtkPolyDataMapper>::New();
        mapper->SetInputData(source ? vtkPolyData::SafeDownCast(source->GetInputDataObject(0, 0)) : nullptr);
        mapper->ScalarVisibilityOff();
        return mapper;
    });
}

@end

@implementation IsiXVTKTexture
{
    vtkSmartPointer<vtkTexture> _texture;
}

- (vtkTexture *)texture { return _texture; }

+ (instancetype)textureWithTIFFAtPath:(NSString *)path connected:(BOOL)connected error:(NSError **)error
{
    IsiXVTKTexture *made = [[IsiXVTKTexture alloc] init];
    BOOL built = IsiXVTKGuard(error, "texture", {}, [&]() -> NSError * {
        auto reader = vtkSmartPointer<vtkTIFFReader>::New();
        reader->SetFileName(path.UTF8String);
        // The reader reads the file before the texture takes its output: a
        // texture given the output object alone never runs the reader.
        reader->Update();
        auto texture = vtkSmartPointer<vtkTexture>::New();
        if (connected) {
            texture->SetInputConnection(reader->GetOutputPort());
            texture->InterpolateOn();
        } else {
            texture->InterpolateOn();
            texture->SetRepeat(1);
            texture->SetInputConnection(reader->GetOutputPort());
            texture->Update();
        }
        made->_texture = texture;
        return nil;
    });
    return built ? made : nil;
}

@end

@implementation IsiXVTKTextActor
{
    vtkSmartPointer<vtkTextActor> _text;
}

- (vtkTextActor *)textActor { return _text; }

- (instancetype)initWithText:(NSString *)text
{
    if ((self = [super init])) {
        IsiXVTKSet("textActor", {}, [&] {
            _text = vtkSmartPointer<vtkTextActor>::New();
            _text->SetInput(text.UTF8String ?: "");
            _text->SetTextScaleModeToNone();
        });
        if (!_text) return nil;
    }
    return self;
}

- (void)setText:(NSString *)text
{
    IsiXVTKSet("setText", {_text}, [&] { _text->SetInput(text.UTF8String ?: ""); });
}

- (void)setPositionX:(double)x y:(double)y normalized:(BOOL)normalized
{
    IsiXVTKSet("setTextPosition", {_text}, [&] {
        if (normalized) _text->GetPositionCoordinate()->SetCoordinateSystemToNormalizedViewport();
        else _text->GetPositionCoordinate()->SetCoordinateSystemToViewport();
        _text->GetPositionCoordinate()->SetValue(x, y);
    });
}

- (void)setFontSize:(int)size bold:(BOOL)bold shadowOffset:(int)shadow
{
    IsiXVTKSet("setTextFont", {_text}, [&] {
        _text->GetTextProperty()->SetFontSize(size);
        _text->GetTextProperty()->SetBold(bold);
        _text->GetTextProperty()->SetShadow(shadow != 0);
        _text->GetTextProperty()->SetShadowOffset(shadow, shadow);
    });
}

- (void)setJustification:(int)horizontal vertical:(int)vertical
{
    IsiXVTKSet("setTextJustification", {_text}, [&] {
        _text->GetTextProperty()->SetJustification(horizontal);
        _text->GetTextProperty()->SetVerticalJustification(vertical);
    });
}

@end

@implementation IsiXVTKIsoSurfaceSource
{
    vtkSmartPointer<vtkImageImport> _reader;
    vtkSmartPointer<vtkImageFlip> _flip;
    vtkSmartPointer<vtkImageResample> _resample;
}

/// What the surfaces are built from: the flipped slices, or the imported ones.
- (vtkAlgorithmOutput *)volumePort
{
    return _flip ? _flip->GetOutputPort() : _reader->GetOutputPort();
}

- (instancetype)initWithVoxels:(const float *)voxels width:(NSInteger)width height:(NSInteger)height depth:(NSInteger)depth
                      spacingX:(double)spacingX spacingY:(double)spacingY spacingZ:(double)spacingZ flip:(BOOL)flip
                         error:(NSError **)error
{
    if (!(self = [super init])) return nil;
    BOOL built = IsiXVTKGuard(error, "isoSurfaceSource", {}, [&]() -> NSError * {
        if (!voxels || width <= 0 || height <= 0 || depth <= 0)
            return IsiXVTKFailure(IsiXVTKErrorCodeInvalidArgument, @"no voxels to import", "isoSurfaceSource");
        _reader = vtkSmartPointer<vtkImageImport>::New();
        _reader->SetWholeExtent(0, (int)width - 1, 0, (int)height - 1, 0, (int)depth - 1);
        _reader->SetDataExtentToWholeExtent();
        _reader->SetDataScalarTypeToFloat();
        _reader->SetImportVoidPointer(const_cast<float *>(voxels));
        _reader->SetDataSpacing(spacingX, spacingY, spacingZ);
        if (flip) {
            _flip = vtkSmartPointer<vtkImageFlip>::New();
            _flip->SetInputConnection(_reader->GetOutputPort());
            _flip->SetFlipAboutOrigin(true);
            _flip->SetFilteredAxis(2);
            _flip->Update();
        }
        return nil;
    });
    return built ? self : nil;
}

- (IsiXVTKActor *)surfaceAtValue:(double)isoValue resolution:(double)resolution decimate:(BOOL)decimate
                       reduction:(double)reduction smooth:(BOOL)smooth iterations:(NSInteger)iterations error:(NSError **)error
{
    IsiXVTKActor *made = nil;
    IsiXVTKGuard(error, "isoSurface", {}, [&]() -> NSError * {
        // vtkImageResample asserts on a magnification factor of 0: a
        // resolution that is not a positive finite number is refused here.
        if (!(resolution > 0) || !std::isfinite(resolution))
            return IsiXVTKFailure(IsiXVTKErrorCodeInvalidArgument, @"the resolution is not a positive number",
                                  "isoSurface");
        // The resampled slices are kept for the next surface; a resolution of
        // 1 drops them.
        if (resolution == 1.0) _resample = nullptr;
        else if (_resample) {
            if (_resample->GetAxisMagnificationFactor(0) != resolution) {
                _resample->SetAxisMagnificationFactor(0, resolution);
                _resample->SetAxisMagnificationFactor(1, resolution);
            }
        } else {
            _resample = vtkSmartPointer<vtkImageResample>::New();
            _resample->SetInputConnection([self volumePort]);
            _resample->SetAxisMagnificationFactor(0, resolution);
            _resample->SetAxisMagnificationFactor(1, resolution);
            _resample->Update();
        }

        std::vector<vtkSmartPointer<vtkObject>> pipeline;
        auto extractor = vtkSmartPointer<vtkContourFilter>::New();
        extractor->SetInputConnection(_resample ? _resample->GetOutputPort() : [self volumePort]);
        extractor->SetValue(0, isoValue);
        extractor->Update();
        pipeline.push_back(extractor);
        vtkPolyData *previous = extractor->GetOutput();

        if (decimate) {
            auto decimation = vtkSmartPointer<vtkDecimatePro>::New();
            decimation->SetInputData(previous);
            decimation->SetTargetReduction(reduction);
            decimation->SetPreserveTopology(true);
            decimation->Update();
            pipeline.push_back(decimation);
            previous = decimation->GetOutput();
        }
        if (smooth) {
            auto smoother = vtkSmartPointer<vtkSmoothPolyDataFilter>::New();
            smoother->SetInputData(previous);
            smoother->SetNumberOfIterations((int)iterations);
            smoother->Update();
            pipeline.push_back(smoother);
            previous = smoother->GetOutput();
        }

        auto normals = vtkSmartPointer<vtkPolyDataNormals>::New();
        normals->SetInputData(previous);
        normals->SetFeatureAngle(120);
        pipeline.push_back(normals);
        auto mapper = vtkSmartPointer<vtkPolyDataMapper>::New();
        mapper->SetInputConnection(normals->GetOutputPort());
        mapper->ScalarVisibilityOff();
        mapper->Update();

        auto actor = vtkSmartPointer<vtkActor>::New();
        actor->SetMapper(mapper);
        actor->PickableOff();
        made = [[IsiXVTKActor alloc] initWithActor:actor pipeline:std::move(pipeline)];
        return nil;
    });
    return made;
}

- (IsiXVTKActor *)outlineWithError:(NSError **)error
{
    IsiXVTKActor *made = nil;
    IsiXVTKGuard(error, "outline", {}, [&]() -> NSError * {
        auto outline = vtkSmartPointer<vtkOutlineFilter>::New();
        outline->SetInputConnection([self volumePort]);
        outline->Update();
        auto mapper = vtkSmartPointer<vtkPolyDataMapper>::New();
        mapper->SetInputConnection(outline->GetOutputPort());
        mapper->Update();
        auto actor = vtkSmartPointer<vtkActor>::New();
        actor->SetMapper(mapper);
        actor->GetProperty()->SetColor(0, 1, 0);
        actor->GetProperty()->SetOpacity(0.5);
        actor->PickableOff();
        made = [[IsiXVTKActor alloc] initWithActor:actor pipeline:{outline}];
        return nil;
    });
    return made;
}

@end
