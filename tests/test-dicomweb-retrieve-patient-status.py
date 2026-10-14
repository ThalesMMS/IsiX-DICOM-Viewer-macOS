#!/usr/bin/env python3
"""A DICOMweb retrieve's activity row names the patient, not a count.

The row's status read "DICOMweb: N objects queued for import" for the whole
retrieve, replacing the patient the query window had put there, while the
count was already in the row's details (n/total). move: now keeps the
patient's name, from the study the node or its series belongs to, shows it
as soon as the retrieve starts, and retrieveDICOMweb keeps it as the status
of every object it queues, with the node's window of requests in the
automatic mode. A node with no patient name keeps the count.
"""
import re
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
source = (root / 'Horos/Sources/DCMTKQueryNode.mm').read_text(encoding='utf-8')
failures = []

move = source[source.index('- (void) move:'):]
start = move.find('_retrievePatient = [[[studyNode.name stringByReplacingOccurrencesOfString:@"^" withString:@" "]')
call = move.find('reportedDICOMwebFailure = ![self retrieveDICOMweb];')
if not 0 <= start < call:
    failures.append('move: does not keep the patient of the study before the DICOMweb retrieve')
elif 'if (_retrievePatient.length) NSThread.currentThread.status = _retrievePatient;' not in move[start:call]:
    failures.append('move: does not show the patient as the retrieve starts')

retrieve = source[source.index('- (BOOL)retrieveDICOMweb'):]
retrieve = retrieve[:retrieve.index('\n- (')]
named = re.search(r'if \(patient\.length\) status = window \? \[NSString stringWithFormat:NSLocalizedString\(@"%@, %ld of %ld requests at once \(automatic\)", nil\),\s*patient, \(long\)window, \(long\)limit\] : patient;', retrieve)
if not named:
    failures.append('an object queued does not keep the patient as the status')
if 'if (![thread.status isEqualToString:status]) [thread setStatus:status];' not in retrieve:
    failures.append('the status is set again for every object even when it has not changed')
if 'NSString *_retrievePatient;' not in (root / 'Horos/Sources/DCMTKQueryNode.h').read_text(encoding='utf-8'):
    failures.append('DCMTKQueryNode has no _retrievePatient')
if '[_retrievePatient release];' not in source[source.index('- (void)dealloc'):]:
    failures.append('dealloc does not release _retrievePatient')

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('PASS: a DICOMweb retrieve shows the patient as its status from start to end')
