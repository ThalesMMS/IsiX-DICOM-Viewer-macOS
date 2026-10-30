#!/usr/bin/env python3
"""A DICOMweb retrieve from a node that counts no instances still gets a bar.

The total of a DICOMweb retrieve was the NumberOfStudyRelatedInstances (or
NumberOfSeriesRelatedInstances) of the search result, and the activity's bar
follows the count only with a total. A node that leaves those counts out left
the bar indeterminate, moving from side to side, until the last object, though
the listing made beside the transfer names every instance well before.

In the sources, retrieveDICOMweb takes the total from the series' counts as
soon as the series are listed, when the study search gave none: a listing as
slow as the transfer, or one that fails, left the bar indeterminate to the end.
Then it takes the total from the listing once it has ended, in place of that: before it waits for the requests, of
what this retrieve asks for (what the rules leave out is not asked for), and
only from a listing that succeeded. The count of each object and that total
are shown under one lock, so a count shown late never replaces a newer one.

Over loopback, the fixture's --omit-instance-counts answers as such a node:
the study and series results carry no count, and the listings still name
every instance.

Needs a Python with pydicom and numpy for the fixture; without one it exits 2.
"""
import http.client
import json
import re
import select
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
import python_with  # noqa: E402

failures = []


def check(ok, message):
    if not ok:
        failures.append(message)
        print('FAIL: ' + message)


# The node is Swift; its DICOMweb retrieve, and the session that counts each
# object, are in DCMTKQueryNode+DICOMweb.swift.
source = (ROOT / 'Horos/Sources/DCMTKQueryNode+DICOMweb.swift').read_text()
start = source.index('func retrieveDICOMweb() -> Bool')
retrieve = source[start:source.index('\n    }\n', start)]
ended = retrieve.find('while !listing.isFinished')
drained = retrieve.find('session.drain()', ended)
check(0 < ended < drained, 'retrieveDICOMweb no longer waits for the listing before the requests')
between = retrieve[ended:drained]
check('countOfSuboperations == 0' in between, 'the total is not taken from the listing when the search gave none')
check('$0.succeeded' in between and 'listedAll && total > 0' in between, 'a listing that failed gives the total')
check('isExcluded(series:' in between and 'asked.count' in between, 'the total is not what this retrieve asks for')
check(re.search(r'ActivityProgressCount\.set\(done: Int\(countOfSuccessfulSuboperations\), total: total, setsProgress: true', between),
      'the bar is not given the total as soon as the listing has ended')
shown = [match.start() for match in re.finditer(r'ActivityProgressCount\.set\(done:', source)]
check(len(shown) == 3, f'the DICOMweb retrieve shows its count in {len(shown)} places, not 3')
early = retrieve[retrieve.find('var counted = false'):ended]
check(re.search(r'if whole && !counted && countOfSuboperations == 0, let plan, plan\.countedInstances > 0', early)
      and 'countOfSuboperations = UInt(plan.countedInstances)' in early,
      'the total is not taken from the series counts before the instances are listed')
check('(countOfSuboperations == 0 || counted)' in between, 'the listing does not replace the series counts')
for at in shown:
    check('synchronized {' in source[max(0, at - 400):at], 'a count is shown outside the lock of the count')

python_with.require('import pydicom', 'import numpy')


def free_port():
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        return probe.getsockname()[1]


def results(port, path):
    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=20)
    connection.request('GET', path, headers={'Accept': 'application/dicom+json'})
    response = connection.getresponse()
    body = response.read()
    connection.close()
    return json.loads(body) if response.status == 200 else None


with tempfile.TemporaryDirectory(prefix='horos-dicomweb-total-') as folder:
    for options, counted in (([], True), (['--omit-instance-counts'], False)):
        port = free_port()
        name = 'counted' if counted else 'uncounted'
        server = subprocess.Popen([sys.executable, '-u', str(ROOT / 'tools/serve-dicomweb-fixture.py'),
                                   str(Path(folder) / name / 'fixture'), str(Path(folder) / name / 'evidence'),
                                   '--port', str(port), '--instances', '5', '--series', '2', *options],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            ready, _, _ = select.select([server.stdout], [], [], 120)
            line = server.stdout.readline() if ready else ''
            check(line.startswith('{'), f'{name}: the fixture did not start')
            if not line.startswith('{'):
                continue
            study = json.loads(line)['studyInstanceUID']
            studies = results(port, '/studies') or []
            series = results(port, f'/studies/{study}/series') or []
            instances = [instance for record in series
                         for instance in results(port, f"/studies/{study}/series/{record['0020000E']['Value'][0]}/instances") or []]
            check(len(studies) == 1 and len(series) == 2, f'{name}: {len(studies)} studies, {len(series)} series')
            check(all(('00201208' in record) == counted for record in studies), f'{name}: NumberOfStudyRelatedInstances in the study result')
            check(all(('00201209' in record) == counted for record in series), f'{name}: NumberOfSeriesRelatedInstances in the series results')
            check(len(instances) == 5, f'{name}: the listing names {len(instances)} instances, not 5')
        finally:
            server.terminate()
            server.wait(timeout=10)

if failures:
    sys.exit(1)
print('ok: the retrieve takes its total from the listing when the search counts nothing')
