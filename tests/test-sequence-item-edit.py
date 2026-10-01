#!/usr/bin/env python3
"""Exercise the production DCMTK tree adapter on a disposable synthetic file.

Usage: test-sequence-item-edit.py DCMTK_INSTALL_DIR SEQUENCE_FIXTURE [--python PYTHON]
The fixture can be generated with tools/generate-sequence-edit-fixture.py.
"""
from pathlib import Path
import argparse
import os
import shutil
import subprocess
import sys
import tempfile

if len(sys.argv) < 3:
    print('skipped: needs DCMTK_INSTALL_DIR SEQUENCE_FIXTURE', file=sys.stderr)
    raise SystemExit(2)
root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('install', type=Path)
parser.add_argument('fixture', type=Path)
parser.add_argument('--python', default=os.environ.get('HOROS_TEST_PYTHON', sys.executable))
args = parser.parse_args()
install = args.install.resolve()
required = [install / 'include/dcmtk/config/osconfig.h',
            *[install / ('lib/lib%s.a' % name) for name in ('dcmdata', 'oflog', 'ofstd', 'oficonv')]]
if any(not path.is_file() for path in required) or not args.fixture.is_file():
    print('skipped: needs built DCMTK archives and a sequence fixture', file=sys.stderr)
    raise SystemExit(2)
if subprocess.run([args.python, '-c', 'import pydicom'], capture_output=True).returncode:
    print('skipped: independent Python needs pydicom', file=sys.stderr)
    raise SystemExit(2)

program = r'''
#include "HorosDCMTKTagEditing.h"
#include <cstdio>
static int failures;
#define check(...) do { if (!(__VA_ARGS__)) { std::fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #__VA_ARGS__); ++failures; } } while(0)
int main(int argc, char **argv) {
    DcmFileFormat file;
    check(file.loadFile(argv[1]).good());
    DcmDataset &root = *file.getDataset();
    std::string reason;
    std::vector<DcmItem *> ancestors;
    std::vector<HorosTagPathStep> dosePath = {{0x0054, 0x0016, 0}};
    DcmItem *item = HorosDICOMEditingResolveItem(root, dosePath, ancestors, &reason);
    check(item && ancestors.size() == 2);
    check(item && HorosDICOMEditingWriteElement(*item, DcmTagKey(0x0018, 0x1074), false, "123456789", true, &reason));
    dosePath[0].item = 7;
    check(!HorosDICOMEditingResolveItem(root, dosePath, ancestors, &reason));
    check(reason.find("item") != std::string::npos);
    dosePath[0].item = 0; dosePath[0].element = 0x0017;
    check(!HorosDICOMEditingResolveItem(root, dosePath, ancestors, &reason));
    check(reason.find("sequence") != std::string::npos);
    dosePath[0] = {0x0010, 0x0010, 0};
    check(!HorosDICOMEditingResolveItem(root, dosePath, ancestors, &reason));
    check(reason.find("not a sequence") != std::string::npos);
    dosePath[0] = {0x0054, 0x0016, 1};
    item = HorosDICOMEditingResolveItem(root, dosePath, ancestors, &reason);
    check(item);
    check(item && !HorosDICOMEditingWriteElement(*item, DcmTagKey(0x0018, 0x9999), false, "1", true, &reason));
    check(item && !HorosDICOMEditingWriteElement(*item, DcmTagKey(0x0018, 0x9999), true, "", true, &reason));
    check(item && !HorosDICOMEditingWriteElement(*item, DcmTagKey(0x0009, 0x1002), false, "", true, &reason));
    std::vector<HorosTagPathStep> deep = {{0x0009, 0x1003, 1}, {0x0040, 0x0555, 0}};
    item = HorosDICOMEditingResolveItem(root, deep, ancestors, &reason);
    check(item && ancestors.size() == 3);
    check(item && HorosDICOMEditingWriteElement(*item, DcmTagKey(0x0010, 0x0010), false, "nested changed", true, &reason));
    check(item && HorosDICOMEditingWriteElement(*item, DcmTagKey(0x0009, 0x1001), false, "HELLO", true, &reason));
    check(item && HorosDICOMEditingWriteElement(*item, DcmTagKey(0x0040, 0x9999), false, "RAW", true, &reason));
    // Empty nested SQ is refused; empty top-level SQ clears items and keeps SQ.
    std::vector<HorosTagPathStep> privatePath = {{0x0009, 0x1003, 0}};
    item = HorosDICOMEditingResolveItem(root, privatePath, ancestors, &reason);
    check(item && !HorosDICOMEditingWriteElement(*item, DcmTagKey(0x0040, 0x0555), false, "", true, &reason));
    check(HorosDICOMEditingWriteElement(root, DcmTagKey(0x0040, 0x0555), false, "", false, &reason));
    // Empty known public binary/SQ can be inserted at the top level; a
    // nested binary remains refused. Remove them to leave the output oracle
    // limited to the persistent edits above.
    check(HorosDICOMEditingWriteElement(root, DcmTagKey(0x0028, 0x0006), false, "", false, &reason));
    DcmElement *emptyBinary = nullptr;
    check(root.findAndGetElement(DcmTagKey(0x0028, 0x0006), emptyBinary).good());
    check(emptyBinary && emptyBinary->getVR() == EVR_US && emptyBinary->getLength() == 0);
    check(HorosDICOMEditingWriteElement(root, DcmTagKey(0x0028, 0x0006), true, "", false, &reason));
    check(HorosDICOMEditingWriteElement(root, DcmTagKey(0x0028, 0x0006), true, "", false, &reason));
    check(HorosDICOMEditingWriteElement(root, DcmTagKey(0x0008, 0x2112), false, "", false, &reason));
    DcmSequenceOfItems *emptySequence = nullptr;
    check(root.findAndGetSequence(DcmTagKey(0x0008, 0x2112), emptySequence).good());
    check(emptySequence && emptySequence->card() == 0);
    check(HorosDICOMEditingWriteElement(root, DcmTagKey(0x0008, 0x2112), true, "", false, &reason));
    OFString originalUID, metaUID;
    check(root.findAndGetOFStringArray(DCM_SOPInstanceUID, originalUID).good());
    check(HorosDICOMEditingWriteElement(root, DCM_SOPInstanceUID, false, "1.2.826.0.1.3680043.8.498.108400", false, &reason));
    check(HorosDICOMEditingSynchronizeUID(file, DCM_SOPInstanceUID, &reason));
    check(file.getMetaInfo()->findAndGetOFStringArray(DCM_MediaStorageSOPInstanceUID, metaUID).good());
    check(metaUID == "1.2.826.0.1.3680043.8.498.108400");
    check(HorosDICOMEditingWriteElement(root, DCM_SOPInstanceUID, false, "", false, &reason));
    check(HorosDICOMEditingSynchronizeUID(file, DCM_SOPInstanceUID, &reason));
    check(file.getMetaInfo()->findAndGetOFStringArray(DCM_MediaStorageSOPInstanceUID, metaUID).good() && metaUID.empty());
    check(HorosDICOMEditingWriteElement(root, DCM_SOPInstanceUID, true, "", false, &reason));
    check(HorosDICOMEditingSynchronizeUID(file, DCM_SOPInstanceUID, &reason));
    check(!file.getMetaInfo()->tagExists(DCM_MediaStorageSOPInstanceUID));
    check(HorosDICOMEditingWriteElement(root, DCM_SOPInstanceUID, false, originalUID.c_str(), false, &reason));
    check(HorosDICOMEditingSynchronizeUID(file, DCM_SOPInstanceUID, &reason));
    check(file.loadAllDataIntoMemory().good());
    check(file.saveFile(argv[1], root.getOriginalXfer(), EET_UndefinedLength, EGL_recalcGL,
                        EPD_noChange, 0, 0, EWM_dontUpdateMeta).good());
    return failures ? 1 : 0;
}
'''

prepare = r'''
import pydicom, sys
from pydicom.dataset import Dataset
from pydicom.sequence import Sequence
source, output = sys.argv[1:]
ds = pydicom.dcmread(source)
ds.RadionuclideTotalDose = 777
# Explicit private SQ with no dictionary entry; two public SQ levels below it.
ds.add_new((0x0009, 0x0010), 'LO', 'HOROS TEST CREATOR')
outer = []
for n in range(2):
    parent = Dataset()
    parent.add_new((0x0009, 0x0010), 'LO', 'ITEM CREATOR')
    children = []
    for j in range(2):
        leaf = Dataset()
        leaf.PatientName = 'child-%d-%d' % (n, j)
        leaf.add_new((0x0009, 0x0010), 'LO', 'LEAF CREATOR')
        leaf.add_new((0x0009, 0x1001), 'UN', b'\x00\\\xffQ')
        leaf.add_new((0x0040, 0x9999), 'UN', b'opaque')
        children.append(leaf)
    parent.AcquisitionContextSequence = Sequence(children)
    outer.append(parent)
ds.add_new((0x0009, 0x1003), 'SQ', Sequence(outer))
ds.AcquisitionContextSequence = Sequence([Dataset()])
ds.RadiopharmaceuticalInformationSequence[1].add_new((0x0009, 0x1002), 'OB', b'\x00\\\xffQ')
ds.save_as(output, enforce_file_format=True)
'''
verify = r'''
import pydicom, sys
before, after = map(pydicom.dcmread, sys.argv[1:])
# Remove only the addressed leaves from both trees, then compare everything else.
for ds in (before, after):
    assert float(ds.RadionuclideTotalDose) == 777
    assert len(ds.RadiopharmaceuticalInformationSequence) == 2
    assert ds[(0x0009,0x1003)].VR == 'SQ'
    assert len(ds[(0x0009,0x1003)].value) == 2
assert float(after.RadiopharmaceuticalInformationSequence[0].RadionuclideTotalDose) == 123456789
leaf = after[(0x0009,0x1003)].value[1].AcquisitionContextSequence[0]
assert str(leaf.PatientName) == 'nested changed'
assert leaf[(0x0009,0x1001)].VR == 'UN' and leaf[(0x0009,0x1001)].value == b'HELLO '
assert leaf[(0x0040,0x9999)].VR == 'UN' and leaf[(0x0040,0x9999)].value == b'RAW '
assert after[(0x0040,0x0555)].VR == 'SQ' and len(after.AcquisitionContextSequence) == 0
assert before.file_meta.TransferSyntaxUID == after.file_meta.TransferSyntaxUID
assert before.PixelData == after.PixelData
for ds in (before, after):
    del ds.RadiopharmaceuticalInformationSequence[0].RadionuclideTotalDose
    leaf = ds[(0x0009,0x1003)].value[1].AcquisitionContextSequence[0]
    del leaf.PatientName
    del leaf[(0x0009,0x1001)]
    del leaf[(0x0040,0x9999)]
    del ds.AcquisitionContextSequence
assert before == after, 'a non-target element, VR, VM, creator or sequence sibling changed'
print('PASS: zero-based items, two levels/private SQ, raw UN and top SQ empty; siblings, absent leaves, creators and pixels preserved')
'''
original = args.fixture.read_bytes()
with tempfile.TemporaryDirectory(prefix='horos-sequence-edit-') as folder:
    folder = Path(folder)
    before, work = folder / 'before.dcm', folder / 'working.dcm'
    subprocess.run([args.python, '-c', prepare, str(args.fixture), str(before)], check=True)
    shutil.copy(before, work)
    source = folder / 'test.cc'
    source.write_text(program)
    binary = folder / 'test'
    subprocess.run(['xcrun', 'clang++', '-std=c++17', '-I' + str(install / 'include'),
                    '-I' + str(root / 'Horos/Sources'), str(source), *map(str, required[1:]),
                    '-lz', '-liconv', '-o', str(binary)], check=True)
    env = dict(os.environ, DCMDICTPATH=str(root / 'DCMTK/dcmdata/data/dicom.dic'))
    subprocess.run([str(binary), str(work)], check=True, env=env)
    subprocess.run([args.python, '-c', verify, str(before), str(work)], check=True)
assert original == args.fixture.read_bytes(), 'original fixture was modified'
