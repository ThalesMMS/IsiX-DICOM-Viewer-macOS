#!/usr/bin/env python3
"""A Modality Worklist SCP that answers C-FIND with synthetic scheduled steps.

Five scheduled procedure steps of made-up patients, relative to the local date
the fixture starts on: three today (one with a name outside ASCII, answered in
ISO_IR 192), one tomorrow and one ten days later. Each has its own Accession
Number, Patient ID, Study Instance UID, modality and station.

It accepts Verification and the Modality Worklist Information Model - FIND
(1.2.840.10008.5.1.4.31) only, so a requestor that proposes the Study Root
model finds no accepted presentation context. A query matches on the keys it
gives values to: single values exactly, `*` as a wildcard, and the scheduled
start date as a DICOM range (`from-to`, `from-`, `-to` or one date). Every
identifier is written down, element by element and with the items of the
Scheduled Procedure Step Sequence, so that a test can see what was asked.

The steps are written to `<evidence>/worklist-steps.json` before the server
listens, and the queries to `<evidence>/worklist-queries.json` after each one.
With `--port 0` the system picks the port; the line `listening on port N`
says which.
"""
import argparse
import datetime
import fnmatch
import json
import logging
import threading
from pathlib import Path

from pydicom.dataset import Dataset
from pydicom.sequence import Sequence
from pydicom.uid import generate_uid
from pynetdicom import AE, ALL_TRANSFER_SYNTAXES, evt
from pynetdicom.sop_class import ModalityWorklistInformationFind, Verification

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument('evidence', type=Path, help='directory for the steps and the queries')
parser.add_argument('--port', type=int, default=11198)
parser.add_argument('--aetitle', default='MWLFIX')
arguments = parser.parse_args()
arguments.evidence.mkdir(parents=True, exist_ok=True)

TODAY = datetime.date.today()


def day(offset):
    return (TODAY + datetime.timedelta(days=offset)).strftime('%Y%m%d')


# Patient, step and order; the station and the requested procedure are shared fields.
STEPS = [
    {'PatientName': 'MWL^ALPHA', 'PatientID': 'MWL-P1', 'AccessionNumber': 'MWL-A1', 'Modality': 'CT',
     'ScheduledStationAETitle': 'CT1', 'ScheduledStationName': 'CT ROOM 1', 'Date': day(0), 'Time': '080000',
     'Description': 'CT HEAD', 'StepID': 'SPS1', 'RequestedProcedureID': 'RP1'},
    {'PatientName': 'MWL^BETA', 'PatientID': 'MWL-P2', 'AccessionNumber': 'MWL-A2', 'Modality': 'MR',
     'ScheduledStationAETitle': 'MR1', 'ScheduledStationName': 'MR ROOM', 'Date': day(0), 'Time': '103000',
     'Description': 'MR KNEE', 'StepID': 'SPS2', 'RequestedProcedureID': 'RP2'},
    {'PatientName': 'MWL^JOÃO', 'PatientID': 'MWL-P3', 'AccessionNumber': 'MWL-A3', 'Modality': 'CT',
     'ScheduledStationAETitle': 'CT1', 'ScheduledStationName': 'CT ROOM 1', 'Date': day(0), 'Time': '1400',
     'Description': 'CT CHEST', 'StepID': 'SPS3', 'RequestedProcedureID': 'RP3'},
    {'PatientName': 'MWL^GAMMA', 'PatientID': 'MWL-P4', 'AccessionNumber': 'MWL-A4', 'Modality': 'US',
     'ScheduledStationAETitle': 'US1', 'ScheduledStationName': 'US ROOM', 'Date': day(1), 'Time': '090000',
     'Description': 'US ABDOMEN', 'StepID': 'SPS4', 'RequestedProcedureID': 'RP4'},
    {'PatientName': 'MWL^DELTA', 'PatientID': 'MWL-P5', 'AccessionNumber': 'MWL-A5', 'Modality': 'DX',
     'ScheduledStationAETitle': 'DX1', 'ScheduledStationName': 'DX ROOM', 'Date': day(10), 'Time': '113000',
     'Description': 'DX CHEST', 'StepID': 'SPS5', 'RequestedProcedureID': 'RP5'},
]
for step in STEPS:
    step['StudyInstanceUID'] = generate_uid()

record = {'today': day(0), 'steps': STEPS, 'queries': []}
lock = threading.Lock()


def values(element):
    """The values of an element as text: none for an empty one."""
    if element is None or element.value is None or element.value == '':
        return []
    if element.VR == 'SQ':
        return [[{item_element.keyword or str(item_element.tag): values(item_element) for item_element in item}
                 for item in element.value]]
    value = element.value
    if isinstance(value, (str, bytes)) or not hasattr(value, '__iter__'):
        return [str(value)]
    return [str(one) for one in value]


def text_matches(held, wanted):
    if not wanted:
        return True
    return fnmatch.fnmatchcase(held, wanted) if '*' in wanted or '?' in wanted else held == wanted


def date_matches(held, wanted):
    if not wanted:
        return True
    if '-' not in wanted:
        return held == wanted
    start, end = wanted.split('-', 1)
    return (not start or held >= start) and (not end or held <= end)


def first(query, keyword):
    element = query[keyword] if keyword in query else None
    found = values(element)
    return found[0] if found and isinstance(found[0], str) else ''


def matches(step, query):
    for keyword in ('PatientName', 'PatientID', 'AccessionNumber', 'StudyInstanceUID'):
        if not text_matches(step[keyword], first(query, keyword)):
            return False
    item = None
    sequence = query['ScheduledProcedureStepSequence'] if 'ScheduledProcedureStepSequence' in query else None
    if sequence is not None and sequence.value:
        item = sequence.value[0]
    if item is not None:
        if not text_matches(step['Modality'], first(item, 'Modality')):
            return False
        if not text_matches(step['ScheduledStationAETitle'], first(item, 'ScheduledStationAETitle')):
            return False
        if not date_matches(step['Date'], first(item, 'ScheduledProcedureStepStartDate')):
            return False
    return True


def answer(step):
    response = Dataset()
    response.SpecificCharacterSet = 'ISO_IR 192'
    response.PatientName = step['PatientName']
    response.PatientID = step['PatientID']
    response.PatientBirthDate = '19700101'
    response.PatientSex = 'O'
    response.AccessionNumber = step['AccessionNumber']
    response.StudyInstanceUID = step['StudyInstanceUID']
    response.ReferringPhysicianName = 'REFERRING^FIXTURE'
    response.RequestedProcedureID = step['RequestedProcedureID']
    response.RequestedProcedureDescription = step['Description']
    item = Dataset()
    item.ScheduledStationAETitle = step['ScheduledStationAETitle']
    item.ScheduledStationName = step['ScheduledStationName']
    item.ScheduledProcedureStepStartDate = step['Date']
    item.ScheduledProcedureStepStartTime = step['Time']
    item.Modality = step['Modality']
    item.ScheduledPerformingPhysicianName = 'PERFORMING^FIXTURE'
    item.ScheduledProcedureStepDescription = step['Description'] + ' STEP'
    item.ScheduledProcedureStepID = step['StepID']
    response.ScheduledProcedureStepSequence = Sequence([item])
    return response


def on_find(event):
    query = event.identifier
    entry = {'model': str(event.request.AffectedSOPClassUID), 'elements': {}}
    for element in query:
        entry['elements'][element.keyword or str(element.tag)] = values(element)
    found = [step for step in STEPS if matches(step, query)]
    entry['answers'] = [step['StepID'] for step in found]
    with lock:
        record['queries'].append(entry)
        arguments.evidence.joinpath('worklist-queries.json').write_text(json.dumps(record, indent=2, ensure_ascii=False))
    print('C-FIND MWL -> %s' % (', '.join(entry['answers']) or 'nothing'), flush=True)
    for step in found:
        yield 0xFF00, answer(step)


# A handler that raises answers 0xC311; its traceback goes to the standard error.
logging.getLogger('pynetdicom').addHandler(logging.StreamHandler())
logging.getLogger('pynetdicom').setLevel(logging.ERROR)
ae = AE(ae_title=arguments.aetitle)
ae.add_supported_context(Verification, ALL_TRANSFER_SYNTAXES)
ae.add_supported_context(ModalityWorklistInformationFind, ALL_TRANSFER_SYNTAXES)
arguments.evidence.joinpath('worklist-steps.json').write_text(json.dumps(record, indent=2, ensure_ascii=False))
server = ae.start_server(('127.0.0.1', arguments.port), block=False, evt_handlers=[(evt.EVT_C_FIND, on_find)])
print('%s listening on port %d' % (arguments.aetitle, server.server_address[1]), flush=True)
try:
    threading.Event().wait()
except KeyboardInterrupt:
    pass
finally:
    server.shutdown()
