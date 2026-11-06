#!/usr/bin/env python3
"""A FluoView TIFF whose unused dimensions have a size of 0 is imported with its images.

The MM header of an Olympus FluoView TIFF always lists ten dimensions, and
FluoView writes those an acquisition did not use with a size of 0. The import
read the header through the VTK adapter (IsiXVTKTIFF, IsiXVTKFluoView) and
counted the series as the product of the sizes of the dimensions other than X,
Y and Z (FluoViewSeries in IsiXDICOMFile): one dimension of size 0 made it 0,
and the file was imported with no series and no images, without a word. A Z of
size 0 made the frames 0 the same way. Such a dimension now has one position.

The files come from tools/generate-fluoview-fixture.py (two stacks, one with an
unused "T" and five unnamed dimensions of size 0, one whose Z is also 0). Here:
- the adapter, compiled with its driver against the libtiff and the VTK of the
  Debug build (exit 2 without that build), reads each file's header, its pages
  and the value of each page;
- FluoViewSeries of the IsiXVTKFile module, compiled here, turns the header's
  dimensions into the series, frames and descriptions the import stores;
- every series and frame must reach its own page, at the directory DCMPix reads
  for it (frames x series + frame), holding the value the generator wrote for
  that series and frame; and DCMPix counts the frames of a Z of size 0 as the
  import does.
"""
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dcmtk_build import BUILD, ROOT  # noqa: E402
import isix_modules  # noqa: E402

ADAPTER = ROOT / 'Horos/Sources/Adapters/VTK'
TIFF = BUILD / 'ExternalInputs.build/Install'
VTK = BUILD / 'VTK.build/Install/include'
VTK_LIBRARY = BUILD / 'VTK.build/Install/wlib/libVTK.a'
missing = [p for p in (TIFF / 'include/tiffio.h', TIFF / 'lib/libtiff.dylib', VTK / 'vtk_tiff.h', VTK_LIBRARY)
           if not p.exists()]
if missing:
    print('skipped: needs a current build from script/build_and_run.sh --verify: %s' % missing[0])
    raise SystemExit(2)

ADAPTER_DRIVER = r'''
#import <Foundation/Foundation.h>
#import "IsiXVTKTIFF.h"

// For each file: whether it has a FluoView header, its dimensions, its pages
// and the first byte of each page, as JSON.
int main(int argc, char **argv)
{
    @autoreleasepool {
        [IsiXVTKTIFF registerFluoViewTags];
        NSMutableDictionary *files = [NSMutableDictionary dictionary];
        for (int i = 1; i < argc; i++) {
            NSString *path = [NSString stringWithUTF8String:argv[i]];
            NSMutableDictionary *file = [NSMutableDictionary dictionary];
            file[@"hasHeader"] = @([IsiXVTKTIFF hasFluoViewHeaderAtPath:path]);
            NSError *error = nil;
            IsiXVTKFluoViewHeader *header = [IsiXVTKTIFF fluoViewHeaderOfFileAtPath:path error:&error];
            NSMutableArray *dimensions = [NSMutableArray array];
            for (IsiXVTKFluoViewDimension *d in header.dimensions)
                [dimensions addObject:@[d.name, @(d.size)]];
            file[@"dimensions"] = dimensions;
            file[@"width"] = @(header.width);
            file[@"height"] = @(header.height);
            file[@"headerError"] = error ? error.localizedDescription : [NSNull null];
            IsiXVTKTIFFPages *pages = [IsiXVTKTIFF pagesOfFileAtPath:path error:NULL];
            file[@"pages"] = @(pages.count);
            NSMutableArray *values = [NSMutableArray array];
            void *tif = HorosTIFFOpen(path);
            if (tif) {
                do {
                    long size = HorosTIFFScanlineSize(tif);
                    unsigned char *line = (unsigned char *) HorosTIFFMalloc(size);
                    HorosTIFFReadScanline(tif, line, 0);
                    [values addObject:@(line[0])];
                    HorosTIFFFree(line);
                } while (HorosTIFFReadDirectory(tif));
                HorosTIFFClose(tif);
            }
            file[@"pageValues"] = values;
            files[path.lastPathComponent] = file;
        }
        NSData *json = [NSJSONSerialization dataWithJSONObject:files options:NSJSONWritingSortedKeys error:NULL];
        fwrite(json.bytes, 1, json.length, stdout);
    }
    return 0;
}
'''

SERIES_DRIVER = r'''
import Foundation
import IsiXDICOMFile

// The adapter's answer on standard input; for each file, the series, frames and
// descriptions the import gives it.
let input = FileHandle.standardInput.readDataToEndOfFile()
let files = try! JSONSerialization.jsonObject(with: input) as! [String: [String: Any]]
var answers: [String: Any] = [:]
for (name, file) in files {
    let dimensions = (file["dimensions"] as! [[Any]]).map {
        FluoViewSeries.Dimension(name: $0[0] as! String, size: $0[1] as! Int)
    }
    let counts = FluoViewSeries.counts(dimensions)
    answers[name] = ["series": counts.series, "frames": counts.frames,
                     "descriptions": (0..<max(0, counts.series)).map { FluoViewSeries.description(ofSeries: $0, dimensions) }]
}
let output = try! JSONSerialization.data(withJSONObject: answers, options: [.sortedKeys])
FileHandle.standardOutput.write(output)
'''

failures = []


def check(condition, what):
    print('%s: %s' % ('PASS' if condition else 'FAIL', what))
    if not condition:
        failures.append(what)


with tempfile.TemporaryDirectory(prefix='isix-fluoview-unused-') as folder:
    work = Path(folder)
    fixture = work / 'fixture'
    subprocess.run([sys.executable, str(ROOT / 'tools/generate-fluoview-fixture.py'), str(fixture)], check=True,
                   capture_output=True, text=True, timeout=60)
    expected = json.loads((fixture / 'fluoview-fixture.json').read_text())
    paths = [str(fixture / name) for name in sorted(expected)]

    (work / 'adapter.mm').write_text(ADAPTER_DRIVER)
    built = subprocess.run(['xcrun', 'clang++', '-std=c++17', '-fobjc-arc', '-x', 'objective-c++',
                            str(work / 'adapter.mm'), str(ADAPTER / 'IsiXVTKTIFF.mm'),
                            str(ADAPTER / 'IsiXVTKFluoView.mm'), str(ADAPTER / 'IsiXVTKError.mm'), '-x', 'none',
                            '-I' + str(ADAPTER), '-I' + str(ROOT / 'Horos/Sources'), '-I' + str(VTK),
                            '-I' + str(TIFF / 'include'), str(VTK_LIBRARY), '-L' + str(TIFF / 'lib'), '-ltiff',
                            '-Wl,-rpath,' + str(TIFF / 'lib'), '-framework', 'Foundation', '-o', str(work / 'adapter')],
                           capture_output=True, text=True, timeout=600)
    if built.returncode:
        print('FAIL: the adapter does not compile with the driver:\n' + built.stderr[-4000:])
        raise SystemExit(1)
    read = subprocess.run([str(work / 'adapter'), *paths], capture_output=True, text=True, timeout=60)
    if read.returncode:
        print('FAIL: the adapter driver exited with %d\n%s' % (read.returncode, read.stderr[-2000:]))
        raise SystemExit(1)
    headers = json.loads(read.stdout)

    (work / 'series.swift').write_text(SERIES_DRIVER)
    flags = isix_modules.module_flags('IsiXDICOMFile', work / 'modules')
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', str(work / 'series.swift'), *flags,
                            '-o', str(work / 'series')], capture_output=True, text=True, timeout=600)
    if built.returncode:
        print('FAIL: FluoViewSeries does not compile with the driver:\n' + built.stderr[-4000:])
        raise SystemExit(1)
    counted = subprocess.run([str(work / 'series')], input=read.stdout, capture_output=True, text=True, timeout=60)
    if counted.returncode:
        print('FAIL: the series driver exited with %d\n%s' % (counted.returncode, counted.stderr[-2000:]))
        raise SystemExit(1)
    series = json.loads(counted.stdout)

    for name in sorted(expected):
        want, header, answer = expected[name], headers[name], series[name]
        zeros = [d for d in header['dimensions'] if d[1] == 0]
        check(header['hasHeader'] and header['headerError'] is None and len(header['dimensions']) == 10
              and header['width'] == want['width'] and header['height'] == want['height'],
              '%s: the adapter reads its FluoView header (ten dimensions, %dx%d)' % (name, want['width'], want['height']))
        check(len(zeros) >= 6, '%s: %d of its dimensions have a size of 0' % (name, len(zeros)))
        check(header['pages'] == want['pages'] and header['pageValues'] == want['pageValues'],
              '%s: the adapter reads its %d pages' % (name, want['pages']))
        check(answer['series'] == want['series'] and answer['frames'] == want['frames'],
              '%s: %d series of %d frames (read %r)' % (name, want['series'], want['frames'],
                                                     (answer['series'], answer['frames'])))
        check(answer['descriptions'] == want['seriesDescriptions'],
              '%s: the series are %s' % (name, ', '.join(want['seriesDescriptions'])))
        reached = [header['pageValues'][answer['frames'] * s + f] if answer['frames'] * s + f < header['pages'] else None
                   for s in range(answer['series']) for f in range(answer['frames'])]
        check(answer['series'] * answer['frames'] == header['pages'] and reached == want['pageValues'],
              '%s: every series and frame reads its own page, with its own pixels' % name)

    # DCMPix reads the page of a frame at frames x series + frame, its frames
    # counted from the Z dimension as FluoViewSeries counts them.
    source = (ROOT / 'Horos/Sources/DCMPix+NonDICOM.swift').read_text()
    body = source[source.index('func loadFVTiff()'):]
    body = body[:body.index('loadTiff(')]
    check(re.search(r'frames = Int32\(bitPattern: max\(dimension\.size, 1\)\)', body) is not None,
          'DCMPix counts a Z of size 0 as one frame, as the import does')

if failures:
    print('%d failure(s)' % len(failures))
    raise SystemExit(1)
print('PASS: a FluoView TIFF with unused dimensions of size 0 gives its series and frames, each on its own page')
