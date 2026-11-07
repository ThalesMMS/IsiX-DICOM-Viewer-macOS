#!/usr/bin/env python3
"""2D Viewer > Reorient All Images to Current Image resamples through the real ITK.

The images of a synthetic series that are not in the reference's orientation
(tilted 20°, of another matrix and pixel spacing; turned a quarter in plane;
oblique about two axes) go through +[ITKTransform reorient2Dimage:firstObject:
firstObjectOriginal:length:] (Swift, with the ITK adapter's IsiXITKResampler,
over the ITK the app links: the install under build/, so the test skips with 2
until ITK is built), with the parameters and the target geometry of
IsiXImaging's ImagePlaneReorientation, on stand-ins for DCMPix
(tests/itk_harness.py).

Each image holds a linear ramp of the patient coordinates of its pixels, and
linear interpolation gives a linear ramp back exactly. So every pixel of the
result, placed by the target geometry (the reference's orientation, matrix and
spacing, on the plane parallel to it through the image's centre), must hold
the ramp at the point of the old image it lies over along the old image's
normal, within 2e-3 (32-bit floats on values up to about 500), when that
point is at least 0.01 pixel inside the old image; pixels more than half a
pixel (plus 0.01) outside it must hold the series' lowest value. The result
has the reference's matrix, and an image already in the reference's
orientation is left alone by the rules.
"""
import private_tmpdir  # noqa: F401  (a TMPDIR of the test's own)
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import itk_harness  # noqa: E402

if itk_harness.installs() is None:
    print('skip: ITK is not built (build/Intermediates.noindex/Horos.build/*/ITK.build/Install)')
    sys.exit(2)

RULES = [itk_harness.ROOT / 'Modules/IsiXImaging/Sources/SeriesOperations' / name
         for name in ('SeriesConsistency.swift', 'ImagePlaneReorientation.swift')]

# The rules for the stand-in DCMPix, reached by class name from the driver.
SHIM = r'''
import Foundation

@objc(ReorientationShim) final class ReorientationShim: NSObject {
    static func plane(_ pix: DCMPix) -> ImagePlane {
        var o = [Double](repeating: 0, count: 9)
        pix.orientationDouble(&o)
        return ImagePlane(origin: [pix.originX, pix.originY, pix.originZ], orientation: o, width: pix.pwidth,
                          height: pix.pheight, spacingX: pix.pixelSpacingX, spacingY: pix.pixelSpacingY)
    }

    @objc(parametersOf:reference:into:)
    static func parameters(of image: DCMPix, reference: DCMPix, into out: UnsafeMutablePointer<Double>) {
        let p = ImagePlaneReorientation.parameters(image: plane(image), reference: plane(reference))
        for i in 0 ..< 12 { out[i] = p[i] }
    }

    /// The target's origin and orientation (twelve values); whether the image is resampled.
    @objc(targetOf:reference:into:)
    static func target(of image: DCMPix, reference: DCMPix, into out: UnsafeMutablePointer<Double>) -> Bool {
        let t = ImagePlaneReorientation.target(of: plane(image), reference: plane(reference))
        for i in 0 ..< 3 { out[i] = t.origin[i] }
        for i in 0 ..< 9 { out[3 + i] = t.orientation[i] }
        return ImagePlaneReorientation.needsResampling(plane(image).orientation, reference: plane(reference).orientation)
    }
}
'''

HARNESS = r'''
#import <Cocoa/Cocoa.h>
#import <objc/message.h>
#import "Stubs.h"
#include <math.h>
#include <vector>

static int failures;
#define check(c, ...) do { if (!(c)) { printf("FAIL line %d: %s: ", __LINE__, #c); printf(__VA_ARGS__); printf("\n"); failures++; } } while (0)

static void unit(double *v) { double l = sqrt(v[0]*v[0] + v[1]*v[1] + v[2]*v[2]); for (int i = 0; i < 3; i++) v[i] /= l; }
static double dot(const double *a, const double *b) { return a[0]*b[0] + a[1]*b[1] + a[2]*b[2]; }
static double ramp(const double *p) { return 7 + 3 * p[0] - 2 * p[1] + 5 * p[2]; }

// An image whose normal is its row x column, as DCMPix sets it, holding the ramp.
static DCMPix *image(double ox, double oy, double oz, const double *row, const double *column,
                     long width, long height, double sx, double sy, std::vector<float> &pixels) {
    DCMPix *pix = [[[DCMPix alloc] init] autorelease];
    double r[3] = {row[0], row[1], row[2]}, c[3] = {column[0], column[1], column[2]};
    unit(r); unit(c);
    double *o = pix.orientation;
    for (int a = 0; a < 3; a++) { o[a] = r[a]; o[3 + a] = c[a]; }
    o[6] = r[1]*c[2] - r[2]*c[1]; o[7] = r[2]*c[0] - r[0]*c[2]; o[8] = r[0]*c[1] - r[1]*c[0];
    pix.originX = ox; pix.originY = oy; pix.originZ = oz;
    pix.pwidth = width; pix.pheight = height; pix.pixelSpacingX = sx; pix.pixelSpacingY = sy;
    pix.sliceInterval = 0; pix.sliceThickness = 1; pix.minValueOfSeries = -1000;
    pixels.assign(width * height, 0);
    for (long y = 0; y < height; y++)
        for (long x = 0; x < width; x++) {
            double p[3];
            for (int a = 0; a < 3; a++) p[a] = (a == 0 ? ox : a == 1 ? oy : oz) + x * sx * r[a] + y * sy * c[a];
            pixels[y * width + x] = (float)ramp(p);
        }
    pix.fImage = pixels.data();
    return pix;
}

int main() {
    @autoreleasepool {
        Class shim = NSClassFromString(@"ReorientationShim"), transform = NSClassFromString(@"ITKTransform");
        check(shim && transform, "the shim or ITKTransform is missing");
        if (!shim || !transform) return 1;

        const double x[3] = {1, 0, 0}, y[3] = {0, 1, 0}, minusX[3] = {-1, 0, 0};
        const double t = 20 * M_PI / 180, tilted[3] = {0, cos(t), sin(t)};
        const double obliqueRow[3] = {cos(0.4), sin(0.4), 0.15}, obliqueColumn[3] = {-sin(0.4), cos(0.4), 0.3};
        std::vector<float> referencePixels, axialPixels, tiltedPixels, turnedPixels, obliquePixels;
        DCMPix *reference = image(-20, -18, 4, x, y, 40, 36, 1, 1, referencePixels);
        DCMPix *axial = image(-20, -18, 6, x, y, 40, 36, 1, 1, axialPixels);
        struct Case { const char *name; DCMPix *pix; std::vector<float> *pixels; } cases[] = {
            {"tilted 20 degrees", image(-14, -12, 10, x, tilted, 30, 26, 0.9, 1.1, tiltedPixels), &tiltedPixels},
            {"turned in plane", image(10, -15, 14, y, minusX, 32, 32, 0.8, 0.8, turnedPixels), &turnedPixels},
            {"oblique", image(-12, -10, 16, obliqueRow, obliqueColumn, 34, 30, 0.95, 0.85, obliquePixels), &obliquePixels},
        };

        double geometry[12];
        BOOL resampled = ((BOOL (*)(id, SEL, DCMPix *, DCMPix *, double *))objc_msgSend)(
            shim, @selector(targetOf:reference:into:), axial, reference, geometry);
        check(!resampled, "an axial image is resampled");

        for (const Case &c : cases) {
            DCMPix *pix = c.pix;
            resampled = ((BOOL (*)(id, SEL, DCMPix *, DCMPix *, double *))objc_msgSend)(
                shim, @selector(targetOf:reference:into:), pix, reference, geometry);
            check(resampled, "%s: not resampled", c.name);
            double referenceOrientation[9];
            [reference orientationDouble:referenceOrientation];
            for (int i = 0; i < 9; i++)
                check(fabs(geometry[3 + i] - referenceOrientation[i]) < 1e-12, "%s: orientation %d", c.name, i);

            double parameters[12];
            ((void (*)(id, SEL, DCMPix *, DCMPix *, double *))objc_msgSend)(
                shim, @selector(parametersOf:reference:into:), pix, reference, parameters);
            long length = 0;
            float *out = ((float *(*)(id, SEL, double *, DCMPix *, DCMPix *, long *))objc_msgSend)(
                transform, @selector(reorient2Dimage:firstObject:firstObjectOriginal:length:), parameters, reference, pix, &length);
            check(out != NULL, "%s: no result", c.name);
            if (!out) continue;
            check(length == 40 * 36 * (long)sizeof(float), "%s: %ld bytes, not the reference's matrix", c.name, length);

            double o[9];
            [pix orientationDouble:o];
            double worst = 0;
            long inside = 0, outside = 0, wrongOutside = 0;
            for (long j = 0; j < 36; j++)
                for (long i = 0; i < 40; i++) {
                    double p[3], d[3];
                    for (int a = 0; a < 3; a++) {
                        p[a] = geometry[a] + i * referenceOrientation[a] + j * referenceOrientation[3 + a];
                    }
                    d[0] = p[0] - pix.originX; d[1] = p[1] - pix.originY; d[2] = p[2] - pix.originZ;
                    double u = dot(d, o) / pix.pixelSpacingX, v = dot(d, o + 3) / pix.pixelSpacingY;
                    float value = out[j * 40 + i];
                    const double margin = 0.01;
                    if (u >= margin && v >= margin && u <= pix.pwidth - 1 - margin && v <= pix.pheight - 1 - margin) {
                        double q[3];
                        for (int a = 0; a < 3; a++) q[a] = (a == 0 ? pix.originX : a == 1 ? pix.originY : pix.originZ)
                                                         + u * pix.pixelSpacingX * o[a] + v * pix.pixelSpacingY * o[3 + a];
                        double e = fabs(value - ramp(q));
                        if (e > worst) worst = e;
                        inside++;
                    } else if (u < -0.5 - margin || v < -0.5 - margin || u > pix.pwidth - 0.5 + margin || v > pix.pheight - 0.5 + margin) {
                        if (value != -1000) wrongOutside++;
                        outside++;
                    }
                }
            free(out);
            printf("%-18s %4ld pixels over the image  worst %.2g  %4ld outside\n", c.name, inside, worst, outside);
            check(inside > 200, "%s: too few pixels over the image (%ld)", c.name, inside);
            check(worst < 2e-3, "%s: a resampled pixel is not the old image projected (%.4f)", c.name, worst);
            check(wrongOutside == 0, "%s: %ld pixels outside the old image without the lowest value", c.name, wrongOutside);
        }
    }
    if (failures) { printf("%d failure(s)\n", failures); return 1; }
    printf("ok\n");
    return 0;
}
'''

with tempfile.TemporaryDirectory() as folder:
    shim = Path(folder) / 'ReorientationShim.swift'
    shim.write_text(SHIM)
    try:
        harness = itk_harness.build('new', folder, HARNESS, swift_sources=RULES + [shim])
    except RuntimeError as error:
        print(error)
        sys.exit(1)
    try:
        result = subprocess.run([str(harness)], capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired:
        print('FAIL: the harness did not finish within 120 s')
        sys.exit(1)
    print(result.stdout, end='')
    if result.returncode:
        print(result.stderr[-2000:])
        print('FAIL: Reorient All Images to Current Image does not resample as its rules say')
        sys.exit(1)
    print('PASS: Reorient All Images to Current Image resamples through ITK onto the reference orientation')
