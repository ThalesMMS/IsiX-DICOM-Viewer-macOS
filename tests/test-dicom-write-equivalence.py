#!/usr/bin/env python3
"""DICOM files are read and written as the Objective-C++ that the adapters replaced did.

The host services the dataset model finds by name - HorosDCMTKObject (DCMObject read
by DCMTK), HorosDICOMWriter (DCMObject written by DCMTK, the attribute builder
and the transcoding of a file) and the JPEG 2000 codec - were Objective-C++ in
Horos/Sources. They are now the DCMTK adapters of Horos/Sources/Adapters/DCMTK
and Swift (HorosDICOMWriter.swift over IsiXDCMTKFile and IsiXDCMTKObjectWriter).

The reference is those sources at the last revision that has
Horos/Sources/HorosDICOMWriter.mm, read from history with the headers they had
there. One driver is compiled twice, against the reference and against the
current code (tests/horos_reader.py), each linked with the same DCMTK and
OpenJPEG of the Debug build, and both run over the same synthetic
series (tools/ generators: a CT volume, colour images in every layout, a
multi-frame object). The dataset model (DCMObject and its attributes, under
the DCM.framework's names: horos_reader.former_names) is the current one, the
IsiXDICOMDataset module, on the current side; the reference reader subclasses
the Objective-C model, so on the reference side it is the last Objective-C
model, read from history. The driver writes:

- the attributes each reads (+[DCMObject objectWithContentsOfFile:...], every
  attribute's description) and every decoded frame;
- +writeObject:toFile:transferSyntax:quality:AET: and
  +datasetOfObject:transferSyntax:quality: (HorosDICOMWriter's in the
  reference, IsiXDCMTKObjectWriter's now) in each transfer syntax the writer
  offers - native, deflated, RLE, JPEG lossless and lossy, JPEG-LS, JPEG 2000
  lossless and lossy at qualities 1 to 3 - and +objectByConvertingObject:...
  read back;
- +transcodeFileAtPath:toPath:transferSyntax:error: in the same syntaxes;
- the frames decoded back from each JPEG 2000 file it wrote;
- two objects built attribute by attribute (an encapsulated PDF with non-ASCII
  text, a 16-bit signed secondary capture), with fixed identifiers.

Every output has to be the same bytes. DCMTK gives a lossily compressed object a
new SOP Instance UID of its own; for those files the bytes are compared with that
identifier (and its copy in the meta header) masked, and the count is reported.

Exit 2 without the Debug build, a Python with pydicom and numpy (HOROS_PYTHON or
the local venvs), or the history.

    python3 tests/test-dicom-write-equivalence.py [--reference REV] [--keep DIR]
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import history_reference  # noqa: E402
import horos_reader  # noqa: E402
from dcmtk_build import BUILD, ROOT, dcmtk_flags  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument('--reference', help='revision whose HorosDICOMWriter.mm is the reference')
parser.add_argument('--keep', type=Path, help='keep the outputs here')
arguments = parser.parse_args()

WRITER = 'Horos/Sources/HorosDICOMWriter.mm'
reference = arguments.reference or history_reference.before_removal(WRITER)
if reference is None:
    print('skipped: no revision of this history has %s' % WRITER)
    raise SystemExit(2)
if (ROOT / WRITER).exists():
    print('skipped: %s is still the writer; there is nothing to compare it with' % WRITER)
    raise SystemExit(2)
# The last revision whose dataset model was Objective-C, in the adapter folder.
MODEL = 'Horos/Sources/Adapters/DCMTK/DCMObject.m'
MODEL_REVISION = history_reference.before_removal(MODEL) or (
    'HEAD' if subprocess.run(['git', '-C', str(ROOT), 'cat-file', '-e', 'HEAD:' + MODEL]).returncode == 0 else None)
if MODEL_REVISION is None:
    print('skipped: no revision of this history has %s' % MODEL)
    raise SystemExit(2)
PRODUCTS = ROOT / 'build/Build/Products' / BUILD.name
reason = horos_reader.missing(PRODUCTS)
if reason:
    print('skipped: needs a current Debug build from script/build_and_run.sh --verify: ' + reason)
    raise SystemExit(2)


def find_python():
    candidates = [os.environ.get('HOROS_PYTHON'), str(ROOT / 'local-validation/venv/bin/python'),
                  str(ROOT.parent.parent.parent / 'local-validation/net-venv/bin/python')
                  if ROOT.parent.name == 'worktrees' else None,
                  str(ROOT / 'local-validation/net-venv/bin/python'), sys.executable]
    for candidate in filter(None, candidates):
        if Path(candidate).exists() and subprocess.run([candidate, '-c', 'import pydicom, numpy'],
                                                       capture_output=True).returncode == 0:
            return candidate
    return None


python = find_python()
if python is None:
    print('skipped: the generators need a Python with pydicom and numpy (HOROS_PYTHON)')
    raise SystemExit(2)

# (transfer syntax, quality); quality is a DCM_CompressionQuality, 0 lossless.
SYNTAXES = [('1.2.840.10008.1.2.1', 0), ('1.2.840.10008.1.2', 0), ('1.2.840.10008.1.2.2', 0),
            ('1.2.840.10008.1.2.1.99', 0), ('1.2.840.10008.1.2.5', 0), ('1.2.840.10008.1.2.4.70', 0),
            ('1.2.840.10008.1.2.4.57', 0), ('1.2.840.10008.1.2.4.50', 1), ('1.2.840.10008.1.2.4.50', 3),
            ('1.2.840.10008.1.2.4.51', 2), ('1.2.840.10008.1.2.4.80', 0), ('1.2.840.10008.1.2.4.81', 1),
            ('1.2.840.10008.1.2.4.90', 0), ('1.2.840.10008.1.2.4.91', 1), ('1.2.840.10008.1.2.4.91', 2),
            ('1.2.840.10008.1.2.4.91', 3)]

DRIVER = r'''
#import <Foundation/Foundation.h>
#import <DCM/DCM.h>
#import <DCM/DCMAbstractSyntaxUID.h>
#import <DCM/DCMCalendarDate.h>
#import <DCM/DCMPixelDataAttribute.h>
#import "HorosDICOMWriter.h"
// DCMObject writing was HorosDICOMWriter's in the reference; it is the DCMTK
// adapter's now, which the dataset model finds by name.
#ifdef ISIX_OBJECT_WRITER
#import "IsiXDCMTKObjectWriter.h"
#define OBJECT_WRITER IsiXDCMTKObjectWriter
#else
#define OBJECT_WRITER HorosDICOMWriter
#endif

extern "C" void HorosTestRegisterDecoders(void);

static void Save(NSString *folder, NSString *name, NSData *data)
{
    [(data ?: [NSData data]) writeToFile:[folder stringByAppendingPathComponent:name] atomically:NO];
}

// Every attribute's description, by tag, and the frames the object decodes.
static void Describe(DCMObject *object, NSString *folder, NSString *name)
{
    NSMutableString *text = [NSMutableString string];
    if (!object) { Save(folder, [name stringByAppendingString:@".attributes"], [@"(nil)" dataUsingEncoding:NSUTF8StringEncoding]); return; }
    for (NSString *key in [object.attributes.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        DCMAttribute *attribute = object.attributes[key];
        if ([attribute isKindOfClass:DCMPixelDataAttribute.class]) {
            DCMPixelDataAttribute *pixels = (DCMPixelDataAttribute *)attribute;
            [text appendFormat:@"%@ pixel data, %d frame(s), %@\n", key, (int)pixels.numberOfFrames,
                               pixels.transferSyntax.transferSyntax];
            for (int frame = 0; frame < pixels.numberOfFrames; ++frame) {
                NSData *decoded = nil;
                @try { decoded = [pixels decodeFrameAtIndex:frame]; } @catch (NSException *e) { decoded = nil; }
                Save(folder, [NSString stringWithFormat:@"%@.frame%d", name, frame], decoded);
            }
        } else
            [text appendFormat:@"%@\n", attribute.description];
    }
    Save(folder, [name stringByAppendingString:@".attributes"], [text dataUsingEncoding:NSUTF8StringEncoding]);
}

static void Build(NSString *folder)
{
    NSData *pdf = [@"%PDF-1.4\n1 0 obj << >> endobj\ntrailer << >>\n%%EOF\n" dataUsingEncoding:NSASCIIStringEncoding];
    HorosDICOMWriter *report = [[[HorosDICOMWriter alloc] init] autorelease];
    NSMutableString *answers = [NSMutableString string];
    NSArray *values = @[@[@"SOPClassUID", [DCMAbstractSyntaxUID pdfStorageClassUID]], @[@"SOPInstanceUID", @"1.2.826.0.1.3680043.2.1143.1.1"],
                        @[@"StudyInstanceUID", @"1.2.826.0.1.3680043.2.1143.1.2"], @[@"SeriesInstanceUID", @"1.2.826.0.1.3680043.2.1143.1.3"],
                        @[@"PatientsName", @"Müller^José"], @[@"PatientID", @"PID-738"], @[@"PatientsBirthDate"],
                        @[@"PatientsSex", @"O"], @[@"StudyDate", [DCMCalendarDate dicomDate:@"20260926"]],
                        @[@"StudyTime", [DCMCalendarDate dicomTime:@"123456"]], @[@"DocumentTitle", @"Relatório"],
                        @[@"InstanceNumber", @"1"], @[@"SeriesNumber", @"0"], @[@"Modality", @"OT"],
                        @[@"MIMETypeOfEncapsulatedDocument", @"application/pdf"], @[@"NoSuchAttributeAnywhere", @"x"]];
    for (NSArray *pair in values)
        [answers appendFormat:@"%@ %d\n", pair[0], [report setValues:[pair subarrayWithRange:NSMakeRange(1, pair.count - 1)] forName:pair[0]]];
    [answers appendFormat:@"sequence %d\n", [report setEmptySequenceForName:@"ConceptNameCodeSequence"]];
    [answers appendFormat:@"data %d\n", [report setData:pdf forName:@"EncapsulatedDocument" vr:@"OB"]];
    [answers appendFormat:@"values %@\n", [report valuesForName:@"PatientsName"]];
    [answers appendFormat:@"write %d\n", [report writeToFile:[folder stringByAppendingPathComponent:@"built-report.dcm"]
                                              transferSyntax:@"1.2.840.10008.1.2.1"]];

    HorosDICOMWriter *capture = [[[HorosDICOMWriter alloc] init] autorelease];
    NSMutableData *pixels = [NSMutableData dataWithLength:4 * 5 * 2];
    short *p = (short *)pixels.mutableBytes;
    for (int i = 0; i < 20; i++) p[i] = (short)(i * 1111 - 9000);
    NSArray *image = @[@[@"SOPClassUID", [DCMAbstractSyntaxUID secondaryCaptureImageStorage]],
                       @[@"SOPInstanceUID", @"1.2.826.0.1.3680043.2.1143.2.1"], @[@"StudyInstanceUID", @"1.2.826.0.1.3680043.2.1143.2.2"],
                       @[@"SeriesInstanceUID", @"1.2.826.0.1.3680043.2.1143.2.3"], @[@"Modality", @"SC"], @[@"Rows", @4],
                       @[@"Columns", @5], @[@"SamplesperPixel", @1], @[@"PhotometricInterpretation", @"MONOCHROME2"],
                       @[@"BitsAllocated", @16], @[@"BitsStored", @16], @[@"HighBit", @15], @[@"PixelRepresentation", @YES],
                       @[@"PixelSpacing", @"0.5", @"0.25"], @[@"WindowCenter", @40.5, @-12]];
    for (NSArray *pair in image)
        [answers appendFormat:@"%@ %d\n", pair[0], [capture setValues:[pair subarrayWithRange:NSMakeRange(1, pair.count - 1)] forName:pair[0]]];
    [answers appendFormat:@"pixels %d\n", [capture setData:pixels forName:@"PixelData" vr:@"OW"]];
    for (NSString *syntax in @[@"1.2.840.10008.1.2", @"1.2.840.10008.1.2.1", @"1.2.840.10008.1.2.4.90", @"9.9.9"])
        [answers appendFormat:@"write %@ %d\n", syntax, [capture writeToFile:[folder stringByAppendingPathComponent:
            [NSString stringWithFormat:@"built-capture-%@.dcm", syntax]] transferSyntax:syntax]];
    Save(folder, @"built.answers", [answers dataUsingEncoding:NSUTF8StringEncoding]);
}

int main(int argc, char **argv) { @autoreleasepool {
    HorosTestRegisterDecoders();
    NSString *folder = @(argv[1]);
    NSArray *syntaxes = [[NSString stringWithContentsOfFile:@(argv[2]) encoding:NSUTF8StringEncoding error:NULL]
                         componentsSeparatedByString:@"\n"];
    Build(folder);
    for (int i = 3; i < argc; ++i) { @autoreleasepool {
        NSString *path = @(argv[i]);
        NSString *name = [NSString stringWithFormat:@"f%03d", i - 3];
        Describe([DCMObject objectWithContentsOfFile:path decodingPixelData:NO], folder, name);
        NSMutableString *answers = [NSMutableString string];
        for (NSString *line in syntaxes) {
            if (!line.length) continue;
            NSArray *parts = [line componentsSeparatedByString:@" "];
            NSString *syntax = parts[0];
            int quality = [parts[1] intValue];
            NSString *stem = [NSString stringWithFormat:@"%@.%@.q%d", name, syntax, quality];
            @autoreleasepool {
                DCMObject *object = [DCMObject objectWithContentsOfFile:path decodingPixelData:NO];
                NSString *written = [folder stringByAppendingPathComponent:[stem stringByAppendingString:@".write.dcm"]];
                BOOL ok = [OBJECT_WRITER writeObject:object toFile:written transferSyntax:syntax quality:quality AET:@"EQUIVALENCE"];
                [answers appendFormat:@"%@ write %d\n", stem, ok];
                if (ok && [syntax hasPrefix:@"1.2.840.10008.1.2.4.9"])
                    Describe([DCMObject objectWithContentsOfFile:written decodingPixelData:NO], folder,
                             [stem stringByAppendingString:@".write.read"]);
            }
            @autoreleasepool {
                DCMObject *object = [DCMObject objectWithContentsOfFile:path decodingPixelData:NO];
                Save(folder, [stem stringByAppendingString:@".dataset"],
                     [OBJECT_WRITER datasetOfObject:object transferSyntax:syntax quality:quality]);
            }
            @autoreleasepool {
                DCMObject *object = [DCMObject objectWithContentsOfFile:path decodingPixelData:NO];
                Describe([OBJECT_WRITER objectByConvertingObject:object toTransferSyntax:syntax quality:quality], folder,
                         [stem stringByAppendingString:@".converted"]);
            }
            if (quality <= 1) @autoreleasepool {
                NSError *error = nil;
                BOOL ok = [HorosDICOMWriter transcodeFileAtPath:path toPath:[folder stringByAppendingPathComponent:
                                                [stem stringByAppendingString:@".transcoded.dcm"]]
                                                transferSyntax:syntax error:&error];
                [answers appendFormat:@"%@ transcode %d %@\n", stem, ok, error ? @"error" : @"-"];
            }
        }
        Save(folder, [name stringByAppendingString:@".answers"], [answers dataUsingEncoding:NSUTF8StringEncoding]);
    }}
    printf("done\n");
    return 0;
}}
'''

# The reference's sources, compiled as tests/horos_reader.py compiled them there.
REFERENCE_SOURCES = ['Horos/Sources/HorosDCMTKObject.mm', 'Horos/Sources/HorosDICOMServices.mm', WRITER,
                     'Horos/Sources/HorosJPEG2000Codec.cpp', 'Horos/Sources/DICOMDataDictionary.mm']
INCLUDE = re.compile(rb'^\s*#\s*(?:import|include)\s+"([^"]+)"', re.M)


def export_reference(folder):
    """The reference's sources and every Horos/Sources header they reach, as they were."""
    pending, seen = list(REFERENCE_SOURCES), set()
    while pending:
        path = pending.pop()
        if path in seen:
            continue
        seen.add(path)
        shown = subprocess.run(['git', '-C', str(ROOT), 'show', '%s:%s' % (reference, path)], capture_output=True)
        if shown.returncode:
            continue  # not in Horos/Sources: a DCMTK or framework header, found by the search paths
        data = shown.stdout
        (folder / Path(path).name).write_bytes(data)
        pending += ['Horos/Sources/' + name.decode() for name in INCLUDE.findall(data)]
    return [folder / Path(p).name for p in REFERENCE_SOURCES]


def build_reference(work):
    sources = work / 'reference-sources'
    sources.mkdir()
    mm = export_reference(sources)
    setup = sources / 'setup.mm'
    setup.write_text(horos_reader.SETUP.replace('HorosJPEG2000Codec.hpp', 'HorosJPEG2000Codec.h'))
    flags = dcmtk_flags('dcmjpeg', 'horosdcmjpls', 'dcmimage', 'dcmimgle', 'ijg8', 'ijg12', 'ijg16', 'dcmnet')
    openjpeg = BUILD / 'OpenJPEG.build/Install'
    # The reference reader subclasses the Objective-C dataset model, which an
    # Objective-C class cannot do to the Swift one: the model is the last
    # Objective-C one, from history, with its headers first.
    model = horos_reader.model_objects(work / 'reference-model', revision=MODEL_REVISION)
    headers = ['-I', str(horos_reader.former_names(work / 'reference-names', model_headers=False)), '-I', str(sources),
               '-I', str(work / 'reference-model/model-sources'),
               '-I', str(horos_reader.ADAPTERS), '-I', str(work / 'reference-model/modules'),
               '-I', str(openjpeg / 'include'), *flags[:2]]
    objects = []
    for path in (mm[0], mm[1], mm[2], setup, work / 'driver.mm'):
        obj = work / ('reference-' + path.name + '.o')
        subprocess.run(['xcrun', 'clang++', '-std=c++17', '-fno-objc-arc', '-fmodules', '-fcxx-modules', '-w',
                        '-mmacosx-version-min=15.0', *headers, '-x', 'objective-c++', '-c', str(path), '-o', str(obj)],
                       check=True)
        objects.append(str(obj))
    for path, arc, language in ((mm[3], '-fno-objc-arc', 'c++'), (mm[4], '-fobjc-arc', 'objective-c++')):
        obj = work / ('reference-' + path.name + '.o')
        subprocess.run(['xcrun', 'clang++', '-std=c++17', arc, '-w', '-mmacosx-version-min=15.0', *headers,
                        '-x', language, '-c', str(path), '-o', str(obj)], check=True)
        objects.append(str(obj))
    output = work / 'reference/bin/driver'
    subprocess.run(['xcrun', 'clang++', *objects, *model, '-framework', 'Foundation',
                    *horos_reader.link_flags(PRODUCTS), '-o', str(output)], check=True)
    return output


def generate(folder):
    files = []
    folder.mkdir(parents=True)
    for tool, extra in (('generate-ct-phantom-fixture.py', ['--slices', '3', '--size', '48']),
                        ('generate-colour-space-fixture.py', ['--rows', '24', '--columns', '32']),
                        ('generate-multiframe-fixture.py', ['--frames', '3'])):
        destination = folder / Path(tool).stem
        if tool != 'generate-multiframe-fixture.py':
            destination.mkdir(parents=True)
        subprocess.run([python, str(ROOT / 'tools' / tool), str(destination), *extra], check=True,
                       capture_output=True, text=True)
        files += sorted(p for p in (destination.rglob('*') if destination.is_dir() else [destination]) if p.is_file()
                        and p.read_bytes()[128:132] == b'DICM')
    return files


def main():
    work = Path(tempfile.mkdtemp(prefix='isix-write-equivalence-'))
    try:
        for side in ('reference', 'current'):
            (work / side / 'bin').mkdir(parents=True)
            (work / side / 'out').mkdir()
        (work / 'driver.mm').write_text(DRIVER)
        files = generate(work / 'files')
        if not files:
            raise SystemExit('FAIL: the generators wrote no DICOM file')
        build_reference(work)
        horos_reader.compile_reader(PRODUCTS, work / 'driver.mm', work / 'current/bin/driver', work / 'current',
                                    extra=['-I', str(ROOT / 'Horos/Sources'), '-DISIX_OBJECT_WRITER'])
        shipped = BUILD.parent.parent.parent / 'Products' / BUILD.name / 'DCMTK/dicom.dic'
        syntaxes = work / 'syntaxes.txt'
        syntaxes.write_text(''.join('%s %d\n' % pair for pair in SYNTAXES))
        for side in ('reference', 'current'):
            if shipped.is_file():
                shutil.copy(shipped, work / side / 'bin/dicom.dic')
            run = subprocess.run([str(work / side / 'bin/driver'), str(work / side / 'out'), str(syntaxes),
                                  *map(str, files)], capture_output=True, text=True, timeout=900)
            (work / (side + '.log')).write_text(run.stdout + run.stderr)
            if run.returncode or 'done' not in run.stdout:
                raise SystemExit('FAIL: the %s driver ended with %s:\n%s' % (side, run.returncode, (run.stdout + run.stderr)[-3000:]))
        compare = subprocess.run([python, '-c', COMPARE, str(work / 'reference/out'), str(work / 'current/out')],
                                 capture_output=True, text=True)
        print(compare.stdout.strip())
        if compare.stderr.strip():
            print(compare.stderr.strip()[-3000:])
        if arguments.keep:
            shutil.rmtree(arguments.keep, ignore_errors=True)
            shutil.copytree(work, arguments.keep, symlinks=True)
        if compare.returncode:
            raise SystemExit(1)
        print('PASS: %d synthetic files in %d syntaxes read and written as the reference (%s) did'
              % (len(files), len(SYNTAXES), reference[:9]))
    finally:
        shutil.rmtree(work, ignore_errors=True)


COMPARE = r'''
import re
import sys
from pathlib import Path
import pydicom
from pydicom.filebase import DicomBytesIO

reference, current = Path(sys.argv[1]), Path(sys.argv[2])
names = sorted({p.name for p in reference.iterdir()} | {p.name for p in current.iterdir()})
identical = masked_equal = 0
failures = []
kinds = {}


def without_generated_uid(path):
    """The file's elements, the SOP Instance UIDs aside, as raw (tag, VR, value bytes)."""
    data = pydicom.dcmread(str(path), force=True)
    meta = [(e.tag, e.VR, e.value) for e in data.file_meta if e.tag not in (0x00020003, 0x00020000)]
    body = [(e.tag, e.VR, e.value if e.VR != 'SQ' else repr(e.value)) for e in data if e.tag != 0x00080018]
    return meta, body, data.get('SOPInstanceUID')


for name in names:
    a, b = reference / name, current / name
    kind = name.split('.')[-1] if not name.startswith('built') else 'built'
    if '.write.read.' in name or name.endswith('.write.read.attributes'):
        kind = 'decoded J2K'
    kinds[kind] = kinds.get(kind, 0) + 1
    if not a.exists() or not b.exists():
        failures.append('%s is only in the %s output' % (name, 'reference' if a.exists() else 'current'))
        continue
    x, y = a.read_bytes(), b.read_bytes()
    if x == y:
        identical += 1
        continue
    if name.endswith('.dcm') and '4.5' in name or name.endswith('.dcm') and ('4.81' in name or '4.91' in name):
        try:
            mx, my = without_generated_uid(a), without_generated_uid(b)
        except Exception as error:
            failures.append('%s: differs and does not parse (%s)' % (name, error))
            continue
        if mx[0] == my[0] and mx[1] == my[1] and mx[2] != my[2]:
            masked_equal += 1
            continue
    if name.endswith('.attributes') and ('4.5' in name or '4.81' in name or '4.91' in name):
        # An attribute's description runs from its tag to the closing parenthesis.
        strip = lambda t: re.sub(r'0008,0018\tSOPInstanceUID\t.*?\n\)\n', '', t.decode('utf-8', 'replace'), flags=re.S)
        if strip(x) == strip(y):
            masked_equal += 1
            continue
    if name.endswith('.dataset') and ('4.5' in name or '4.81' in name or '4.91' in name):
        def parse(raw):
            ds = pydicom.dcmread(DicomBytesIO(raw), force=True)
            return [(e.tag, e.VR, e.value if e.VR != 'SQ' else repr(e.value)) for e in ds if e.tag != 0x00080018]
        try:
            if parse(x) == parse(y):
                masked_equal += 1
                continue
        except Exception:
            pass
    failures.append('%s: %d bytes against %d' % (name, len(x), len(y)))

for failure in failures[:40]:
    print('FAIL: ' + failure)
print('%d outputs identical, %d identical but for the SOP Instance UID DCMTK generates for a lossy copy, %d different; %s'
      % (identical, masked_equal, len(failures), ', '.join('%s %d' % item for item in sorted(kinds.items()))))
sys.exit(1 if failures else 0)
'''

main()
