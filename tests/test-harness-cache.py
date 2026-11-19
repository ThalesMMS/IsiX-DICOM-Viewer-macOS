#!/usr/bin/env python3
"""What the tests that link the application's objects keep from one to the
next (tests/harness_cache.py) is never what a former build left.

What is read from an object file is kept with the file's path, size and
modification time: read once, it is not read again while the file stays as it
is; a file written again, with another size or at another time, is read again
and what was kept of the former one is removed; an object outside the build's
folder is never kept. What is compiled from sources is kept under a digest of
them: built once, whole or not at all, and one entry stays when two tests
build the same one at once; an entry no test asked for in a long time is
removed when another is made.

The objects here are compiled from two lines of C into a folder that stands
for the build's, and the cache is a folder of this test: neither the
application's build nor its cache is read or written.
"""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time

SKIPPED = 2
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
import harness_cache  # noqa: E402

if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (clang, nm)', file=sys.stderr)
    sys.exit(SKIPPED)

failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def compiled(source, obj):
    obj.with_suffix('.c').write_text(source)
    subprocess.run(['xcrun', 'clang', '-c', str(obj.with_suffix('.c')), '-o', str(obj)], check=True, capture_output=True)
    return obj


def another_process(folder, obj):
    """What a test in a process of its own reads of `obj`, and whether it ran nm for it."""
    script = ('import json, subprocess, sys; sys.path.insert(0, sys.argv[1]); import harness_cache\n'
              'from pathlib import Path\n'
              'harness_cache.BUILD = Path(sys.argv[2]); ran = []; run = subprocess.run\n'
              'subprocess.run = lambda command, *a, **k: (ran.append(command[0]), run(command, *a, **k))[1]\n'
              'print(json.dumps([harness_cache.nm(sys.argv[3], "-g", "--defined-only", "-j").split(), ran]))\n')
    import json
    done = subprocess.run([sys.executable, '-c', script, str(ROOT / 'tests'), str(folder / 'build'), str(obj)],
                          capture_output=True, text=True, check=True, env={**os.environ, 'HOROS_TEST_HARNESS_CACHE': str(folder / 'cache')})
    return json.loads(done.stdout)


with tempfile.TemporaryDirectory(prefix='horos-harness-cache-') as name:
    folder = Path(name).resolve()
    (folder / 'build').mkdir()
    os.environ['HOROS_TEST_HARNESS_CACHE'] = str(folder / 'cache')
    harness_cache.BUILD = folder / 'build'
    entries = folder / 'cache/objects'

    obj = compiled('int first_symbol = 1;\n', folder / 'build/one.o')
    check(another_process(folder, obj) == [['_first_symbol'], ['nm']], 'an object of the build is read with nm the first time')
    check(another_process(folder, obj) == [['_first_symbol'], []], 'and not again while the file stays as it is')
    check(len(list(entries.iterdir())) == 1, 'one entry is kept for it')

    # The build writes the object again: another size.
    compiled('int second_symbol = 1; int third_symbol = 2;\n', obj)
    check(another_process(folder, obj) == [['_second_symbol', '_third_symbol'], ['nm']],
          'an object the build wrote again is read again, and nothing of the former one is answered')
    check(len(list(entries.iterdir())) == 1, 'what was kept of the former object is removed')

    # The same size at another time: other contents all the same.
    before = obj.stat()
    data = obj.read_bytes()
    check(b'second_symbol' in data, 'the object names its symbol')
    obj.write_bytes(data.replace(b'second_symbol', b'fourth_symbol'))
    os.utime(obj, ns=(before.st_atime_ns, before.st_mtime_ns + 1_000_000_000))
    check(obj.stat().st_size == before.st_size, 'the object rewritten in place has the size it had')
    answer = another_process(folder, obj)
    check(sorted(answer[0]) == ['_fourth_symbol', '_third_symbol'] and answer[1] == ['nm'],
          'an object of the same size written at another time is read again: %r' % answer)

    # An entry is of the file it names: one copied to the name of another file's is not taken for it.
    other = compiled('int other_symbol = 1;\n', folder / 'build/two.o')
    stale = next(entries.iterdir())
    shutil.copyfile(stale, harness_cache._fact_file(other, harness_cache.signature(other)))
    check(another_process(folder, other) == [['_other_symbol'], ['nm']], 'an entry that names another file is not answered')

    # An object a test compiled itself is never kept.
    kept = len(list(entries.iterdir()))
    own = compiled('int own_symbol = 1;\n', folder / 'own.o')
    check(another_process(folder, own) == [['_own_symbol'], ['nm']] and another_process(folder, own)[1] == ['nm']
          and len(list(entries.iterdir())) == kept, 'an object outside the build is read each time and not kept')
    check(harness_cache.nm(folder / 'build/absent.o', '-u') == '', 'a file that is not there is nothing kept, as nm says of it')

    # What is compiled: built once under its key, whole, and once when two build it at once.
    builds = []

    def build(work):
        builds.append(work)
        check(work.parent == folder / 'cache/kind' and work.name.startswith('.building-'), 'an entry is built beside its place, under another name')
        (work / 'made').write_text('made')
    key = harness_cache.digest('sources', [b'a', b'b'], 'flags')
    first = harness_cache.built('kind', key, build)
    check(first == folder / 'cache/kind' / key and (first / 'made').read_text() == 'made' and len(builds) == 1, 'an entry is built the first time')
    check(harness_cache.built('kind', key, build) == first and len(builds) == 1, 'and not again')
    check(harness_cache.digest('sources', [b'a', b'b'], 'flags') == key and harness_cache.digest('sources', [b'a', b'c'], 'flags') != key
          and harness_cache.digest('sources', [b'ab'], 'flags') != key, 'the key is of the contents, each apart')

    # An entry no test asked for in a long time goes when another is made; one asked for stays.
    for name in ('unused', 'used'):
        harness_cache.built('kind', name, build)
        long_ago = time.time() - (harness_cache.UNUSED_DAYS + 1) * 86400
        os.utime(folder / 'cache/kind' / name, (long_ago, long_ago))
    harness_cache.built('kind', 'used', build)
    harness_cache.built('kind', 'another', build)
    check(sorted(p.name for p in (folder / 'cache/kind').iterdir()) == sorted([key, 'used', 'another']),
          'an entry not asked for in %d days is removed when another is made, one asked for since is not: %r'
          % (harness_cache.UNUSED_DAYS, sorted(p.name for p in (folder / 'cache/kind').iterdir())))
    shutil.rmtree(folder / 'cache/kind/used')
    shutil.rmtree(folder / 'cache/kind/another')

    def failing(work):
        (work / 'half').write_text('half')
        raise RuntimeError('does not compile')
    try:
        harness_cache.built('kind', 'failing', failing)
        check(False, 'a build that fails is an error')
    except RuntimeError:
        pass
    check(not (folder / 'cache/kind/failing').exists() and sorted(p.name for p in (folder / 'cache/kind').iterdir()) == [key],
          'a build that fails leaves no entry and nothing half made')

    both = threading.Barrier(2)
    answers = []

    def racing(work):
        (work / 'made').write_text(threading.current_thread().name)
        both.wait(timeout=30)
    threads = [threading.Thread(target=lambda: answers.append(harness_cache.built('kind', 'raced', racing)), name=f'builder-{i}') for i in range(2)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    check(answers == [folder / 'cache/kind/raced'] * 2 and (folder / 'cache/kind/raced/made').read_text().startswith('builder-')
          and sorted(p.name for p in (folder / 'cache/kind').iterdir()) == sorted([key, 'raced']),
          'two tests that build one entry at once leave one, whole: %r' % answers)

if failures:
    print('FAIL:')
    for failure in failures:
        print('  - ' + failure)
    sys.exit(1)
print('PASS: what is read of an object of the build is kept while the file stays as it is and read again once the build '
      'writes it again; what is compiled is built once under its key, whole, by one of the tests that ask for it')
