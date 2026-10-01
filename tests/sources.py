"""Where a test finds the source of a class, whatever language it is in (#708).

419 tests read an Objective-C source by its path. When a class moves to Swift
the test that read Name.m reads the
Swift file instead, through source_path('Name') or source_text('Name'), and
its assertion moves to the Swift spelling in the same change: a test does not
turn into a skip, nor into an assertion that can no longer fail.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
# The preference panes keep their sources in one folder per pane (#711);
# DICOM print has its own folder (#717).
FOLDERS = ('Horos/Sources', 'Nitrogen/Sources', 'DCM Framework', 'DICOMPrint') + tuple(
    sorted(str(pane.relative_to(ROOT)) for pane in (ROOT / 'Preference Panes').iterdir() if pane.is_dir()))
EXTENSIONS = ('.swift', '.mm', '.m')


def source_path(name):
    """The implementation of `name`: Name.swift if it has one, else Name.mm or Name.m."""
    for extension in EXTENSIONS:
        for folder in FOLDERS:
            path = ROOT / folder / (name + extension)
            if path.is_file():
                return path
    raise FileNotFoundError(f'no implementation of {name} in {", ".join(FOLDERS)}')


def source_text(name):
    """The implementation's text; Objective-C sources may be Latin-1."""
    return source_path(name).read_bytes().decode('latin1' if source_path(name).suffix != '.swift' else 'utf-8')


def is_swift(name):
    return source_path(name).suffix == '.swift'


def dependency_source(name):
    """Resolve a pinned original source with the production acquisition contract."""
    import json
    import os
    import subprocess
    import sys
    prefix = ROOT / 'build/TestSources' / name
    downloads = os.environ.get('EXTERNAL_SOURCES_DOWNLOADS', str(ROOT / 'build/ExternalSources.downloads'))
    outcome = subprocess.run(['/bin/sh', str(ROOT / 'Horos/Scripts/external-inputs.sh'),
                              '--source', name, str(prefix), downloads],
                             capture_output=True, text=True)
    if outcome.returncode:
        pin = json.loads((ROOT / 'Horos/Scripts/external-sources.json').read_text())[name]
        missing = not (Path(downloads) / pin['archive']).exists()
        unavailable = any(message in outcome.stderr for message in
                          ('missing or corrupt archive', 'could not download'))
        if missing and unavailable:
            print('skipped: requires original %s archive: %s' % (name, outcome.stderr.strip()))
            sys.exit(2)
        raise RuntimeError('original %s acquisition failed: %s' % (name, outcome.stderr.strip()))
    return Path(outcome.stdout.strip())
