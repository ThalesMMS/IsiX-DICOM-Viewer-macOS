#!/usr/bin/env python3
"""tools/export-isix-plugin-kit.py --xcode builds the kit without resolving packages.

A release approves the lockfile of the Swift packages before it builds, and
refuses to go on when a build rewrites it. The application's build tells Xcode
not to resolve; the kit's own build, which the export runs, has to say the
same, or a dependency's newer version rewrites the lockfile there and no
release can be made until the lockfile is updated.

With xcodebuild replaced by a stand-in that records its arguments and fails,
the export with --xcode passes both package options, and stops with the
build's failure.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / 'tools' / 'export-isix-plugin-kit.py'

with tempfile.TemporaryDirectory(prefix='isix-kit-packages-') as work:
    work = Path(work)
    stub = work / 'bin'
    stub.mkdir()
    recorded = work / 'arguments.txt'
    (stub / 'xcodebuild').write_text('#!/bin/sh\nprintf \'%s\\n\' "$@" > "$RECORDED"\necho "stand-in: no build"\nexit 65\n')
    (stub / 'xcodebuild').chmod(0o755)
    environment = dict(os.environ, PATH=f'{stub}:{os.environ["PATH"]}', RECORDED=str(recorded))
    result = subprocess.run([sys.executable, str(TOOL), '--xcode', 'Release', '--archs', 'arm64,x86_64',
                             '--output', str(work / 'sdk')], capture_output=True, text=True, env=environment)
    failures = []
    passed = recorded.read_text().splitlines() if recorded.exists() else []
    if not passed:
        failures.append('the export did not run xcodebuild')
    for option in ('-disableAutomaticPackageResolution', '-onlyUsePackageVersionsFromResolvedFile'):
        if option not in passed:
            failures.append(f'the kit is built without {option}: {passed}')
    if '-target' not in passed or passed[passed.index('-target') + 1:][:1] != ['IsiXPluginKit']:
        failures.append(f'the build is not of the kit alone: {passed}')
    if result.returncode == 0 or 'xcodebuild failed' not in result.stderr:
        failures.append(f'a failed build did not stop the export: {result.returncode} {result.stderr.strip()[-300:]}')
    if (work / 'sdk' / 'SDK.json').exists():
        failures.append('an SDK was written after a failed build')

if failures:
    print('\n'.join('FAIL: ' + failure for failure in failures))
    sys.exit(1)
print('PASS: the kit is built with the package versions of the lockfile, and a failed build stops the export')
