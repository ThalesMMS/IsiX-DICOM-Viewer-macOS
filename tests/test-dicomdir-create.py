#!/usr/bin/env python3
"""A DICOMDIR is created over a folder with the real DCMTK, and read back.

`+[DicomDir createDicomDirAtDir:error:]` asked `OFStandard::searchDirectoryRecursively`
for the folder's files with NULL as the pattern. The pattern is an OFString, which
this DCMTK builds on std::string, and std::string(NULL) aborts under libc++'s
hardening (undefined behaviour without it): every media burn and every DICOM export
with a DICOMDIR stopped the app before an index was written.
tests/test-dicomdir-result.py exercises the same method against a stand-in adapter.

Here DicomDir.swift is compiled as the app has it, with the real ExportArchive,
the IsiXDICOMFile rules and the DCMTK adapter (IsiXDCMTKDicomDir.mm), against
the DCMTK archives the app links, with libc++'s extensive hardening: the fast
mode has no null check, so the old source crashed on strlen instead of the
assertion the app stopped on. It indexes a synthetic folder - two series of one
study, uncompressed CT, DICOM file IDs - and the DICOMDIR is read back: the
patient, study, two series and three images, each image record naming its file.
"""
from pathlib import Path
import json
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dcmtk_build import ROOT, dcmtk_flags  # noqa: E402
import isix_modules  # noqa: E402

flags = dcmtk_flags('dcmnet', 'dcmjpeg', 'ijg8', 'ijg12', 'ijg16', 'dcmimage', 'dcmimgle')
ADAPTERS = ROOT / 'Horos/Sources/Adapters/DCMTK'

# What DicomDir.swift sees of Objective-C, as the app's bridging header gives it.
bridge = r'''
#import <Foundation/Foundation.h>
#import "HorosObjCException.h"
#import "DicomDir.h"
#import "IsiXDCMTKError.h"
#import "IsiXDCMTKDicomDir.h"
#ifdef __cplusplus
extern "C"
#endif
void _N2LogExceptionImpl(NSException * _Nonnull e, BOOL logStack, const char * _Nonnull pf);
'''

driver = r'''
#import <Foundation/Foundation.h>
#include <dcmtk/config/osconfig.h>
#include <dcmtk/dcmdata/dctk.h>
#include <dcmtk/dcmdata/dcdicdir.h>
#include <cstdio>
#import "bridge.h"

extern "C" void _N2LogExceptionImpl(NSException *e, BOOL logStack, const char *pf) { NSLog(@"%s: %@", pf, e); }

static void image(NSString *path, const char *series, int seriesNumber, int number) {
    DcmFileFormat file;
    DcmDataset *d = file.getDataset();
    char uid[100];
    d->putAndInsertString(DCM_SOPClassUID, UID_CTImageStorage);
    d->putAndInsertString(DCM_SOPInstanceUID, dcmGenerateUniqueIdentifier(uid, SITE_INSTANCE_UID_ROOT));
    d->putAndInsertString(DCM_StudyInstanceUID, "1.2.826.0.1.3680043.8.498.639.1");
    d->putAndInsertString(DCM_SeriesInstanceUID, series);
    d->putAndInsertString(DCM_PatientName, "SYNTHETIC^DICOMDIR");
    d->putAndInsertString(DCM_PatientID, "SYN-639");
    d->putAndInsertString(DCM_StudyDate, "20260917");
    d->putAndInsertString(DCM_StudyTime, "120000");
    d->putAndInsertString(DCM_StudyID, "639");
    d->putAndInsertString(DCM_Modality, "CT");
    d->putAndInsertUint16(DCM_Rows, 8);
    d->putAndInsertUint16(DCM_Columns, 8);
    d->putAndInsertUint16(DCM_SamplesPerPixel, 1);
    d->putAndInsertString(DCM_PhotometricInterpretation, "MONOCHROME2");
    d->putAndInsertUint16(DCM_BitsAllocated, 16);
    d->putAndInsertUint16(DCM_BitsStored, 12);
    d->putAndInsertUint16(DCM_HighBit, 11);
    d->putAndInsertUint16(DCM_PixelRepresentation, 0);
    char text[16];
    snprintf(text, sizeof text, "%d", seriesNumber);
    d->putAndInsertString(DCM_SeriesNumber, text);
    snprintf(text, sizeof text, "%d", number);
    d->putAndInsertString(DCM_InstanceNumber, text);
    Uint16 pixels[64];
    for (int i = 0; i < 64; i++) pixels[i] = (Uint16)(i * 50 + number);
    d->putAndInsertUint16Array(DCM_PixelData, pixels, 64);
    OFCondition written = file.saveFile(path.fileSystemRepresentation, EXS_LittleEndianExplicit);
    if (written.bad()) { fprintf(stderr, "could not write %s: %s\n", path.UTF8String, written.text()); exit(3); }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *folder = [NSString stringWithUTF8String:argv[1]];
        NSString *images = [folder stringByAppendingPathComponent:@"DICOM"];
        [[NSFileManager defaultManager] createDirectoryAtPath:images withIntermediateDirectories:YES attributes:nil error:NULL];
        image([images stringByAppendingPathComponent:@"IM000001"], "1.2.826.0.1.3680043.8.498.639.2", 1, 1);
        image([images stringByAppendingPathComponent:@"IM000002"], "1.2.826.0.1.3680043.8.498.639.2", 1, 2);
        image([images stringByAppendingPathComponent:@"IM000003"], "1.2.826.0.1.3680043.8.498.639.3", 2, 1);

        NSError *error = nil;
        BOOL created = [DicomDir createDicomDirAtDir:folder error:&error];
        NSString *index = [folder stringByAppendingPathComponent:@"DICOMDIR"];
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        result[@"created"] = @(created);
        result[@"error"] = error.localizedFailureReason ?: @"";
        NSMutableArray *records = [NSMutableArray array];
        if ([[NSFileManager defaultManager] fileExistsAtPath:index]) {
            DcmDicomDir directory(index.fileSystemRepresentation);
            DcmDirectoryRecord &root = directory.getRootRecord();
            for (unsigned long p = 0; p < root.cardSub(); p++) {
                DcmDirectoryRecord *patient = root.getSub(p);
                OFString name;
                patient->findAndGetOFString(DCM_PatientName, name);
                [records addObject:@{@"type": @"PATIENT", @"name": @(name.c_str())}];
                for (unsigned long s = 0; s < patient->cardSub(); s++) {
                    DcmDirectoryRecord *study = patient->getSub(s);
                    [records addObject:@{@"type": @"STUDY"}];
                    for (unsigned long r = 0; r < study->cardSub(); r++) {
                        DcmDirectoryRecord *series = study->getSub(r);
                        OFString number;
                        series->findAndGetOFString(DCM_SeriesNumber, number);
                        [records addObject:@{@"type": @"SERIES", @"number": @(number.c_str())}];
                        for (unsigned long i = 0; i < series->cardSub(); i++) {
                            DcmDirectoryRecord *item = series->getSub(i);
                            OFString file;
                            item->findAndGetOFStringArray(DCM_ReferencedFileID, file);
                            [records addObject:@{@"type": @(item->getRecordType() == ERT_Image ? "IMAGE" : "OTHER"),
                                                 @"file": @(file.c_str())}];
                        }
                    }
                }
            }
        }
        result[@"records"] = records;
        NSData *json = [NSJSONSerialization dataWithJSONObject:result options:0 error:NULL];
        fwrite(json.bytes, 1, json.length, stdout);
    }
    return 0;
}
'''

failures = []
with tempfile.TemporaryDirectory(prefix='horos-dicomdir-') as temporary:
    work = Path(temporary)
    stubs = work / 'stubs'
    stubs.mkdir()
    (stubs / 'bridge.h').write_text(bridge)
    (work / 'driver.mm').write_text(driver)
    binary = work / 'dicomdir'
    modules = work / 'modules'
    imaging = isix_modules.module_flags('IsiXImaging', modules)
    isix_modules.module_flags('IsiXDICOMFile', modules, extra=imaging)
    includes = ['-I' + str(stubs), '-I' + str(ADAPTERS), '-I' + str(ROOT / 'Horos/Sources')]
    hardened = '-D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_EXTENSIVE'
    steps = [
        ['xcrun', 'swiftc', '-parse-as-library', '-wmo', '-swift-version', '6', '-module-name', 'Horos',
         '-import-objc-header', str(stubs / 'bridge.h'), '-I', str(modules), *[a for i in includes for a in ('-Xcc', i)],
         '-c', str(ROOT / 'Horos/Sources/DicomDir.swift'), str(ROOT / 'Horos/Sources/ExportArchive.swift'),
         '-o', str(work / 'swift.o')],
        ['xcrun', 'clang', '-fobjc-arc', '-x', 'objective-c', *includes, '-c',
         str(ROOT / 'Horos/Sources/HorosObjCException.m'), '-o', str(work / 'exception.o')],
        ['xcrun', 'clang++', '-std=c++17', '-fobjc-arc', '-Wno-deprecated-declarations', hardened, *includes, *flags[:2],
         '-c', str(ADAPTERS / 'IsiXDCMTKDicomDir.mm'), '-o', str(work / 'adapter.o')],
        ['xcrun', 'clang++', '-std=c++17', '-fobjc-arc', hardened, *includes, *flags[:2],
         '-c', str(ADAPTERS / 'IsiXDCMTKError.mm'), '-o', str(work / 'error.o')],
        ['xcrun', 'clang++', '-std=c++17', '-fobjc-arc', hardened, *includes, *flags[:2],
         '-c', str(work / 'driver.mm'), '-o', str(work / 'driver.o')],
        ['xcrun', 'swiftc', *(str(work / name) for name in ('swift.o', 'exception.o', 'adapter.o', 'error.o', 'driver.o')),
         str(modules / 'libIsiXDICOMFile.a'), str(modules / 'libIsiXImaging.a'), *flags[2:], '-lc++',
         '-framework', 'Foundation', '-o', str(binary)],
    ]
    for step in steps:
        built = subprocess.run(step, capture_output=True, text=True)
        if built.returncode != 0:
            print('FAIL: DicomDir does not build against the DCMTK archives: ' + built.stderr[-2000:])
            raise SystemExit(1)
    folder = work / 'medium'
    folder.mkdir()
    run = subprocess.run([str(binary), str(folder)], capture_output=True, text=True, timeout=120)
    if run.returncode != 0:
        print(f'FAIL: creating the DICOMDIR stopped the process (exit {run.returncode}): {run.stderr[-800:]}')
        raise SystemExit(1)
    result = json.loads(run.stdout)
    records = result['records']
    kinds = [record['type'] for record in records]
    if not result['created']:
        failures.append(f"the DICOMDIR was not created: {result['error']}")
    if kinds.count('PATIENT') != 1 or kinds.count('STUDY') != 1 or kinds.count('SERIES') != 2 or kinds.count('IMAGE') != 3:
        failures.append(f'the DICOMDIR holds {kinds}, not one patient, one study, two series and three images')
    files = sorted(record['file'] for record in records if record['type'] == 'IMAGE')
    if files != ['DICOM\\IM000001', 'DICOM\\IM000002', 'DICOM\\IM000003']:
        failures.append(f'the image records name {files}')
    names = [record['name'] for record in records if record['type'] == 'PATIENT']
    if names != ['SYNTHETIC^DICOMDIR']:
        failures.append(f'the patient record is {names}')
    leftovers = [path.name for path in folder.iterdir() if path.name.startswith('.horos-zip-')]
    if leftovers:
        failures.append(f'staging folders left behind: {leftovers}')

if failures:
    print('\n'.join('FAIL: ' + failure for failure in failures))
    raise SystemExit(1)
print('DICOMDIR: created over a synthetic folder with the real DCMTK and read back - 1 patient, 1 study, 2 series, 3 images')
