#!/usr/bin/env python3
"""The application C-GET loop stores on its own association with request-local state."""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
failures = []
project = (root / 'Horos.xcodeproj/project.pbxproj').read_text()
receiver = (root / 'Horos/Sources/Adapters/DCMTK/IsiXDCMTKGetUser.mm').read_bytes().decode('latin1')
sys.path.insert(0, str(root / 'tests'))
from sources import class_text  # noqa: E402
node = class_text('DCMTKQueryNode')
adapter = (root / 'Horos/Sources/Adapters/DCMTK/IsiXDCMTKQueryRetrieveSCU.mm').read_text()


def body(signature, source):
    at = source.find(signature)
    if at < 0:
        return ''
    opening = source.index('{', at)
    depth, index = 0, opening
    while index < len(source):
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return source[opening:index + 1]
        index += 1
    return ''


# --- the target compiles the implementation that handles sub-operations -------
if 'IsiXDCMTKGetUser.mm in Sources' not in project:
    failures.append('dimget.mm is not compiled: the C-GET that reaches the network would be '
                    'the unadapted C-MOVE copy in dimget.cc, and every retrieval would fail '
                    'with every instance counted as failed')
if re.search(r'dimget\.cc in Sources', project):
    failures.append('dimget.cc is compiled as well: two definitions of DIMSE_getUser, and which '
                    'one the link picks is not something to leave to chance')

# --- and that implementation really does handle them --------------------------
loop = body('HorosDIMSEGetUser(', receiver)
if not loop:
    failures.append('DIMSE_getUser is gone from dimget.mm')
else:
    if 'DIMSE_C_STORE_RQ' not in loop:
        failures.append('the C-GET loop no longer accepts a C-STORE-RQ on the association, so a '
                        'conformant peer\'s sub-operations are rejected as unexpected responses')
    if 'IsiXDCMTKStoreSCP(assoc,' not in loop or 'mainStoreSCP' in loop:
        failures.append('C-GET must use its own storage context instead of a listener global')
    # The database it stores through is the one the caller gives for this request.
    for setup in ('new IsiXDCMTKSCPDatabaseHandle(storage)', 'storageOptions.dimse_timeout_ = timeout',
                  'storageOptions.blockMode_ = blockMode'):
        if setup not in loop: failures.append('missing per-request storage setup: '+setup)
    if 'storage: { SCPDatabaseSession(callingAETitle: $0) }' not in body('private func getSCU(', node):
        failures.append('the query node does not give the C-GET a database of its own to store in')
    # The loop is the DCMTK adapter's: it calls the caller back, and the query
    # node asks the database to index what arrived.
    if loop.count('incoming(incomingData)') != 2 or \
            'initiateImportFilesFromIncomingDirUnlessAlreadyImporting' not in body('private func getSCU(', node):
        failures.append('nothing asks the database to index what arrived, so a retrieval that '
                        'finished can still show nothing')
    if 'DIMSE_C_GET_RSP' not in loop:
        failures.append('the C-GET responses themselves are no longer read')

# --- a retrieval that loses instances says so ---------------------------------
get = body('private func getSCU(', node)
fill = body('static void IsiXDCMTKFillRetrieveResult(', adapter)
if not get:
    failures.append('getSCU(on:identifier:) is gone')
else:
    if 'NumberOfFailedSubOperations' not in fill or 'failed = UInt(result.failed)' not in get:
        failures.append('the retrieval does not look at the failed sub-operation count, so a '
                        'partial C-GET is reported as a success')
    # The sentence itself lives in RetrieveCompletion, which the C-MOVE path
    # shares; tests/test-cmove-completeness.py holds it to its wording.
    for field in ('RetrieveCompletion(', 'everythingArrived', 'completion.summary'):
        if field not in get:
            failures.append('the incomplete-retrieval message does not go through %s' % field)
    if 'Get Failed' not in get:
        failures.append('an incomplete retrieval is not reported to the user at all')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: the compiled C-GET stores the sub-operations that arrive on its own association and '
      'names what an incomplete retrieval lost')
