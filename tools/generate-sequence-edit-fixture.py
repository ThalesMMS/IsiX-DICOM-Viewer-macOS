#!/usr/bin/env python3
"""A PET image whose radiopharmaceutical sequence carries two items.

Both items hold the same elements with different values, so an edit addressed to
the sequence rather than to one item is visible as either the wrong item
changing or nothing changing at all:

  (0054,0016) RadiopharmaceuticalInformationSequence
    item 0: (0018,1072) RadiopharmaceuticalStartTime 090000.000
            (0018,1074) RadionuclideTotalDose        370000000
    item 1: (0018,1072) RadiopharmaceuticalStartTime 143000.000
            (0018,1074) RadionuclideTotalDose        185000000

There is no (0018,1074) at the top level, so an edit that lands there is visible
too, as an element that did not exist before.

--charset-cases additionally writes separate Latin-1, UTF-8, absent-charset
and ISO 2022 series with Unicode filenames. Their first item inherits the root
charset; the second declares a local override, inherited by a child item.
PatientName appears at each depth so editing the wrong leaf is visible.
"""
import argparse
from copy import deepcopy
from pathlib import Path

import numpy
from pydicom.dataset import Dataset, FileMetaDataset
from pydicom.sequence import Sequence
from pydicom.uid import ExplicitVRLittleEndian, PositronEmissionTomographyImageStorage, generate_uid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('destination', type=Path, help='an empty directory for the file')
parser.add_argument('--rows', type=int, default=32)
parser.add_argument('--columns', type=int, default=32)
parser.add_argument('--charset-cases', action='store_true',
                    help='also write UTF-8/Latin-1, inherited/overridden items, absent charset and ISO 2022 cases')
arguments = parser.parse_args()

arguments.destination.mkdir(parents=True, exist_ok=True)
if any(arguments.destination.iterdir()):
    raise SystemExit('%s is not empty' % arguments.destination)

rows, columns = arguments.rows, arguments.columns
instance = generate_uid()

dataset = Dataset()
dataset.file_meta = FileMetaDataset()
dataset.file_meta.MediaStorageSOPClassUID = PositronEmissionTomographyImageStorage
dataset.file_meta.MediaStorageSOPInstanceUID = instance
dataset.file_meta.TransferSyntaxUID = ExplicitVRLittleEndian
dataset.file_meta.ImplementationClassUID = generate_uid()

dataset.SpecificCharacterSet = 'ISO_IR 100'
dataset.SOPClassUID = PositronEmissionTomographyImageStorage
dataset.SOPInstanceUID = instance
dataset.StudyInstanceUID = generate_uid()
dataset.SeriesInstanceUID = generate_uid()
dataset.PatientName = 'SEQUENCE^EDIT'
dataset.PatientID = 'SEQUENCE-121'
dataset.PatientBirthDate = '19700101'
dataset.PatientSex = 'O'
dataset.StudyDate = '20260101'
dataset.StudyTime = '120000'
dataset.SeriesDate = '20260101'
dataset.SeriesTime = '120000'
dataset.AcquisitionDate = '20260101'
dataset.AcquisitionTime = '120000'
dataset.ContentDate = '20260101'
dataset.ContentTime = '120000'
dataset.AccessionNumber = 'SEQ121'
dataset.StudyID = '121'
dataset.SeriesNumber = 1
dataset.InstanceNumber = 1
dataset.Modality = 'PT'
dataset.StudyDescription = 'Sequence edit'
dataset.SeriesDescription = 'two radiopharmaceutical items'
dataset.ImageType = ['ORIGINAL', 'PRIMARY']
dataset.ImagePositionPatient = [0.0, 0.0, 0.0]
dataset.ImageOrientationPatient = [1.0, 0.0, 0.0, 0.0, 1.0, 0.0]
dataset.PixelSpacing = [4.0, 4.0]
dataset.SliceThickness = 4.0
dataset.Units = 'BQML'
dataset.CorrectedImage = ['DECY', 'ATTN']
dataset.DecayCorrection = 'START'

first = Dataset()
first.RadiopharmaceuticalStartTime = '090000.000'
first.RadionuclideTotalDose = 370000000.0
first.RadiopharmaceuticalRoute = 'Intravenous'
second = Dataset()
second.RadiopharmaceuticalStartTime = '143000.000'
second.RadionuclideTotalDose = 185000000.0
second.RadiopharmaceuticalRoute = 'Intravenous'
dataset.RadiopharmaceuticalInformationSequence = Sequence([first, second])

dataset.Rows = rows
dataset.Columns = columns
dataset.SamplesPerPixel = 1
dataset.PhotometricInterpretation = 'MONOCHROME2'
dataset.BitsAllocated = 16
dataset.BitsStored = 16
dataset.HighBit = 15
dataset.PixelRepresentation = 0
dataset.RescaleIntercept = 0.0
dataset.RescaleSlope = 1.0
line = numpy.linspace(0, 1000, columns)
dataset.PixelData = numpy.tile(line, (rows, 1)).astype(numpy.uint16).tobytes()

path = arguments.destination / 'sequence-edit.dcm'
dataset.save_as(str(path), enforce_file_format=True)

print('%s' % path)
for index, item in enumerate(dataset.RadiopharmaceuticalInformationSequence):
    print('  item %d: (0018,1072) %s  (0018,1074) %s'
          % (index, item.RadiopharmaceuticalStartTime, item.RadionuclideTotalDose))
print('  top level (0018,1074): %s'
      % ('present' if 'RadionuclideTotalDose' in dataset else 'absent'))


if arguments.charset_cases:
    # Keep the normal dose fixture intact and add separate, importable series.
    # Names are ASCII initially so every destination is valid before editing.
    for name, charset in [('latin1', 'ISO_IR 100'), ('utf8', 'ISO_IR 192'),
                          ('absent', None), ('extensions', ['', 'ISO 2022 IR 100'])]:
        case = deepcopy(dataset)
        case.SOPInstanceUID = generate_uid()
        case.file_meta.MediaStorageSOPInstanceUID = case.SOPInstanceUID
        case.SeriesInstanceUID = generate_uid()
        case.SeriesDescription = 'Charset edit ' + name
        if charset is None:
            del case.SpecificCharacterSet
        else:
            case.SpecificCharacterSet = charset
        for index, item in enumerate(case.RadiopharmaceuticalInformationSequence):
            item.PatientName = 'ORIGINAL^ITEM'
            child = Dataset()
            child.PatientName = 'ORIGINAL^DEEP'
            item.RequestAttributesSequence = Sequence([child])
            if index == 1:
                item.SpecificCharacterSet = 'ISO_IR 192' if name == 'latin1' else 'ISO_IR 100'
        case_path = arguments.destination / ('charset-' + name + '-edição.dcm')
        case.save_as(str(case_path), enforce_file_format=True)
        print(case_path)
