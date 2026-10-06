"""Give a test, and every tool it runs, a TMPDIR removed when the test exits.

The toolchain leaves folders behind in TMPDIR that the test never names:
swiftc makes a `TemporaryDirectory.XXXXXX` holding only `.keep-directory`
whenever it compiles with `-c`, links object files or runs a script, and clang
leaves an empty `<output>-XXXXXX` folder per architecture when it links a
universal binary. Importing this module first points TMPDIR, and the tempfile
module, at a folder of the test's own, so a run leaves nothing new in the
user's temporary folder however the test ends (except by SIGKILL).

NSTemporaryDirectory() does not read TMPDIR; a harness that writes there must
remove what it writes itself.
"""
import atexit
import os
import shutil
import tempfile

# python_with.require() re-executes the test under another interpreter, which
# skips atexit; the same process (same pid) takes the folder over instead of
# leaving it behind. A child test run by this one makes a folder of its own.
_OWNER = "HOROS_TEST_TMPDIR_PID"
if os.environ.get(_OWNER) == str(os.getpid()) and os.path.isdir(os.environ.get("TMPDIR", "")):
    folder = os.environ["TMPDIR"].rstrip("/")
else:
    folder = tempfile.mkdtemp(prefix="horos-test-")
    os.environ["TMPDIR"] = folder + "/"
    os.environ[_OWNER] = str(os.getpid())
tempfile.tempdir = folder
atexit.register(shutil.rmtree, folder, ignore_errors=True)

# ibtool talks to its daemon through FIFOs it makes in the user's temporary
# folder (confstr DARWIN_USER_TEMP_DIR, which TMPDIR does not move) and leaves
# there after it exits. The ones that appear while this test runs are removed.
import subprocess as _subprocess
from pathlib import Path as _Path

_shared = _Path(_subprocess.run(['getconf', 'DARWIN_USER_TEMP_DIR'], capture_output=True, text=True).stdout.strip() or '/nonexistent')
_before = {entry.name for entry in _shared.iterdir()} if _shared.is_dir() else set()


def _remove_ibtool_fifos():
    if _shared.is_dir():
        for entry in _shared.iterdir():
            if entry.name not in _before and '-IBTOOLD-' in entry.name:
                entry.unlink(missing_ok=True)


atexit.register(_remove_ibtool_fifos)
