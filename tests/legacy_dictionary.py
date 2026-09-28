"""The DCM Framework's former tag dictionaries, as a reference for tests.

tagDictionary.plist and nameDictionary.plist left the repository in #742; the
host builds its dictionaries from DCMTK and HorosDICOMLegacyNames.h. The tests
that compare against the former files read them from the commit named in
docs/dcm-facade-catalog.json, so a clone with history has them and a shallow
one skips.
"""
import json
import plistlib
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def legacy_bytes(name):
    """The bytes of 'tagDictionary.plist' or 'nameDictionary.plist', or None."""
    catalog = json.loads((ROOT / 'docs/dcm-facade-catalog.json').read_text())['legacy_dictionary']
    path = next(p for p in catalog['paths'] if p.endswith('/' + name))
    shown = subprocess.run(['git', '-C', str(ROOT), 'show', '%s:%s' % (catalog['commit'], path)],
                           capture_output=True)
    return shown.stdout if shown.returncode == 0 and shown.stdout else None


def legacy_plist(name):
    data = legacy_bytes(name)
    return plistlib.loads(data) if data else None
