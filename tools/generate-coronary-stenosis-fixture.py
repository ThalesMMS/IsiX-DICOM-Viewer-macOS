#!/usr/bin/env python3
"""A synthetic coronary CT angiography with a narrowing of known degree.

For the in-app check of the stenosis tool measuring a stretch as a coronary
artery, against a proximal and a distal reference. Nothing here comes from a
patient.

A vessel along z at (25.6, 25.6) mm, 400 HU in soft tissue at 50 HU. It
tapers as a coronary artery does: 1.75 mm of radius at z = 4 mm down to 1.25
mm at z = 44 mm. From z = 22 to 26 mm it is narrowed to half the radius it
would have there (1 mm ramps on each side): a stenosis of 50 % by diameter
and 75 % by area, wherever the reference is taken as what the vessel would
be at the narrowing. Read against the distal end alone it comes out short
of that. Blurred by a Gaussian of 0.35 mm, with 20 HU of noise (seeded).
0.4 mm voxels, 128 x 128 x 120.

With --plaque, another patient and study, for the plaque of a stretch: a
vessel of 1.5 mm of radius all along, in fat at -90 HU, with a wall of 0.3 mm
at 80 HU. From z = 14 to 34 mm plaque in three rings around the lumen:
fibrous at 150 HU out to 2.1 mm from the axis, fibro-fatty at 80 HU to 2.7,
lipid-rich at 0 HU to 3.3; and from z = 20 to 28 a calcium nodule of 0.5 mm
of radius at 1300 HU in the fibro-fatty ring. truth.json has the volumes.

With --tree, a third patient and study, for several paths and the coronary
MIP: three vessels of 1.5 mm of radius at 400 HU along z, at (12, 12),
(40, 12) and (25.6, 42) mm, in soft tissue at 50 HU, and between them a
chamber full of contrast, a ball of 8 mm of radius at 400 HU centred at
(25.6, 24, 24) mm, 10 mm or more from each vessel. A projection of maxima
shows the chamber; one of the voxels within 4 mm of the three paths does
not. Writes centerline-lad.txt, centerline-lcx.txt and centerline-rca.txt.

    generate-coronary-stenosis-fixture.py [--plaque | --tree] <empty dir>

writes ct-NNN.dcm, centerline.txt (patient space, mm: the path of the vessel
from z = 4 to 44) and truth.json. Needs pydicom and numpy.
"""
import json
import sys
from pathlib import Path

import numpy
from pydicom.dataset import Dataset, FileMetaDataset
from pydicom.uid import CTImageStorage, ExplicitVRLittleEndian, generate_uid

arguments = [a for a in sys.argv[1:] if a not in ('--plaque', '--tree')]
plaque, tree = '--plaque' in sys.argv[1:], '--tree' in sys.argv[1:]
if plaque and tree:
    sys.exit(__doc__)
if len(arguments) != 1:
    sys.exit(__doc__)
destination = Path(arguments[0])
destination.mkdir(parents=True, exist_ok=True)
if any(destination.iterdir()):
    sys.exit('the destination is not empty')
voxel, size, slices, center, fine = 0.4, 128, 120, 25.6, 4
START, END, NARROW = 4.0, 44.0, (22.0, 26.0)


def healthy(z):
    """The radius the vessel would have at z without the narrowing."""
    return 1.75 - 0.5 * min(max((z - START) / (END - START), 0), 1)


VESSELS = {'lad': (12.0, 12.0), 'lcx': (40.0, 12.0), 'rca': (25.6, 42.0)}
CHAMBER, CHAMBER_RADIUS = (25.6, 24.0, 24.0), 8.0
PLAQUE, NODULE = (14.0, 34.0), (20.0, 28.0)
RINGS = [(2.1, 150.0), (2.7, 80.0), (3.3, 0.0)]


def radius(z):
    if plaque:
        return 1.5
    low, high = NARROW
    if low <= z <= high:
        share = 0.5
    elif low - 1 < z < low:
        share = 1 - 0.5 * (z - (low - 1))
    elif high < z < high + 1:
        share = 0.5 + 0.5 * (z - high)
    else:
        share = 1
    return healthy(z) * share


# Each voxel is the mean of fine x fine samples of its plane: the partial volume of the wall.
coordinates = (numpy.arange(size * fine) + 0.5) / fine * voxel - voxel / 2
x, y = numpy.meshgrid(coordinates - center, coordinates - center)
rho = numpy.hypot(x, y)
volume = numpy.empty((slices, size, size))
for k in range(slices):
    z = k * voxel
    plane = numpy.full(rho.shape, -90.0 if plaque else 50.0)
    if tree:
        for vx, vy in VESSELS.values():
            plane[numpy.hypot(x + center - vx, y + center - vy) <= 1.5] = 400
        across = CHAMBER_RADIUS ** 2 - (z - CHAMBER[2]) ** 2
        if across > 0:
            plane[numpy.hypot(x + center - CHAMBER[0], y + center - CHAMBER[1]) <= across ** 0.5] = 400
        volume[k] = plane.reshape(size, fine, size, fine).mean(axis=(1, 3))
        continue
    if plaque:
        if PLAQUE[0] <= z <= PLAQUE[1]:
            for outer, value in reversed(RINGS):
                plane[rho <= outer] = value
            if NODULE[0] <= z <= NODULE[1]:
                plane[numpy.hypot(x - 2.4, y) <= 0.5] = 1300
        else:
            plane[rho <= 1.8] = 80
    plane[rho <= radius(z)] = 400
    volume[k] = plane.reshape(size, fine, size, fine).mean(axis=(1, 3))

sigma = 0.35 / voxel
reach = int(numpy.ceil(3 * sigma))
kernel = numpy.exp(-numpy.arange(-reach, reach + 1) ** 2 / (2 * sigma * sigma))
kernel /= kernel.sum()
for axis in range(3):
    volume = numpy.apply_along_axis(lambda line: numpy.convolve(numpy.pad(line, reach, mode='edge'), kernel, mode='valid'), axis, volume)
volume += numpy.random.default_rng(1978).normal(0, 20, volume.shape)

study, series = generate_uid(), generate_uid()
for k in range(slices):
    sop = generate_uid()
    d = Dataset()
    d.file_meta = FileMetaDataset()
    d.file_meta.MediaStorageSOPClassUID = CTImageStorage
    d.file_meta.MediaStorageSOPInstanceUID = sop
    d.file_meta.TransferSyntaxUID = ExplicitVRLittleEndian
    d.file_meta.ImplementationClassUID = generate_uid()
    d.SpecificCharacterSet = 'ISO_IR 100'
    d.SOPClassUID, d.SOPInstanceUID, d.StudyInstanceUID, d.SeriesInstanceUID = CTImageStorage, sop, study, series
    d.PatientName, d.PatientID = ('CORONARY^TREE', 'SYN-1980') if tree else ('STENOSIS^PLAQUE', 'SYN-1979') if plaque else ('STENOSIS^CORONARY', 'SYN-1978')
    d.PatientBirthDate, d.PatientSex = '19700101', 'O'
    d.StudyDate = d.ContentDate = '20260101'
    d.StudyTime = d.ContentTime = '120000'
    d.AccessionNumber, d.StudyID = ('SYN1980', '1980') if tree else ('SYN1979', '1979') if plaque else ('SYN1978', '1978')
    d.SeriesNumber, d.InstanceNumber, d.Modality = 1, k + 1, 'CT'
    d.StudyDescription = 'synthetic coronary tree beside a chamber' if tree else 'synthetic coronary artery in fat with plaque and calcium' if plaque else 'synthetic tapering coronary artery with a 50 % narrowing'
    d.SeriesDescription = 'vessel 0.4 mm'
    d.ImageType = ['ORIGINAL', 'PRIMARY', 'AXIAL']
    d.ImagePositionPatient = [0.0, 0.0, k * voxel]
    d.ImageOrientationPatient = [1.0, 0.0, 0.0, 0.0, 1.0, 0.0]
    d.SliceLocation, d.PixelSpacing, d.SliceThickness, d.SpacingBetweenSlices = k * voxel, [voxel, voxel], voxel, voxel
    d.Rows = d.Columns = size
    d.SamplesPerPixel, d.PhotometricInterpretation = 1, 'MONOCHROME2'
    d.BitsAllocated, d.BitsStored, d.HighBit, d.PixelRepresentation = 16, 16, 15, 0
    d.WindowCenter, d.WindowWidth, d.RescaleIntercept, d.RescaleSlope = 300.0, 1200.0, -1024.0, 1.0
    d.PixelData = numpy.clip(numpy.rint(volume[k] + 1024), 0, 65535).astype(numpy.uint16).tobytes()
    d.save_as(str(destination / ('ct-%03d.dcm' % k)), enforce_file_format=True)

if tree:
    for name, (vx, vy) in VESSELS.items():
        (destination / f'centerline-{name}.txt').write_text('# space=patient\n# units=mm\n' + ''.join(f'{vx} {vy} {vz}\n' for vz in (4, 24, 44)))
    truth = {
        'vessels': {name: f'along z at x = {vx}, y = {vy} mm, radius 1.5 mm, 400 HU' for name, (vx, vy) in VESSELS.items()},
        'chamber': f'ball of {CHAMBER_RADIUS} mm at {CHAMBER} mm, 400 HU',
        'voxels (column, row, slice)': {'chamber centre': [64, 60, 60], 'lad': [30, 30, 60], 'lcx': [100, 30, 60], 'rca': [64, 105, 60], 'tissue far from all': [5, 120, 60]},
        'voxel index': 'column + 128 * (row + 128 * slice)',
    }
    (destination / 'truth.json').write_text(json.dumps(truth, indent=2) + '\n')
    print(slices, 'slices; three vessels along z and a chamber of 8 mm between them')
    sys.exit(0)
(destination / 'centerline.txt').write_text('# space=patient\n# units=mm\n25.6 25.6 4\n25.6 25.6 24\n25.6 25.6 44\n')
if plaque:
    import math
    step = lambda span: min(span[1], END) - max(span[0], START)
    ring = lambda inner, outer: math.pi * (outer * outer - inner * inner)
    nodule = math.pi * 0.25 * step(NODULE)
    healthy_wall = ring(1.5, 1.8) * (END - START - step(PLAQUE))
    truth = {
        'vessel': 'along z at x = y = 25.6 mm, 400 HU, radius 1.5 mm, in fat at -90 HU, wall of 0.3 mm at 80 HU',
        'plaque': 'z 14 to 34 mm: fibrous 150 HU to 2.1 mm, fibro-fatty 80 HU to 2.7, lipid-rich 0 HU to 3.3; calcium 1300 HU, radius 0.5 mm at x + 2.4, z 20 to 28',
        'volumes mm3 along z 4 to 44': {
            'lipid-rich (below 30 HU)': round(ring(2.7, 3.3) * step(PLAQUE), 1),
            'fibro-fatty (30 to 130 HU)': round(ring(2.1, 2.7) * step(PLAQUE) - nodule + healthy_wall, 1),
            'fibrous (130 to 350 HU)': round(ring(1.5, 2.1) * step(PLAQUE), 1),
            'calcium (above 350 HU)': round(nodule, 1),
            'plaque and wall': round(ring(1.5, 3.3) * step(PLAQUE) + healthy_wall, 1),
            'lumen': round(math.pi * 2.25 * (END - START), 1),
        },
        'centerline': 'z 4 to 44 mm: a relative position t of the path is z = 4 + 40 t',
    }
    (destination / 'truth.json').write_text(json.dumps(truth, indent=2) + '\n')
    print(slices, 'slices; plaque at z 14-34 mm in three bands, calcium at z 20-28; centerline of 40 mm')
    sys.exit(0)
middle = sum(NARROW) / 2
truth = {
    'vessel': 'along z at x = y = 25.6 mm, 400 HU in 50 HU, radius 1.75 mm at z 4 to 1.25 mm at z 44',
    'narrowing': {'z mm': list(NARROW), 'radius mm at its middle': radius(middle), 'healthy radius mm at its middle': healthy(middle)},
    'stenosis by diameter %': 50.0, 'stenosis by area %': 75.0,
    'against the distal end alone (z 34 to 44), by diameter %': round((1 - radius(middle) / healthy(39.0)) * 100, 1),
    'centerline': 'z 4 to 44 mm: a relative position t of the path is z = 4 + 40 t',
}
(destination / 'truth.json').write_text(json.dumps(truth, indent=2) + '\n')
print(slices, 'slices; narrowing at z 22-26 mm, 50 % by diameter; centerline of 40 mm')
