#!/usr/bin/env python3
"""tools/serve-dicomweb-fixture.py serves large studies, at small sizes.

- Hundreds of instances: --instances 512 starts, and the Pixel Data of every
  instance is distinct and holds the expected gradient, with no int16
  overflow on the way (the plain index * 200 used to overflow at 164).
- Responses past one write: a WADO-RS response is streamed from the instance
  files in writes of at most --write-block bytes, with a Content-Length that
  matches what arrives, both straight and with --part-delay, which keeps its
  per-part record. A reduced block stands for the 2 GiB a single socket write
  cannot carry on macOS.
- --refuse-syntax: 406 to an Accept that asks first for that syntax, recorded;
  the same study asked again for Explicit VR Little Endian arrives whole, each
  part typed with it.

Needs a Python with pydicom and numpy for the fixture; without one it exits 2.
"""
import http.client
import json
import select
import socket
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
import python_with  # noqa: E402

python_with.require('import pydicom', 'import numpy')

failures = []


def check(ok, message):
    if not ok:
        failures.append(message)
        print('FAIL: ' + message)


def free_port():
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        return probe.getsockname()[1]


def start(folder, name, *options):
    port = free_port()
    server = subprocess.Popen([sys.executable, '-u', str(ROOT / 'tools/serve-dicomweb-fixture.py'),
                               str(folder / name / 'fixture'), str(folder / name / 'evidence'),
                               '--port', str(port), *options],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    ready, _, _ = select.select([server.stdout], [], [], 120)
    line = server.stdout.readline() if ready else ''
    if not line.startswith('{'):
        server.kill()
        error = server.communicate(timeout=10)[1]
        check(False, f'the {name} fixture started: {line}{error[-2000:]}')
        return None, None, None
    return server, port, json.loads(line)


def retrieve(port, path, accept='multipart/related; type="application/dicom"', headers=None):
    """The WADO-RS response's Content-Length and its parts' payloads; `headers`
    collects each part's headers."""
    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=60)
    connection.request('GET', '/' + path, headers={'Accept': accept})
    response = connection.getresponse()
    body = response.read()
    connection.close()
    boundary = response.getheader('Content-Type', '').rpartition('boundary=')[2].encode()
    parts = []
    for chunk in body.split(b'--' + boundary)[1:]:
        if chunk.startswith(b'--'):
            break
        head, _, payload = chunk.partition(b'\r\n\r\n')
        if headers is not None:
            headers.append(head.strip().decode())
        parts.append(payload[:-2])
    return response.status, int(response.getheader('Content-Length', '-1')), len(body), parts


def record_when(path, ready):
    """The fixture's record once ready(record) holds: it is written after the last byte is sent."""
    deadline = time.time() + 10
    while True:
        try:
            record = json.loads(path.read_text())
        except (OSError, ValueError):
            record = None
        if (record and ready(record)) or time.time() > deadline:
            return record or {'requests': [], 'maxWADOWrite': 0}
        time.sleep(0.1)


def stop(server):
    server.terminate()
    try:
        server.wait(timeout=10)
    except subprocess.TimeoutExpired:
        server.kill()
        server.wait(timeout=10)


with tempfile.TemporaryDirectory(prefix='horos-dicomweb-fixture-large-') as folder:
    folder = Path(folder)

    # 512 instances of 8x8, in writes of 100 bytes.
    server, port, started = start(folder, 'many', '--instances', '512', '--rows', '8', '--columns', '8',
                                  '--write-block', '100')
    if server:
        try:
            status, length, received, parts = retrieve(port, 'studies/' + started['studyInstanceUID'])
            check(status == 200 and length == received, f'the study arrives whole: {status}, {length} announced, {received} received')
            check(len(parts) == 512, f'512 parts arrive, not {len(parts)}')
            files = sorted((folder / 'many' / 'fixture').iterdir())
            check([part for part in parts] == [path.read_bytes() for path in files], 'each part is its instance file, in order')
            # Pixel Data is the last element: 64 int16 values.
            pixels = [struct.unpack('<64h', part[-128:]) for part in parts]
            check(len(set(pixels)) == 512, 'every instance has its own pixels')
            expected = [index * 200 % 30000 + index * 200 // 30000 + 1000 for index in range(512)]
            check([values[-1] for values in pixels] == expected and all(min(values[8:]) >= 0 for values in pixels),
                  'the gradient of each instance ends at its offset plus 1000, none wrapped negative')
            record = record_when(folder / 'many' / 'evidence' / 'dicomweb-fixture.json', lambda record: record['maxWADOWrite'])
            check(0 < record['maxWADOWrite'] <= 100, f'no write above the block: {record["maxWADOWrite"]}')
        finally:
            stop(server)

    # Two series of 64x64 with --part-delay, in writes of 1000 bytes.
    server, port, started = start(folder, 'delayed', '--series-sizes', '3,3', '--write-block', '1000',
                                  '--part-delay', '0.02')
    if server:
        try:
            status, length, received, parts = retrieve(port, 'studies/' + started['studyInstanceUID'])
            files = sorted((folder / 'delayed' / 'fixture').iterdir())
            check(status == 200 and length == received and parts == [path.read_bytes() for path in files],
                  f'the delayed study arrives whole: {status}, {length} announced, {received} received, {len(parts)} parts')
            status, length, received, parts = retrieve(
                port, 'studies/%s/series/%s' % (started['studyInstanceUID'], started['seriesInstanceUIDs'][1]))
            check(status == 200 and length == received and parts == [path.read_bytes() for path in files[3:]],
                  f'the second series arrives whole: {status}, {length} announced, {received} received, {len(parts)} parts')
            record = record_when(folder / 'delayed' / 'evidence' / 'dicomweb-fixture.json',
                                 lambda record: sum(entry['path'] == 'multipart-timing' for entry in record['requests']) == 2)
            timings = [entry for entry in record['requests'] if entry['path'] == 'multipart-timing']
            check([len(entry['partsSent']) for entry in timings] == [6, 3], 'each part sent is recorded')
            check(0 < record['maxWADOWrite'] <= 1000, f'no write above the block: {record["maxWADOWrite"]}')
        finally:
            stop(server)

    # A server that cannot convert to JPEG 2000 Lossless.
    server, port, started = start(folder, 'refusing', '--instances', '2', '--rows', '8', '--columns', '8',
                                  '--refuse-syntax', '1.2.840.10008.1.2.4.90')
    if server:
        try:
            study = 'studies/' + started['studyInstanceUID']
            wado = 'multipart/related; type="application/dicom"; transfer-syntax='
            status, _, _, parts = retrieve(port, study, wado + '1.2.840.10008.1.2.4.90, ' + wado + '1.2.840.10008.1.2.1; q=0.9')
            check(status == 406 and not parts, f'JPEG 2000 asked first is refused: {status}')
            headers = []
            status, length, received, parts = retrieve(port, study, wado + '1.2.840.10008.1.2.1', headers)
            files = sorted((folder / 'refusing' / 'fixture').iterdir())
            check(status == 200 and length == received and parts == [path.read_bytes() for path in files],
                  f'Explicit VR Little Endian arrives whole: {status}, {length} announced, {received} received')
            check(headers == ['Content-Type: application/dicom; transfer-syntax=1.2.840.10008.1.2.1'] * 2,
                  f'each part is typed with its syntax: {headers}')
            record = record_when(folder / 'refusing' / 'evidence' / 'dicomweb-fixture.json',
                                 lambda record: any(entry['path'] == 'refused-syntax' for entry in record['requests']))
            check([entry['status'] for entry in record['requests'] if entry['path'] == 'refused-syntax'] == [406],
                  'the refusal is recorded')
        finally:
            stop(server)

    source = (ROOT / 'tools/serve-dicomweb-fixture.py').read_text()
    sender = source[source.find('    def send_multipart'):source.find('    def do_POST')]
    check('read_bytes' not in sender and 'handle.read(args.write_block)' in sender,
          'the response is read from the files a block at a time, not held whole')

if failures:
    print(f'FAIL: {len(failures)} check(s) failed')
    sys.exit(1)
print('PASS: 512 distinct instances, WADO-RS streamed in bounded writes with and without a part delay, 406 to a refused syntax')
