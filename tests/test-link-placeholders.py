#!/usr/bin/env python3
"""A probe that does not load is not taken as built.

The helpers that link a probe out of the app's objects give every symbol dyld
names a zeroed placeholder and link again, until a run of the probe no longer
names one (tests/link_placeholders.py). A run that names none is not a probe
that runs: a placeholder standing in for an Objective-C class kills the load
when a linked object extends the class with a category, by a signal and without
a word, and a loop that looked only for dyld's message took the probe as built.
A reference harness was once accepted that way, and its test failed minutes
later with a signal number and nothing about what was missing.

This builds small executables, without the app's build, and gives their runs
to the functions those loops ask:

  * a probe that links, and one that lacks two data, go through the loop as
    they always did: no placeholder, and one for each datum, a run apiece;
  * a category on a class nothing defines, the case above: dyld names the
    class, the loop gives it a placeholder, and the next run is killed with a
    segmentation fault and an empty standard error. It is refused, by the
    signal's name, with the class told apart from the other placeholders;
  * a probe that aborts, one that answers another status, and one that never
    ends are refused as well, with how each ended and what it had written;
  * a symbol dyld names again although it has its placeholder cannot be
    satisfied;
  * a probe run for its result only, with nothing in its main() to ask, is
    compiled with what answers the same run once the image has loaded, before
    main(): the same category is refused there, and a probe that dies in its
    main() is not, since that death is its result and for its test to judge.
    Any other run of it, with that argument among others too, is its own.

Every file of tests/ that links with placeholders asks those functions.

The symbol a probe lacks is read from the executable, not learnt from a run
dyld aborts: each such abort left a crash report in the user's
~/Library/Logs/DiagnosticReports, one for every placeholder of every build of
a harness. The probes above that lack data are run once, when nothing is
missing any more, or never when they cannot be built. What is read is what
dyld asks for to start the probe and no more: a symbol found only in a
library the probe loads through another is there, a weak import may be
absent, and a function that is never called is not looked up. A probe whose
symbols cannot be read is asked by its run, as before.
"""
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
import link_placeholders  # noqa: E402

LINKED = r'''
int main(int argc, char **argv) { return 0; }
'''
# Two data nothing defines: dyld names one per run.
TWO_DATA = r'''
extern int ProbeFirstDatum, ProbeSecondDatum;
int *first = &ProbeFirstDatum, *second = &ProbeSecondDatum;
int main(int argc, char **argv) { return 0; }
'''
# A category on a class nothing defines, as DCMPix.m's on the parser's DCMObject
# once was: with the class a zeroed placeholder, the runtime reads it to attach
# the category when the image loads. main() is never reached.
CATEGORY = r'''
#import <Foundation/Foundation.h>
extern int ProbeOtherDatum;
int *other = &ProbeOtherDatum;
@interface ProbeAbsentClass : NSObject
@end
@implementation ProbeAbsentClass (Probe)
+ (void)probe {}
@end
int main(int argc, char **argv) { puts("ran"); return 0; }
'''
ABORTS = r'''
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) { fputs("probe: giving up\n", stderr); abort(); }
'''
OTHER_STATUS = r'''
#include <stdio.h>
int main(int argc, char **argv) { fputs("probe: no such argument\n", stderr); return 3; }
'''
NEVER_ENDS = r'''
#include <unistd.h>
int main(int argc, char **argv) { sleep(600); return 0; }
'''
# What dyld does not refuse: a symbol of a library loaded through another one
# (zlib, which nothing here links and Foundation's libraries load), a weak
# import that nothing defines, and a function nothing defines, never called.
TOLERATED = r'''
extern const char *zlibVersion(void);
extern int ProbeWeakDatum __attribute__((weak_import));
extern void ProbeNeverCalled(void);
void *indirect = (void *)&zlibVersion;
int *weak = &ProbeWeakDatum;
int main(int argc, char **argv) { if (argc > 9) ProbeNeverCalled(); return 0; }
'''
# Probes run for their result: main() asks no argument.
RESULT = r'''
#include <stdio.h>
int main(int argc, char **argv) { puts("ran"); return 7; }
'''
DIES_IN_MAIN = r'''
#include <signal.h>
#include <stdio.h>
#include <unistd.h>
int main(int argc, char **argv) { puts("ran"); fflush(stdout); kill(getpid(), SIGSEGV); return 0; }
'''

failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def link(folder, name, source, placeholders, extension='c'):
    (folder / f'{name}.{extension}').write_text(source)
    (folder / f'{name}.s').write_text(link_placeholders.assembly(placeholders))
    subprocess.run(['xcrun', 'clang', '-w', str(folder / f'{name}.{extension}'), str(folder / f'{name}.s'),
                    '-Wl,-undefined,dynamic_lookup', '-framework', 'Foundation', '-o', str(folder / name)],
                   check=True, capture_output=True, text=True)
    return folder / name


def loop(folder, name, source, extension='c'):
    """The helpers' loop: link, ask the link run, add the placeholder it
    names. The placeholders the probe was built with."""
    placeholders = set()
    for _ in range(10):
        probe = link(folder, name, source, placeholders, extension)
        missing = link_placeholders.probe(probe, placeholders, f'the link probe {name}')
        if missing is None:
            return placeholders
        placeholders.add(missing)
    raise AssertionError(f'{name}: the loop does not end')


# Every process started, by its executable: a probe is run only when asked here.
runs = []
run_process = subprocess.run


def recorded_run(command, *arguments, **options):
    runs.append(Path(command[0]).name)
    return run_process(command, *arguments, **options)


subprocess.run = recorded_run


def refused(folder, name, source, extension='c'):
    """What the loop says of a probe it refuses, or None when it built it."""
    try:
        loop(folder, name, source, extension)
    except link_placeholders.ProbeNotBuilt as error:
        return str(error)
    return None


with tempfile.TemporaryDirectory(prefix='horos-link-placeholders-') as name:
    folder = Path(name)

    # What the loop took, it still takes.
    check(loop(folder, 'linked', LINKED) == set(), 'a probe that links is built without a placeholder')
    check(loop(folder, 'two-data', TWO_DATA) == {'_ProbeFirstDatum', '_ProbeSecondDatum'},
          'a probe that lacks two data is built with a placeholder for each')

    # The data were told without a run that dyld aborts: one run, of the probe built.
    check(runs.count('linked') == 1 and runs.count('two-data') == 1,
          'a probe is run once, when it lacks nothing: %d and %d runs' % (runs.count('linked'), runs.count('two-data')))
    probe = link(folder, 'two-data-read', TWO_DATA, set())
    check(link_placeholders.load_binds(probe) == ['_ProbeFirstDatum', '_ProbeSecondDatum']
          and link_placeholders.unbound_symbol(probe) == '_ProbeFirstDatum' and 'two-data-read' not in runs,
          'the first datum a probe lacks is read from it, without running it: %r' % link_placeholders.load_binds(probe))
    probe = link(folder, 'two-data-read', TWO_DATA, {'_ProbeFirstDatum'})
    check(link_placeholders.unbound_symbol(probe) == '_ProbeSecondDatum', 'with its placeholder, the next one is read')
    probe = link(folder, 'two-data-read', TWO_DATA, {'_ProbeFirstDatum', '_ProbeSecondDatum'})
    check(link_placeholders.unbound_symbol(probe) is None and 'two-data-read' not in runs, 'and none once both have theirs')

    # What dyld starts is not given a placeholder: one would hide zlib's own function.
    probe = link(folder, 'tolerated', TOLERATED, set())
    binds = link_placeholders.load_binds(probe)
    check(binds == ['_zlibVersion'], 'only what dyld asks for as the image loads is read: %r' % binds)
    if run_process([str(probe)], capture_output=True).returncode == 0:
        check(link_placeholders.unbound_symbol(probe) is None, 'a symbol of a library loaded through another is not missing')
        check(loop(folder, 'tolerated', TOLERATED) == set(), 'and the probe is built without a placeholder')
    # A probe that cannot be read is asked by its run.
    check(link_placeholders.unbound_symbol(folder / 'no-such-probe') is None, 'nothing is told of a file that cannot be read')

    # The category on a zeroed class: what the loop took as built.
    CLASS = '_OBJC_CLASS_$_ProbeAbsentClass'
    probe = link(folder, 'category-raw', CATEGORY, {CLASS, '_ProbeOtherDatum'}, 'm')
    raw = subprocess.run([str(probe), link_placeholders.LINK_RUN], capture_output=True, text=True)
    check(raw.returncode == -signal.SIGSEGV and raw.stdout == '' and link_placeholders.MISSING.search(raw.stderr) is None,
          'a category on a zeroed class kills the probe as it loads, by SIGSEGV, with no symbol named: status %d, %r'
          % (raw.returncode, raw.stderr[-300:]))
    said = refused(folder, 'category', CATEGORY, 'm')
    check(said is not None, 'a probe killed as it loads is refused')
    said = said or ''
    check('the link probe category was killed by SIGSEGV (signal %d): the probe is not built.' % signal.SIGSEGV in said,
          'the refusal names the signal: %r' % said)
    check('It is linked with 2 zeroed placeholders.' in said, 'the refusal counts the placeholders: %r' % said)
    check('Standing in for Objective-C classes: ProbeAbsentClass. ' in said, 'the refusal names the class a placeholder stands in for: %r' % said)
    check('The others: _ProbeOtherDatum.' in said, 'the refusal lists the other placeholders apart: %r' % said)
    check('It wrote nothing to its standard error.' in said, 'the refusal says the probe wrote nothing: %r' % said)
    check(runs.count('category') == 1, 'the class and the datum were read, and the one run is the one that is killed: %d runs'
          % runs.count('category'))

    said = refused(folder, 'aborts', ABORTS) or ''
    check('was killed by SIGABRT (signal %d)' % signal.SIGABRT in said and 'It is linked with no placeholder.' in said
          and said.rstrip().endswith('probe: giving up'), 'a probe that aborts is refused, with what it wrote: %r' % said)
    said = refused(folder, 'other-status', OTHER_STATUS) or ''
    check('the link probe other-status ended with status 3: the probe is not built.' in said
          and said.rstrip().endswith('probe: no such argument'), 'a probe that answers another status is refused: %r' % said)

    probe = link(folder, 'never-ends', NEVER_ENDS, set())
    started = time.monotonic()
    try:
        link_placeholders.probe(probe, set(), 'the link probe never-ends', timeout=1)
        said = ''
    except link_placeholders.ProbeNotBuilt as error:
        said = str(error)
    check('the link probe never-ends did not end in 1 s: the probe is not built.' in said and time.monotonic() - started < 30,
          'a probe that does not end is refused when its time is up: %r' % said)

    again = subprocess.CompletedProcess([], -signal.SIGABRT, '', "dyld[1]: symbol not found in flat namespace '_ProbeFirstDatum'\n")
    check(link_placeholders.verdict(again, set()) == '_ProbeFirstDatum', 'the symbol dyld names is the next placeholder')
    try:
        link_placeholders.verdict(again, {'_ProbeFirstDatum'})
        said = ''
    except link_placeholders.ProbeNotBuilt as error:
        said = str(error)
    check(said == 'cannot satisfy _ProbeFirstDatum', 'a symbol named although it has its placeholder cannot be satisfied: %r' % said)
    check(link_placeholders.classes({'_OBJC_METACLASS_$_A', '_OBJC_CLASS_$_A', '_OBJC_CLASS_$_B', '_c'}) == ['A', 'B'],
          'a class and its metaclass are one class')

    # A probe run for its result only: its link run is answered before main().
    answered = link_placeholders.LINK_RUN_SOURCE
    check(refused(folder, 'result-unanswered', RESULT) is not None, 'a main() that asks no argument does not answer the link run')
    check(loop(folder, 'result', RESULT + answered) == set(), 'a probe that loads is built')
    for arguments, expected in (([link_placeholders.LINK_RUN], (0, '')), ([], (7, 'ran\n')),
                                ([link_placeholders.LINK_RUN, 'cases'], (7, 'ran\n')), (['cases'], (7, 'ran\n'))):
        ran = subprocess.run([str(folder / 'result'), *arguments], capture_output=True, text=True)
        check((ran.returncode, ran.stdout) == expected,
              'only its link run ends before main(): %r answers %d %r' % (arguments, ran.returncode, ran.stdout))
    check(loop(folder, 'two-data-result', TWO_DATA + answered) == {'_ProbeFirstDatum', '_ProbeSecondDatum'}
          and runs.count('two-data-result') == 1, 'the data it lacks are found before main() too, with one run')
    said = refused(folder, 'category-result', CATEGORY + answered, 'm') or ''
    check('the link probe category-result was killed by SIGSEGV' in said
          and 'Standing in for Objective-C classes: ProbeAbsentClass. ' in said,
          'a probe killed as it loads is refused before it is run for its result: %r' % said)
    check(loop(folder, 'dies-in-main', DIES_IN_MAIN + answered) == set(), 'a probe that dies in its main() loads')
    ran = subprocess.run([str(folder / 'dies-in-main')], capture_output=True, text=True)
    check((ran.returncode, ran.stdout) == (-signal.SIGSEGV, 'ran\n'), 'and its death is its result: %d %r' % (ran.returncode, ran.stdout))

# No loop of tests/ looks for dyld's message by itself.
for path in sorted((ROOT / 'tests').glob('*.py')):
    text = path.read_text(encoding='utf-8', errors='replace')
    if path.name in ('link_placeholders.py', Path(__file__).name):
        continue
    if '.quad 0' in text or 'placeholders.s' in text:
        check('link_placeholders.probe(' in text,
              f'{path.name} links with placeholders and does not ask link_placeholders whether the probe is built')
        check('symbol not found in flat namespace' not in text or 'link_placeholders.' in text,
              f'{path.name} looks for the missing symbol by itself')

if failures:
    print('FAIL:')
    for failure in failures:
        print('  - ' + failure)
    sys.exit(1)
print('PASS: a probe killed as it loads, by a zeroed class under a category, one that aborts, one with another status '
      'and one that never ends are refused by name; a probe that links, and data given placeholders, are built as before')
