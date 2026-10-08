#!/usr/bin/env python3
"""Run the actual Xcode metadata phase against clean and modified Git trees."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
project = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-',
                                             str(root / 'Horos.xcodeproj/project.pbxproj')]))
phase = next(v for v in project['objects'].values()
             if v.get('isa') == 'PBXShellScriptBuildPhase' and v.get('name') == 'Git Hash')
script = phase['shellScript']
script = '\n'.join(script) if isinstance(script, list) else script
with tempfile.TemporaryDirectory(prefix='isix-build-metadata-') as folder:
    work = Path(folder)
    subprocess.run(['git', 'init', '-q', str(work)], check=True)
    (work / 'source.txt').write_text('committed source\n')
    subprocess.run(['git', 'add', 'source.txt'], cwd=work, check=True)
    subprocess.run(['git', '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                    'commit', '-q', '-m', 'Fixture'], cwd=work, check=True)
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=work, text=True).strip()
    products = work / 'build'
    info_path = products / 'Fixture.app/Contents/Info.plist'
    info_path.parent.mkdir(parents=True)
    info_path.write_bytes(plistlib.dumps({'CFBundleIdentifier': 'test.fixture'}))
    environment = dict(os.environ, BUILT_PRODUCTS_DIR=str(products), WRAPPER_NAME='Fixture.app')
    for expected in ('clean', 'dirty'):
        if expected == 'dirty':
            (work / 'source.txt').write_text('modified source\n')
        subprocess.run([phase['shellPath'], '-e', script], cwd=work, env=environment, check=True)
        values = plistlib.loads(info_path.read_bytes())
        assert values['GitHash'] == head, values
        assert values['GitState'] == expected, values
        assert info_path.stat().st_mode & 0o777 == 0o644, oct(info_path.stat().st_mode)
        assert values['CFBundleIdentifier'] == 'test.fixture', values
print('PASS: the Xcode phase records the actual Git revision and state, preserves metadata, and leaves Info.plist readable.')
