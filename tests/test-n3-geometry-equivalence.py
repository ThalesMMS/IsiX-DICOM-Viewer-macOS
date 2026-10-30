#!/usr/bin/env python3
"""The Swift N3 geometry gives what the Objective-C gave.

Nitrogen's N3Geometry.m, N3BezierCore.m, N3BezierCoreAdditions.m and
N3BezierPath.m became Swift: the module IsiXGeometry, on simd vectors, and
Nitrogen/Sources/N3*.swift, which give it the C functions and the classes of
the same headers. One driver, compiled against each side's headers, calls
both through those headers on the same seeded random inputs and writes every
result; the outputs must agree, in Debug (Swift -Onone against Objective-C
-O0) and in Release (Swift -O against -O3 -DNDEBUG).

Covered: vector arithmetic, normals, angles and bends; lines and planes
(intersections, closest points, distances, transforms); transforms (invert,
concatenate, determinant, transpose, OpenGL matrices) and arrays of vectors;
dictionaries, strings and NSValues; Bézier cores (curves through nodes,
flattening, subdivision, lengths, iterators and random accessors, appending,
dictionaries, samples along the path with tangents and normals, projected
samples, outlines, closest points, intersections with planes, projections,
planes of a path, reversing, subpaths, clipping, signed areas); and
N3BezierPath (its initializers, copies, coding, elements, enumeration,
relative positions, derived paths and mutations).

Tolerance: a number may differ from the reference by at most
TOLERANCE * max(1, |reference|), and must otherwise be equal, NaN for NaN;
everything else (counts, flags, kinds, strings) must be equal. The rounding
was kept (products fused as clang fused them), so the runs so far differ
nowhere; the test prints how many numbers were not bit for bit equal.

The reference is the last revision that has N3Geometry.m. Exit 2 when the
history does not reach it.
"""
from pathlib import Path
import math
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
import history_reference  # noqa: E402
import n3_geometry_harness as harness  # noqa: E402

SKIPPED = 2
TOLERANCE = 1e-9
SEEDS = 600

DRIVER = r'''
#import <Cocoa/Cocoa.h>
#import "N3Geometry.h"
#import "N3BezierCore.h"
#import "N3BezierCoreAdditions.h"
#import "N3BezierPath.h"

static uint64_t seed;
static uint64_t next64(void) { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return seed; }
static double uniform(void) { return (double)(next64() >> 11) * 0x1p-53; }
/* Several scales, and the values that take special branches. */
static double value(void) {
    switch (next64() % 16) {
        case 0: return 0.0;
        case 1: return 1.0;
        case 2: return -1.0;
        case 3: return (uniform() - 0.5) * 1e-6;
        case 4: return (uniform() - 0.5) * 1e6;
        default: return (uniform() - 0.5) * 200.0;
    }
}
static N3Vector vec(void) { N3Vector v = {value(), value(), value()}; return v; }
/* Not too close to zero: a direction, or a node of a path. */
static N3Vector direction(void) {
    for (;;) {
        N3Vector v = {(uniform() - 0.5) * 20.0, (uniform() - 0.5) * 20.0, (uniform() - 0.5) * 20.0};
        if (v.x * v.x + v.y * v.y + v.z * v.z > 1e-2) return v;
    }
}
static N3Vector node(void) { N3Vector v = {(uniform() - 0.5) * 200.0, (uniform() - 0.5) * 200.0, (uniform() - 0.5) * 50.0}; return v; }
/* An affine transform made with Core Animation alone, the same on both sides. */
static N3AffineTransform affine(void) {
    N3Vector axis = direction();
    CATransform3D t = CATransform3DMakeRotation(uniform() * 7.0, axis.x, axis.y, axis.z);
    t = CATransform3DConcat(t, CATransform3DMakeScale(0.5 + uniform() * 3.0, 0.5 + uniform() * 3.0, (next64() % 4 == 0) ? 1.0 : 0.5 + uniform() * 3.0));
    t = CATransform3DConcat(t, CATransform3DMakeTranslation(value(), value(), value()));
    t.m14 = 0.0; t.m24 = 0.0; t.m34 = 0.0; t.m44 = 1.0;
    return t;
}

static FILE *out;
static void label(const char *name) { fprintf(out, "\n%s:", name); }
static void d(double x) { fprintf(out, " %a", x); }
static void i(long x) { fprintf(out, " %ld", x); }
static void b(bool x) { fprintf(out, " %d", x ? 1 : 0); }
static void v(N3Vector x) { d(x.x); d(x.y); d(x.z); }
static void ln(N3Line x) { v(x.point); v(x.vector); }
static void pl(N3Plane x) { v(x.point); v(x.normal); }
static void tr(N3AffineTransform m) {
    d(m.m11); d(m.m12); d(m.m13); d(m.m14); d(m.m21); d(m.m22); d(m.m23); d(m.m24);
    d(m.m31); d(m.m32); d(m.m33); d(m.m34); d(m.m41); d(m.m42); d(m.m43); d(m.m44);
}
static void s(id text) {
    NSString *string = [[text description] stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
    string = [string stringByReplacingOccurrencesOfString:@" " withString:@"_"];
    fprintf(out, " %s", string.UTF8String);
}

static void core(N3BezierCoreRef c) {
    CFIndex count = N3BezierCoreSegmentCount(c);
    i(count);
    for (CFIndex k = 0; k < count; k++) {
        N3Vector c1, c2, e;
        i(N3BezierCoreGetSegmentAtIndex(c, k, &c1, &c2, &e)); v(c1); v(c2); v(e);
    }
}

static void path(N3BezierPath *p) {
    s(NSStringFromClass([p class]));
    i([p elementCount]);
    for (NSInteger k = 0; k < [p elementCount]; k++) {
        N3Vector c1 = {7, 7, 7}, c2 = {8, 8, 8}, e = {9, 9, 9};
        i([p elementAtIndex:k control1:&c1 control2:&c2 endpoint:&e]); v(c1); v(c2); v(e);
    }
}

static void geometry(void) {
    N3Vector a = vec(), c = vec(), n = direction(), m = direction();
    double t = value();
    label("vector");
    v(N3VectorMake(a.x, a.y, a.z)); b(N3VectorEqualToVector(a, c)); b(N3VectorEqualToVector(a, a));
    b(N3VectorIsCoincidentToVector(a, c)); b(N3VectorIsZero(a)); b(N3VectorIsZero(N3VectorZero));
    v(N3VectorAdd(a, c)); v(N3VectorSubtract(a, c)); v(N3VectorScalarMultiply(a, t));
    v(N3VectorANormalVector(a)); v(N3VectorANormalVector(n)); d(N3VectorDistance(a, c));
    d(N3VectorDotProduct(a, c)); v(N3VectorCrossProduct(a, c)); v(N3VectorLerp(a, c, uniform()));
    d(N3VectorAngleBetweenVectorsAroundVector(a, c, n)); d(N3VectorLength(a)); v(N3VectorNormalize(a));
    v(N3VectorNormalize(N3VectorZero)); v(N3VectorProject(a, c)); v(N3VectorProject(a, n)); v(N3VectorInvert(a));
    v(N3VectorInvert(N3VectorZero)); v(N3VectorBend(a, n, m)); v(N3VectorBend(a, n, N3VectorInvert(n)));
    v(N3VectorMakeFromNSPoint(NSMakePoint(a.x, a.y))); d(NSPointFromN3Vector(a).x);

    N3Line line = N3LineMake(vec(), n), line2 = N3LineMakeFromPoints(node(), node()), parallel = N3LineMake(vec(), N3VectorScalarMultiply(n, -2.0));
    N3Plane plane = N3PlaneMake(vec(), m), plane2 = N3PlaneMake(vec(), direction());
    label("line");
    ln(line); ln(line2); b(N3LineEqualToLine(line, line)); b(N3LineEqualToLine(line, line2));
    b(N3LineIsCoincidentToLine(line, line2)); b(N3LineIsCoincidentToLine(line, line)); b(N3LineIsOnPlane(line, plane));
    b(N3LineIsParallelToLine(line, line2)); b(N3LineIsParallelToLine(line, parallel)); b(N3LineIsValid(line)); b(N3LineIsValid(N3LineInvalid));
    b(N3LineIntersectsPlane(line, plane)); v(N3LineIntersectionWithPlane(line, plane));
    v(N3LineIntersectionWithPlane(N3LineMake(plane.point, N3VectorCrossProduct(m, n)), plane));
    v(N3LineIntersectionWithPlane(N3LineMake(N3VectorAdd(plane.point, m), N3VectorCrossProduct(m, n)), plane));
    v(N3LinePointClosestToVector(line, a));
    N3AffineTransform transform = affine();
    ln(N3LineApplyTransform(line, transform));
    N3Vector p1 = {1, 2, 3}, p2 = {4, 5, 6};
    d(N3LineClosestPoints(line, line2, &p1, &p2)); v(p1); v(p2);
    N3Vector q1 = {1, 2, 3}, q2 = {4, 5, 6};
    d(N3LineClosestPoints(line, parallel, &q1, &q2)); v(q1); v(q2);
    b(N3VectorIsOnLine(a, line)); b(N3VectorIsOnLine(line.point, line)); d(N3VectorDistanceToLine(a, line));
    b(N3VectorIsOnPlane(a, plane)); b(N3VectorIsOnPlane(plane.point, plane)); d(N3VectorDistanceToPlane(a, plane));

    label("plane");
    pl(plane); b(N3PlaneEqualToPlane(plane, plane)); b(N3PlaneEqualToPlane(plane, plane2));
    b(N3PlaneIsCoincidentToPlane(plane, plane2)); b(N3PlaneIsCoincidentToPlane(plane, N3PlaneMake(N3VectorAdd(plane.point, N3VectorCrossProduct(m, n)), N3VectorScalarMultiply(m, 3))));
    b(N3PlaneIsValid(plane)); b(N3PlaneIsValid(N3PlaneInvalid)); v(N3PlanePointClosestToVector(plane, a));
    b(N3PlaneIsParallelToPlane(plane, plane2)); b(N3PlaneIsParallelToPlane(plane, N3PlaneMake(a, m)));
    b(N3PlaneIsBetweenVectors(plane, a, c)); ln(N3PlaneIntersectionWithPlane(plane, plane2));
    ln(N3PlaneIntersectionWithPlane(plane, N3PlaneMake(a, m)));
    N3Vector points[5] = {node(), node(), node(), node(), node()};
    pl(N3PlaneLeastSquaresPlaneFromPoints(points, 5)); pl(N3PlaneLeastSquaresPlaneFromPoints(points, 3));
    pl(N3PlaneApplyTransform(plane, transform));
    pl(N3PlaneXZero); pl(N3PlaneYZero); pl(N3PlaneZZero); pl(N3PlaneInvalid);
    ln(N3LineXAxis); ln(N3LineYAxis); ln(N3LineZAxis); ln(N3LineInvalid);

    label("transform");
    N3AffineTransform other = affine();
    tr(transform); b(N3AffineTransformIsRectilinear(transform)); b(N3AffineTransformIsRectilinear(CATransform3DMakeScale(2, 3, 4)));
    tr(N3AffineTransformTranspose(transform)); d(N3AffineTransformDeterminant(transform));
    tr(N3AffineTransformInvert(transform)); tr(N3AffineTransformConcat(transform, other));
    CATransform3D perspective = transform; perspective.m34 = -0.002;
    tr(N3AffineTransformInvert(perspective)); tr(N3AffineTransformConcat(perspective, other));
    v(N3VectorApplyTransform(a, transform)); v(N3VectorApplyTransformToDirectionalVector(a, transform));
    double gl[16]; float glf[16];
    N3AffineTransformGetOpenGLMatrixd(transform, gl); N3AffineTransformGetOpenGLMatrixf(transform, glf);
    for (int k = 0; k < 16; k++) { d(gl[k]); d(glf[k]); }
    tr(N3AffineTransformMakeFromOpenGLMatrixd(gl)); tr(N3AffineTransformMakeFromOpenGLMatrixf(glf));
    tr(N3AffineTransformIdentity);

    label("arrays");
    N3Vector array1[7], array2[7];
    for (int k = 0; k < 7; k++) { array1[k] = vec(); array2[k] = vec(); }
    N3VectorScalarMultiplyVectors(t, array1, 7); for (int k = 0; k < 7; k++) v(array1[k]);
    N3VectorAddVectors(array1, array2, 7); for (int k = 0; k < 7; k++) v(array1[k]);
    N3VectorApplyTransformToVectors(transform, array1, 7); for (int k = 0; k < 7; k++) v(array1[k]);
    N3VectorCrossProductVectors(a, array1, 7); for (int k = 0; k < 7; k++) v(array1[k]);
    N3VectorCrossProductWithVectors(array1, array2, 7); for (int k = 0; k < 7; k++) v(array1[k]);
    N3VectorNormalizeVectors(array1, 7); for (int k = 0; k < 7; k++) v(array1[k]);

    label("representations");
    CFDictionaryRef vd = N3VectorCreateDictionaryRepresentation(a), ld = N3LineCreateDictionaryRepresentation(line), pd = N3PlaneCreateDictionaryRepresentation(plane);
    s((id)vd); s((id)ld); s((id)pd);
    N3Vector rv = {1, 1, 1}; N3Line rl = N3LineInvalid; N3Plane rp = N3PlaneInvalid;
    b(N3VectorMakeWithDictionaryRepresentation(vd, &rv)); v(rv);
    b(N3LineMakeWithDictionaryRepresentation(ld, &rl)); ln(rl);
    b(N3PlaneMakeWithDictionaryRepresentation(pd, &rp)); pl(rp);
    b(N3VectorMakeWithDictionaryRepresentation(NULL, &rv)); b(N3LineMakeWithDictionaryRepresentation(vd, &rl));
    b(N3PlaneMakeWithDictionaryRepresentation(ld, &rp)); b(N3VectorMakeWithDictionaryRepresentation(vd, NULL));
    NSDictionary *floats = @{@"x": @(1.1f), @"y": @2, @"z": @(-3.5)};
    b(N3VectorMakeWithDictionaryRepresentation((CFDictionaryRef)floats, &rv)); v(rv);
    b(N3VectorMakeWithDictionaryRepresentation((CFDictionaryRef)@{@"x": @1, @"y": @"2", @"z": @3}, &rv));
    b(N3VectorMakeWithDictionaryRepresentation((CFDictionaryRef)@{@"x": @1, @"y": @2}, &rv));
    CFRelease(vd); CFRelease(ld); CFRelease(pd);
    s(NSStringFromN3Vector(a)); s(NSStringFromN3Line(line)); s(NSStringFromN3Plane(plane)); s(NSStringFromN3AffineTransform(transform));
    NSValue *vv = [NSValue valueWithN3Vector:a], *lv = [NSValue valueWithN3Line:line], *pv = [NSValue valueWithN3Plane:plane], *tv = [NSValue valueWithN3AffineTransform:transform];
    s(@(vv.objCType)); s(@(lv.objCType)); s(@(pv.objCType)); s(@(tv.objCType));
    v([vv N3VectorValue]); ln([lv N3LineValue]); pl([pv N3PlaneValue]); tr([tv N3AffineTransformValue]);
    b([vv isEqualToValue:[NSValue valueWithN3Vector:a]]);
}

/* A path of one subpath through random nodes, or made of random segments. */
static N3MutableBezierCoreRef randomCore(bool closed, bool curvesOnly) {
    long count = 2 + (long)(next64() % 9);
    N3Vector nodes[12];
    for (long k = 0; k < count; k++) nodes[k] = node();
    if (curvesOnly || next64() % 2) {
        N3MutableBezierCoreRef c = N3BezierCoreCreateMutableCurveWithNodes(nodes, count, (next64() % 2) ? N3BezierNodeOpenEndsStyle : N3BezierNodeEndsMeetStyle);
        if (closed) N3BezierCoreAddSegment(c, N3CloseBezierCoreSegmentType, N3VectorZero, N3VectorZero, N3VectorZero);
        return c;
    }
    N3MutableBezierCoreRef c = N3BezierCoreCreateMutable();
    N3BezierCoreAddSegment(c, N3MoveToBezierCoreSegmentType, vec(), vec(), nodes[0]);
    for (long k = 1; k < count; k++) {
        if (next64() % 3 == 0) N3BezierCoreAddSegment(c, N3CurveToBezierCoreSegmentType, node(), node(), nodes[k]);
        else N3BezierCoreAddSegment(c, N3LineToBezierCoreSegmentType, vec(), vec(), nodes[k]);
    }
    if (closed) N3BezierCoreAddSegment(c, N3CloseBezierCoreSegmentType, vec(), vec(), vec());
    return c;
}

static void bezier(void) {
    N3MutableBezierCoreRef c = randomCore(next64() % 4 == 0, false);
    N3Vector n = direction();
    N3Plane plane = N3PlaneMake(N3VectorMake(value() * 0.2, value() * 0.2, value() * 0.1), direction());
    N3Line line = N3LineMake(node(), direction());

    label("core");
    core(c); b(N3BezierCoreHasCurve(c)); i(N3BezierCoreSubpathCount(c)); d(N3BezierCoreLength(c));
    s((id)CFAutorelease(N3BezierCoreCopyDescription(c)));
    v(N3BezierCoreVectorAtStart(c)); v(N3BezierCoreVectorAtEnd(c)); v(N3BezierCoreTangentAtStart(c)); v(N3BezierCoreTangentAtEnd(c));
    N3BezierCoreRef copy = N3BezierCoreCreateCopy(c);
    b(N3BezierCoreEqualToBezierCore(c, copy)); b(N3BezierCoreEqualToBezierCore(c, c));
    double flatness = (next64() % 3) ? 0.0 : 0.02 + uniform();
    N3BezierCoreRef flat = N3BezierCoreCreateFlattenedCopy(c, flatness); core(flat);
    b(N3BezierCoreEqualToBezierCore(c, flat));
    N3BezierCoreRef divided = N3BezierCoreCreateSubdividedCopy(c, (next64() % 3) ? 0.0 : 1.0 + uniform() * 20.0); core(divided);
    N3BezierCoreRef moved = N3BezierCoreCreateTransformedCopy(c, affine()); core(moved);
    N3MutableBezierCoreRef appended = N3BezierCoreCreateMutableCopy(c);
    N3MutableBezierCoreRef open = randomCore(false, false);
    N3BezierCoreAppendBezierCore(appended, open, next64() % 2); core(appended); i(N3BezierCoreSubpathCount(appended));

    label("iterate");
    N3BezierCoreIteratorRef iterator = N3BezierCoreIteratorCreateWithBezierCore(c);
    i(N3BezierCoreIteratorSegmentCount(iterator));
    while (!N3BezierCoreIteratorIsAtEnd(iterator)) {
        N3Vector c1, c2, e;
        i(N3BezierCoreIteratorIndex(iterator)); i(N3BezierCoreIteratorGetNextSegment(iterator, &c1, &c2, &e)); v(c1); v(c2); v(e);
    }
    N3Vector z1 = {1, 1, 1}, z2 = {1, 1, 1}, z3 = {1, 1, 1};
    i(N3BezierCoreIteratorGetNextSegment(iterator, &z1, &z2, &z3)); v(z1); v(z2); v(z3);
    N3BezierCoreIteratorSetIndex(iterator, N3BezierCoreSegmentCount(c) / 2); i(N3BezierCoreIteratorIndex(iterator));
    i(N3BezierCoreIteratorGetNextSegment(iterator, NULL, NULL, &z3)); v(z3);
    N3BezierCoreIteratorRelease(N3BezierCoreIteratorRetain(iterator));
    N3BezierCoreIteratorRelease(iterator);

    N3MutableBezierCoreRef edited = N3BezierCoreCreateMutableCopy(c);
    N3BezierCoreRandomAccessorRef accessor = N3BezierCoreRandomAccessorCreateWithMutableBezierCore(edited);
    i(N3BezierCoreRandomAccessorSegmentCount(accessor));
    for (CFIndex k = 0; k <= N3BezierCoreSegmentCount(c); k++) {
        N3Vector c1 = {2, 2, 2}, c2 = {2, 2, 2}, e = {2, 2, 2};
        i(N3BezierCoreRandomAccessorGetSegmentAtIndex(accessor, k, &c1, &c2, &e)); v(c1); v(c2); v(e);
    }
    N3BezierCoreRandomAccessorSetVectorsForSegementAtIndex(accessor, 0, node(), node(), node());
    N3BezierCoreRandomAccessorSetVectorsForSegementAtIndex(accessor, N3BezierCoreSegmentCount(c) - 1, node(), node(), node());
    N3BezierCoreRandomAccessorRelease(N3BezierCoreRandomAccessorRetain(accessor));
    N3BezierCoreRandomAccessorRelease(accessor);
    N3BezierCoreSetVectorsForSegementAtIndex(edited, N3BezierCoreSegmentCount(c) / 2, node(), node(), node());
    core(edited);

    label("dictionary");
    CFDictionaryRef dict = N3BezierCoreCreateDictionaryRepresentation(c);
    s((id)dict);
    N3BezierCoreRef read = N3BezierCoreCreateWithDictionaryRepresentation(dict);
    core(read); b(N3BezierCoreEqualToBezierCore(c, read));
    b(N3BezierCoreCreateWithDictionaryRepresentation((CFDictionaryRef)@{}) == NULL);
    CFRelease(dict);

    label("planes");
    i(N3BezierCoreCountIntersectionsWithPlane(c, plane));
    N3Vector crossings[64]; CGFloat positions[64];
    long found = N3BezierCoreIntersectionsWithPlane(c, plane, crossings, positions, 64);
    i(found); for (long k = 0; k < found; k++) { v(crossings[k]); d(positions[k]); }
    i(N3BezierCoreIntersectionsWithPlane(c, plane, NULL, NULL, 1));
    N3BezierCoreRef split = N3BezierCoreCreateMutableCopyWithEndpointsAtPlaneIntersections(c, plane); core(split);
    N3BezierCoreRef projected = N3BezierCoreCreateCopyProjectedToPlane(c, plane); core(projected);
    pl(N3BezierCoreLeastSquaresPlane(c)); d(N3BezierCoreMeanDistanceToPlane(c, plane));
    N3Plane planar = N3PlaneInvalid; b(N3BezierCoreIsPlanar(c, &planar)); pl(planar);
    b(N3BezierCoreIsPlanar(projected, &planar)); pl(planar);
    N3Plane top = N3PlaneInvalid, bottom = N3PlaneInvalid;
    b(N3BezierCoreGetBoundingPlanesForNormal(c, n, &top, &bottom)); pl(top); pl(bottom);

    label("closest");
    N3Vector closest = {3, 3, 3}; CGFloat distance = -1;
    d(N3BezierCoreRelativePositionClosestToVector(c, node(), &closest, &distance)); v(closest); d(distance);
    d(N3BezierCoreRelativePositionClosestToLine(c, line, &closest, &distance)); v(closest); d(distance);
    d(N3BezierCoreRelativePositionClosestToVector(c, N3BezierCoreVectorAtEnd(c), NULL, NULL));
    for (CFIndex k = 0; k < N3BezierCoreSegmentCount(c); k++) d(N3BezierCoreLengthToSegmentAtIndex(c, k, flatness));
    CGFloat lengths[16];
    long measured = N3BezierCoreSegmentLengths(c, lengths, 16, flatness);
    i(measured); for (long k = 0; k < measured; k++) d(lengths[k]);

    label("edit");
    N3BezierCoreRef reversed = N3BezierCoreCreateCopyByReversing(c); core(reversed);
    N3BezierCoreRef twice = N3BezierCoreCreateCopyByReversing(appended); core(twice);
    CFArrayRef subpaths = N3BezierCoreCopySubpaths(appended);
    i(CFArrayGetCount(subpaths));
    for (CFIndex k = 0; k < CFArrayGetCount(subpaths); k++) core(CFArrayGetValueAtIndex(subpaths, k));
    CFRelease(subpaths);
    d(N3BezierCoreSignedAreaUsingNormal(c, n)); d(N3BezierCoreSignedAreaUsingNormal(appended, n));
    double from = uniform(), to = uniform();
    if (next64() % 5 == 0) from = 0; if (next64() % 5 == 0) to = 1;
    N3BezierCoreRef clipped = N3BezierCoreCreateCopyByClipping(c, from, to); core(clipped); N3BezierCoreRelease(clipped);

    label("samples");
    N3MutableBezierCoreRef single = randomCore(false, false);
    double spacing = 0.2 + uniform() * 5.0, start = uniform() * 3.0;
    N3Vector vectors[300], tangents[300], normals[300]; CGFloat relative[300];
    long got = N3BezierCoreGetVectorInfo(single, spacing, start, n, vectors, tangents, normals, 300);
    i(got); for (long k = 0; k < got; k++) { v(vectors[k]); v(tangents[k]); v(normals[k]); }
    got = N3BezierCoreGetVectorInfo(single, spacing, start, N3VectorZero, NULL, tangents, NULL, 7);
    i(got); for (long k = 0; k < got; k++) v(tangents[k]);
    got = N3BezierCoreGetVectorInfo(single, 0, uniform() * N3BezierCoreLength(single), N3VectorZero, vectors, NULL, NULL, 1);
    i(got); if (got) v(vectors[0]);
    got = N3BezierCoreGetProjectedVectorInfo(single, spacing, start, n, vectors, tangents, normals, relative, 300);
    i(got); for (long k = 0; k < got; k++) { v(vectors[k]); v(tangents[k]); v(normals[k]); d(relative[k]); }
    v(N3BezierCoreNormalAtEndWithInitialNormal(single, n));
    double offset = value() * 0.05;
    N3BezierCoreRef outline = N3BezierCoreCreateOutline(single, offset, spacing, n);
    b(outline != NULL); if (outline) { core(outline); N3BezierCoreRelease(outline); }
    outline = N3BezierCoreCreateOutlineWithNormal(single, offset, spacing, n);
    b(outline != NULL); if (outline) { core(outline); N3BezierCoreRelease(outline); }
    N3BezierCoreCheckDebug(single);

    N3BezierCoreRelease(single); N3BezierCoreRelease(reversed); N3BezierCoreRelease(twice);
    N3BezierCoreRelease(split); N3BezierCoreRelease(projected); N3BezierCoreRelease(read); N3BezierCoreRelease(edited);
    N3BezierCoreRelease(open); N3BezierCoreRelease(appended); N3BezierCoreRelease(moved); N3BezierCoreRelease(divided);
    N3BezierCoreRelease(flat); N3BezierCoreRelease(copy);
    N3BezierCoreRetain(c); N3BezierCoreRelease(c); N3BezierCoreRelease(c);
}

static void paths(void) {
    long count = (long)(next64() % 7);
    NSMutableArray *nodes = [NSMutableArray array];
    for (long k = 0; k < count; k++) [nodes addObject:[NSValue valueWithN3Vector:node()]];
    N3Vector n = direction();
    N3Plane plane = N3PlaneMake(N3VectorMake(value() * 0.2, value() * 0.2, value() * 0.1), direction());
    N3Line line = N3LineMake(node(), direction());

    label("path");
    N3BezierPath *p = [[N3BezierPath alloc] initWithNodeArray:nodes style:(next64() % 2) ? N3BezierNodeOpenEndsStyle : N3BezierNodeEndsMeetStyle];
    path(p); d([p length]); s(p); i((long)[p hash]);
    N3MutableBezierPath *m = [p mutableCopy];
    path(m); path([p copy]); b([p isEqual:m]); b([p isEqualToBezierPath:m]); b([p isEqual:@"path"]);
    path([N3BezierPath bezierPath]); path([N3MutableBezierPath bezierPath]);
    path([N3MutableBezierPath bezierPathWithBezierPath:p]); path([N3BezierPath bezierPathN3BezierCore:[p N3BezierCore]]);
    path([[N3BezierPath alloc] initWithN3BezierCore:[p N3BezierCore]]);
    path([[N3BezierPath alloc] initWithDictionaryRepresentation:[p dictionaryRepresentation]]);
    b([[N3BezierPath alloc] initWithDictionaryRepresentation:@{}] == nil);
    path([N3BezierPath bezierPathCircleWithCenter:node() radius:1.0 + uniform() * 30 normal:n]);
    NSError *error = nil;
    NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:p requiringSecureCoding:YES error:&error];
    N3BezierPath *decoded = [NSKeyedUnarchiver unarchivedObjectOfClass:[N3BezierPath class] fromData:archive error:&error];
    path(decoded); b(error == nil);
    /* A mutable path, as the CPR saves its curved path: it is archived as
       N3MutableBezierPath and read back as an N3BezierPath. */
    error = nil;
    archive = [NSKeyedArchiver archivedDataWithRootObject:m requiringSecureCoding:YES error:&error];
    b(archive != nil); b(error == nil);
    decoded = archive ? [NSKeyedUnarchiver unarchivedObjectOfClass:[N3BezierPath class] fromData:archive error:&error] : nil;
    path(decoded); b(error == nil); b([decoded isKindOfClass:[N3MutableBezierPath class]]);
#if CHECK_ENUMERATION
    for (NSValue *endpoint in p) v([endpoint N3VectorValue]);
#endif

    if ([p elementCount] >= 2) {
        label("path-reading");
        v([p vectorAtStart]); v([p vectorAtEnd]); v([p tangentAtStart]); v([p tangentAtEnd]); v([p normalAtEndWithInitialNormal:n]);
        b([p isPlanar]); pl([p leastSquaresPlane]); pl([p topBoundingPlaneForNormal:n]); pl([p bottomBoundingPlaneForNormal:n]);
        for (NSInteger k = 0; k < [p elementCount]; k++) { i([p elementAtIndex:k]); d([p lengthThroughElementAtIndex:k]); }
        for (int k = 0; k <= 8; k++) {
            CGFloat position = k / 8.0;
            v([p vectorAtRelativePosition:position]); v([p tangentAtRelativePosition:position]); v([p normalAtRelativePosition:position initialNormal:n]);
        }
        d([p relativePositionClosestToVector:node()]); d([p relativePositionClosestToLine:line]);
        N3Vector closest = {4, 4, 4}; d([p relativePositionClosestToLine:line closestVector:&closest]); v(closest);
        NSArray *positions = nil; NSArray *crossings = [p intersectionsWithPlane:plane relativePositions:&positions];
        i((long)crossings.count); for (NSValue *x in crossings) v([x N3VectorValue]); for (NSNumber *x in positions) d(x.doubleValue);
        i((long)[p intersectionsWithPlane:plane].count);
        NSArray *subPaths = [p subPaths]; i((long)subPaths.count); for (N3BezierPath *x in subPaths) path(x);
        d([p signedAreaUsingNormal:n]);
        path([p bezierPathByFlattening:0.05 + uniform()]); path([p bezierPathBySubdividing:1.0 + uniform() * 10.0]);
        path([p bezierPathByApplyingTransform:affine()]); path([p bezierPathByAppendingBezierPath:p connectPaths:YES]);
        path([p bezierPathByAppendingBezierPath:p connectPaths:NO]); path([p bezierPathByAddingEndpointsAtIntersectionsWithPlane:plane]);
        path([p bezierPathByProjectingToPlane:plane]); path([p bezierPathByCollapsingZ]); path([p bezierPathByReversing]);
        path([p bezierPathByClippingFromRelativePosition:uniform() toRelativePosition:uniform()]);
        if ([p length] > 20) {
            path([p outlineBezierPathAtDistance:value() * 0.05 initialNormal:n spacing:1.0 + uniform() * 4.0]);
            path([p outlineBezierPathAtDistance:value() * 0.05 projectionNormal:n spacing:1.0 + uniform() * 4.0]);
        }

        label("path-mutation");
        d([m length]);
        [m setVectorsForElementAtIndex:[m elementCount] - 1 control1:node() control2:node() endpoint:node()];
        d([m length]); path(m);
        [m lineToVector:node()]; d([m length]);
        [m curveToVector:node() controlVector1:node() controlVector2:node()];
        [m close]; [m moveToVector:node()]; [m lineToVector:node()];
        path(m); d([m length]);
        [m subdivide:5.0]; [m flatten:0.2]; [m applyAffineTransform:affine()]; path(m);
        [m projectToPlane:plane]; [m addEndpointsAtIntersectionsWithPlane:plane]; path(m);
        [m appendBezierPath:p connectPaths:NO]; path(m); b([m isEqualToBezierPath:p]);
#if CHECK_ENUMERATION
        @try {
            for (NSValue *endpoint in m) { (void)endpoint; [m lineToVector:node()]; }
            s(@"no-exception");
        } @catch (NSException *exception) {
            s(exception.name);
        }
#endif
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        out = fopen(argv[1], "w");
        long seeds = atol(argv[2]);
        for (long k = 0; k < seeds; k++) {
            seed = 0x9E3779B97F4A7C15ull ^ (uint64_t)(k * 2654435761u + 1);
            fprintf(out, "\nseed: %ld", k);
            @autoreleasepool { geometry(); bezier(); paths(); }
        }
        fprintf(out, "\n");
        fclose(out);
    }
    return 0;
}
'''


def reference_revision():
    revision = history_reference.before_removal('Nitrogen/Sources/N3Geometry.m')
    if revision:
        return revision
    # Before the Objective-C leaves the tree, the revision under test still has it.
    if subprocess.run(['git', '-C', str(ROOT), 'cat-file', '-e', 'HEAD:Nitrogen/Sources/N3Geometry.m'], capture_output=True).returncode == 0:
        return 'HEAD'
    return None


def driver(folder, configuration, flags, link):
    source = folder / 'driver.m'
    source.write_text(DRIVER)
    binary = folder / 'driver'
    # The Objective-C -countByEnumeratingWithState:objects:count: handed back a
    # pointer to its own stack variable, which an optimized caller may read
    # after it is gone: the Release reference crashes on it. Fast enumeration
    # is compared in Debug only.
    enumeration = ['-DCHECK_ENUMERATION=1'] if configuration == 'debug' else []
    harness.run(['xcrun', 'clang', '-x', 'objective-c', *harness.TARGET, '-fno-objc-arc', '-fobjc-exceptions', '-w', *enumeration, *flags,
                 str(source), '-x', 'none', *link, '-o', str(binary)])
    return binary


def output(binary, folder):
    result = folder / 'output.txt'
    subprocess.run([str(binary), str(result), str(SEEDS)], check=True, timeout=300)
    return result.read_text().split('\n')


def number(token):
    try:
        return float.fromhex(token)
    except ValueError:
        return None


def compare(reference, candidate, name):
    """(failures, numbers that were not bit for bit equal)."""
    failures, inexact = [], 0
    if len(reference) != len(candidate):
        failures.append(f'{name}: {len(candidate)} lines, the reference has {len(reference)}')
    for line_number, (expected, actual) in enumerate(zip(reference, candidate), 1):
        if expected == actual:
            continue
        expected_tokens, actual_tokens = expected.split(' '), actual.split(' ')
        if len(expected_tokens) != len(actual_tokens):
            failures.append(f'{name} line {line_number}: {actual[:300]!r} != {expected[:300]!r}')
            continue
        for e, a in zip(expected_tokens, actual_tokens):
            if e == a:
                continue
            x, y = number(e), number(a)
            if x is None or y is None or (math.isnan(x) != math.isnan(y)):
                failures.append(f'{name} line {line_number}: {a} != {e} in {expected[:200]!r}')
                break
            if not math.isnan(x) and abs(x - y) > TOLERANCE * max(1.0, abs(x)):
                failures.append(f'{name} line {line_number}: {a} ({y!r}) != {e} ({x!r}) in {expected[:200]!r}')
                break
            inexact += 1
        if len(failures) > 20:
            break
    return failures, inexact


def main():
    revision = reference_revision()
    if revision is None:
        print('SKIP: the history does not reach the Objective-C N3 geometry')
        return SKIPPED
    failures = []
    with tempfile.TemporaryDirectory() as temporary:
        temporary = Path(temporary)
        for configuration in ('debug', 'release'):
            old_folder = temporary / configuration / 'objc'
            new_folder = temporary / configuration / 'swift'
            old_folder.mkdir(parents=True)
            new_folder.mkdir(parents=True)
            old = output(driver(old_folder, configuration, *harness.build_reference(old_folder, revision, configuration)), old_folder)
            new = output(driver(new_folder, configuration, *harness.build(new_folder, configuration)), new_folder)
            found, inexact = compare(old, new, configuration)
            failures += found
            print(f'{configuration}: {len(old)} lines of results, {inexact} numbers within the tolerance but not equal')
    for failure in failures:
        print('FAIL:', failure)
    if failures:
        return 1
    print(f'the Swift N3 geometry gives the results of {revision[:12]}, in Debug and Release, on {SEEDS} seeds')
    return 0


if __name__ == '__main__':
    sys.exit(main())
