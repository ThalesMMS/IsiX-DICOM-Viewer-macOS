"""The factory settings, as the application and the Decompress helper build them.

The defaults registered beneath the user's preferences are built by the
IsiXPreferences module (DefaultPreferences, Modules/IsiXPreferences). A check
that needs one of them asks `registered()` for the dictionary itself: the
module compiled once per process with swiftc (isix_modules) and run, its result
read back as a property list, so a string, an integer, a float and a boolean
stay what they are. `viewer=False` gives the helper's; `app_store=True` those of
the Mac App Store build. `source()` is the module's Swift, for a check on how a
value is computed rather than what it is.

The probe runs in a folder of its own, where the colour tables and default
annotations the application looks up in its bundle are absent, and with a
super-sampling above the default in its argument domain, so it writes nothing
into the preferences.
"""
import functools
import plistlib
import subprocess
import tempfile
from pathlib import Path

import isix_modules

ROOT = Path(__file__).resolve().parents[1]
MODULE = 'IsiXPreferences'
PROBE = r'''
import Foundation
import IsiXPreferences
let values = DefaultPreferences.defaults(forViewer: CommandLine.arguments[1] == "true", appStore: CommandLine.arguments[2] == "true")
FileHandle.standardOutput.write(try! PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0))
'''


@functools.lru_cache(maxsize=None)
def _probe():
    folder = Path(tempfile.mkdtemp(prefix='horos-default-preferences-'))
    (folder / 'probe.swift').write_text(PROBE)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', *isix_modules.module_flags(MODULE, folder / 'module'),
                    str(folder / 'probe.swift'), '-o', str(folder / 'probe')], check=True, capture_output=True)
    return folder / 'probe'


@functools.lru_cache(maxsize=None)
def registered(viewer=True, app_store=False):
    """The factory settings, as a dictionary of Python values."""
    probe = _probe()
    output = subprocess.run([str(probe), 'true' if viewer else 'false', 'true' if app_store else 'false',
                             '-superSampling', '9'], capture_output=True, check=True, timeout=60, cwd=probe.parent).stdout
    return plistlib.loads(output)


def source():
    """The module's Swift sources, joined."""
    return '\n'.join(path.read_text(encoding='utf-8') for path in isix_modules.module_sources(MODULE))
