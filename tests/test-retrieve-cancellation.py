#!/usr/bin/env python3
"""Guard single-owner DIMSE cancellation, bounded response waiting, streaming
C-GET interruption and the native cancellation feedback route.
Runtime timing and pixel evidence come from the parallel diagnostic probe.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
failures = []
node = (root / 'Horos/Sources/DCMTKQueryNode.mm').read_bytes().decode('latin1')
header = (root / 'Horos/Sources/DCMTKQueryNode.h').read_bytes().decode('latin1')
code = re.sub(r'//[^\n]*', '', node)


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


# Cancellation belongs to each transport invocation: it must work even when
# the peer sends no more pending responses, and cannot be duplicated by callbacks.
for filename, operation in (('HorosDIMSEMove.mm', 'move'), ('HorosDIMSEGet.mm', 'get')):
    transport = (root / 'Horos/Sources' / filename).read_text(encoding='latin1')
    loop = body('HorosDIMSE' + operation.title() + 'User(', transport)
    for required in ('DIMSE_sendCancelRequest', 'isCancelled', '!cancelSent',
                     'cancelDeadline', 'systemUptime', 'cancellation response timed out'):
        if required not in loop:
            failures.append(filename + ' lacks ' + required)
    if loop.count('DIMSE_sendCancelRequest') != 1:
        failures.append(filename + ' has multiple cancel send sites')
    if not (loop.find('const int readable = selectReadable(') < loop.find('DIMSE_sendCancelRequest') < loop.find('DIMSE_receiveCommand')):
        failures.append(filename + ' loses cancellation arriving during its readiness wait')
    callback = body(operation + 'Callback(void *callbackData', code)
    if 'cancelIfAsked' in callback or 'DIMSE_sendCancelRequest' in callback:
        failures.append(operation + ' callback duplicates the transport cancel')
    if 'reportProgress' not in callback:
        failures.append(operation + ' callback lost progress')

progress = body('static void reportProgress(', code)
if not progress:
    failures.append('the progress computation is gone')
elif 'accounted ?' not in progress:
    failures.append('a peer that accounts for no sub-operations still divides by zero')

store = (root / 'Horos/Sources/HorosQueryRetrieveServer.mm').read_text(encoding='latin1')
callback = body('storeCallback(', store)
for required in ('isCancelled', 'ASC_closeTransportConnection', '!info->aborted'):
    if required not in callback: failures.append('streaming store cancel lacks ' + required)
if callback.find('ASC_closeTransportConnection') > callback.find('context->callbackHandler'):
    failures.append('cancelled pixels reach publication before cancellation is handled')
report = body('- (void) reportRetrieveCancellation:', code)
for required in ('setStatus:', 'Retrieve Cancelled', 'performSelectorOnMainThread', 'cancellationSummaryWithOperation'):
    if required not in report: failures.append('cancel feedback lacks ' + required)

# WADODownload is Swift.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import sources
wado = sources.source_text('WADODownload')
if '(self.WADODownloadDictionary?.count ?? 0) >= Int(WADOMaximumConcurrentDownloads)' not in wado:
    failures.append('WADO exceeds its configured concurrent requests')
queue_guard = 'if aborted || self._abortAssociation || Thread.current.isCancelled'
start_task = 'session.dataTask(with:'
if start_task not in wado:
    failures.append('WADO no longer starts its requests as URLSession tasks')
elif queue_guard not in wado or wado.index(queue_guard) > wado.index(start_task):
    failures.append('WADO schedules a request after cancellation')
# Cancelling a pass ends its requests, and what they report afterwards is not
# read: nothing is written after the end.
if 'mailbox.close()' not in wado or 'session.invalidateAndCancel()' not in wado:
    failures.append('WADO leaves the requests of a cancelled pass running')
elif wado.index('mailbox.close()') > wado.index('session.invalidateAndCancel()'):
    failures.append('WADO cancels its requests before it stops reading what they report')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: a cancelled C-MOVE or C-GET sends the peer a C-CANCEL, once, and progress no longer '
      'divides by a count the peer may not have given')
