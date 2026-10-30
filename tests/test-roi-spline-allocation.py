#!/usr/bin/env python3
"""Inject allocation failures into the production spline's C entry point.

`spline()` is IsiXROI's (ROISpline.swift), the function the volume rendering's
3D outlines call: it allocates the points it answers, and the segment of each
when asked, with calloc. The driver links the module and defines calloc and
free itself, which the module's calls bind to, so that each allocation can
fail in turn: the function then answers 0 with NULL outputs and nothing
leaked. A successful call hands over arrays the caller frees, with finite
points and segment indices inside the outline; two points alike answer 0.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
import isix_modules  # noqa: E402

DRIVER = r'''
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <malloc/malloc.h>
#include <CoreGraphics/CoreGraphics.h>

extern int spline( CGPoint *Pt, int tot, CGPoint **newPt, long **correspondingSegmentPt, double scale);

static int failAt, calls, live;
static void *owned[ 64];

void *calloc( size_t count, size_t size)
{
    if( ++calls == failAt) return NULL;
    void *p = malloc_zone_calloc( malloc_default_zone(), count, size);
    for( int i = 0; p && i < 64; i++) if( owned[ i] == NULL) { owned[ i] = p; live++; break; }
    return p;
}

void free( void *p)
{
    for( int i = 0; p && i < 64; i++) if( owned[ i] == p) { owned[ i] = NULL; live--; break; }
    if( p) malloc_zone_free( malloc_zone_from_ptr( p), p);
}

int main( void)
{
    CGPoint points[] = {{0, 0}, {20, 35}, {45, -10}, {60, 15}};
    for( int segments = 0; segments < 2; segments++)
        for( int failure = 1; failure <= 3; failure++)
        {
            calls = live = 0; failAt = failure; CGPoint *out = NULL; long *map = NULL;
            int count = spline( points, 4, &out, segments ? &map : NULL, 5);
            if( failure <= 1 + segments) { assert( count == 0); assert( out == NULL); assert( map == NULL); }
            else { assert( count > 0); free( out); free( map); }
            assert( live == 0);
        }
    calls = live = 0; failAt = 0; CGPoint *out = NULL; long *map = NULL;
    int count = spline( points, 4, &out, &map, 5);
    assert( count > 4 && out && map);
    for( int i = 0; i < count; i++) { assert( isfinite( out[ i].x) && isfinite( out[ i].y)); assert( map[ i] >= 0 && map[ i] < 4); }
    free( out); free( map); assert( live == 0);
    CGPoint duplicate[] = {{0, 0}, {0, 0}, {10, 10}};
    calls = live = 0; failAt = 0; out = NULL; map = NULL;
    assert( spline( duplicate, 3, &out, &map, 5) == 0);
    assert( out == NULL && map == NULL && live == 0);
    puts( "PASS: each allocation failure answers nothing and leaks nothing; clean output ownership and segment mapping");
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix='horos-spline-alloc-') as d:
    p = Path(d)
    (p / 'test.c').write_text(DRIVER)
    module = isix_modules.module_flags('IsiXROI', p / 'module')
    subprocess.run(['xcrun', 'clang', '-c', '-fsanitize=undefined', str(p / 'test.c'), '-o', str(p / 'test.o')], check=True)
    subprocess.run(['xcrun', 'swiftc', str(p / 'test.o'), *module, '-sanitize=undefined', '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True)
