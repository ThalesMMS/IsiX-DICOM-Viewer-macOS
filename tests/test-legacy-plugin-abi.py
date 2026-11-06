#!/usr/bin/env python3
"""A plugin built for Horos or OsiriX finds in the application the binary
surface it was linked against.

A .horosplugin or .osirixplugin is not rebuilt. Its binary looks up in the
running application the classes, selectors, instance variables, constants,
notifications and C functions of the SDK it was compiled with, and its load
commands name the SDK frameworks. tests/legacy-plugin-abi.json records that
surface as the Horos.framework SDK of IsiX 5.3.4 published it, before only
plugin API 1 bundles were loaded, together with the host methods the plugins of
horosproject/horosplugins call without the SDK declaring them. "about" and
"host_resolution" in the file say where each part comes from and how the host
resolved the symbols for a plugin.

Checked against the built application bundle (its executable and every Mach-O
file under Contents/Frameworks, all of which a flat lookup searches):

- frameworks: Contents/Frameworks/<name>.framework/Versions/A/<name> exists
  and exports the symbols listed for it;
- classes: _OBJC_CLASS_$_<name> and _OBJC_METACLASS_$_<name> are exported,
  and the former superclass is still the class's superclass or an ancestor of
  it;
- selectors and used_outside_sdk ("Class -selector", "Class +selector"): the
  class or one of its ancestors implements the method, in the application's
  Objective-C metadata (classes and categories) or, past the application's
  classes, in the system class the chain reaches; for a system class the SDK
  extended, in the application's category or in the system class; for the
  class of a Core Data entity, also an accessor Core Data generates for a
  property of the entity in the current version of the bundle's model;
- ivars ("Class.ivar"): _OBJC_IVAR_$_Class.ivar is exported;
- symbols (constants, notifications, C functions): the symbol is exported.

"missing" lists, with its reason, each item of the other sections that is
absent today ("<section> <item>"); those are not required. The list only
shrinks: an entry whose item is present again fails, so that the entry goes
with the change that restored it, and so does an entry that names no item of
the registry. Every other item must be present. The file keeps the canonical
text written by render(): sections and entries sorted, one entry per line.

The value of a selector, ivar or symbol is the number of known plugins that
use it. The reorganization of the central classes and the removal of @objc
that nothing needs may take out an item no known plugin uses (value 0): its
missing entry then gives RETIRED as its reason. An item a known plugin uses
cannot be retired that way.

    python3 tests/test-legacy-plugin-abi.py [--release | --app APP] [--registry FILE]

--app checks another bundle (by default the Debug build in build/Build/
Products); --registry checks another registry. A copy of the executable with
one selector renamed in its method names, given with --app, must fail: that is
how the test is shown to catch a removed selector.

--release checks the Release build in build/Build/Products, which
HOROS_DEV_CONFIGURATION=Release script/build_and_run.sh --verify produces. A
change to this surface is accepted when the test passes against both builds.
The Debug build has testability on, which exports the symbols of internal Swift
declarations and keeps every global symbol through dead stripping; the Release
build does neither, so a class or a function the Debug build exports can be
private external, or gone, in Release. A Swift class or @_cdecl function a
plugin looks up is therefore @usableFromInline, which gives its symbol public
linkage, and an Objective-C function the application does not call is marked
used.

Exit status 2 when the bundle or dyld_info/nm (Xcode command line tools) are
missing.
"""
import argparse
import ctypes
import json
import plistlib
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REGISTRY = ROOT / 'tests/legacy-plugin-abi.json'
DEFAULT_APP = ROOT / 'build/Build/Products/Debug/IsiX DICOM Viewer.app'
RELEASE_APP = ROOT / 'build/Build/Products/Release/IsiX DICOM Viewer.app'
SKIPPED = 2
# Sections whose entries are checked; a key of "missing" is "<section> <entry>".
CHECKED = ('frameworks', 'classes', 'selectors', 'used_outside_sdk', 'ivars', 'symbols')
SECTIONS = set(CHECKED) | {'about', 'host_resolution', 'missing'}
# The reason of a missing entry whose item was taken out on purpose; only an
# item with a use count of 0 may have it.
RETIRED = 'retired by the reorganization of the application: no known plugin uses it'
# The system frameworks whose classes the SDK's classes descend from or extend.
SYSTEM_FRAMEWORKS = ('Foundation', 'AppKit', 'CoreData', 'QuartzCore', 'CoreImage', 'Quartz', 'PDFKit',
                     'WebKit', 'AVFoundation', 'AVKit')
SELECTOR_ENTRY = re.compile(r'^(\S+) ([-+])(\S+)$')
INTERFACE = re.compile(r'^@interface ([^\s(:]+)(\([^)]*\))?\s*(?::\s*(\S+))?')
METHOD = re.compile(r'^(?:0x[0-9A-Fa-f]+\s+)?([-+])\[(\S+) (\S+)\]$')


def render(registry):
    """The registry's canonical text: sections and entries sorted, one entry per line."""
    lines = ['{']
    names = sorted(registry)
    for i, name in enumerate(names):
        value = registry[name]
        comma = ',' if i < len(names) - 1 else ''
        if not isinstance(value, dict):
            lines.append(f' {json.dumps(name)}: {json.dumps(value, ensure_ascii=False)}{comma}')
            continue
        lines.append(f' {json.dumps(name)}: {{')
        keys = sorted(value)
        for j, key in enumerate(keys):
            lines.append(f'  {json.dumps(key, ensure_ascii=False)}: '
                         f'{json.dumps(value[key], sort_keys=True, ensure_ascii=False)}'
                         + (',' if j < len(keys) - 1 else ''))
        lines.append(' }' + comma)
    lines.append('}')
    return '\n'.join(lines) + '\n'


def tools_available():
    return all(shutil.which(tool) for tool in ('dyld_info', 'nm'))


def bundle_images(app):
    """The executable of the bundle and every Mach-O file under Contents/Frameworks."""
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    images = [app / 'Contents/MacOS' / info['CFBundleExecutable']]
    frameworks = app / 'Contents/Frameworks'
    if frameworks.is_dir():
        for path in sorted(frameworks.rglob('*')):
            if path.is_file() and not path.is_symlink() and is_macho(path):
                images.append(path)
    return images


def is_macho(path):
    with open(path, 'rb') as handle:
        magic = handle.read(4)
    return magic in (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca')


def exported_symbols(path):
    """Names of the external symbols the image defines."""
    run = subprocess.run(['nm', '-gUj', str(path)], capture_output=True, text=True)
    if run.returncode != 0:
        raise SystemExit(f'nm failed on {path}: {run.stderr.strip()[-300:]}')
    return {line.strip() for line in run.stdout.splitlines() if line.strip() and not line.endswith(':')}


def objc_metadata(path):
    """{class: {'super': name or None, 'defined': bool, '-': {sel}, '+': {sel}}}
    from the image's Objective-C classes and categories. A class only extended
    by a category of the image ('defined' False) is a system class."""
    run = subprocess.run(['dyld_info', '-objc', str(path)], capture_output=True, text=True)
    if run.returncode != 0:
        raise SystemExit(f'dyld_info failed on {path}: {run.stderr.strip()[-300:]}')
    classes = {}
    in_class = False
    for line in run.stdout.splitlines():
        text = line.strip()
        if text.startswith('@protocol'):
            in_class = False
            continue
        interface = INTERFACE.match(text)
        if interface:
            in_class = True
            entry = classes.setdefault(interface.group(1), {'super': None, 'defined': False, '-': set(), '+': set()})
            if not interface.group(2):
                entry['defined'] = True
                entry['super'] = interface.group(3)
            continue
        if text == '@end':
            in_class = False
            continue
        method = METHOD.match(text) if in_class else None
        if method:
            entry = classes.setdefault(method.group(2), {'super': None, 'defined': False, '-': set(), '+': set()})
            entry[method.group(1)].add(method.group(3))
    return classes


def managed_properties(app):
    """{class: {property}} of the entities of the bundle's Core Data models, in
    their current version, with the properties of their parent entities.
    Core Data generates the accessors of these properties when they are first
    called, so they are not in the Objective-C metadata of the executable."""
    found = {}
    for momd in sorted((app / 'Contents/Resources').glob('*.momd')):
        version = plistlib.loads((momd / 'VersionInfo.plist').read_bytes())['NSManagedObjectModel_CurrentVersionName']
        objects = plistlib.loads((momd / f'{version}.mom').read_bytes())['$objects']

        def resolve(uid):
            return objects[uid.data] if isinstance(uid, plistlib.UID) and uid.data else None

        def properties(entity):
            names = set()
            while entity:
                names |= {resolve(key) for key in resolve(entity['NSProperties'])['NS.keys']}
                entity = resolve(entity.get('NSSuperentity'))
            return names

        for item in objects:
            if isinstance(item, dict) and (resolve(item.get('$class')) or {}).get('$classname') == 'NSEntityDescription':
                name = resolve(item.get('NSClassNameForEntity'))
                if name:
                    found.setdefault(name, set()).update(properties(item))
    return found


def managed_accessor(properties, selector):
    """Whether Core Data generates `selector` for one of `properties`: the getter,
    the setter, or the add/remove methods of a to-many relationship."""
    if selector in properties:
        return True
    match = re.fullmatch(r'set(\w+):', selector) or re.fullmatch(r'(?:add|remove)(\w+?)(?:Object)?:', selector)
    return bool(match) and match.group(1)[:1].lower() + match.group(1)[1:] in properties


class SystemRuntime:
    """The system's Objective-C classes, through the runtime of this process."""

    def __init__(self):
        self.objc = ctypes.cdll.LoadLibrary('/usr/lib/libobjc.A.dylib')
        for name in SYSTEM_FRAMEWORKS:
            try:
                ctypes.cdll.LoadLibrary(f'/System/Library/Frameworks/{name}.framework/{name}')
            except OSError:
                pass
        self.objc.objc_lookUpClass.restype = ctypes.c_void_p
        self.objc.objc_lookUpClass.argtypes = [ctypes.c_char_p]
        self.objc.sel_registerName.restype = ctypes.c_void_p
        self.objc.sel_registerName.argtypes = [ctypes.c_char_p]
        for function in ('class_getInstanceMethod', 'class_getClassMethod'):
            getattr(self.objc, function).restype = ctypes.c_void_p
            getattr(self.objc, function).argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        self.objc.class_getSuperclass.restype = ctypes.c_void_p
        self.objc.class_getSuperclass.argtypes = [ctypes.c_void_p]
        self.objc.class_getName.restype = ctypes.c_char_p
        self.objc.class_getName.argtypes = [ctypes.c_void_p]

    def has_class(self, name):
        return bool(self.objc.objc_lookUpClass(name.encode()))

    def responds(self, name, kind, selector):
        cls = self.objc.objc_lookUpClass(name.encode())
        if not cls:
            return False
        lookup = self.objc.class_getInstanceMethod if kind == '-' else self.objc.class_getClassMethod
        return bool(lookup(cls, self.objc.sel_registerName(selector.encode())))

    def ancestors(self, name):
        cls = self.objc.objc_lookUpClass(name.encode())
        chain = []
        while cls:
            cls = self.objc.class_getSuperclass(cls)
            if cls:
                chain.append(self.objc.class_getName(cls).decode())
        return chain


class Surface:
    """What a bundle offers a plugin: exported symbols and Objective-C methods."""

    def __init__(self, app, runtime=None):
        self.app = Path(app)
        self.images = bundle_images(self.app)
        self.exports = set()
        self.classes = {}
        for image in self.images:
            self.exports |= exported_symbols(image)
            for name, entry in objc_metadata(image).items():
                merged = self.classes.setdefault(name, {'super': None, 'defined': False, '-': set(), '+': set()})
                if entry['defined']:
                    merged['defined'] = True
                    merged['super'] = entry['super']
                merged['-'] |= entry['-']
                merged['+'] |= entry['+']
        self.managed = managed_properties(self.app)
        self.runtime = runtime or SystemRuntime()

    def chain(self, name):
        """The class and its ancestors: the application's classes, then the system's."""
        chain = []
        while name and name not in chain:
            chain.append(name)
            entry = self.classes.get(name)
            if entry and entry['defined']:
                name = entry['super']
                continue
            return chain + [n for n in self.runtime.ancestors(name) if n not in chain]
        return chain

    def implements(self, name, kind, selector):
        for cls in self.chain(name):
            entry = self.classes.get(cls)
            if entry and selector in entry[kind]:
                return True
            if kind == '-' and cls in self.managed and managed_accessor(self.managed[cls], selector):
                return True
            if not (entry and entry['defined']) and self.runtime.responds(cls, kind, selector):
                return True
        return False

    def class_present(self, name):
        return f'_OBJC_CLASS_$_{name}' in self.exports and f'_OBJC_METACLASS_$_{name}' in self.exports

    def framework_present(self, name, symbols):
        executable = self.app / 'Contents/Frameworks' / f'{name}.framework/Versions/A' / name
        if not executable.is_file():
            return False
        return set(symbols) <= exported_symbols(executable)


def absent(registry, surface):
    """The keys ("<section> <item>") of the registry's items the bundle lacks."""
    lacking = set()
    for name, framework in registry['frameworks'].items():
        if not surface.framework_present(name, framework['symbols']):
            lacking.add(f'frameworks {name}')
    for name, superclass in registry['classes'].items():
        if not surface.class_present(name) or (superclass and superclass not in surface.chain(name)[1:]):
            lacking.add(f'classes {name}')
    for section in ('selectors', 'used_outside_sdk'):
        for item in registry[section]:
            cls, kind, selector = SELECTOR_ENTRY.match(item).groups()
            if not surface.implements(cls, kind, selector):
                lacking.add(f'{section} {item}')
    for item in registry['ivars']:
        if f'_OBJC_IVAR_$_{item}' not in surface.exports:
            lacking.add(f'ivars {item}')
    for item in registry['symbols']:
        if item not in surface.exports:
            lacking.add(f'symbols {item}')
    return lacking


def problems(registry, text, surface):
    """Every reason the registry does not hold for the bundle, one line each."""
    found = []
    if set(registry) != SECTIONS:
        return [f'sections must be {sorted(SECTIONS)}, not {sorted(registry)}']
    if text != render(registry):
        found.append('the registry is not in its canonical text (sorted, one entry per line): rewrite it with render()')
    for section in ('selectors', 'used_outside_sdk'):
        found += [f'{section}: "{item}" is not "Class -selector" or "Class +selector"'
                  for item in registry[section] if not SELECTOR_ENTRY.match(item)]
    if found:
        return found
    items = {f'{section} {item}' for section in CHECKED for item in registry[section]}
    missing = registry['missing']
    for key, reason in sorted(missing.items()):
        if key not in items:
            found.append(f'missing: "{key}" names no item of the registry')
        elif not isinstance(reason, str) or not reason.strip():
            found.append(f'missing: "{key}" has no reason')
        elif reason == RETIRED:
            section, entry = key.split(' ', 1)
            if registry[section][entry] != 0:
                found.append(f'missing: "{key}" is used by known plugins and cannot be retired')
    lacking = absent(registry, surface)
    found += [f'absent from the application and not in missing: {key}' for key in sorted(lacking - set(missing))]
    found += [f'present again, remove its missing entry: {key}' for key in sorted(set(missing) & items - lacking)]
    return found


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    bundle = parser.add_mutually_exclusive_group()
    bundle.add_argument('--app', type=Path, default=DEFAULT_APP)
    bundle.add_argument('--release', dest='app', action='store_const', const=RELEASE_APP,
                        help='check the Release build in build/Build/Products')
    parser.add_argument('--registry', type=Path, default=REGISTRY)
    args = parser.parse_args(argv)
    if not tools_available():
        print('skipped: needs dyld_info and nm (Xcode command line tools)', file=sys.stderr)
        return SKIPPED
    if not (args.app / 'Contents/Info.plist').is_file():
        print(f'skipped: needs a built IsiX DICOM Viewer.app (script/build_and_run.sh --verify): --app {args.app}',
              file=sys.stderr)
        return SKIPPED
    text = args.registry.read_text(encoding='utf-8')
    registry = json.loads(text)
    surface = Surface(args.app)
    found = problems(registry, text, surface)
    for line in found:
        print('FAIL: ' + line)
    if found:
        print(f'FAIL: {len(found)} problems against {args.app}')
        return 1
    checked = sum(len(registry[section]) for section in CHECKED)
    print(f'PASS: {checked - len(registry["missing"])} of {checked} items of the former plugin SDK are in '
          f'{args.app.name}; {len(registry["missing"])} are listed as missing, each with its reason')
    return 0


if __name__ == '__main__':
    sys.exit(main())
