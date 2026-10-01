#!/usr/bin/env python3
"""HorosDICOMWriter writes valid objects through DCMTK (#738).

Builds Horos/Sources/HorosDICOMWriter.mm, with the host reader and codecs
(horos_reader.py), against the built DCM.framework, and writes:

- an Encapsulated PDF document with the attributes the report path sets,
  a non-ASCII patient name, dates, an empty sequence and the PDF bytes;
- a Secondary Capture with signed 16-bit pixels written as OW.

Then pydicom reads both back (values, PDF bytes and pixels identical) and
dciodvfy, the validator the application ships, finds no error in either IOD.

Usage: python test-dicom-writer.py PRODUCTS_DIR PYTHON
       PYTHON has pydicom and numpy
"""
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dcmtk_build import ROOT
import horos_reader

if len(sys.argv) != 3:
    print('skipped: needs the built DCM framework and a Python with pydicom/numpy: PRODUCTS_DIR PYTHON',
          file=sys.stderr)
    raise SystemExit(2)
products, python = Path(sys.argv[1]).resolve(), sys.argv[2]
validator = ROOT / 'Binaries/dciodvfy'
if not (products / 'DCM.framework').is_dir():
    print('skipped: no DCM.framework in %s: PRODUCTS_DIR PYTHON' % products, file=sys.stderr)
    raise SystemExit(2)
if horos_reader.missing(products):
    print('skipped: %s: PRODUCTS_DIR PYTHON' % horos_reader.missing(products), file=sys.stderr)
    raise SystemExit(2)

driver = r'''
#import <Foundation/Foundation.h>
#import <DCM/DCM.h>
#import <DCM/DCMAbstractSyntaxUID.h>
#import <DCM/DCMCalendarDate.h>
#import "HorosDICOMWriter.h"
#include <dlfcn.h>
int main(int argc, char **argv) { @autoreleasepool {
    for (int i = 2; i < argc; ++i) {
        void *library = dlopen(argv[i], RTLD_NOW | RTLD_GLOBAL);
        if (!library) { fprintf(stderr, "%s\n", dlerror()); return 1; }
        int (*ownership)(void) = (int (*)(void))dlsym(library, "HorosTestWriterUIDOwnership");
        if (!ownership) { fprintf(stderr, "ownership symbol: %s\n", dlerror()); return 1; }
        if (ownership() != 1) { fprintf(stderr, "ownership callback failed: %s\n", argv[i]); return 1; }
        // Keep the Swift/ARC image loaded until process exit.
    }
    NSString *folder = @(argv[1]);
    NSData *pdf = [@"%PDF-1.4\n1 0 obj << >> endobj\ntrailer << >>\n%%EOF\n" dataUsingEncoding: NSASCIIStringEncoding];
    HorosDICOMWriter *report = [[[HorosDICOMWriter alloc] init] autorelease];
    BOOL ok = YES;
    ok &= [report setValues: @[[DCMAbstractSyntaxUID pdfStorageClassUID]] forName: @"SOPClassUID"];
    ok &= [report setValues: @[[HorosDICOMWriter newSOPInstanceUID]] forName: @"SOPInstanceUID"];
    ok &= [report setValues: @[[HorosDICOMWriter newStudyInstanceUID]] forName: @"StudyInstanceUID"];
    ok &= [report setValues: @[[HorosDICOMWriter newSeriesInstanceUID]] forName: @"SeriesInstanceUID"];
    ok &= [report setValues: @[@"Müller^José"] forName: @"PatientsName"];
    ok &= [report setValues: @[@"PID-738"] forName: @"PatientID"];
    ok &= [report setValues: @[] forName: @"PatientsBirthDate"];
    ok &= [report setValues: @[@"O"] forName: @"PatientsSex"];
    ok &= [report setValues: @[[DCMCalendarDate dicomDate: @"20260926"]] forName: @"StudyDate"];
    ok &= [report setValues: @[[DCMCalendarDate dicomTime: @"123456"]] forName: @"StudyTime"];
    ok &= [report setValues: @[[DCMCalendarDate dicomDate: @"20260926"]] forName: @"ContentDate"];
    ok &= [report setValues: @[[DCMCalendarDate dicomTime: @"123456"]] forName: @"ContentTime"];
    ok &= [report setValues: @[] forName: @"AcquisitionDatetime"];
    ok &= [report setValues: @[@"Relatório"] forName: @"DocumentTitle"];
    ok &= [report setValues: @[@"1"] forName: @"InstanceNumber"];
    ok &= [report setValues: @[@"0"] forName: @"SeriesNumber"];
    ok &= [report setValues: @[@"1"] forName: @"StudyID"];
    ok &= [report setValues: @[] forName: @"AccessionNumber"];
    ok &= [report setValues: @[] forName: @"ReferringPhysiciansName"];
    ok &= [report setValues: @[@"NO"] forName: @"BurnedInAnnotation"];
    ok &= [report setValues: @[@"WSD"] forName: @"ConversionType"];
    ok &= [report setValues: @[@"Horos"] forName: @"Manufacturer"];
    ok &= [report setValues: @[@"OT"] forName: @"Modality"];
    ok &= [report setEmptySequenceForName: @"ConceptNameCodeSequence"];
    ok &= [report setValues: @[@"application/pdf"] forName: @"MIMETypeOfEncapsulatedDocument"];
    ok &= [report setData: pdf forName: @"EncapsulatedDocument" vr: @"OB"];
    ok &= ![report setValues: @[@"x"] forName: @"NoSuchAttributeAnywhere"];
    ok &= [report writeToFile: [folder stringByAppendingPathComponent: @"report.dcm"] transferSyntax: @"1.2.840.10008.1.2.1"];

    HorosDICOMWriter *capture = [[[HorosDICOMWriter alloc] init] autorelease];
    const int rows = 4, columns = 5;
    NSMutableData *pixels = [NSMutableData dataWithLength: rows * columns * 2];
    short *p = (short *) pixels.mutableBytes;
    for (int i = 0; i < rows * columns; i++) p[i] = (short) (i * 1111 - 9000);
    ok &= [capture setValues: @[[DCMAbstractSyntaxUID secondaryCaptureImageStorage]] forName: @"SOPClassUID"];
    ok &= [capture setValues: @[[HorosDICOMWriter newSOPInstanceUID]] forName: @"SOPInstanceUID"];
    ok &= [capture setValues: @[[HorosDICOMWriter newStudyInstanceUID]] forName: @"StudyInstanceUID"];
    ok &= [capture setValues: @[[HorosDICOMWriter newSeriesInstanceUID]] forName: @"SeriesInstanceUID"];
    for (NSString *name in @[@"PatientsName", @"PatientID", @"PatientsBirthDate", @"PatientsSex", @"StudyID",
                             @"AccessionNumber", @"ReferringPhysiciansName", @"SeriesNumber", @"InstanceNumber",
                             @"Laterality", @"PatientOrientation"])
        ok &= [capture setValues: @[] forName: name];
    ok &= [capture setValues: @[[DCMCalendarDate dicomDate: @"20260926"]] forName: @"StudyDate"];
    ok &= [capture setValues: @[[DCMCalendarDate dicomTime: @"123456"]] forName: @"StudyTime"];
    ok &= [capture setValues: @[@"SC"] forName: @"Modality"];
    ok &= [capture setValues: @[@"WSD"] forName: @"ConversionType"];
    ok &= [capture setValues: @[@(rows)] forName: @"Rows"];
    ok &= [capture setValues: @[@(columns)] forName: @"Columns"];
    ok &= [capture setValues: @[@1] forName: @"SamplesperPixel"];
    ok &= [capture setValues: @[@"MONOCHROME2"] forName: @"PhotometricInterpretation"];
    ok &= [capture setValues: @[@16] forName: @"BitsAllocated"];
    ok &= [capture setValues: @[@16] forName: @"BitsStored"];
    ok &= [capture setValues: @[@15] forName: @"HighBit"];
    ok &= [capture setValues: @[@YES] forName: @"PixelRepresentation"];
    ok &= [capture setValues: @[@"0.5", @"0.25"] forName: @"PixelSpacing"];
    ok &= [capture setData: pixels forName: @"PixelData" vr: @"OW"];
    ok &= [capture writeToFile: [folder stringByAppendingPathComponent: @"capture.dcm"] transferSyntax: @"1.2.840.10008.1.2"];
    printf("%s\n", ok ? "written" : "FAILED");
    return ok ? 0 : 1;
}}
'''

check = r'''
import sys, numpy as np, pydicom
folder = sys.argv[1]
r = pydicom.dcmread(folder + '/report.dcm')
assert str(r.SpecificCharacterSet) == 'ISO_IR 192', r.SpecificCharacterSet
assert str(r.PatientName) == 'Müller^José', r.PatientName
assert str(r.DocumentTitle) == 'Relatório', r.DocumentTitle
assert r.EncapsulatedDocument.startswith(b'%PDF-1.4') and r.EncapsulatedDocument.rstrip(b'\0').endswith(b'%%EOF\n')
assert r.MIMETypeOfEncapsulatedDocument == 'application/pdf' and r.Modality == 'OT'
assert r.StudyDate == '20260926' and r.StudyTime.startswith('123456') and r.ConceptNameCodeSequence == []
assert r.file_meta.MediaStorageSOPClassUID == '1.2.840.10008.5.1.4.1.1.104.1'
c = pydicom.dcmread(folder + '/capture.dcm')
assert str(c.file_meta.TransferSyntaxUID) == '1.2.840.10008.1.2'
expected = (np.arange(20, dtype=np.int32) * 1111 - 9000).astype(np.int16).reshape(4, 5)
assert np.array_equal(c.pixel_array, expected), c.pixel_array
assert [float(v) for v in c.PixelSpacing] == [0.5, 0.25]
print('pydicom: values, PDF bytes and pixels read back')
'''

# Compile actual Swift and ARC callers of the production MRC UID factories.
# The old header's implicit new-family +1 contract must be rejected by the same
# pool-loop consumer, not by an assertion that merely scans the annotation.
uid_swift = r'''
import Foundation
@_cdecl("HorosTestWriterUIDOwnership")
public func writerUIDOwnership() -> Int32 {
    for _ in 0..<64 {
        autoreleasepool {
            let writer = HorosDICOMWriter()
            let identifiers = [HorosDICOMWriter.newStudyInstanceUID(),
                               HorosDICOMWriter.newSeriesInstanceUID(),
                               HorosDICOMWriter.newSOPInstanceUID()]
            precondition(Set(identifiers).count == 3)
            for (key, uid) in zip(["StudyInstanceUID", "SeriesInstanceUID", "SOPInstanceUID"], identifiers) {
                precondition(uid.count <= 64 && uid.contains("."))
                precondition(writer.setValues([uid], forName: key))
                precondition((writer.values(forName: key)?.first as? String) == uid)
                precondition(writer.setValues(["1.2.3"], forName: key))
            }
        }
    }
    return 1
}
'''
uid_arc = r'''
#import "HorosDICOMWriter.h"
int HorosTestWriterUIDOwnership(void) {
    for (int i = 0; i < 64; ++i) { @autoreleasepool {
        HorosDICOMWriter *writer = [HorosDICOMWriter new];
        NSArray *uids = @[[HorosDICOMWriter newStudyInstanceUID],
                          [HorosDICOMWriter newSeriesInstanceUID],
                          [HorosDICOMWriter newSOPInstanceUID]];
        NSArray *keys = @[@"StudyInstanceUID", @"SeriesInstanceUID", @"SOPInstanceUID"];
        if ([NSSet setWithArray:uids].count != 3) return 0;
        for (NSUInteger j = 0; j < uids.count; ++j) {
            NSString *uid = uids[j];
            if (uid.length > 64 || [uid rangeOfString:@"."].location == NSNotFound) return 0;
            if (![writer setValues:@[uid] forName:keys[j]]) return 0;
            if (![[writer valuesForName:keys[j]].firstObject isEqual:uid]) return 0;
            if (![writer setValues:@[@"1.2.3"] forName:keys[j]]) return 0;
        }
    }}
    return 1;
}
'''

with tempfile.TemporaryDirectory(prefix='horos-writer-') as work:
    work = Path(work)
    (work / 'bin').mkdir()
    (work / 'Frameworks').symlink_to(products)
    (work / 'driver.mm').write_text(driver)
    # The writer and the reader it hands DCMObject writing back through (#742).
    horos_reader.compile_reader(products, work / 'driver.mm', work / 'bin/driver', work)
    header = ROOT / 'Horos/Sources/HorosDICOMWriter.h'
    # Temporary Swift source carries the same attribution as other new sources.
    copyright_header = (ROOT / 'Horos/Sources/RichTextReportPDF.swift').read_text().split('import AppKit', 1)[0]
    (work / 'ownership.swift').write_text(copyright_header + uid_swift)
    (work / 'ownership.m').write_text(uid_arc)
    swift_library = work / 'uid-swift.dylib'
    arc_library = work / 'uid-arc.dylib'
    def compile_swift(bridge, destination):
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-strict-concurrency=complete',
                        '-warnings-as-errors', '-parse-as-library', '-emit-library', '-O',
                        '-import-objc-header', str(bridge), str(work / 'ownership.swift'),
                        '-Xlinker', '-undefined', '-Xlinker', 'dynamic_lookup',
                        '-o', str(destination)], check=True)
    compile_swift(header, swift_library)
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-Werror', '-dynamiclib',
                    '-I', str(header.parent), str(work / 'ownership.m'), '-framework', 'Foundation',
                    '-undefined', 'dynamic_lookup', '-o', str(arc_library)], check=True)
    old_header = work / 'old-writer.h'
    old_header.write_text(header.read_text().replace(' NS_RETURNS_NOT_RETAINED', ''))
    negative_library = work / 'uid-old-swift.dylib'
    compile_swift(old_header, negative_library)
    out = work / 'out'
    out.mkdir()
    subprocess.run([str(work / 'bin/driver'), str(out), str(swift_library), str(arc_library)], check=True)
    print('ownership: real Swift 6 and ARC callers survive 64 autorelease pools and value replacement')
    negative_out = work / 'negative-out'
    negative_out.mkdir()
    negative = subprocess.run([str(work / 'bin/driver'), str(negative_out), str(negative_library)],
                              capture_output=True, text=True, timeout=60, env={**os.environ, 'NSZombieEnabled': 'YES'})
    negative_output = negative.stdout + negative.stderr
    if 'message sent to deallocated instance' not in negative_output:
        print('FAIL: original new-family ownership did not trigger the expected zombie', file=sys.stderr)
        raise SystemExit(1)
    print('negative: original header rejected by actual deallocated-object diagnostic')
    subprocess.run([python, '-c', check, str(out)], check=True)
    failures = []
    if validator.is_file():
        for name in ('report.dcm', 'capture.dcm'):
            report = subprocess.run([str(validator), str(out / name)], capture_output=True, text=True)
            errors = [line for line in (report.stdout + report.stderr).splitlines() if line.startswith('Error')]
            print('dciodvfy %s: %d error(s)' % (name, len(errors)))
            failures += ['%s: %s' % (name, e) for e in errors]
    else:
        print('dciodvfy not present; the independent validator did not run')
for failure in failures:
    print('FAIL: ' + failure)
sys.exit(1 if failures else 0)
