#!/usr/bin/env python3
"""Exercise the production CLI selector/adapter with synthetic DICOMs.

Optional --install points to an already built DCMTK Install directory (read-only).
Uses the existing focused compilation convention, never a full app build.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import zlib
import struct
import shutil

from dcmtk_build import ROOT, dcmtk_flags

parser = argparse.ArgumentParser()
parser.add_argument('--install', type=Path)
args = parser.parse_args()
try:
    import pydicom
    from pydicom.dataset import Dataset, FileDataset, FileMetaDataset
    from pydicom.sequence import Sequence
    from pydicom.encaps import encapsulate
    from pydicom.uid import ExplicitVRLittleEndian, ImplicitVRLittleEndian, ExplicitVRBigEndian, JPEGBaseline8Bit, DeflatedExplicitVRLittleEndian
except ImportError:
    print('skipped: needs pydicom >= 3')
    raise SystemExit(2)

if args.install:
    install = args.install.resolve()
    required = [install / 'include/dcmtk/config/osconfig.h', *[install / ('lib/lib' + n + '.a') for n in ('dcmdata', 'oflog', 'ofstd', 'oficonv')]]
    if any(not p.is_file() for p in required):
        print('skipped: --install needs built DCMTK headers/archives')
        raise SystemExit(2)
    flags = ['-I' + str(install / 'include'), '-I' + str(ROOT / 'Horos/Sources'), *map(str, required[1:]), '-lz', '-liconv']
else:
    flags = dcmtk_flags()

category = (ROOT / 'Horos/Sources/XMLControllerDCMTKCategory.mm').read_text(encoding='latin1')
start = category.index('+ (int) modifyDicom:(NSArray*) params encoding:')
method = category[start:category.index('-(int) getGroupAndElementForName:', start)]
driver = r'''
#import <Foundation/Foundation.h>
#import "HorosDICOMCLI.h"
#include <dcmtk/config/osconfig.h>
#include <dcmtk/dcmdata/dctk.h>
#include <cstdio>
@interface XMLController : NSObject
+ (int)modifyDicom:(NSArray *)params encoding:(NSStringEncoding)encoding;
@end
@implementation XMLController
METHOD
@end
int main(int argc, char **argv) { @autoreleasepool {
    NSMutableArray *params = [NSMutableArray arrayWithObject:@"dcmodify"];
    for (int i = 2; i < argc; ++i) [params addObject:[NSString stringWithUTF8String:argv[i]]];
    NSStringEncoding encoding = !strcmp(argv[1], "latin1") ? NSISOLatin1StringEncoding : NSUTF8StringEncoding;
    if (!strcmp(argv[1], "bad-type")) [params addObject:@42];
    if (!strcmp(argv[1], "nul")) { const unichar chars[] = {'x', 0, 'y'}; [params addObject:[NSString stringWithCharacters:chars length:3]]; }
    const OFBool odd = dcmAcceptOddAttributeLength.get();
    const OFBool unknown = dcmEnableUnknownVRGeneration.get();
    int result = [XMLController modifyDicom:params encoding:encoding];
    if (odd != dcmAcceptOddAttributeLength.get() || unknown != dcmEnableUnknownVRGeneration.get()) return 120;
    printf("errors=%d\n", result);
    return 0;
} }
'''.replace('METHOD', method)

UID = '1.2.826.0.1.3680043.10.543.1'
CLASS = '1.2.840.10008.5.1.4.1.1.7'
checks = 0

def fixture(path, syntax=ExplicitVRLittleEndian, charset='ISO_IR 192'):
    meta = FileMetaDataset()
    meta.MediaStorageSOPClassUID, meta.MediaStorageSOPInstanceUID = CLASS, UID
    meta.TransferSyntaxUID = syntax
    d = FileDataset(str(path), {}, file_meta=meta, preamble=b'\0' * 128)
    d.SOPClassUID, d.SOPInstanceUID = CLASS, UID
    d.SpecificCharacterSet = charset
    d.PatientName, d.PatientID, d.StudyDescription = 'ORIGINAL^CLI', 'TOP', 'description'
    d.StudyInstanceUID, d.SeriesInstanceUID = UID + '.2', UID + '.3'
    items = []
    for n in range(2):
        item = Dataset()
        item.PatientID = 'ITEM' + str(n)
        item.ReferencedSOPInstanceUID = UID + '.' + str(n + 10)
        child = Dataset(); child.PatientID = 'DEEP' + str(n)
        item.ReferencedImageSequence = Sequence([child])
        items.append(item)
    d.ReferencedImageSequence = Sequence(items)
    d.add_new((0x0009, 0x0010), 'LO', 'HOROS CLI SYNTHETIC')
    d.add_new((0x0009, 0x1001), 'LO', 'private original')
    d.add_new((0x0009, 0x1002), 'UN', b'\x01\x02\x03\x04')
    d.add_new((0x0009, 0x1003), 'SQ', Sequence([items[0]]))
    d.Rows, d.Columns, d.SamplesPerPixel = 2, 2, 1
    d.PhotometricInterpretation = 'MONOCHROME2'
    d.BitsAllocated, d.BitsStored, d.HighBit, d.PixelRepresentation = 8, 8, 7, 0
    if syntax == JPEGBaseline8Bit:
        d.PixelData = encapsulate([b'\xff\xd8synthetic-frame\xff\xd9', b'\xff\xd8other-frame\xff\xd9'])
        d['PixelData'].is_undefined_length = True
    else:
        d.PixelData = bytes(range(4))
    pydicom.dcmwrite(path, d, enforce_file_format=True, little_endian=syntax != ExplicitVRBigEndian, implicit_vr=syntax == ImplicitVRLittleEndian)
    return d

with tempfile.TemporaryDirectory(prefix='horos-dicom-cli-') as directory:
    folder = Path(directory)
    # Compile the real public selector declaration in both plugin languages.
    shutil.copy(ROOT / 'Horos/Sources/XMLControllerDCMTKCategory.h', folder)
    (folder / 'XMLController.h').write_text('#import <Foundation/Foundation.h>\n@interface XMLController : NSObject @end\n')
    (folder / 'sdk.m').write_text('#import "XMLControllerDCMTKCategory.h"\nint invoke(NSArray *p) { return [XMLController modifyDicom:p encoding:NSUTF8StringEncoding]; }\n')
    for language in ('objective-c', 'objective-c++'):
        subprocess.run(['xcrun', 'clang', '-x', language, '-Werror', '-fsyntax-only', str(folder / 'sdk.m')], check=True)
    source = folder / 'driver.mm'; source.write_text(driver)
    binary = folder / 'driver'
    subprocess.run(['xcrun', 'clang++', '-std=c++17', '-fno-objc-arc', str(source), str(ROOT / 'Horos/Sources/HorosDICOMCLI.mm'), *flags, '-framework', 'Foundation', '-o', str(binary)], check=True)

    def call(*options, encoding='utf8', errors=0):
        global checks
        result = subprocess.run([str(binary), encoding, *map(str, options)], capture_output=True, text=True, timeout=30, env=dict(os.environ, TMPDIR=str(folder)))
        assert result.returncode == 0, (options, result.stdout, result.stderr)
        actual = int(result.stdout.split('errors=')[-1].strip())
        assert actual == errors, (options, actual, errors, result.stderr)
        checks += 1

    def fresh(name='sample.dcm', syntax=ExplicitVRLittleEndian, charset='ISO_IR 192'):
        path = folder / name
        fixture(path, syntax, charset)
        return path

    def preserved(path, *options, encoding='utf8', errors=1):
        before = path.read_bytes()
        call(*options, path, encoding=encoding, errors=errors)
        assert path.read_bytes() == before

    # The no-op and isolated changes preserve every untargeted dataset element,
    # sequence/private VR, transfer syntax and native/encapsulated pixel payload.
    for syntax in (ExplicitVRLittleEndian, ImplicitVRLittleEndian, ExplicitVRBigEndian, JPEGBaseline8Bit, DeflatedExplicitVRLittleEndian):
        for operations in ([], ['-m', 'PatientID=CHANGED']):
            path = fresh('roundtrip.dcm', syntax)
            before = pydicom.dcmread(path)
            original = path.read_bytes()
            call(*operations, path)
            after = pydicom.dcmread(path)
            assert after.file_meta.TransferSyntaxUID == syntax
            assert after.PixelData == before.PixelData
            assert Path(str(path) + '.bak').read_bytes() == original
            if operations: before.PatientID = 'CHANGED'
            assert after == before, (syntax, after, before)

    # Benign deferred-value controls for both source-backed and inflated input.
    for syntax in (ExplicitVRLittleEndian, DeflatedExplicitVRLittleEndian):
        path = fresh('large-valid.dcm', syntax)
        d = pydicom.dcmread(path); d.Rows = d.Columns = 512
        d.PixelData = b'\x2a' * (512 * 512)
        d.save_as(path, enforce_file_format=True)
        before = path.read_bytes()
        call('+fo', '-td', '-m', 'PatientID=LAZY', path)
        after = pydicom.dcmread(path)
        assert after.PatientID == 'LAZY' and after.PixelData == b'\x2a' * (512 * 512)
        assert after.file_meta.TransferSyntaxUID == syntax
        assert Path(str(path) + '.bak').read_bytes() == before
        assert not list(folder.glob('.horos-inflate-*'))

    path = fresh('çaminho.dcm')
    original = path.read_bytes()
    call('-m', '(0008,1140)[1].(0008,1140)[0].PatientID=TARGET', '-m', '(0009,1003)[0].PatientID=PRIVATE', '-m', '(0009,1001)=kept VR', '-i', 'SeriesDescription=FIRST', '-m', 'SeriesDescription=SECOND', '-e', 'StudyDescription', path)
    d = pydicom.dcmread(path)
    assert d.PatientID == 'TOP' and d.ReferencedImageSequence[0].PatientID == 'ITEM0'
    assert d.ReferencedImageSequence[1].ReferencedImageSequence[0].PatientID == 'TARGET'
    assert d[0x00091003][0].PatientID == 'PRIVATE'
    assert d[0x00091001].VR == 'LO' and d[0x00091001].value == 'kept VR'
    assert d[0x00091002].value == b'\1\2\3\4'
    assert d.SeriesDescription == 'SECOND' and 'StudyDescription' not in d
    assert Path(str(path) + '.bak').read_bytes() == original

    path = fresh()
    call('-ma', '(0008,1141)[99].PatientID=EVERYWHERE', '-ea', 'ReferencedSOPInstanceUID', path)
    d = pydicom.dcmread(path)
    assert all(e.value == 'EVERYWHERE' for e in d.iterall() if e.tag == 0x00100020)
    assert all(e.tag != 0x00081155 for e in d.iterall())
    call('-i', '(0009,1010)=discarded for unknown VR', '-i', '(7776,1234)=discarded', path)
    d = pydicom.dcmread(path)
    assert d[0x00091010].VR == 'UN' and d[0x00091010].value is None
    assert d[0x77761234].VR == 'UN' and d[0x77761234].value is None
    call('-m', 'PatientID=', path)
    assert pydicom.dcmread(path).PatientID == ''

    for encoding, charset in [('utf8', 'ISO_IR 192'), ('latin1', 'ISO_IR 100')]:
        path = fresh(charset=charset)
        call('-m', 'PatientName=Müller^José', path, encoding=encoding)
        assert str(pydicom.dcmread(path).PatientName) == 'Müller^José'
        assert pydicom.dcmread(path).SpecificCharacterSet == charset
    preserved(path, '-m', 'PatientName=漢字', encoding='latin1')

    path = fresh()
    call('-m', 'SOPInstanceUID=' + UID + '.99', path)
    d = pydicom.dcmread(path); assert d.file_meta.MediaStorageSOPInstanceUID == d.SOPInstanceUID == UID + '.99'
    call('-nmu', '-m', 'SOPInstanceUID=' + UID + '.88', path)
    d = pydicom.dcmread(path); assert d.file_meta.MediaStorageSOPInstanceUID == UID + '.99' and d.SOPInstanceUID == UID + '.88'
    old = d
    call('-nmu', '-gst', '-gse', '-gin', path)
    d = pydicom.dcmread(path)
    assert d.StudyInstanceUID != old.StudyInstanceUID and d.SeriesInstanceUID != old.SeriesInstanceUID
    assert d.SOPInstanceUID != old.SOPInstanceUID and d.SOPInstanceUID == d.file_meta.MediaStorageSOPInstanceUID

    for syntax, option in [(ExplicitVRLittleEndian, '+te'), (ImplicitVRLittleEndian, '+ti'), (ExplicitVRBigEndian, '+tb')]:
        path = fresh()
        call(option, '+g', '-le', '+p', '512', '16', path)
        assert len(path.read_bytes()) % 512 == 0
        d = pydicom.dcmread(path); assert d.file_meta.TransferSyntaxUID == syntax
        assert d.pixel_array.tolist() == [[0, 1], [2, 3]]
        assert d[0x00080000].VR == 'UL' and d.ReferencedImageSequence.is_undefined_length
        call('-g', '+le', '-p', path)
        assert 0x00080000 not in pydicom.dcmread(path)
    path = fresh()
    call('-F', path)
    assert path.read_bytes()[128:132] != b'DICM'
    call('-f', '-te', '-m', 'PatientID=DATASET', '+F', path)
    assert pydicom.dcmread(path).PatientID == 'DATASET'
    for syntax, option in [(ImplicitVRLittleEndian, '-ti'), (ExplicitVRBigEndian, '-tb')]:
        path = fresh(syntax=syntax)
        call('-F', path)
        preserved(path, '+fo')
        call('-f', option, path)
        assert pydicom.dcmread(path).file_meta.TransferSyntaxUID == syntax
    path = fresh(syntax=DeflatedExplicitVRLittleEndian)
    call('+bd', '-m', 'PatientID=DEFLATED', path)
    assert pydicom.dcmread(path).PatientID == 'DEFLATED'
    raw = path.read_bytes()
    begin = 144 + struct.unpack_from('<I', raw, 140)[0]
    path.write_bytes(raw[:begin] + zlib.compress(zlib.decompress(raw[begin:], -15)))
    call('+bz', '-m', 'PatientID=ZLIB', path)
    assert pydicom.dcmread(path).PatientID == 'ZLIB'
    path = fresh(syntax=JPEGBaseline8Bit)
    call('-F', path)
    assert pydicom.dcmread(path).file_meta.TransferSyntaxUID == JPEGBaseline8Bit
    preserved(path, '+ti')  # No silent decoding or transfer syntax fallback.

    path = fresh()
    for options in (['--unknown'], ['-i'], ['+p', '-1', '0'], ['-F', '-p='], ['-F', '+p', '1', '1'], ['-te'],
                    ['-m', 'NoSuchKeyword=x'], ['-m', '(0000,1000)=x'], ['-m', '(0001,1000)=x'], ['-m', '(10010,0010)=x'], ['-m', '(0010,10010)=x'],
                    ['-m', '(0008,1140)[2].PatientID=x'], ['-i', '(0008,1141)[0].PatientID=x'],
                    ['-m', '(0008,1140)[4294967296].PatientID=x'], ['-m', '(0008,1140)[*].PatientID=x'],
                    ['-m', 'SeriesDescription=missing'], ['-e', 'SeriesDescription']):
        preserved(path, *options)
    call('-v', '-d', '+f', '+fo', '+t=', '+g=', '-p=', path)
    call('--help'); call('--version'); call()
    call(encoding='bad-type', errors=1); call(encoding='nul', errors=1)
    call('-m', 'PatientID=X', errors=1)  # Missing filename.
    preserved(path, '-m', 'PatientID=X', '-m', 'MissingKeyword=Y')
    call('-ie', '-m', 'PatientID=X', '-m', 'MissingKeyword=Y', path, errors=1)
    assert pydicom.dcmread(path).PatientID == 'X'
    first, second = fresh('first.dcm'), fresh('second.dcm')
    before = second.read_bytes()
    call('-m', 'NoSuchKeyword=x', first, second, errors=2)
    assert second.read_bytes() == before
    # Parse switches restore global settings and don't contaminate another call.
    call('+ae', '-dc', '-u', '-td', '-g', path)
    call('+ao', '+dc', '+u', '-t=', path)

    path = fresh('backup-failure.dcm')
    backup = Path(str(path) + '.bak'); backup.mkdir(); (backup / 'keep').write_text('occupied')
    preserved(path, '-m', 'PatientID=X')
    assert (backup / 'keep').read_text() == 'occupied'
    path = fresh('truncated.dcm')
    path.write_bytes(path.read_bytes()[:-2]); preserved(path, '-m', 'PatientID=X')
    path = fresh('deferred.dcm')
    d = pydicom.dcmread(path); d.Rows = d.Columns = 1024; d.PixelData = b'\x2a' * (1024 * 1024)
    d.save_as(path, enforce_file_format=True)
    path.write_bytes(path.read_bytes()[:-500000]); preserved(path, '-m', 'PatientID=X')
    path = folder / 'invalid.dcm'; path.write_bytes(b'not DICOM'); preserved(path, '-m', 'PatientID=X')
    call(folder / 'nonexistent.dcm', errors=1)
    locked = folder / 'locked'; locked.mkdir()
    path = locked / 'sample.dcm'; fixture(path)
    locked.chmod(0o555)
    try:
        preserved(path, '-m', 'PatientID=X')
    finally:
        locked.chmod(0o755)
    assert not list(folder.rglob('*.horos-*'))
    assert not list(folder.glob('.horos-inflate-*'))
print(f'PASS: {checks} production CLI invocations; independent values/tree/VR/pixels/TS, backups and failure preservation')
