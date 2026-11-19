"""What the tests that link the application's objects reuse from one to the next.

A test that links a probe with the objects of the application's build
(roi_harness, app_object_probe) asks the same things of the same files as
every other one: the symbols each Swift object of the build defines and
needs, and the internal modules compiled from this checkout. They are kept
under build/test-harness-cache, which git ignores, or in the folder
HOROS_TEST_HARNESS_CACHE names.

Nothing is kept by a name alone:

* what is read from an object file (object_fact) is kept under the object's
  path, size and modification time. A build that writes the object again
  changes them, and what was read from the former object is not found any
  more: it is read again from the new one, and the former entry is removed.
* what is compiled from sources (built) is kept under a digest of everything
  it is made from, which the caller gives: the contents of the sources, the
  flags and the compiler. No object of the application's build is kept here
  or copied from here: a probe links the objects of the build itself.

Tests run in parallel. An entry is written under a temporary name and renamed
when it is complete, so that another test reads all of it or none; when two
make the same entry at once, both are whole and the same, and one of them stays.

A compiled entry no test has asked for in UNUSED_DAYS is removed when another
of its kind is made: sources change, and each change leaves the entries of
the former contents behind.
"""
from pathlib import Path
import atexit
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
# Where the application's build leaves its objects.
BUILD = ROOT / 'build'

# How long a compiled entry stays without a test asking for it.
UNUSED_DAYS = 14

_facts = {}     # object path -> [signature, {tag: value}, changed]
_toolchain = []


class Unkept(Exception):
    """Raised by what object_fact() computes, with the value to answer this once and not to keep."""


def folder():
    return Path(os.environ.get('HOROS_TEST_HARNESS_CACHE') or ROOT / 'build/test-harness-cache')


def digest(*parts):
    """A digest of `parts`: texts, bytes, and lists of them."""
    hashed = hashlib.sha256()

    def add(part):
        if isinstance(part, (list, tuple)):
            hashed.update(b'[%d]' % len(part))
            for each in part:
                add(each)
        else:
            data = part if isinstance(part, bytes) else str(part).encode('utf-8', 'surrogateescape')
            hashed.update(b'%d:' % len(data) + data)
    add(parts)
    return hashed.hexdigest()[:32]


def signature(path):
    """The size and the modification time of a file: what a build changes when it writes it again."""
    status = os.stat(path)
    return '%d-%d' % (status.st_size, status.st_mtime_ns)


def _write(path, data):
    """`data` at `path`, whole or not at all."""
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, name = tempfile.mkstemp(prefix='.writing-', dir=path.parent)
    try:
        with os.fdopen(handle, 'wb') as file:
            file.write(data)
        os.replace(name, path)
    except BaseException:
        try:
            os.unlink(name)
        except OSError:
            pass
        raise


def _fact_file(obj, signed):
    return folder() / 'objects' / ('%s-%s.json' % (digest(str(obj)), digest(signed)))


def object_fact(obj, tag, compute):
    """What `compute()` answers of the object file `obj`, a JSON value, kept
    under `tag` for as long as the file has its size and modification time."""
    obj = Path(obj).resolve()
    signed = signature(obj)
    entry = _facts.get(obj)
    if entry is None or entry[0] != signed:
        try:
            stored = json.loads(_fact_file(obj, signed).read_bytes())
            # The entry says which file it is of: a digest that named two would not pass for one.
            known = stored['facts'] if stored.get('object') == str(obj) and stored.get('signature') == signed else {}
        except (OSError, ValueError, KeyError):
            known = {}
        entry = _facts[obj] = [signed, known, False]
        if len(_facts) == 1:
            atexit.register(flush)
    if tag not in entry[1]:
        try:
            entry[1][tag] = compute()
        except Unkept as unkept:
            return unkept.args[0]
        entry[2] = True
    return entry[1][tag]


def flush():
    """Writes what object_fact() read in this process and the cache did not have."""
    for obj, entry in _facts.items():
        signed, known, changed = entry
        if not changed:
            continue
        path = _fact_file(obj, signed)
        try:
            # What another test wrote of the same file meanwhile stays.
            stored = json.loads(path.read_bytes())
            if stored.get('object') == str(obj) and stored.get('signature') == signed:
                known = {**stored['facts'], **known}
        except (OSError, ValueError, KeyError):
            pass
        try:
            _write(path, json.dumps({'object': str(obj), 'signature': signed, 'facts': known}).encode())
            # What was read from the file a former build wrote at this path.
            for former in path.parent.glob(path.name.split('-')[0] + '-*.json'):
                if former != path:
                    former.unlink(missing_ok=True)
        except OSError:
            pass
        entry[2] = False


def of_the_build(obj):
    """Whether `obj` is a file of build/: an object a test compiled itself, in
    a folder of its own that it removes, is read each time and never kept."""
    try:
        Path(obj).resolve().relative_to(BUILD.resolve())
    except ValueError:
        return False
    return True


def fact(obj, tag, compute):
    """object_fact() for an object of the build, `compute()` for any other, a
    file that is not there among them."""
    return object_fact(obj, tag, compute) if of_the_build(obj) and Path(obj).is_file() else compute()


def nm(obj, *flags, check=False):
    """The output of `nm flags obj`, kept with an object of the build. What nm
    says of a file it cannot read is not kept; with `check`, it is an error."""
    def listed():
        done = subprocess.run(['nm', *flags, str(obj)], capture_output=True, text=True, check=check)
        if done.returncode:
            raise Unkept(done.stdout)
        return done.stdout
    try:
        return fact(obj, 'nm ' + ' '.join(flags), listed)
    except Unkept as unkept:
        return unkept.args[0]


def source_digest(*files):
    """A digest of the contents of source files: for the tag or the key of
    what their code derives, which a change to them makes anew."""
    return digest([Path(file).read_bytes() for file in files])


def toolchain():
    """The compiler and the SDK a compiled entry depends on, asked once per process."""
    if not _toolchain:
        version = subprocess.run(['xcrun', 'swiftc', '--version'], capture_output=True, text=True).stdout
        sdk = subprocess.run(['xcrun', '--show-sdk-path'], capture_output=True, text=True).stdout.strip()
        _toolchain.append(digest(version, sdk, os.path.realpath(sdk) if sdk else ''))
    return _toolchain[0]


def built(kind, key, build):
    """The folder of the entry `key` of `kind`, which `build(folder)` fills
    the first time. `key` is a digest of all the entry is made from."""
    final = folder() / kind / key
    if final.is_dir():
        try:
            os.utime(final)     # asked for now
        except OSError:
            pass
        return final
    final.parent.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix='.building-', dir=final.parent))
    try:
        build(work)
        try:
            os.rename(work, final)
        except OSError:
            # Another test made the same entry meanwhile: that one stays.
            if not final.is_dir():
                raise
    finally:
        shutil.rmtree(work, ignore_errors=True)
    # The entries no test asked for in a long time, and what a test that was
    # killed while it built one left under its temporary name.
    limit = time.time() - UNUSED_DAYS * 86400
    for other in final.parent.iterdir():
        try:
            if other != final and other.stat().st_mtime < limit:
                shutil.rmtree(other, ignore_errors=True)
        except OSError:
            pass
    return final
