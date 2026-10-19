#!/usr/bin/env python3
"""A pix that is freed lets go of its parsed file.

`-[DCMPix loadDICOMWithDCMTK]` shares one parsed file per source file across
the pixes that read it, in the process-wide `cachedParsedDICOMFiles`, with a
count of its users. Since the reader loads the whole file into memory, an entry
holds the file's Pixel Data too: 10 to 50 MB for an uncompressed CR or DX.

`-clearCachedDCMFrameworkFiles` gave the count back only `if( fImage)`, and
`-dealloc` frees an owned `fImage` before calling it. A pix that owns its
buffer (one made without a volume: the browser preview, the series
thumbnails, the flip check before opening a series) and is freed without a
`-revert` left its file in the cache until the application quit. Reading X-ray
studies for an hour took the application from 100 MB to 16 GB.

DCMPix.m is compiled with the command xcodebuild logged for the app, with only
the cache's linkage opened so the probe can read it, and linked into a probe
that registers a parsed file the way a load does (a miss, then a hit for a
second pix) and checks the entry, and the parsed object, after each pix goes:

  * an owned buffer, freed without -revert          (the leak);
  * an owned buffer, -revert, then freed            (the path that worked);
  * two owned pixes of one file, freed in turn      (the count);
  * a buffer owned by a volume, freed               (the viewer's pixes).

It needs a build log holding DCMPix.m's compile command (build Debug once, or
pass --build-root of a checkout that has one); without it the test reports
itself skipped (exit 2).

    python3 tests/test-dcmpix-parsed-file-cache-release.py              # the working tree
    python3 tests/test-dcmpix-parsed-file-cache-release.py <revision>   # negative control
"""
import argparse
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import object_probe  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument('revision', nargs='?', help='read DCMPix.m from this revision (the negative control)')
parser.add_argument('--configuration', default='Debug', choices=('Debug', 'Release'))
parser.add_argument('--build-root', type=Path, default=ROOT,
                    help='checkout whose xcodebuild log holds the compile command for DCMPix.m')
arguments = parser.parse_args()

PIX = 'Horos/Sources/DCMPix.m'
CACHE = 'static NSMutableDictionary *cachedParsedDICOMFiles = nil;'
TARGET = ['-arch', 'arm64', '-mmacosx-version-min=26.0']


def source_bytes(relative):
    if arguments.revision:
        return subprocess.run(['git', '-C', str(ROOT), 'show', arguments.revision + ':' + relative],
                              check=True, capture_output=True).stdout
    return (ROOT / relative).read_bytes()


PROBE = r'''
#import <Foundation/Foundation.h>
#import "DCMPix.h"
#include <cstdio>
#include <cstdlib>

extern NSMutableDictionary *cachedParsedDICOMFiles;   // opened in the copy under test

static int parsedFreed = 0;
@interface ParsedFile : NSObject @end
@implementation ParsedFile
- (void) dealloc { parsedFreed++; [super dealloc]; }
@end

@interface ProbePix : DCMPix
- (void) loadAs:(NSString*) key volume:(float*) volume;
@end
@implementation ProbePix
- (void) CheckLoad {}
// What -loadDICOMWithDCMTK does with the cache on a miss and on a hit, then
// the decoded buffer: owned by the pix, or by a volume (fExternalOwnedImage).
- (void) loadAs:(NSString*) key volume:(float*) volume
{
    NSMutableDictionary *group = [cachedParsedDICOMFiles objectForKey: key];
    if( group)
        [group setValue: [NSNumber numberWithInt: [[group objectForKey: @"count"] intValue] + 1] forKey: @"count"];
    else
    {
        group = [NSMutableDictionary dictionary];
        ParsedFile *parsed = [[ParsedFile alloc] init];
        [group setValue: parsed forKey: @"dcmObject"];
        [parsed release];
        [group setValue: [NSNumber numberWithInt: 1] forKey: @"count"];
        [cachedParsedDICOMFiles setObject: group forKey: key];
    }
    retainedCacheGroup = group;
    [cachedFileKey release];
    cachedFileKey = [key retain];
    width = 4; height = 4;
    fImage = volume ? volume : (float*) calloc( width * height, sizeof( float));
    fExternalOwnedImage = volume;
}
@end

static int failures = 0;
static void expect( bool ok, const char *what) { if( !ok) { fprintf( stderr, "FAIL: %s\n", what); failures++; } }
static int users( NSString *key) { return [[[cachedParsedDICOMFiles objectForKey: key] objectForKey: @"count"] intValue]; }

int main() {
    @autoreleasepool { [[[DCMPix alloc] myinitEmpty] release]; }   // creates the cache, as the first pix does
    if( cachedParsedDICOMFiles == nil) { fprintf( stderr, "FAIL: no parsed-file cache\n"); return 1; }

    @autoreleasepool {
        ProbePix *pix = [[ProbePix alloc] init];
        [pix loadAs: @"owned" volume: NULL];
        [pix release];
    }
    expect( [cachedParsedDICOMFiles objectForKey: @"owned"] == nil,
            "a pix that owned its buffer and was freed without -revert left its parsed file in the cache");
    expect( parsedFreed == 1, "the parsed file of a freed pix is still alive");

    @autoreleasepool {
        ProbePix *pix = [[ProbePix alloc] init];
        [pix loadAs: @"reverted" volume: NULL];
        [pix revert: NO];
        expect( [cachedParsedDICOMFiles objectForKey: @"reverted"] == nil, "-revert keeps the parsed file cached");
        [pix release];
    }

    @autoreleasepool {
        ProbePix *first = [[ProbePix alloc] init], *second = [[ProbePix alloc] init];
        [first loadAs: @"shared" volume: NULL];
        [second loadAs: @"shared" volume: NULL];
        expect( users( @"shared") == 2, "two pixes of one file do not share its entry");
        [first release];
        expect( users( @"shared") == 1, "the entry did not lose the freed pix's use, or lost both");
        [second release];
        expect( [cachedParsedDICOMFiles objectForKey: @"shared"] == nil, "the last pix of a file left it cached");
    }

    @autoreleasepool {
        float *volume = (float*) calloc( 16, sizeof( float));
        ProbePix *pix = [[ProbePix alloc] init];
        [pix loadAs: @"volume" volume: volume];
        [pix release];
        free( volume);
        expect( [cachedParsedDICOMFiles objectForKey: @"volume"] == nil,
                "a pix whose buffer belongs to a volume left its parsed file in the cache");
    }

    expect( parsedFreed == 4, "not every parsed file was freed with its last pix");
    expect( cachedParsedDICOMFiles.count == 0, "the cache still holds entries");
    if( failures) { fprintf( stderr, "FAIL: %d check%s\n", failures, failures == 1 ? "" : "s"); return 1; }
    printf( "four pixes freed (owned without -revert, reverted, shared, volume-backed): the cache is empty "
            "and their parsed files are gone");
    return 0;
}
'''

FRAMEWORKS = ['Foundation', 'AppKit', 'AVFoundation', 'CoreData', 'CoreMedia', 'CoreVideo', 'Accelerate']


def objective_c_stubs(obj):
    listing = subprocess.run(['nm', '-u', str(obj)], capture_output=True, text=True, check=True).stdout
    names = sorted({m.group(1) for m in re.finditer(r'_OBJC_CLASS_\$_(\w+)', listing)})
    sources = ROOT / 'Horos/Sources'
    declared = [n for n in names
                if n != 'ROI' and any((sources / (n + suffix)).is_file() for suffix in ('.h', '.m', '.mm'))]
    return ('@interface ROI : NSObject @end\n@implementation ROI @end\n'
            + ''.join('@interface %s : NSObject @end\n@implementation %s @end\n' % (n, n) for n in declared))


try:
    command = object_probe.compile_command(PIX, arguments.configuration, root=arguments.build_root)
except LookupError as error:
    print('needs a build log with the compile command for DCMPix.m: %s' % error, file=sys.stderr)
    raise SystemExit(2)

with tempfile.TemporaryDirectory(prefix='horos-parsed-cache-') as name:
    work = Path(name)
    source = source_bytes(PIX)
    if CACHE.encode() not in source:
        print('FAIL: DCMPix.m no longer declares %r' % CACHE)
        raise SystemExit(1)
    # A copy outside the checkout, so its quoted includes resolve through the
    # logged header maps; only the cache's linkage differs from the source.
    copy = work / 'DCMPix.m'
    copy.write_bytes(source.replace(CACHE.encode(), CACHE.replace('static ', '').encode()))
    pix = work / 'DCMPix.o'
    compiled = subprocess.run(command + ['-c', str(copy), '-o', str(pix)], capture_output=True, text=True)
    if compiled.returncode:
        sys.stderr.write(compiled.stderr[-3000:])
        print('FAIL: DCMPix.m does not compile with the logged command')
        raise SystemExit(1)
    (work / 'probe.mm').write_text(PROBE)
    (work / 'stubs.mm').write_text('#import <Foundation/Foundation.h>\n' + objective_c_stubs(pix))
    placeholders = set()
    for _ in range(200):
        assembly = ''.join('.globl %s\n%s: .quad 0\n' % (s, s) for s in sorted(placeholders))
        (work / 'placeholders.s').write_text('.data\n' + assembly)
        link = ['xcrun', 'clang++', '-std=c++11', '-g', *TARGET, '-Wno-deprecated-declarations',
                '-I' + str(arguments.build_root / 'Horos/Sources'),
                str(work / 'probe.mm'), str(work / 'stubs.mm'), str(work / 'placeholders.s'),
                str(pix), '-Wl,-undefined,dynamic_lookup', '-o', str(work / 'probe')]
        for framework in FRAMEWORKS:
            link += ['-framework', framework]
        subprocess.run(link, check=True, capture_output=True)
        run = subprocess.run([str(work / 'probe')], capture_output=True, text=True, timeout=120)
        missing = re.search(r"symbol not found in flat namespace '([^']+)'", run.stderr)
        if not missing:
            break
        if missing.group(1) in placeholders:
            print('cannot satisfy %s' % missing.group(1), file=sys.stderr)
            raise SystemExit(1)
        placeholders.add(missing.group(1))
    else:
        print('too many unresolved symbols in %s' % pix, file=sys.stderr)
        raise SystemExit(1)

    if run.returncode:
        sys.stderr.write(run.stderr[-6000:])
        print('FAIL: freed pixes keep their parsed files in the cache (%s)' % arguments.configuration)
        raise SystemExit(1)
    print('PASS: %s (%s)' % (run.stdout.strip(), arguments.configuration))
