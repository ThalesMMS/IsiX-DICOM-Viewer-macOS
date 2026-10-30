#!/usr/bin/env python3
"""The VTK adapter of the fly-through curves and renderer props turns VTK's errors and C++ exceptions into NSError.

Horos/Sources/Adapters/VTK/IsiXVTKCurves is the Objective-C++ through which the
fly-through's interpolations (Spline3D, Piecewise3D), the fly-path centerline
smoothing (FlyAssistant) and the thick slab's opacity table (ThickSlabVR) reach
VTK: a curve of three coordinates over t, each axis a vtkCardinalSpline or a
vtkPiecewiseFunction, and a vtkPiecewiseFunction of one variable.
IsiXVTKRendererProps adds a ROI volume's actor to the 3D view's renderer and
removes it. Their headers carry no C++ type; every call into VTK runs inside
the adapter's guard.

The adapter is compiled here against the VTK the Debug build installed (exit 2
without that build), with a driver that:
- evaluates a cardinal spline and a piecewise curve through the same points,
  and a piecewise function and its table, against VTK called directly (the
  thick slab's opacity table against GetValue of each byte, as ThickSlabVR.mm
  read it);
- provokes a VTK error: a spline computed with a single point ("Cannot compute
  a spline with less than 2 points"), an NSError of IsiXVTKErrorDomain
  (Library) with VTK's message; and a prop whose release of its graphics
  resources reports an error when the renderer removes it;
- provokes a C++ exception: a table too large to allocate, and a prop whose
  release throws, each an NSError of IsiXVTKErrorCodeException instead of a
  terminated process;
- passes no renderer, a negative table size and objects of the wrong classes,
  each an NSError with its own code.
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
#import "IsiXVTKError.h"
#import "IsiXVTKCurves.h"
#import "IsiXVTKRendererProps.h"
#include <vtkActor.h>
#include <vtkCardinalSpline.h>
#include <vtkObjectFactory.h>
#include <vtkPiecewiseFunction.h>
#include <vtkRenderer.h>
#include <vtkSmartPointer.h>
#include <cmath>
#include <cstdio>
#include <stdexcept>

static int failures = 0;
static void check(bool condition, const char *what)
{
    printf("%s: %s\n", condition ? "PASS" : "FAIL", what);
    if (!condition) failures++;
}

static bool isError(NSError *error, IsiXVTKErrorCode code)
{
    return [error.domain isEqualToString:IsiXVTKErrorDomain] && error.code == code;
}

static NSString *reason(NSError *error)
{
    return error.userInfo[NSLocalizedFailureReasonErrorKey] ?: error.localizedDescription;
}

// A prop whose release of its graphics resources, which the renderer asks
// for when it removes the prop, reports a VTK error.
class ErrorActor : public vtkActor
{
public:
    static ErrorActor *New();
    vtkTypeMacro(ErrorActor, vtkActor);
    void ReleaseGraphicsResources(vtkWindow *) override { vtkErrorMacro("graphics resources not released"); }
};
vtkStandardNewMacro(ErrorActor);

// The same, throwing a C++ exception, once: the renderer releases the prop
// again when it is destroyed, where an exception would end the process.
class ThrowingActor : public vtkActor
{
public:
    static ThrowingActor *New();
    vtkTypeMacro(ThrowingActor, vtkActor);
    bool armed = true;
    void ReleaseGraphicsResources(vtkWindow *) override
    {
        if (armed) {
            armed = false;
            throw std::runtime_error("release threw");
        }
    }
};
vtkStandardNewMacro(ThrowingActor);

int main()
{
    @autoreleasepool {
        const double ts[] = {0, 1, 2, 4}, xs[] = {0, 2, 3, 7}, ys[] = {1, -1, 5, 2}, zs[] = {3, 3, 0, 1};

        // Curves, against VTK called directly.
        IsiXVTKCurve3D *spline = [[IsiXVTKCurve3D alloc] initWithKind:IsiXVTKCurveKindCardinalSpline];
        IsiXVTKCurve3D *linear = [[IsiXVTKCurve3D alloc] initWithKind:IsiXVTKCurveKindPiecewiseLinear];
        vtkSmartPointer<vtkCardinalSpline> axes[3];
        vtkSmartPointer<vtkPiecewiseFunction> lines[3];
        for (int a = 0; a < 3; a++) {
            axes[a] = vtkSmartPointer<vtkCardinalSpline>::New();
            lines[a] = vtkSmartPointer<vtkPiecewiseFunction>::New();
        }
        bool added = true;
        for (int i = 0; i < 4; i++) {
            NSError *error = nil;
            added = added && [spline addPointAt:ts[i] x:xs[i] y:ys[i] z:zs[i] error:&error] && !error;
            added = added && [linear addPointAt:ts[i] x:xs[i] y:ys[i] z:zs[i] error:&error] && !error;
            const double values[3] = {xs[i], ys[i], zs[i]};
            for (int a = 0; a < 3; a++) {
                axes[a]->AddPoint(ts[i], values[a]);
                lines[a]->AddPoint(ts[i], values[a]);
            }
        }
        check(added, "points are added to both curves");
        NSError *error = nil;
        check([spline computeWithError:&error] && !error && [linear computeWithError:&error] && !error, "both curves compute");
        for (int a = 0; a < 3; a++) axes[a]->Compute();
        bool same = true;
        for (double t = -0.5; t <= 4.5; t += 0.125) {
            double s[3], l[3];
            same = same && [spline evaluateAt:t point:s error:&error] && [linear evaluateAt:t point:l error:&error];
            for (int a = 0; a < 3; a++)
                same = same && s[a] == axes[a]->Evaluate(t) && l[a] == lines[a]->GetValue(t);
        }
        check(same, "the curves give, bit for bit, what vtkCardinalSpline and vtkPiecewiseFunction give");

        IsiXVTKPiecewiseFunction *function = [IsiXVTKPiecewiseFunction new];
        vtkSmartPointer<vtkPiecewiseFunction> direct = vtkSmartPointer<vtkPiecewiseFunction>::New();
        const double points[][2] = {{0, 0}, {10, 0.25}, {20, 1}, {30, 0.5}};
        for (auto &point : points) {
            [function addPointAt:point[0] value:point[1] error:&error];
            direct->AddPoint(point[0], point[1]);
        }
        float table[40], expected[40];
        check([function getValues:table count:40 error:&error] && !error, "a table of the function is read");
        direct->GetTable(0, 39, 40, expected);
        check(memcmp(table, expected, sizeof table) == 0 && [function valueAt:15 error:&error] == direct->GetValue(15),
              "its values are vtkPiecewiseFunction's");
        check([function removeAllPointsWithError:&error] && [function valueAt:15 error:&error] == 0, "its points are removed");

        // ThickSlabVR's opacity table: 0 at 0, the menu's points, 255 at the end, read
        // as the Objective-C++ read it, one GetValue(i) a byte.
        vtkSmartPointer<vtkPiecewiseFunction> slab = vtkSmartPointer<vtkPiecewiseFunction>::New();
        const double opacity[][2] = {{0, 0}, {37.5, 0}, {80.25, 0.4}, {120, 0.35}, {200, 1}, {255, 1}};
        for (auto &point : opacity) {
            [function addPointAt:point[0] value:point[1] error:&error];
            slab->AddPoint(point[0], point[1]);
        }
        float bytes[256];
        bool perByte = [function getValues:bytes count:256 error:&error];
        for (int i = 0; i < 256; i++) perByte = perByte && bytes[i] == (float)slab->GetValue(i);
        check(perByte, "a table of 256 is, bit for bit, GetValue of each byte");

        // A VTK error: a spline of one point.
        IsiXVTKCurve3D *lonely = [[IsiXVTKCurve3D alloc] initWithKind:IsiXVTKCurveKindCardinalSpline];
        [lonely addPointAt:0 x:1 y:2 z:3 error:&error];
        error = nil;
        check(![lonely computeWithError:&error] && isError(error, IsiXVTKErrorCodeLibrary) &&
              [reason(error) containsString:@"less than 2 points"],
              "a spline of one point is a VTK error, with VTK's message");
        printf("  %s\n", reason(error).UTF8String);

        // A C++ exception: a table too large to allocate.
        error = nil;
        float one = 0;
        check(![function getValues:&one count:NSIntegerMax error:&error] && isError(error, IsiXVTKErrorCodeException),
              "a table too large is an exception turned into an NSError");
        printf("  %s\n", reason(error).UTF8String);
        error = nil;
        check(![function getValues:&one count:-1 error:&error] && isError(error, IsiXVTKErrorCodeInvalidArgument),
              "a negative table size is InvalidArgument");

        // Renderer props.
        vtkSmartPointer<vtkRenderer> renderer = vtkSmartPointer<vtkRenderer>::New();
        vtkSmartPointer<vtkActor> actor = vtkSmartPointer<vtkActor>::New();
        error = nil;
        check([IsiXVTKRendererProps addProp:actor toRenderer:renderer error:&error] && !error && renderer->HasViewProp(actor),
              "an actor is added to a renderer");
        check([IsiXVTKRendererProps removeProp:actor fromRenderer:renderer error:&error] && !error && !renderer->HasViewProp(actor),
              "and removed from it");
        error = nil;
        check(![IsiXVTKRendererProps addProp:actor toRenderer:NULL error:&error] && isError(error, IsiXVTKErrorCodeUnavailable),
              "no renderer is Unavailable");
        error = nil;
        check(![IsiXVTKRendererProps addProp:renderer toRenderer:actor error:&error] && isError(error, IsiXVTKErrorCodeInvalidArgument),
              "a renderer and a prop the wrong way round are InvalidArgument");

        vtkSmartPointer<ErrorActor> failing = vtkSmartPointer<ErrorActor>::New();
        [IsiXVTKRendererProps addProp:failing toRenderer:renderer error:&error];
        error = nil;
        check(![IsiXVTKRendererProps removeProp:failing fromRenderer:renderer error:&error] && isError(error, IsiXVTKErrorCodeLibrary) &&
              [reason(error) containsString:@"graphics resources not released"],
              "a VTK error while a prop is removed is an NSError, with VTK's message");

        vtkSmartPointer<ThrowingActor> throwing = vtkSmartPointer<ThrowingActor>::New();
        [IsiXVTKRendererProps addProp:throwing toRenderer:renderer error:&error];
        error = nil;
        check(![IsiXVTKRendererProps removeProp:throwing fromRenderer:renderer error:&error] && isError(error, IsiXVTKErrorCodeException) &&
              [reason(error) containsString:@"release threw"],
              "an exception while a prop is removed is an NSError, not a terminated process");
        check([IsiXVTKRendererProps addProp:actor toRenderer:renderer error:&error] && renderer->HasViewProp(actor),
              "and the adapter keeps working afterwards");
    }
    printf("%d failure(s)\n", failures);
    return failures ? 1 : 0;
}
'''

with tempfile.TemporaryDirectory(prefix='isix-vtk-curves-') as folder:
    folder = Path(folder)
    (folder / 'driver.mm').write_text(DRIVER)
    objects = []
    for index, source in enumerate([folder / 'driver.mm', ADAPTER / 'IsiXVTKError.mm', ADAPTER / 'IsiXVTKCurves.mm',
                                    ADAPTER / 'IsiXVTKRendererProps.mm']):
        output = folder / f'{index}.o'
        # Only the adapter's own folder is on the path: it includes nothing of the app.
        compiled = subprocess.run(['xcrun', 'clang++', '-std=c++17', '-x', 'objective-c++', '-fobjc-arc', '-c',
                                   '-I' + str(INSTALL / 'include'), '-I' + str(ADAPTER), str(source), '-o', str(output)],
                                  capture_output=True, text=True, timeout=600)
        if compiled.returncode != 0:
            print(compiled.stderr[-4000:], file=sys.stderr)
            print('FAIL: ' + source.name + ' does not compile on its own against VTK', file=sys.stderr)
            sys.exit(1)
        objects.append(str(output))
    linked = subprocess.run(['xcrun', 'clang++', *objects, str(INSTALL / 'wlib/libVTK.a'), '-lz', '-framework', 'Foundation',
                             '-o', str(folder / 'driver')], capture_output=True, text=True, timeout=600)
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
print('PASS: curves and renderer props through the VTK adapter; VTK errors and C++ exceptions are NSErrors')
