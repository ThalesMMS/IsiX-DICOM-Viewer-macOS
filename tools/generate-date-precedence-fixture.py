#!/usr/bin/env python3
"""Studies that disagree about which date they are, and how its time is written.

The importer takes the date a study is filed under from the first of
AcquisitionDate, ContentDate, SeriesDate, StudyDate that is present - and, when
none is, from a sentinel. Each study here carries a different subset, with
different values, so which rule was applied is readable from the result:

  all        AcquisitionDate 20240101, ContentDate 20230601, SeriesDate 20230202, StudyDate 20220303
  content    ContentDate 20230601, SeriesDate 20230202, StudyDate 20220303
  series     SeriesDate 20230202, StudyDate 20220303
  study      StudyDate 20220303
  none       no date at all

Four more carry the time as most CT, MR and PET equipment writes it, or
shorter, which the importer must read as DICOM TM:

  fraction   AcquisitionDate 20261004, AcquisitionTime 103015.123456
             (SeriesTime 1030, StudyTime 10 beside it)
  half       AcquisitionDate 20261001, AcquisitionTime 103015.5
  hhmm       AcquisitionDate 20261003, AcquisitionTime 1030
  hh         AcquisitionDate 20261002, AcquisitionTime 10

Synthetic throughout.
"""
import argparse
from pathlib import Path

import numpy
from pydicom.dataset import Dataset, FileMetaDataset
from pydicom.uid import CTImageStorage, ExplicitVRLittleEndian, generate_uid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('destination', type=Path)
arguments = parser.parse_args()
arguments.destination.mkdir(parents=True, exist_ok=True)

CASES = [
    ('all', {'AcquisitionDate': '20240101', 'AcquisitionTime': '101010',
             'ContentDate': '20230601', 'ContentTime': '111111',
             'SeriesDate': '20230202', 'SeriesTime': '121212',
             'StudyDate': '20220303', 'StudyTime': '131313'}),
    ('content', {'ContentDate': '20230601', 'ContentTime': '111111',
                 'SeriesDate': '20230202', 'SeriesTime': '121212',
                 'StudyDate': '20220303', 'StudyTime': '131313'}),
    ('series', {'SeriesDate': '20230202', 'SeriesTime': '121212',
                'StudyDate': '20220303', 'StudyTime': '131313'}),
    ('study', {'StudyDate': '20220303', 'StudyTime': '131313'}),
    ('none', {}),
    ('fraction', {'AcquisitionDate': '20261004', 'AcquisitionTime': '103015.123456',
                  'SeriesDate': '20261004', 'SeriesTime': '1030',
                  'StudyDate': '20261004', 'StudyTime': '10'}),
    ('half', {'AcquisitionDate': '20261001', 'AcquisitionTime': '103015.5'}),
    ('hhmm', {'AcquisitionDate': '20261003', 'AcquisitionTime': '1030'}),
    ('hh', {'AcquisitionDate': '20261002', 'AcquisitionTime': '10'}),
]

for name, dates in CASES:
    dataset = Dataset()
    dataset.file_meta = FileMetaDataset()
    dataset.file_meta.MediaStorageSOPClassUID = CTImageStorage
    dataset.file_meta.MediaStorageSOPInstanceUID = generate_uid()
    dataset.file_meta.TransferSyntaxUID = ExplicitVRLittleEndian
    dataset.SOPClassUID = CTImageStorage
    dataset.SOPInstanceUID = dataset.file_meta.MediaStorageSOPInstanceUID
    dataset.StudyInstanceUID = generate_uid()
    dataset.SeriesInstanceUID = generate_uid()
    dataset.PatientName = 'DATES^%s' % name.upper()
    dataset.PatientID = 'DATE-115-%s' % name
    dataset.StudyDescription = 'Date precedence %s' % name
    dataset.SeriesDescription = name
    dataset.Modality = 'CT'
    for tag, value in dates.items():
        setattr(dataset, tag, value)
    dataset.SeriesNumber = 1
    dataset.InstanceNumber = 1
    dataset.Rows = dataset.Columns = 16
    dataset.BitsAllocated = dataset.BitsStored = 16
    dataset.HighBit = 15
    dataset.PixelRepresentation = 0
    dataset.SamplesPerPixel = 1
    dataset.PhotometricInterpretation = 'MONOCHROME2'
    dataset.PixelData = numpy.zeros((16, 16), dtype=numpy.uint16).tobytes()
    dataset.save_as(arguments.destination / ('%s.dcm' % name), enforce_file_format=True)
    print('%-8s %s' % (name, ', '.join('%s=%s' % item for item in sorted(dates.items())) or 'no dates'))
