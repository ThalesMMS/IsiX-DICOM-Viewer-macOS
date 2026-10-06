#!/usr/bin/env python3
"""Fusion > Resample samples the moving series where the output voxel is shown.

+[ITKTransform resampleWithParameters:...rescale:] is extracted from
ITKTransform.mm and run through the real itk::ResampleImageFilter of the ITK
the app links (the install under build/, so the test skips with 2 until ITK is
built), with ITK.mm itself building the importer and a DCMPix reduced to the
geometry these two read. The transform parameters are computed as
-[ViewerController resampleSeries:rescale:] computes them for two series of one
study.

The moving series holds a linear ramp of its patient coordinates. Linear
interpolation reproduces a linear function exactly, so every output voxel
whose DICOM position lies inside the moving volume must hold the ramp's value
at that position: the point ITK sampled is the point the viewer shows. This is
checked with pixel spacings and slice intervals that differ, a slice thickness
that is not the interval, rescale YES and NO, and orientations that are not
axial. The case of the report is checked pixel by pixel: the 1 mm stack
resampled onto the 0.5 mm x 2 mm one, rescale NO, gives at z = 2 mm the moving
stack's slice 2 (it gave the mean of slices 1 and 2).

The method as it was before the fix is taken from history and run on the same
cases, so the half-voxel shift it is being fixed for is shown, not asserted.
"""
import private_tmpdir  # noqa: F401  (a TMPDIR of the test's own)
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sources = root / 'Horos/Sources'


def install():
    for configuration in ('Debug', 'Release'):
        for base in ('build/Intermediates.noindex/Horos.build', 'build/Build/Intermediates.noindex/Horos.build'):
            folder = root / base / configuration / 'ITK.build/Install'
            if (folder / 'include/itkResampleImageFilter.h').is_file() and list((folder / 'lib').glob('libITKCommon-*.a')):
                return folder
    return None


itk = install()
if itk is None:
    print('skip: ITK is not built (build/Intermediates.noindex/Horos.build/*/ITK.build/Install)')
    sys.exit(2)

SIGNATURE = ('+ (float*) resampleWithParameters: (double*)theParameters firstObject: (DCMPix*) firstObject '
             'firstObjectOriginal: (DCMPix*)  firstObjectOriginal noOfImages: (int) noOfImages length: (long*) length '
             'itkImage: (ITK*) itkImage rescale: (BOOL) rescale')
END = '    return fVolumePtr;\n}'


def method(text):
    begin = text.index(SIGNATURE)
    return text[begin:text.index(END, begin) + len(END)]


current = method((sources / 'ITKTransform.mm').read_bytes().decode('latin1'))
assert 'pixelSpacingX/2.' not in current and 'sliceThickness' not in current, \
    'the origins passed to ITK still take half a voxel off'


def revision_containing(path, marker):
    """The newest revision of `path` whose content still has `marker`."""
    listed = subprocess.run(['git', 'log', '--format=%H', '--', path], cwd=str(root), capture_output=True, text=True)
    for revision in listed.stdout.split():
        shown = subprocess.run(['git', 'show', '%s:%s' % (revision, path)], cwd=str(root), capture_output=True)
        if shown.returncode == 0:
            content = shown.stdout.decode('latin1')
            if marker in content:
                return content
    return None


old_source = revision_containing('Horos/Sources/ITKTransform.mm',
                                 '[firstObjectOriginal originX] - firstObjectOriginal.pixelSpacingX/2.;')
before = method(old_source) if old_source else None

STUB_DCMPIX = r'''
#import <Foundation/Foundation.h>
// The pixel object, reduced to the geometry ITK.mm and ITKTransform read.
@interface DCMPix : NSObject {
@public
    double orientation[9];
}
@property double originX, originY, originZ, pixelSpacingX, pixelSpacingY, sliceThickness, sliceInterval;
@property long pwidth, pheight;
@property float minValueOfSeries;
- (void)orientationDouble:(double *)o;
@end
'''

HARNESS = r'''
#include <itkImage.h>
#include <itkImportImageFilter.h>
#include <itkAffineTransform.h>
#include <itkResampleImageFilter.h>
#import <Cocoa/Cocoa.h>
#import "DCMPix.h"
#import "ITK.h"
#include <math.h>
#include <vector>

typedef itk::ResampleImageFilter<ImageType, ImageType> ResampleFilterType;
#define N2LogException(e) NSLog(@"exception %@", e)
#define N2LogStackTrace(...) NSLog(__VA_ARGS__)

@implementation DCMPix
- (void)orientationDouble:(double *)o { for (int i = 0; i < 9; i++) o[i] = orientation[i]; }
@end

@interface WaitRendering : NSObject
- (id)init:(NSString *)message;
- (void)showWindow:(id)sender;
- (void)close;
@end
@implementation WaitRendering
- (id)init:(NSString *)message { return [super init]; }
- (void)showWindow:(id)sender {}
- (void)close {}
@end

@interface ITKTransform : NSObject @end
@implementation ITKTransform
@@CURRENT@@
@end

#if HAVE_BEFORE
@interface ITKTransformBefore : NSObject @end
@implementation ITKTransformBefore
@@BEFORE@@
@end
#endif

static int failures;
#define check(c, ...) do { if (!(c)) { printf("FAIL line %d: %s: ", __LINE__, #c); printf(__VA_ARGS__); printf("\n"); failures++; } } while (0)

struct Series {
    double origin[3], row[3], column[3], normal[3];
    double spacingX, spacingY, interval, thickness;
    long width, height, slices;
};

static void unit(double *v) { double l = sqrt(v[0]*v[0] + v[1]*v[1] + v[2]*v[2]); for (int i = 0; i < 3; i++) v[i] /= l; }

static Series series(const double origin[3], const double row[3], const double column[3],
                     double spacingX, double spacingY, double interval, double thickness,
                     long width, long height, long slices) {
    Series s;
    for (int i = 0; i < 3; i++) { s.origin[i] = origin[i]; s.row[i] = row[i]; s.column[i] = column[i]; }
    unit(s.row); unit(s.column);
    s.normal[0] = s.row[1]*s.column[2] - s.row[2]*s.column[1];
    s.normal[1] = s.row[2]*s.column[0] - s.row[0]*s.column[2];
    s.normal[2] = s.row[0]*s.column[1] - s.row[1]*s.column[0];
    s.spacingX = spacingX; s.spacingY = spacingY; s.interval = interval; s.thickness = thickness;
    s.width = width; s.height = height; s.slices = slices;
    return s;
}

// The DICOM position of voxel (i, j) of slice k: the slice's Image Position
// Patient plus i columns and j rows.
static void position(const Series &s, double i, double j, double k, double spacingX, double spacingY, double *p) {
    for (int a = 0; a < 3; a++)
        p[a] = s.origin[a] + k * s.interval * s.normal[a] + i * spacingX * s.row[a] + j * spacingY * s.column[a];
}

static NSArray *pixList(const Series &s) {
    NSMutableArray *list = [NSMutableArray array];
    for (long k = 0; k < s.slices; k++) {
        DCMPix *pix = [[[DCMPix alloc] init] autorelease];
        double p[3];
        position(s, 0, 0, k, s.spacingX, s.spacingY, p);
        pix.originX = p[0]; pix.originY = p[1]; pix.originZ = p[2];
        pix.pixelSpacingX = s.spacingX; pix.pixelSpacingY = s.spacingY;
        pix.sliceInterval = s.interval; pix.sliceThickness = s.thickness;
        pix.pwidth = s.width; pix.pheight = s.height;
        pix.minValueOfSeries = -1e6;
        for (int a = 0; a < 3; a++) {
            pix->orientation[a] = s.row[a]; pix->orientation[3 + a] = s.column[a]; pix->orientation[6 + a] = s.normal[a];
        }
        [list addObject:pix];
    }
    return list;
}

// -[ViewerController resampleSeries:rescale:], same study: no translation, the
// rotation from the reference's frame to the moving series' frame.
static void parameters(DCMPix *moving, DCMPix *reference, double *matrix) {
    double s[9], m[9];
    [moving orientationDouble:s];
    [reference orientationDouble:m];
    for (int r = 0; r < 3; r++)
        for (int c = 0; c < 3; c++)
            matrix[3 * r + c] = s[3 * r] * m[3 * c] + s[3 * r + 1] * m[3 * c + 1] + s[3 * r + 2] * m[3 * c + 2];
    matrix[9] = matrix[10] = matrix[11] = 0;
}

static double ramp(const double *p) { return 7 + 11 * p[0] - 5 * p[1] + 13 * p[2]; }

typedef float *(*Resample)(double *, DCMPix *, DCMPix *, int, long *, ITK *, BOOL);

static float *run(Class transform, const Series &moving, const Series &reference, BOOL rescale,
                  std::vector<float> &volume) {
    NSArray *movingPix = pixList(moving), *referencePix = pixList(reference);
    ITK *itk = [[ITK alloc] initWith:(NSMutableArray *)movingPix :volume.data() :-1];
    double matrix[12];
    parameters(movingPix[0], referencePix[0], matrix);
    long length = 0;
    SEL selector = @selector(resampleWithParameters:firstObject:firstObjectOriginal:noOfImages:length:itkImage:rescale:);
    float *out = ((float *(*)(id, SEL, double *, DCMPix *, DCMPix *, int, long *, ITK *, BOOL))objc_msgSend)(
        transform, selector, matrix, referencePix[0], movingPix[0], (int)reference.slices, &length, itk, rescale);
    [itk release];
    return out;
}

static std::vector<float> rampVolume(const Series &s) {
    std::vector<float> v(s.width * s.height * s.slices);
    for (long k = 0; k < s.slices; k++)
        for (long j = 0; j < s.height; j++)
            for (long i = 0; i < s.width; i++) {
                double p[3];
                position(s, i, j, k, s.spacingX, s.spacingY, p);
                v[(k * s.height + j) * s.width + i] = ramp(p);
            }
    return v;
}

// Where p falls in the moving series, in voxels; inside means between the
// centres of its first and last voxels on every axis.
static bool inside(const Series &s, const double *p, double margin) {
    double d[3] = {p[0] - s.origin[0], p[1] - s.origin[1], p[2] - s.origin[2]};
    double i = (d[0]*s.row[0] + d[1]*s.row[1] + d[2]*s.row[2]) / s.spacingX;
    double j = (d[0]*s.column[0] + d[1]*s.column[1] + d[2]*s.column[2]) / s.spacingY;
    double k = (d[0]*s.normal[0] + d[1]*s.normal[1] + d[2]*s.normal[2]) / s.interval;
    return i >= margin && j >= margin && k >= margin
        && i <= s.width - 1 - margin && j <= s.height - 1 - margin && k <= s.slices - 1 - margin;
}

// Worst difference between an output voxel and the ramp at its DICOM
// position, over the voxels inside the moving volume; *count gets how many.
static double worst(Class transform, const Series &moving, const Series &reference, BOOL rescale, long *count) {
    std::vector<float> volume = rampVolume(moving);
    float *out = run(transform, moving, reference, rescale, volume);
    if (!out) { *count = -1; return INFINITY; }
    double spacingX = rescale ? reference.spacingX : moving.spacingX;
    double spacingY = rescale ? reference.spacingY : moving.spacingY;
    long width = rescale ? reference.width : moving.width, height = rescale ? reference.height : moving.height;
    double error = 0;
    *count = 0;
    for (long k = 0; k < reference.slices; k++)
        for (long j = 0; j < height; j++)
            for (long i = 0; i < width; i++) {
                double p[3];
                position(reference, i, j, k, spacingX, spacingY, p);
                if (!inside(moving, p, 0.01)) continue;
                double e = fabs(out[(k * height + j) * width + i] - ramp(p));
                if (e > error) error = e;
                (*count)++;
            }
    free(out);
    return error;
}

int main() {
    @autoreleasepool {
        const double zero[3] = {0, 0, 0}, x[3] = {1, 0, 0}, y[3] = {0, 1, 0}, minusZ[3] = {0, 0, -1};
        // tools/generate-volume-geometry-fixture.py --also-isotropic: "regular" (reference)
        // 64 x 64, 0.5 mm, 16 slices 2 mm apart; "isotropic" (moving) 1 mm, 16 slices 1 mm apart.
        Series regular = series(zero, x, y, 0.5, 0.5, 2, 2, 64, 64, 16);
        Series isotropic = series(zero, x, y, 1, 1, 1, 1, 64, 64, 16);
        // Thickness that is not the interval, and an origin off the grid.
        const double off[3] = {-20.3, 11.7, -4.1};
        Series thick = series(off, x, y, 0.8, 0.6, 1.5, 5, 48, 40, 20);
        Series thin = series(off, x, y, 0.35, 0.45, 2.5, 0.5, 96, 80, 10);
        // A coronal reference on an axial moving series, and an oblique moving series.
        const double coronalOrigin[3] = {-20, 5, 10};
        Series coronal = series(coronalOrigin, x, minusZ, 0.7, 0.9, 1.25, 1.25, 40, 24, 12);
        const double obliqueRow[3] = {cos(0.5), sin(0.5), 0}, obliqueColumn[3] = {-sin(0.5) * cos(0.3), cos(0.5) * cos(0.3), sin(0.3)};
        const double obliqueOrigin[3] = {-5, -2, -3};
        Series oblique = series(obliqueOrigin, obliqueRow, obliqueColumn, 0.9, 1.1, 1.3, 3, 40, 40, 24);
        const double axialOrigin[3] = {-10, -8, -6};
        Series axial = series(axialOrigin, x, y, 0.6, 0.6, 1.7, 1.7, 48, 48, 12);

        struct Case { const char *name; Series moving, reference; } cases[] = {
            {"isotropic onto regular", isotropic, regular},
            {"regular onto isotropic", regular, isotropic},
            {"thickness 5 onto thickness 0.5", thick, thin},
            {"thickness 0.5 onto thickness 5", thin, thick},
            {"axial onto coronal", thick, coronal},
            {"oblique onto axial", oblique, axial},
        };
        for (const Case &c : cases)
            for (int rescale = 0; rescale < 2; rescale++) {
                long count = 0;
                double error = worst([ITKTransform class], c.moving, c.reference, rescale, &count);
                printf("%-32s rescale %-3s  %6ld voxels inside  worst %.2g\n", c.name, rescale ? "YES" : "NO", count, error);
                check(count > 100, "%s: too few voxels inside the moving volume (%ld)", c.name, count);
                check(error < 0.05, "%s rescale %d: the sampled point is not the shown point (%.3f)", c.name, rescale, error);
#if HAVE_BEFORE
                long countBefore = 0;
                double errorBefore = worst([ITKTransformBefore class], c.moving, c.reference, rescale, &countBefore);
                printf("%-32s rescale %-3s  before the fix: worst %.3g\n", c.name, rescale ? "YES" : "NO", errorBefore);
                check(errorBefore > 1, "%s rescale %d: the method before the fix should be off by half a voxel", c.name, rescale);
#endif
            }

        // The report, pixel by pixel: slice picture of the fixture (a bar whose height is
        // the slice's place, a rail at the left), rescale NO. Output slice 1 (z = 2 mm)
        // is the moving slice 2; every output slice k inside the moving stack is slice 2k.
        std::vector<float> bars(64 * 64 * 16, 0);
        for (long k = 0; k < 16; k++) {
            long top = 63 - (60 * k) / 15;
            for (long j = 0; j < 64; j++)
                for (long i = 0; i < 64; i++) {
                    float v = (i < 2) ? 500 : 0;
                    if (j >= (top - 2 > 0 ? top - 2 : 0) && j < top + 2 && i >= 16 && i < 48) v = 2000;
                    bars[(k * 64 + j) * 64 + i] = v;
                }
        }
        float *out = run([ITKTransform class], isotropic, regular, NO, bars);
        check(out != NULL, "no output");
        if (out) {
            for (long k = 0; k < 8; k++) {
                long differing = 0, bright = 0;
                for (long n = 0; n < 64 * 64; n++) {
                    if (fabsf(out[k * 64 * 64 + n] - bars[2 * k * 64 * 64 + n]) > 1e-3) differing++;
                    if (out[k * 64 * 64 + n] > 1000) bright++;
                }
                check(differing == 0, "output slice %ld (z = %ld mm) differs from moving slice %ld in %ld pixels", k, 2 * k, 2 * k, differing);
                check(bright == 128 || (k == 0 && bright == 96), "output slice %ld: %ld pixels above 1000", k, bright);
            }
            free(out);
        }
    }
    if (failures) { printf("%d failure(s)\n", failures); return 1; }
    printf("ok\n");
    return 0;
}
'''

with tempfile.TemporaryDirectory() as folder:
    folder = Path(folder)
    (folder / 'DCMPix.h').write_text(STUB_DCMPIX)
    for name in ('ITK.h', 'ITK.mm'):
        (folder / name).write_bytes((sources / name).read_bytes())
    code = HARNESS.replace('@@CURRENT@@', current).replace('@@BEFORE@@', before or '')
    code = code.replace('#import <Cocoa/Cocoa.h>', '#import <Cocoa/Cocoa.h>\n#import <objc/message.h>\n#define HAVE_BEFORE %d' % (1 if before else 0), 1)
    (folder / 'harness.mm').write_text(code, encoding='latin1')
    libraries = sorted(str(p) for p in (itk / 'lib').glob('lib*.a'))
    command = ['xcrun', 'clang++', '-std=c++17', '-fno-objc-arc', '-w', '-O1', '-x', 'objective-c++',
               '-I', str(folder), '-I', str(itk / 'include'),
               str(folder / 'harness.mm'), str(folder / 'ITK.mm'),
               '-x', 'none', '-framework', 'Cocoa'] + libraries + ['-o', str(folder / 'harness')]
    built = subprocess.run(command, capture_output=True, text=True)
    if built.returncode:
        print(built.stderr[-4000:])
        sys.exit(1)
    result = subprocess.run([str(folder / 'harness')], capture_output=True, text=True)
    print(result.stdout, end='')
    if result.returncode:
        print(result.stderr[-2000:])
        sys.exit(1)
if not before:
    print('note: the method before the fix is not in this checkout\'s history; only the current one was run')
