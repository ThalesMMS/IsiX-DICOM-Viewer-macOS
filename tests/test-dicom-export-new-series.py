#!/usr/bin/env python3
"""Each DICOM export that begins writes a series of its own.

The 2D viewer, the orthogonal MPR and PET-CT viewers, the MPR, the surface
renderer and the endoscopy keep one DICOMExport from an export to the next, and
number the series of an export as a base + minute + second (or a fixed
number). -[DICOMExport setSeriesNumber:] makes a new SeriesInstanceUID only
when the number changes, so two exports of the same viewer whose numbers came
out equal (10:09 and 09:10, or the same second) wrote the same series: the
second went into the first, which took its description.

- exporter: -[DICOMExport beginSeriesWithNumber:], copied from DICOMExport.mm
  with -setSeriesNumber: and compiled with a stand-in of
  +[DCMObject newSeriesInstanceUID], makes a new UID at each call, also for
  the number already set, and numbers the images of the new series from 1;
  -setSeriesNumber: keeps what plugins know (a new UID only for a new number).
  The case of the report, "CHK876D2" and then "CHK867ALL" both on 5319, gets
  two series.
- viewers: the branches of the export sheets that begin an export (current
  image, 4D, series, all images, the CT, PET-CT and PET series of the PET-CT)
  begin their series with it, directly or through a helper of the file that
  calls it; none of them sends -setSeriesNumber: to the exporter it keeps.
  The steps of one export (the images of a series, the frames of a 4D, the
  views of the PET-CT's series) stay inside the series begun.

`<git revision>` as an optional argument reads the sources from that
revision, the negative control.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
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
        data = subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}'])
    else:
        data = (root / path).read_bytes()
    return data.decode('utf-8' if path.endswith('.swift') else 'latin1')


failures = []


def check(condition, what):
    if not condition:
        failures.append(what)


# ---------------------------------------------------------------- the exporter
exporter = source('Horos/Sources/DICOMExport.mm')


def objc_method(text, signature):
    """The method whose line starts with `signature`, to its closing brace."""
    at = text.find('\n' + signature)
    if at < 0:
        return None
    end = text.index('\n}\n', at) + 3
    return text[at + 1:end]


set_number = objc_method(exporter, '- (void) setSeriesNumber:')
begin = objc_method(exporter, '- (void) beginSeriesWithNumber:')
check(set_number is not None, 'DICOMExport.mm has -setSeriesNumber:')
check(begin is not None, 'DICOMExport.mm has -beginSeriesWithNumber:, which begins a series whatever the number')

HARNESS = r'''
#import <Foundation/Foundation.h>
static int made = 0;
@interface DCMObject : NSObject
+ (NSString*) newSeriesInstanceUID;
@end
@implementation DCMObject
+ (NSString*) newSeriesInstanceUID { return [NSString stringWithFormat:@"1.2.3.%d", ++made]; }
@end
@interface DICOMExport : NSObject {
    int exportInstanceNumber, exportSeriesNumber;
    NSString *exportSeriesUID;
}
- (void) setSeriesNumber: (long) no;
- (void) beginSeriesWithNumber: (long) no;
@end
@implementation DICOMExport
- (id) init { if ((self = [super init])) { exportInstanceNumber = 1; exportSeriesNumber = 5000; exportSeriesUID = [[DCMObject newSeriesInstanceUID] retain]; } return self; }
- (void) dealloc { [exportSeriesUID release]; [super dealloc]; }
// -writeDCMFile: puts these in the file and counts the instance.
- (NSString*) uid { return exportSeriesUID; }
- (int) number { return exportSeriesNumber; }
- (int) write { return exportInstanceNumber++; }
METHODS
@end
static int failures = 0;
#define CHECK(c, ...) do { if (!(c)) { printf("FAIL: "); printf(__VA_ARGS__); printf("\n"); failures++; } } while (0)
int main() { @autoreleasepool {
    DICOMExport *e = [[[DICOMExport alloc] init] autorelease];

    // The report: two exports of one viewer on 5319 (10:09 and 09:10).
    [e beginSeriesWithNumber: 5319];
    NSString *first = [[[e uid] copy] autorelease];
    for (int i = 0; i < 4; i++) [e write];
    [e beginSeriesWithNumber: 5319];
    CHECK(![[e uid] isEqualToString: first], "a second export on the same number writes the series of the first (%s)", [first UTF8String]);
    CHECK([e number] == 5319, "the series number is the one given, not %d", [e number]);
    CHECK([e write] == 1, "the images of the new series are numbered from 1");
    NSString *second = [[[e uid] copy] autorelease];
    CHECK([[e uid] isEqualToString: second] && [e write] == 2, "the steps of one export stay in its series");

    // Another number begins a series too.
    [e beginSeriesWithNumber: 15319];
    CHECK(![[e uid] isEqualToString: second] && [e number] == 15319, "another number begins another series");

    // -setSeriesNumber: as plugins know it: a new UID only for a new number.
    NSString *kept = [[[e uid] copy] autorelease];
    [e setSeriesNumber: 15319];
    CHECK([[e uid] isEqualToString: kept], "-setSeriesNumber: with the number already set keeps the series");
    [e setSeriesNumber: 8200];
    CHECK(![[e uid] isEqualToString: kept] && [e number] == 8200, "-setSeriesNumber: with a new number begins a series");

    if (failures) return 1;
    puts("PASS: -beginSeriesWithNumber: begins a series at each export, -setSeriesNumber: is as before");
}}
'''

if set_number and begin:
    if shutil.which('xcrun') is None:
        print('skipped: needs xcrun (clang)', file=sys.stderr)
        sys.exit(SKIPPED)
    with tempfile.TemporaryDirectory(prefix='horos-export-series-') as folder:
        d = Path(folder)
        (d / 'test.m').write_text(HARNESS.replace('METHODS', set_number + '\n' + begin))
        build = subprocess.run(['xcrun', 'clang', '-fno-objc-arc', '-fsanitize=address', str(d / 'test.m'),
                                '-framework', 'Foundation', '-o', str(d / 'test')], capture_output=True, text=True)
        if build.returncode != 0:
            failures.append('the exporter harness does not compile:\n' + build.stderr[-3000:])
        else:
            run = subprocess.run([str(d / 'test')], capture_output=True, text=True, timeout=60)
            print(run.stdout.strip())
            if run.returncode != 0:
                failures.append('the exporter harness failed')

# ---------------------------------------------------------------- the viewers


def swift_method(text, signature):
    at = text.index(signature)
    return text[at:text.index('\n    }\n', at) + 7]


def begin_calls(text):
    """How a file begins a series: beginSeries(withNumber: and the helpers of the
    file that call it and nothing else."""
    names = ['beginSeries(withNumber:', 'beginSeriesWithNumber:']
    for match in re.finditer(r'\n    (?:private |fileprivate )?func (\w+)\(', text):
        body = text[match.start():text.index('\n    }\n', match.start())]
        if 'beginSeries(withNumber:' in body and 'setSeriesNumber' not in body:
            names.append(match.group(1) + '(')
    return names


def count_begins(region, names):
    helpers = [n for n in names if n not in ('beginSeries(withNumber:', 'beginSeriesWithNumber:')]
    total = region.count('beginSeries(withNumber:') + region.count('beginSeriesWithNumber:')
    for helper in helpers:
        total += len(re.findall(r'(?<![\w.])(?:self\.)?' + re.escape(helper), region))
    return total


def before(region, names, write):
    """The series is begun before the first image of the branch is written."""
    at = region.find(write)
    return at >= 0 and count_begins(region[:at], names) > 0


# The 2D viewer.
viewer = source('Horos/Sources/ViewerController+Export.swift')
names = begin_calls(viewer)
sheet = swift_method(viewer, 'func endExportDICOMFileSettings(')
check('setSeriesNumber' not in sheet, '2D viewer: the DICOM sheet still sends -setSeriesNumber:')
current = sheet[:sheet.index('// 4th Dimension')]
fourth = sheet[sheet.index('// 4th Dimension'):sheet.index('var from: Int32')]
series = sheet[sheet.index('var from: Int32'):]
check(before(current, names, 'self.exportDICOMFileInt('), '2D viewer: the current image begins its series')
check(before(fourth, names, 'while i <') and count_begins(fourth[fourth.index('while i <'):], names) == 0,
      '2D viewer: the 4D export begins one series before its frames')
check(before(series, names, 'while i < to') and count_begins(series[series.index('while i < to'):], names) == 0,
      '2D viewer: the series export begins one series before its images')
all_images = swift_method(viewer, 'func exportAllImages(')
check('setSeriesNumber' not in all_images and before(all_images, names, 'while Int(i)'),
      '2D viewer: -exportAllImages: begins its series')

# The orthogonal MPR viewer.
mpr = source('Horos/Sources/OrthogonalMPRViewer.swift')
names = begin_calls(mpr)
sheet = swift_method(mpr, 'func endExportDICOMFileSettings(')
check('setSeriesNumber' not in sheet, 'orthogonal MPR: the DICOM sheet still sends -setSeriesNumber:')
current = sheet[:sheet.index('// 4th Dimension')]
fourth = sheet[sheet.index('// 4th Dimension'):sheet.index('var deltaX')]
series = sheet[sheet.index('var deltaX'):]
check(before(current, names, 'self.exportDICOMFileInt('), 'orthogonal MPR: the current image begins its series')
check(before(fourth, names, 'while i <') and count_begins(fourth[fourth.index('while i <'):], names) == 0,
      'orthogonal MPR: the 4D export begins one series before its frames')
check(before(series, names, 'for index in indices') and count_begins(series[series.index('for index in indices'):], names) == 0,
      'orthogonal MPR: the series export begins one series before its images')

# The orthogonal PET-CT viewer.
petct = source('Horos/Sources/OrthogonalMPRPETCTViewer.swift')
names = begin_calls(petct)
sheet = swift_method(petct, 'func endExportDICOMFileSettings(')
check('setSeriesNumber' not in sheet, 'PET-CT: the DICOM sheet still sends -setSeriesNumber:')
current = sheet[:sheet.index('// all images of the series')]
one = current[current.index('"export3modalities") == false {'):current.index('} else {')]
three = current[current.index('} else {'):]
check(before(one, names, 'self.exportDICOMFileInt('), 'PET-CT: the current image begins its series')
for view in ('originalView', 'xReslicedView', 'yReslicedView'):
    branch = three[three.index(view):]
    writes = [m.start() for m in re.finditer(r'self\.exportDICOMFileInt\(', branch)][:3]
    starts = [0] + writes[:2]
    check(len(writes) == 3 and all(count_begins(branch[a:b], names) == 1 for a, b in zip(starts, writes)),
          f'PET-CT: each of the three current images of the {view} begins its series')
series = sheet[sheet.index('// all images of the series'):]
single = series[series.index('"export3modalities") == false {'):series.index('} else {', series.index('"export3modalities") == false {'))]
check(before(series, names, '"export3modalities") == false {') and count_begins(single, names) == 0,
      'PET-CT: the series export begins one series before its images')
modalities = series[series.index('for (seriesNumber, seriesView) in'):]
loop = modalities[:modalities.index('for index in indices')]
check(count_begins(loop, names) == 1 and count_begins(modalities[modalities.index('for index in indices'):], names) == 0,
      'PET-CT: each of the three series of the three modalities is begun once, before its images')

# The MPR: the exporter of the view is kept for the current image.
mpr3d = source('Horos/Sources/MPRController.swift')
sheet = swift_method(mpr3d, 'func endDCMExportSettings(')
common = sheet[:sheet.index('// CURRENT image only')]
check('setSeriesNumber(9983)' not in common and 'exportDCM?.beginSeries(withNumber: 9983)' in common,
      'MPR: the current image begins its series on the exporter the view keeps')

# The surface renderer: the exporter is kept for the current image.
surface = source('Horos/Sources/SRView.mm')
sheet = surface[surface.index('-(IBAction) endDCMExportSettings:'):]
current = sheet[sheet.index('// CURRENT image only'):sheet.index('// A 3D sequence')]
check('setSeriesNumber' not in current and before(current, ['beginSeriesWithNumber:'], 'writeDCMFile:'),
      'surface renderer: the current image begins its series')

# The endoscopy's 3D view: the VR view keeps its exporter.
endoscopy = source('Horos/Sources/EndoscopyViewer.swift')
sheet = swift_method(endoscopy, 'func endDCMExportSettings(')
three_d = sheet[sheet.index('// 3D view'):]
check(before(three_d, ['beginSeries(withNumber:'], 'exportDCMCurrentImage(in16bit:'),
      'endoscopy: the 3D view begins its series on the exporter of the VR view')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
print('PASS: each DICOM export that begins writes a series of its own')
