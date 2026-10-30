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
# The query node is Swift: the move is in DCMTKQueryNode+Retrieve.swift, the
# DICOMweb retrieve and the session that takes each object in +DICOMweb.
move = (root / 'Horos/Sources/DCMTKQueryNode+Retrieve.swift').read_text()
session = (root / 'Horos/Sources/DCMTKQueryNode+DICOMweb.swift').read_text()
failures = []

move = move[move.index('func move(_ dictionary: [AnyHashable: Any]!, retrieveMode: Int32)'):]
start = move.find('retrievePatient = studyNode?.name()?.replacingOccurrences(of: "^", with: " ")')
call = move.find('reportedDICOMwebFailure = !retrieveDICOMweb()')
if not 0 <= start < call:
    failures.append('move does not keep the patient of the study before the DICOMweb retrieve')
elif 'if let patient = retrievePatient, !patient.isEmpty { Thread.current.status = patient }' not in move[start:call]:
    failures.append('move does not show the patient as the retrieve starts')

named = re.search(r'if let patient = node\.retrievePatient, !patient\.isEmpty \{\s*status = window > 0 \? String\(format: NSLocalizedString\("%@, %ld of %ld requests at once \(automatic\)", comment: ""\), patient, window, limit\) : patient', session)
if not named:
    failures.append('an object queued does not keep the patient as the status')
if 'if thread.status != status { thread.status = status }' not in session:
    failures.append('the status is set again for every object even when it has not changed')
if 'var retrievePatient: String?' not in (root / 'Horos/Sources/DCMTKQueryNode.swift').read_text():
    failures.append('DCMTKQueryNode has no retrievePatient')

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('PASS: a DICOMweb retrieve shows the patient as its status from start to end')
