"""The DCM Framework's former tag dictionaries, as a reference for tests.

tagDictionary.plist and nameDictionary.plist left the repository in #742; the
host builds its dictionaries from DCMTK and HorosDICOMLegacyNames.h. The tests
that compare against the former files read them from the parent of their
removal commit in the available Git history. A full clone has those bytes; a
shallow clone without them skips.
"""
import plistlib
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def legacy_bytes(name):
    """The bytes of 'tagDictionary.plist' or 'nameDictionary.plist', or None."""
    if name not in ('tagDictionary.plist', 'nameDictionary.plist'):
        raise ValueError('unsupported legacy dictionary: ' + name)
    path = 'DCM Framework/' + name
    removed = subprocess.run(['git', '-C', str(ROOT), 'log', '-1',
                              '--diff-filter=D', '--format=%H', '--', path],
                             capture_output=True, text=True).stdout.strip()
    if not removed:
        return None
    shown = subprocess.run(['git', '-C', str(ROOT), 'show', removed + '^:' + path],
                           capture_output=True)
    return shown.stdout if shown.returncode == 0 and shown.stdout else None


def legacy_plist(name):
    data = legacy_bytes(name)
    return plistlib.loads(data) if data else None
