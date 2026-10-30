"""Link a probe against an object file the app is compiled from, and run it.

Several tests link the app's own `DCMPix.o` into a small program, so they
measure the shipped code. The object names symbols the app resolves from its
other objects; the probe links with `-undefined dynamic_lookup` and gives each
one the runtime asks for a bare address, which is enough for code the probe
never reaches.

Classes are different: the runtime fixes class references and attaches
categories when the image loads, so a class at a zero address crashes the probe
before it starts. So:

* the internal modules the object refers to (Modules/, see isix_modules) are
  linked, built from this checkout, and their classes are the real ones;
* every other class the project declares - in the app's sources or in the DCM
  Framework, whose `DCMObject` DCMPix.m extends with a category - gets an empty
  stub class;
* for `DCMPix.o`, the parts of DCMPix that left DCMPix.m for Swift extensions
  (DCMPix+<area>.swift) are linked as the same build compiled them, with the
  app Swift and Objective-C they need - unless the object still has that part
  itself (a revision before the move). Once the class itself is Swift,
  `DCMPix.o` is DCMPix.swift's object and every part of the class is linked.

`HOROS_PROBE_OBJECT`, when set, is linked instead of the built object: a test
can then be run against a deliberately changed object, to see it fail.
"""
from pathlib import Path
import os
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
sys.path.insert(0, str(ROOT / 'tests'))
import isix_modules  # noqa: E402
import object_probe  # noqa: E402

FRAMEWORKS = ('Foundation', 'AppKit', 'AVFoundation', 'CoreData', 'CoreMedia', 'CoreVideo', 'Accelerate')
PROJECT_FOLDERS = (ROOT / 'Horos/Sources', ROOT / 'Horos/Sources/Adapters/DCMTK')


def built_object(name='DCMPix'):
    """The object to probe: `HOROS_PROBE_OBJECT`, or the newest one a Debug or Release build left."""
    override = os.environ.get('HOROS_PROBE_OBJECT')
    if override:
        return Path(override)
    return object_probe.first_app_object(name)


def referenced_classes(objects):
    names = set()
    for obj in objects:
        listing = subprocess.run(['nm', '-u', str(obj)], capture_output=True, text=True, check=True).stdout
        names |= set(re.findall(r'_OBJC_CLASS_\$_(\w+)', listing))
    return names


# A method of the Objective-C class: an object that defines it is DCMPix.m's.
CLASS_MARKER = '-[DCMPix CheckLoad]'
# The Swift extensions of DCMPix, and a method each still defines in DCMPix.m
# before its part moved: an object that has it does not get the extension.
DCMPIX_EXTENSIONS = {
    'DCMPix+ROIMeasure': '-[DCMPix getROIValue:::]',
    'DCMPix+ROIFill': '-[DCMPix fillROI:newVal:minValue:maxValue:outside:orientationStack:stackNo:restore:addition:]',
    'DCMPix+NonDICOM': '-[DCMPix LoadLSM]',
    'DCMPix+Database': '-[DCMPix imageObj]',
    'DCMPix+Annotations': '-[DCMPix loadCustomImageAnnotationsPapyLink:DCMLink:]',
    # Read inline in -loadDICOMWithDCMTK before, which moved with the database links.
    'DCMPix+EncapsulatedDocuments': '-[DCMPix imageObj]',
    # Not DCMPix+RTStruct: DCMPix.m does not call it, and it would bring ROI with it.
    # The coordinates the probes convert, and the rendering.
    'DCMPix+Geometry': '-[DCMPix convertPixX:pixY:toDICOMCoords:pixelCenter:]',
    # The 8-bit picture -setfImage: drops, and what it is made from.
    'DCMPix+Display': '-[DCMPix kill8bitsImage]',
    'DCMPix+DisplaySource': '-[DCMPix computefImage]',
    # The rest of the class, Swift with it: its loading, its attributes, the
    # subtraction, the SUV, key-value coding by former instance variable, the
    # preferences.
    'DCMPix+Loading': CLASS_MARKER,
    'DCMPix+FrameLoading': CLASS_MARKER,
    'DCMPix+ImageAttributes': CLASS_MARKER,
    'DCMPix+Subtraction': CLASS_MARKER,
    'DCMPix+SUV': CLASS_MARKER,
    'DCMPix+KeyValueCoding': CLASS_MARKER,
    'DCMPixSettings': CLASS_MARKER,
}
# Properties of DCMPix declared today by a Swift extension: a DCMPix.m from
# before synthesizes them, which today's headers refuse.
DCMPIX_SWIFT_PROPERTIES = ('annotationsDictionary', 'annotationsDBFields')


def dcmpix_source_for_current_headers(source):
    """The bytes of a DCMPix.m of any revision, without the @synthesize of the
    properties a Swift extension declares today; the ivars are still there."""
    def kept(match):
        names = [n for n in match.group(1).split(',') if n.split('=')[0].strip() not in DCMPIX_SWIFT_PROPERTIES]
        return '@synthesize' + ','.join(names) + ';' if names else ''
    text = source.decode('latin1')
    return re.sub(r'@synthesize([^;]*);', kept, text).encode('latin1')


# The Objective-C of the app the extensions call: the accessors of the
# Objective-C class's instance variables while it had them; once the class is
# Swift, what it keeps in Objective-C and the parser's attribute source.
DCMPIX_EXTENSION_OBJC = ('DCMPix+SwiftIvars', 'HorosObjCException', 'DCMPix+NonDICOMCAPI')
DCMPIX_CLASS_OBJC = ('DCMPix+CAPI', 'DCMObject+IsiXAttributeSource')


def dcmpix_extensions(obj):
    """The build's objects of the Swift extensions of DCMPix that `obj` lacks,
    with the app Swift (by the symbols they need) and Objective-C they call."""
    if obj.stem != 'DCMPix':
        return []
    folder = obj.parent if any((obj.parent / f'{name}.o').is_file() for name in ('DCMPix+SwiftIvars', 'DCMPix+CAPI')) else None
    if folder is None:
        configuration = os.environ.get('HOROS_TEST_CONFIGURATION')
        built = object_probe.app_object('DCMPix', configuration) if configuration else object_probe.first_app_object('DCMPix')
        folder = built.parent if built else None
    if folder is None:
        return []
    listing = subprocess.run(['nm', '-g', '--defined-only', '-j', str(obj)], capture_output=True, text=True).stdout + \
        subprocess.run(['nm', '-j', str(obj)], capture_output=True, text=True).stdout
    wanted = [name for name, marker in DCMPIX_EXTENSIONS.items()
              if marker not in listing and (folder / f'{name}.o').is_file()]
    if not wanted:
        return []
    import roi_harness  # noqa: E402  (its closure of the app's Swift objects)
    swift = roi_harness.swift_closure(folder, wanted)
    objc = DCMPIX_EXTENSION_OBJC + (DCMPIX_CLASS_OBJC if CLASS_MARKER not in listing else ())
    return swift + [folder / f'{name}.o' for name in objc if (folder / f'{name}.o').is_file()]


def defined_classes(objects):
    names = set()
    for obj in objects:
        listing = subprocess.run(['nm', '-g', '--defined-only', str(obj)], capture_output=True, text=True, check=True).stdout
        names |= set(re.findall(r'_OBJC_CLASS_\$_(\w+)', listing))
    return names


def module_link(objects, folder):
    """Linker flags for the internal modules the objects refer to, and the classes those define."""
    flags, classes = [], set()
    for obj in objects:
        # swiftc flags: -I folder -L folder -lName for each module.
        swift_flags, defined = isix_modules.object_link_flags(obj, folder)
        classes |= defined
        for index, flag in enumerate(swift_flags):
            if flag == '-L':
                flags.append('-L' + swift_flags[index + 1])
            elif flag.startswith('-l'):
                flags.append(flag)
    if flags:
        sdk = subprocess.run(['xcrun', '--show-sdk-path'], capture_output=True, text=True, check=True).stdout.strip()
        flags += ['-L/usr/lib/swift', '-L' + sdk + '/usr/lib/swift']
    return list(dict.fromkeys(flags)), classes


def stubs(objects, linked=(), probe_classes=(), always=()):
    """An Objective-C source with an empty class for every project class the
    objects name, except those the linked modules or the probe define; `always`
    are stubbed whether or not the objects name them."""
    names = referenced_classes(objects) - set(linked) - set(probe_classes) - defined_classes(objects)
    declared = sorted(n for n in names
                      if any((folder / (n + suffix)).is_file()
                             for folder in PROJECT_FOLDERS for suffix in ('.h', '.m', '.mm')))
    declared = sorted(set(declared) | set(always))
    return '#import <Foundation/Foundation.h>\n' + ''.join(
        '@interface %s : NSObject @end\n@implementation %s @end\n' % (n, n) for n in declared)


def link_and_run(work, sources, objects, run_arguments=(), *, compiler=('xcrun', 'clang++', '-std=c++11'),
                 flags=(), frameworks=FRAMEWORKS, probe_classes=(), always_stub=(), timeout=120, attempts=200,
                 runner=None, headers=ROOT / 'Horos/Sources'):
    """Links `sources` with `objects` into `work`/probe and runs it with `run_arguments`.

    Returns the completed run, or what `runner(probe)` returns - one completed
    run or a list of them - when the probe has to run more than once. Raises
    RuntimeError when a symbol cannot be satisfied; subprocess.TimeoutExpired
    when the probe does not finish.
    """
    work = Path(work)
    objects = [Path(o) for o in objects]
    # The extensions and the app Swift they call, but not an object defining a
    # class the probe implements itself or has stubbed: the probe's own one is wanted.
    texts = [Path(source).read_text(errors='replace') for source in sources]
    standing_in = set(always_stub) | {name for name in probe_classes
                                       if any(re.search(r'@implementation\s+%s\b' % re.escape(name), text) for text in texts)}
    objects += [extension for o in list(objects) for extension in dcmpix_extensions(o)
                if extension not in objects and not defined_classes([extension]) & standing_in]
    linked_flags, linked_classes = module_link(objects, work / 'modules')
    # DCMModel.h, which the application's headers import for the dataset
    # model, imports the Objective-C headers of the internal modules.
    isix_modules.build_module('IsiXDICOMDataset', work / 'modules')
    (work / 'stubs.mm').write_text(stubs(objects, linked_classes, probe_classes, always_stub))
    placeholders = set()
    probe = work / 'probe'
    for _ in range(attempts):
        assembly = ''.join('.globl %s\n%s: .quad 0\n' % (s, s) for s in sorted(placeholders))
        (work / 'placeholders.s').write_text('.data\n' + assembly)
        command = [*compiler, '-Wno-deprecated-declarations', '-I' + str(headers), '-I' + str(work / 'modules'), *flags,
                   *map(str, sources), str(work / 'stubs.mm'), str(work / 'placeholders.s'), *map(str, objects),
                   *linked_flags, '-Wl,-undefined,dynamic_lookup', '-o', str(probe)]
        for framework in frameworks:
            command += ['-framework', framework]
        built = subprocess.run(command, capture_output=True, text=True)
        if built.returncode:
            raise RuntimeError('the probe does not link:\n' + built.stderr[-3000:])
        if runner:
            result = runner(probe)
        else:
            result = subprocess.run([str(probe), *map(str, run_arguments)], capture_output=True, text=True,
                                    timeout=timeout)
        missing = [m.group(1) for run in (result if isinstance(result, list) else [result])
                   for m in [re.search(r"symbol not found in flat namespace '([^']+)'", run.stderr)] if m]
        if not missing:
            return result
        if missing[0] in placeholders:
            raise RuntimeError('cannot satisfy %s' % missing[0])
        placeholders.add(missing[0])
    raise RuntimeError('too many unresolved symbols in %s' % ', '.join(map(str, objects)))
