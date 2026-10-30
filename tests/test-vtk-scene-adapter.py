#!/usr/bin/env python3
"""The VTK adapter of the surface views turns VTK's errors and C++ exceptions into NSError.

The surface rendering, the ROI volume and the SEG surfaces' views are Swift
(SRView, ROIVolumeView, ViewerSEGSurface.swift, over HorosSceneView); what they
do with VTK is in Horos/Sources/Adapters/VTK: IsiXVTKScene (the renderer, its
window and interactor, the camera, picks, the 2D layer's frame, the exports),
the actors and what builds them (IsiXVTKSceneActors.mm: spheres, meshes, the
Delaunay hull, the iso-surfaces of a volume, sections by a plane) and the
overlay's reading of the 2D actors (IsiXVTKSceneOverlay). Their headers carry
no C++ type; every call into VTK runs inside a guard.

The adapter's files are compiled here against the VTK the Debug build installed
(exit 2 without that build), with a driver that:
- builds a sphere, a voxel cube mesh (and refuses a mesh whose triangles name
  missing points), an iso-surface and its outline from a small volume, and cuts
  the cube by a plane on its face into its section;
- makes the textures of the app's TIFF texture, connected and not, and a
  follower's 3D text: the TIFF reader and the vector text have run before
  anything renders them (a mapper or texture given an output object alone
  never runs the algorithm that makes it);
- puts the texture on the two surfaces of the ROI volume view, the Iso Contour
  mesh (made with texture coordinates mapped onto a sphere) and the Delaunay
  hull, renders each in a scene whose frame presenter records what it is
  asked to draw, and checks each reaches the presenter as a mesh carrying the
  texture. A mesh made without texture coordinates is drawn without it: the
  Metal presenter draws a texture only through the surface's coordinates, and
  only a surface whose mapper input is polygonal data;
- writes the visible actors to an STL file and reads it back: the hidden one is
  left out;
- makes a scene, adds and removes an actor, and moves its camera;
- provokes a VTK error: the STL writer asked to write into a folder that does
  not exist reports it (vtkErrorMacro), an NSError of IsiXVTKErrorDomain with
  VTK's message and the writer's class;
- provokes a C++ exception: an observer of the cube's mapper throws when the
  writer brings it up to date; the exception crosses VTK and comes back as an
  NSError (Exception, with its text) instead of terminating the process;
- asks for what the adapter refuses itself: a volume without voxels, an
  iso-surface at a resolution that is not a positive number (vtkImageResample
  asserts on a factor of 0), a 2D layer of a window without a size and an
  unknown export format, each with its code.
"""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'Horos/Sources'
ADAPTER = SOURCES / 'Adapters/VTK'
CONFIGURATION = 'Debug'
INSTALL = next((base / 'Intermediates.noindex/Horos.build' / CONFIGURATION / 'VTK.build/Install'
                for base in (ROOT / 'build', ROOT / 'build/Build')
                if (base / 'Intermediates.noindex/Horos.build' / CONFIGURATION / 'VTK.build/Install/wlib/libVTK.a').is_file()), None)
if INSTALL is None:
    print('skipped: needs the VTK of a Debug build from script/build_and_run.sh --verify')
    sys.exit(2)

DRIVER = r'''
#import <Foundation/Foundation.h>
#import "IsiXVTKScene.h"
#import "IsiXVTKFramePresenter.h"
#import "IsiXVTKSceneOverlay.h"
#import "IsiXVTKInternal.hpp"
#import "IsiXVTKSceneInternal.hpp"
#include <vtkActor.h>
#include <vtkImageData.h>
#include <vtkTexture.h>
#include <vtkCallbackCommand.h>
#include <vtkCommand.h>
#include <vtkMapper.h>
#include <vtkPolyData.h>
#include <vtkSTLReader.h>
#include <vtkSmartPointer.h>
#include <cmath>
#include <cstdio>
#include <stdexcept>
#include <vector>

static int failures = 0;
static void check(bool condition, const char *what)
{
    printf("%s: %s\n", condition ? "PASS" : "FAIL", what);
    if (!condition) failures++;
}
static bool isError(NSError *error, IsiXVTKErrorCode code)
{
    return [error.domain isEqualToString:IsiXVTKErrorDomain] && error.code == code && error.userInfo[IsiXVTKOperationKey];
}
static bool near(double a, double b) { return std::fabs(a - b) < 1e-6; }

/// A frame presenter that only counts the meshes it is asked to draw, and
/// those that come with a texture.
@interface IsiXRecordingPresenter : NSObject <IsiXVTKFramePresenter>
@property (nonatomic) NSInteger meshes, textured;
@end

@implementation IsiXRecordingPresenter
- (BOOL)beginWithWidth:(NSInteger)width height:(NSInteger)height red:(double)red green:(double)green blue:(double)blue { return YES; }
- (void)drawMeshWithVertices:(NSData *)vertices indices:(NSData *)indices uniforms:(NSData *)uniforms
                     texture:(NSData *)texture textureWidth:(NSInteger)textureWidth
               textureHeight:(NSInteger)textureHeight translucent:(BOOL)translucent cull:(NSInteger)cull
                   wireframe:(BOOL)wireframe
{
    self.meshes++;
    if (texture.length == (NSUInteger)(textureWidth * textureHeight * 4) && textureWidth > 1 && textureHeight > 1) self.textured++;
}
- (void)drawLinesWithVertices:(NSData *)vertices indices:(NSData *)indices uniforms:(NSData *)uniforms translucent:(BOOL)translucent {}
- (void)compositeTranslucent {}
- (void)drawImageWithPixels:(const void *)pixels memoryWidth:(NSInteger)memoryWidth memoryHeight:(NSInteger)memoryHeight
                  usedWidth:(NSInteger)usedWidth usedHeight:(NSInteger)usedHeight originX:(NSInteger)originX
                    originY:(NSInteger)originY viewportWidth:(NSInteger)viewportWidth viewportHeight:(NSInteger)viewportHeight
                      depth:(double)depth scale:(double)scale {}
- (void)finish {}
- (void)present {}
- (BOOL)copyFrameInto:(id<IsiXVTKFramePresenter>)other { return NO; }
- (void)exchangeFrameWith:(id<IsiXVTKFramePresenter>)other {}
- (BOOL)readDepthWithX:(NSInteger)x y:(NSInteger)y width:(NSInteger)width height:(NSInteger)height into:(float *)values { return NO; }
- (NSData *)readPixelsWithX:(NSInteger)x y:(NSInteger)y width:(NSInteger)width height:(NSInteger)height alpha:(BOOL)alpha { return nil; }
- (BOOL)writePixels:(NSData *)data x:(NSInteger)x y:(NSInteger)y width:(NSInteger)width height:(NSInteger)height alpha:(BOOL)alpha { return NO; }
@end

/// What a scene of `actor` alone, wearing `texture`, asks its presenter to draw.
static IsiXRecordingPresenter *rendered(IsiXVTKActor *actor, IsiXVTKTexture *texture)
{
    NSError *error = nil;
    IsiXVTKScene *scene = [[IsiXVTKScene alloc] initWithError:&error];
    IsiXRecordingPresenter *presenter = [IsiXRecordingPresenter new];
    [scene setWidth:64 height:64];
    [scene setPresenter:presenter];
    [actor setTexture:texture];
    [scene addActor:actor];
    [scene resetCamera];
    if (![scene renderWithError:&error]) printf("  render: %s\n", error.description.UTF8String);
    [scene removeActor:actor];
    [actor setTexture:nil];
    return presenter;
}

/// The twelve triangles of the unit cube.
static void cube(NSData **vertices, NSData **triangles)
{
    double points[8][3];
    for (int i = 0; i < 8; i++) { points[i][0] = i & 1; points[i][1] = (i >> 1) & 1; points[i][2] = (i >> 2) & 1; }
    uint64_t faces[12][3] = {{0,2,1},{1,2,3},{4,5,6},{5,7,6},{0,1,4},{1,5,4},{2,6,3},{3,6,7},{0,4,2},{2,4,6},{1,3,5},{3,7,5}};
    *vertices = [NSData dataWithBytes:points length:sizeof(points)];
    *triangles = [NSData dataWithBytes:faces length:sizeof(faces)];
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        NSString *folder = [NSString stringWithUTF8String:argv[1]];
        NSError *error = nil;

        IsiXVTKActor *sphere = [IsiXVTKActor sphereAt:(IsiXVTKPoint){1, 2, 3} radius:2 error:&error];
        IsiXVTKBounds b = sphere.bounds;
        // Its poles are on the axis; its equator, a polygon, within a tenth of the radius.
        check(sphere && !error && near(b.zmin, 1) && near(b.zmax, 5) && std::fabs(b.xmin + 1) < 0.2 && std::fabs(b.xmax - 3) < 0.2,
              "a sphere is where it was asked, as large");

        NSData *vertices, *triangles;
        cube(&vertices, &triangles);
        IsiXVTKActor *mesh = [IsiXVTKActor meshWithVertices:vertices triangles:triangles error:&error];
        b = mesh.bounds;
        check(mesh && near(b.xmin, 0) && near(b.xmax, 1) && near(b.ymax, 1) && near(b.zmax, 1), "a mesh has its vertices' bounds");
        NSArray<NSData *> *sections = [mesh sectionsByPlaneThrough:(IsiXVTKPoint){0, 0, 0} normal:(IsiXVTKPoint){0, 0, 1} error:&error];
        double length = 0;
        for (NSData *line in sections) {
            const double *p = (const double *)line.bytes;
            for (NSUInteger i = 1; i < line.length / (3 * sizeof(double)); i++)
                length += std::hypot(p[3 * i] - p[3 * i - 3], p[3 * i + 1] - p[3 * i - 2]);
        }
        check(sections.count > 0 && near(length, 4), "the cut on the cube's face is the section just past it");
        check([mesh sectionsByPlaneThrough:(IsiXVTKPoint){0, 0, 0.5} normal:(IsiXVTKPoint){0, 0, 0} error:&error].count == 0,
              "a plane without a normal cuts nothing");
        uint64_t wrong[3] = {0, 1, 99};
        IsiXVTKActor *refused = [IsiXVTKActor meshWithVertices:vertices triangles:[NSData dataWithBytes:wrong length:sizeof(wrong)]
                                                         error:&error];
        check(refused && [refused sectionsByPlaneThrough:(IsiXVTKPoint){0, 0, 0.5} normal:(IsiXVTKPoint){0, 0, 1} error:&error].count == 0,
              "a mesh whose triangles name missing points is empty");

        std::vector<float> voxels(8 * 8 * 8, 0);
        for (int z = 0; z < 8; z++) for (int y = 0; y < 8; y++) for (int x = 0; x < 8; x++)
            if ((x - 3.5) * (x - 3.5) + (y - 3.5) * (y - 3.5) + (z - 3.5) * (z - 3.5) < 6) voxels[(z * 8 + y) * 8 + x] = 100;
        IsiXVTKIsoSurfaceSource *source = [[IsiXVTKIsoSurfaceSource alloc] initWithVoxels:voxels.data() width:8 height:8 depth:8
                                                                                 spacingX:1 spacingY:1 spacingZ:2 flip:NO error:&error];
        IsiXVTKActor *surface = [source surfaceAtValue:50 resolution:1 decimate:NO reduction:0 smooth:NO iterations:0 error:&error];
        b = surface.bounds;
        check(source && surface && b.xmin > 0 && b.xmax < 7 && b.zmax > b.xmax, "an iso-surface of a volume, its spacing applied");
        check([source outlineWithError:&error] != nil, "and the volume's outline");
        error = nil;
        check([[IsiXVTKIsoSurfaceSource alloc] initWithVoxels:NULL width:8 height:8 depth:8 spacingX:1 spacingY:1 spacingZ:1
                                                         flip:NO error:&error] == nil && isError(error, IsiXVTKErrorCodeInvalidArgument),
              "a volume without voxels is IsiXVTKErrorCodeInvalidArgument");
        for (double resolution : {0.0, -0.5, std::nan("")}) {
            error = nil;
            check([source surfaceAtValue:50 resolution:resolution decimate:NO reduction:0 smooth:NO iterations:0 error:&error] == nil
                      && isError(error, IsiXVTKErrorCodeInvalidArgument),
                  "a resolution that is not a positive number is IsiXVTKErrorCodeInvalidArgument, before VTK resamples by it");
        }
        error = nil;
        check([source surfaceAtValue:50 resolution:0.5 decimate:NO reduction:0 smooth:NO iterations:0 error:&error] != nil && !error,
              "and the source still builds a resampled surface afterwards");

        // The inputs that readers build: the texture's image and the text's
        // polygons are there as soon as the texture and the follower are made,
        // before anything renders them.
        NSString *tiff = [folder stringByAppendingPathComponent:@"texture.tif"];
        for (BOOL connected : {YES, NO}) {
            error = nil;
            IsiXVTKTexture *texture = [IsiXVTKTexture textureWithTIFFAtPath:tiff connected:connected error:&error];
            int dimensions[3] = {0, 0, 0};
            if (texture && [texture texture]->GetInput()) [texture texture]->GetInput()->GetDimensions(dimensions);
            check(texture && !error && dimensions[0] > 1 && dimensions[1] > 1,
                  connected ? "a connected texture holds the TIFF the reader read" : "an unconnected texture holds the TIFF the reader read");
        }
        // The texture of the ROI volume view on its two surfaces: the Iso
        // Contour mesh and the Delaunay hull of points on a sphere.
        error = nil;
        IsiXVTKTexture *water = [IsiXVTKTexture textureWithTIFFAtPath:tiff connected:NO error:&error];
        IsiXVTKActor *contour = [IsiXVTKActor sphereMappedMeshWithVertices:vertices triangles:triangles error:&error];
        std::vector<double> ball;
        for (int i = 0; i <= 8; i++) for (int j = 0; j < 12; j++) {
            double polar = M_PI * i / 8, azimuth = 2 * M_PI * j / 12;
            ball.insert(ball.end(), {5 * std::sin(polar) * std::cos(azimuth), 5 * std::sin(polar) * std::sin(azimuth), 5 * std::cos(polar)});
        }
        IsiXVTKActor *hull = [IsiXVTKActor delaunayHullOfPoints:[NSData dataWithBytes:ball.data() length:ball.size() * sizeof(double)]
                                                          error:&error];
        b = contour.bounds;
        check(water && contour && hull && !error && near(b.xmin, 0) && near(b.xmax, 1), "the ROI volume's two surfaces and the texture are made");
        IsiXRecordingPresenter *drawn = rendered(contour, water);
        check(drawn.meshes == 1 && drawn.textured == 1, "the Iso Contour mesh reaches the presenter with the texture");
        drawn = rendered(hull, water);
        check(drawn.meshes == 1 && drawn.textured == 1, "the Delaunay hull reaches the presenter, with the texture");
        b = hull.bounds;
        check(b.xmax - b.xmin > 9 && b.zmax - b.zmin > 9, "the hull spans the points");
        drawn = rendered(mesh, water);
        check(drawn.meshes == 1 && drawn.textured == 0, "a mesh without texture coordinates is drawn without the texture");

        IsiXVTKActor *text = [IsiXVTKActor followerWithText:@"x: 1 mm" error:&error];
        b = text.bounds;
        check(text && b.xmax > b.xmin + 1 && b.ymax > b.ymin, "a follower's text has its polygons, and their bounds");

        NSString *stl = [folder stringByAppendingPathComponent:@"surfaces.stl"];
        sphere.visible = NO;
        error = nil;
        check([IsiXVTKScene writeSTLOfActors:@[mesh, sphere] toPath:stl error:&error] && !error, "the visible surfaces are written to STL");
        auto reader = vtkSmartPointer<vtkSTLReader>::New();
        reader->SetFileName(stl.UTF8String);
        reader->Update();
        check(reader->GetOutput()->GetNumberOfPolys() == 12, "the STL holds the cube's twelve triangles, not the hidden sphere");

        IsiXVTKScene *scene = [[IsiXVTKScene alloc] initWithError:&error];
        check(scene != nil, "a scene is made");
        [scene addActor:mesh];
        check([scene containsActor:mesh], "an actor is added to it");
        [scene removeActor:mesh];
        check(![scene containsActor:mesh], "and removed");
        scene.camera.position = (IsiXVTKPoint){0, 0, 50};
        scene.camera.focalPoint = (IsiXVTKPoint){0, 0, 0};
        check(near(scene.camera.distance, 50), "its camera moves");
        error = nil;
        check([scene overlayFrameWithCube:YES picked:nil error:&error] == nil && isError(error, IsiXVTKErrorCodeUnavailable),
              "a window without a size has no 2D layer: IsiXVTKErrorCodeUnavailable");
        error = nil;
        check(![scene exportFormat:(IsiXVTKSceneFormat)99 toPath:stl error:&error] && isError(error, IsiXVTKErrorCodeInvalidArgument),
              "an unknown export format is IsiXVTKErrorCodeInvalidArgument");

        // A VTK error: the writer cannot open its file.
        error = nil;
        check(![IsiXVTKScene writeSTLOfActors:@[mesh] toPath:[folder stringByAppendingPathComponent:@"missing/surfaces.stl"] error:&error] &&
              isError(error, IsiXVTKErrorCodeLibrary) && [error.userInfo[IsiXVTKClassKey] isEqualToString:@"vtkSTLWriter"],
              "the writer's refusal is IsiXVTKErrorCodeLibrary, with VTK's message and class");
        printf("  %s\n", [error.userInfo[IsiXVTKMessageKey] UTF8String]);

        // A C++ exception out of an observer, through VTK.
        vtkMapper *mapper = static_cast<vtkActor *>(mesh.vtkActor)->GetMapper();
        auto thrower = vtkSmartPointer<vtkCallbackCommand>::New();
        thrower->SetCallback([](vtkObject *, unsigned long, void *, void *) { throw std::runtime_error("observer refused"); });
        unsigned long tag = mapper->AddObserver(vtkCommand::StartEvent, thrower);
        mapper->Modified();
        error = nil;
        check(![IsiXVTKScene writeSTLOfActors:@[mesh] toPath:stl error:&error] && isError(error, IsiXVTKErrorCodeException) &&
              [error.userInfo[IsiXVTKMessageKey] isEqualToString:@"observer refused"],
              "an exception out of VTK is an NSError, not a terminated process");
        mapper->RemoveObserver(tag);
        mapper->Modified();
        check([IsiXVTKScene writeSTLOfActors:@[mesh] toPath:stl error:&error], "and the adapter keeps working afterwards");
    }
    printf("%d failure(s)\n", failures);
    return failures ? 1 : 0;
}
'''

with tempfile.TemporaryDirectory() as folder:
    folder = Path(folder)
    (folder / 'driver.mm').write_text(DRIVER)
    shutil.copyfile(ROOT / 'Horos/Resources/Icons/texture.tif', folder / 'texture.tif')
    sources = [folder / 'driver.mm', ADAPTER / 'IsiXVTKError.mm', ADAPTER / 'IsiXVTKScene.mm',
               ADAPTER / 'IsiXVTKSceneActors.mm', ADAPTER / 'IsiXVTKSceneOverlay.mm',
               ADAPTER / 'IsiXVTKVolumePresentation.mm', ADAPTER / 'IsiXVTKVolumeInteraction.mm']
    plain = [SOURCES / 'Adapters/VTK/vtkHorosFixedPointVolumeRayCastMapper.cxx', SOURCES / 'Adapters/VTK/vtkHorosFixedPointVolumeRayCastMIPHelper.cxx',
             SOURCES / 'Adapters/VTK/SceneFactory.cxx']
    objects = []
    for index, source in enumerate(sources + plain):
        output = folder / f'{index}.o'
        language = ['-x', 'objective-c++', '-fobjc-arc'] if source.suffix == '.mm' else ['-x', 'c++']
        # Only the adapter's own folder and the app's VTK subclasses are on
        # the path: the adapter includes nothing else of the app.
        compiled = subprocess.run(['xcrun', 'clang++', '-std=c++17', *language, '-c', '-I' + str(INSTALL / 'include'),
                                   '-I' + str(ADAPTER), '-iquote', str(SOURCES), str(source), '-o', str(output)],
                                  capture_output=True, text=True)
        if compiled.returncode != 0:
            print(compiled.stderr[-4000:], file=sys.stderr)
            print('FAIL: ' + source.name + ' does not compile on its own against VTK', file=sys.stderr)
            sys.exit(1)
        objects.append(str(output))
    # The texture reader and the image writers VTK links take the libraries
    # the build installed beside it.
    external = INSTALL.parent.parent / 'ExternalInputs.build/Install/lib'
    linked = subprocess.run(['xcrun', 'clang++', *objects, str(INSTALL / 'wlib/libVTK.a'), '-L' + str(external),
                             '-lpng16', '-ltiff', '-Wl,-rpath,' + str(external), '-lz', '-framework', 'Foundation',
                             '-framework', 'AppKit', '-o', str(folder / 'driver')], capture_output=True, text=True)
    if linked.returncode != 0:
        print(linked.stderr[-4000:], file=sys.stderr)
        sys.exit(1)
    try:
        run = subprocess.run([str(folder / 'driver'), str(folder)], capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        print('FAIL: the driver did not finish within 60 s', file=sys.stderr)
        sys.exit(1)
    print(run.stdout, end='')
    if run.returncode != 0:
        print(run.stderr[-2000:], file=sys.stderr)
        sys.exit(1)
print('PASS: the surface views reach VTK through the adapter; a VTK error and a C++ exception are NSErrors')
