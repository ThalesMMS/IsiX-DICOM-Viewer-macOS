"""What a run of a probe says of the placeholders it is linked with.

A probe linked out of the app's objects with `-undefined dynamic_lookup` names
symbols that nothing it links defines. dyld refuses to start it while one of
them is a datum, naming one per run; roi_harness.build(),
app_object_probe.link_and_run() and the tests with a loop of their own give
each symbol named a placeholder, eight zeroed bytes, link again and run again,
until the probe starts. That is enough for what the probe never reaches.

It is not enough for an Objective-C class the runtime reads when the image
loads: a linked object that extends the class with a category, or subclasses
it, has the runtime read the zeroed class, and the probe is killed there,
before main() and without a word. Its standard error names no missing symbol,
so a loop that only looked for one took the probe as built, and the test
failed later with a signal number and nothing about what was missing.

So a run that tells whether the probe is linked ends in one of two ways the
loop goes on from - it answered 0, or dyld named a symbol - and any other end
is the probe not built: ProbeNotBuilt says how it ended, by which signal, which
placeholders it was linked with, those standing in for classes apart, and the
end of what it wrote.

The run is the probe's with the argument LINK_RUN (`--probe-link`). A probe of
roi_harness answers it 0 at once in its main(); a probe that is only ever run
for its result, with nothing in its main() to ask, is compiled with
LINK_RUN_SOURCE, which answers it once the image has loaded, before main(). An
argument, not the environment: a run for the probe's result cannot be given it
by mistake and pass for having ended well.
"""
import re
import signal
import subprocess

MISSING = re.compile(r"symbol not found in flat namespace '([^']+)'")
CLASS_SYMBOLS = ('_OBJC_CLASS_$_', '_OBJC_METACLASS_$_')
LINK_RUN = '--probe-link'
# The runtime has attached the categories of the image by the time its
# constructors run, and dyld has bound its data.
LINK_RUN_SOURCE = '''
#include <crt_externs.h>
#include <string.h>
#include <unistd.h>
__attribute__((constructor)) static void ProbeAnswersItsLinkRun(void)
{
    if (*_NSGetArgc() == 2 && strcmp((*_NSGetArgv())[1], "%s") == 0) _exit(0);
}
''' % LINK_RUN


class ProbeNotBuilt(RuntimeError):
    """The probe does not start, for something a placeholder does not mend."""


def assembly(placeholders):
    """The placeholders: each symbol at eight zeroed bytes."""
    return '.data\n' + ''.join('.globl %s\n%s: .quad 0\n' % (s, s) for s in sorted(placeholders))


def class_of(symbol):
    """The Objective-C class a symbol is the class or the metaclass of, or None."""
    for prefix in CLASS_SYMBOLS:
        if symbol.startswith(prefix):
            return symbol[len(prefix):]
    return None


def classes(placeholders):
    """The Objective-C classes the placeholders stand in for."""
    return sorted({class_of(s) for s in placeholders} - {None})


def ending(returncode):
    """How a run ended, a signal by its name."""
    if returncode >= 0:
        return 'ended with status %d' % returncode
    try:
        return 'was killed by %s (signal %d)' % (signal.Signals(-returncode).name, -returncode)
    except ValueError:
        return 'was killed by signal %d' % -returncode


def not_built(what, how, placeholders, stderr=''):
    lines = ['%s %s: the probe is not built.' % (what, how)]
    stood_in = classes(placeholders)
    others = [s for s in sorted(placeholders) if class_of(s) is None]
    if not placeholders:
        lines.append('It is linked with no placeholder.')
    else:
        lines.append('It is linked with %d zeroed placeholder%s.' % (len(placeholders), '' if len(placeholders) == 1 else 's'))
    if stood_in:
        lines.append('Standing in for Objective-C classes: %s. A zeroed class kills the load when a linked object '
                     'extends it with a category or subclasses it: link the module or the object that defines the '
                     'class, or give it a stub class.' % ', '.join(stood_in))
    if others:
        lines.append('%s: %s.' % ('The others' if stood_in else 'None stands in for an Objective-C class', ', '.join(others)))
    text = stderr.decode('utf-8', 'replace') if isinstance(stderr, bytes) else stderr or ''
    tail = text.strip().splitlines()[-15:]
    lines.append('Its standard error ended with:' if tail else 'It wrote nothing to its standard error.')
    return ProbeNotBuilt('\n'.join(lines + ['    ' + line[:400] for line in tail]))


def missing_symbol(run, placeholders):
    """The symbol dyld could not find for a completed run, the next
    placeholder, or None when dyld named none. A symbol that already has its
    placeholder cannot be satisfied."""
    stderr = run.stderr.decode('utf-8', 'replace') if isinstance(run.stderr, bytes) else run.stderr or ''
    missing = MISSING.search(stderr)
    if missing is None:
        return None
    if missing.group(1) in placeholders:
        raise ProbeNotBuilt('cannot satisfy %s' % missing.group(1))
    return missing.group(1)


def verdict(run, placeholders, what='the link probe'):
    """What a completed run that tells whether the probe is linked says: None
    when it answered 0, the probe is linked; the symbol dyld could not find,
    the next placeholder. ProbeNotBuilt for any other end."""
    missing = missing_symbol(run, placeholders)
    if missing is None and run.returncode != 0:
        raise not_built(what, ending(run.returncode), placeholders, run.stderr)
    return missing


def probe(executable, placeholders, what='the link probe', *, timeout=60):
    """Runs the link run of the probe `executable`: its verdict(). A run that
    does not end in `timeout` seconds is not built either."""
    try:
        run = subprocess.run([str(executable), LINK_RUN], capture_output=True, text=True, errors='replace', timeout=timeout)
    except subprocess.TimeoutExpired as expired:
        raise not_built(what, 'did not end in %g s' % timeout, placeholders, expired.stderr) from None
    return verdict(run, placeholders, what)
