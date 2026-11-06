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
sys.path.insert(0, str(Path(__file__).resolve().parent))
import sources  # noqa: E402
# The node is Swift; its DIMSE callbacks are in the DCMTK adapter.
node = sources.class_text('DCMTKQueryNode')
code = re.sub(r'//[^\n]*', '', node)
adapter = re.sub(r'//[^\n]*', '', (root / 'Horos/Sources/Adapters/DCMTK/IsiXDCMTKQueryRetrieveSCU.mm').read_text())


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
for filename, operation in (('IsiXDCMTKMoveUser.mm', 'move'), ('IsiXDCMTKGetUser.mm', 'get')):
    transport = (root / 'Horos/Sources/Adapters/DCMTK' / filename).read_text(encoding='latin1')
    loop = body('HorosDIMSE' + operation.title() + 'User(', transport)
    for required in ('DIMSE_sendCancelRequest', 'isCancelled', '!cancelSent',
                     'cancelDeadline', 'systemUptime', 'cancellation response timed out'):
        if required not in loop:
            failures.append(filename + ' lacks ' + required)
    if loop.count('DIMSE_sendCancelRequest') != 1:
        failures.append(filename + ' has multiple cancel send sites')
    if not (loop.find('const int readable = selectReadable(') < loop.find('DIMSE_sendCancelRequest') < loop.find('DIMSE_receiveCommand')):
        failures.append(filename + ' loses cancellation arriving during its readiness wait')
    callback = body('IsiXDCMTK' + operation.title() + 'Callback(void *data', adapter)
    if 'cancelIfAsked' in callback or 'DIMSE_sendCancelRequest' in callback:
        failures.append(operation + ' callback duplicates the transport cancel')
    if 'IsiXDCMTKReportProgress(data, response)' not in callback:
        failures.append(operation + ' callback lost progress')
    scu = body('private func ' + operation + 'SCU(on association:', code)
    if 'reportRetrieveProgress(&progress' not in scu:
        failures.append(operation + ' no longer shows the progress the callback reports')
if 'DIMSE_sendCancelRequest' in body('static void IsiXDCMTKReportProgress(', adapter):
    failures.append('the progress callback duplicates the transport cancel')

progress = body('static func reportProgress(', code)
rules = (root / 'Modules/IsiXDICOMNetwork/Sources/RetrieveRules.swift').read_text()
if 'RetrieveProgress.fraction(accounted: accounted, finished: finished)' not in progress:
    failures.append('the progress computation is gone')
elif 'accounted > 0 ?' not in body('public static func fraction(', rules):
    failures.append('a peer that accounts for no sub-operations still divides by zero')

# The listener's C-STORE is the DCMTK adapter's IsiXDCMTKSCPDatabase.mm.
store = (root / 'Horos/Sources/Adapters/DCMTK/IsiXDCMTKSCPDatabase.mm').read_text()
callback = body('storeCallback(', store)
for required in ('isCancelled', 'ASC_closeTransportConnection', '!info->aborted'):
    if required not in callback: failures.append('streaming store cancel lacks ' + required)
if callback.find('ASC_closeTransportConnection') > callback.find('context->callbackHandler'):
    failures.append('cancelled pixels reach publication before cancellation is handled')
report = body('func reportRetrieveCancellation(', code)
for required in ('Thread.current.status = summary', 'Retrieve Cancelled', 'Self.postNotice(', 'RetrieveCompletion.cancellationSummary('):
    if required not in report: failures.append('cancel feedback lacks ' + required)
if 'performSelector(onMainThread:' not in body('static func postNotice(', code):
    failures.append('cancel feedback is not posted on the main thread')

# WADODownload is Swift.
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
