#!/usr/bin/env python3
"""Convert a Horos/OsiriX plugin's source into an IsiX plugin project (API 1)
that builds with the porting kit IsiXLegacyBridge.

    tools/port-legacy-plugin.py --source <legacy plugin folder> --output <folder>
        [--name ModuleName] [--sdk <folder with IsiXPluginKit.framework>]
        [--arc | --mrc] [--framework Accelerate ...] [--exclude <file name> ...]
        [--shared-kit <path of the kit, relative to the project>]
    tools/port-legacy-plugin.py --collection <horosplugins> [--output <folder>] --report <report.json>

The legacy folder is only read. The project is written to <output>/<Module>:

- <Module>.xcodeproj and Config/<Module>.xcconfig: one bundle target,
  .isixplugin, macOS 15, arm64 and x86_64, IsiXPluginKit linked from the SDK
  folder (Config/SDK.xcconfig, ISIX_SDK_DIR), the kit's headers first in the
  header search, ISIX_LEGACY_NAMESPACE set to the module name. Each file keeps
  the memory management the legacy project gave it (manual reference
  counting or ARC, per file); the kit's Objective-C is compiled with ARC.
  Config/Prefix.pch includes the kit's prefix header, then the plugin's own.
  Config/port.json says the same to tools/build-isix-legacy-plugin.py, which
  builds the project without Xcode.
- Config/Info.plist: the legacy keys turned into those of API 1 (pluginType,
  MenuTitles and the legacy principal class are kept under IsiXLegacy... keys
  for the kit's entry point, which registers one command per menu title; the
  capabilities follow what the plugin uses).
- Sources/: the plugin's own files, without its copy of the former SDK and
  its build products, with the mechanical rewrites below. The files the
  legacy target compiled and copied are the ones built.
- IsiXLegacyBridge/: the copy of the kit the project builds with. With
  --shared-kit there is none: the project uses the kit at that path, relative
  to the project's folder (../IsiXLegacyBridge for a collection of projects
  next to one copy of the kit), in its header search, its sources and its
  Xcode project. The kit's objects are still compiled into each plugin, with
  the plugin's module name in their runtime names.
- Porting/: original/ (every file as it was before a rewrite),
  rewrites.diff, report.json and REPORT.md: each rewrite, and what has no
  automatic equivalent, with its file and line.

Rewrites (each one keeps the legacy behaviour; see the kit's
IsiXLegacyPortSupport.h and IsiXLegacyCalendarDate.h):

- alerts: NSRunAlertPanel() and its critical and informational forms,
  NSBeginAlertSheet() and its forms, +[NSAlert alertWithMessageText:...] and
  NSAlertDefaultReturn... become the kit's IsiXLegacy... functions on NSAlert;
- sheets and panels: -[NSApplication beginSheet:modalForWindow:modalDelegate:...],
  -[NSAlert beginSheetModalForWindow:modalDelegate:...], the save and open
  panels' -beginSheetForDirectory:..., -runModalForDirectory:...,
  -runModalForTypes:, -setRequiredFileType: and -filenames, NSOKButton and
  the like;
- nib loading: +[NSBundle loadNibNamed:owner:];
- NSCalendarDate: IsiXLegacyCalendarDate, and -[NSDate dateWithCalendarFormat:timeZone:]
  and -descriptionWithCalendarFormat:timeZone:locale:;
- file paths: NSFileManager's -removeFileAtPath:handler:, -copyPath:toPath:handler:,
  -movePath:toPath:handler:, -createDirectoryAtPath:attributes:,
  -directoryContentsAtPath:, -fileAttributesAtPath:traverseLink: and
  +[NSString stringWithContentsOfFile:] on their ...Item...:error: forms;
- garbage collection: the collector's calls, which do nothing without it,
  and GCC_ENABLE_OBJC_GC; NSMakeCollectable() in manual reference counting;
- the former SDK, architectures and system: the project's settings, and in
  each xib a system before the plugin's, which ibtool refuses to compile
  before macOS 10.6 (see rewrite_xib).
- nibs: an object or view of a class of the kit (a custom view of class
  DCMView...) named by the class's runtime name, IsiXLegacy<Module>_<Name>,
  in a xib and in a compiled nib's archive, so that the nib makes the
  plugin's own copy of the class (by its legacy name the runtime would find
  the application's class, or none).

A call that matches none of these forms exactly (a handler that is not nil,
a receiver that is not the expected class...) is left as it was and listed
in the report. With --collection every plugin folder of the collection is
converted (into --output when given; without it nothing is written but the
report) and one report gathers them, which
tools/legacy-plugin-compatibility-matrix.py --converter-report reads.
"""
from pathlib import Path
import argparse
import difflib
import hashlib
import importlib.util
import json
import plistlib
import re
import shutil
import sys
import traceback

ROOT = Path(__file__).resolve().parents[1]
KIT = ROOT / 'IsiXLegacyBridge'
# The kit's folder in a converted project: its own copy, unless --shared-kit names another.
KIT_FOLDER = 'IsiXLegacyBridge'
MINIMUM_SYSTEM = '15.0'
ARCHS = ['arm64', 'x86_64']
REPORT_FORMAT = 1


def load_inventory():
    spec = importlib.util.spec_from_file_location('inventory_plugin_api', ROOT / 'tools/inventory-plugin-api.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


inv = load_inventory()

# ---------------------------------------------------------------- data: Info.plist

BASE_CAPABILITIES = ['viewer.read', 'viewer.write', 'roi']
RENAMED_KEYS = {'pluginType': 'IsiXLegacyPluginType', 'MenuTitles': 'IsiXLegacyMenuTitles'}
# Former keys the application refuses: what each meant, when it has no equivalent.
DROPPED_KEYS = {
    'ToolbarNames': 'toolbar buttons in the viewer have no equivalent in plugin API 1',
    'FileFormats': 'file format plugins have no equivalent in plugin API 1',
    'HorosCompatiblePlugin': None,
    'Requirements': None,
}
DATABASE_USE = re.compile(r'\b(BrowserController|DicomStudy|DicomSeries|DicomImage|DicomDatabase|DicomAlbum|DICOMExport'
                          r'|sourceFile|srcFile|imageObj|seriesObj|currentStudy|currentSeries|exportDICOMFileInt)\b')
# What the user can edit in the database (comments, state, report, lock, key
# image, albums), set by its setter or by key-value coding.
WRITE_USE = re.compile(r'\b(setComment[234]?|setStateText|setReportURL|setLockedStudy|setIsKeyImage|newAlbumWithName'
                       r'|addStudiesObject|removeStudiesObject|addStudies|removeStudies)\s*:'
                       r'|forKey:\s*@"(comment[234]?|stateText|reportURL|lockedStudy|isKeyImage)"')
# Files imported into the database, and DICOM written into a study.
IMPORT_USE = re.compile(r'\b(addFilesToDatabase|addFiles|addFilesAtPaths|addFilesAndFolderToDatabase'
                        r'|importFilesFromIncomingDir|copyFilesIntoDatabaseIfNeeded|writeDCMFile|exportDICOMFileInt)\s*:')
# The legacy notifications of the database, by constant or by name in text:
# the kit relays them from the events of the database, which need database.read.
DATABASE_NOTIFICATION_USE = re.compile(r'\bOsirixAddToDB(Complete)?Notification\b')
# Sending to the nodes of Locations, querying them, and XML-RPC methods.
SEND_USE = re.compile(r'\b(SendController|DCMTKStoreSCU)\b')
QUERY_USE = re.compile(r'\b(DCMTKQueryNode|DCMTKRootQueryNode|DCMTKStudyQueryNode|DCMTKSeriesQueryNode)\b')
NODES_USE = re.compile(r'\bDCMNetServiceDelegate\b')
XMLRPC_USE = re.compile(r'\bOsirixXMLRPCMessageNotification\b|@"OsiriXXMLRPCMessage"')
# The method names a plugin compared the XML-RPC call's method name with.
XMLRPC_METHOD = re.compile(r'\b[mM]ethodName\b[^;{}]*?isEqualToString:\s*@"([A-Za-z][\w.\-]{0,127})"')
BUILD_VARIABLE = re.compile(r'\$[({](PRODUCT_NAME|EXECUTABLE_NAME|TARGET_NAME|PRODUCT_MODULE_NAME)(:[\w,]+)?[)}]')

# ---------------------------------------------------------------- data: files

# Folders of a plugin that hold a copy of the former SDK, or build products.
FORMER_SDK = re.compile(r'(?i)^(osirix|horos)[ ._-]?(api|headers|\.framework)?$|^osirix headers$|\.framework$|'
                        r'^build$|\.xcodeproj$|\.xcworkspace$|^derived ?data$|^xcuserdata$|^\.(git|svn)$|^__macosx$')
# Folders of third-party libraries a plugin carries: copied, never rewritten,
# not in the header search (the plugin's own libraries are another stage).
LIBRARY_FOLDER = re.compile(r'(?i)^(itk|vtk|insight|dcmtk|gsl|boost|libxml|freetype|frameworks$)')
OBJC_SOURCES = {'.m', '.mm'}
C_SOURCES = {'.c'}
CXX_SOURCES = {'.cpp', '.cc', '.cxx'}
COMPILED = OBJC_SOURCES | C_SOURCES | CXX_SOURCES | {'.swift'}
REWRITTEN = {'.h', '.hh', '.hpp', '.m', '.mm', '.c', '.cc', '.cpp', '.cxx', '.pch'}
HEADERS = {'.h', '.hh', '.hpp', '.pch'}
# The system a xib is set to build for (see rewrite_xib).
# The IB 3 archive format: the document's target, and the Cocoa plugin's
# declared dependency, which ibtool checks as well in the later archives.
XIB_ARCHIVE_TARGETS = [re.compile(r'<int key="IBDocument\.SystemTarget">(\d+)</int>'),
                       re.compile(r'<string key="NS\.key\.(?:\d+)">com\.apple\.InterfaceBuilder\.CocoaPlugin\.macosx'
                                  r'</string>\s*<integer value="(\d+)"')]
XIB_DEPLOYMENT = re.compile(r'<deployment\b[^>]*>')
XIB_DEPLOYMENT_VERSION = re.compile(r'\s+version="(\d+)"')
# Resources taken when the plugin has no Xcode project to say which.
RESOURCE_SUFFIXES = {'.tif', '.tiff', '.png', '.jpg', '.icns', '.pdf', '.strings', '.plist', '.xib', '.nib'}
# What the compilers legacy plugins were written for reported as warnings and
# current ones refuse (an integer assigned to a pointer, a function used before
# its declaration...): the plugin's files compile as they did, with warnings.
LEGACY_DIAGNOSTICS = ['-Wno-error=int-conversion', '-Wno-error=implicit-function-declaration',
                      '-Wno-error=incompatible-pointer-types', '-Wno-error=implicit-int',
                      '-Wno-error=incompatible-function-pointer-types']
# CoreData: the kit's database context evaluates the plugin's fetch requests.
DEFAULT_FRAMEWORKS = ['Cocoa', 'Accelerate', 'QuartzCore', 'CoreImage', 'UniformTypeIdentifiers', 'CoreData']
# Frameworks of the former SDK: the kit replaces them.
FORMER_FRAMEWORKS = {'OsiriX', 'OsiriXAPI', 'Horos', 'HorosAPI', 'OsiriX Headers'}
# Frameworks a ported plugin never links, by the maintainer's decision.
OUT_FRAMEWORKS = {'QTKit', 'QuickTime'}
SYSTEM_LIBRARIES = {'z', 'c++', 'xml2', 'sqlite3', 'bz2', 'iconv', 'objc', 'System', 'resolv', 'curl'}
# The language a file of the legacy project was compiled in, when its type says so.
LANGUAGES = {'sourcecode.c.objc': 'objective-c', 'sourcecode.cpp.objcpp': 'objective-c++', 'sourcecode.c.c': 'c',
             'sourcecode.cpp.cpp': 'c++'}
SUFFIX_LANGUAGES = {'.m': 'objective-c', '.mm': 'objective-c++', '.c': 'c', '.cpp': 'c++', '.cc': 'c++', '.cxx': 'c++'}
# Per-file compiler flags kept from the legacy project.
KEPT_FLAG = re.compile(r'^(-D\S+|-U\S+|-W[\w=-]+|-w|-fno-objc-arc|-fobjc-arc|-std=\S+)$')

# ---------------------------------------------------------------- data: rewrites

# Inventory categories the converter deals with; the compatibility matrix
# names the same ones as the converter's stage.
CATEGORIES = ['legacy-alert/sheet', 'deprecated-nib-loading', 'deprecated-file-api', 'NSCalendarDate',
              'garbage-collection', 'Carbon', 'legacy-sdk/arch']
NIL = re.compile(r'^\(?\s*(nil|NULL|0|0L|Nil|nullptr)\s*\)?$')
NS_APP = re.compile(r'^(NSApp|\[\s*NSApplication\s+sharedApplication\s*\])$')

# Identifiers renamed wherever they are code (not in strings, comments or #import lines).
RENAMES = [
    ('alert-panel', 'legacy-alert/sheet', 'NSRunAlertPanel', 'IsiXLegacyRunAlertPanel'),
    ('alert-panel', 'legacy-alert/sheet', 'NSRunCriticalAlertPanel', 'IsiXLegacyRunCriticalAlertPanel'),
    ('alert-panel', 'legacy-alert/sheet', 'NSRunInformationalAlertPanel', 'IsiXLegacyRunInformationalAlertPanel'),
    ('alert-sheet', 'legacy-alert/sheet', 'NSBeginAlertSheet', 'IsiXLegacyBeginAlertSheet'),
    ('alert-sheet', 'legacy-alert/sheet', 'NSBeginCriticalAlertSheet', 'IsiXLegacyBeginCriticalAlertSheet'),
    ('alert-sheet', 'legacy-alert/sheet', 'NSBeginInformationalAlertSheet', 'IsiXLegacyBeginInformationalAlertSheet'),
    ('alert-return', 'legacy-alert/sheet', 'NSAlertDefaultReturn', 'IsiXLegacyAlertDefaultReturn'),
    ('alert-return', 'legacy-alert/sheet', 'NSAlertAlternateReturn', 'IsiXLegacyAlertAlternateReturn'),
    ('alert-return', 'legacy-alert/sheet', 'NSAlertOtherReturn', 'IsiXLegacyAlertOtherReturn'),
    ('alert-return', 'legacy-alert/sheet', 'NSAlertErrorReturn', 'IsiXLegacyAlertErrorReturn'),
    ('panel-return', 'legacy-alert/sheet', 'NSOKButton', 'NSModalResponseOK'),
    ('panel-return', 'legacy-alert/sheet', 'NSCancelButton', 'NSModalResponseCancel'),
    ('panel-return', 'legacy-alert/sheet', 'NSFileHandlingPanelOKButton', 'NSModalResponseOK'),
    ('panel-return', 'legacy-alert/sheet', 'NSFileHandlingPanelCancelButton', 'NSModalResponseCancel'),
    ('calendar-date', 'NSCalendarDate', 'NSCalendarDate', 'IsiXLegacyCalendarDate'),
]

# What is left after the rewrites, by category: (pattern, what to do).
LEFTOVERS = [
    ('legacy-alert/sheet', r'\bNSRunAlertPanelRelativeToWindow\b|\bNSGet\w*AlertPanel\b|\bNSReleaseAlertPanel\b',
     'no automatic rewrite: build an NSAlert and present it with -beginSheetModalForWindow:completionHandler:'),
    ('legacy-alert/sheet', r'modalDelegate\s*:|beginSheetForDirectory\s*:|runModalForDirectory\s*:|runModalForTypes\s*:|'
                           r'setRequiredFileType\s*:|alertWithMessageText\s*:',
     'a legacy sheet or panel call in a form the converter does not rewrite; use the completion handler forms '
     '(or a host class of the former SDK that takes a modal delegate, which the kit does not offer)'),
    ('legacy-alert/sheet', r'\bNSAlert(Default|Alternate|Other|Error)Return\b|\bNSOKButton\b|\bNSCancelButton\b|'
                           r'\bNSFileHandlingPanel\w*Button\b',
     'a legacy return code left in a form the converter does not rewrite'),
    ('deprecated-nib-loading', r'loadNibNamed\s*:[^\]]*?owner\s*:\s*[^\]]*\]|loadNibFile\s*:|instantiateNibWithOwner\s*:',
     'legacy nib loading in a form the converter does not rewrite; use '
     '-[NSBundle loadNibNamed:owner:topLevelObjects:] and keep the top-level objects'),
    ('deprecated-file-api', r'removeFileAtPath\s*:|copyPath\s*:|movePath\s*:|createDirectoryAtPath\s*:\s*[^\]]*?\battributes\s*:'
                            r'(?![^\]]*error\s*:)|directoryContentsAtPath\s*:|fileAttributesAtPath\s*:|'
                            r'stringWithContentsOfFile\s*:\s*[^\]\s]+\s*\]',
     'a legacy NSFileManager or NSString path call whose handler or arguments the converter cannot rewrite safely; '
     'use the ...Item...:error: form and handle the error'),
    ('NSCalendarDate', r'\bNSCalendarDate\b', 'NSCalendarDate in a form the converter does not rewrite'),
    ('garbage-collection', r'\bobjc_collect\w*|\bNSGarbageCollector\b|\bobjc_startCollectorThread\b|'
                           r'\b(NS|CF)MakeCollectable\b|\bNSAllocateCollectable\b|\bobjc_assign_\w+',
     'garbage collection is gone: release the object as manual reference counting or ARC requires'),
    ('garbage-collection', r'-\s*\(\s*void\s*\)\s*finalize\b',
     '-finalize is never called without garbage collection: move its clean-up to -dealloc'),
    ('Carbon', r'<Carbon/|\bFSRef\b|\bFSSpec\b|\bGetEventKind\b|\bAliasHandle\b',
     'Carbon has no automatic rewrite: use NSURL, NSFileManager and NSEvent'),
    ('legacy-sdk/arch', r'\b(MacOSX10\.[0-9]+u?\.sdk|ppc64|ppc7400|ppc970|ppc\b|i386)\b',
     'a reference to a former SDK or architecture in the source; the project builds arm64 and x86_64 on macOS 15'),
]


# ---------------------------------------------------------------- Xcode projects (OpenStep property lists)

class ParseError(Exception):
    pass


def parse_openstep(text):
    """The value of an OpenStep property list, such as a project.pbxproj."""
    position = [0]
    length = len(text)
    bare = re.compile(r'[A-Za-z0-9_$+/:.\-~]+')

    def skip():
        while position[0] < length:
            character = text[position[0]]
            if character in ' \t\r\n':
                position[0] += 1
            elif text.startswith('/*', position[0]):
                end = text.find('*/', position[0] + 2)
                position[0] = length if end < 0 else end + 2
            elif text.startswith('//', position[0]):
                end = text.find('\n', position[0])
                position[0] = length if end < 0 else end + 1
            else:
                break

    def expect(character):
        skip()
        if position[0] >= length or text[position[0]] != character:
            raise ParseError(f'expected {character!r} at {position[0]}')
        position[0] += 1

    def value():
        skip()
        if position[0] >= length:
            raise ParseError('unexpected end')
        character = text[position[0]]
        if character == '{':
            position[0] += 1
            result = {}
            while True:
                skip()
                if position[0] < length and text[position[0]] == '}':
                    position[0] += 1
                    return result
                key = value()
                expect('=')
                result[key] = value()
                skip()
                if position[0] < length and text[position[0]] == ';':
                    position[0] += 1
        if character == '(':
            position[0] += 1
            result = []
            while True:
                skip()
                if position[0] < length and text[position[0]] == ')':
                    position[0] += 1
                    return result
                result.append(value())
                skip()
                if position[0] < length and text[position[0]] == ',':
                    position[0] += 1
        if character == '"':
            position[0] += 1
            out = []
            while position[0] < length and text[position[0]] != '"':
                if text[position[0]] == '\\' and position[0] + 1 < length:
                    escaped = text[position[0] + 1]
                    out.append({'n': '\n', 't': '\t', 'r': '\r'}.get(escaped, escaped))
                    position[0] += 2
                else:
                    out.append(text[position[0]])
                    position[0] += 1
            position[0] += 1
            return ''.join(out)
        if character == '<':
            end = text.find('>', position[0])
            raw = text[position[0]:end + 1]
            position[0] = end + 1
            return raw
        match = bare.match(text, position[0])
        if not match:
            raise ParseError(f'unexpected {character!r} at {position[0]}')
        token = match.group(0)
        if '/*' in token or '//' in token:
            token = re.split(r'/[*/]', token)[0]
        position[0] += len(token)
        return token

    return value()


def as_list(value):
    if value is None:
        return []
    if isinstance(value, list):
        return [str(v) for v in value]
    return str(value).split()


class LegacyProject:
    """What a legacy Xcode project says about its plugin target."""

    def __init__(self, pbxproj):
        self.path = pbxproj
        data = parse_openstep(pbxproj.read_text(errors='replace'))
        self.objects = data.get('objects', {})
        self.root = self.objects.get(data.get('rootObject'), {})
        self.directory = (pbxproj.parent.parent / self.root.get('projectDirPath', '')).resolve()
        self.parents = {}
        for oid, obj in self.objects.items():
            if obj.get('isa') in ('PBXGroup', 'PBXVariantGroup'):
                for child in obj.get('children', []):
                    self.parents[child] = oid
        self._paths = {}

    def expand(self, value):
        return re.sub(r'\$[({](SRCROOT|PROJECT_DIR|SOURCE_ROOT|PROJECT_DERIVED_FILE_DIR)[)}]', str(self.directory), value)

    def resolve(self, oid):
        """The absolute path of a file reference or group, or None outside the project's folders."""
        if oid in self._paths:
            return self._paths[oid]
        self._paths[oid] = None  # guards against cycles
        obj = self.objects.get(oid, {})
        tree = obj.get('sourceTree', '<group>')
        path = self.expand(obj.get('path', '')) if obj.get('path') else ''
        result = None
        if tree == '<group>':
            parent = self.parents.get(oid)
            base = self.resolve(parent) if parent else self.directory
            if base is not None:
                result = (base / path) if path else base
        elif tree == 'SOURCE_ROOT':
            result = self.directory / path
        elif tree == '<absolute>':
            result = Path(path)
        if result is not None:
            result = Path(str(result))
        self._paths[oid] = result
        return result

    def settings(self, list_id):
        configurations = [self.objects.get(c, {}) for c in self.objects.get(list_id, {}).get('buildConfigurations', [])]
        by_name = {c.get('name'): c.get('buildSettings', {}) for c in configurations}
        for preferred in ('Release', 'Deployment', 'Default'):
            if preferred in by_name:
                return preferred, by_name[preferred]
        if configurations:
            return configurations[-1].get('name'), configurations[-1].get('buildSettings', {})
        return None, {}

    def targets(self):
        found = []
        for oid in self.root.get('targets', []):
            target = self.objects.get(oid, {})
            if target.get('isa') != 'PBXNativeTarget':
                continue
            name, settings = self.settings(target.get('buildConfigurationList'))
            project_by_name = {self.objects.get(c, {}).get('name'): self.objects.get(c, {}).get('buildSettings', {})
                               for c in self.objects.get(self.root.get('buildConfigurationList'), {})
                               .get('buildConfigurations', [])}
            merged = dict(project_by_name.get(name) or self.settings(self.root.get('buildConfigurationList'))[1])
            merged.update(settings)
            product = self.objects.get(target.get('productReference'), {})
            product_path = str(product.get('path', ''))
            wrapper = str(merged.get('WRAPPER_EXTENSION', ''))
            score = 0
            if wrapper in ('osirixplugin', 'horosplugin') or re.search(r'\.(osirixplugin|horosplugin)$', product_path):
                score = 3
            elif re.search(r'\.(plugin|bundle)$', product_path) or wrapper in ('plugin', 'bundle'):
                score = 2
            elif 'bundle' in str(target.get('productType', '')) and 'test' not in str(target.get('productType', '')):
                score = 1
            found.append({'id': oid, 'name': str(target.get('name', '')), 'settings': merged, 'score': score,
                          'product': product_path, 'phases': target.get('buildPhases', [])})
        return found

    def phase_files(self, target, isa):
        """(file reference id, settings) of every build file of a phase kind."""
        for phase_id in target['phases']:
            phase = self.objects.get(phase_id, {})
            if phase.get('isa') != isa:
                continue
            for build_id in phase.get('files', []):
                build = self.objects.get(build_id, {})
                if build.get('fileRef'):
                    yield build['fileRef'], build.get('settings', {})

    def phase_kinds(self, target):
        return [self.objects.get(p, {}).get('isa', '') for p in target['phases']]


# ---------------------------------------------------------------- source text

def newline_of(text):
    if '\r\n' in text:
        return '\r\n'
    if '\r' in text and '\n' not in text:
        return '\r'
    return '\n'


def normalized(text):
    """The text with one \\n per line break and the same length."""
    return text.replace('\r\n', ' \n').replace('\r', '\n')


def masks(text):
    """(comments blanked, comments and strings blanked), both the length of `text`."""
    return inv.strip_source(normalized(text))


def line_at(norm, position):
    return norm.count('\n', 0, position) + 1


def is_import_line(norm, position):
    start = norm.rfind('\n', 0, position) + 1
    return re.match(r'\s*#\s*(import|include)\b', norm[start:position + 1]) is not None


def matching(masked, start, opening, closing):
    depth = 0
    for index in range(start, len(masked)):
        if masked[index] == opening:
            depth += 1
        elif masked[index] == closing:
            depth -= 1
            if depth == 0:
                return index
    return -1


class Message:
    """An Objective-C message send: [receiver keyword:argument ...]."""

    def __init__(self, start, end, receiver, parts):
        self.start, self.end = start, end
        self.unary = None
        self.receiver = receiver  # (text, start, end)
        self.parts = parts  # [(keyword, keyword start, argument text, argument start, argument end)]

    @property
    def selector(self):
        return ''.join(k + ':' for k, *_ in self.parts) if self.parts else self.unary

    def argument(self, keyword):
        return next(p[2] for p in self.parts if p[0] == keyword)


def parse_message(text, masked, start):
    """The message whose '[' is at `start`, or None."""
    end = matching(masked, start, '[', ']')
    if end < 0:
        return None
    inner = start + 1
    depth = 0
    keywords = []
    for index in range(inner, end):
        character = masked[index]
        if character in '([{':
            depth += 1
        elif character in ')]}':
            depth -= 1
        elif depth == 0 and character == ':' and masked[index + 1:index + 2] != ':' and masked[index - 1] != ':':
            match = re.search(r'([A-Za-z_]\w*)$', masked[inner:index])
            if not match:
                continue
            word_start = index - len(match.group(1))
            if word_start == inner or masked[word_start - 1] in ' \t\n)]':
                keywords.append((match.group(1), word_start, index))
    if not keywords:
        match = re.match(r'(.*\S)\s+([A-Za-z_]\w*)\s*$', masked[inner:end], re.S)
        if not match:
            return None
        receiver_end = inner + len(match.group(1))
        receiver = (text[inner:receiver_end].strip(), inner, receiver_end)
        message = Message(start, end, receiver, [])
        message.unary = match.group(2)
        return message
    receiver_text = text[inner:keywords[0][1]]
    if not receiver_text.strip():
        return None
    parts = []
    for number, (keyword, word_start, colon) in enumerate(keywords):
        argument_end = keywords[number + 1][1] if number + 1 < len(keywords) else end
        raw = text[colon + 1:argument_end]
        leading = len(raw) - len(raw.lstrip())
        trailing = len(raw) - len(raw.rstrip())
        parts.append((keyword, word_start, raw.strip(), colon + 1 + leading, argument_end - trailing))
    return Message(start, end, (receiver_text.strip(), inner + (len(receiver_text) - len(receiver_text.lstrip())),
                                keywords[0][1] - (len(receiver_text) - len(receiver_text.rstrip()))), parts)


def messages_with(text, masked, first_keyword):
    """Every message whose selector starts with `first_keyword` (a keyword with
    its colon, or a unary selector)."""
    found = []
    if first_keyword.endswith(':'):
        pattern = re.compile(r'(?<![\w.])%s\s*:' % re.escape(first_keyword[:-1]))
    else:
        pattern = re.compile(r'(?<![\w.:])%s\s*\]' % re.escape(first_keyword))
    for match in pattern.finditer(masked):
        depth = 0
        index = match.start() - 1
        while index >= 0:
            character = masked[index]
            if character in ')]}':
                depth += 1
            elif character in '([{':
                if depth == 0:
                    break
                depth -= 1
            elif character == ';' and depth == 0:
                index = -1
                break
            index -= 1
        if index < 0 or masked[index] != '[':
            continue
        message = parse_message(text, masked, index)
        if message and (message.parts and message.parts[0][1] == match.start() or
                        not message.parts and first_keyword == message.unary):
            found.append(message)
    return found


def call_text(text, norm, name, items, close, newline):
    """name(item, item...) keeping the line breaks of the legacy layout:
    `items` are (text, start, end) with start None for a new literal; `close`
    is where the legacy expression ended."""
    out = [name, '(']
    previous_end = None
    for number, (item, start, end) in enumerate(items):
        if number:
            gap = norm[previous_end:start] if previous_end is not None and start is not None else ''
            breaks = gap.count('\n')
            if breaks:
                line_start = norm.rfind('\n', 0, start) + 1
                indent = re.match(r'[ \t]*', norm[line_start:]).group(0)
                out.append(',' + newline * breaks + indent)
            else:
                out.append(', ')
        out.append(item)
        if end is not None:
            previous_end = end
    if previous_end is not None and norm[previous_end:close].count('\n'):
        out.append(newline * norm[previous_end:close].count('\n'))
    out.append(')')
    return ''.join(out)


# ---------------------------------------------------------------- rewrites

class Rewriter:
    """The mechanical rewrites of one source file."""

    def __init__(self, text, arc):
        self.text = text
        self.arc = arc
        self.newline = newline_of(text)
        self.changes = []

    def refresh(self):
        self.norm = normalized(self.text)
        self.comments_blanked, self.masked = masks(self.text)

    def apply(self, edits):
        """Apply non-overlapping edits (start, end, replacement, rule, category); True if any."""
        edits = sorted(edits, key=lambda e: (e[0], -e[1]))
        chosen = []
        last_end = -1
        for edit in edits:
            if edit[0] >= last_end:
                chosen.append(edit)
                last_end = edit[1]
        for start, end, replacement, rule, category in reversed(chosen):
            before = self.text[start:end]
            line = line_at(self.norm, start)
            self.text = self.text[:start] + replacement + self.text[end:]
            self.changes.append({'rule': rule, 'category': category, 'line': line,
                                 'before': ' '.join(before.split())[:200], 'after': ' '.join(replacement.split())[:200]})
        return bool(chosen)

    def run(self, rule):
        """Apply `rule` until it finds nothing more (nested calls come out one level at a time)."""
        for _ in range(50):
            self.refresh()
            if not self.apply(rule()):
                return

    def rewrite(self):
        self.run(self.renames)
        for rule in (self.alert_message_text, self.app_sheets, self.alert_sheets, self.panel_sheets, self.panel_modal,
                     self.panel_required_type, self.panel_filenames, self.nib_loading, self.file_api,
                     self.calendar_messages, self.garbage_collection):
            self.run(rule)
        self.changes.sort(key=lambda change: change['line'])
        return self.text

    # -- identifiers

    def renames(self):
        edits = []
        for rule, category, old, new in RENAMES:
            for match in re.finditer(r'(?<![\w$])%s(?![\w$])' % old, self.masked):
                if not is_import_line(self.norm, match.start()):
                    edits.append((match.start(), match.end(), new, rule, category))
        return edits

    # -- helpers for messages

    def as_call(self, message, name, items):
        """The message as a call of `name`; `items` are argument names of the
        message ('receiver' or a keyword) or literal text."""
        resolved = []
        for item in items:
            if item == 'receiver':
                resolved.append(message.receiver)
            elif isinstance(item, str) and any(p[0] == item for p in message.parts):
                part = next(p for p in message.parts if p[0] == item)
                resolved.append((part[2], part[3], part[4]))
            else:
                resolved.append((item, None, None))
        return call_text(self.text, self.norm, name, resolved, message.end, self.newline)

    def selector_messages(self, selector):
        first = selector.split(':')[0] + (':' if ':' in selector else '')
        return [m for m in messages_with(self.text, self.masked, first) if m.selector == selector]

    # -- alerts and sheets

    def alert_message_text(self):
        edits = []
        selector = 'alertWithMessageText:defaultButton:alternateButton:otherButton:informativeTextWithFormat:'
        for message in self.selector_messages(selector):
            if message.receiver[0] != 'NSAlert':
                continue
            call = self.as_call(message, 'IsiXLegacyAlertWithMessageText',
                                ['alertWithMessageText', 'defaultButton', 'alternateButton', 'otherButton',
                                 'informativeTextWithFormat'])
            edits.append((message.start, message.end + 1, call, 'alert-message-text', 'legacy-alert/sheet'))
        return edits

    def app_sheets(self):
        edits = []
        for message in self.selector_messages('beginSheet:modalForWindow:modalDelegate:didEndSelector:contextInfo:'):
            if not NS_APP.match(message.receiver[0]):
                continue
            call = self.as_call(message, 'IsiXLegacyBeginSheet',
                                ['beginSheet', 'modalForWindow', 'modalDelegate', 'didEndSelector', 'contextInfo'])
            edits.append((message.start, message.end + 1, call, 'app-sheet', 'legacy-alert/sheet'))
        return edits

    def alert_sheets(self):
        edits = []
        for message in self.selector_messages('beginSheetModalForWindow:modalDelegate:didEndSelector:contextInfo:'):
            if message.receiver[0] == 'super':
                continue
            call = self.as_call(message, 'IsiXLegacyAlertBeginSheet',
                                ['receiver', 'beginSheetModalForWindow', 'modalDelegate', 'didEndSelector', 'contextInfo'])
            edits.append((message.start, message.end + 1, call, 'alert-modal-sheet', 'legacy-alert/sheet'))
        return edits

    def panel_sheets(self):
        edits = []
        forms = {
            'beginSheetForDirectory:file:modalForWindow:modalDelegate:didEndSelector:contextInfo:':
                ['receiver', 'beginSheetForDirectory', 'file', 'nil', 'modalForWindow', 'modalDelegate',
                 'didEndSelector', 'contextInfo'],
            'beginSheetForDirectory:file:types:modalForWindow:modalDelegate:didEndSelector:contextInfo:':
                ['receiver', 'beginSheetForDirectory', 'file', 'types', 'modalForWindow', 'modalDelegate',
                 'didEndSelector', 'contextInfo'],
        }
        for selector, items in forms.items():
            for message in self.selector_messages(selector):
                if message.receiver[0] == 'super':
                    continue
                edits.append((message.start, message.end + 1, self.as_call(message, 'IsiXLegacyPanelBeginSheet', items),
                              'panel-sheet', 'legacy-alert/sheet'))
        return edits

    def panel_modal(self):
        edits = []
        forms = {
            'runModalForDirectory:file:': ['receiver', 'runModalForDirectory', 'file', 'nil'],
            'runModalForDirectory:file:types:': ['receiver', 'runModalForDirectory', 'file', 'types'],
            'runModalForTypes:': ['receiver', 'nil', 'nil', 'runModalForTypes'],
        }
        for selector, items in forms.items():
            for message in self.selector_messages(selector):
                if message.receiver[0] == 'super':
                    continue
                edits.append((message.start, message.end + 1, self.as_call(message, 'IsiXLegacyPanelRunModal', items),
                              'panel-modal', 'legacy-alert/sheet'))
        return edits

    def panel_required_type(self):
        edits = []
        for message in self.selector_messages('setRequiredFileType:'):
            if message.receiver[0] == 'super':
                continue
            edits.append((message.start, message.end + 1,
                          self.as_call(message, 'IsiXLegacyPanelSetRequiredFileType', ['receiver', 'setRequiredFileType']),
                          'panel-required-type', 'legacy-alert/sheet'))
        return edits

    def panel_filenames(self):
        edits = []
        for message in messages_with(self.text, self.masked, 'filenames'):
            if message.receiver[0] in ('self', 'super') or message.parts:
                continue
            edits.append((message.start, message.end + 1,
                          self.as_call(message, 'IsiXLegacyPanelFilenames', ['receiver']),
                          'panel-filenames', 'legacy-alert/sheet'))
        return edits

    # -- nibs

    def nib_loading(self):
        edits = []
        for message in self.selector_messages('loadNibNamed:owner:'):
            if message.receiver[0] != 'NSBundle':
                continue
            edits.append((message.start, message.end + 1,
                          self.as_call(message, 'IsiXLegacyLoadNibNamed', ['loadNibNamed', 'owner']),
                          'nib-loading', 'deprecated-nib-loading'))
        return edits

    # -- file paths

    def file_api(self):
        edits = []
        category = 'deprecated-file-api'

        def keyword_edit(message, keyword, new):
            part = next(p for p in message.parts if p[0] == keyword)
            return (part[1], part[1] + len(keyword), new)

        def argument_edit(message, keyword, new):
            part = next(p for p in message.parts if p[0] == keyword)
            return (part[3], part[4], new)

        def grouped(message, pieces, rule):
            # The edits of one message, applied together as one edit of the message.
            start, end = message.start, message.end + 1
            body = self.text[start:end]
            for piece_start, piece_end, new in sorted(pieces, reverse=True):
                body = body[:piece_start - start] + new + body[piece_end - start:]
            edits.append((start, end, body, rule, category))

        for old, new in (('removeFileAtPath:handler:', 'removeItemAtPath'), ('copyPath:toPath:handler:', 'copyItemAtPath'),
                         ('movePath:toPath:handler:', 'moveItemAtPath')):
            for message in self.selector_messages(old):
                if not NIL.match(message.argument('handler')):
                    continue
                grouped(message, [keyword_edit(message, old.split(':')[0], new), keyword_edit(message, 'handler', 'error'),
                                  argument_edit(message, 'handler', 'NULL')], 'file-path')
        for message in self.selector_messages('createDirectoryAtPath:attributes:'):
            part = next(p for p in message.parts if p[0] == 'attributes')
            grouped(message, [(part[1], part[1], 'withIntermediateDirectories:NO '),
                              (part[4], part[4], ' error:NULL')], 'file-path')
        for message in self.selector_messages('directoryContentsAtPath:'):
            part = message.parts[0]
            grouped(message, [keyword_edit(message, 'directoryContentsAtPath', 'contentsOfDirectoryAtPath'),
                              (part[4], part[4], ' error:NULL')], 'file-path')
        for message in self.selector_messages('fileAttributesAtPath:traverseLink:'):
            traverse = message.argument('traverseLink')
            if traverse not in ('YES', 'NO', 'TRUE', 'FALSE', 'true', 'false', '1', '0'):
                continue
            path = next(p for p in message.parts if p[0] == 'fileAttributesAtPath')
            pieces = [keyword_edit(message, 'fileAttributesAtPath', 'attributesOfItemAtPath'),
                      keyword_edit(message, 'traverseLink', 'error'), argument_edit(message, 'traverseLink', 'NULL')]
            if traverse in ('YES', 'TRUE', 'true', '1'):
                pieces.append((path[3], path[4], '[%s stringByResolvingSymlinksInPath]' % path[2]))
            grouped(message, pieces, 'file-path')
        for message in self.selector_messages('stringWithContentsOfFile:'):
            if message.receiver[0] not in ('NSString', 'NSMutableString'):
                continue
            part = message.parts[0]
            grouped(message, [(part[4], part[4], ' usedEncoding:NULL error:NULL')], 'file-path')
        return edits

    # -- NSCalendarDate

    def calendar_messages(self):
        edits = []
        for message in self.selector_messages('dateWithCalendarFormat:timeZone:'):
            if message.receiver[0] == 'super':
                continue
            body = '[IsiXLegacyCalendarDate dateWithDate:%s calendarFormat:%s timeZone:%s]' % (
                message.receiver[0], message.argument('dateWithCalendarFormat'), message.argument('timeZone'))
            edits.append((message.start, message.end + 1, body, 'calendar-date', 'NSCalendarDate'))
        for message in self.selector_messages('descriptionWithCalendarFormat:timeZone:locale:'):
            if message.receiver[0] == 'super':
                continue
            body = '[IsiXLegacyCalendarDate descriptionOfDate:%s calendarFormat:%s timeZone:%s locale:%s]' % (
                message.receiver[0], message.argument('descriptionWithCalendarFormat'), message.argument('timeZone'),
                message.argument('locale'))
            edits.append((message.start, message.end + 1, body, 'calendar-date', 'NSCalendarDate'))
        return edits

    # -- garbage collection

    def garbage_collection(self):
        edits = []
        category = 'garbage-collection'
        for match in re.finditer(r'(?<![\w$])(objc_collectingEnabled|objc_collecting_enabled)\s*\(\s*\)', self.masked):
            edits.append((match.start(), match.end(), 'NO', 'garbage-collection', category))
        for match in re.finditer(r'(?<![\w$])(objc_collect|objc_startCollectorThread)\s*\(', self.masked):
            close = matching(self.masked, match.end() - 1, '(', ')')
            if close > 0:
                edits.append((match.start(), close + 1, '((void)0)', 'garbage-collection', category))
        for match in re.finditer(r'\[\s*NSGarbageCollector\s+defaultCollector\s*\]', self.masked):
            # Without the collector, the default collector is nil: a message to it
            # does nothing and answers 0.
            outer = re.search(r'\[\s*$', self.masked[:match.start()])
            close = matching(self.masked, outer.start(), '[', ']') if outer else -1
            if close > 0:
                before = self.masked[:outer.start()].rstrip()
                after = self.masked[close + 1:].lstrip()
                statement = after.startswith(';') and (not before or before[-1] in ';{})')
                edits.append((outer.start(), close + 1, '((void)0)' if statement else '0', 'garbage-collection',
                              category))
            else:
                edits.append((match.start(), match.end(), '((id)nil)', 'garbage-collection', category))
        if not self.arc:
            for match in re.finditer(r'(?<![\w$])(NSMakeCollectable|CFMakeCollectable)\s*\(', self.masked):
                close = matching(self.masked, match.end() - 1, '(', ')')
                if close > 0:
                    argument = self.text[match.end():close]
                    new = '((id)(%s))' % argument if match.group(1) == 'NSMakeCollectable' else '(%s)' % argument
                    edits.append((match.start(), close + 1, new, 'garbage-collection', category))
        return edits


def leftovers_of(text):
    """What is left of the legacy calls the converter deals with: (category, line, text, hint)."""
    norm = normalized(text)
    _, code = masks(text)
    found = []
    seen = set()
    for category, pattern, hint in LEFTOVERS:
        for match in re.finditer(pattern, code):
            if is_import_line(norm, match.start()) and category not in ('Carbon',):
                continue
            line = line_at(norm, match.start())
            if (category, line) in seen:
                continue
            seen.add((category, line))
            source_line = norm.split('\n')[line - 1].strip()
            found.append((category, line, source_line[:160], hint))
    return sorted(found, key=lambda f: (f[1], f[0]))


def decode(raw):
    try:
        return raw.decode('utf-8'), 'utf-8'
    except UnicodeDecodeError:
        return raw.decode('latin-1'), 'latin-1'


def system_value(version):
    """'15.0' as Interface Builder writes a system in a xib: 150000 (10.5 was 1050)."""
    major, minor = (version.split('.') + ['0'])[:2]
    return int(major) * 10000 + int(minor) * 100


def rewrite_xib(text):
    """(new text, changes) of one xib: a system it was set to build for before
    the plugin's (macOS 10.5 in most legacy plugins), which ibtool refuses to
    compile before 10.6, becomes the plugin's. In the document format the
    deployment's version is dropped, so the xib builds for the project's
    system, as Xcode writes it; in the IB 3 archive format, which has no such
    form, IBDocument.SystemTarget and the Cocoa plugin's declared dependency
    are set to the plugin's system."""
    minimum = system_value(MINIMUM_SYSTEM)
    edits = []
    for pattern in XIB_ARCHIVE_TARGETS:
        for match in pattern.finditer(text):
            if int(match.group(1)) < minimum:
                edits.append((match.start(1), match.end(1), str(minimum)))
    for match in XIB_DEPLOYMENT.finditer(text):
        version = XIB_DEPLOYMENT_VERSION.search(match.group(0))
        if version and 'identifier="macosx"' in match.group(0) and int(version.group(1)) < minimum:
            edits.append((match.start() + version.start(), match.start() + version.end(), ''))
    changes = []
    for start, end, replacement in sorted(edits, reverse=True):
        line = line_at(text, start)
        tag_start, tag_end = text.rfind('<', 0, start), text.find('>', end) + 1
        before = text[tag_start:tag_end]
        text = text[:start] + replacement + text[end:]
        changes.append({'rule': 'xib-system', 'category': 'legacy-sdk/arch', 'line': line,
                        'before': before, 'after': before[:start - tag_start] + replacement + before[end - tag_start:]})
    return text, sorted(changes, key=lambda c: c['line'])


def rewrite_source(text, arc):
    """(new text, changes, leftovers) of one source file."""
    rewriter = Rewriter(text, arc)
    new = rewriter.rewrite()
    leftovers = [{'category': c, 'line': line, 'text': t, 'hint': h} for c, line, t, h in leftovers_of(new)]
    return new, rewriter.changes, leftovers


# ---------------------------------------------------------------- the plugin

def module_name(name):
    module = re.sub(r'\W', '', name or '') or 'LegacyPlugin'
    return module if not module[0].isdigit() else 'Legacy' + module


def own_files(source):
    """Every file of the plugin's own, outside copies of the former SDK and build products."""
    for path in sorted(source.rglob('*')):
        relative = path.relative_to(source)
        if any(FORMER_SDK.search(part) for part in relative.parts) or path.name in ('.DS_Store',):
            continue
        if path.is_symlink() or not path.is_file():
            continue
        if any(part.endswith('.nib') for part in relative.parts[:-1]):
            continue  # inside a nib wrapper, which is copied whole
        yield path


def in_library(relative):
    return any(LIBRARY_FOLDER.search(part) or inv.VENDORED_DIR.search(part) for part in Path(relative).parts[:-1])


def read_info(path, notes):
    raw = path.read_bytes()
    try:
        info = plistlib.loads(raw)
        if isinstance(info, dict):
            return info
    except Exception:
        pass
    picked = inv.read_plist(path) or {}
    picked.pop('_unparsed', None)
    picked.pop('file', None)
    notes.append({'category': 'build', 'file': path.name, 'line': None,
                  'text': 'Info.plist is not a valid property list',
                  'hint': 'rebuilt from the keys the converter could read: ' + ', '.join(sorted(picked))})
    return picked


def expand_variables(value, module):
    return BUILD_VARIABLE.sub(module, value) if isinstance(value, str) else value


def ported_info(info, module, legacy_class, capabilities):
    """The Info.plist of API 1 for the legacy plugin's Info.plist."""
    info = {key: expand_variables(value, module) for key, value in info.items()}
    for old, new in RENAMED_KEYS.items():
        if old in info:
            info[new] = info.pop(old)
    for key in DROPPED_KEYS:
        info.pop(key, None)
    info['IsiXLegacyFilterClass'] = legacy_class
    info['NSPrincipalClass'] = f'{module}.IsiXLegacyPluginEntry'
    info['CFBundleExecutable'] = module
    info['IsiXPluginAPIVersion'] = 1
    info['IsiXPluginCapabilities'] = capabilities
    info['CFBundlePackageType'] = 'BNDL'
    info['LSMinimumSystemVersion'] = MINIMUM_SYSTEM
    identifier = str(info.get('CFBundleIdentifier') or '')
    if not identifier or '$' in identifier:
        info['CFBundleIdentifier'] = f'org.isix.legacy.{module}'
    if not info.get('CFBundleName') or '$' in str(info.get('CFBundleName')):
        info['CFBundleName'] = module
    info.setdefault('CFBundleShortVersionString', str(info.get('CFBundleVersion', '1.0')))
    return info


class Plugin:
    """A legacy plugin read for conversion: its files, its target and the report."""

    def __init__(self, source, name=None, arc=None, frameworks=(), exclude=()):
        self.source = Path(source).resolve()
        self.notes = []          # what has no equivalent outside the source: {category, file, line, text, hint}
        self.project_changes = []  # settings the conversion replaced: {category, setting, before, after}
        self.exclude = set(exclude)
        self.extra_frameworks = list(frameworks)
        self.legacy = None
        self.target = None
        self.read_project()
        self.read_files(arc)
        self.read_info_plist(name)
        if self.info_path is not None:
            # The legacy Info.plist becomes Config/Info.plist; it stays in Porting/original.
            moved = self.relative(self.info_path)
            if moved is not None:
                self.files.pop(str(moved), None)

    # -- the legacy project

    def note(self, category, text, hint=None, file=None, line=None):
        self.notes.append({'category': category, 'file': file, 'line': line, 'text': text, 'hint': hint})

    def read_project(self):
        projects = sorted(self.source.glob('*.xcodeproj/project.pbxproj')) + \
            sorted(self.source.glob('*/*.xcodeproj/project.pbxproj'))
        candidates = []
        for pbxproj in projects:
            try:
                project = LegacyProject(pbxproj)
            except Exception as error:  # a damaged project: the folder is read instead
                self.note('build', f'{pbxproj.parent.name} could not be read ({error})',
                          'the files were taken from the folder', file=str(pbxproj.parent.relative_to(self.source)))
                continue
            for target in project.targets():
                candidates.append((target['score'], -len(candidates), project, target))
        candidates = [c for c in candidates if c[0] > 0]
        if not candidates:
            if projects:
                self.note('build', 'no bundle target in the Xcode project', 'the files were taken from the folder')
            return
        candidates.sort(key=lambda c: (c[0], c[1]), reverse=True)
        _, _, self.legacy, self.target = candidates[0]
        for _, _, project, target in candidates[1:]:
            self.note('build', f'target {target["name"]} of {project.path.parent.name} is not converted',
                      'only the plugin target is; convert the others by hand if the plugin needs them',
                      file=str(project.path.parent.relative_to(self.source)))
        settings = self.target['settings']
        for key in ('ARCHS', 'VALID_ARCHS', 'SDKROOT', 'MACOSX_DEPLOYMENT_TARGET', 'GCC_VERSION'):
            if key in settings:
                after = {'ARCHS': ' '.join(ARCHS), 'VALID_ARCHS': '(not set)', 'SDKROOT': 'macosx',
                         'MACOSX_DEPLOYMENT_TARGET': MINIMUM_SYSTEM, 'GCC_VERSION': '(not set)'}[key]
                self.project_changes.append({'category': 'legacy-sdk/arch', 'setting': key,
                                             'before': ' '.join(as_list(settings[key])), 'after': after})
        if str(settings.get('GCC_ENABLE_OBJC_GC', 'unsupported')) in ('supported', 'required', 'YES'):
            self.project_changes.append({'category': 'garbage-collection', 'setting': 'GCC_ENABLE_OBJC_GC',
                                         'before': str(settings['GCC_ENABLE_OBJC_GC']), 'after': '(not set)'})
        flags = ' '.join(as_list(settings.get('OTHER_LDFLAGS')))
        if 'dynamic_lookup' in flags or settings.get('BUNDLE_LOADER'):
            self.project_changes.append({'category': 'legacy-sdk/arch', 'setting': 'OTHER_LDFLAGS / BUNDLE_LOADER',
                                         'before': (flags + ' ' + str(settings.get('BUNDLE_LOADER', ''))).strip(),
                                         'after': '-framework IsiXPluginKit: every symbol is resolved when linking'})
        for kind in self.legacy.phase_kinds(self.target):
            if kind in ('PBXShellScriptBuildPhase', 'PBXCopyFilesBuildPhase'):
                self.note('build', f'a {kind[3:]} of the legacy target is not converted',
                          'add it to the project by hand if the plugin needs it',
                          file=str(self.legacy.path.parent.relative_to(self.source)))

    def setting(self, key, default=None):
        return self.target['settings'].get(key, default) if self.target else default

    def legacy_path(self, value):
        value = self.legacy.expand(str(value).strip('"'))
        if '$' in value:
            return None
        path = Path(value)
        return (path if path.is_absolute() else self.legacy.directory / path).resolve()

    def relative(self, path):
        """The path inside the plugin's folder, or None outside it."""
        try:
            return path.resolve().relative_to(self.source)
        except ValueError:
            return None

    def former_sdk(self, path):
        return any(FORMER_SDK.search(part) for part in path.parts)

    # -- files

    def read_files(self, arc):
        self.files = {}         # relative path in Sources -> absolute source path
        self.sources = []       # {'path': relative, 'arc': bool, 'flags': [...]}
        self.resources = []     # {'path': relative, 'destination': ...}
        self.frameworks, self.libraries = [], []
        self.defines = []
        for path in own_files(self.source):
            relative = path.relative_to(self.source)
            self.files[str(relative)] = path
        for nib in sorted(self.source.rglob('*.nib')):
            relative = nib.relative_to(self.source)
            if nib.is_dir() and not any(FORMER_SDK.search(part) for part in relative.parts):
                self.files[str(relative)] = nib
        default_arc = str(self.setting('CLANG_ENABLE_OBJC_ARC', 'NO')) == 'YES'
        if arc is not None:
            default_arc = arc
        self.arc = default_arc
        if self.target:
            self.files_from_project()
        else:
            self.files_from_folder()
        self.sources = [s for s in self.sources if Path(s['path']).name not in self.exclude]
        self.resources = [r for r in self.resources if Path(r['path']).name not in self.exclude]
        for framework in [*DEFAULT_FRAMEWORKS, *self.extra_frameworks]:
            if framework not in self.frameworks:
                self.frameworks.append(framework)
        if any(Path(s['path']).suffix == '.swift' for s in self.sources):
            self.note('build', 'the plugin has Swift sources',
                      'they are compiled in the plugin\'s module with the kit\'s Swift; check them by hand')

    def add_source(self, relative, flags_text='', file_type=None):
        flags = as_list(flags_text)
        arc = self.arc
        kept, dropped = [], []
        index = 0
        while index < len(flags):
            flag = flags[index]
            if flag in ('-I', '-isystem', '-iquote', '-include') and index + 1 < len(flags):
                flag = flag + ' ' + flags[index + 1]
                index += 1
            index += 1
            if flag == '-fobjc-arc':
                arc = True
            elif flag == '-fno-objc-arc':
                arc = False
            elif KEPT_FLAG.match(flag):
                kept.append(flag)
            else:
                dropped.append(flag)
        if dropped:
            self.note('build', f'compiler flags of {relative} not kept: {" ".join(dropped)[:300]}',
                      'header paths of the former SDK and flags of former compilers and architectures do not apply; '
                      'the project\'s header search has the plugin\'s own folders', file=str(relative))
        source = {'path': str(relative), 'arc': arc, 'flags': kept}
        language = LANGUAGES.get(file_type)
        if language and language != SUFFIX_LANGUAGES.get(Path(relative).suffix):
            source['language'] = language
        self.sources.append(source)

    def external(self, path):
        """A file of the legacy target outside the plugin's folder: copied in External/."""
        relative = Path('External') / path.name
        self.files[str(relative)] = path
        self.note('build', f'{path.name} comes from outside the plugin\'s folder',
                  f'copied into Sources/{relative}', file=str(relative))
        return relative

    def files_from_project(self):
        project, target = self.legacy, self.target
        self.library_sources = []
        for file_id, settings in project.phase_files(target, 'PBXSourcesBuildPhase'):
            path = project.resolve(file_id)
            if path is None:
                continue
            relative = self.relative(path)
            if relative is None and self.former_sdk(path):
                continue
            if not path.exists():
                self.note('build', f'{path.name}, compiled by the legacy target, is missing',
                          'the project builds without it', file=str(relative or path.name))
                continue
            if relative is None:
                relative = self.external(path)
            if relative.suffix in COMPILED and in_library(relative):
                self.library_sources.append(str(relative))
            elif relative.suffix in COMPILED:
                reference = project.objects.get(file_id, {})
                self.add_source(relative, settings.get('COMPILER_FLAGS', ''),
                                reference.get('explicitFileType') or reference.get('lastKnownFileType'))
        for file_id, _ in project.phase_files(target, 'PBXResourcesBuildPhase'):
            obj = project.objects.get(file_id, {})
            children = obj.get('children', []) if obj.get('isa') == 'PBXVariantGroup' else [file_id]
            for child in children:
                path = project.resolve(child)
                if path is None:
                    continue
                relative = self.relative(path)
                if path.name == 'Info.plist' or (relative is None and self.former_sdk(path)):
                    continue
                if not path.exists():
                    self.note('build', f'resource {path.name} of the legacy target is missing',
                              'the project builds without it', file=str(relative or path.name))
                    continue
                if relative is None:
                    relative = self.external(path)
                lproj = path.parent.name if path.parent.name.endswith('.lproj') else None
                if obj.get('isa') == 'PBXVariantGroup' and not lproj:
                    lproj = str(project.objects.get(child, {}).get('name', 'English')) + '.lproj'
                destination = f'{lproj}/{path.name}' if lproj else path.name
                if path.is_dir() and path.suffix != '.nib':
                    for inner in sorted(p for p in path.rglob('*') if p.is_file()):
                        inner_relative = self.relative(inner) or Path(relative) / inner.relative_to(path)
                        self.files.setdefault(str(inner_relative), inner)
                    self.resources.append({'path': str(relative), 'destination': destination, 'folder': True})
                else:
                    self.files.setdefault(str(relative), path)
                    self.resources.append({'path': str(relative), 'destination': destination})
        if self.library_sources:
            self.note('build', f'{len(self.library_sources)} source file(s) of the plugin\'s own copy of a library not '
                      f'built: {", ".join(self.library_sources[:4])}{"..." if len(self.library_sources) > 4 else ""}',
                      'bring the library as a library of the plugin (tools/build-isix-legacy-plugin.py --library)')
        self.unlinked = []
        for file_id, _ in project.phase_files(target, 'PBXFrameworksBuildPhase'):
            obj = project.objects.get(file_id, {})
            self.add_linked(str(obj.get('path') or obj.get('name') or ''))
        flags = as_list(self.setting('OTHER_LDFLAGS'))
        for index, flag in enumerate(flags):
            if flag == '-framework' and index + 1 < len(flags):
                self.add_linked(flags[index + 1] + '.framework')
            elif flag.startswith('-l') and len(flag) > 2:
                self.add_linked('lib' + flag[2:] + '.dylib')
        if self.unlinked:
            self.note('build', f'{len(self.unlinked)} librar{"y" if len(self.unlinked) == 1 else "ies"} of the plugin '
                      f'not linked: {", ".join(self.unlinked[:6])}{"..." if len(self.unlinked) > 6 else ""}',
                      'a library the plugin carries must be built for arm64 and x86_64 and brought by the plugin; '
                      'see the IsiXPluginKit guide on libraries of your own', file=str(project.path.parent.name))
        for define in as_list(self.setting('GCC_PREPROCESSOR_DEFINITIONS')):
            if define != '$(inherited)' and '$' not in define and define not in self.defines:
                self.defines.append(define)
        prefix = self.setting('GCC_PREFIX_HEADER')
        self.prefix = None
        if prefix:
            path = self.legacy_path(prefix)
            relative = self.relative(path) if path else None
            if relative is not None and path.is_file():
                self.prefix = str(relative)
            else:
                self.note('build', f'prefix header {prefix} not found', 'the project builds without it')
        self.info_path = None
        info = self.setting('INFOPLIST_FILE')
        if info:
            path = self.legacy_path(info)
            if path is not None and path.is_file():
                self.info_path = path

    def files_from_folder(self):
        for relative, path in self.files.items():
            relative = Path(relative)
            if in_library(relative):
                continue
            if relative.suffix in COMPILED:
                self.add_source(relative)
            elif relative.suffix in RESOURCE_SUFFIXES and relative.name not in ('Info.plist', 'version.plist'):
                lproj = next((part for part in relative.parts[:-1] if part.endswith('.lproj')), None)
                self.resources.append({'path': str(relative), 'destination': f'{lproj}/{relative.name}' if lproj
                                       else relative.name})
        found = sorted(p for p in self.source.glob('*.pch'))
        self.prefix = str(found[0].relative_to(self.source)) if found else None
        self.info_path = None

    def add_linked(self, name):
        name = name.strip('"').split('/')[-1]
        stem = re.sub(r'\.(framework|dylib|tbd|a)$', '', name)
        sdk = macos_sdk()
        if name.endswith('.framework'):
            if stem in FORMER_FRAMEWORKS:
                return
            if stem in OUT_FRAMEWORKS:
                self.note('build', f'framework {stem} is not linked',
                          'QuickTime and QTKit are out of the port; remove their uses', file=name)
                return
            if sdk and not (sdk / 'System/Library/Frameworks' / name).is_dir():
                self.note('build', f'framework {stem} is not in the macOS SDK',
                          'QuickTime, QTKit and the like have no equivalent; a framework of the plugin\'s own is '
                          'a library it must bring', file=name)
                return
            if stem not in self.frameworks:
                self.frameworks.append(stem)
        elif re.search(r'\.(dylib|tbd|a)$', name):
            library = re.sub(r'^lib', '', stem)
            library = re.sub(r'\.\d.*$', '', library)
            if library in SYSTEM_LIBRARIES and name.endswith(('.dylib', '.tbd')):
                if library not in self.libraries:
                    self.libraries.append(library)
            elif library in ('stdc++', 'stdc++.6'):
                if 'c++' not in self.libraries:
                    self.libraries.append('c++')
                self.project_changes.append({'category': 'legacy-sdk/arch', 'setting': 'libstdc++',
                                             'before': name, 'after': 'libc++'})
            elif name not in self.unlinked:
                self.unlinked.append(name)

    # -- Info.plist

    def read_info_plist(self, name):
        if self.info_path is None:
            for candidate in [self.source / 'Info.plist', *sorted(self.source.glob('*Info.plist'))]:
                if candidate.is_file():
                    self.info_path = candidate
                    break
        info = read_info(self.info_path, self.notes) if self.info_path else {}
        if not self.info_path:
            self.note('build', 'the plugin has no Info.plist', 'the converter wrote one from the defaults')
        product = str(self.setting('PRODUCT_NAME', '') or '')
        product = '' if '$' in product else product
        self.module = module_name(name or product or str(info.get('CFBundleExecutable', '') or '').replace('$', '')
                                  or self.source.name)
        if '(' in str(info.get('CFBundleExecutable', '')) or '{' in str(info.get('CFBundleExecutable', '')):
            self.module = module_name(name or product or self.source.name)
        self.legacy_class = str(info.get('NSPrincipalClass', '') or '')
        self.plugin_type = str(info.get('pluginType', '') or '')
        if not self.legacy_class:
            self.note('build', 'Info.plist names no principal class',
                      'the kit takes the plugin\'s only subclass of PluginFilter', file='Info.plist')
        if not self.plugin_type:
            self.note('build', 'Info.plist has no pluginType', 'the commands go to the Plugins menu (other)',
                      file='Info.plist')
        for key, meaning in DROPPED_KEYS.items():
            if key in info and meaning:
                self.note('build', f'Info.plist key {key} has no equivalent', meaning, file='Info.plist')
        self.info = info

    def capabilities(self, texts, literal_texts=None):
        """`texts`: the sources with comments and strings blanked; `literal_texts`:
        with comments blanked only, for the keys set by key-value coding."""
        capabilities = list(BASE_CAPABILITIES)
        code = '\n'.join(texts)
        literal = '\n'.join(literal_texts) if literal_texts is not None else code
        if self.plugin_type.lower() == 'database' or DATABASE_USE.search(code):
            capabilities.append('database.read')
        if WRITE_USE.search(literal):
            capabilities.append('database.write')
        if IMPORT_USE.search(code):
            capabilities.append('database.import')
        if 'database.read' not in capabilities and DATABASE_NOTIFICATION_USE.search(literal):
            capabilities.append('database.read')
        if SEND_USE.search(code) or (NODES_USE.search(code) and not QUERY_USE.search(code)):
            capabilities.append('network.send')
        if QUERY_USE.search(code):
            capabilities.append('network.query')
        if XMLRPC_USE.search(literal):
            capabilities.append('xmlrpc')
        return capabilities

    @staticmethod
    def xmlrpc_methods(texts):
        """The XML-RPC methods a plugin answered through OsirixXMLRPCMessageNotification:
        the names its files that use the notification compare the method name with."""
        names = []
        for text in texts:
            if XMLRPC_USE.search(text):
                names += [name for name in XMLRPC_METHOD.findall(text) if name not in names]
        return names


_SDK = []


def macos_sdk():
    if not _SDK:
        import subprocess
        try:
            _SDK.append(Path(subprocess.run(['xcrun', '--show-sdk-path'], capture_output=True, text=True,
                                            check=True).stdout.strip()))
        except Exception:
            _SDK.append(None)
    return _SDK[0]


# ---------------------------------------------------------------- the project

def object_id(*parts):
    return hashlib.md5('\0'.join(map(str, parts)).encode()).hexdigest()[:24].upper()


def quoted(value):
    value = str(value)
    if re.fullmatch(r'[A-Za-z0-9_./]+', value) and not value.startswith('//'):
        return value
    return '"%s"' % value.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')


def openstep(value, indent=2):
    pad = '\t' * indent
    if isinstance(value, dict):
        lines = ['{']
        for key, item in value.items():
            lines.append('%s\t%s = %s;' % (pad, quoted(key), openstep(item, indent + 1)))
        lines.append(pad + '}')
        return '\n'.join(lines)
    if isinstance(value, list):
        if not value:
            return '(\n%s)' % pad
        return '(\n' + ''.join('%s\t%s,\n' % (pad, openstep(item, indent + 1)) for item in value) + pad + ')'
    return quoted(value)


FILE_TYPES = {'.m': 'sourcecode.c.objc', '.mm': 'sourcecode.cpp.objcpp', '.c': 'sourcecode.c.c',
              '.cpp': 'sourcecode.cpp.cpp', '.cc': 'sourcecode.cpp.cpp', '.cxx': 'sourcecode.cpp.cpp',
              '.swift': 'sourcecode.swift', '.h': 'sourcecode.c.h', '.hh': 'sourcecode.cpp.h', '.hpp': 'sourcecode.cpp.h',
              '.pch': 'sourcecode.c.h', '.xib': 'file.xib', '.nib': 'wrapper.nib', '.strings': 'text.plist.strings',
              '.plist': 'text.plist.xml', '.png': 'image.png', '.tif': 'image.tiff', '.tiff': 'image.tiff',
              '.jpg': 'image.jpeg', '.icns': 'image.icns', '.pdf': 'image.pdf', '.xcconfig': 'text.xcconfig',
              '.json': 'text.json', '.md': 'net.daringfireball.markdown', '.diff': 'text', '.txt': 'text'}


def pbxproj(module, sources, kit_sources, resources, browse, arc, kit=KIT_FOLDER):
    """The project.pbxproj of the converted plugin: one bundle target whose
    settings come from Config/<module>.xcconfig. `kit` is the kit's folder,
    relative to the project; one outside it (../IsiXLegacyBridge) is one group
    of the main group, named after the kit."""
    objects = {}
    groups = {}

    def group_for(folder):
        folder = str(folder)
        if folder in groups:
            return groups[folder]
        oid = object_id(module, 'group', folder)
        groups[folder] = oid
        if folder == kit and len(Path(kit).parts) > 1:
            objects[oid] = {'isa': 'PBXGroup', 'children': [], 'name': Path(kit).name, 'path': kit,
                            'sourceTree': '<group>'}
            objects[main]['children'].append(oid)
            return oid
        name = Path(folder).name
        objects[oid] = {'isa': 'PBXGroup', 'children': [], 'path': name, 'sourceTree': '<group>'}
        parent = str(Path(folder).parent)
        objects[group_for(parent) if parent != '.' else main]['children'].append(oid)
        return oid

    main = object_id(module, 'main group')
    objects[main] = {'isa': 'PBXGroup', 'children': [], 'sourceTree': '<group>'}
    file_refs = {}

    def file_ref(relative):
        relative = str(relative)
        if relative in file_refs:
            return file_refs[relative]
        oid = object_id(module, 'file', relative)
        path = Path(relative)
        entry = {'isa': 'PBXFileReference'}
        kind = 'folder' if path.suffix == '' and relative in folders else FILE_TYPES.get(path.suffix.lower())
        if kind:
            entry['lastKnownFileType'] = kind
        entry['path'] = path.name
        entry['sourceTree'] = '<group>'
        objects[oid] = entry
        objects[group_for(path.parent)]['children'].append(oid)
        file_refs[relative] = oid
        return oid

    folders = {r['path'] for r in resources if r.get('folder')}
    source_files, resource_files = [], []
    languages = {v: k for k, v in LANGUAGES.items()}
    for source in [*sources, *kit_sources]:
        oid = object_id(module, 'build', source['path'])
        objects[oid] = {'isa': 'PBXBuildFile', 'fileRef': file_ref(source['path'])}
        if source.get('language'):
            reference = objects[objects[oid]['fileRef']]
            reference.pop('lastKnownFileType', None)
            objects[objects[oid]['fileRef']] = {'isa': 'PBXFileReference',
                                                'explicitFileType': languages[source['language']],
                                                **{k: v for k, v in reference.items() if k != 'isa'}}
        flags = list(source.get('flags', []))
        objc = source.get('language', SUFFIX_LANGUAGES.get(Path(source['path']).suffix, '')).startswith('objective')
        if objc and source['arc'] != arc:
            flags.insert(0, '-fobjc-arc' if source['arc'] else '-fno-objc-arc')
        if flags:
            objects[oid]['settings'] = {'COMPILER_FLAGS': ' '.join(flags)}
        source_files.append(oid)
    variants = {}
    for resource in resources:
        path = Path(resource['path'])
        destination = Path(resource['destination'])
        if len(destination.parts) == 2 and destination.parts[0].endswith('.lproj'):
            key = (str(path.parent.parent), destination.name)
            if key not in variants:
                oid = object_id(module, 'variant', *key)
                objects[oid] = {'isa': 'PBXVariantGroup', 'children': [], 'name': destination.name,
                                'sourceTree': '<group>'}
                objects[group_for(path.parent.parent)]['children'].append(oid)
                variants[key] = oid
                build = object_id(module, 'build', 'variant', *key)
                objects[build] = {'isa': 'PBXBuildFile', 'fileRef': oid}
                resource_files.append(build)
            child = object_id(module, 'file', resource['path'])
            objects[child] = {'isa': 'PBXFileReference', 'name': destination.parts[0][:-len('.lproj')],
                              'path': f'{destination.parts[0]}/{path.name}', 'sourceTree': '<group>'}
            kind = FILE_TYPES.get(path.suffix.lower())
            if kind:
                objects[child]['lastKnownFileType'] = kind
            objects[variants[key]]['children'].append(child)
            file_refs[resource['path']] = child
        else:
            build = object_id(module, 'build', resource['path'])
            objects[build] = {'isa': 'PBXBuildFile', 'fileRef': file_ref(resource['path'])}
            resource_files.append(build)
    for relative in browse:
        if relative not in file_refs:
            file_ref(relative)

    product = object_id(module, 'product')
    objects[product] = {'isa': 'PBXFileReference', 'explicitFileType': 'wrapper.cfbundle', 'includeInIndex': '0',
                        'path': f'{module}.isixplugin', 'sourceTree': 'BUILT_PRODUCTS_DIR'}
    products = object_id(module, 'products group')
    objects[products] = {'isa': 'PBXGroup', 'children': [product], 'name': 'Products', 'sourceTree': '<group>'}
    objects[main]['children'].append(products)
    xcconfig = file_refs[f'Config/{module}.xcconfig']

    phases = {}
    for kind, files in (('PBXSourcesBuildPhase', source_files), ('PBXFrameworksBuildPhase', []),
                        ('PBXResourcesBuildPhase', resource_files)):
        oid = object_id(module, kind)
        objects[oid] = {'isa': kind, 'buildActionMask': '2147483647', 'files': files,
                        'runOnlyForDeploymentPostprocessing': '0'}
        phases[kind] = oid

    def configurations(owner, settings_by_name, base=None):
        ids = []
        for name in ('Debug', 'Release'):
            oid = object_id(module, owner, name)
            objects[oid] = {'isa': 'XCBuildConfiguration'}
            if base:
                objects[oid]['baseConfigurationReference'] = base
            objects[oid]['buildSettings'] = settings_by_name.get(name, {})
            objects[oid]['name'] = name
            ids.append(oid)
        oid = object_id(module, owner, 'list')
        objects[oid] = {'isa': 'XCConfigurationList', 'buildConfigurations': ids,
                        'defaultConfigurationIsVisible': '0', 'defaultConfigurationName': 'Release'}
        return oid

    target = object_id(module, 'target')
    objects[target] = {'isa': 'PBXNativeTarget', 'buildConfigurationList': configurations('target', {}, xcconfig),
                       'buildPhases': [phases['PBXSourcesBuildPhase'], phases['PBXFrameworksBuildPhase'],
                                       phases['PBXResourcesBuildPhase']],
                       'buildRules': [], 'dependencies': [], 'name': module, 'productName': module,
                       'productReference': product, 'productType': 'com.apple.product-type.bundle'}
    common = {'ALWAYS_SEARCH_USER_PATHS': 'NO', 'MACOSX_DEPLOYMENT_TARGET': MINIMUM_SYSTEM, 'SDKROOT': 'macosx'}
    regions = sorted({Path(r['destination']).parts[0][:-len('.lproj')] for r in resources
                      if Path(r['destination']).parts[0].endswith('.lproj')} | {'en', 'Base'})
    project = object_id(module, 'project')
    objects[project] = {'isa': 'PBXProject',
                        'attributes': {'BuildIndependentTargetsInParallel': '1', 'LastUpgradeCheck': '2700'},
                        'buildConfigurationList': configurations('project', {
                            'Debug': dict(common, ONLY_ACTIVE_ARCH='YES'),
                            'Release': dict(common)}),
                        'developmentRegion': 'en', 'hasScannedForEncodings': '0', 'knownRegions': regions,
                        'mainGroup': main, 'productRefGroup': products, 'projectDirPath': '', 'projectRoot': '',
                        'targets': [target]}
    body = ['// !$*UTF8*$!', '{', '\tarchiveVersion = 1;', '\tclasses = {', '\t};', '\tobjectVersion = 56;',
            '\tobjects = {', '']
    for isa in sorted({o['isa'] for o in objects.values()}):
        body.append('/* Begin %s section */' % isa)
        for oid in sorted(o for o in objects if objects[o]['isa'] == isa):
            body.append('\t\t%s = %s;' % (oid, openstep(objects[oid], 2)))
        body.append('/* End %s section */' % isa)
        body.append('')
    body += ['\t};', '\trootObject = %s;' % project, '}', '']
    return '\n'.join(body)


def xcconfig(module, plugin, header_folders, identifier, kit=KIT_FOLDER):
    lines = [
        '// Build settings of the ported plugin, written by tools/port-legacy-plugin.py.',
        '// Config/port.json says the same to tools/build-isix-legacy-plugin.py.',
        '',
        '#include "SDK.xcconfig"',
        '',
        f'PRODUCT_NAME = {module}',
        f'PRODUCT_MODULE_NAME = {module}',
        f'PRODUCT_BUNDLE_IDENTIFIER = {identifier}',
        'WRAPPER_EXTENSION = isixplugin',
        'MACH_O_TYPE = mh_bundle',
        'INFOPLIST_FILE = Config/Info.plist',
        'GENERATE_INFOPLIST_FILE = NO',
        'SKIP_INSTALL = YES',
        '',
        '// macOS 15; Release builds arm64 and x86_64 in one bundle, Debug this Mac\'s architecture.',
        f'MACOSX_DEPLOYMENT_TARGET = {MINIMUM_SYSTEM}',
        f'ARCHS = {" ".join(ARCHS)}',
        'ONLY_ACTIVE_ARCH[config=Debug] = YES',
        'ONLY_ACTIVE_ARCH[config=Release] = NO',
        '',
        '// The plugin\'s files keep the memory management the legacy project gave them',
        '// (per file in the Sources phase); the kit\'s Objective-C is compiled with ARC.',
        f'CLANG_ENABLE_OBJC_ARC = {"YES" if plugin.arc else "NO"}',
        'GCC_ENABLE_OBJC_EXCEPTIONS = YES',
        'CLANG_ENABLE_MODULES = NO',
        'CLANG_CXX_LANGUAGE_STANDARD = c++17',
        'CLANG_CXX_LIBRARY = libc++',
        '// Errors of current compilers that the legacy ones reported as warnings.',
        'WARNING_CFLAGS = $(inherited) ' + ' '.join(LEGACY_DIAGNOSTICS),
        '',
        '// The kit\'s headers come first, also under the folder names plugins imported the',
        '// former SDK from; the project\'s own header map would find old copies first.',
        f'HEADER_SEARCH_PATHS = $(inherited) "$(PROJECT_DIR)/{kit}/Headers" "$(PROJECT_DIR)/{kit}/Include"',
        'USER_HEADER_SEARCH_PATHS = $(inherited) ' + ' '.join(f'"$(PROJECT_DIR)/{f}"' for f in header_folders),
        'USE_HEADERMAP = NO',
        'ALWAYS_SEARCH_USER_PATHS = NO',
        'GCC_PREFIX_HEADER = Config/Prefix.pch',
        'GCC_PRECOMPILE_PREFIX_HEADER = NO',
        'GCC_PREPROCESSOR_DEFINITIONS = $(inherited) ISIX_LEGACY_NAMESPACE=$(PRODUCT_MODULE_NAME) '
        + ' '.join(quoted(d) for d in plugin.defines),
        '',
        '// The kit\'s Swift, compiled in the plugin\'s module.',
        'SWIFT_VERSION = 5.0',
        'SWIFT_OBJC_INTERFACE_HEADER_NAME = IsiXLegacyBridge-Swift.h',
        'SWIFT_OBJC_BRIDGING_HEADER =',
        '// The kit\'s Objective-C reaches its Swift, which is internal to the plugin.',
        'OTHER_SWIFT_FLAGS = $(inherited) -emit-clang-header-min-access internal',
        '',
        '// The plugin exports its Objective-C classes only, which the kit looks up in the plugin\'s',
        '// own image: a library it carries keeps its C++ templates and inline functions its own.',
        'EXPORTED_SYMBOLS_FILE = $(PROJECT_DIR)/Config/Exports.exp',
        'GCC_INLINES_ARE_PRIVATE_EXTERN = YES',
        '',
        '// IsiXPluginKit from the SDK folder, linked and never embedded: the application',
        '// provides it at run time. Everything else comes from the system.',
        'FRAMEWORK_SEARCH_PATHS = $(inherited) "$(ISIX_SDK_DIR)"',
        'OTHER_LDFLAGS = $(inherited) -framework IsiXPluginKit '
        + ' '.join(f'-framework {f}' for f in plugin.frameworks)
        + ''.join(f' -l{lib}' for lib in plugin.libraries),
        'LD_RUNPATH_SEARCH_PATHS =',
        '',
        '// Signed ad hoc for local use; sign with your Developer ID to distribute.',
        'CODE_SIGN_STYLE = Manual',
        'CODE_SIGN_IDENTITY = -',
        'DEVELOPMENT_TEAM =',
        'ENABLE_HARDENED_RUNTIME = NO',
        'ENABLE_USER_SCRIPT_SANDBOXING = NO',
        '',
    ]
    return '\n'.join(lines)


EXPORTS = '''# The symbols the ported plugin exports: its Objective-C classes only.
_OBJC_CLASS_$_*
_OBJC_METACLASS_$_*
'''

SDK_XCCONFIG = '''// Where the IsiXPluginKit SDK is: the folder that holds IsiXPluginKit.framework.
// The default is the SDK folder of this project. To use another one, put
//     ISIX_SDK_DIR = /path/to/folder
// in Config/SDK.local.xcconfig (not versioned), or pass ISIX_SDK_DIR=... to xcodebuild.
ISIX_SDK_DIR = $(PROJECT_DIR)/SDK

#include? "SDK.local.xcconfig"
'''


def unified_diff(before, after, old_name, new_name):
    if before == after:
        return ''
    return ''.join(difflib.unified_diff(normalized(before).splitlines(True), normalized(after).splitlines(True),
                                        f'original/{old_name}', new_name))


# ---------------------------------------------------------------- nibs

def kit_classes():
    """The legacy names the kit's classes take (@compatibility_alias DCMView IsiXLegacyDCMView)."""
    names = set()
    for header in (KIT / 'Headers').glob('*.h'):
        names.update(re.findall(r'^@compatibility_alias (\w+) IsiXLegacy\1;', header.read_text(), re.M))
    return sorted(names)


def runtime_class(module, name):
    """The name a kit class has in the runtime, in the plugin `module` (ISIX_LEGACY_CLASS)."""
    return f'IsiXLegacy{module}_{name}'


def rename_xib_classes(text, module):
    """A xib whose objects or views of a kit class (custom class DCMView...)
    name it by its runtime name, which a nib needs to make the plugin's own
    copy: by its legacy name the runtime would find none, or the
    application's. The text, and the changes as rewrites."""
    changes = []
    for name in kit_classes():
        new = runtime_class(module, name)
        for pattern, replacement in ((rf'customClass="{name}"', f'customClass="{new}"'),
                                     (rf'(<string key="NSClassName">){name}(</string>)', rf'\g<1>{new}\g<2>')):
            for match in list(re.finditer(pattern, text)):
                changes.append({'rule': 'nib-kit-class', 'category': 'nib', 'line': text.count('\n', 0, match.start()) + 1,
                                'before': name, 'after': new})
            text = re.sub(pattern, replacement, text)
    return text, changes


def rename_nib_classes(nib, module):
    """The same in a compiled nib folder's keyed archives (keyedobjects*.nib):
    the strings an archived object names its class by (NSClassName). How many."""
    count = 0
    names = set(kit_classes())
    for archive in sorted(Path(nib).glob('keyedobjects*.nib')):
        try:
            data = plistlib.loads(archive.read_bytes())
        except Exception:  # not a keyed archive: left as it is
            continue
        objects = data.get('$objects', [])
        changed = 0
        for item in objects:
            if isinstance(item, dict) and isinstance(item.get('NSClassName'), plistlib.UID):
                index = item['NSClassName'].data
                if 0 <= index < len(objects) and objects[index] in names:
                    objects[index] = runtime_class(module, objects[index])
                    changed += 1
        if changed:
            archive.write_bytes(plistlib.dumps(data, fmt=plistlib.FMT_BINARY))
        count += changed
    return count


def shared_kit_folder(path):
    """`path` (--shared-kit) as the kit's folder in the project: relative, in POSIX form."""
    text = str(path).replace('\\', '/').rstrip('/')
    if not text or text.startswith('/') or Path(text).is_absolute() or Path(text).name in ('', '.', '..'):
        raise ValueError(f'--shared-kit takes the kit\'s folder relative to the project, such as ../IsiXLegacyBridge: {path}')
    return str(Path(text).as_posix())


def convert(source, output=None, name=None, arc=None, frameworks=(), exclude=(), sdk=None, shared_kit=None):
    """Convert the legacy plugin at `source`. With `output`, write the project
    to <output>/<module> and return its report with 'project' set; without it,
    only return the report. With `shared_kit`, the kit's folder relative to
    the project, the project uses that copy of the kit instead of its own."""
    kit_folder = shared_kit_folder(shared_kit) if shared_kit else KIT_FOLDER
    plugin = Plugin(source, name, arc, frameworks, exclude)
    module = plugin.module
    rewrites, leftovers, texts, contents, originals = [], [], [], {}, {}
    literal_texts = []
    diff = []
    for relative, path in sorted(plugin.files.items()):
        suffix = Path(relative).suffix.lower()
        if path.is_dir() or suffix not in REWRITTEN | {'.xib'} or in_library(relative):
            continue
        raw = path.read_bytes()
        text, encoding = decode(raw)
        if suffix == '.xib':
            new, changes = rewrite_xib(text)
            new, renames = rename_xib_classes(new, module)
            changes = changes + renames
            left = []
        else:
            arc_of_file = next((s['arc'] for s in plugin.sources if s['path'] == relative), plugin.arc)
            try:
                new, changes, left = rewrite_source(text, arc_of_file)
            except Exception as error:  # never stop the conversion on one file
                new, changes, left = text, [], [{'category': 'build', 'line': None, 'text': f'not rewritten: {error}',
                                                 'hint': 'rewrite this file by hand'}]
            texts.append(masks(new)[1])
            literal_texts.append(masks(new)[0])
        for change in changes:
            rewrites.append(dict(change, file=f'Sources/{relative}'))
        for item in left:
            leftovers.append(dict(item, file=f'Sources/{relative}'))
        if new != text:
            contents[relative] = new.encode(encoding)
            originals[relative] = raw
            diff.append(unified_diff(text, new, relative, f'Sources/{relative}'))
    capabilities = plugin.capabilities(texts, literal_texts)
    info = ported_info(plugin.info, module, plugin.legacy_class, capabilities)
    xmlrpc_methods = plugin.xmlrpc_methods(literal_texts)
    if xmlrpc_methods:
        info['IsiXLegacyXMLRPCMethods'] = xmlrpc_methods
    info_xml = plistlib.dumps(info).decode()
    if plugin.info_path is not None:
        original_info = plugin.info_path.read_bytes()
        try:
            original_text = plistlib.dumps(plistlib.loads(original_info)).decode()
        except Exception:
            original_text = decode(original_info)[0]
        diff.insert(0, unified_diff(original_text, info_xml, 'Info.plist', 'Config/Info.plist'))
    header_folders = sorted({str(Path('Sources') / Path(r).parent) for r in plugin.files
                             if Path(r).suffix.lower() in HEADERS and not in_library(r)} | {'Sources'})
    report = {
        'format': REPORT_FORMAT,
        'plugin': plugin.source.name,
        'module': module,
        'legacyProject': str(plugin.legacy.path.parent.relative_to(plugin.source)) if plugin.legacy else None,
        'legacyTarget': plugin.target['name'] if plugin.target else None,
        'legacyClass': plugin.legacy_class,
        'pluginType': plugin.plugin_type,
        'menuTitles': [str(t) for t in plugin.info.get('MenuTitles', [])] if isinstance(plugin.info.get('MenuTitles'), list)
        else [],
        'capabilities': capabilities,
        'memoryManagement': {'default': 'ARC' if plugin.arc else 'MRC',
                             'ARC': sorted(s['path'] for s in plugin.sources if s['arc']),
                             'MRC': sorted(s['path'] for s in plugin.sources if not s['arc'])},
        'sources': len(plugin.sources),
        'resources': len(plugin.resources),
        'rewrites': sorted(rewrites, key=lambda r: (r['file'], r['line'])),
        'projectChanges': plugin.project_changes,
        'unconverted': sorted(leftovers, key=lambda r: (r['file'], r['line'] or 0)) + plugin.notes,
        'changedFiles': sorted(f'Sources/{r}' for r in contents),
    }
    report['summary'] = summary_of(report)
    if output is None:
        return report

    project = Path(output) / module
    if project.exists():
        shutil.rmtree(project)
    (project / 'Config').mkdir(parents=True)
    sources_dir = project / 'Sources'
    for relative, path in sorted(plugin.files.items()):
        destination = sources_dir / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        if path.is_dir():
            shutil.copytree(path, destination, symlinks=True, dirs_exist_ok=True)
            if path.suffix == '.nib':
                count = rename_nib_classes(destination, module)
                if count:
                    report['rewrites'].append({'rule': 'nib-kit-class', 'category': 'nib', 'line': 0,
                                               'before': 'legacy class names', 'after': f'{count} runtime names',
                                               'file': f'Sources/{relative}'})
        elif relative in contents:
            destination.write_bytes(contents[relative])
        else:
            shutil.copy2(path, destination)
    if not shared_kit:
        kit = project / KIT_FOLDER
        for part in ('Headers', 'Include', 'Sources'):
            shutil.copytree(KIT / part, kit / part, symlinks=True)
        shutil.copy2(KIT / 'README.md', kit / 'README.md')
    kit_sources = [{'path': f'{kit_folder}/Sources/{p.name}', 'arc': True, 'flags': []}
                   for p in sorted((KIT / 'Sources').iterdir()) if p.suffix in ('.m', '.swift')]
    porting = project / 'Porting'
    porting.mkdir()
    for relative, raw in originals.items():
        destination = porting / 'original' / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(raw)
    if plugin.info_path is not None:
        (porting / 'original').mkdir(parents=True, exist_ok=True)
        shutil.copy2(plugin.info_path, porting / 'original' / 'Info.plist')
    (porting / 'rewrites.diff').write_text(''.join(diff))
    (project / 'Config' / 'Info.plist').write_text(info_xml)
    prefix = ['// The prefix header of the ported plugin, written by tools/port-legacy-plugin.py:',
              '// the porting kit\'s, then the plugin\'s own.', '#include "IsiXLegacyPrefix.h"']
    if plugin.prefix:
        prefix.append(f'#include "../Sources/{plugin.prefix}"')
    (project / 'Config' / 'Prefix.pch').write_text('\n'.join(prefix) + '\n')
    (project / 'Config' / f'{module}.xcconfig').write_text(xcconfig(module, plugin, header_folders, info['CFBundleIdentifier'],
                                                                     kit_folder))
    (project / 'Config' / 'SDK.xcconfig').write_text(SDK_XCCONFIG)
    (project / 'Config' / 'Exports.exp').write_text(EXPORTS)
    if sdk:
        (project / 'Config' / 'SDK.local.xcconfig').write_text(f'ISIX_SDK_DIR = {Path(sdk).resolve()}\n')
    (project / '.gitignore').write_text('build/\nDerivedData/\nxcuserdata/\nConfig/SDK.local.xcconfig\nSDK/\n')
    manifest = {
        'format': 1,
        'module': module,
        'arc': plugin.arc,
        'sources': [dict(s, path=f'Sources/{s["path"]}') for s in plugin.sources] + kit_sources,
        'resources': [dict(r, path=f'Sources/{r["path"]}') for r in plugin.resources],
        'headerFolders': header_folders,
        'defines': plugin.defines,
        'diagnostics': LEGACY_DIAGNOSTICS,
        'frameworks': plugin.frameworks,
        'libraries': plugin.libraries,
        'prefixHeader': 'Config/Prefix.pch',
        'infoPlist': 'Config/Info.plist',
        'exportedSymbols': 'Config/Exports.exp',
        'archs': ARCHS,
        'minimumSystem': MINIMUM_SYSTEM,
    }
    if shared_kit:
        manifest['kit'] = kit_folder
    (project / 'Config' / 'port.json').write_text(json.dumps(manifest, indent=1) + '\n')
    report['summary'] = summary_of(report)  # with the compiled nibs' renamed classes
    (porting / 'report.json').write_text(json.dumps(report, indent=1, ensure_ascii=False) + '\n')
    (porting / 'REPORT.md').write_text(report_markdown(report, kit_folder))
    browse = sorted({*(f'Sources/{r}' for r in plugin.files if Path(r).suffix.lower() in HEADERS
                       and not in_library(r)),
                     'Config/Info.plist', 'Config/Prefix.pch', f'Config/{module}.xcconfig', 'Config/SDK.xcconfig',
                     'Config/port.json', 'Config/Exports.exp', 'Porting/REPORT.md', 'Porting/rewrites.diff',
                     *(f'{kit_folder}/Headers/{p.name}' for p in sorted((KIT / 'Headers').iterdir())
                       if p.suffix == '.h'),
                     *(f'{kit_folder}/Sources/{p.name}' for p in sorted((KIT / 'Sources').iterdir())
                       if p.suffix == '.h')})
    xcodeproj = project / f'{module}.xcodeproj'
    xcodeproj.mkdir()
    (xcodeproj / 'project.pbxproj').write_text(
        pbxproj(module, [dict(s, path=f'Sources/{s["path"]}') for s in plugin.sources], kit_sources,
                [dict(r, path=f'Sources/{r["path"]}') for r in plugin.resources], browse, plugin.arc, kit_folder))
    report['project'] = str(project)
    return report


def summary_of(report):
    by_category = {}
    for rewrite in report['rewrites']:
        by_category[rewrite['category']] = by_category.get(rewrite['category'], 0) + 1
    left = {}
    for item in report['unconverted']:
        left[item['category']] = left.get(item['category'], 0) + 1
    return {'rewrites': by_category, 'unconverted': left,
            'projectChanges': sorted({c['category'] for c in report['projectChanges']})}


def report_markdown(report, kit=KIT_FOLDER):
    out = [f'# Porting report: {report["plugin"]}', '',
           'Written by tools/port-legacy-plugin.py. Porting/rewrites.diff shows every change; '
           'Porting/original/ keeps each changed file as it was.', '',
           f'- Module: `{report["module"]}`; legacy class `{report["legacyClass"] or "—"}`, type '
           f'`{report["pluginType"] or "—"}`, menu titles: {", ".join(report["menuTitles"]) or "—"}',
           f'- Legacy project: {report["legacyProject"] or "none (files taken from the folder)"}, target '
           f'{report["legacyTarget"] or "—"}',
           f'- Capabilities: {", ".join(report["capabilities"])}',
           f'- Memory management: {report["memoryManagement"]["default"]} by default; '
           f'{len(report["memoryManagement"]["ARC"])} file(s) with ARC, {len(report["memoryManagement"]["MRC"])} '
           'with manual reference counting',
           f'- {report["sources"]} source file(s), {report["resources"]} resource(s)', '']
    out += ['## Rewrites', '']
    if report['rewrites']:
        out += ['| File | Line | Rule | Before | After |', '| --- | --- | --- | --- | --- |']
        for r in report['rewrites']:
            out.append('| %s | %d | %s | `%s` | `%s` |' % (r['file'], r['line'], r['rule'],
                                                           r['before'].replace('|', '\\|')[:100],
                                                           r['after'].replace('|', '\\|')[:100]))
    else:
        out.append('None.')
    out += ['', '## Project settings replaced', '']
    if report['projectChanges']:
        out += ['| Setting | Legacy | Now |', '| --- | --- | --- |']
        for c in report['projectChanges']:
            out.append('| %s | %s | %s |' % (c['setting'], c['before'].replace('|', '\\|'), c['after']))
    else:
        out.append('None.')
    out += ['', '## Without an automatic equivalent', '']
    if report['unconverted']:
        for item in report['unconverted']:
            where = item['file'] or ''
            if item.get('line'):
                where += f':{item["line"]}'
            out.append(f'- {item["category"]}, {where or "project"}: `{item["text"]}`'
                       + (f' — {item["hint"]}' if item.get('hint') else ''))
    else:
        out.append('Nothing.')
    out += ['', f'The compiler reports what the porting kit does not declare: see {kit}/README.md.', '']
    return '\n'.join(out)


# ---------------------------------------------------------------- collection

def convert_collection(collection, output=None):
    """Every plugin folder of a collection such as horosplugins: one report."""
    collection = Path(collection)
    plugins = {}
    for name, path, kind in inv.collection_entries(collection):
        if kind == 'no-sources':
            continue
        target = Path(output) / re.sub(r'[^\w.-]+', '_', name) if output else None
        try:
            report = convert(path, target)
            report.pop('project', None)
            plugins[name] = report
        except Exception as error:
            plugins[name] = {'plugin': name, 'error': f'{type(error).__name__}: {error}',
                             'traceback': traceback.format_exc()[-2000:]}
    git = inv.git_info(collection) or {}
    return {'format': REPORT_FORMAT, 'collection': collection.name, 'revision': git.get('revision'),
            'converter': 'tools/port-legacy-plugin.py', 'plugins': plugins,
            'errors': sorted(n for n, r in plugins.items() if 'error' in r)}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    what = parser.add_mutually_exclusive_group(required=True)
    what.add_argument('--source', type=Path, help='folder of the legacy plugin')
    what.add_argument('--collection', type=Path, help='folder of legacy plugin folders, such as horosplugins')
    parser.add_argument('--output', type=Path, help='folder for the project(s)')
    parser.add_argument('--report', type=Path, help='write the report (JSON) here')
    parser.add_argument('--name', help="the plugin's module name (default: its product name)")
    parser.add_argument('--sdk', type=Path, help='the IsiXPluginKit SDK folder, written to Config/SDK.local.xcconfig')
    memory = parser.add_mutually_exclusive_group()
    memory.add_argument('--arc', dest='arc', action='store_true', default=None,
                        help='files without their own setting use ARC')
    memory.add_argument('--mrc', dest='arc', action='store_false',
                        help='files without their own setting use manual reference counting')
    parser.add_argument('--framework', action='append', default=[])
    parser.add_argument('--exclude', action='append', default=[], help='a file name to leave out of the build')
    parser.add_argument('--shared-kit', metavar='RELATIVE_PATH',
                        help='use the kit at this path, relative to the project (../IsiXLegacyBridge), instead of a copy')
    arguments = parser.parse_args(argv)
    if arguments.shared_kit:
        if arguments.collection:
            parser.error('--shared-kit goes with --source')
        try:
            shared_kit_folder(arguments.shared_kit)
        except ValueError as error:
            parser.error(str(error))
    if arguments.collection:
        if not arguments.collection.is_dir():
            print(f'SKIP: {arguments.collection} is not a folder', file=sys.stderr)
            return 2
        if not arguments.report and not arguments.output:
            parser.error('--collection needs --report or --output')
        report = convert_collection(arguments.collection, arguments.output)
        if arguments.report:
            arguments.report.write_text(json.dumps(report, indent=1, ensure_ascii=False) + '\n')
        converted = len(report['plugins']) - len(report['errors'])
        print(f'{converted} of {len(report["plugins"])} plugins converted'
              + (f'; failed: {", ".join(report["errors"])}' if report['errors'] else ''))
        return 1 if report['errors'] else 0
    if not arguments.source.is_dir():
        parser.error(f'{arguments.source} is not a folder')
    if not arguments.output:
        parser.error('--source needs --output')
    report = convert(arguments.source, arguments.output, arguments.name, arguments.arc, arguments.framework,
                     arguments.exclude, arguments.sdk, arguments.shared_kit)
    if arguments.report:
        arguments.report.write_text(json.dumps(report, indent=1, ensure_ascii=False) + '\n')
    print(report['project'])
    return 0


if __name__ == '__main__':
    sys.exit(main())
