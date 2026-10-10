#!/usr/bin/env python3
"""Serve a synthetic study over loopback QIDO-RS and WADO-RS.

The DICOMweb pilot was validated against an Orthanc in a container. This
serves the same two halves a Horos DICOMweb node uses — QIDO-RS for the
hierarchy and WADO-RS for the objects — from data it generates itself, with the
standard library and pydicom, so a study can be retrieved by the application's
own client without any other infrastructure.

Loopback by default, no authentication, and it records what was asked of it.
--bind-address selects one explicit local IPv4 interface for HTTP opt-in checks.

It also takes STOW-RS: a POST to studies (or studies/{uid}) is read as
multipart/related application/dicom, each part is parsed, recorded with its
SOP Instance UID and transfer syntax (the part's and the file's), and kept in
--store when given. The SOP Instance UIDs listed in --refuse-uids-file are
refused with Failure Reason 0x0110, so a partial failure (202) can be tried;
200 when every instance is stored, 409 when none is.

--series N splits the instances into N series, in order; --series-sizes
A,B,... gives each series its own number of instances instead, and
--series-descriptions A,B,... its own SeriesDescription. --listing-delay
SECONDS pauses each series' QIDO-RS instance listing, as a slow node's would.
WADO-RS answers the study, a series, or one instance.

--extra-study-modalities MR,US,... adds one study per modality, with the same
patient, that only the study-level QIDO-RS lists. The study-level search
filters on ModalitiesInStudy (00080061) and StudyInstanceUID (0020000D), each
a comma-separated list of values as PS3.18 defines; a backslash is matched
literally, as a standard server would. The raw query string of each request
goes to the record too.

--throttle-above N answers a WADO-RS request with --throttle-status (429 by
default) while N others are being sent, with --retry-after VALUE as its
Retry-After header when given (any text, valid or not); each such answer is
recorded. --throttle-first N answers the same way the first N QIDO-RS, the
first N WADO-RS and the first N STOW-RS requests, each counted apart, as a
node that is busy for a while; a large N keeps it busy.

--refuse-status N answers every WADO-RS and STOW-RS request with HTTP N and
--refuse-text TEXT as a text/plain body, as a node that gives its reason;
"\\n" in TEXT is a line break. --qido-warning TEXT sends TEXT as the Warning
header of every QIDO-RS answer, such as 299 for a parameter it ignored.

--refuse-syntax UID answers 406 to a WADO-RS request whose Accept asks first
for that transfer syntax, as a server that cannot convert to it does, and
records it; the request asked again without that range is served, each part
typed with the syntax the instances are written in (Explicit VR Little
Endian). --refuse-syntax '*' refuses transfer-syntax=*, as a minimal server
that knows only named syntaxes does; --refuse-syntax-status N answers N
instead of 406, such as 501.

--listing-status N answers HTTP N to the QIDO-RS listings of a study's series
and of a series' instances, as a minimal server that implements only the
search for studies does (501); --instance-listing-status N answers N to the
instance listings only. Each such request is recorded with its status.

--cut-syntax UID stands for a server that can convert only the study's first
instance to that transfer syntax and converts while it streams, as Orthanc
does. A WADO-RS request whose Accept asks first for that syntax and that
starts with the first instance is answered 200 with that one part and the
next part's headers, then the connection is closed without the rest; one that starts with another instance
is answered 500 before any part. Both are recorded. Asked again without that
range, the request is served whole, as --refuse-syntax does.

--derive-first, with --cut-syntax, sends the first instance in that syntax as
Orthanc sends an object it converts to a lossy syntax: a copy under a new SOP
Instance UID, whose Source Image Sequence names the original, with a
Derivation Description and Lossy Image Compression 01. The listing names only
the original; the record gives the copy's UID as derived. With
--derive-unreferenced the copy names nothing it came from, as Orthanc 1.13.0
sends an object it converts through GDCM: no Source Image Sequence, Derivation
Description or Lossy Image Compression; its series, SOP class and Instance
Number stay the original's.

--repeat-first-number gives the second instance the first one's Instance
Number, in the files and the listing: two listed instances that a copy naming
neither could stand for.

--json-edge-cases writes the study's QIDO-RS results the way some servers do:
a PatientName with only an Ideographic group, a ReferringPhysicianName with
"Alphabetic": null, a ModalitiesInStudy with a null between two values,
NumberOfStudyRelatedSeries and SeriesNumber (IS) as strings beside
NumberOfStudyRelatedInstances (IS) as a number, and PatientSize (DS) as a
number beside PatientWeight (DS) as a string.

--part-delay SECONDS sends a WADO-RS response slowly: the next part's
delimiter and first bytes, then a pause, then the rest, so each object is
known complete while the response is still arriving. The time each part was
sent, its series and the end of the response go to the request record.

--studies N serves N studies, each with the series and instances the other
options describe, for its own patient: the first is the one the output and
the record name as before, the others are listed in studyInstanceUIDs and
under studies. Each answers the study-level search, the listings and WADO-RS
at its own UIDs.

--cut-after K closes a WADO-RS study or series response after its first K
complete parts and the next part's headers, as a connection lost in the
middle of a transfer; --cut-times T (1 by default) cuts the first T such
responses of each study, and serves the later ones whole. A response of K
parts or fewer, such as one instance, is never cut. Each cut is recorded.

--stall-after K --stall-seconds S stops sending the first WADO-RS study or
series response of each study after its first K parts and the next part's
headers, for S seconds, then closes the connection: a node that stalls longer
than a client's inactivity timeout. The later responses are sent whole. Each
stall is recorded.

--instance-failures FILE names instances the node fails to send, one per
line: "SOPInstanceUID STATUS COUNT". A study or series response leaves them
out, as a node that skips what it cannot read does; asked for by itself, such
an instance is answered STATUS for its first COUNT requests (-1: always), then
sent. The file is read at each request, so it can name the UIDs the output
gives. Each such answer is recorded.

--listing-cap N answers each page of an instance listing with at most N
instances and no Warning, as a server that caps its pages below the client's
limit; NumberOfSeriesRelatedInstances and NumberOfStudyRelatedInstances keep
the true counts.

--omit-instance-counts leaves NumberOfStudyRelatedInstances and
NumberOfSeriesRelatedInstances out of QIDO-RS results. Instance listings and
WADO-RS responses still contain the generated instances.

A WADO-RS response is streamed from the instance files, never held whole in
memory, and each write to the socket is at most --write-block bytes: a single
write of 2 GiB or more fails on macOS. The largest write made goes to the
record as maxWADOWrite.

    python3 tools/serve-dicomweb-fixture.py FIXTURE EVIDENCE [--port 18044]
        [--store DIR] [--refuse-uids-file FILE] [--part-delay SECONDS]
        [--series N | --series-sizes A,B,...] [--series-descriptions A,B,...]
        [--listing-delay SECONDS] [--extra-study-modalities MR,...] [--throttle-above N] [--throttle-first N]
        [--throttle-status 429|503] [--retry-after VALUE] [--refuse-status N [--refuse-text TEXT]]
        [--qido-warning TEXT] [--refuse-syntax UID [--refuse-syntax-status N]]
        [--listing-status N] [--instance-listing-status N] [--cut-syntax UID [--derive-first [--derive-unreferenced]]] [--repeat-first-number] [--json-edge-cases] [--write-block BYTES]
        [--studies N] [--cut-after K [--cut-times T]] [--listing-cap N] [--instance-failures FILE]
        [--stall-after K --stall-seconds S]
"""
import time
import argparse
import ipaddress
import io
import json
import re
import signal
import socket
import threading
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse, parse_qs

import numpy
from pydicom import dcmread
from pydicom.dataset import Dataset, FileMetaDataset
from pydicom.uid import CTImageStorage, ExplicitVRLittleEndian, generate_uid
# Run as tools/serve-dicomweb-fixture.py: this folder is already on the path.
from local_http import ThreadingLocalHTTPServer

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('fixture', type=Path, help='empty directory for the generated study')
parser.add_argument('evidence', type=Path, help='directory for the request record')
parser.add_argument('--port', type=int, default=18044)
parser.add_argument('--bind-address', default='127.0.0.1', help='explicit local IPv4 interface for synthetic HTTP validation')
parser.add_argument('--instances', type=int, default=4)
parser.add_argument('--rows', type=int, default=64)
parser.add_argument('--columns', type=int, default=64)
parser.add_argument('--patient-name', default='SYNTHETIC^DICOMWEB384')
parser.add_argument('--patient-id', default='LOCAL-DICOMWEB-384')
parser.add_argument('--store', type=Path, help='directory the instances STOW-RS stores are written to')
parser.add_argument('--refuse-uids-file', type=Path, help='SOP Instance UIDs, one per line, that STOW-RS refuses')
parser.add_argument('--part-delay', type=float, default=0.0, help='pause inside each WADO-RS part after the first, in seconds')
parser.add_argument('--series', type=int, default=1, help='number of series the instances are split into')
parser.add_argument('--series-sizes', help='instances of each series, comma-separated; overrides --instances and --series')
parser.add_argument('--series-descriptions', help='SeriesDescription of each series, comma-separated, in order')
parser.add_argument('--throttle-above', type=int, default=0, help='answer busy beyond this many WADO-RS responses at once; 0 never')
parser.add_argument('--throttle-first', type=int, default=0,
                    help='answer busy to the first N requests of each of QIDO-RS, WADO-RS and STOW-RS; 0 never')
parser.add_argument('--throttle-status', type=int, choices=(429, 503), default=429)
parser.add_argument('--retry-after', help='Retry-After header of a busy answer, sent as given')
parser.add_argument('--refuse-status', type=int, default=0, help='answer WADO-RS and STOW-RS with this status; 0 never')
parser.add_argument('--refuse-text', default='', help='the text/plain body of --refuse-status; \\n is a line break')
parser.add_argument('--qido-warning', help='Warning header of every QIDO-RS answer')
parser.add_argument('--qido-ignores-offset', action='store_true', help='answer every QIDO-RS page with the first one, as a node that ignores offset')
parser.add_argument('--refuse-syntax', help='answer 406 to WADO-RS when the first range of Accept asks for this transfer syntax')
parser.add_argument('--refuse-syntax-status', type=int, default=406, help='the status --refuse-syntax answers with')
parser.add_argument('--listing-status', type=int, default=0, help='answer series and instance QIDO-RS listings with this status; 0 never')
parser.add_argument('--instance-listing-status', type=int, default=0, help='answer instance QIDO-RS listings with this status; 0 never')
parser.add_argument('--cut-syntax', help='send one part and close the connection when the first range of Accept asks for this transfer syntax')
parser.add_argument('--derive-first', action='store_true', help='with --cut-syntax, send the first instance in that syntax as a copy with a new UID')
parser.add_argument('--derive-unreferenced', action='store_true', help='with --derive-first, a copy that names nothing it came from')
parser.add_argument('--repeat-first-number', action='store_true', help='the second instance has the first one\'s Instance Number')
parser.add_argument('--listing-delay', type=float, default=0.0, help='pause before each series instance listing, in seconds')
parser.add_argument('--json-edge-cases', action='store_true', help='nulls, a PN without Alphabetic and IS/DS as numbers and strings in QIDO-RS')
parser.add_argument('--extra-study-modalities', default='', help='one more study, listed by QIDO-RS only, per modality; comma-separated')
parser.add_argument('--write-block', type=int, default=8 << 20, help='largest single write of a WADO-RS response, in bytes')
parser.add_argument('--studies', type=int, default=1, help='number of studies served, each with its own patient')
parser.add_argument('--cut-after', type=int, default=0, help='close a WADO-RS study or series response after this many parts; 0 never')
parser.add_argument('--cut-times', type=int, default=1, help='how many responses of each study --cut-after cuts')
parser.add_argument('--listing-cap', type=int, default=0, help='at most this many instances per instance listing page, with no Warning; 0 never')
parser.add_argument('--omit-instance-counts', action='store_true', help='omit study and series instance counts from QIDO-RS results')
parser.add_argument('--stall-after', type=int, default=0, help='stall the first study or series response of each study after this many parts; 0 never')
parser.add_argument('--stall-seconds', type=float, default=0.0, help='how long --stall-after stalls before closing the connection')
parser.add_argument('--instance-failures', type=Path, help='"SOPInstanceUID STATUS COUNT" per line: left out of study and series responses, failed when asked alone')
args = parser.parse_args()
sizes = None
if args.series_sizes:
    try:
        sizes = [int(size) for size in args.series_sizes.split(',')]
    except ValueError:
        sizes = []
    if not sizes or min(sizes) < 1:
        parser.error('--series-sizes takes positive counts, such as 12,12,2')
    args.instances, args.series = sum(sizes), len(sizes)
descriptions = args.series_descriptions.split(',') if args.series_descriptions else []


def series_description(number):
    if number < len(descriptions):
        return descriptions[number]
    return 'DICOMweb retrieved' if number == 0 else 'DICOMweb series %d' % (number + 1)

try:
    bind_ip = ipaddress.IPv4Address(args.bind_address)
    if bind_ip.is_unspecified or bind_ip.is_multicast:
        raise ValueError()
except ValueError:
    parser.error('--bind-address must name one local IPv4 interface, not a wildcard or multicast address')
if not 1024 <= args.port <= 65535 or args.instances < 1:
    parser.error('a port above 1024 and at least one instance')
if args.write_block < 1:
    parser.error('--write-block takes a positive number of bytes')
if args.derive_first and not args.cut_syntax:
    parser.error('--derive-first takes --cut-syntax')
if args.derive_unreferenced and not args.derive_first:
    parser.error('--derive-unreferenced takes --derive-first')
if args.refuse_syntax_status != 406 and not args.refuse_syntax:
    parser.error('--refuse-syntax-status takes --refuse-syntax')
for status in (args.refuse_syntax_status, args.listing_status or 400, args.instance_listing_status or 400):
    if not 400 <= status <= 599:
        parser.error('a refusal status is between 400 and 599')
if args.studies < 1 or args.cut_after < 0 or args.cut_times < 1 or args.listing_cap < 0:
    parser.error('--studies and --cut-times take a positive number, --cut-after and --listing-cap a count')
if bool(args.stall_after) != (args.stall_seconds > 0):
    parser.error('--stall-after and --stall-seconds go together')
if args.cut_after and args.cut_syntax:
    parser.error('--cut-after and --cut-syntax are two ways to cut a response: use one')
if args.repeat_first_number and args.instances < 2:
    parser.error('--repeat-first-number takes at least two instances')
args.fixture.mkdir(parents=True, exist_ok=True)
if any(args.fixture.iterdir()):
    parser.error('the fixture directory must be empty: ' + str(args.fixture))
args.evidence.mkdir(parents=True, exist_ok=True)
if args.store:
    args.store.mkdir(parents=True, exist_ok=True)

def make_study(ordinal):
    """One study, its series and instances; the first has the options' patient and file names."""
    study_uid, series_uid = generate_uid(), generate_uid()
    series_uids = [series_uid] + [generate_uid() for _ in range(max(1, args.series) - 1)]
    patient_name = args.patient_name + ('' if ordinal == 0 else '-%d' % (ordinal + 1))
    patient_id = args.patient_id + ('' if ordinal == 0 else '-%d' % (ordinal + 1))
    instances = []
    for index in range(args.instances):
        dataset = Dataset()
        dataset.file_meta = FileMetaDataset()
        dataset.file_meta.MediaStorageSOPClassUID = CTImageStorage
        dataset.file_meta.MediaStorageSOPInstanceUID = generate_uid()
        dataset.file_meta.TransferSyntaxUID = ExplicitVRLittleEndian
        dataset.is_little_endian, dataset.is_implicit_VR = True, False
        dataset.SOPClassUID = CTImageStorage
        dataset.SOPInstanceUID = dataset.file_meta.MediaStorageSOPInstanceUID
        in_series = (next(n for n in range(len(sizes)) if index < sum(sizes[:n + 1])) if sizes
                     else index * len(series_uids) // args.instances)
        dataset.StudyInstanceUID, dataset.SeriesInstanceUID = study_uid, series_uids[in_series]
        dataset.PatientName, dataset.PatientID = patient_name, patient_id
        dataset.PatientBirthDate = '19700101'
        dataset.StudyDate, dataset.StudyTime = '20260914', '120000'
        dataset.StudyDescription = 'Synthetic DICOMweb Retrieval'
        dataset.SeriesDescription = series_description(in_series)
        number = 1 if args.repeat_first_number and index == 1 else index + 1
        dataset.Modality, dataset.SeriesNumber, dataset.InstanceNumber = 'CT', in_series + 1, number
        dataset.StudyID, dataset.AccessionNumber = '384', ''
        dataset.ImagePositionPatient = [0.0, 0.0, float(index) * 2.0]
        dataset.ImageOrientationPatient = [1.0, 0.0, 0.0, 0.0, 1.0, 0.0]
        dataset.FrameOfReferenceUID = generate_uid() if index == -1 else study_uid
        dataset.PixelSpacing, dataset.SliceThickness = [0.5, 0.5], 2.0
        dataset.Rows, dataset.Columns = args.rows, args.columns
        dataset.SamplesPerPixel, dataset.PhotometricInterpretation = 1, 'MONOCHROME2'
        dataset.BitsAllocated, dataset.BitsStored, dataset.HighBit = 16, 16, 15
        dataset.PixelRepresentation = 1
        dataset.RescaleIntercept, dataset.RescaleSlope = -1024.0, 1.0
        dataset.WindowCenter, dataset.WindowWidth = 40.0, 400.0
        # A gradient that differs per instance, so a retrieved page is identifiable.
        # Steps of 200 wrap below 30000 and every wrap adds one more, so the
        # gradient (up to 1000) stays inside int16 and no two instances share an
        # offset; the first 150 keep the plain index * 200.
        offset = index * 200 % 30000 + index * 200 // 30000
        gradient = numpy.linspace(0, 1000, args.rows * args.columns, dtype=numpy.int32)
        pixels = (gradient.reshape(args.rows, args.columns) + offset).astype(numpy.int16)
        pixels[: args.rows // 8, : args.columns // 8] = 2000
        dataset.PixelData = pixels.tobytes()
        path = args.fixture / (('instance-%03d.dcm' % index) if ordinal == 0 else 'study-%02d-instance-%03d.dcm' % (ordinal + 1, index))
        dataset.save_as(path, enforce_file_format=True)
        instances.append({'path': path, 'sop': dataset.SOPInstanceUID, 'number': number, 'series': series_uids[in_series],
                          'study': study_uid})
    return {'uid': study_uid, 'series': series_uids, 'instances': instances, 'patientName': patient_name, 'patientID': patient_id}


studies = [make_study(ordinal) for ordinal in range(args.studies)]
# The first study, as the options and the output have always named it.
study_uid, series_uids, instances = studies[0]['uid'], studies[0]['series'], studies[0]['instances']
series_uid = series_uids[0]

# The first instance as a server sends it once converted to a lossy syntax.
derived = None
if args.derive_first:
    dataset = dcmread(instances[0]['path'])
    if not args.derive_unreferenced:
        reference = Dataset()
        reference.ReferencedSOPClassUID, reference.ReferencedSOPInstanceUID = dataset.SOPClassUID, dataset.SOPInstanceUID
        dataset.SourceImageSequence = [reference]
        dataset.DerivationDescription = 'Lossy compression with JPEG baseline, quality 90'
        dataset.LossyImageCompression = '01'
    dataset.SOPInstanceUID = dataset.file_meta.MediaStorageSOPInstanceUID = generate_uid()
    path = args.fixture / 'derived-000.dcm'
    dataset.save_as(path, enforce_file_format=True)
    derived = dict(instances[0], path=path, sop=dataset.SOPInstanceUID)

served = []
lock = threading.Lock()
# WADO-RS responses being sent now, and the most at once: what a client's
# request limit allowed.
wado_in_flight = [0, 0]
# The requests of each service answered busy by --throttle-first so far.
throttled_first = {'qido': 0, 'wado': 0, 'stow': 0}
# The largest single write of a WADO-RS response so far.
wado_largest_write = [0]
# The responses of each study --cut-after has cut, and --stall-after stalled, so far.
cuts_by_study = {}
stalls_by_study = set()


def attribute(vr, value):
    return {'vr': vr, 'Value': value if isinstance(value, list) else [value]}


def study_record(study=None):
    study = study or studies[0]
    return {
        '0020000D': attribute('UI', study['uid']),
        '00100010': attribute('PN', {'Alphabetic': study['patientName']}),
        '00100020': attribute('LO', study['patientID']),
        '00100030': attribute('DA', '19700101'),
        '00080020': attribute('DA', '20260914'),
        '00080030': attribute('TM', '120000'),
        '00081030': attribute('LO', 'Synthetic DICOMweb Retrieval'),
        '00080061': attribute('CS', 'CT'),
        '00200010': attribute('SH', '384'),
        '00201206': attribute('IS', len(study['series'])),
        '00201208': attribute('IS', len(study['instances'])),
    } | (json_edge_cases() if args.json_edge_cases else {})


def json_edge_cases():
    return {
        '00100010': attribute('PN', {'Ideographic': '山田^太郎'}),
        '00080090': attribute('PN', {'Alphabetic': None, 'Ideographic': '佐藤^花子'}),
        '00080061': attribute('CS', ['CT', None, 'MR']),
        '00201206': attribute('IS', str(len(series_uids))),
        '00101020': attribute('DS', 1.75),
        '00101030': attribute('DS', '70.5'),
    }


# Studies with other modalities, listed by the study-level search only.
extra_studies = [(generate_uid(), modality) for modality in args.extra_study_modalities.split(',') if modality]


def study_records(query):
    records = [study_record(study) for study in studies]
    for uid, modality in extra_studies:
        record = study_record()
        record.update({'0020000D': attribute('UI', uid), '00080061': attribute('CS', modality),
                       '00201206': attribute('IS', 0), '00201208': attribute('IS', 0)})
        records.append(record)
    for keys, tag in ((('00080061', 'ModalitiesInStudy'), '00080061'), (('0020000D', 'StudyInstanceUID'), '0020000D')):
        wanted = next((query[key][0] for key in keys if key in query), None)
        if wanted is not None:
            values = set(wanted.split(','))
            records = [record for record in records if values & set(record[tag]['Value'])]
    return records


def series_records(study):
    return [{
        '0020000D': attribute('UI', study['uid']),
        '0020000E': attribute('UI', uid),
        '00080060': attribute('CS', 'CT'),
        '0008103E': attribute('LO', series_description(number)),
        '00200011': attribute('IS', str(number + 1) if args.json_edge_cases else number + 1),
        '00201209': attribute('IS', len([item for item in study['instances'] if item['series'] == uid])),
    } for number, uid in enumerate(study['series'])]


def instance_records(study, series=None):
    return [{
        '0020000D': attribute('UI', study['uid']),
        '0020000E': attribute('UI', item['series']),
        '00080018': attribute('UI', item['sop']),
        '00080016': attribute('UI', CTImageStorage),
        '00200013': attribute('IS', item['number']),
        '00280010': attribute('US', args.rows),
        '00280011': attribute('US', args.columns),
    } for item in study['instances'] if series is None or item['series'] == series]


def find_study(uid):
    """The study a path names; with one study, that study whatever the path says, as before --studies."""
    if len(studies) == 1:
        return studies[0]
    return next((study for study in studies if study['uid'] == uid), None)


def write_record():
    with lock:
        record.write_text(json.dumps({
            'port': args.port, 'studyInstanceUID': study_uid, 'seriesInstanceUID': series_uid,
            'patientID': args.patient_id, 'patientName': args.patient_name,
            'extraStudies': [{'studyInstanceUID': uid, 'modality': modality} for uid, modality in extra_studies],
            'instances': [{'sopInstanceUID': item['sop'], 'file': item['path'].name} for item in instances],
            'derived': {'sopInstanceUID': derived['sop'], 'source': instances[0]['sop']} if derived else None,
            'requests': served,
            'maxConcurrentWADO': wado_in_flight[1],
            'maxWADOWrite': wado_largest_write[0],
            'studies': [{'studyInstanceUID': study['uid'], 'patientID': study['patientID'],
                         'seriesInstanceUIDs': study['series'],
                         'instances': [{'sopInstanceUID': item['sop'], 'series': item['series']} for item in study['instances']]}
                        for study in studies],
        }, indent=1) + '\n')


# Requests each --instance-failures instance has been answered with its status.
failures_served = {}


def instance_failures():
    """Read at each request: {uid: (status, count)}."""
    if not args.instance_failures:
        return {}
    try:
        lines = args.instance_failures.read_text().splitlines()
    except OSError:
        return {}
    failing = {}
    for line in lines:
        fields = line.split()
        if len(fields) == 3 and fields[1].isdigit() and 400 <= int(fields[1]) <= 599:
            failing[fields[0]] = (int(fields[1]), int(fields[2]))
    return failing


def refused_uids():
    """Read at each request, so a running server can be told to refuse more."""
    if not args.refuse_uids_file:
        return set()
    try:
        return {line.strip() for line in args.refuse_uids_file.read_text().splitlines() if line.strip()}
    except OSError:
        return set()


def multipart_parts(content_type, body):
    """The (headers, payload) of each part of a multipart/related body."""
    boundary = None
    for parameter in content_type.split(';')[1:]:
        key, _, value = parameter.strip().partition('=')
        if key.lower() == 'boundary':
            boundary = value.strip('"')
    if not boundary:
        return None
    delimiter = b'--' + boundary.encode()
    parts = []
    for chunk in body.split(delimiter)[1:]:
        if chunk.startswith(b'--'):
            break
        chunk = chunk[2:] if chunk.startswith(b'\r\n') else chunk
        head, separator, payload = chunk.partition(b'\r\n\r\n')
        if not separator:
            return None
        if payload.endswith(b'\r\n'):
            payload = payload[:-2]
        headers = {}
        for line in head.decode('latin1').split('\r\n'):
            key, _, value = line.partition(':')
            if key:
                headers[key.strip().lower()] = value.strip()
        parts.append((headers, payload))
    return parts


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def json(self, records):
        if args.omit_instance_counts:
            for record in records:
                record.pop('00201208', None)
                record.pop('00201209', None)
        body = json.dumps(records).encode()
        if not records:
            self.send_response(204)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        self.send_response(200)
        self.send_header('Content-Type', 'application/dicom+json')
        if args.qido_warning:
            self.send_header('Warning', args.qido_warning)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def refused(self, service):
        """Answer --refuse-status with --refuse-text, if it is set."""
        if not args.refuse_status:
            return False
        body = args.refuse_text.replace('\\n', '\r\n').encode()
        with lock:
            served.append({'path': 'refused', 'service': service, 'status': args.refuse_status, 'at': time.time()})
        write_record()
        self.send_response(args.refuse_status)
        self.send_header('Content-Type', 'text/plain; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        return True

    def busy_first(self, service):
        """Answer busy if this is one of the service's first --throttle-first requests."""
        with lock:
            busy = throttled_first[service] < args.throttle_first
            if busy:
                throttled_first[service] += 1
                served.append({'path': 'throttled', 'service': service, 'status': args.throttle_status, 'at': time.time()})
        if not busy:
            return False
        write_record()
        self.send_response(args.throttle_status)
        if args.retry_after is not None:
            self.send_header('Retry-After', args.retry_after)
        self.send_header('Content-Length', '0')
        self.end_headers()
        return True

    def first_syntax(self):
        first = (self.headers.get('Accept') or '').split(',')[0]
        asked = re.search(r'transfer-syntax\s*=\s*"?([^";\s]+)', first)
        return asked.group(1) if asked else None

    def refuses_syntax(self):
        return bool(args.refuse_syntax) and self.first_syntax() == args.refuse_syntax

    def multipart(self, wanted):
        if self.refuses_syntax():
            with lock:
                served.append({'path': 'refused-syntax', 'status': args.refuse_syntax_status,
                               'accept': self.headers.get('Accept', ''), 'at': time.time()})
            write_record()
            self.send_response(args.refuse_syntax_status)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if self.busy_first('wado') or self.refused('wado'):
            return
        with lock:
            busy = args.throttle_above > 0 and wado_in_flight[0] >= args.throttle_above
            if busy:
                served.append({'path': 'throttled', 'status': args.throttle_status, 'at': time.time()})
            else:
                wado_in_flight[0] += 1
                wado_in_flight[1] = max(wado_in_flight[1], wado_in_flight[0])
        if busy:
            write_record()
            self.send_response(args.throttle_status)
            if args.retry_after is not None:
                self.send_header('Retry-After', args.retry_after)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        try:
            self.send_multipart(wanted)
        finally:
            with lock:
                wado_in_flight[0] -= 1
            write_record()

    def send_bytes(self, data):
        """Write data in slices of at most --write-block bytes."""
        view = memoryview(data)
        for start in range(0, len(view), args.write_block):
            block = view[start:start + args.write_block]
            self.wfile.write(block)
            if len(block) > wado_largest_write[0]:
                with lock:
                    wado_largest_write[0] = max(wado_largest_write[0], len(block))

    def send_part(self, chunks, pause):
        """Send one part's chunks; with a pause, its first 64 bytes, the pause, then the rest."""
        chunks = iter(chunks)
        if pause > 0:
            head = b''
            for chunk in chunks:
                head += chunk
                if len(head) >= 64:
                    break
            self.send_bytes(head[:64])
            self.wfile.flush()
            time.sleep(pause)
            self.send_bytes(head[64:])
        for chunk in chunks:
            self.send_bytes(chunk)
        self.wfile.flush()

    def send_multipart(self, wanted):
        boundary = 'horos384boundary'
        typed = '; transfer-syntax=%s' % ExplicitVRLittleEndian if args.refuse_syntax or args.cut_syntax else ''
        head = ('--%s\r\nContent-Type: application/dicom%s\r\n\r\n' % (boundary, typed)).encode()
        closing = ('--%s--\r\n' % boundary).encode()

        def part(item):
            # Read from disk a block at a time: the response may be larger
            # than the memory it is worth holding.
            yield head
            with item['path'].open('rb') as handle:
                while block := handle.read(args.write_block):
                    yield block
            yield b'\r\n'

        cut = bool(args.cut_syntax) and self.first_syntax() == args.cut_syntax
        if cut and derived:
            wanted = [derived if item is instances[0] else item for item in wanted]
        length = sum(len(head) + item['path'].stat().st_size + 2 for item in wanted) + len(closing)
        if cut and wanted[0] is not instances[0] and wanted[0] is not derived:
            with lock:
                served.append({'path': 'cut-syntax', 'status': 500, 'accept': self.headers.get('Accept', ''),
                               'partsSent': 0, 'of': len(wanted), 'at': time.time()})
            write_record()
            self.send_response(500)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        stall = False
        if args.stall_after and len(wanted) > args.stall_after:
            with lock:
                stall = wanted[0]['study'] not in stalls_by_study
                stalls_by_study.add(wanted[0]['study'])
        cut_after = False
        if args.cut_after and len(wanted) > args.cut_after:
            with lock:
                done = cuts_by_study.get(wanted[0]['study'], 0)
                cut_after = done < args.cut_times
                if cut_after:
                    cuts_by_study[wanted[0]['study']] = done + 1
        self.send_response(200)
        self.send_header('Content-Type',
                         'multipart/related; type="application/dicom"; boundary=%s' % boundary)
        self.send_header('Content-Length', str(length))
        self.end_headers()
        if stall:
            for item in wanted[:args.stall_after]:
                self.send_part(part(item), 0)
            self.send_bytes(head)
            self.wfile.flush()
            with lock:
                served.append({'path': 'stall', 'status': 200, 'study': wanted[0]['study'], 'partsSent': args.stall_after,
                               'of': len(wanted), 'seconds': args.stall_seconds, 'at': time.time()})
            write_record()
            time.sleep(args.stall_seconds)
            self.close_connection = True
            try:
                self.connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            return
        if cut_after:
            # The next part's delimiter ends the last complete one; the
            # connection closes inside the part after it.
            for item in wanted[:args.cut_after]:
                self.send_part(part(item), 0)
            self.send_bytes(head)
            self.wfile.flush()
            with lock:
                served.append({'path': 'cut-after', 'status': 200, 'study': wanted[0]['study'],
                               'partsSent': args.cut_after, 'of': len(wanted), 'at': time.time()})
            write_record()
            self.close_connection = True
            self.connection.shutdown(socket.SHUT_RDWR)
            return
        if cut and len(wanted) > 1:
            # The next part's delimiter ends the first one for the client;
            # the connection closes inside that next part.
            self.send_part(part(wanted[0]), 0)
            self.send_bytes(head)
            self.wfile.flush()
            with lock:
                served.append({'path': 'cut-syntax', 'status': 200, 'accept': self.headers.get('Accept', ''), 'partsSent': 1,
                               'of': len(wanted), 'at': time.time()})
            write_record()
            self.close_connection = True
            self.connection.shutdown(socket.SHUT_RDWR)
            return
        if args.part_delay <= 0:
            for item in wanted:
                self.send_part(part(item), 0)
            self.send_part([closing], 0)
            return
        # Each part after the first starts, pauses, then ends: the one before
        # it is complete once its delimiter has arrived.
        sent = []
        self.send_part(part(wanted[0]), 0)
        sent.append(time.time())
        for item in wanted[1:]:
            self.send_part(part(item), args.part_delay)
            sent.append(time.time())
        self.send_part([closing], args.part_delay)
        with lock:
            served.append({'path': 'multipart-timing', 'partsSent': sent, 'responseEnded': time.time(),
                           'partSeries': [item['series'] for item in wanted]})
        write_record()

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path.strip('/')
        length = int(self.headers.get('Content-Length') or 0)
        body = self.rfile.read(length) if length > 0 else b''
        entry = {'method': 'POST', 'path': path, 'contentType': self.headers.get('Content-Type', ''),
                 'accept': self.headers.get('Accept', ''), 'instances': []}
        if re.fullmatch(r'studies(/[0-9.]+)?', path) and (self.busy_first('stow') or self.refused('stow')):
            return
        parts = multipart_parts(entry['contentType'], body) if re.fullmatch(r'studies(/[0-9.]+)?', path) else None
        if parts is None:
            with lock:
                served.append(entry)
            write_record()
            self.send_response(400 if re.fullmatch(r'studies(/[0-9.]+)?', path) else 404)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        refuse = refused_uids()
        stored, failed = [], []
        for headers, payload in parts:
            item = {'partType': headers.get('content-type', ''), 'bytes': len(payload)}
            try:
                dataset = dcmread(io.BytesIO(payload))
                item['sop'] = str(dataset.SOPInstanceUID)
                item['sopClass'] = str(dataset.SOPClassUID)
                item['transferSyntax'] = str(dataset.file_meta.TransferSyntaxUID)
            except Exception:
                item['status'] = 'unreadable'
                failed.append({'00081197': attribute('US', 0xC000)})
                entry['instances'].append(item)
                continue
            reference = {'00081150': attribute('UI', item['sopClass']), '00081155': attribute('UI', item['sop'])}
            if item['sop'] in refuse:
                item['status'] = 'refused'
                failed.append(dict(reference, **{'00081197': attribute('US', 0x0110)}))
            else:
                item['status'] = 'stored'
                stored.append(reference)
                if args.store:
                    (args.store / (item['sop'] + '.dcm')).write_bytes(payload)
            entry['instances'].append(item)
        with lock:
            served.append(entry)
        write_record()
        response = {}
        if stored:
            response['00081199'] = {'vr': 'SQ', 'Value': stored}
        if failed:
            response['00081198'] = {'vr': 'SQ', 'Value': failed}
        data = json.dumps(response).encode()
        self.send_response(200 if not failed else 202 if stored else 409)
        self.send_header('Content-Type', 'application/dicom+json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path.strip('/')
        query = parse_qs(parsed.query)
        offset = 0 if args.qido_ignores_offset else int(query.get('offset', ['0'])[0])
        entry = {'path': path, 'query': {k: v for k, v in query.items()}, 'rawQuery': parsed.query,
                 'accept': self.headers.get('Accept', ''), 'received': time.time()}
        with lock:
            served.append(entry)
        # Record as it happens: a record that needs a clean shutdown is a record
        # that can be lost.
        write_record()
        wado = 'multipart/related' in (self.headers.get('Accept') or '')
        if not wado and re.fullmatch(r'studies(/[0-9.]+/series(/[0-9.]+/instances)?)?', path) and self.busy_first('qido'):
            return

        if path == 'studies' and not wado:
            return self.json([] if offset else study_records(query))
        series_listing = re.fullmatch(r'studies/([0-9.]+)/series', path)
        listing = re.fullmatch(r'studies/([0-9.]+)/series/([0-9.]+)/instances', path)
        refusal = args.listing_status if series_listing else (args.instance_listing_status or args.listing_status) if listing else 0
        if refusal and not wado:
            with lock:
                entry['status'] = refusal
            write_record()
            self.send_response(refusal)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if series_listing and not wado:
            study = find_study(series_listing.group(1))
            return self.json([] if offset or not study else series_records(study))
        if listing and not wado:
            if args.listing_delay > 0 and not offset:
                time.sleep(args.listing_delay)
            study = find_study(listing.group(1))
            records = instance_records(study, listing.group(2)) if study else []
            if args.listing_cap:
                return self.json(records[offset:offset + args.listing_cap])
            return self.json([] if offset else records)
        failing = instance_failures()
        whole = re.fullmatch(r'studies/([0-9.]+)', path)
        study = find_study(whole.group(1)) if whole and wado else None
        if study and (len(studies) > 1 or whole.group(1) == study_uid):
            return self.multipart([item for item in study['instances'] if item['sop'] not in failing])
        one = re.fullmatch(r'studies/([0-9.]+)/series/([0-9.]+)(?:/instances/([0-9.]+))?', path)
        study = find_study(one.group(1)) if one and wado else None
        if study and (len(studies) > 1 or one.group(1) == study_uid):
            wanted = [item for item in study['instances'] if item['series'] == one.group(2) and one.group(3) in (None, item['sop'])]
            if one.group(3) and one.group(3) in failing:
                status, count = failing[one.group(3)]
                with lock:
                    done = failures_served.get(one.group(3), 0)
                    fail = count < 0 or done < count
                    if fail:
                        failures_served[one.group(3)] = done + 1
                        served.append({'path': 'instance-failure', 'sop': one.group(3), 'status': status, 'at': time.time()})
                if fail:
                    write_record()
                    self.send_response(status)
                    self.send_header('Content-Length', '0')
                    self.end_headers()
                    return
            elif not one.group(3):
                wanted = [item for item in wanted if item['sop'] not in failing]
            if wanted:
                return self.multipart(wanted)
        self.send_response(404)
        self.send_header('Content-Length', '0')
        self.end_headers()


server = ThreadingLocalHTTPServer((args.bind_address, args.port), Handler)
record = args.evidence / 'dicomweb-fixture.json'


def stop(*_):
    write_record()
    threading.Thread(target=server.shutdown, daemon=True).start()


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
write_record()
print(json.dumps({'port': args.port, 'studyInstanceUID': study_uid, 'seriesInstanceUID': series_uid, 'seriesInstanceUIDs': series_uids,
                  'instances': len(instances), 'record': str(record),
                  'studyInstanceUIDs': [study['uid'] for study in studies]}))
try:
    server.serve_forever()
finally:
    write_record()
