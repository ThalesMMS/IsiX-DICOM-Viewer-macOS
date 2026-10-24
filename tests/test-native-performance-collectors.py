#!/usr/bin/env python3
"""Collectors must reject incomplete evidence before publishing a final JSON.

Mock only the LLDB transport; execute the real CLI and output validation with
small synthetic captures. Native expression execution is validated in the app.
"""
import contextlib
import copy
import io
import json
from pathlib import Path
import re
import runpy
import subprocess
import sys
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
checks = 0


def check(kind, mutate=None, truncate=False, collision=False, trace=True, gate_failure=None):
    global checks
    with tempfile.TemporaryDirectory(prefix='horos-collector-') as directory:
        folder = Path(directory)
        base = folder / 'sample'
        sample = dict(total_ms=1, assign_ms=.1, generate_ms=.7, draw_ms=.2,
                      cpu_ms=2, valid=True, dimensions=[2, 2, 1])
        if kind == 'cpr':
            data = {'runs': [dict(pass_=i, samples=[copy.deepcopy(sample)], captureValid=True) for i in range(2)]}
            for run in data['runs']:
                run['pass'] = run.pop('pass_')
            captures = {f'sample-pass{i}.f32': bytes(16) for i in range(2)}
            args = ['--capture']
        else:
            data = {f'engine2-pass{i}': dict(engine=2, milliseconds=[1], captureValid=True,
                nativePixelBytes=32, width=2, height=2, samples=3, bits=8,
                snapshot=dict(colourVolume=True, componentTables=[{}, {}, {}]),
                fallback='', trace=dict(dropped=0, samples=[dict(operation='vr.render.metal4', status='completed', gpu_ms=.5)])) for i in range(2)}
            captures = {f'sample-pass{i}.rgba16': bytes(32) for i in range(2)}
            captures.update({f'sample-engine2-pass{i}.rgb': bytes(12) for i in range(2)})
            args = ['--prepare-rgb-tables'] + (['--trace'] if trace else [])
        if mutate:
            mutate(data)
        if collision:
            base.with_suffix('.json').write_text('prior evidence')

        def lldb(command, **kwargs):
            assert not collision, 'Must reject reused labels before attaching'
            expression = base.with_suffix('.expression.txt').read_text()
            if kind == 'vr':
                # Execute the generated debugger Python, mocking only the LLDB
                # API. A failed symbol lookup must never reach native evaluation.
                evaluated = []
                def evaluate_native(text, options):
                    assert 'RENDER_GATE_ADDRESS' not in text
                    assert 'int *vrBenchRenderGate=(int *)0x1000;' in text
                    assert '*vrBenchRenderGate=vrBenchInitialRenderGate;' in text
                    evaluated.append(text)
                    return SimpleNamespace(GetError=lambda: 'success')
                def symbol(name, address=0x1000, kind=1):
                    return SimpleNamespace(GetName=lambda: name, GetType=lambda: kind,
                        GetStartAddress=lambda: SimpleNamespace(GetLoadAddress=lambda target: address))
                symbols = [symbol('dontRenderVolumeRenderingLegacy'),
                           symbol('unrelated'), symbol('dontRenderVolumeRenderingHelper', kind=2)]
                if gate_failure == 'missing': symbols = []
                if gate_failure == 'ambiguous': symbols.append(symbol('dontRenderVolumeRenderingOther'))
                if gate_failure in ('null', 'invalid', 'unaligned'):
                    symbols = [symbol('dontRenderVolumeRenderingLegacy', {'null': 0, 'invalid': 2**64-1, 'unaligned': 0x1001}[gate_failure])]
                options = SimpleNamespace(**{name: lambda value: None for name in
                    ('SetLanguage', 'SetTrapExceptions', 'SetStopOthers', 'SetTimeoutInMicroSeconds')})
                api = SimpleNamespace(SBExpressionOptions=lambda: options,
                    eLanguageTypeObjC_plus_plus=0, eSymbolTypeData=1, LLDB_INVALID_ADDRESS=2**64-1,
                    target=SimpleNamespace(modules=[SimpleNamespace(symbols=symbols)]),
                    frame=SimpleNamespace(EvaluateExpression=evaluate_native))
                script = next(line[7:] for line in base.with_suffix('.lldb').read_text().splitlines() if line.startswith('script '))
                try:
                    exec(script, {'lldb': api})
                except AssertionError:
                    if not gate_failure: raise
                    assert not evaluated, 'An invalid gate reached native code'
                    return subprocess.CompletedProcess(command, 0, 'debugger assertion', '')
                assert not gate_failure and len(evaluated) == 1
            matches = re.findall(r'@("[^"\n]+\.partial")', expression)
            assert matches, 'No staging destination in native expression'
            Path(json.loads(matches[-1])).write_text(json.dumps(data))
            for name, content in captures.items():
                (folder / name).write_bytes(content[:-1] if truncate else content)
            return subprocess.CompletedProcess(command, 0, '', '')

        tool = ROOT / 'tools' / ('measure-native-cpr.py' if kind == 'cpr' else 'measure-native-vr-metal.py')
        argv = [str(tool), 'sample', '--pid', '1', '--iterations', '1', '--output', directory, *args]
        rejected = False
        with patch.object(sys, 'argv', argv), patch('subprocess.run', side_effect=lldb), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            try:
                runpy.run_path(str(tool), run_name='__main__')
            except SystemExit as e:
                assert e.code != 0
                rejected = True
        expected_rejection = bool(mutate or truncate or collision or gate_failure)
        assert rejected == expected_rejection, (kind, mutate, truncate, collision)
        if collision:
            assert base.with_suffix('.json').read_text() == 'prior evidence'
        else:
            assert base.with_suffix('.json').exists() != expected_rejection
        checks += 1


for kind in ('cpr', 'vr'):
    check(kind)
    check(kind, truncate=True)
    check(kind, collision=True)
    check(kind, lambda d: d.clear())
    check(kind, lambda d: d.update(error='native exception'))
check('cpr', lambda d: d['runs'][0]['samples'].clear())
check('cpr', lambda d: d['runs'][0]['samples'][0].update(total_ms=float('nan')))
check('cpr', lambda d: d['runs'][0]['samples'][0].update(dimensions=[2, 0, 1]))
check('cpr', lambda d: d['runs'][0].update(captureValid=False))
check('vr', lambda d: d['engine2-pass0'].update(milliseconds=[]))
check('vr', lambda d: d['engine2-pass0'].update(milliseconds=[float('inf')]))
check('vr', lambda d: d['engine2-pass0'].update(captureValid=False))
check('vr', lambda d: d['engine2-pass0']['snapshot'].update(componentTables=[]))
check('vr', lambda d: d['engine2-pass0']['trace'].update(samples=[]))
check('vr', lambda d: d['engine2-pass0']['trace'].update(dropped=1))
check('vr', lambda d: d['engine2-pass0'].update(fallback='CPU fallback'))
check('vr', lambda d: d['engine2-pass0'].update(engine=0))
check('vr', lambda d: d['engine2-pass0']['trace']['samples'][0].update(status='failed'))
check('vr', lambda d: d['engine2-pass0']['trace']['samples'][0].update(gpu_ms=None))
check('vr', trace=False)
check('vr', lambda d: d['engine2-pass0'].update(fallback='CPU fallback'), trace=False)
for failure in ('missing', 'ambiguous', 'null', 'invalid', 'unaligned'):
    check('vr', gate_failure=failure)
print(f'PASS: {checks} collector acceptance/rejection and evidence preservation checks')
