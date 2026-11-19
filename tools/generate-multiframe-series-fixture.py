#!/usr/bin/env python3
"""Multiframe files that share one Series Instance UID, and the series they make.

Five sets, each its own study of its own synthetic patient, under <destination>:

  A  one-volume-per-file   4 Enhanced MR files of 12 frames (12 slice positions,
                           the same in every file), ONE StudyInstanceUID and ONE
                           SeriesInstanceUID, InstanceNumber 1..4, as an
                           acquisition in time stores one volume per file. File
                           t holds value 1000*t + 10*slice in frame `slice`, so
                           the time point and the slice of any frame can be read
                           off a pixel, and its ContentTime is 2 s after the
                           file before it.
  B  single-multiframe     1 Enhanced MR file of 12 frames, alone in its series.
  C  us-loops              2 Ultrasound Multi-frame files with the same
                           SeriesInstanceUID, different Rows/Columns and frame
                           counts (48x64 x 5 frames, 40x56 x 8 frames), no positions.
  D  classic-series        12 classic single-frame MR files, one series.
  E  legacy-converted      3 series of one study, of 2 files of 12 frames each,
                           made as the files of A are: Legacy Converted
                           Enhanced CT (series 1), MR (series 2) and PET
                           (series 3). File t of series s holds value
                           1000*t + 100*s + 10*slice in frame `slice`.

Imported, A is one series of 48 images (4 files), B one series of 12, C two
series (one per loop), D one series of 12 and E three series of 24 images
(2 files) each.

UIDs are derived from fixed names, so the files are the same at every run.

    python3 tools/generate-multiframe-series-fixture.py <destination>

Needs pydicom and numpy. The destination must be empty or absent, and outside
the repository. Writes manifest.json beside the sets: per set, what the files
say (study, series, SOP instances, frames) and the series the import makes.
"""
import argparse
import hashlib
import json
from pathlib import Path

import numpy
from pydicom.dataset import Dataset, FileMetaDataset
from pydicom.uid import ExplicitVRLittleEndian

ENHANCED_MR = '1.2.840.10008.5.1.4.1.1.4.1'
CLASSIC_MR = '1.2.840.10008.5.1.4.1.1.4'
US_MULTIFRAME = '1.2.840.10008.5.1.4.1.1.3.1'
# Legacy Converted Enhanced CT, MR and PET, with the modality of each.
LEGACY_CONVERTED = [('1.2.840.10008.5.1.4.1.1.2.2', 'CT'), ('1.2.840.10008.5.1.4.1.1.4.4', 'MR'),
                    ('1.2.840.10008.5.1.4.1.1.128.1', 'PT')]
ROOT_UID = '1.2.826.0.1.3680043.8.498.4104'
REPOSITORY = Path(__file__).resolve().parents[1]
ROWS = COLUMNS = 64
SLICES = 12
SPACING = 3.0


def uid(name: str) -> str:
    """A UID that depends on the name alone."""
    digits = int(hashlib.sha256(name.encode()).hexdigest()[:24], 16)
    return '%s.%d' % (ROOT_UID, digits)


def base(sop_class: str, instance: str, study: str, series: str, patient: str, modality: str,
         series_number: int, instance_number: int, description: str) -> Dataset:
    dataset = Dataset()
    dataset.file_meta = FileMetaDataset()
    dataset.file_meta.MediaStorageSOPClassUID = sop_class
    dataset.file_meta.MediaStorageSOPInstanceUID = instance
    dataset.file_meta.TransferSyntaxUID = ExplicitVRLittleEndian
    dataset.file_meta.ImplementationClassUID = ROOT_UID + '.0'
    dataset.SpecificCharacterSet = 'ISO_IR 100'
    dataset.SOPClassUID = sop_class
    dataset.SOPInstanceUID = instance
    dataset.StudyInstanceUID = study
    dataset.SeriesInstanceUID = series
    dataset.PatientName = 'SYNTHETIC^%s' % patient
    dataset.PatientID = 'MFSERIES-%s' % patient
    dataset.PatientBirthDate = '19700101'
    dataset.PatientSex = 'O'
    dataset.StudyDate = '20260101'
    dataset.StudyTime = '120000'
    dataset.ContentDate = '20260101'
    dataset.ContentTime = '120000'
    dataset.AccessionNumber = 'MFS%s' % patient[-1]
    dataset.StudyID = '1'
    dataset.SeriesNumber = series_number
    dataset.InstanceNumber = instance_number
    dataset.Modality = modality
    dataset.Manufacturer = 'SYNTHETIC'
    dataset.StudyDescription = 'multiframe series: %s' % description
    dataset.SeriesDescription = description
    dataset.SamplesPerPixel = 1
    dataset.PhotometricInterpretation = 'MONOCHROME2'
    dataset.BitsAllocated = 16
    dataset.BitsStored = 16
    dataset.HighBit = 15
    dataset.PixelRepresentation = 0
    return dataset


def enhanced_mr(path: Path, study: str, series: str, patient: str, instance_number: int, offset: int,
                description: str, name: str, temporal_positions: int, sop_class: str = ENHANCED_MR,
                modality: str = 'MR', series_number: int = 1) -> dict:
    """A volume of 12 frames placed by its functional groups: Enhanced MR, or another class that states them alike."""
    instance = uid(name)
    dataset = base(sop_class, instance, study, series, patient, modality, series_number, instance_number, description)
    dataset.ImageType = ['ORIGINAL', 'PRIMARY', 'M', 'NONE']
    dataset.Rows = ROWS
    dataset.Columns = COLUMNS
    dataset.NumberOfFrames = SLICES
    dataset.AcquisitionNumber = instance_number
    dataset.ContentTime = '1200%02d' % (2 * (instance_number - 1))
    dataset.DimensionOrganizationSequence = [Dataset()]
    dataset.DimensionOrganizationSequence[0].DimensionOrganizationUID = uid('dimension ' + series)

    shared = Dataset()
    transformation = Dataset()
    transformation.RescaleIntercept = 0.0
    transformation.RescaleSlope = 1.0
    transformation.RescaleType = 'US'
    shared.PixelValueTransformationSequence = [transformation]
    window = Dataset()
    window.WindowCenter = 2000.0
    window.WindowWidth = 5000.0
    shared.FrameVOILUTSequence = [window]
    dataset.SharedFunctionalGroupsSequence = [shared]

    per_frame, frames = [], []
    for slice_index in range(SLICES):
        item = Dataset()
        content = Dataset()
        content.StackID = '1'
        content.InStackPositionNumber = slice_index + 1
        content.TemporalPositionIndex = instance_number
        content.FrameAcquisitionNumber = instance_number
        content.DimensionIndexValues = [1, slice_index + 1, instance_number]
        item.FrameContentSequence = [content]
        position = Dataset()
        position.ImagePositionPatient = [-100.0, -100.0, slice_index * SPACING]
        item.PlanePositionSequence = [position]
        orientation = Dataset()
        orientation.ImageOrientationPatient = [1.0, 0.0, 0.0, 0.0, 1.0, 0.0]
        item.PlaneOrientationSequence = [orientation]
        measures = Dataset()
        measures.PixelSpacing = [3.0, 3.0]
        measures.SliceThickness = SPACING
        measures.SpacingBetweenSlices = SPACING
        item.PixelMeasuresSequence = [measures]
        per_frame.append(item)
        frame = numpy.full((ROWS, COLUMNS), offset + 10 * slice_index, dtype=numpy.uint16)
        # A bright square that moves with the slice, so a slice is recognisable by eye.
        frame[8 + 2 * slice_index:16 + 2 * slice_index, 8:16] += 500
        frames.append(frame)
    dataset.NumberOfTemporalPositions = temporal_positions
    dataset.PerFrameFunctionalGroupsSequence = per_frame
    dataset.PixelData = numpy.stack(frames).tobytes()
    path.parent.mkdir(parents=True, exist_ok=True)
    dataset.save_as(str(path), enforce_file_format=True)
    return {'path': path.name, 'sop': instance, 'frames': SLICES, 'rows': ROWS, 'columns': COLUMNS,
            'instance_number': instance_number, 'offset': offset}


def ultrasound(path: Path, study: str, series: str, instance_number: int, rows: int, columns: int,
               frames: int, name: str) -> dict:
    instance = uid(name)
    dataset = base(US_MULTIFRAME, instance, study, series, 'C', 'US', 1, instance_number, 'US loops of two sizes')
    dataset.ImageType = ['ORIGINAL', 'PRIMARY', 'NONE']
    dataset.Rows = rows
    dataset.Columns = columns
    dataset.NumberOfFrames = frames
    dataset.FrameTime = '40'
    dataset.FrameIncrementPointer = 0x00181063
    dataset.CineRate = 25
    dataset.BitsAllocated = 8
    dataset.BitsStored = 8
    dataset.HighBit = 7
    pixels = numpy.zeros((frames, rows, columns), dtype=numpy.uint8)
    for frame in range(frames):
        pixels[frame] = 20 * instance_number + 5 * frame
        pixels[frame, 4:12, 4 + 3 * frame:12 + 3 * frame] = 250
    dataset.PixelData = pixels.tobytes()
    path.parent.mkdir(parents=True, exist_ok=True)
    dataset.save_as(str(path), enforce_file_format=True)
    return {'path': path.name, 'sop': instance, 'frames': frames, 'rows': rows, 'columns': columns,
            'instance_number': instance_number}


def classic_mr(path: Path, study: str, series: str, slice_index: int) -> dict:
    instance = uid('D classic %d' % slice_index)
    dataset = base(CLASSIC_MR, instance, study, series, 'D', 'MR', 1, slice_index + 1, 'classic single-frame series')
    dataset.ImageType = ['ORIGINAL', 'PRIMARY', 'M', 'NONE']
    dataset.Rows = ROWS
    dataset.Columns = COLUMNS
    dataset.PixelSpacing = [3.0, 3.0]
    dataset.SliceThickness = SPACING
    dataset.SpacingBetweenSlices = SPACING
    dataset.ImagePositionPatient = [-100.0, -100.0, slice_index * SPACING]
    dataset.ImageOrientationPatient = [1.0, 0.0, 0.0, 0.0, 1.0, 0.0]
    dataset.SliceLocation = slice_index * SPACING
    dataset.WindowCenter = 2000.0
    dataset.WindowWidth = 5000.0
    frame = numpy.full((ROWS, COLUMNS), 10 * slice_index, dtype=numpy.uint16)
    frame[8 + 2 * slice_index:16 + 2 * slice_index, 8:16] += 500
    dataset.PixelData = frame.tobytes()
    path.parent.mkdir(parents=True, exist_ok=True)
    dataset.save_as(str(path), enforce_file_format=True)
    return {'path': path.name, 'sop': instance, 'frames': 1, 'rows': ROWS, 'columns': COLUMNS,
            'instance_number': slice_index + 1}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--volumes', type=int, default=4, help='files of set A (time points)')
    arguments = parser.parse_args()
    if arguments.volumes < 1:
        parser.error('at least one volume')
    destination = arguments.destination.resolve()
    if destination == REPOSITORY or REPOSITORY in destination.parents:
        raise SystemExit('the destination must be outside the repository')
    if destination.exists() and any(destination.iterdir()):
        raise SystemExit('%s is not empty' % destination)
    destination.mkdir(parents=True, exist_ok=True)

    manifest = {}

    study, series = uid('A study'), uid('A series')
    files = [enhanced_mr(destination / 'A-one-volume-per-file' / ('volume-%02d.dcm' % t), study, series, 'A', t,
                         1000 * t, 'one volume per file', 'A volume %d' % t, arguments.volumes)
             for t in range(1, arguments.volumes + 1)]
    manifest['A-one-volume-per-file'] = {'study': study, 'series': [series], 'files': files,
                                         'expected_series': 1, 'frames_total': SLICES * arguments.volumes}

    study, series = uid('B study'), uid('B series')
    files = [enhanced_mr(destination / 'B-single-multiframe' / 'volume.dcm', study, series, 'B', 1, 1000,
                         'one multi-frame file', 'B volume', 1)]
    manifest['B-single-multiframe'] = {'study': study, 'series': [series], 'files': files,
                                       'expected_series': 1, 'frames_total': SLICES}

    study, series = uid('C study'), uid('C series')
    files = [ultrasound(destination / 'C-us-loops' / 'loop-1.dcm', study, series, 1, 48, 64, 5, 'C loop 1'),
             ultrasound(destination / 'C-us-loops' / 'loop-2.dcm', study, series, 2, 40, 56, 8, 'C loop 2')]
    manifest['C-us-loops'] = {'study': study, 'series': [series], 'files': files,
                              'expected_series': 2, 'frames_total': 13}

    study, series = uid('D study'), uid('D series')
    files = [classic_mr(destination / 'D-classic-series' / ('slice-%02d.dcm' % (k + 1)), study, series, k)
             for k in range(SLICES)]
    manifest['D-classic-series'] = {'study': study, 'series': [series], 'files': files,
                                    'expected_series': 1, 'frames_total': SLICES}

    study, series_uids, files = uid('E study'), [], []
    for number, (sop_class, modality) in enumerate(LEGACY_CONVERTED, start=1):
        series = uid('E series %s' % modality)
        series_uids.append(series)
        for t in (1, 2):
            entry = enhanced_mr(destination / 'E-legacy-converted' / ('%s-volume-%02d.dcm' % (modality.lower(), t)), study, series,
                                'E', t, 1000 * t + 100 * number, 'legacy converted enhanced %s' % modality,
                                'E %s volume %d' % (modality, t), 2, sop_class=sop_class, modality=modality,
                                series_number=number)
            files.append(dict(entry, series=series, sop_class=sop_class))
    manifest['E-legacy-converted'] = {'study': study, 'series': series_uids, 'files': files,
                                      'expected_series': 3, 'frames_total': 2 * SLICES * len(LEGACY_CONVERTED)}

    (destination / 'manifest.json').write_text(json.dumps(manifest, indent=1) + '\n')
    for name, entry in manifest.items():
        print('%-24s %2d file(s), %d SeriesInstanceUID, %3d frames in all, %d series when imported'
              % (name, len(entry['files']), len(entry['series']), entry['frames_total'], entry['expected_series']))


if __name__ == '__main__':
    main()
