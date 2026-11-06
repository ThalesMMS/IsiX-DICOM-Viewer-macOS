#!/usr/bin/env python3
"""The VTK adapter of the 3D view turns VTK's errors and C++ exceptions into NSError.

Horos/Sources/Adapters/VTK holds the Objective-C++ through which the 3D view's
Metal host (VRView+VolumeHost.swift) reads VTK: IsiXVTKVolumeScene, whose
header carries no C++ type, reads the camera, the mapper, the volume, its
property and transfer functions as values and writes Metal's picture back into
the mapper's ray-cast image; IsiXVTKOverlayObserver hides a renderer's 2D
actors from VTK's render and hands them back after it. The render window, the
renderer, the interactor and the crop box (IsiXVTKVolumePresentation,
IsiXVTKVolumeInteraction) are part of the adapter too and draw only through
its protocols (IsiXVTKFramePresenter, IsiXVTKLineCanvas), with nothing of the
app. Swift cannot catch a C++ exception, so every call into VTK runs inside a
guard that turns one into an NSError, as it does with an error VTK reports for
one of the call's objects (vtkErrorMacro, sent as the object's ErrorEvent).

The adapter's files, the app's ray-cast mapper and the scene factory are
compiled here against the VTK the Debug build installed (exit 2 without that
build), with a driver that:
- reads a scene's camera, sampling, placement, lights, tables and ray-cast
  image as VTK holds them;
- provokes a VTK error: the mapper's tables brought up to date without an
  input ("No Input!"), an NSError of IsiXVTKErrorDomain with VTK's message and
  the mapper's class, and the error observer gone after the call;
- provokes a C++ exception inside two adapter calls (a light enumeration and
  an access to the ray-cast image) and receives each as an NSError of
  IsiXVTKErrorCodeException instead of a terminated process;
- asks for objects the scene does not have and for a table of no entries,
  each an NSError with its own code;
- hides and hands back a renderer's visible 2D actors around a render, and
  stops when invalidated.
"""
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
#import "IsiXVTKVolumeScene.hpp"
#import "IsiXVTKOverlay.hpp"
#include "vtkHorosFixedPointVolumeRayCastMapper.h"
#include <vtkActor2D.h>
#include <vtkCamera.h>
#include <vtkColorTransferFunction.h>
#include <vtkCommand.h>
#include <vtkImageData.h>
#include <vtkImageImport.h>
#include <vtkLight.h>
#include <vtkPiecewiseFunction.h>
#include <vtkRenderer.h>
#include <vtkTextActor.h>
#include <vtkVolume.h>
#include <vtkVolumeProperty.h>
#include <cstdio>
#include <stdexcept>
#include <vector>

static int failures = 0;
static void check(bool condition, const char *what)
{
    printf("%s: %s\n", condition ? "PASS" : "FAIL", what);
    if (!condition) failures++;
}

static bool isError(NSError *error, NSInteger code)
{
    return [error.domain isEqualToString:IsiXVTKErrorDomain] && error.code == code && error.userInfo[IsiXVTKOperationKey];
}

int main()
{
    @autoreleasepool {
        vtkRenderer *renderer = vtkRenderer::New();
        vtkCamera *camera = vtkCamera::New();
        camera->SetPosition(1, 2, 30);
        camera->SetFocalPoint(1, 2, 3);
        camera->SetViewUp(0, 1, 0);
        camera->ParallelProjectionOn();
        camera->SetParallelScale(12.5);
        camera->SetWindowCenter(0.25, -0.5);
        renderer->SetActiveCamera(camera);
        vtkLight *light = vtkLight::New();
        light->SetIntensity(0.75);
        light->SetAmbientColor(0.3, 0.6, 0.9);
        renderer->AddLight(light);

        vtkImageData *image = vtkImageData::New();
        image->SetDimensions(8, 8, 8);
        image->SetSpacing(0.5, 0.5, 2);
        image->SetOrigin(-1, -2, -3);
        image->AllocateScalars(VTK_UNSIGNED_SHORT, 1);
        vtkImageImport *importer = vtkImageImport::New();
        unsigned short voxels[8 * 8 * 8] = {};
        importer->SetImportVoidPointer(voxels);
        importer->SetDataScalarTypeToUnsignedShort();
        importer->SetWholeExtent(0, 7, 0, 7, 0, 7);
        importer->SetDataExtentToWholeExtent();
        importer->SetDataSpacing(0.5, 0.5, 2);
        importer->SetDataOrigin(-1, -2, -3);
        importer->Update();

        vtkHorosFixedPointVolumeRayCastMapper *mapper = vtkHorosFixedPointVolumeRayCastMapper::New();
        mapper->SetSampleDistance(1.6f);
        vtkVolumeProperty *property = vtkVolumeProperty::New();
        property->ShadeOn();
        property->SetAmbient(0.15);
        vtkColorTransferFunction *colour = vtkColorTransferFunction::New();
        colour->AddRGBPoint(0, 0, 0, 0);
        colour->AddRGBPoint(255, 1, 0.5, 0.25);
        vtkPiecewiseFunction *opacity = vtkPiecewiseFunction::New();
        opacity->AddPoint(0, 0);
        opacity->AddPoint(255, 1);
        property->SetColor(colour);
        property->SetScalarOpacity(opacity);
        vtkVolume *volume = vtkVolume::New();
        volume->SetMapper(mapper);
        volume->SetProperty(property);
        volume->SetPosition(4, 0, 0);

        IsiXVTKVolumeSceneObjects objects;
        objects.renderer = renderer;
        objects.camera = camera;
        objects.mapper = mapper;
        objects.volume = volume;
        objects.property = property;
        objects.colour = colour;
        objects.opacity = opacity;
        objects.importer = importer;
        IsiXVTKVolumeScene *scene = IsiXVTKMakeVolumeScene(objects);
        check(scene.hasRenderer && scene.hasMapper && scene.hasImporter && scene.hasVolume, "the scene has the view's objects");

        NSError *error = nil;
        IsiXVTKCameraState state;
        check([scene readCamera:&state error:&error] && state.position[2] == 30 && state.parallelProjection &&
              state.parallelScale == 12.5 && state.windowCenter[1] == -0.5 && !state.stereoRender, "the camera reads as VTK holds it");
        IsiXVTKVolumeSampling sampling;
        check([scene readSampling:&sampling error:&error] && sampling.sampleDistance == 1.6f && sampling.shade && sampling.ambient == 0.15
              && sampling.componentWeight[0] == 1 && !sampling.cropping && !sampling.hasInput, "the sampling reads as VTK holds it");
        IsiXVTKVolumePlacement placement;
        check([scene readPlacement:&placement error:&error] && placement.hasImporterOutput && placement.spacing[2] == 2 &&
              placement.origin[1] == -2 && placement.matrix[3] == 4 && placement.matrix[15] == 1, "the placement reads the importer and the matrix");
        __block int lights = 0;
        __block double intensity = 0, green = 0;
        check([scene enumerateLightsUsingBlock:^(BOOL on, double value, const double *ambient) {
            lights++; intensity = value; green = ambient[1];
        } error:&error] && lights == 1 && intensity == 0.75 && green == 0.6, "the lights read as VTK holds them");
        NSData *table = [scene colourTableFrom:0 to:255 count:2 error:&error];
        const double *rgb = (const double *)table.bytes;
        check(table.length == 6 * sizeof(double) && rgb[3] == 1 && rgb[4] == 0.5, "the colour function evaluates over a range");
        NSData *components = [scene componentOpacityTable:0 from:0 to:255 count:3 error:&error];
        check(components.length == 3 * sizeof(double) && ((const double *)components.bytes)[2] == 1, "a component's opacity evaluates");

        // A VTK error: the mapper's tables brought up to date without an input.
        error = nil;
        BOOL initialized = [scene initializeVolumeTablesWithError:&error];
        check(!initialized && isError(error, IsiXVTKErrorCodeLibrary) &&
              [error.userInfo[IsiXVTKMessageKey] containsString:@"No Input!"] &&
              [error.userInfo[IsiXVTKClassKey] length] > 0, "a VTK error is an NSError with VTK's message and the object's class");
        printf("  %s\n", error.localizedDescription.UTF8String);
        check(!mapper->HasObserver(vtkCommand::ErrorEvent), "the error observer is gone after the call");
        error = nil;
        check([scene prepareGeometryAcceptingClippingPlanes:YES error:&error] == IsiXVTKGeometryRefusalNoInput && error == nil,
              "a mapper without input refuses its geometry without an error");

        // A C++ exception inside an adapter call.
        error = nil;
        BOOL enumerated = [scene enumerateLightsUsingBlock:^(BOOL, double, const double *) {
            std::vector<int> none;
            (void)none.at(3);
        } error:&error];
        check(!enumerated && isError(error, IsiXVTKErrorCodeException), "a C++ exception in an enumeration is an NSError");
        printf("  %s\n", error.localizedDescription.UTF8String);
        mapper->SetInputData(image);
        error = nil;
        BOOL accessed = [scene accessRayCastImage:^(uint16_t *, IsiXVTKRayCastImageInfo) {
            throw std::runtime_error("the picture does not fit");
        } error:&error];
        check(!accessed && isError(error, IsiXVTKErrorCodeException) &&
              [error.userInfo[IsiXVTKMessageKey] isEqualToString:@"the picture does not fit"], "a C++ exception in an image access is an NSError");

        // What the scene does not have, and what a table cannot be.
        IsiXVTKVolumeScene *empty = IsiXVTKMakeVolumeScene(IsiXVTKVolumeSceneObjects());
        error = nil;
        check(![empty readCamera:&state error:&error] && isError(error, IsiXVTKErrorCodeUnavailable), "no camera is IsiXVTKErrorCodeUnavailable");
        error = nil;
        check([empty componentColourTable:1 from:0 to:1 count:4 error:&error] == nil && isError(error, IsiXVTKErrorCodeUnavailable),
              "no property is IsiXVTKErrorCodeUnavailable");
        error = nil;
        check([scene opacityTableFrom:0 to:1 count:0 error:&error] == nil && isError(error, IsiXVTKErrorCodeInvalidArgument),
              "a table of no entries is IsiXVTKErrorCodeInvalidArgument");
        error = nil;
        check([scene componentColourTable:7 from:0 to:1 count:4 error:&error] == nil && isError(error, IsiXVTKErrorCodeInvalidArgument),
              "a component beyond the fourth is IsiXVTKErrorCodeInvalidArgument");
        error = nil;
        check([IsiXVTKOverlayObserver observerOfRenderer:nullptr draw:^(const std::vector<vtkActor2D *> &) {} error:&error] == nil &&
              isError(error, IsiXVTKErrorCodeUnavailable), "an overlay without a renderer is refused");

        // The 2D layer: hidden from VTK's render, handed back after it.
        vtkTextActor *text = vtkTextActor::New();
        vtkTextActor *hidden = vtkTextActor::New();
        hidden->SetVisibility(0);
        renderer->AddViewProp(text);
        renderer->AddViewProp(hidden);
        __block size_t drawn = 0;
        __block bool visibleWhenDrawn = false;
        IsiXVTKOverlayObserver *overlay = [IsiXVTKOverlayObserver observerOfRenderer:renderer draw:^(const std::vector<vtkActor2D *> &shown) {
            drawn = shown.size();
            visibleWhenDrawn = shown.size() == 1 && shown[0] == text && text->GetVisibility();
        } error:&error];
        renderer->InvokeEvent(vtkCommand::StartEvent);
        check(overlay != nil && text->GetVisibility() == 0 && hidden->GetVisibility() == 0, "a render starts with the visible 2D actors hidden");
        renderer->InvokeEvent(vtkCommand::EndEvent);
        check(drawn == 1 && visibleWhenDrawn && text->GetVisibility() == 1 && hidden->GetVisibility() == 0,
              "a render ends with them visible and handed to the view");
        [overlay invalidate];
        drawn = 0;
        renderer->InvokeEvent(vtkCommand::StartEvent);
        renderer->InvokeEvent(vtkCommand::EndEvent);
        check(drawn == 0 && text->GetVisibility() == 1, "an invalidated observer no longer hides nor hands back");

        scene = nil;
        empty = nil;
        overlay = nil;
        for (vtkObject *object : std::vector<vtkObject *>{text, hidden, volume, opacity, colour, property, mapper, importer, image, light,
                                                          camera, renderer})
            object->Delete();
    }
    printf("%d failure(s)\n", failures);
    return failures ? 1 : 0;
}
'''

with tempfile.TemporaryDirectory() as folder:
    folder = Path(folder)
    (folder / 'driver.mm').write_text(DRIVER)
    sources = [folder / 'driver.mm', ADAPTER / 'IsiXVTKError.mm', ADAPTER / 'IsiXVTKVolumeScene.mm', ADAPTER / 'IsiXVTKOverlay.mm',
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
    linked = subprocess.run(['xcrun', 'clang++', *objects, str(INSTALL / 'wlib/libVTK.a'), '-lz', '-framework', 'Foundation',
                             '-o', str(folder / 'driver')], capture_output=True, text=True)
    if linked.returncode != 0:
        print(linked.stderr[-4000:], file=sys.stderr)
        sys.exit(1)
    try:
        run = subprocess.run([str(folder / 'driver')], capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        print('FAIL: the driver did not finish within 60 s', file=sys.stderr)
        sys.exit(1)
    print(run.stdout, end='')
    if run.returncode != 0:
        print(run.stderr[-2000:], file=sys.stderr)
        sys.exit(1)
