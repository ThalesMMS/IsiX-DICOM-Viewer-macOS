#!/usr/bin/env python3
"""The VTK adapter of the volume rendering view turns VTK's errors and C++
exceptions into NSError.

VRView keeps every VTK object it renders with in the VTK adapter's
IsiXVTKVolumeView (Horos/Sources/Adapters/VTK/IsiXVTKVolume*.mm), whose header
carries no C++ type: the window and the renderer, the importer, the transfer
functions, the ray casters, the volume, the camera, the crop box, the 2D
actors and the 3D points. Every call into VTK runs inside the adapter's guard,
which turns a C++ exception into an NSError of IsiXVTKErrorCodeException and an
error VTK reports for one of the call's objects (vtkErrorMacro, sent as its
ErrorEvent) into one of IsiXVTKErrorCodeLibrary; the calls that have no error
to give back log it.

The adapter's files, the app's ray-cast mapper and the scene factory are
compiled here against the VTK the Debug build installed (exit 2 without that
build), with a driver that:
- builds a small volume through the adapter as the view does - importer,
  transfer functions, volume, ray caster, camera, texts and measurement
  actors - and reads back its bounds, its camera and the window text;
- provokes a VTK error: an importer whose update callback fails, reported by
  vtkImageImport, comes back from -updateImportWithError: as an NSError with
  VTK's message and the importer's class;
- provokes a C++ exception inside -makeCameraWithError: (an observer of the
  renderer throws when the camera is made its active one) and receives it as
  an NSError of IsiXVTKErrorCodeException instead of a terminated process;
- checks that a setter that cannot give an error back logs one (the logging
  function is the driver's here), and that the ray caster's switch and the
  crop box's absence read as the view expects.
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
#import "IsiXVTKVolumeViewInternal.hpp"
#include <vtkCallbackCommand.h>
#include <vtkCommand.h>
#include <vtkImageImport.h>
#include <vtkRenderer.h>
#include <vtkTextActor.h>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <vector>

static int failures = 0;
static int logged = 0;
static NSError *lastLogged = nil;

// What the app's IsiXVTKSceneActors.mm defines: here it counts.
void IsiXVTKLogFailure(NSError *error)
{
    logged++;
    lastLogged = error;
}

static void check(bool condition, const char *what)
{
    printf("%s: %s\n", condition ? "PASS" : "FAIL", what);
    if (!condition) failures++;
}

static bool isError(NSError *error, NSInteger code)
{
    return [error.domain isEqualToString:IsiXVTKErrorDomain] && error.code == code && error.userInfo[IsiXVTKOperationKey];
}

static void failingUpdate(void *)
{
    throw std::runtime_error("the voxels are gone");
}

int main()
{
    @autoreleasepool {
        NSError *error = nil;
        IsiXVTKVolumeView *view = [IsiXVTKVolumeView volumeViewWithError:&error];
        check(view != nil && error == nil && view.rendererHandle && view.renderWindowHandle, "the view's window and renderer are made");
        check(!view.hasRenderer && !view.hasCamera && !view.hasVolume, "nothing else is made before the volume");
        [view useOwnRenderer];
        check(view.hasRenderer, "the pipeline renders with the view's renderer");

        // A volume of 4 x 3 x 2 voxels, built as -[VRView setPixSource::] does.
        std::vector<unsigned short> voxels(4 * 3 * 2);
        for (size_t i = 0; i < voxels.size(); i++) voxels[i] = (unsigned short)(100 * i);
        check([view importVolume:voxels.data() rgb:NO width:4 height:3 depth:2 error:&error] && error == nil, "the importer takes the voxels");
        [view setImportSpacingX:0.5 y:0.5 z:2];
        check([view makeTransferFunctionsRGB:NO invertedPolarity:NO opacityAdapter:1 error:&error], "the transfer functions are made");
        float cosines[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
        check([view makeVolumeNearest:NO cosines:cosines factor:1 originX:10 y:20 z:30 error:&error], "the volume is made");
        [view allocateVolumeMapper];
        check(view.hasVolumeMapper && view.volumeHasMapper, "the ray caster is made and given to the volume");
        check([view makeCameraWithError:&error] && view.hasCamera && view.cameraParallelProjection, "the camera is made, in parallel projection");
        check([view makeMeasurementActorsWithNotice:@"notice" error:&error] && [view activeLinePointCount] == 0 && [view hasAngleActors],
              "the measurement actors are made, the line empty");
        check([view makeTextsWithWindowText:"WL: 40 WW: 400 " corner:YES tilt:nil error:&error] && view.hasWindowText && view.hasCornerText,
              "the texts are made");
        double bounds[6];
        [view getVolumeBounds:bounds];
        check(bounds[0] == 10 && bounds[1] == 11.5 && bounds[2] == 20 && bounds[3] == 21 && bounds[4] == 30 && bounds[5] == 32,
              "the volume lies where the series is");
        double position[3] = {1, 2, 3}, read[3];
        [view setCameraPosition:position];
        [view getCameraPosition:read];
        check(read[0] == 1 && read[1] == 2 && read[2] == 3, "the camera reads back what was set");
        [view setWindowText:"WL: 50 WW: 500 "];
        check(strcmp(view->_o->textWLWW->GetInput(), "WL: 50 WW: 500 ") == 0, "the window text is the view's");
        check([view getCameraCropOrigins:nullptr normals:nullptr] == -1 && !view.cropBoxEnabled, "without a crop box there is no crop");
        BOOL suppressed = IsiXVTKVolumeView.volumeRenderingSuppressed;
        IsiXVTKVolumeView.volumeRenderingSuppressed = !suppressed;
        check(IsiXVTKVolumeView.volumeRenderingSuppressed == !suppressed, "the ray caster's switch is the mapper's");
        IsiXVTKVolumeView.volumeRenderingSuppressed = suppressed;

        // A VTK error: the importer's update callback fails, and vtkImageImport
        // reports it for the importer.
        view->_o->reader->SetUpdateDataCallback(failingUpdate);
        view->_o->reader->Modified();
        error = nil;
        BOOL updated = [view updateImportWithError:&error];
        check(!updated && isError(error, IsiXVTKErrorCodeLibrary) &&
              [error.userInfo[IsiXVTKMessageKey] containsString:@"the voxels are gone"] &&
              [error.userInfo[IsiXVTKClassKey] length] > 0, "a VTK error is an NSError with VTK's message and the object's class");
        printf("  %s\n", error.localizedDescription.UTF8String);
        check(!view->_o->reader->HasObserver(vtkCommand::ErrorEvent), "the error observer is gone after the call");
        view->_o->reader->SetUpdateDataCallback(nullptr);

        // A C++ exception inside an adapter call: an observer of a second
        // view's renderer throws when the camera is made its active one.
        IsiXVTKVolumeView *other = [IsiXVTKVolumeView volumeViewWithError:&error];
        [other useOwnRenderer];
        vtkCallbackCommand *thrower = vtkCallbackCommand::New();
        thrower->SetCallback([](vtkObject *, unsigned long, void *, void *) { throw std::runtime_error("no room for the camera"); });
        unsigned long tag = other->_o->aRenderer->AddObserver(vtkCommand::ModifiedEvent, thrower);
        error = nil;
        BOOL made = [other makeCameraWithError:&error];
        check(!made && isError(error, IsiXVTKErrorCodeException) &&
              [error.userInfo[IsiXVTKMessageKey] isEqualToString:@"no room for the camera"], "a C++ exception is an NSError, not a crash");
        printf("  %s\n", error.localizedDescription.UTF8String);

        // A setter has no error to give back: it logs the exception.
        int before = logged;
        [other setBackgroundRed:0.1 green:0.2 blue:0.3];
        check(logged == before + 1 && isError(lastLogged, IsiXVTKErrorCodeException), "a setter logs the exception it caught");
        other->_o->aRenderer->RemoveObserver(tag);
        thrower->Delete();
        before = logged;
        [other setBackgroundRed:0.1 green:0.2 blue:0.3];
        check(logged == before, "without the observer, nothing is logged");
        [other releasePipeline];
        [other releasePresentation];
        other = nil;

        [view releasePipeline];
        check(!view.hasVolume && !view.hasCamera && !view.hasWindowText, "the pipeline is let go");
        [view releasePresentation];
        view = nil;
    }
    printf("%d failure(s)\n", failures);
    return failures ? 1 : 0;
}
'''

with tempfile.TemporaryDirectory() as folder:
    folder = Path(folder)
    (folder / 'driver.mm').write_text(DRIVER)
    sources = [folder / 'driver.mm', ADAPTER / 'IsiXVTKError.mm', ADAPTER / 'IsiXVTKVolumeView.mm',
               ADAPTER / 'IsiXVTKVolumePipeline.mm', ADAPTER / 'IsiXVTKVolumeCamera.mm', ADAPTER / 'IsiXVTKVolumeCrop.mm',
               ADAPTER / 'IsiXVTKVolumeActors.mm', ADAPTER / 'IsiXVTKVolumeScene.mm', ADAPTER / 'IsiXVTKOverlay.mm',
               ADAPTER / 'IsiXVTKSceneOverlay.mm', ADAPTER / 'IsiXVTKVolumePresentation.mm',
               ADAPTER / 'IsiXVTKVolumeInteraction.mm']
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
                             '-framework', 'QuartzCore', '-framework', 'CoreGraphics', '-o', str(folder / 'driver')],
                            capture_output=True, text=True)
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
