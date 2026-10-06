#!/usr/bin/env python3
"""Camera copies keep their state, Quaternion rotates by the angle it is
given, a thick-slab Y reslice takes one path for all its threads, and
CurveFitter frees the simplex of the previous fit.

The real sources are compiled (Camera, Point3D, CurveFitter,
OrthogonalReslice and ResliceCacheLayout in Swift, Quaternion.mm and
N3Geometry.m in Objective-C), under AddressSanitizer, and driven as the app
drives them:

- camera-copy: -[Camera initWithCamera:], which -copy is and the MPR undo
  stores, did not take the index, the 4D state and movie index, the roll,
  the LOD or forceUpdate. A copy must keep all of them, and every property
  the copy already kept.
- camera-planes: -setCroppingPlanes: stored -copy of the array, an immutable
  NSArray, under the NSMutableArray type (and so did -initWithCamera:), so
  VRView's -replaceObjectAtIndex:withObject: on the planes raised. The planes
  must be a mutable copy, independent of the array given and of the copies.
- quaternion: the axis-angle constructors and -fromAxis multiplied the angle
  in degrees by 180 instead of dividing, and length() returned the squared
  norm, so normalize() left non-unit quaternions off the unit sphere; and
  the product passed its scalar part where the constructor takes x, so every
  component of every product moved by one (i j came out as i, not k). Known
  rotations must come out: 90 degrees about z takes x to y, 120 degrees about
  (1, 1, 1) takes x to y, 180 about x takes y to -y; lengths are norms, and
  an axis of any length gives the same rotation (FlyAssistant passes
  non-unit axes).
- reslice-race: the Y reslice's threads each asked the cache queue whether
  the cache was full. A thick-slab reslice started while the cache filled
  could have one thread read the images and another the cache, and with a
  positive slice interval the two paths fill mirrored bands, so some rows
  were written twice and others not at all. The double makes that happen on
  every run: the reslice runs on two threads (a detached one and the
  caller's); the cache fill blocks until the detached thread reads the images
  directly, which then lets the fill finish before the caller's thread goes
  on. Every row of every image must be right.
- reslice-cache: once the cache is full, the reslice reads it (no thread
  reads the images) and the rows are right.
- reslice-free: -freeYCache (setUseYcache:NO, which the 4D viewers call on a
  frame change) freed the cache under the operations still filling it, which
  then wrote into freed memory. It must cancel the pending ones and wait for
  the running ones; AddressSanitizer reports the write otherwise.
- fitter-values: a straight line and a fourth-degree fit, repeated and
  alternated, find the known parameters of y = 2x + 1.
- fitter-leak: -doFit: called -initialize, which allocated a new simplex and
  next vertex over the previous ones. Run under `leaks --atExit`, 40 extra
  fits must leak no more blocks than one fit does (AddressSanitizer's leak
  detection is not supported on macOS).

`<git revision>` as an optional argument reads the sources from that
revision, the negative control.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import os
import re
import shutil
import subprocess
import sys
import tempfile

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def source(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}'])
    return (root / path).read_bytes()


if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc, clang)', file=sys.stderr)
    sys.exit(SKIPPED)

GEOMETRY_SWIFT = ['Horos/Sources/Camera.swift', 'Horos/Sources/Point3D.swift', 'Horos/Sources/CurveFitter.swift']
GEOMETRY_HEADERS = ['Horos/Sources/Camera.h', 'Horos/Sources/Point3D.h', 'Horos/Sources/CurveFitter.h',
                    'Horos/Sources/Quaternion.h', 'Nitrogen/Sources/N3Geometry.h']
GEOMETRY_OBJC = ['Nitrogen/Sources/N3Geometry.m', 'Horos/Sources/Quaternion.mm']

RESLICE_SWIFT = ['Horos/Sources/OrthogonalReslice.swift', 'Horos/Sources/ResliceCacheLayout.swift']
RESLICE_HEADERS = ['Horos/Sources/HorosObjCException.h']
RESLICE_OBJC = ['Horos/Sources/HorosObjCException.m']

GEOMETRY_MAIN = r'''
#import <Cocoa/Cocoa.h>
#import "Camera.h"
#import "CurveFitter.h"
#import "Quaternion.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0;
#define CHECK(c, ...) do { if (!(c)) { printf("FAIL: "); printf(__VA_ARGS__); printf("\n"); failures++; } } while (0)

static BOOL samePlane(N3Plane a, N3Plane b) {
    return N3VectorDistance(a.point, b.point) < 1e-12 && N3VectorDistance(a.normal, b.normal) < 1e-12;
}

static void cameraCopy(void) {
    Camera *c = [[[Camera alloc] init] autorelease];
    c.position = [Point3D pointWithX:12.25 y:-19.5 z:450.75];
    c.focalPoint = [Point3D pointWithX:1.5 y:2.25 z:3.75];
    c.viewUp = [Point3D pointWithX:0 y:0 z:1];
    c.clippingRangeNear = 2.25; c.clippingRangeFar = 512.5;
    c.viewAngle = 30; c.eyeAngle = 2; c.parallelScale = 74.25;
    c.wl = -40.25; c.ww = 350.5; c.fusionPercentage = 63.75;
    c.windowCenterX = 0.125; c.windowCenterY = -0.25;
    c.index = 7; c.is4D = YES; c.movieIndexIn4D = 3; c.rollAngle = 12.5; c.LOD = 2.5; c.forceUpdate = YES;

    Camera *copy = [[c copy] autorelease];
    CHECK(copy.index == 7, "the copy's index is %d, not 7", copy.index);
    CHECK(copy.is4D, "the copy is not 4D");
    CHECK(copy.movieIndexIn4D == 3, "the copy's 4D movie index is %ld, not 3", (long)copy.movieIndexIn4D);
    CHECK(copy.rollAngle == 12.5f, "the copy's roll is %g, not 12.5", copy.rollAngle);
    CHECK(copy.LOD == 2.5f, "the copy's LOD is %g, not 2.5", copy.LOD);
    CHECK(copy.forceUpdate, "the copy lost forceUpdate");
    // What the copy already kept.
    CHECK(copy.position != c.position && copy.position.x == 12.25f && copy.position.z == 450.75f, "position");
    CHECK(copy.focalPoint.y == 2.25f && copy.viewUp.z == 1, "focal point and view up");
    CHECK(copy.clippingRangeNear == 2.25f && copy.clippingRangeFar == 512.5f, "clipping range");
    CHECK(copy.viewAngle == 30 && copy.eyeAngle == 2 && copy.parallelScale == 74.25f, "angles and scale");
    CHECK(copy.wl == -40.25f && copy.ww == 350.5f && copy.fusionPercentage == 63.75f, "window and fusion");
    CHECK(copy.windowCenterX == 0.125f && copy.windowCenterY == -0.25f, "window center");
    CHECK([[copy exportToXML] isEqual:[c exportToXML]], "the copy exports differently");

    // A camera with nothing set copies as zeros, and a nil camera too.
    Camera *blank = [[[[Camera alloc] init] autorelease] copy];
    CHECK(blank.index == 0 && !blank.is4D && blank.movieIndexIn4D == 0 && blank.LOD == 0 && !blank.forceUpdate,
          "a blank camera copies as zeros");
    [blank release];
    if (!failures) printf("a copy keeps index 7, 4D frame 3, roll 12.5, LOD 2.5, forceUpdate and every other property\n");
}

static void cameraPlanes(void) {
    N3Plane given[6];
    NSMutableArray *planes = [NSMutableArray array];
    for (int i = 0; i < 6; i++) {
        given[i] = N3PlaneMake(N3VectorMake(i, 2 * i, 3 * i), N3VectorMake(0, 0, 1));
        [planes addObject:[NSValue valueWithN3Plane:given[i]]];
    }
    Camera *c = [[[Camera alloc] init] autorelease];
    c.croppingPlanes = planes;
    N3Plane replaced = N3PlaneMake(N3VectorMake(9, 9, 9), N3VectorMake(1, 0, 0));
    @try {
        [c.croppingPlanes replaceObjectAtIndex:0 withObject:[NSValue valueWithN3Plane:replaced]];
        CHECK(samePlane([c.croppingPlanes[0] N3PlaneValue], replaced), "the replaced plane did not stick");
    } @catch (NSException *e) {
        CHECK(0, "replacing a plane after -setCroppingPlanes: raised %s", e.reason.UTF8String);
    }
    CHECK(samePlane([planes[0] N3PlaneValue], given[0]), "the setter shares the array it was given");

    Camera *copy = [[c copy] autorelease];
    CHECK(copy.croppingPlanes != c.croppingPlanes, "the copy shares the planes");
    @try {
        [copy.croppingPlanes replaceObjectAtIndex:1 withObject:[NSValue valueWithN3Plane:replaced]];
    } @catch (NSException *e) {
        CHECK(0, "replacing a plane of a copy raised %s", e.reason.UTF8String);
    }
    CHECK(samePlane([c.croppingPlanes[1] N3PlaneValue], given[1]), "a copy's planes change the original's");
    CHECK(copy.croppingPlanes.count == 6, "the copy has %lu planes", (unsigned long)copy.croppingPlanes.count);

    c.croppingPlanes = nil;
    CHECK(c.croppingPlanes == nil, "nil planes are kept nil");
    if (!failures) printf("the planes are a mutable copy after the setter and after -copy\n");
}

static BOOL near(N3Vector a, N3Vector b, float tolerance) {
    return fabs(a.x - b.x) < tolerance && fabs(a.y - b.y) < tolerance && fabs(a.z - b.z) < tolerance;
}
#define VEC(v) (double)(v).x, (double)(v).y, (double)(v).z

static void quaternion(void) {
    const float tol = 1e-5f;
    N3Vector x = N3VectorMake(1, 0, 0), y = N3VectorMake(0, 1, 0), z = N3VectorMake(0, 0, 1);

    Quaternion aboutZ(z, 90);
    N3Vector r = aboutZ * x;
    CHECK(near(r, y, tol), "90 degrees about z takes x to (%g, %g, %g), not y", VEC(r));

    Quaternion aboutX(x, 180);
    r = aboutX * y;
    CHECK(near(r, N3VectorMake(0, -1, 0), tol), "180 degrees about x takes y to (%g, %g, %g), not -y", VEC(r));

    // The classic: 120 degrees about the diagonal permutes the axes.
    Quaternion diagonal(N3VectorMake(1, 1, 1), 120);
    r = diagonal * x;
    CHECK(near(r, y, tol), "120 degrees about (1, 1, 1) takes x to (%g, %g, %g), not y", VEC(r));
    r = diagonal * y;
    CHECK(near(r, z, tol), "120 degrees about (1, 1, 1) takes y to (%g, %g, %g), not z", VEC(r));

    // Components: half angles of 30 degrees for a rotation of 60.
    Quaternion q;
    q.fromAxis(0, 1, 0, 60);
    CHECK(fabs(q.getW() - cosf(M_PI / 6)) < tol && fabs(q.getY() - sinf(M_PI / 6)) < tol &&
          fabs(q.getX()) < tol && fabs(q.getZ()) < tol,
          "60 degrees about y is (%g, %g, %g, %g), not (0, 0.5, 0, 0.866)", q.getX(), q.getY(), q.getZ(), q.getW());

    // The axis length does not change the rotation (FlyAssistant's axes are not unit).
    Quaternion longAxis(N3VectorMake(0, 0, 2.5f), 90);
    r = longAxis * x;
    CHECK(near(r, y, tol), "90 degrees about (0, 0, 2.5) takes x to (%g, %g, %g), not y", VEC(r));
    Quaternion slanted(N3VectorMake(-0.5f, 1, 0), -45);
    Quaternion slantedUnit(N3VectorMake(-0.5f / sqrtf(1.25f), 1 / sqrtf(1.25f), 0), -45);
    N3Vector v = N3VectorMake(1, 2, 3);
    CHECK(near(slanted * v, slantedUnit * v, tol), "a non-unit axis rotates otherwise than its unit vector");
    r = slanted * v;
    CHECK(fabs(N3VectorLength(r) - N3VectorLength(v)) < 1e-4f, "a rotation changed a length to %g", N3VectorLength(r));

    // Degrees, not radians times 180: 360 degrees is the identity.
    Quaternion full(N3VectorMake(0.3f, -0.4f, 0.5f), 360);
    CHECK(near(full * v, v, 1e-4f), "360 degrees moves (1, 2, 3) to (%g, %g, %g)", VEC(full * v));

    // The Point3D forms.
    Point3D *axis = [Point3D pointWithX:0 y:0 z:1];
    Quaternion fromPoint(axis, 90);
    Point3D *p = fromPoint * [Point3D pointWithX:1 y:0 z:0];
    CHECK(fabs(p.x) < tol && fabs(p.y - 1) < tol && fabs(p.z) < tol,
          "the Point3D form takes x to (%g, %g, %g), not y", p.x, p.y, p.z);
    Quaternion again;
    again.fromAxis(axis, 90);
    CHECK(near(again * x, y, tol), "fromAxis(Point3D) takes x elsewhere");
    Quaternion byVector;
    byVector.fromAxis(z, 90);
    CHECK(near(byVector * x, y, tol), "fromAxis(N3Vector) takes x elsewhere");

    // FlyAssistant composes two: -45 about a tilted y, then -45 about a tilted x.
    Quaternion xRot(N3VectorMake(-2, 1, 0), -45), yRot(N3VectorMake(-3, 0, 1), -45);
    N3Vector d = N3VectorMake(1, 2, 3);
    N3Vector composed = yRot * xRot * d;
    N3Vector stepwise = yRot * (xRot * d);
    CHECK(near(composed, stepwise, 1e-4f), "a product of rotations is not their composition");
    CHECK(fabs(N3VectorLength(composed) - N3VectorLength(d)) < 1e-4f, "the composition changed a length");

    // The Hamilton product: i j = k, j i = -k, i i = -1.
    Quaternion i(1, 0, 0, 0), j(0, 1, 0, 0);
    Quaternion ij = i * j, ji = j * i, ii = i * i;
    CHECK(ij.getX() == 0 && ij.getY() == 0 && ij.getZ() == 1 && ij.getW() == 0,
          "i j is (%g, %g, %g, %g), not k", ij.getX(), ij.getY(), ij.getZ(), ij.getW());
    CHECK(ji.getZ() == -1 && ji.getW() == 0, "j i is (%g, %g, %g, %g), not -k", ji.getX(), ji.getY(), ji.getZ(), ji.getW());
    CHECK(ii.getW() == -1 && ii.getX() == 0, "i i is (%g, %g, %g, %g), not -1", ii.getX(), ii.getY(), ii.getZ(), ii.getW());

    // length() is the norm; normalize() makes it 1.
    Quaternion unnormalized(1, 2, 2, 4);
    CHECK(fabs(unnormalized.length() - 5) < tol, "the length of (1, 2, 2, 4) is %g, not 5", unnormalized.length());
    Quaternion three(3, 0, 0, 0);
    three.setW(4);
    CHECK(fabs(three.length() - 1) < tol && fabs(three.getX() - 0.6f) < tol && fabs(three.getW() - 0.8f) < tol,
          "(3, 0, 0, 4) normalizes to (%g, %g, %g, %g), not (0.6, 0, 0, 0.8)",
          three.getX(), three.getY(), three.getZ(), three.getW());
    Quaternion zero;
    zero.normalize();
    CHECK(zero.getW() == 0 && zero.getX() == 0, "normalizing zero gave NaN");
    if (!failures) printf("90 about z, 180 about x, 120 about the diagonal, 360, non-unit axes and norms are right\n");
}

static double xs[10], ys[10];

static CurveFitter *fitter(void) {
    for (int i = 0; i < 10; i++) { xs[i] = i; ys[i] = 2.0 * i + 1.0; }
    return [[CurveFitter alloc] initCurveFitterWithXData:xs andYData:ys length:10];
}

static void checkLine(CurveFitter *f, const char *after) {
    double *p = [f getParams];
    CHECK(fabs(p[0] - 1) < 1e-3 && fabs(p[1] - 2) < 1e-3, "after %s the line is y = %g + %g x, not 1 + 2x", after, p[0], p[1]);
}

static void fitterValues(void) {
    CurveFitter *f = fitter();
    [f doFit:0];                    // STRAIGHT_LINE, 3 vertices
    checkLine(f, "one fit");
    for (int i = 0; i < 5; i++) [f doFit:0];
    checkLine(f, "six fits");
    [f doFit:3];                    // POLY4, 6 vertices
    double *p = [f getParams];
    CHECK(fabs(p[0] - 1) < 0.05 && fabs(p[1] - 2) < 0.05 && fabs(p[2]) < 0.05 && fabs(p[3]) < 0.01 && fabs(p[4]) < 0.001,
          "the fourth-degree fit is %g + %g x + %g x2 + %g x3 + %g x4", p[0], p[1], p[2], p[3], p[4]);
    [f doFit:0];                    // back to 3 vertices
    checkLine(f, "a fourth-degree fit and a line");
    [f release];
    if (!failures) printf("repeated and alternated fits find y = 1 + 2x\n");
}

int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 2) return 64;
    if (!strcmp(argv[1], "camera-copy")) cameraCopy();
    else if (!strcmp(argv[1], "camera-planes")) cameraPlanes();
    else if (!strcmp(argv[1], "quaternion")) quaternion();
    else if (!strcmp(argv[1], "fitter-values")) fitterValues();
    else if (!strcmp(argv[1], "fitter-leak")) {
        // The fitter is released: what is left unreachable at exit leaked.
        int fits = argc > 2 ? atoi(argv[2]) : 1;
        CurveFitter *f = fitter();
        for (int i = 0; i < fits; i++) [f doFit:(i % 2) ? 1 : 0];
        [f release];
        printf("%d fits\n", fits);
    }
    else { printf("FAIL: unknown case %s\n", argv[1]); return 64; }
    return failures ? 1 : 0;
} }
'''

# DCMPix as OrthogonalReslice reaches it, with the hooks that stage the cache
# fill against the reslice threads.
RESLICE_DCMPIX_H = r'''
#import <Cocoa/Cocoa.h>
@interface DCMPix:NSObject { float *_pixels; float _cosines[9]; }
@property long pwidth,pheight;
@property double pixelSpacingX,pixelSpacingY,pixelRatio,sliceInterval,sliceThickness,sliceLocation,originX,originY,originZ;
@property BOOL isRGB,displayInverted;
@property BOOL isSource;
@property(retain) NSString *frameofReferenceUID,*modalityString;
@property(setter=setID:) long ID;
@property long frameNo;
@property(getter=Tot, setter=setTot:) long Tot;
-(id)initWithData:(float*)data :(short)bits :(long)w :(long)h :(float)sx :(float)sy :(float)x :(float)y :(float)z :(BOOL)rgb;
@property(readonly) float* fImage;
-(void)orientation:(float*)o; -(void)setOrientation:(float*)o; -(void)setOrigin:(float*)o;
-(void)copySUVfrom:(DCMPix*)p;
-(void)computeSliceLocation;
@end
extern void _N2LogExceptionImpl(NSException* e, BOOL logStack, const char* pf);

// 0: the fill runs freely. 1: race -- the fill waits for the gate, and the
// first detached thread to read the images opens it, waits for the fill to
// finish, and only then lets the caller's thread go on. 2: the fill waits
// for the gate, which the driver opens.
void HarnessSetMode(int mode);
void HarnessOpenGate(void);
int HarnessWaitFill(void);
int HarnessDirectReads(void);
void HarnessResetDirectReads(void);
int HarnessRaceRan(void);
int HarnessMainTimedOut(void);
void HarnessAfterDetach(void);
'''

RESLICE_DCMPIX_M = r'''
#import "DCMPix.h"
#include <stdatomic.h>
#include <unistd.h>

static int gMode;
static dispatch_semaphore_t gGate, gWorkerDone;
static atomic_int gGateOpened, gDirectReads, gRaceArmed, gRaceRan, gMainHeld, gMainTimedOut;
static NSOperationQueue *gFillQueue;
static NSLock *gLock;

__attribute__((constructor)) static void setUp(void) { gLock = [NSLock new]; HarnessSetMode(0); }

void HarnessSetMode(int mode) {
    gMode = mode;
    gGate = dispatch_semaphore_create(0);
    atomic_store(&gGateOpened, 0);
    if (mode == 0) HarnessOpenGate();
    gWorkerDone = dispatch_semaphore_create(0);
    atomic_store(&gRaceArmed, mode == 1);
    atomic_store(&gRaceRan, 0);
    atomic_store(&gMainHeld, 0);
    atomic_store(&gMainTimedOut, 0);
    [gLock lock]; [gFillQueue release]; gFillQueue = nil; [gLock unlock];
}

void HarnessOpenGate(void) {
    if (atomic_exchange(&gGateOpened, 1) == 0) dispatch_semaphore_signal(gGate);
}

int HarnessWaitFill(void) {
    for (int i = 0; i < 1000; i++) {
        [gLock lock]; NSOperationQueue *q = [gFillQueue retain]; [gLock unlock];
        if (q) {
            [q waitUntilAllOperationsAreFinished];
            for (int j = 0; j < 500 && q.operationCount > 0; j++) usleep(10000);
            [q release];
            return 1;
        }
        usleep(10000);
    }
    return 0;
}

int HarnessDirectReads(void) { return atomic_load(&gDirectReads); }
void HarnessResetDirectReads(void) { atomic_store(&gDirectReads, 0); }
int HarnessRaceRan(void) { return atomic_load(&gRaceRan); }
int HarnessMainTimedOut(void) { return atomic_load(&gMainTimedOut); }

void HarnessAfterDetach(void) {
    if (gMode == 1 && atomic_exchange(&gMainHeld, 1) == 0) {
        if (dispatch_semaphore_wait(gWorkerDone, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)))
            atomic_store(&gMainTimedOut, 1);
    }
}

void _N2LogExceptionImpl(NSException* e, BOOL logStack, const char* pf) { NSLog(@"%@", e); }

@implementation DCMPix
@synthesize ID, frameNo, Tot;
-(id)initWithData:(float*)data :(short)bits :(long)w :(long)h :(float)sx :(float)sy :(float)x :(float)y :(float)z :(BOOL)rgb {
    if ((self = [super init])) {
        self.pwidth = w; self.pheight = h; self.pixelSpacingX = sx; self.pixelSpacingY = sy;
        self.originX = x; self.originY = y; self.originZ = z; self.isRGB = rgb;
        _pixels = calloc(w * h, sizeof(float));
        _cosines[0] = _cosines[4] = _cosines[8] = 1;
    }
    return self;
}
-(float*)fImage {
    if (self.isSource) {
        NSOperationQueue *q = [NSOperationQueue currentQueue];
        if (q && q != [NSOperationQueue mainQueue]) {
            // A cache fill operation: remember its queue, wait for the gate.
            [gLock lock];
            if (gFillQueue != q) { [gFillQueue release]; gFillQueue = [q retain]; }
            [gLock unlock];
            dispatch_semaphore_wait(gGate, DISPATCH_TIME_FOREVER);
            dispatch_semaphore_signal(gGate);
        } else {
            // A reslice thread reading the images, not the cache.
            atomic_fetch_add(&gDirectReads, 1);
            if (![NSThread isMainThread] && atomic_exchange(&gRaceArmed, 0)) {
                HarnessOpenGate();
                if (HarnessWaitFill()) atomic_store(&gRaceRan, 1);
                dispatch_semaphore_signal(gWorkerDone);
            }
        }
    }
    return _pixels;
}
-(void)orientation:(float*)o { memcpy(o, _cosines, sizeof(_cosines)); }
-(void)setOrientation:(float*)o {
    memcpy(_cosines, o, sizeof(_cosines));
    _cosines[6] = o[1]*o[5]-o[2]*o[4]; _cosines[7] = o[2]*o[3]-o[0]*o[5]; _cosines[8] = o[0]*o[4]-o[1]*o[3];
}
-(void)setOrigin:(float*)o { self.originX = o[0]; self.originY = o[1]; self.originZ = o[2]; }
-(void)copySUVfrom:(DCMPix*)p {}
-(void)computeSliceLocation { self.sliceLocation = self.originX*_cosines[6]+self.originY*_cosines[7]+self.originZ*_cosines[8]; }
-(void)dealloc { free(_pixels); [_frameofReferenceUID release]; [_modalityString release]; [super dealloc]; }
@end
'''

# Module-level types shadow Foundation's inside the module: the reslice runs
# on two threads, and the caller's thread passes through the hook right after
# it detaches the other.
RESLICE_SHIMS = r'''
import Foundation

final class ProcessInfo {
    static let processInfo = ProcessInfo()
    var processorCount: Int { 2 }
}

final class Thread {
    static func detachNewThreadSelector(_ selector: Selector, toTarget target: Any, with argument: Any?) {
        Foundation.Thread.detachNewThreadSelector(selector, toTarget: target, with: argument)
        HarnessAfterDetach()
    }

    static func sleep(forTimeInterval interval: TimeInterval) {
        Foundation.Thread.sleep(forTimeInterval: interval)
    }
}
'''

RESLICE_MAIN = r'''
import Foundation

func fail(_ message: String) -> Never {
    print("FAIL: \(message)")
    fflush(stdout)
    exit(1)
}

// 7 x 5 images, 4 slices 1 mm apart (a positive interval), voxel (x, y, z)
// = 1 + x + 10 y + 100 z, so no right value is 0.
let width = 7, height = 5, slices = 4

func makeVolume() -> NSMutableArray {
    let list = NSMutableArray()
    for z in 0..<slices {
        let p: DCMPix = DCMPix(data: nil, 32, width, height, 1, 1, 0, 0, Float(z), false)
        p.sliceInterval = 1
        p.computeSliceLocation()
        let pixels: UnsafeMutablePointer<Float> = p.fImage
        for y in 0..<height { for x in 0..<width { pixels[y * width + x] = Float(1 + x + 10 * y + 100 * z) } }
        p.isSource = true
        list.add(p)
    }
    return list
}

/// A Y reslice at column c: rows are slices, last slice first; row r, x is
/// the source voxel (c, x, slices - 1 - r).
func wrongRows(_ r: OrthogonalReslice, columns: [Int]) -> String? {
    let planes = r.yReslicedDCMPixList!
    if planes.count != columns.count { return "\(planes.count) images, not \(columns.count)" }
    var problems = [String]()
    for (k, column) in columns.enumerated() {
        let p = planes.object(at: k) as! DCMPix
        let pixels: UnsafeMutablePointer<Float> = p.fImage
        var bad = [String]()
        for row in 0..<slices {
            for x in 0..<height {
                let expected = Float(1 + column + 10 * x + 100 * (slices - 1 - row))
                let actual = pixels[row * height + x]
                if actual != expected { bad.append("row \(row) reads \(actual) for \(expected)"); break }
            }
        }
        if !bad.isEmpty { problems.append("image \(k) (column \(column)): " + bad.joined(separator: ", ")) }
    }
    return problems.isEmpty ? nil : problems.joined(separator: "; ")
}

switch CommandLine.arguments[1] {
case "reslice-race":
    let list = makeVolume()
    let r = OrthogonalReslice(originalDCMPixList: list)
    r.thickSlab = 2
    HarnessSetMode(1)
    HarnessResetDirectReads()
    r.yReslice(3)
    if HarnessMainTimedOut() != 0 || HarnessRaceRan() == 0 {
        fail("the scenario did not run: the detached thread never read the images while the cache filled")
    }
    if let wrong = wrongRows(r, columns: [2, 3]) {
        fail("a thick-slab Y reslice started while the cache filled has wrong rows: \(wrong)")
    }
    _ = HarnessWaitFill()
    print("both threads read the images while the cache filled; every row of both images is right")

case "reslice-cache":
    let list = makeVolume()
    let r = OrthogonalReslice(originalDCMPixList: list)
    r.thickSlab = 2
    HarnessSetMode(0)
    r.yReslice(3)
    if HarnessWaitFill() == 0 { fail("the cache was never filled") }
    HarnessResetDirectReads()
    r.yReslice(4)
    if HarnessDirectReads() != 0 { fail("a full cache was not read: \(HarnessDirectReads()) direct image reads") }
    if let wrong = wrongRows(r, columns: [3, 4]) { fail("the reslice from the full cache has wrong rows: \(wrong)") }
    print("with the cache full, the reslice reads only the cache and every row is right")

case "reslice-free":
    let list = makeVolume()
    let r = OrthogonalReslice(originalDCMPixList: list)
    r.thickSlab = 2
    HarnessSetMode(2)
    r.yReslice(3)
    if let wrong = wrongRows(r, columns: [2, 3]) { fail("the reslice while the cache filled has wrong rows: \(wrong)") }
    // The fill is still running (held at the gate); let it go shortly after
    // the cache is released. Freed under it, its writes land in freed memory.
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { HarnessOpenGate() }
    r.useYcache = false
    _ = HarnessWaitFill()
    // And the cache comes back when it is allowed again.
    HarnessSetMode(0)
    r.useYcache = true
    r.yReslice(3)
    if HarnessWaitFill() == 0 { fail("the cache was not filled again") }
    HarnessResetDirectReads()
    r.yReslice(3)
    if HarnessDirectReads() != 0 { fail("the cache allowed again was not read") }
    if let wrong = wrongRows(r, columns: [2, 3]) { fail("the reslice from the new cache has wrong rows: \(wrong)") }
    print("releasing the cache while it filled waited for the fill; the cache came back and reads right")

default:
    fail("unknown case \(CommandLine.arguments[1])")
}
exit(0)
'''

CASES = [
    ('camera-copy', 'a Camera copy keeps its index, 4D state, roll, LOD and forceUpdate'),
    ('camera-planes', 'a Camera keeps its cropping planes in a mutable copy'),
    ('quaternion', 'Quaternion rotates by the angle in degrees and length() is the norm'),
    ('fitter-values', 'CurveFitter finds the known line through repeated and alternated fits'),
    ('reslice-race', 'a thick-slab Y reslice started while the cache fills takes one path on all threads'),
    ('reslice-cache', 'a thick-slab Y reslice reads the full cache'),
    ('reslice-free', 'releasing the Y cache waits for the operations filling it'),
]


def run(command, **kwargs):
    return subprocess.run(command, check=True, capture_output=True, **kwargs)


def detail(result):
    lines = [line for line in (result.stdout + result.stderr).splitlines() if line.strip()]
    return '; '.join(line[len('FAIL: '):] for line in lines if line.startswith('FAIL:')) or \
        next((line for line in lines if 'ERROR: AddressSanitizer' in line), None) or \
        (lines[-1] if lines else f'exit {result.returncode}')


failures = []
with tempfile.TemporaryDirectory(prefix='horos-geometry-775-') as tmp:
    tmp = Path(tmp)
    geometry, reslice = tmp / 'geometry', tmp / 'reslice'
    geometry.mkdir()
    reslice.mkdir()
    for path in GEOMETRY_SWIFT + GEOMETRY_HEADERS + GEOMETRY_OBJC:
        (geometry / Path(path).name).write_bytes(source(path))
    for path in RESLICE_SWIFT + RESLICE_HEADERS + RESLICE_OBJC:
        (reslice / Path(path).name).write_bytes(source(path))
    (geometry / 'bridging.h').write_text('#define HOROS_BRIDGING_HEADER 1\n#import <Cocoa/Cocoa.h>\n'
                                         '#import "Camera.h"\n#import "CurveFitter.h"\n')
    (geometry / 'main.mm').write_text(GEOMETRY_MAIN)
    (reslice / 'DCMPix.h').write_text(RESLICE_DCMPIX_H)
    (reslice / 'DCMPixDouble.m').write_text(RESLICE_DCMPIX_M)
    (reslice / 'bridging.h').write_text('#define HOROS_BRIDGING_HEADER 1\n#import "DCMPix.h"\n'
                                        '#import "HorosObjCException.h"\n')
    (reslice / 'Shims.swift').write_text(RESLICE_SHIMS)
    (reslice / 'main.swift').write_text(RESLICE_MAIN)
    try:
        # The geometry harness twice: with AddressSanitizer, and plain for
        # `leaks`, which cannot read ASan's allocator.
        for variant, sanitize in (('asan', True), ('plain', False)):
            out = geometry / variant
            out.mkdir()
            swift_asan = ['-sanitize=address'] if sanitize else []
            clang_asan = ['-fsanitize=address'] if sanitize else []
            run(['xcrun', 'swiftc', '-swift-version', '5', '-module-name', 'Horos', '-parse-as-library', '-wmo', '-g',
                 *swift_asan, '-import-objc-header', str(geometry / 'bridging.h'),
                 '-Xcc', '-I' + str(geometry), '-emit-objc-header-path', str(out / 'Horos-Swift.h'),
                 '-c', *[str(geometry / Path(p).name) for p in GEOMETRY_SWIFT], '-o', str(out / 'geometry.o')])
            objects = [str(out / 'geometry.o')]
            for name, language in (('N3Geometry.m', 'objective-c'), ('Quaternion.mm', 'objective-c++'),
                                   ('main.mm', 'objective-c++')):
                obj = out / (Path(name).stem + '.o')
                run(['xcrun', 'clang', '-x', language, '-fno-objc-arc', '-g', *clang_asan,
                     '-Wno-deprecated-declarations', '-include', 'Cocoa/Cocoa.h',
                     '-I', str(out), '-I', str(geometry), '-c', str(geometry / name), '-o', str(obj)])
                objects.append(str(obj))
            run(['xcrun', 'swiftc', *swift_asan, *objects, '-lc++', '-framework', 'Cocoa', '-framework', 'QuartzCore',
                 '-framework', 'Accelerate', '-o', str(out / 'harness')])

        run(['xcrun', 'clang', '-fno-objc-arc', '-fsanitize=address', '-g', '-Wno-deprecated-declarations',
             '-I', str(reslice), '-c', str(reslice / 'DCMPixDouble.m'), '-o', str(reslice / 'double.o')])
        run(['xcrun', 'clang', '-fobjc-arc', '-fsanitize=address', '-g', '-I', str(reslice),
             '-c', str(reslice / 'HorosObjCException.m'), '-o', str(reslice / 'exception.o')])
        run(['xcrun', 'swiftc', '-swift-version', '5', '-module-name', 'Horos', '-sanitize=address', '-g', '-Onone',
             '-import-objc-header', str(reslice / 'bridging.h'), '-Xcc', '-I' + str(reslice),
             *[str(reslice / Path(p).name) for p in RESLICE_SWIFT], str(reslice / 'Shims.swift'),
             str(reslice / 'main.swift'), str(reslice / 'double.o'), str(reslice / 'exception.o'),
             '-framework', 'Cocoa', '-o', str(reslice / 'harness')])
    except subprocess.CalledProcessError as e:
        print('FAIL: the harness did not build:', (e.stderr or b'').decode(errors='replace')[-3000:])
        sys.exit(1)

    env = dict(os.environ, ASAN_OPTIONS='detect_leaks=0')
    for case, claim in CASES:
        binary = (reslice if case.startswith('reslice') else geometry / 'asan') / 'harness'
        try:
            result = subprocess.run([str(binary), case], capture_output=True, text=True, timeout=120, env=env)
        except subprocess.TimeoutExpired:
            failures.append(f'{claim}: timed out')
            continue
        if result.returncode == 0:
            lines = result.stdout.strip().splitlines()
            print('ok:', claim, '-', lines[-1] if lines else 'exit 0')
        else:
            failures.append(f'{claim}: {detail(result)}')

    # The leak: what one fit leaves unreachable against what 41 leave.
    claim = 'CurveFitter frees the previous simplex on every fit'
    if shutil.which('leaks') is None:
        failures.append(f'{claim}: needs leaks(1)')
    else:
        counts = {}
        for fits in (1, 41):
            result = subprocess.run(['leaks', '--atExit', '--', str(geometry / 'plain' / 'harness'), 'fitter-leak',
                                     str(fits)], capture_output=True, text=True, timeout=300,
                                    env=dict(os.environ, MallocStackLogging='0'))
            found = re.search(r'(\d+) leaks? for (\d+) total leaked bytes', result.stdout)
            if not found:
                failures.append(f'{claim}: leaks did not report on {fits} fits: '
                                f'{(result.stdout + result.stderr).strip().splitlines()[-1:]}')
                break
            counts[fits] = (int(found.group(1)), int(found.group(2)))
        if len(counts) == 2:
            extra = counts[41][0] - counts[1][0]
            if extra > 0:
                failures.append(f'{claim}: 40 more fits leaked {extra} more blocks '
                                f'({counts[41][1] - counts[1][1]} bytes): {counts[1][0]} after one fit, '
                                f'{counts[41][0]} after 41')
            else:
                print(f'ok: {claim} - leaks --atExit: {counts[1][0]} leaks after one fit, {counts[41][0]} after 41')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: Camera copies keep their state and mutable planes, Quaternion rotates by degrees about unit axes, '
      'a Y reslice takes one path while its cache fills and waits for it before freeing it, and CurveFitter '
      'does not leak its simplex')
