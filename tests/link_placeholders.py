"""What a run of a probe says of the placeholders it is linked with.

A probe linked out of the app's objects with `-undefined dynamic_lookup` names
symbols that nothing it links defines. dyld refuses to start it while one of
them is a datum, naming one per run; roi_harness.build(),
app_object_probe.link_and_run() and the tests with a loop of their own give
each symbol named a placeholder, eight zeroed bytes, link again and ask again,
until the probe starts. That is enough for what the probe never reaches.

The loops ask lacking(), which answers every symbol the probe lacks at once
when they can be read from it: the ROI's closure lacks some 480, and a link
for each of them, of the same objects, was most of the time such a test
took. A placeholder is zeroed data that refers to nothing, so the symbols a
probe lacks with one placeholder more are the same ones less that one: given
all at once or one per link, the probe ends with the same placeholders.

The symbol is found without running the probe. A run that dyld refuses is an
abort, and every abort leaves a crash report in ~/Library/Logs/
DiagnosticReports under the probe's name: one for each placeholder of each
build, among the reports of the user's own applications. unbound_symbol()
reads from the executable the pointers dyld fills as the image loads with a
symbol of the flat namespace, and asks a process that has loaded the
libraries the probe loads whether each symbol is there. The probe is run only
once none is missing, and that run still judges: what dyld would name
against what was read here is the next placeholder all the same. A library
the probe names through a run path is found as dyld finds it; the runtime of
a sanitizer, which no process can load once it has started, is not loaded
there, and the symbols it exports are read from it.

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
import json
from pathlib import Path
import re
import signal
import subprocess
import sys

MISSING = re.compile(r"symbol not found in flat namespace '([^']+)'")
# A pointer dyld fills as the image loads with a symbol of the flat namespace,
# as `dyld_info -fixups` lists it: segment, section, address, "bind", target.
# A "lazy-bind" is a function looked up when it is first called, which dyld
# does not ask for to start the probe.
LOAD_BIND = re.compile(r'^\s*\S+\s+\S+\s+0x[0-9A-Fa-f]+\s+bind\s+<flat-namespace>/(\S+)(.*)$', re.M)
# Asked of a process of its own: the libraries the probe loads, with all they
# load in turn, and whether the flat namespace they make holds each symbol.
# It answers those that are not there, in the order asked, or the library it
# could not load.
RESOLVER = r'''
import ctypes, json, sys
asked = json.load(sys.stdin)
for library in asked['libraries']:
    try:
        ctypes.CDLL(library, mode=ctypes.RTLD_GLOBAL)
    except OSError:
        print(json.dumps({'unloaded': library}))
        sys.exit(0)
dlsym = ctypes.CDLL(None).dlsym
dlsym.restype = ctypes.c_void_p
dlsym.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
RTLD_DEFAULT = ctypes.c_void_p(-2)
# The linker's name of a C symbol has an underscore dlsym() adds by itself.
print(json.dumps({'missing': [symbol for symbol in asked['symbols']
                              if not dlsym(RTLD_DEFAULT, symbol[1:].encode())]}))
'''
# A folder a library named @rpath/ is looked for in, as `otool -l` lists the load command.
RUN_PATH = re.compile(r'cmd LC_RPATH\n\s*cmdsize \d+\n\s*path (.+?) \(offset \d+\)')
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


def load_binds(executable):
    """The symbols of the flat namespace dyld has to find to start
    `executable`, in the order of its fixups, each once: the weak imports,
    which may be absent, are not among them. None when dyld_info cannot say."""
    try:
        listed = subprocess.run(['xcrun', 'dyld_info', '-fixups', str(executable)], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if listed.returncode != 0 or '-fixups:' not in listed.stdout:
        return None
    return list(dict.fromkeys(symbol for symbol, rest in LOAD_BIND.findall(listed.stdout) if 'weak-import' not in rest))


def beside(executable, path):
    """`path` with @executable_path or @loader_path as the folder of `executable`."""
    for prefix in ('@executable_path', '@loader_path'):
        if path == prefix or path.startswith(prefix + '/'):
            return str(Path(executable).resolve().parent) + path[len(prefix):]
    return path


def run_paths(executable):
    """The folders `executable` has a library named @rpath/ looked for in, in its order."""
    try:
        listed = subprocess.run(['xcrun', 'otool', '-l', str(executable)], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return []
    return [beside(executable, path) for path in RUN_PATH.findall(listed.stdout)] if listed.returncode == 0 else []


def loaded_libraries(executable):
    """The libraries `executable` names to load, as paths: one named through
    a run path is the first there is in the executable's run paths, as dyld
    takes it. None when they cannot be listed, or when one is not found."""
    try:
        listed = subprocess.run(['xcrun', 'otool', '-L', str(executable)], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if listed.returncode != 0:
        return None
    libraries = []
    for line in listed.stdout.splitlines()[1:]:
        library = beside(executable, line.strip().split(' (compatibility version')[0])
        if library.startswith('@rpath/'):
            library = next((found for found in (folder + library[len('@rpath'):] for folder in run_paths(executable))
                            if Path(found).is_file()), library)
        if library.startswith('@') or not library:
            return None
        libraries.append(library)
    return libraries


def loads_late(library):
    """Whether the asking process can load `library`. A sanitizer's runtime
    (a probe compiled with -fsanitize) ends a process that loads it once the
    process has started."""
    return not Path(library).name.startswith('libclang_rt.')


def exported_symbols(library):
    """The symbols `library` gives the flat namespace, read from it. None when they cannot be read."""
    try:
        listed = subprocess.run(['nm', '-g', '--defined-only', '-j', str(library)], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return set(listed.stdout.split()) if listed.returncode == 0 else None


def unbound_symbols(executable):
    """The symbols dyld would not find as it loads `executable`, in the order
    of its fixups, told without running it; none when it would find them all.
    None either when that cannot be told here - no dyld_info, a library that is
    not found or does not load, a name dlsym() cannot be asked: the run of the
    probe says it then, as it always did."""
    symbols = load_binds(executable)
    if not symbols:
        return []
    libraries = loaded_libraries(executable)
    if libraries is None or not all(symbol.startswith('_') for symbol in symbols):
        return []
    # A library the asking process cannot load is not loaded there: what it
    # exports is read from it, and is not missing.
    given = set()
    for library in libraries:
        if not loads_late(library):
            exported = exported_symbols(library)
            if exported is None:
                return []
            given |= exported
    try:
        asked = subprocess.run([sys.executable, '-c', RESOLVER],
                               input=json.dumps({'libraries': [library for library in libraries if loads_late(library)], 'symbols': symbols}),
                               capture_output=True, text=True, timeout=60)
        answer = json.loads(asked.stdout) if asked.returncode == 0 else {}
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return []
    return [symbol for symbol in answer.get('missing') or [] if symbol not in given]


def unbound_symbol(executable):
    """The first of unbound_symbols(), or None."""
    return next(iter(unbound_symbols(executable)), None)


def lacking(executable, placeholders, what='the link probe', *, timeout=60):
    """Whether the probe `executable` is linked: the symbols it lacks, each to
    be given a placeholder before the next link, none when it is linked. All
    of them when they can be read from it without a run (unbound_symbols),
    else the one the verdict() of its link run names. A run that does not end
    in `timeout` seconds is not built either."""
    missing = unbound_symbols(executable)
    if missing:
        for symbol in missing:
            if symbol in placeholders:
                raise ProbeNotBuilt('cannot satisfy %s' % symbol)
        return missing
    try:
        run = subprocess.run([str(executable), LINK_RUN], capture_output=True, text=True, errors='replace', timeout=timeout)
    except subprocess.TimeoutExpired as expired:
        raise not_built(what, 'did not end in %g s' % timeout, placeholders, expired.stderr) from None
    named = verdict(run, placeholders, what)
    return [] if named is None else [named]


def probe(executable, placeholders, what='the link probe', *, timeout=60):
    """The first symbol of lacking(), or None when the probe is linked: what a
    loop that gives one placeholder per link asks."""
    return next(iter(lacking(executable, placeholders, what, timeout=timeout)), None)
