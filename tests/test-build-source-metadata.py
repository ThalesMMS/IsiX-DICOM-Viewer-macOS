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
assert '$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)' in phase.get('inputPaths', []), \
    'the metadata phase must wait for Xcode to process the installed Info.plist'
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
    installed = work / 'InstallationBuildProductsLocation/Applications'
    installed_info = installed / 'Fixture.app/Contents/Info.plist'
    installed_info.parent.mkdir(parents=True)
    installed_info.write_bytes(info_path.read_bytes())
    environment = dict(os.environ, BUILT_PRODUCTS_DIR=str(products), WRAPPER_NAME='Fixture.app')
    environment.pop('TARGET_BUILD_DIR', None)
    for expected in ('clean', 'dirty'):
        if expected == 'dirty':
            (work / 'source.txt').write_text('modified source\n')
        subprocess.run([phase['shellPath'], '-e', script], cwd=work, env=environment, check=True)
        values = plistlib.loads(info_path.read_bytes())
        assert values['GitHash'] == head, values
        assert values['GitState'] == expected, values
        assert info_path.stat().st_mode & 0o777 == 0o644, oct(info_path.stat().st_mode)
        assert values['CFBundleIdentifier'] == 'test.fixture', values
        before = info_path.read_bytes()
        archive_environment = dict(environment, TARGET_BUILD_DIR=str(installed))
        subprocess.run([phase['shellPath'], '-e', script], cwd=work, env=archive_environment, check=True)
        values = plistlib.loads(installed_info.read_bytes())
        assert values['GitHash'] == head, values
        assert values['GitState'] == expected, values
        assert values['CFBundleIdentifier'] == 'test.fixture', values
        assert installed_info.stat().st_mode & 0o777 == 0o644
        assert info_path.read_bytes() == before, 'archive stamping changed the ordinary build product'
print('PASS: the Xcode phase stamps ordinary builds and installed archive products, preserving metadata and readable permissions.')
