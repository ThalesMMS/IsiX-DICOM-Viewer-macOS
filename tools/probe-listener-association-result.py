#!/usr/bin/env python3
"""Exercise a disposable loopback Horos listener with synthetic files and bad PDUs.

Requires pydicom and pynetdicom. Use generate-jpeg-series-fixture.py in an empty
directory and an isolated development database. Save stdout beside the app log.
This intentionally aborts associations; never point it at a production listener.

Between two valid receptions, one association per fault:

- peer-abort: an A-ABORT;
- timeout: no command at all, for --timeout-wait seconds;
- invalid-pdu: a PDU of an unknown type;
- idle-after-find: a complete C-FIND, then nothing for --idle-wait seconds;
- find-identifier-withheld: the command of a C-FIND-RQ and nothing of its
  identifier;
- command-split: the first half of a command, as a fragment that is not the
  last;
- store-cut: the command of a C-STORE-RQ and the first fragment of its data set.

The last three stop in the middle of a message and leave the connection open
for --timeout-wait seconds, which must be longer than the listener's timeout.
--modes picks the faults, in the order given.
"""
import argparse
import json
import time
from io import BytesIO
from pathlib import Path

import pydicom
from pydicom.dataset import Dataset
from pydicom.uid import ExplicitVRLittleEndian, ImplicitVRLittleEndian
from pynetdicom import AE
from pynetdicom.dimse_messages import C_FIND_RQ, C_STORE_RQ
from pynetdicom.dimse_primitives import C_FIND, C_STORE
from pynetdicom.dsutils import encode
from pynetdicom.pdu_primitives import P_DATA
from pynetdicom.sop_class import StudyRootQueryRetrieveInformationModelFind, Verification

MODES = ('peer-abort', 'timeout', 'invalid-pdu', 'idle-after-find', 'find-identifier-withheld', 'command-split', 'store-cut')

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('fixture', type=Path)
parser.add_argument('--port', type=int, default=11272)
parser.add_argument('--called', default='PDVTEST')
parser.add_argument('--timeout-wait', type=float, default=13)
parser.add_argument('--idle-wait', type=float, default=8)
parser.add_argument('--modes', nargs='+', choices=MODES, default=list(MODES), metavar='MODE',
                    help='the faults to inject, in this order (default: all of %s)' % ', '.join(MODES))
args = parser.parse_args()
datasets = [pydicom.dcmread(path) for path in sorted(args.fixture.glob('*.dcm'))]
if not datasets or any(ds.PatientID != 'LOCAL-JPEG-SERIES' for ds in datasets):
    raise SystemExit('Use only the generated JPEG series fixture')


def associate(storage=False, find=False, title='PDVFAULT'):
    ae = AE(ae_title=title)
    ae.add_requested_context(Verification)
    if find:
        ae.add_requested_context(StudyRootQueryRetrieveInformationModelFind, [ImplicitVRLittleEndian])
    if storage:
        for sop in sorted({str(ds.SOPClassUID) for ds in datasets}):
            ae.add_requested_context(sop, [ExplicitVRLittleEndian, ImplicitVRLittleEndian])
    association = ae.associate('127.0.0.1', args.port, ae_title=args.called)
    if not association.is_established:
        raise RuntimeError('Loopback association refused')
    return association


def accepted(association, abstract_syntax):
    """The accepted presentation context of `abstract_syntax`."""
    for context in association.accepted_contexts:
        if context.abstract_syntax == abstract_syntax:
            return context
    raise RuntimeError('The listener did not accept %s' % abstract_syntax)


def study_query():
    identifier = Dataset()
    identifier.QueryRetrieveLevel = 'STUDY'
    identifier.PatientID = 'LOCAL-JPEG-SERIES'
    identifier.StudyInstanceUID = ''
    return identifier


def find_request(context):
    """The P-DATA primitives of a C-FIND-RQ with its identifier: the command, then the data set."""
    primitive = C_FIND()
    primitive.MessageID = 1
    primitive.AffectedSOPClassUID = StudyRootQueryRetrieveInformationModelFind
    primitive.Priority = 2
    syntax = context.transfer_syntax[0]
    primitive.Identifier = BytesIO(encode(study_query(), syntax.is_implicit_VR, syntax.is_little_endian))
    message = C_FIND_RQ()
    message.primitive_to_message(primitive)
    return list(message.encode_msg(context.context_id, 16382))


def store_request(context, ds):
    """The P-DATA primitives of a C-STORE-RQ of `ds`, its data set in fragments of at most 4096 bytes."""
    primitive = C_STORE()
    primitive.MessageID = 1
    primitive.AffectedSOPClassUID = ds.SOPClassUID
    primitive.AffectedSOPInstanceUID = ds.SOPInstanceUID
    primitive.Priority = 2
    syntax = context.transfer_syntax[0]
    primitive.DataSet = BytesIO(encode(ds, syntax.is_implicit_VR, syntax.is_little_endian))
    message = C_STORE_RQ()
    message.primitive_to_message(primitive)
    return list(message.encode_msg(context.context_id, 4096))


def control(pdata):
    """The message control header of the only PDV of `pdata`: 0x01 a command, 0x02 the last fragment."""
    (_, value), = pdata.presentation_data_value_list
    return value[0]


def cut_message(a, mode):
    """Sends the beginning of a message and nothing more; the connection stays open."""
    if mode == 'find-identifier-withheld':
        context = accepted(a, StudyRootQueryRetrieveInformationModelFind)
        sent = [pdata for pdata in find_request(context) if control(pdata) & 0x01]
        withheld = 'the identifier'
    elif mode == 'command-split':
        context = accepted(a, StudyRootQueryRetrieveInformationModelFind)
        (_, value), = find_request(context)[0].presentation_data_value_list
        half = ((len(value) - 1) // 2) & ~1
        fragment = P_DATA()
        # The command bit alone: a fragment of a command that is not its last.
        fragment.presentation_data_value_list.append((context.context_id, b'\x01' + value[1:1 + half]))
        sent = [fragment]
        withheld = 'the rest of the command'
    else:
        ds = datasets[0]
        context = accepted(a, ds.SOPClassUID)
        request = store_request(context, ds)
        if len(request) < 3 or control(request[1]) != 0x00:
            raise RuntimeError('The data set of the fixture fits one fragment: nothing to cut')
        sent = request[:2]
        withheld = 'the rest of the data set (%d of %d fragments sent)' % (1, len(request) - 1)
    for pdata in sent:
        if len(pdata.presentation_data_value_list) != 1:
            raise RuntimeError('Unexpected P-DATA layout')
        a.dul.send_pdu(pdata)
    return {'pdus': len(sent), 'controls': ['0x%02x' % control(pdata) for pdata in sent], 'withheld': withheld}


for stage in ('before-faults', 'after-faults'):
    a = associate(storage=True, title='PDVVALID')
    statuses = []
    try:
        for ds in datasets:
            result = a.send_c_store(ds)
            statuses.append(int(result.Status) if 'Status' in result else None)
        a.release()
        print(json.dumps({'stage': stage, 'statuses': statuses, 'released': a.is_released}), flush=True)
        if any(status != 0 for status in statuses) or not a.is_released:
            raise RuntimeError('Valid reception failed')
    finally:
        if a.is_established:
            a.abort()
    if stage == 'after-faults':
        break
    for mode in args.modes:
        a = associate(storage=mode == 'store-cut', find=mode in ('idle-after-find', 'find-identifier-withheld', 'command-split'))
        detail = {}
        try:
            if mode == 'peer-abort':
                a.abort()
            elif mode == 'timeout':
                time.sleep(args.timeout_wait)
            elif mode == 'idle-after-find':
                statuses = [int(status.Status) if status and 'Status' in status else None
                            for status, _ in a.send_c_find(study_query(), StudyRootQueryRetrieveInformationModelFind)]
                if not statuses or statuses[-1] != 0:
                    raise RuntimeError('The C-FIND before the idle wait did not end with Success: %r' % statuses)
                detail = {'find': statuses}
                time.sleep(args.idle_wait)
            elif mode in ('find-identifier-withheld', 'command-split', 'store-cut'):
                detail = cut_message(a, mode)
                time.sleep(args.timeout_wait)
            else:
                # Unknown PDU type, six-byte header, empty payload. Deliberately
                # bypass the encoder to exercise Horos's actual receive parser.
                a.dul.socket.socket.sendall(bytes([0x99, 0, 0, 0, 0, 0]))
                time.sleep(2)
            print(json.dumps({'fault': mode, 'aborted': a.is_aborted, 'established': a.is_established, **detail}), flush=True)
        finally:
            if a.is_established:
                a.abort()
