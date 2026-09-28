"""Where a test finds the source of a class, whatever language it is in (#708).

419 tests read an Objective-C source by its path. When a class moves to Swift
(docs/swift-migration-contract.md), the test that read Name.m reads the
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
