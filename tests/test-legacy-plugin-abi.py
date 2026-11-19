#!/usr/bin/env python3
"""A plugin built for Horos or OsiriX finds in the application the binary
surface it was linked against.

A .horosplugin or .osirixplugin is not rebuilt. Its binary looks up in the
running application the classes, selectors, instance variables, constants,
notifications and C functions of the SDK it was compiled with, and its load
commands name the SDK frameworks. That surface is contract: the application
loads these plugins as they are, and no change takes an item of it out or
renames it. tests/legacy-plugin-abi.json records it from the two SDKs there
were: the headers of the Horos the application started from, with what the
sources that Horos compiled defined, and the headers of the Horos.framework
SDK of IsiX 5.3.4, with what the application that published them exported and
implemented; together with the host methods the plugins of
horosproject/horosplugins call without an SDK declaring them.
tools/inventory-plugin-api.py --registry writes the registry from those
sources and from itself, taking nothing out; "about" in the file says the
sources, what was left out and why, and the command, and "host_resolution" how
the host resolved the symbols for a plugin.

Checked against the built application bundle, one architecture at a time: the
architectures are those of its executable (lipo -archs), and for each of them
the slice of the executable and of every Mach-O file under Contents/Frameworks
that has it, all of which a flat lookup searches. An item absent from only
some architectures fails with their names, as in "symbols _name [x86_64]"; a
universal binary read without naming the slice shows only the slice of the
machine, and would pass with the item missing from the other.

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
  property of the entity in the current version of the bundle's model. The
  system classes are asked through the Objective-C runtime of this process,
  which has the architecture it runs as whatever slice is being checked, and
  a method whose implementation is in /System/Library/PrivateFrameworks does
  not count: the public frameworks the application links bring private ones
  with them, and a private category that happens to have the selector (as
  -shuffle on NSArray, which answers a copy and leaves the receiver alone) is
  not the method the SDK had;
- ivars ("Class.ivar"): _OBJC_IVAR_$_Class.ivar is exported;
- symbols (constants, notifications, C functions): the symbol is exported.

A class written in Swift has no _OBJC_IVAR_$_ symbol of its own: it exports
the offset of a stored field under that name through a linker alias, and
Horos/Scripts/Horos/legacy-plugin-ivars.json is the table of those fields
(tools/legacy_plugin_ivars.py says what an entry is). For every entry of the
table:

- it is in ivars of the registry, is not listed as missing, and its
  _OBJC_IVAR_$_ name is exported in every architecture;
- it has its five fields, a state and an ownership of those the table
  defines, and a symbol that is the offset of the field it names, of a type
  that is what the SDK's C type (sdk) has in memory, with value as the
  ownership of what is not an object and no other;
- where the image that exports the name still has its symbol table (a build
  that was not installed, a published package), the name and the symbol of
  the field are at one address: the alias is of that field and of no other.
  An image stripped of its local symbols has no address to compare, and the
  result line says so.

"missing" lists, with its reason, each item of the other sections that is
absent today ("<section> <item>"); those are not required. The list only
shrinks: an entry whose item is present again fails, so that the entry goes
with the change that restored it, and so does an entry that names no item of
the registry. Every other item must be present. The file keeps the canonical
text written by render(): sections and entries sorted, one entry per line.

A reason does not excuse a class, a symbol or a framework: a plugin that names
one the application lacks is refused whole when it loads, "symbol not found in
flat namespace", so the item comes back instead of being listed. The registry
once listed such items with reasons in free text, and the test passed on a
release that had stopped exporting names of the SDK. The one exception is
"isix5_additions": the classes and symbols that the headers of IsiX 5.3.4
declare and no source of Horos defined, each with the header that declares
it. Horos never had them, so no plugin built for Horos or OsiriX looks them
up, and one of them may be listed as missing, with the reason ISIX5_ADDITION
and no other. That reason on an entry outside the section fails, and so does
an entry of the section that is not a class or a symbol of the registry.

What Horos compiled without declaring it in its SDK, and the IsiX 5 SDK then
declared, is no addition by that rule. The four such items that had not come
back when the rule was written waited in AWAITED_KEYS, listed with the reason
AWAITS_FACADE, and each left the list with the change that brought its item
back: the list is closed and empty, and that reason on any entry fails.

The value of a selector, ivar or symbol is the number of known plugins that
use it. A selector a known plugin sends may not be listed as missing, whatever
the reason given: the plugin raises "unrecognized selector" in the middle of
its work. Nor may an instance variable a known plugin reads: the plugin binds
the name when it loads and is refused whole without it. Nor may any instance
variable be listed with the reason that a Swift stored property has no
_OBJC_IVAR_$_ symbol, which the table disproves; one that waits for its field
says what it waits for.

"sdk_selectors" names the selectors the SDK of Horos declared in its headers
and implemented, each with the header and the line that declares it. They are
contract whatever their count: a plugin nobody listed sends them too. Each is
in "selectors", and none may be excused in "missing", with two exceptions that
end when a class comes back: its class is missing ("its class is missing
(classes X)"), or the class of an object it takes or answers ("takes an object
of a missing class (classes X)"), and "classes X" is in "missing" as well. One
the SDK added to a class of the system counts as present only when the
application's own category has it: a method of the system with that name is
another method.

Before that rule, the reorganization of the central classes took out items no
known plugin used, and their missing entries give RETIRED as their reason.
Nothing more is retired: the reason stays valid for the entries of
RETIRED_KEYS alone, none of them of sdk_selectors, and an entry leaves that
list with the change that brings its item back.

"osirix_selectors" names the selectors that only later headers of the OsiriX
SDK declare and a plugin built with them sends, each with the source of its
name and of its types: a header published as text, or the public headers of
AppKit for what the object such a header declares answers. They are contract
as those of sdk_selectors are: each is in "selectors", and none may be listed
in "missing", whatever the reason. The section is written by hand, and
tools/inventory-plugin-api.py keeps it as it is.

    python3 tests/test-legacy-plugin-abi.py [--debug | --app APP] [--registry FILE] [--table FILE]

The Release build in build/Build/Products is checked, which
HOROS_DEV_CONFIGURATION=Release script/build_and_run.sh --verify produces: it
is the configuration the packages are built with. --debug checks the Debug
build there, and --app another bundle, such as an unpacked package (unpack it
with ditto -x -k, which keeps the links of the frameworks); --registry checks
another registry and --table another table of instance variables. A change to this surface is accepted when the test passes
against the Release build. The Debug build has testability on, which exports
the symbols of internal Swift declarations and keeps every global symbol
through dead stripping; the Release build does neither, so a class or a
function the Debug build exports can be private external, or gone, in Release.
A Swift class or @_cdecl function a plugin looks up is therefore
@usableFromInline, which gives its symbol public linkage, and an Objective-C
function or datum the application does not use is marked used.

The result line names the bundle: its version, its build, the commit and the
state of the tree it was built from (GitHash and GitState of its Info.plist)
and the architectures checked. A build of build/Build/Products made from
another commit than the one checked out is said in a warning, since its result
says nothing of the tree as it is.

A copy of the executable with one selector renamed in its method names, given
with --app, must fail: that is how the test is shown to catch a removed
selector. A registry that excuses a selector of sdk_selectors with any other
reason, or retires an entry that is not in RETIRED_KEYS, must fail as well. A registry with a symbol the bundle does not have, given with
--registry, must fail too; and a universal bundle with a symbol in only one of
its slices must fail with the name of the other.

The rules are shown to refuse at every run, against the bundle being checked:
copies of the registry, of the table and of the bundle's list of exports, each
changed in one thing, must give the line of the rule that thing breaks. A
registry with a symbol the bundle does not export; the bundle without
_pasteBoardOsiriX among its exports, and, where it has several architectures,
without it in one of them, which must be named; a registry that lists as
missing, with a reason of its own, a symbol or a class, or a framework; one
that gives the reason of an addition to a symbol outside isix5_additions, and
one that gives an addition another reason; an isix5_additions that names a
selector, and one that names what the registry does not have; a symbol made to
wait for a facade outside the closed list; a selector that plugins send listed
as missing. Of the instance variables: a
registry that lists as missing a variable a plugin reads, and one that gives
the Swift reason; a table with an entry the registry does not have, which no
bundle exports; a registry that lists an entry of the table as missing; a
table with the symbols of two entries exchanged (where there are addresses to
compare), with the sdk of an entry changed to another C type, with a state
and with an ownership the table does not define. A control that is not
refused fails the test.

Exit status 2 when the bundle or dyld_info, nm and lipo (Xcode command line
tools) are missing.
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
sys.path.insert(0, str(ROOT / 'tools'))
import legacy_plugin_ivars  # noqa: E402

REGISTRY = ROOT / 'tests/legacy-plugin-abi.json'
TABLE = legacy_plugin_ivars.TABLE
IVAR_PREFIX = legacy_plugin_ivars.PREFIX
DEBUG_APP = ROOT / 'build/Build/Products/Debug/IsiX DICOM Viewer.app'
RELEASE_APP = ROOT / 'build/Build/Products/Release/IsiX DICOM Viewer.app'
SKIPPED = 2
# Sections whose entries are checked; a key of "missing" is "<section> <entry>".
CHECKED = ('frameworks', 'classes', 'selectors', 'used_outside_sdk', 'ivars', 'symbols')
SECTIONS = set(CHECKED) | {'about', 'host_resolution', 'missing', 'sdk_selectors', 'osirix_selectors', 'isix5_additions'}
# The sections whose items no reason excuses: a plugin that names a class, a
# symbol or a framework the application lacks is refused whole when it loads.
HARD = ('classes', 'symbols', 'frameworks')
# The one reason a class or a symbol may be listed as missing with, and only one
# of isix5_additions: Horos never had it, so no plugin built for Horos or OsiriX
# looks it up.
ISIX5_ADDITION = 'added by the IsiX 5 SDK: Horos did not define it'
# What Horos compiled without declaring it in its SDK, and the IsiX 5 SDK then
# declared: by the rule above it is not an addition, and it comes back. The
# four that had not when the rule was written waited in this list with this
# reason, and each left it with the change that brought its item back: the list
# is empty, none enters, and the reason is refused on any entry.
AWAITS_FACADE = 'Horos compiled it and only the IsiX 5 SDK declared it: it is not an addition, and comes back as a facade'
AWAITED_KEYS = frozenset()
# The reason of a missing entry whose item was taken out on purpose, before the
# SDK's surface was contract again. No entry takes it any more: it stays valid
# for the keys of RETIRED_KEYS, none of them a selector of sdk_selectors.
RETIRED = 'retired by the reorganization of the application: no known plugin uses it'
# The only reasons a selector of sdk_selectors may be listed as missing with:
# its class is missing, or the class of an object it takes or answers; that
# class is then in missing too, and the selector comes back with it.
CLASS_MISSING = re.compile(r'^its class is missing \(classes (\S+)\)$')
ARGUMENT_MISSING = re.compile(r'^takes an object of a missing class \(classes (\S+)\)$')
# The reason the missing entries of instance variables gave while no field of a
# Swift class was exported. The aliases of the table export such fields, so the
# reason holds for none: an entry that waits says what it waits for.
NO_SWIFT_SYMBOL = re.compile(r': a Swift stored property has no _OBJC_IVAR_\$_ symbol$')
ADDRESS = re.compile(r'^([0-9A-Fa-f]+) \S (\S.*)$')
# The system frameworks whose classes the SDK's classes descend from or extend.
SYSTEM_FRAMEWORKS = ('Foundation', 'AppKit', 'CoreData', 'QuartzCore', 'CoreImage', 'Quartz', 'PDFKit',
                     'WebKit', 'AVFoundation', 'AVKit')
# The entries retired before the rule, frozen: an entry leaves this list when its item
# comes back, and none enters.
RETIRED_KEYS = frozenset((
    'selectors AppController +resetThumbnailsList',
    'selectors AppController -UpdateCLUTMenu:',
    'selectors AppController -UpdateConvolutionMenu:',
    'selectors AppController -UpdateOpacityMenu:',
    'selectors AppController -UpdateWLWWMenu:',
    'selectors AppController -_receivingIconSet:',
    'selectors AppController -_receivingIconUpdate',
    'selectors AppController -buildTilingAreaMenu',
    'selectors AppController -checkForUpdatesDisabled:',
    'selectors AppController -clutMenuTestLocalized:',
    'selectors AppController -convMenuTestLocalized:',
    'selectors AppController -currentRowForViewer:',
    'selectors AppController -deliverNotificationTitle:description:name:sound:',
    'selectors AppController -displayUpdateMessage:',
    'selectors AppController -displayViewers:monitorIndex:screens:numberOfMonitors:rowsPerScreen:columnsPerScreen:',
    'selectors AppController -exportMenuTestLocalized:',
    'selectors AppController -fileMenuTestLocalized:',
    'selectors AppController -imageTilingMenuTestLocalized:',
    'selectors AppController -loadWindowsStateDICOMSR:',
    'selectors AppController -opacityMenuTestLocalized:',
    'selectors AppController -orderedScreens',
    'selectors AppController -orientationMenuTestLocalized:',
    'selectors AppController -preferencesUpdated:',
    'selectors AppController -setAETitleToHostname',
    'selectors AppController -sound:didFinishPlaying:',
    'selectors AppController -startDICOMBonjour:',
    'selectors AppController -switchHandler:',
    'selectors AppController -testMenus',
    'selectors AppController -viewerMenuTestLocalized:',
    'selectors AppController -windowCenter:',
    'selectors AppController -wlwwMenuTestLocalized:',
    'selectors AppController -workspaceMenuTestLocalized:',
    'selectors BrowserController -ROIImages:sameSeries:',
    'selectors BrowserController -_albumWithID:',
    'selectors BrowserController -_complain:',
    'selectors BrowserController -databaseAlbumSortDescriptorsPlistPath',
    'selectors BrowserController -reportIcon',
    'selectors BrowserController -saveSortDescriptors:',
    'selectors BrowserController -setDatabaseThread:',
    'selectors BrowserController -spaceEvenly:',
    'selectors BrowserController -subSearchForComparativeStudies:',
    'selectors BrowserController -toolbarDidRemoveItem:',
    'selectors BrowserController -toolbarWillAddItem:',
    'selectors BrowserController -writeDatabaseFilePromise:',
    'selectors BrowserController -writeJPEGImages:paths:wholeSeriesIDs:directory:reportExports:activityThread:',
    'selectors BrowserController -writeReportFileExports:activityThread:',
    'selectors DCMView +horos_static_PETblueTable',
    'selectors DCMView +horos_static_PETgreenTable',
    'selectors DCMView +horos_static_PETredTable',
    'selectors DCMView +horos_static_avoidSetWLWWRentry',
    'selectors DCMView +horos_static_drawLock',
    'selectors DCMView +horos_static_gDontListenToSyncMessage',
    'selectors DCMView +horos_static_syncro',
    'selectors DCMView +setHoros_static_PETblueTable:',
    'selectors DCMView +setHoros_static_PETgreenTable:',
    'selectors DCMView +setHoros_static_PETredTable:',
    'selectors DCMView +setHoros_static_avoidSetWLWWRentry:',
    'selectors DCMView +setHoros_static_drawLock:',
    'selectors DCMView +setHoros_static_gDontListenToSyncMessage:',
    'selectors DCMView +setHoros_static_syncro:',
    'selectors DCMView -horos_avoidChangeWLWWRecursive',
    'selectors DCMView -horos_bdstartMax',
    'selectors DCMView -horos_bdstartMin',
    'selectors DCMView -horos_bdstartWL',
    'selectors DCMView -horos_bdstartWW',
    'selectors DCMView -horos_blendingFactor',
    'selectors DCMView -horos_blendingFactorStart',
    'selectors DCMView -horos_blendingView',
    'selectors DCMView -horos_blueTable',
    'selectors DCMView -horos_colorBuf',
    'selectors DCMView -horos_colorTransfer',
    'selectors DCMView -horos_curImage',
    'selectors DCMView -horos_curWL',
    'selectors DCMView -horos_curWLWWSUVConverted',
    'selectors DCMView -horos_curWLWWSUVFactor',
    'selectors DCMView -horos_curWW',
    'selectors DCMView -horos_greenTable',
    'selectors DCMView -horos_origin',
    'selectors DCMView -horos_originStart',
    'selectors DCMView -horos_redTable',
    'selectors DCMView -horos_rotation',
    'selectors DCMView -horos_rotationStart',
    'selectors DCMView -horos_scaleValue',
    'selectors DCMView -horos_startImage',
    'selectors DCMView -horos_startMax',
    'selectors DCMView -horos_startMin',
    'selectors DCMView -horos_startScaleValue',
    'selectors DCMView -horos_startWL',
    'selectors DCMView -horos_startWW',
    'selectors DCMView -horos_xFlipped',
    'selectors DCMView -horos_yFlipped',
    'selectors DCMView -setHoros_avoidChangeWLWWRecursive:',
    'selectors DCMView -setHoros_bdstartMax:',
    'selectors DCMView -setHoros_bdstartMin:',
    'selectors DCMView -setHoros_bdstartWL:',
    'selectors DCMView -setHoros_bdstartWW:',
    'selectors DCMView -setHoros_blendingFactor:',
    'selectors DCMView -setHoros_blendingFactorStart:',
    'selectors DCMView -setHoros_blendingView:',
    'selectors DCMView -setHoros_colorBuf:',
    'selectors DCMView -setHoros_colorTransfer:',
    'selectors DCMView -setHoros_curImage:',
    'selectors DCMView -setHoros_curWL:',
    'selectors DCMView -setHoros_curWLWWSUVConverted:',
    'selectors DCMView -setHoros_curWLWWSUVFactor:',
    'selectors DCMView -setHoros_curWW:',
    'selectors DCMView -setHoros_origin:',
    'selectors DCMView -setHoros_originStart:',
    'selectors DCMView -setHoros_rotation:',
    'selectors DCMView -setHoros_rotationStart:',
    'selectors DCMView -setHoros_scaleValue:',
    'selectors DCMView -setHoros_startImage:',
    'selectors DCMView -setHoros_startMax:',
    'selectors DCMView -setHoros_startMin:',
    'selectors DCMView -setHoros_startScaleValue:',
    'selectors DCMView -setHoros_startWL:',
    'selectors DCMView -setHoros_startWW:',
    'selectors DCMView -setHoros_xFlipped:',
    'selectors DCMView -setHoros_yFlipped:',
    'selectors HorosViewerSeriesLoad -acceptCompletion:',
    'selectors HorosViewerSeriesLoad -startWithPixLists:volumes:computeOpeningContentBounds:',
    'selectors ViewerController -appendAssociationItemsFromUnarchived:fileName:items:rois:',
    'selectors ViewerController -appendMovie:movieIndex:fileName:items:rois:',
    'selectors ViewerController -appendROIList:movieIndex:sliceIndex:fileName:items:rois:',
    'selectors ViewerController -applyAssociationItems:rois:error:',
    'selectors ViewerController -applyConvolutionXYThread:',
    'selectors ViewerController -applyConvolutionZThread:',
    'selectors ViewerController -finishLoadImageData:',
))
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
    return all(shutil.which(tool) for tool in ('dyld_info', 'nm', 'lipo', 'xcrun'))


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


def architectures(path):
    """The architectures of the Mach-O file, as lipo names them."""
    run = subprocess.run(['lipo', '-archs', str(path)], capture_output=True, text=True)
    if run.returncode != 0:
        raise SystemExit(f'lipo failed on {path}: {run.stderr.strip()[-300:]}')
    return run.stdout.split()


def exported_symbols(path, arch):
    """Names of the external symbols the image defines in its slice for `arch`.

    Without -arch, nm lists only the slice of the machine it runs on, so a
    symbol absent from another slice of a universal binary would pass."""
    run = subprocess.run(['nm', '-arch', arch, '-gUj', str(path)], capture_output=True, text=True)
    if run.returncode != 0:
        raise SystemExit(f'nm failed on {path}: {run.stderr.strip()[-300:]}')
    return {line.strip() for line in run.stdout.splitlines() if line.strip() and not line.endswith(':')}


def symbol_addresses(path, arch):
    """{name: address} of the instance variable names and of the Swift field offsets
    in the symbol table of the image's slice for `arch`, local symbols included."""
    run = subprocess.run(['nm', '-arch', arch, str(path)], capture_output=True, text=True)
    if run.returncode != 0:
        raise SystemExit(f'nm failed on {path}: {run.stderr.strip()[-300:]}')
    placed = {}
    for line in run.stdout.splitlines():
        found = ADDRESS.match(line)
        if found and (found.group(2).startswith(IVAR_PREFIX) or found.group(2).endswith('Wvd')):
            placed[found.group(2)] = found.group(1)
    return placed


def objc_metadata(path, arch):
    """{class: {'super': name or None, 'defined': bool, '-': {sel}, '+': {sel}}}
    from the Objective-C classes and categories of the image's slice for `arch`.
    A class only extended by a category of the image ('defined' False) is a
    system class."""
    run = subprocess.run(['dyld_info', '-arch', arch, '-objc', str(path)], capture_output=True, text=True)
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


class Dl_info(ctypes.Structure):
    _fields_ = [('dli_fname', ctypes.c_char_p), ('dli_fbase', ctypes.c_void_p),
                ('dli_sname', ctypes.c_char_p), ('dli_saddr', ctypes.c_void_p)]


# A method only a private framework implements is not one a plugin can count on:
# loading Quartz brings in private frameworks whose categories on Foundation
# classes would otherwise stand in for a method the application no longer has.
PRIVATE_FRAMEWORKS = '/System/Library/PrivateFrameworks/'


class SystemRuntime:
    """The system's Objective-C classes, through the runtime of this process.

    It sees the architecture this process runs as, whatever slice of the
    bundle is being checked."""

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
        self.objc.method_getImplementation.restype = ctypes.c_void_p
        self.objc.method_getImplementation.argtypes = [ctypes.c_void_p]
        self.libc = ctypes.CDLL(None)
        self.libc.dladdr.restype = ctypes.c_int
        self.libc.dladdr.argtypes = [ctypes.c_void_p, ctypes.POINTER(Dl_info)]

    def has_class(self, name):
        return bool(self.objc.objc_lookUpClass(name.encode()))

    def responds(self, name, kind, selector):
        cls = self.objc.objc_lookUpClass(name.encode())
        if not cls:
            return False
        lookup = self.objc.class_getInstanceMethod if kind == '-' else self.objc.class_getClassMethod
        method = lookup(cls, self.objc.sel_registerName(selector.encode()))
        if not method:
            return False
        return not self.image_of(self.objc.method_getImplementation(method)).startswith(PRIVATE_FRAMEWORKS)

    def image_of(self, address):
        """The path of the image that holds `address`, or '' when dyld knows none."""
        info = Dl_info()
        if not address or not self.libc.dladdr(address, ctypes.byref(info)) or not info.dli_fname:
            return ''
        return info.dli_fname.decode(errors='replace')

    def ancestors(self, name):
        cls = self.objc.objc_lookUpClass(name.encode())
        chain = []
        while cls:
            cls = self.objc.class_getSuperclass(cls)
            if cls:
                chain.append(self.objc.class_getName(cls).decode())
        return chain


class Surface:
    """What one architecture of a bundle offers a plugin: exported symbols and
    Objective-C methods, from the slice for `arch` of each image that has it."""

    def __init__(self, app, arch, runtime=None):
        self.app = Path(app)
        self.arch = arch
        self.images = [image for image in bundle_images(self.app) if arch in architectures(image)]
        self.exports = set()
        self.image_exports = {}
        self.classes = {}
        for image in self.images:
            self.image_exports[image] = exported_symbols(image, arch)
            self.exports |= self.image_exports[image]
            for name, entry in objc_metadata(image, arch).items():
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

    def implements(self, name, kind, selector, own_only=False):
        """Whether `name` or an ancestor has the method. With own_only, only the
        application's own classes and categories count, not the system's."""
        for cls in self.chain(name):
            entry = self.classes.get(cls)
            if entry and selector in entry[kind]:
                return True
            if kind == '-' and cls in self.managed and managed_accessor(self.managed[cls], selector):
                return True
            if not own_only and not (entry and entry['defined']) and self.runtime.responds(cls, kind, selector):
                return True
        return False

    def defines(self, name):
        """Whether `name` is a class of the application, not one of the system's it extends."""
        entry = self.classes.get(name)
        return bool(entry and entry['defined'])

    def class_present(self, name):
        return f'_OBJC_CLASS_$_{name}' in self.exports and f'_OBJC_METACLASS_$_{name}' in self.exports

    def alias_problems(self, table):
        """Where an exported name of the table is not at the address of its field's symbol.

        Answers the lines and how many names were compared. An image that
        exports names of the table and has none of their fields' symbols was
        stripped of its local symbols: nothing of it is compared."""
        found, compared = [], 0
        for image, exports in self.image_exports.items():
            here = {name: entry for name, entry in table.items() if IVAR_PREFIX + name in exports}
            if not here:
                continue
            placed = symbol_addresses(image, self.arch)
            if not any(entry['symbol'] in placed for entry in here.values()):
                continue
            for name, entry in here.items():
                alias, field = placed.get(IVAR_PREFIX + name), placed.get(entry['symbol'])
                compared += 1
                if field is None:
                    found.append(f'{name}: {image.name} has no symbol {entry["symbol"]}, the field the table names [{self.arch}]')
                elif alias != field:
                    found.append(f'{name}: {IVAR_PREFIX}{name} is at {alias} and the symbol of its field, {entry["symbol"]}, '
                                 f'at {field} [{self.arch}]')
        return found, compared

    def framework_present(self, name, symbols):
        executable = self.app / 'Contents/Frameworks' / f'{name}.framework/Versions/A' / name
        if not executable.is_file() or self.arch not in architectures(executable):
            return False
        return set(symbols) <= exported_symbols(executable, self.arch)


def absent(registry, surface):
    """The keys ("<section> <item>") of the registry's items the bundle lacks."""
    lacking = set()
    for name, framework in registry['frameworks'].items():
        if not surface.framework_present(name, framework['symbols']):
            lacking.add(f'frameworks {name}')
    for name, superclass in registry['classes'].items():
        if not surface.class_present(name) or (superclass and superclass not in surface.chain(name)[1:]):
            lacking.add(f'classes {name}')
    sdk = registry['sdk_selectors']
    for section in ('selectors', 'used_outside_sdk'):
        for item in registry[section]:
            cls, kind, selector = SELECTOR_ENTRY.match(item).groups()
            # A selector the SDK added to a class of the system is the application's
            # method or it is absent: a method of the system with the same name is
            # not the one the SDK had.
            own_only = item in sdk and not surface.defines(cls) and surface.runtime.has_class(cls)
            if not surface.implements(cls, kind, selector, own_only=own_only):
                lacking.add(f'{section} {item}')
    for item in registry['ivars']:
        if f'_OBJC_IVAR_$_{item}' not in surface.exports:
            lacking.add(f'ivars {item}')
    for item in registry['symbols']:
        if item not in surface.exports:
            lacking.add(f'symbols {item}')
    return lacking


def missing_ivar_problems(registry):
    """The instance variables that may not be listed as missing, a line per class and rule."""
    used, swift = {}, {}
    for key, reason in sorted(registry['missing'].items()):
        section, _, item = key.partition(' ')
        if section != 'ivars' or item not in registry['ivars']:
            continue
        cls, _, name = item.partition('.')
        count = registry['ivars'][item]
        if isinstance(count, int) and count > 0:
            used.setdefault(cls, []).append(name)
        elif isinstance(reason, str) and NO_SWIFT_SYMBOL.search(reason):
            swift.setdefault(cls, []).append(name)
    found = [f'missing: {len(names)} instance variables of {cls} are read by known plugins and cannot be listed as missing, '
             f'whatever the reason: a plugin that reads one is refused when it loads. They are exported, each from a field of '
             f'{legacy_plugin_ivars.relative(TABLE)}: {", ".join(names)}' for cls, names in used.items()]
    found += [f'missing: {len(names)} instance variables of {cls} are listed with the reason that a Swift stored property has no '
              f'_OBJC_IVAR_$_ symbol, which does not hold: the alias of a field exports one. Give what each waits for: '
              f'{", ".join(names[:8])}{", ..." if len(names) > 8 else ""}' for cls, names in swift.items()]
    return found


def table_problems(registry, table, structs, surfaces, where):
    """Every reason the table of the instance variables Swift classes export does not hold, one line each.

    Returns the lines and the number of names whose address was compared with their field's."""
    found = legacy_plugin_ivars.table_problems(table, where, structs)
    if any(not isinstance(entry, dict) or 'symbol' not in entry for entry in table.values()):
        return found, 0
    for name in table:
        if name not in registry['ivars']:
            found.append(f'{where}: {name} is not in ivars of the registry')
        elif f'ivars {name}' in registry['missing']:
            found.append(f'{where}: {name} is exported by the table and listed as missing in the registry')
        lacking = [surface.arch for surface in surfaces if IVAR_PREFIX + name not in surface.exports]
        if lacking:
            found.append(f'{where}: {name} is not exported: the application was not linked with the aliases of this table'
                         + ('' if len(lacking) == len(surfaces) else f' [{", ".join(lacking)}]'))
    compared = 0
    for surface in surfaces:
        lines, count = surface.alias_problems(table)
        found += [f'{where}: {line}' for line in lines]
        compared += count
    return found, compared


def controls(registry, table, structs, surfaces, compared):
    """The rules of the instance variables, each given a registry or a table changed to break it.

    Answers a line per control that was not refused, and how many were tried."""
    failures, tried = [], 0

    def expect(what, lines, *needles):
        nonlocal tried
        tried += 1
        absent_needles = [needle for needle in needles if not any(needle in line for line in lines)]
        if absent_needles:
            failures.append(f'control: {what} was expected to be refused with {absent_needles[0]!r}')

    def changed_registry(ivars=None, missing=None):
        return dict(registry, ivars=dict(registry['ivars'], **(ivars or {})), missing=dict(registry['missing'], **(missing or {})))

    def of_table(changed, changed_registry_=None):
        return table_problems(changed_registry_ or registry, changed, structs, surfaces, 'control')[0]

    expect('a registry that lists as missing an instance variable a plugin reads',
           missing_ivar_problems(changed_registry({'QAControl.read': 1}, {'ivars QAControl.read': 'its storage is elsewhere'})),
           '1 instance variables of QAControl are read by known plugins')
    expect('a registry that gives the Swift reason for a missing instance variable',
           missing_ivar_problems(changed_registry({'QAControl.kept': 0}, {
               'ivars QAControl.kept': 'QAControl is implemented in Swift now: a Swift stored property has no _OBJC_IVAR_$_ symbol'})),
           '1 instance variables of QAControl are listed with the reason that a Swift stored property')
    name, entry = next(iter(table.items()))
    expect('a table with an entry the registry does not have and no bundle exports',
           of_table(dict(table, **{'QAControl.absent': dict(entry)})),
           'QAControl.absent is not in ivars of the registry', 'QAControl.absent is not exported')
    expect('a registry that lists an entry of the table as missing',
           of_table(table, changed_registry(missing={f'ivars {name}': 'its storage is elsewhere'})),
           f'{name} is exported by the table and listed as missing')
    if compared and len(table) > 1:
        (first, one), (second, other) = list(table.items())[:2]
        exchanged = dict(table)
        exchanged[first] = dict(one, field=other['field'], symbol=other['symbol'])
        exchanged[second] = dict(other, field=one['field'], symbol=one['symbol'])
        expect('a table with the symbols of two entries exchanged', of_table(exchanged),
               f'{first}: {IVAR_PREFIX}{first} is at', f'{second}: {IVAR_PREFIX}{second} is at')
    another = 'float' if entry['sdk'].strip() == 'short' else 'short'
    expect('a table with the sdk of an entry changed to another C type',
           of_table(dict(table, **{name: dict(entry, sdk=another)})), f'{name}: the type of {entry["field"]} does not correspond to sdk')
    expect('a table with a state it does not define',
           of_table(dict(table, **{name: dict(entry, state='dormant')})), f"{name}: state 'dormant' is not one of")
    expect('a table with an ownership it does not define',
           of_table(dict(table, **{name: dict(entry, ownership='weak')})), f"{name}: ownership 'weak' is not one of")
    return failures, tried


def shape_problems(registry, text):
    """Why the registry cannot be read as one: its sections, its text and the form of its selectors."""
    if set(registry) != SECTIONS:
        return [f'sections must be {sorted(SECTIONS)}, not {sorted(registry)}']
    found = []
    if text != render(registry):
        found.append('the registry is not in its canonical text (sorted, one entry per line): rewrite it with render()')
    for section in ('selectors', 'used_outside_sdk', 'sdk_selectors', 'osirix_selectors'):
        found += [f'{section}: "{item}" is not "Class -selector" or "Class +selector"'
                  for item in registry[section] if not SELECTOR_ENTRY.match(item)]
    for section in ('sdk_selectors', 'osirix_selectors'):
        found += [f'{section}: "{item}" is not in selectors'
                  for item in sorted(registry[section]) if item not in registry['selectors']]
    found += [f'osirix_selectors: "{item}" does not say the source of its name and types'
              for item, source in sorted(registry['osirix_selectors'].items()) if not isinstance(source, str) or not source.strip()]
    return found


def registry_items(registry):
    return {f'{section} {item}' for section in CHECKED for item in registry[section]}


def missing_problems(registry):
    """The entries of missing and of isix5_additions that the rules refuse, one line each."""
    found = []
    sdk, missing, additions = registry['sdk_selectors'], registry['missing'], registry['isix5_additions']
    items = registry_items(registry)
    for key in sorted(additions):
        if key not in items or key.split(' ', 1)[0] not in ('classes', 'symbols'):
            found.append(f'isix5_additions: "{key}" names no class or symbol of the registry')
    for key in sorted(AWAITED_KEYS & set(additions)):
        found.append(f'isix5_additions: "{key}" is in the list of what Horos compiled, and cannot be an addition as well')
    for key, reason in sorted(missing.items()):
        section, _, entry = key.partition(' ')
        if key not in items:
            found.append(f'missing: "{key}" names no item of the registry')
        elif not isinstance(reason, str) or not reason.strip():
            found.append(f'missing: "{key}" has no reason')
        elif reason == ISIX5_ADDITION and key not in additions:
            found.append(f'missing: "{key}" is not in isix5_additions and cannot be excused as an addition of the IsiX 5 SDK')
        elif reason == AWAITS_FACADE and key not in AWAITED_KEYS:
            found.append(f'missing: "{key}" cannot wait for a facade: the list of what waits is closed, and its item comes back '
                         f'with the change that would list it')
        elif section in HARD:
            if not (key in additions and reason == ISIX5_ADDITION) and not (key in AWAITED_KEYS and reason == AWAITS_FACADE):
                found.append(f'missing: "{key}" is contract of the Horos and OsiriX SDK: a plugin that names it is refused when it '
                             f'loads, so it comes back instead of being listed. Only an entry of isix5_additions may be listed, '
                             f'with the reason "{ISIX5_ADDITION}"')
        elif section in ('selectors', 'used_outside_sdk') and registry[section][entry] != 0:
            found.append(f'missing: "{key}" is used by known plugins and cannot be listed as missing, whatever the reason')
        elif section == 'selectors' and entry in registry['osirix_selectors']:
            found.append(f'missing: "{key}" is a selector that later headers of the OsiriX SDK declare, which is contract: a '
                         f'plugin built with them sends it, and it cannot be listed as missing, whatever the reason')
        elif section == 'selectors' and entry in sdk:
            waits = CLASS_MISSING.match(reason) or ARGUMENT_MISSING.match(reason)
            own = CLASS_MISSING.match(reason)
            if not waits or f'classes {waits.group(1)}' not in missing or (own and own.group(1) != key.split(' ')[1]):
                found.append(f'missing: "{key}" is a selector of the Horos and OsiriX SDK, which is contract: it comes back as a '
                             f'facade. It waits only for a missing class, with the reason "its class is missing (classes X)" or '
                             f'"takes an object of a missing class (classes X)" and "classes X" in missing')
        elif reason == RETIRED and key not in RETIRED_KEYS:
            found.append(f'missing: "{key}" cannot be retired: nothing more is retired from the SDK\'s surface')
    return found + missing_ivar_problems(registry)


def presence_problems(registry, surfaces):
    """What the bundle lacks without the registry saying so, and what it has again.

    surfaces is one Surface per architecture of the bundle's executable. An
    item is absent when any of them lacks it; one absent from only some names
    them, as in "symbols _name [x86_64]"."""
    missing = registry['missing']
    by_arch = {surface.arch: absent(registry, surface) for surface in surfaces}
    lacking = set().union(*by_arch.values())

    def where(key):
        archs = [arch for arch, keys in by_arch.items() if key in keys]
        return '' if len(archs) == len(by_arch) else f' [{", ".join(archs)}]'

    found = [f'absent from the application and not in missing: {key}{where(key)}' for key in sorted(lacking - set(missing))]
    found += [f'present again, remove its missing entry: {key}' for key in sorted(set(missing) & registry_items(registry) - lacking)]
    return found


def problems(registry, text, surfaces):
    """Every reason the registry does not hold for the bundle, one line each."""
    found = shape_problems(registry, text)
    if found:
        return found
    return missing_problems(registry) + presence_problems(registry, surfaces)


class WithoutExports:
    """A Surface as it would be had the bundle not exported `names`: the stand-in for a build that lost them."""

    def __init__(self, surface, names):
        self.surface, self.exports = surface, surface.exports - set(names)

    def __getattr__(self, name):
        return getattr(self.surface, name)

    def class_present(self, name):
        return f'_OBJC_CLASS_$_{name}' in self.exports and f'_OBJC_METACLASS_$_{name}' in self.exports


def surface_controls(registry, surfaces):
    """The rules of the classes, symbols and selectors, each given a registry or a bundle changed to break it.

    Answers a line per control that was not refused, and how many were tried."""
    failures, tried = [], 0

    def expect(what, lines, needle):
        nonlocal tried
        tried += 1
        if not any(needle in line for line in lines):
            failures.append(f'control: {what} was expected to be refused with {needle!r}')

    def changed(**sections):
        return dict(registry, **{name: dict(registry[name], **entries) for name, entries in sections.items()})

    def only(**sections):
        """The registry with nothing to look for in the bundle but `sections`."""
        return dict(registry, **dict({name: {} for name in CHECKED + ('missing', 'sdk_selectors', 'osirix_selectors')}, **sections))

    def unused(name, section):
        """`name`, lengthened until the registry given has no such entry: a control stands for what it lacks."""
        while name in registry[section]:
            name += 'X'
        return name

    symbol, cls = unused('_QAControlSymbol', 'symbols'), unused('QAControlClass', 'classes')
    selector = unused('QAControlClass -sent', 'selectors')
    absent_symbol = {symbol: 0}
    expect('a registry with a symbol the bundle does not export', presence_problems(only(symbols=absent_symbol), surfaces),
           f'absent from the application and not in missing: symbols {symbol}')
    # The defect this registry was completed for: the application stopped exporting a
    # name of the SDK and nothing failed. A bundle without it must fail by that name.
    lost = '_pasteBoardOsiriX' if '_pasteBoardOsiriX' in registry['symbols'] else next(iter(sorted(registry['symbols'])), None)
    if lost and not any(lost not in surface.exports for surface in surfaces):
        expect(f'a bundle that no longer exports {lost}',
               presence_problems(only(symbols={lost: registry['symbols'][lost]}), [WithoutExports(s, [lost]) for s in surfaces]),
               f'absent from the application and not in missing: symbols {lost}')
        if len(surfaces) > 1:
            expect(f'a bundle that no longer exports {lost} in one architecture',
                   presence_problems(only(symbols={lost: registry['symbols'][lost]}),
                                     [WithoutExports(surfaces[0], [lost])] + list(surfaces[1:])),
                   f'absent from the application and not in missing: symbols {lost} [{surfaces[0].arch}]')
    expect('a registry that lists a symbol of the SDK as missing, with a reason of its own',
           missing_problems(changed(symbols=absent_symbol, missing={f'symbols {symbol}': 'removed from the sources'})),
           f'missing: "symbols {symbol}" is contract of the Horos and OsiriX SDK')
    expect('a registry that lists a class of the SDK as missing, with a reason of its own',
           missing_problems(changed(classes={cls: 'NSObject'}, missing={f'classes {cls}': 'removed from the application'})),
           f'missing: "classes {cls}" is contract of the Horos and OsiriX SDK')
    framework = next(iter(sorted(registry['frameworks'])), None)
    if framework:
        expect('a registry that lists a framework of the SDK as missing',
               missing_problems(changed(missing={f'frameworks {framework}': ISIX5_ADDITION})),
               f'missing: "frameworks {framework}" is not in isix5_additions')
    expect('a registry that excuses as an addition a symbol that is not in isix5_additions',
           missing_problems(changed(symbols=absent_symbol, missing={f'symbols {symbol}': ISIX5_ADDITION})),
           f'missing: "symbols {symbol}" is not in isix5_additions')
    expect('a registry that lists an addition as missing with another reason',
           missing_problems(changed(symbols=absent_symbol, isix5_additions={f'symbols {symbol}': 'QA.h'},
                                    missing={f'symbols {symbol}': 'removed from the sources'})),
           f'missing: "symbols {symbol}" is contract of the Horos and OsiriX SDK')
    expect('a registry whose isix5_additions names a selector',
           missing_problems(changed(selectors={selector: 0}, isix5_additions={f'selectors {selector}': 'QA.h'})),
           f'isix5_additions: "selectors {selector}" names no class or symbol of the registry')
    expect('a registry whose isix5_additions names something it does not have',
           missing_problems(changed(isix5_additions={f'symbols {symbol}': 'QA.h'})),
           f'isix5_additions: "symbols {symbol}" names no class or symbol of the registry')
    expect('a registry that makes a symbol wait for a facade outside the closed list',
           missing_problems(changed(symbols=absent_symbol, missing={f'symbols {symbol}': AWAITS_FACADE})),
           f'missing: "symbols {symbol}" cannot wait for a facade')
    expect('a registry that lists as missing a selector known plugins send',
           missing_problems(changed(selectors={selector: 2}, missing={f'selectors {selector}': 'its class no longer has it'})),
           f'missing: "selectors {selector}" is used by known plugins')
    later = changed(selectors={selector: 0}, osirix_selectors={selector: 'QA.h'})
    expect('a registry that lists as missing a selector only later headers declare',
           missing_problems(dict(later, missing=dict(registry['missing'], **{f'selectors {selector}': 'its class no longer has it'}))),
           f'missing: "selectors {selector}" is a selector that later headers')
    expect('a bundle without a selector only later headers declare',
           presence_problems(only(selectors={selector: 0}, osirix_selectors={selector: 'QA.h'}), surfaces),
           f'absent from the application and not in missing: selectors {selector}')
    expect('a registry whose selector of later headers left its selectors',
           shape_problems(changed(osirix_selectors={selector: 'QA.h'}), render(changed(osirix_selectors={selector: 'QA.h'}))),
           f'osirix_selectors: "{selector}" is not in selectors')
    expect('a registry whose selector of later headers has no source',
           shape_problems(dict(later, osirix_selectors=dict(registry['osirix_selectors'], **{selector: ' '})),
                          render(dict(later, osirix_selectors=dict(registry['osirix_selectors'], **{selector: ' '})))),
           f'osirix_selectors: "{selector}" does not say the source')
    return failures, tried


def identity(app, archs):
    """What tells one build of the bundle from another, for the result line."""
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    return (f'{info.get("CFBundleShortVersionString", "?")} ({info.get("CFBundleVersion", "?")}), '
            f'GitHash {info.get("GitHash") or "none"}, GitState {info.get("GitState") or "none"}, '
            f'{" ".join(archs)}'), info.get('GitHash') or ''


def head_commit():
    run = subprocess.run(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], capture_output=True, text=True)
    return run.stdout.strip() if run.returncode == 0 else ''


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    bundle = parser.add_mutually_exclusive_group()
    bundle.add_argument('--app', type=Path, help='check this bundle, such as an unpacked package')
    bundle.add_argument('--debug', dest='app', action='store_const', const=DEBUG_APP,
                        help='check the Debug build in build/Build/Products')
    bundle.add_argument('--release', dest='app', action='store_const', const=RELEASE_APP,
                        help='check the Release build in build/Build/Products (the default)')
    parser.add_argument('--registry', type=Path, default=REGISTRY)
    parser.add_argument('--table', type=Path, default=TABLE,
                        help='check this table of the instance variables Swift classes export')
    args = parser.parse_args(argv)
    app = args.app or RELEASE_APP
    if not tools_available():
        print('skipped: needs dyld_info, nm, lipo and xcrun (Xcode command line tools)', file=sys.stderr)
        return SKIPPED
    if not (app / 'Contents/Info.plist').is_file():
        configuration = 'Debug' if app == DEBUG_APP else 'Release'
        print(f'skipped: needs a built IsiX DICOM Viewer.app at {app}: '
              f'HOROS_DEV_CONFIGURATION={configuration} script/build_and_run.sh --verify', file=sys.stderr)
        return SKIPPED
    text = args.registry.read_text(encoding='utf-8')
    registry = json.loads(text)
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    archs = architectures(app / 'Contents/MacOS' / info['CFBundleExecutable'])
    runtime = SystemRuntime()
    surfaces = [Surface(app, arch, runtime) for arch in archs]
    found = problems(registry, text, surfaces)
    where = legacy_plugin_ivars.relative(args.table)
    compared = tried = 0
    table = {}
    if not shape_problems(registry, text):
        refused, tried = surface_controls(registry, surfaces)
        found += refused
    if set(registry) == SECTIONS:
        try:
            table = legacy_plugin_ivars.read_table(args.table)['ivars']
            structs = legacy_plugin_ivars.storage_structs(legacy_plugin_ivars.STORAGE.read_text(encoding='utf-8'))
            lines, compared = table_problems(registry, table, structs, surfaces, where)
            refused, more = controls(registry, table, structs, surfaces, compared)
            tried += more
            found += lines + refused
        except (legacy_plugin_ivars.TableError, OSError) as error:
            found.append(str(error))
    build, commit = identity(app, archs)
    if app in (DEBUG_APP, RELEASE_APP) and commit != head_commit():
        print(f'warning: the bundle was built from {commit or "an unknown commit"}, not from the commit checked out '
              f'({head_commit() or "unknown"}): build it again before trusting this result')
    for line in found:
        print('FAIL: ' + line)
    if found:
        print(f'FAIL: {len(found)} problems against {app}: {build}')
        return 1
    checked = sum(len(registry[section]) for section in CHECKED)
    addresses = (f'each at the address of its field in {compared} comparisons' if compared
                 else 'their addresses not compared: the bundle was stripped of its local symbols')
    print(f'PASS: {checked - len(registry["missing"])} of {checked} items of the former plugin SDK are in '
          f'{app.name}, {build}; {len(registry["missing"])} are listed as missing, each with its reason; '
          f'the {len(table)} instance variables of {where} are exported, {addresses}; '
          f'{tried} changed registries, tables and lists of exports were refused as they must be')
    return 0


if __name__ == '__main__':
    sys.exit(main())
