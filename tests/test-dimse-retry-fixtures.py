#!/usr/bin/env python3
"""Existing SCP generators omit a UID once, or forever, without losing zero-count requests."""
import ast
import copy
from itertools import product
from pathlib import Path
from threading import Lock
from types import SimpleNamespace as NS
import time

ROOT = Path(__file__).resolve().parents[1]
for operation in ('get', 'move'):
    path = ROOT / f'tools/serve-c{operation}-fixture.py'
    function = next(n for n in ast.parse(path.read_text()).body if isinstance(n, ast.FunctionDef) and n.name == f'on_{operation}')
    for permanent, failure in product((False, True), repeat=2):
        args = NS(repair_flag=None, omit_instance=2 if permanent and not failure else None, omit_once=2 if not permanent and not failure else None,
                  hold_back_once=[2] if not permanent and not failure else [],
                  fail_once=2 if failure and not permanent else None, refuse_once=2 if failure and not permanent else None,
                  fail_status=0xA702, fail_suboperations=True, duplicate_instance=None, stall_after=-1, instance_delay=0,
                  fail_image_retrieve=False, destination='LOCAL', destination_address='127.0.0.1', destination_port=11112)
        namespace = dict(arguments=args, time=time, lock=Lock(), record={'moves':[]}, save=lambda:None,
                         OMITTED_ONCE=set(), FAILED_ONCE=set(), REFUSED_ONCE=set(),
                         HELD_BACK={2} if permanent and not failure else set(),
                         REFUSED={2} if permanent and failure else set(), FAILING={2} if permanent and failure else set(),
                         copy=copy, Dataset=NS, UNSUPPORTED_SOP_CLASS="unsupported",
                         evt=NS(EVT_DIMSE_RECV=1,EVT_DIMSE_SENT=2,EVT_RELEASED=3),on_dimse=lambda _:None,on_released=lambda _:None,
                         INSTANCES=[NS(StudyInstanceUID='study',SeriesInstanceUID='series',SOPInstanceUID=str(n),InstanceNumber=n,SOPClassUID='supported',file_meta=NS(MediaStorageSOPClassUID='supported')) for n in range(1,4)])
        exec(compile(ast.Module(body=[function],type_ignores=[]),str(path),'exec'),namespace)
        def retrieve(uid='', consume_zero=True):
            event = NS(identifier=NS(QueryRetrieveLevel='IMAGE' if uid else 'STUDY',StudyInstanceUID='study',
                                   SeriesInstanceUID='series' if uid else '',SOPInstanceUID=uid),
                       assoc=NS(dimse=NS(send_msg=lambda *a:None)),move_destination='LOCAL',is_cancelled=False)
            generator = namespace[f'on_{operation}'](event)
            if operation == 'move': next(generator) # destination association
            count = next(generator)
            if not count and not consume_zero:
                generator.close() # pynetdicom does not resume a zero-suboperation generator
                return []
            responses = list(generator)
            stores = [str(dataset.SOPInstanceUID) for status,dataset in responses
                      if status == 0xFF00 and getattr(dataset, 'SOPClassUID', '') == 'supported']
            assert count == len(responses)
            return stores
        assert retrieve('1') == ['1'] # an unrelated IMAGE request must not consume the omission
        assert retrieve() == ['1','3']
        assert retrieve('2',consume_zero=False) == ([] if permanent else ['2'])
        assert retrieve('2',consume_zero=False) == ([] if permanent else ['2'])
        entries = namespace['record']['moves' if operation == 'move' else 'retrievals']
        assert len(entries) == 4
        assert entries[-1]['requestedUIDs'] == ['2']
print('ok: C-MOVE/C-GET transient and permanent omissions, exact retry UIDs, zero-count evidence, failed sub-operations')
