#!/usr/bin/env python3
"""Serve a synthetic study over loopback C-FIND and WADO, for native retrieve tests.

A WADO retrieval in Horos is a C-FIND at IMAGE level followed by one HTTP GET per
instance, so exercising it needs both halves. This provides them over loopback
against data it generates itself, and records what was asked for.
"""
import argparse
import copy
import hashlib
import io
import json
import threading
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from pydicom import dcmread
from pydicom.dataset import Dataset, FileMetaDataset
from pydicom.uid import CTImageStorage, ExplicitVRLittleEndian, generate_uid
from pynetdicom import AE, evt
from pynetdicom.sop_class import Verification
from pynetdicom.sop_class import StudyRootQueryRetrieveInformationModelFind as FIND
# Run as tools/serve-wado-fixture.py: this folder is already on the path.
from local_http import ThreadingLocalHTTPServer

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('fixture', type=Path, help='directory for the generated study')
parser.add_argument('evidence', type=Path, help='directory for the result file')
parser.add_argument('--dicom-port', type=int, default=11121)
parser.add_argument('--wado-port', type=int, default=11122)
parser.add_argument('--aetitle', default='WADOFIX')
parser.add_argument('--series', type=int, default=2)
parser.add_argument('--instances', type=int, default=4, help='instances per series')
parser.add_argument('--odd-length-series-uids', action='store_true', help='exercise DICOM UI NUL padding')
parser.add_argument('--strict', action='store_true',
                    help='answer only hierarchical queries, refusing relational ones')
parser.add_argument('--refuse-instances', type=int, default=0,
                    help='refuse this many instances over WADO, to leave a retrieval incomplete')
parser.add_argument('--truncate-instances', type=int, default=0,
                    help='answer this many instances with the first half of the file and a '
                         'matching Content-Length - a transfer that succeeds and delivers a '
                         'file that is not whole')
parser.add_argument('--truncate-to-bytes', type=int, default=0,
                    help='with --truncate-instances, keep this many bytes instead of half the '
                         'file; below 132 the reply has no DICOM magic at all')
parser.add_argument('--find-delay', type=float, default=0.0,
                    help='seconds to wait before answering each IMAGE level C-FIND, so a '
                         'retrieval starts downloading while the query is still running')
parser.add_argument('--fail-once', type=int, default=0,
                    help='answer 503 to this many instances the first time each is asked for, '
                         'and serve them on any later request - a transient failure')
parser.add_argument('--http-delay', type=float, default=0, help='delay responses after instance 1 for cancellation tests')
parser.add_argument('--repair-flag', type=Path, help='stop refusing configured instances when this file exists')
parser.add_argument('--negotiate-transfer-syntax', choices=('dcm4chee', 'legacy-useOrig', 'refuse-wildcard'),
                    help='fixture negotiation: wildcard/stored/Explicit LE, a legacy '
                         'endpoint that ignores transferSyntax and honors useOrig, or one '
                         'that answers 404 to transferSyntax=* and otherwise behaves as the '
                         'legacy one; unsupported syntax returns 406 (not a PACS emulator)')
parser.add_argument('--tls-cert', type=Path,
                    help='serve WADO over https with this PEM certificate (with --tls-key); '
                         'a self-signed one exercises the refusal of an untrusted server')
parser.add_argument('--tls-key', type=Path, help='PEM private key for --tls-cert')
parser.add_argument('--basic-credentials', type=Path,
                    help='demand Authorization: Basic for these credentials: a file holding '
                         'username:password on its first line, UTF-8, so they stay off the '
                         'command line; any other request is answered 401')
args = parser.parse_args()
expected_authorization = None
if args.basic_credentials:
    import base64
    pair = args.basic_credentials.read_text(encoding='utf-8').splitlines()[0]
    if ':' not in pair:
        parser.error('--basic-credentials needs username:password')
    expected_authorization = 'Basic ' + base64.b64encode(pair.encode('utf-8')).decode('ascii')
for port in (args.dicom_port, args.wado_port):
    if port != 0 and not 1024 <= port <= 65535:
        parser.error('Use unprivileged ports, or 0 for automatic allocation')
if not 1 <= args.series <= 20 or not 1 <= args.instances <= 200:
    parser.error('Keep the fixture small')

args.fixture.mkdir(parents=True, exist_ok=True)
if not any(args.fixture.glob('*.dcm')):
    study = generate_uid()
    for series_number in range(1, args.series + 1):
        series = generate_uid()
        if args.odd_length_series_uids and len(series) % 2 == 0:
            series = series[:-1]
        for instance in range(1, args.instances + 1):
            ds = Dataset()
            ds.file_meta = FileMetaDataset()
            ds.file_meta.TransferSyntaxUID = ExplicitVRLittleEndian
            ds.SOPClassUID = CTImageStorage
            ds.SOPInstanceUID = generate_uid()
            ds.StudyInstanceUID = study
            ds.SeriesInstanceUID = series
            ds.PatientName = 'QA^WADO'
            ds.PatientID = 'LOCAL-WADO'
            ds.StudyDate = '20260909'
            ds.StudyTime = '120000'
            ds.StudyID = 'WADO'
            ds.StudyDescription = 'Synthetic WADO retrieve'
            ds.SeriesDescription = 'Synthetic series %d' % series_number
            ds.SeriesNumber = series_number
            ds.InstanceNumber = instance
            ds.Modality = 'CT'
            ds.Rows = ds.Columns = 16
            ds.SamplesPerPixel = 1
            ds.PhotometricInterpretation = 'MONOCHROME2'
            ds.BitsAllocated = ds.BitsStored = 16
            ds.HighBit = 15
            ds.PixelRepresentation = 0
            ds.PixelSpacing = [1, 1]
            ds.ImageOrientationPatient = [1, 0, 0, 0, 1, 0]
            ds.ImagePositionPatient = [0, 0, instance]
            ds.SliceThickness = 1
            # A per-instance pattern, so a mixed-up download is visible.
            base = series_number * 1000 + instance
            ds.PixelData = b''.join(((base + n) % 4096).to_bytes(2, 'little') for n in range(256))
            ds.save_as(args.fixture / ('%d-%03d.dcm' % (series_number, instance)),
                       enforce_file_format=True)

images = [dcmread(path) for path in sorted(args.fixture.glob('*.dcm'))]
assert images
by_instance = {str(ds.SOPInstanceUID): (path, ds) for path, ds
               in zip(sorted(args.fixture.glob('*.dcm')), images)}
# Opt in so existing transport/cancellation fixtures retain their behavior.
representations = {}
if args.negotiate_transfer_syntax:
    for uid, (path, ds) in by_instance.items():
        stored = path.read_bytes()
        explicit = copy.deepcopy(ds)
        if explicit.file_meta.TransferSyntaxUID.is_compressed:
            explicit.decompress(generate_instance_uid=False)
        explicit.file_meta.TransferSyntaxUID = ExplicitVRLittleEndian
        stream = io.BytesIO()
        explicit.save_as(stream, enforce_file_format=True)
        representations[uid] = (stored, stream.getvalue(), str(ds.file_meta.TransferSyntaxUID))

if not 0 <= args.refuse_instances < len(images):
    parser.error('Refuse fewer instances than the study holds')
# Named up front so the evidence says which ones a complete retrieval is missing.
refused_instances = sorted(by_instance)[:args.refuse_instances]
# Taken from the other end, so the two sets do not overlap.
if not 0 <= args.fail_once <= len(images) - args.refuse_instances:
    parser.error('Fail fewer instances than the study holds outside the refused ones')
transient_instances = sorted(by_instance)[len(by_instance) - args.fail_once:] if args.fail_once else []
already_failed = set()
# Taken from the front, after the refused ones, so the three sets do not overlap.
if not 0 <= args.truncate_instances <= len(images) - args.refuse_instances - args.fail_once:
    parser.error('Truncate fewer instances than the study holds outside the other kinds')
truncated_instances = sorted(by_instance)[args.refuse_instances:
                                          args.refuse_instances + args.truncate_instances]

args.evidence.mkdir(parents=True, exist_ok=True)
state = {'aetitle': args.aetitle, 'dicom_port': args.dicom_port, 'wado_port': args.wado_port,
         'strict': bool(args.strict), 'study': str(images[0].StudyInstanceUID),
         'expected': len(images), 'series': len({str(ds.SeriesInstanceUID) for ds in images}),
         'refused_instances': refused_instances,
         'transient_instances': transient_instances,
         'truncated_instances': truncated_instances,
         'find': [], 'wado': [], 'refused': [], 'relational': [], 'transient': [],
         'truncated': [], 'unauthorized': [], 'basic': bool(expected_authorization), 'ready': False}
lock = threading.Lock()


def save():
    with lock:
        temporary = args.evidence / 'wado-results.json.tmp'
        temporary.write_text(json.dumps(state, indent=2) + '\n')
        temporary.replace(args.evidence / 'wado-results.json')


save()


def matches(query, ds):
    for key in ('StudyInstanceUID', 'SeriesInstanceUID', 'SOPInstanceUID', 'PatientID'):
        value = str(getattr(query, key, '') or '')
        if value and value != str(getattr(ds, key, '')):
            return False
    return True


def handle_find(event):
    query = event.identifier
    level = str(getattr(query, 'QueryRetrieveLevel', '') or '')
    study = str(getattr(query, 'StudyInstanceUID', '') or '')
    series = str(getattr(query, 'SeriesInstanceUID', '') or '')
    with lock:
        state['find'].append({'level': level, 'study': study, 'series': series})
    save()
    if args.find_delay > 0 and level == 'IMAGE':
        time.sleep(min(args.find_delay, 30))
    # A hierarchical C-FIND carries the unique key of every level above the one
    # it asks for. Without them the query is relational, which is optional and
    # negotiated; a strictly hierarchical SCP refuses it. 0xA900 is
    # Identifier Does Not Match SOP Class, which is what such an SCP answers.
    if args.strict:
        missing = (level == 'IMAGE' and not series) or (level in ('IMAGE', 'SERIES') and not study)
        if missing:
            with lock:
                state['relational'].append({'level': level, 'study': study, 'series': series})
            save()
            yield 0xA900, None
            return
    seen = set()
    for ds in images:
        if not matches(query, ds):
            continue
        answer = Dataset()
        answer.QueryRetrieveLevel = level
        answer.StudyInstanceUID = ds.StudyInstanceUID
        if level == 'STUDY':
            key = str(ds.StudyInstanceUID)
            answer.PatientID = ds.PatientID
            answer.PatientName = ds.PatientName
            answer.StudyDate = ds.StudyDate
            answer.StudyTime = ds.StudyTime
            answer.StudyDescription = ds.StudyDescription
            answer.ModalitiesInStudy = 'CT'
            answer.NumberOfStudyRelatedInstances = len(images)
        elif level == 'SERIES':
            key = str(ds.SeriesInstanceUID)
            answer.SeriesInstanceUID = ds.SeriesInstanceUID
            answer.SeriesDescription = ds.SeriesDescription
            answer.SeriesNumber = ds.SeriesNumber
            answer.Modality = ds.Modality
            answer.NumberOfSeriesRelatedInstances = sum(
                1 for other in images if other.SeriesInstanceUID == ds.SeriesInstanceUID)
        else:
            key = str(ds.SOPInstanceUID)
            answer.SeriesInstanceUID = ds.SeriesInstanceUID
            answer.SOPInstanceUID = ds.SOPInstanceUID
            answer.InstanceNumber = ds.InstanceNumber
        if key in seen:
            continue
        seen.add(key)
        yield 0xFF00, answer
    yield 0x0000, None


class WADOHandler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def do_GET(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        request_type = (query.get('requestType') or [''])[0]
        instance = (query.get('objectUID') or [''])[0]
        record = {'path': parsed.path, 'requestType': request_type, 'objectUID': instance,
                  'studyUID': (query.get('studyUID') or [''])[0],
                  'seriesUID': (query.get('seriesUID') or [''])[0],
                  'contentType': (query.get('contentType') or [''])[0],
                  'transferSyntax': (query.get('transferSyntax') or [''])[0],
                  'useOrig': (query.get('useOrig') or [''])[0]}
        if expected_authorization:
            # Whether the request carried the credential, never the credential itself.
            supplied = self.headers.get('Authorization')
            record['authorization'] = 'none' if supplied is None else (
                'basic-ok' if supplied == expected_authorization else 'wrong')
            if record['authorization'] != 'basic-ok':
                with lock:
                    state['unauthorized'].append(record)
                save()
                self.send_response(401)
                self.send_header('WWW-Authenticate', 'Basic realm="WADO fixture"')
                self.send_header('Content-Length', '0')
                self.end_headers()
                return
        if request_type != 'WADO' or instance not in by_instance or instance in refused_instances and not (args.repair_flag and args.repair_flag.exists()):
            with lock:
                state['refused'].append(record)
            save()
            self.send_response(404)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        # A failure the client should recover from by asking again: 503 once,
        # then the instance. 404 above is the other kind, and asking again for
        # one of those is wasted work.
        with lock:
            transient = instance in transient_instances and instance not in already_failed
            if transient:
                already_failed.add(instance)
                state['transient'].append(record)
        if transient:
            save()
            self.send_response(503)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        with lock:
            state.setdefault('httpStarted', []).append({'objectUID': instance, 'time': time.monotonic()})
        save()
        if args.http_delay and int(by_instance[instance][1].InstanceNumber) > 1:
            time.sleep(min(args.http_delay, 60))
        body = by_instance[instance][0].read_bytes()
        actual_syntax = str(by_instance[instance][1].file_meta.TransferSyntaxUID)
        if args.negotiate_transfer_syntax:
            stored, explicit, stored_syntax = representations[instance]
            selected = record['transferSyntax']
            if args.negotiate_transfer_syntax == 'refuse-wildcard' and selected == '*':
                record.update(status=404, responseContentType='text/plain')
                with lock:
                    state['refused'].append(record)
                save()
                self.send_response(404)
                self.send_header('Content-Length', '0')
                self.end_headers()
                return
            if args.negotiate_transfer_syntax in ('legacy-useOrig', 'refuse-wildcard'):
                selected = '*' if record['useOrig'] == 'true' else str(ExplicitVRLittleEndian)
            if selected in ('*', stored_syntax):
                body, actual_syntax = stored, stored_syntax
            elif selected in ('', str(ExplicitVRLittleEndian)):
                body, actual_syntax = explicit, str(ExplicitVRLittleEndian)
            else:
                record.update(status=406, responseContentType='text/plain')
                with lock:
                    state['refused'].append(record)
                save()
                error = b'Unsupported transfer syntax in negotiation fixture'
                self.send_response(406)
                self.send_header('Content-Type', 'text/plain')
                self.send_header('Content-Length', str(len(error)))
                self.end_headers()
                self.wfile.write(error)
                return
        record.update(status=200, responseContentType='application/dicom',
                      responseTransferSyntax=actual_syntax, bytes=len(body),
                      bodySHA256=hashlib.sha256(body).hexdigest())
        if instance in truncated_instances:
            # Half a file, delivered as if it were whole. The transfer succeeds;
            # what arrives is not a readable DICOM object.
            body = body[:args.truncate_to_bytes] if args.truncate_to_bytes else body[:len(body) // 2]
            record['bytes'] = len(body)
            with lock:
                state['truncated'].append(record)
        else:
            with lock:
                state['wado'].append(record)
        save()
        self.send_response(200)
        self.send_header('Content-Type', 'application/dicom')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


wado = ThreadingLocalHTTPServer(('127.0.0.1', args.wado_port), WADOHandler)
if args.tls_cert:
    import ssl
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(args.tls_cert, args.tls_key)
    wado.socket = context.wrap_socket(wado.socket, server_side=True)
    state['tls'] = True
threading.Thread(target=wado.serve_forever, daemon=True).start()

ae = AE(ae_title=args.aetitle)
ae.add_supported_context(Verification)
ae.add_supported_context(FIND)
server = None
try:
    server = ae.start_server(('127.0.0.1', args.dicom_port), block=False,
                             evt_handlers=[(evt.EVT_C_FIND, handle_find)])
    # Port 0 lets the kernel allocate independent ports for concurrent tests.
    # Publish readiness only after both listeners have successfully bound.
    with lock:
        state['dicom_port'] = server.server_address[1]
        state['wado_port'] = wado.server_address[1]
        state['ready'] = True
    save()
    print('C-FIND on %d, WADO on %d, study %s, %d instances'
          % (state['dicom_port'], state['wado_port'], state['study'], len(images)), flush=True)
    threading.Event().wait()
except KeyboardInterrupt:
    pass
finally:
    if server is not None:
        server.shutdown()
    wado.shutdown()
    wado.server_close()
    with lock:
        state['ready'] = False
    save()
