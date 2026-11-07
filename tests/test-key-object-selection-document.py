#!/usr/bin/env python3
"""The Key Object Selection Document of a study's key images is valid DICOM.

2D Viewer > Key Images > Create Key Object Selection Document writes the key
images of every series of the viewer's study in a new series of the study
(ViewerKeyObjectDocument): the content rules are IsiXDICOMFile's
KeyObjectDocumentContent, which its Swift tests check, and DCMTK writes the
document through the report adapter, IsiXDCMTKStructuredReport.

This compiles that adapter (IsiXDCMTKStructuredReportReader.mm, with the
HorosStructuredReportBridge.cpp it drives) against the DCMTK of the Debug build
and writes, with the calls ViewerKeyObjectDocument makes, the document of a
synthetic study: two CT images of one series, two frames of an enhanced MR
object of another, an image of a class DCMTK does not take as an image and a
frame list it cannot write, which must be refused without spoiling the
document. The file is then
- read back by the app's own reader (the one behind DicomImage's
  keyObjectType and referencedObjects), which must find the title "Of
  Interest" and the same images in the same order;
- checked with pydicom: SOP class and modality, the patient and study of the
  image it was made from with its character set, a new series in the same
  study, the root container (113000, DCM, "Of Interest") of template 2010 with
  continuity SEPARATE, IMAGE items without a concept name with their frames,
  the Current Requested Procedure Evidence grouped by series, and none of the
  SR document general module, which a key object selection does not have;
- and, when Binaries/dciodvfy is unpacked, validated by it without an error.

The menu item, the command object's action and its validation are checked in
the sources. Exits 2 when pydicom (local-validation/work/dicom-venv, or
HOROS_PYTHON) or the Debug build's DCMTK is missing. Synthetic data only,
written in a temporary folder.
"""
import os
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dcmtk_build import ROOT, dcmtk_flags  # noqa: E402

failures = []


def fail(message):
    failures.append(message)
    print('FAIL:', message)


def find_python():
    candidates = [os.environ.get('HOROS_PYTHON'), str(ROOT / 'local-validation/work/dicom-venv/bin/python')]
    if ROOT.parent.name == 'worktrees':
        candidates.append(str(ROOT.parent.parent.parent / 'local-validation/work/dicom-venv/bin/python'))
    candidates.append(sys.executable)
    for candidate in filter(None, candidates):
        if Path(candidate).exists() and subprocess.run([candidate, '-c', 'import pydicom'],
                                                       capture_output=True).returncode == 0:
            return candidate
    return None


python = find_python()
if python is None:
    print('skipped: needs a Python with pydicom (local-validation/work/dicom-venv or HOROS_PYTHON)')
    raise SystemExit(2)
flags = dcmtk_flags('dcmnet', 'dcmsr', 'dcmimage', 'dcmimgle')

# ------------------------------------------------------------- the wiring
menu = ET.parse(ROOT / 'Horos/Resources/en.lproj/MainMenu.xib').getroot()
key_images = next((item for item in menu.iter('menuItem') if item.get('title') == 'Key Images'), None)
entry = None if key_images is None else next(
    (item for item in key_images.iter('menuItem') if item.get('title') == 'Create Key Object Selection Document'), None)
action = None if entry is None else entry.find('connections/action')
if action is None or action.get('selector') != 'createKeyObjectSelectionDocument:' or action.get('target') != 'Vsc-cm-Obj':
    fail('2D Viewer > Key Images > Create Key Object Selection Document does not send '
         'createKeyObjectSelectionDocument: to the study commands object')
commands = (ROOT / 'Horos/Sources/ViewerStudyCommands.swift').read_text(encoding='utf-8')
if ('@objc(createKeyObjectSelectionDocument:)' not in commands
        or 'case #selector(createKeyObjectSelectionDocument(_:))' not in commands
        or 'ViewerKeyObjectDocument(viewer: $0).isPossible' not in commands):
    fail('the study commands object does not act on and validate Create Key Object Selection Document')
writer = (ROOT / 'Horos/Sources/ViewerKeyObjectDocument.swift').read_text(encoding='utf-8')
for needed in ('KeyObjectDocumentContent.keyImages(', 'KeyObjectDocumentContent.evidence(of: listed)',
               'KeyObjectDocumentContent.readsBack(', 'createNewDocument(.keyObjectSelection)',
               'readStudy(ofFileAtPath:', 'createNewSeries(inStudy:', 'setRootTemplate(identifier:',
               'addSelectedImage(sopClass:', 'addEvidence(study:', 'GeneratedSeriesImport.process.add(into: database)'):
    if needed not in writer:
        fail(f'ViewerKeyObjectDocument no longer calls {needed}, which this test reproduces')

# ------------------------------------------------------------- the document
STUDY = '1.2.826.0.1.3680043.8.498.71000'
CT_SERIES, MR_SERIES = STUDY + '.1', STUDY + '.2'
CT, ENHANCED_MR, BASIC_TEXT_SR = '1.2.840.10008.5.1.4.1.1.2', '1.2.840.10008.5.1.4.1.1.4.1', '1.2.840.10008.5.1.4.1.1.88.11'
CT1, CT2, MR1, SR1 = CT_SERIES + '.1', CT_SERIES + '.2', MR_SERIES + '.1', STUDY + '.9.1'

DRIVER = r'''
#import <Foundation/Foundation.h>
#import "IsiXDCMTKStructuredReportReader.h"
#include "HorosDCMTKCompatibility.h"
#include <dcmtk/config/osconfig.h>
#include <dcmtk/dcmdata/dctk.h>
#include <cstdio>

static int failures = 0;
static void check(bool condition, const char *what)
{
    if (!condition) { printf("FAIL: %s\n", what); ++failures; }
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc != 2) return 2;
        NSString *folder = [NSString stringWithUTF8String:argv[1]];
        NSString *image = [folder stringByAppendingPathComponent:@"image.dcm"];
        NSString *kos = [folder stringByAppendingPathComponent:@"kos.dcm"];

        // The image the document takes its patient and study from: a Latin-1 name.
        DcmFileFormat source;
        DcmDataset *dataset = source.getDataset();
        dataset->putAndInsertString(DCM_SpecificCharacterSet, "ISO_IR 100");
        dataset->putAndInsertString(DCM_SOPClassUID, "@@CT@@");
        dataset->putAndInsertString(DCM_SOPInstanceUID, "@@CT1@@");
        dataset->putAndInsertString(DCM_StudyInstanceUID, "@@STUDY@@");
        dataset->putAndInsertString(DCM_SeriesInstanceUID, "@@CT_SERIES@@");
        dataset->putAndInsertString(DCM_Modality, "CT");
        dataset->putAndInsertString(DCM_PatientName, "M\xfcller^Ana");
        dataset->putAndInsertString(DCM_PatientID, "KOS-LOCAL-1");
        dataset->putAndInsertString(DCM_PatientBirthDate, "19700101");
        dataset->putAndInsertString(DCM_PatientSex, "F");
        dataset->putAndInsertString(DCM_StudyDate, "20260101");
        dataset->putAndInsertString(DCM_StudyTime, "101010");
        dataset->putAndInsertString(DCM_AccessionNumber, "ACC-71000");
        dataset->putAndInsertString(DCM_StudyID, "42");
        dataset->putAndInsertString(DCM_ReferringPhysicianName, "Doe^John");
        dataset->putAndInsertString(DCM_StudyDescription, "Synthetic key images");
        check(source.saveFile(image.fileSystemRepresentation, EXS_LittleEndianExplicit).good(), "the image is written");

        // As ViewerKeyObjectDocument.write(_:studyInstanceUID:studyFile:seriesNumber:to:).
        NSError *error = nil;
        IsiXDCMTKStructuredReport *document = [IsiXDCMTKStructuredReport new];
        [document createNewDocument:IsiXDCMTKReportTypeKeyObjectSelection];
        check([document readStudyOfFileAtPath:image error:&error], "the study of the image is read");
        check([document createNewSeriesInStudy:@"@@STUDY@@" error:&error], "the study UID is taken");
        [document setValue:"Key Object Selection" ofField:IsiXDCMTKReportFieldSeriesDescription];
        [document setValue:"3" ofField:IsiXDCMTKReportFieldSeriesNumber];
        [document setValue:"1" ofField:IsiXDCMTKReportFieldInstanceNumber];
        [document setValue:"IsiX DICOM Viewer" ofField:IsiXDCMTKReportFieldManufacturer];
        [document setValue:"20261108" ofField:IsiXDCMTKReportFieldContentDate];
        [document setValue:"120000" ofField:IsiXDCMTKReportFieldContentTime];
        [document addRootContainerWithCode:@"113000" scheme:@"DCM" meaning:@"Of Interest"];
        check([document setRootTemplateIdentifier:@"2010" mappingResource:@"DCMR"], "the template is set");
        check([document addSelectedImageWithSOPClass:@"@@CT@@" instance:@"@@CT1@@" frames:nil], "CT1 is listed");
        check([document addSelectedImageWithSOPClass:@"@@CT@@" instance:@"@@CT2@@" frames:nil], "CT2 is listed");
        check(![document addSelectedImageWithSOPClass:@"@@BASIC_TEXT_SR@@" instance:@"@@SR1@@" frames:nil],
              "a report is refused as an image");
        check(![document addSelectedImageWithSOPClass:@"@@CT@@" instance:@"@@CT2@@" frames:@"two,four"],
              "a frame list DCMTK cannot read is refused");
        check([document addSelectedImageWithSOPClass:@"@@ENHANCED_MR@@" instance:@"@@MR1@@" frames:@"2,4"],
              "two frames of MR1 are listed");
        check([document addEvidenceInStudy:@"@@STUDY@@" series:@"@@CT_SERIES@@" SOPClass:@"@@CT@@" instance:@"@@CT1@@" error:&error], "evidence CT1");
        check([document addEvidenceInStudy:@"@@STUDY@@" series:@"@@CT_SERIES@@" SOPClass:@"@@CT@@" instance:@"@@CT2@@" error:&error], "evidence CT2");
        check([document addEvidenceInStudy:@"@@STUDY@@" series:@"@@MR_SERIES@@" SOPClass:@"@@ENHANCED_MR@@" instance:@"@@MR1@@" error:&error],
              "evidence MR1");
        check(![document addEvidenceInStudy:@"" series:@"@@MR_SERIES@@" SOPClass:@"@@ENHANCED_MR@@" instance:@"@@MR1@@" error:&error] && error,
              "evidence without a study is an error");
        error = nil;
        check([document prepareFileWithEncapsulatedDocument:nil seriesInstanceUID:nil error:&error], "the file is prepared");
        check([document writePreparedFileAtomicallyToPath:kos], "the file is written");

        // The app's own reader.
        NSString *title = [IsiXDCMTKStructuredReportReader titleMeaningOfReportAtPath:kos error:&error];
        check([title isEqualToString:@"Of Interest"], "the reader finds the title Of Interest");
        NSArray *images = [IsiXDCMTKStructuredReportReader referencedImageInstancesOfReportAtPath:kos];
        check([images isEqualToArray:@[@"@@CT1@@", @"@@CT2@@", @"@@MR1@@"]], "the reader finds CT1, CT2 and MR1 in order");
        if (![images isEqualToArray:@[@"@@CT1@@", @"@@CT2@@", @"@@MR1@@"]]) printf("read back: %s\n", images.description.UTF8String);
    }
    return failures ? 1 : 0;
}
'''
for name, value in (('STUDY', STUDY), ('CT_SERIES', CT_SERIES), ('MR_SERIES', MR_SERIES), ('CT', CT),
                    ('ENHANCED_MR', ENHANCED_MR), ('BASIC_TEXT_SR', BASIC_TEXT_SR), ('CT1', CT1), ('CT2', CT2),
                    ('MR1', MR1), ('SR1', SR1)):
    DRIVER = DRIVER.replace('@@' + name + '@@', value)

CHECK = r'''
import sys
import pydicom

STUDY, CT_SERIES, MR_SERIES, CT, ENHANCED_MR, CT1, CT2, MR1 = sys.argv[2:10]
ds = pydicom.dcmread(sys.argv[1])
problems = []


def expect(condition, what):
    if not condition:
        problems.append(what)


kos_class = '1.2.840.10008.5.1.4.1.1.88.59'
expect(ds.SOPClassUID == kos_class, 'SOP Class UID %s' % ds.SOPClassUID)
expect(ds.file_meta.MediaStorageSOPClassUID == kos_class, 'Media Storage SOP Class UID')
expect(ds.file_meta.MediaStorageSOPInstanceUID == ds.SOPInstanceUID, 'Media Storage SOP Instance UID')
expect(ds.Modality == 'KO', 'Modality %s' % ds.get('Modality'))
expect(ds.StudyInstanceUID == STUDY, 'the document is not in the study')
expect(ds.SeriesInstanceUID not in ('', STUDY, CT_SERIES, MR_SERIES), 'the document is not in a new series')
expect(ds.SOPInstanceUID not in ('', CT1, CT2, MR1), 'the document has no instance UID of its own')
expect(int(ds.SeriesNumber) == 3 and int(ds.InstanceNumber) == 1, 'series and instance numbers')
expect(ds.SeriesDescription == 'Key Object Selection', 'series description')
expect(ds.SpecificCharacterSet == 'ISO_IR 100', 'character set %r' % ds.get('SpecificCharacterSet'))
expect(str(ds.PatientName) == 'Müller^Ana', 'patient name %r' % str(ds.PatientName))
expect(ds.PatientID == 'KOS-LOCAL-1' and ds.PatientBirthDate == '19700101' and ds.PatientSex == 'F', 'patient')
expect(ds.StudyDate == '20260101' and ds.StudyTime == '101010' and ds.AccessionNumber == 'ACC-71000'
       and ds.StudyID == '42' and str(ds.ReferringPhysicianName) == 'Doe^John', 'study')
expect(ds.ContentDate == '20261108' and ds.ContentTime == '120000', 'content date and time')
expect('ReferencedPerformedProcedureStepSequence' in ds, 'Referenced Performed Procedure Step Sequence (type 2)')
for absent in ('CompletionFlag', 'VerificationFlag', 'PerformedProcedureCodeSequence'):
    expect(absent not in ds, absent + ' belongs to the SR document general module')

expect(ds.ValueType == 'CONTAINER' and ds.ContinuityOfContent == 'SEPARATE', 'root container')
title = ds.ConceptNameCodeSequence[0]
expect((title.CodeValue, title.CodingSchemeDesignator, title.CodeMeaning) == ('113000', 'DCM', 'Of Interest'),
       'document title')
template = ds.ContentTemplateSequence[0]
expect(template.TemplateIdentifier == '2010' and template.MappingResource == 'DCMR', 'template')

items = ds.ContentSequence
expect(len(items) == 3, '%d content items' % len(items))
listed = []
for item in items:
    expect(item.RelationshipType == 'CONTAINS' and item.ValueType == 'IMAGE', 'an item is not a contained image')
    expect('ConceptNameCodeSequence' not in item, 'an image item has a concept name')
    reference = item.ReferencedSOPSequence[0]
    frames = reference.get('ReferencedFrameNumber')
    frames = [] if frames is None else [int(frame) for frame in ([frames] if isinstance(frames, (int, str)) else frames)]
    listed.append((reference.ReferencedSOPClassUID, reference.ReferencedSOPInstanceUID, frames))
expect(listed == [(CT, CT1, []), (CT, CT2, []), (ENHANCED_MR, MR1, [2, 4])], 'images %r' % listed)

evidence = ds.CurrentRequestedProcedureEvidenceSequence
expect(len(evidence) == 1 and evidence[0].StudyInstanceUID == STUDY, 'evidence study')
series = {each.SeriesInstanceUID: [(sop.ReferencedSOPClassUID, sop.ReferencedSOPInstanceUID)
                                   for sop in each.ReferencedSOPSequence]
          for each in evidence[0].ReferencedSeriesSequence}
expect(series == {CT_SERIES: [(CT, CT1), (CT, CT2)], MR_SERIES: [(ENHANCED_MR, MR1)]}, 'evidence %r' % series)

for problem in problems:
    print('FAIL: pydicom: ' + problem)
sys.exit(1 if problems else 0)
'''

with tempfile.TemporaryDirectory(prefix='isix-key-object-selection-') as directory:
    work = Path(directory)
    adapters = ROOT / 'Horos/Sources/Adapters/DCMTK'
    (work / 'driver.mm').write_text(DRIVER)
    (work / 'files').mkdir()
    bridge = work / 'bridge.o'
    built = subprocess.run(['xcrun', 'clang++', '-std=gnu++17', '-w', '-I' + str(adapters), '-x', 'c++', '-c',
                            str(adapters / 'HorosStructuredReportBridge.cpp'), *flags[:2], '-o', str(bridge)],
                           capture_output=True, text=True, timeout=300)
    if built.returncode:
        print(built.stderr[-4000:])
        fail('HorosStructuredReportBridge.cpp does not compile against the build\'s DCMTK')
    else:
        driver = work / 'driver.o'
        built = subprocess.run(['xcrun', 'clang++', '-std=gnu++17', '-w', '-fobjc-arc', '-I' + str(adapters),
                                '-x', 'objective-c++', '-c', str(work / 'driver.mm'), *flags[:2], '-o', str(driver)],
                               capture_output=True, text=True, timeout=300)
        if built.returncode:
            print(built.stderr[-4000:])
            fail('the driver does not compile')
        else:
            # The adapter as the app compiles it, warnings as errors.
            linked = subprocess.run(['xcrun', 'clang++', '-std=gnu++17', '-fobjc-arc', '-Wall', '-Werror',
                                     '-Wno-unused-parameter', '-I' + str(adapters), '-x', 'objective-c++',
                                     str(adapters / 'IsiXDCMTKError.mm'), str(adapters / 'IsiXDCMTKStructuredReportReader.mm'),
                                     '-x', 'none', str(driver), str(bridge), *flags, '-lxml2', '-framework', 'Foundation',
                                     '-o', str(work / 'check')], capture_output=True, text=True, timeout=600)
            if linked.returncode:
                print(linked.stderr[-4000:])
                fail('the report adapter does not compile or link against the build\'s DCMTK')
            else:
                run = subprocess.run([str(work / 'check'), str(work / 'files')], capture_output=True, text=True,
                                     timeout=60, cwd=str(work / 'files'))
                print(run.stdout, end='')
                for line in run.stdout.splitlines():
                    if line.startswith('FAIL: '):
                        failures.append(line[len('FAIL: '):])
                if run.returncode and not failures:
                    fail('the driver exited with %d\n%s' % (run.returncode, run.stderr[-2000:]))
                kos = work / 'files/kos.dcm'
                if kos.is_file():
                    checked = subprocess.run([python, '-I', '-c', CHECK, str(kos), STUDY, CT_SERIES, MR_SERIES, CT,
                                              ENHANCED_MR, CT1, CT2, MR1], capture_output=True, text=True, timeout=120)
                    print(checked.stdout, end='')
                    for line in checked.stdout.splitlines():
                        if line.startswith('FAIL: '):
                            failures.append(line[len('FAIL: '):])
                    if checked.returncode and not any(line.startswith('FAIL: ') for line in checked.stdout.splitlines()):
                        fail('pydicom could not read the document:\n' + checked.stderr[-2000:])
                    # The validator the application ships, when it is unpacked here.
                    validators = [ROOT / 'Binaries/dciodvfy']
                    if ROOT.parent.name == 'worktrees':
                        validators.append(ROOT.parent.parent.parent / 'Binaries/dciodvfy')
                    validator = next((path for path in validators if path.is_file()), None)
                    if validator is None:
                        print('dciodvfy not present; the independent validator did not run')
                    else:
                        report = subprocess.run([str(validator), str(kos)], capture_output=True, text=True, timeout=60)
                        errors = [line for line in (report.stdout + report.stderr).splitlines() if line.startswith('Error')]
                        print('dciodvfy: %d error(s)' % len(errors))
                        for error in errors:
                            fail('dciodvfy: ' + error)
                else:
                    fail('no document was written')

if failures:
    sys.exit(1)
print('PASS: the key object selection document of a synthetic study reads back with the same key images in the '
      'app\'s reader and is a valid KOS for pydicom: title, template, images and frames, evidence by series, '
      'patient and study of its images, in a new series; the menu item reaches the study commands object')
