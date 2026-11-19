#!/usr/bin/env python3
"""The table of the instance variables of the former plugin SDK that classes
written in Swift export: its text, what its entries must be, and its
completion from a build.

Horos/Scripts/Horos/legacy-plugin-ivars.json names, for each instance variable
of the former Horos and OsiriX plugin SDK kept by a Swift class, the type the
SDK declared (sdk), the Swift stored field (field), the symbol of that field's
offset (symbol), its state and its ownership; the file's own "about" says what
each is. The linker response file of the application target is the rendering of
that table. tests/test-legacy-plugin-instance-variables.py and
tests/test-legacy-plugin-abi.py read the table through this module.

The type of a field is the one the C declaration has in memory. An entry's
sdk corresponds to the type Swift gives in the name of the offset symbol
(xcrun swift-demangle: "direct field offset for Horos.DCMView.horos_curImage :
Swift.Int16"):

- short Int16, int Int32, long and NSInteger Int, unsigned long and NSUInteger
  UInt, GLuint UInt32, char Int8 (CChar), unsigned char UInt8, float Float,
  double and NSTimeInterval Double, CGFloat CGFloat, BOOL Bool, and the other
  integer types by their width; a typedef of one of them, and an enumeration
  or the boolean of a C++ library (DCMTK's OFBool, E_TransferSyntax), which
  Swift does not import: the number of the same size;
- NSPoint, NSSize, NSRect, a C struct and a C enum: the imported type of that
  name;
- T * for a C type: UnsafeMutablePointer<T>?, optional, as deep as the stars;
  void *: UnsafeMutableRawPointer?, and so are a typedef of it in the
  system's headers (vImage's GammaFunction) and a smart pointer of a C++
  library, which is one pointer (ITK's ImportFilterType::Pointer);
- a reference to a Core Foundation object (CFRunLoopRef): the class Swift
  imports it as, optional (CFRunLoop?), with the ownership of an object;
- X * for a class: X?, always optional, since a plugin may store nil (X! is
  the same type, and so is X<A, B>? of a generic class); id: AnyObject?; an object pointer whose state is inert, of a
  class that may be gone: AnyObject? as well; one whose ownership is manual:
  also the ManuallyRetained<X> struct, declared as a field of its own;
- T name[N] and T name[N][M], written "T[N]" and "T[N][M]": a C struct of one
  member, "typedef struct { T v[N]; } Name;", declared in
  Horos/Sources/LegacyPluginIvarStorage.h, with the same element type and the
  same dimensions. MAX4D is 500.

Never String, Array, Dictionary, a Swift struct, an optional scalar, a
non-optional object. ownership is value for what is not an object and one of
strong, unowned or manual for an object or an array of objects.

    python3 tools/legacy_plugin_ivars.py complete --objects BUILD_OBJECTS FRAGMENT [FRAGMENT ...]

complete writes the table from a build. A fragment is a JSON object
{"Class.ivar": {"sdk", "field", "state", "ownership"}}, without the symbol.
The entries of the table come first, in the order they have, then the new ones
of the fragments, by class in the order the classes first appear and inside a
class in the order of the fragment; an entry the table already has takes the
fragment's values where it is. The symbol of every entry, those the table had
included, is the one the objects have for the field: nm over the object files
(--objects: a folder of .o files, such as
build/Build/Intermediates.noindex/Horos.build/Debug/Horos.build/Objects-normal/arm64,
object files, or a linked executable that keeps its symbol table), demangled.
Nothing is written, and every entry at fault is listed, when a field is not
found, is private (its symbol is local to its object file), has a type that
does not correspond to sdk, or when two entries name one field. Afterwards
python3 tests/test-legacy-plugin-instance-variables.py --write-aliases writes
the response file.

A class of the SDK that an internal module declares (MODULE_CLASSES) has its
fields in that module's objects, not in the application's: give them as one
more --objects (build/Build/Products/Debug/IsiXImaging.o).
"""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TABLE = ROOT / 'Horos/Scripts/Horos/legacy-plugin-ivars.json'
ALIASES = ROOT / 'Horos/Scripts/Horos/legacy-plugin-ivar-aliases.rsp'
STORAGE = ROOT / 'Horos/Sources/LegacyPluginIvarStorage.h'
ENTRY_FIELDS = ('sdk', 'field', 'symbol', 'state', 'ownership')
FRAGMENT_FIELDS = ('sdk', 'field', 'state', 'ownership')
STATES = ('live', 'derived', 'inert')
OWNERSHIPS = ('value', 'strong', 'unowned', 'manual')
PREFIX = '_OBJC_IVAR_$_'
MODULE = 'Horos'

# The C types of the SDK's declarations that are numbers, and what Swift calls
# the type of the same size (the demangled name is of the canonical type: CChar
# is Swift.Int8, TimeInterval Swift.Double).
SCALARS = {
    'short': ('Swift.Int16',), 'unsigned short': ('Swift.UInt16',),
    'int': ('Swift.Int32',), 'unsigned int': ('Swift.UInt32',), 'unsigned': ('Swift.UInt32',),
    'long': ('Swift.Int',), 'NSInteger': ('Swift.Int',), 'unsigned long': ('Swift.UInt',), 'NSUInteger': ('Swift.UInt',),
    'long long': ('Swift.Int64',), 'unsigned long long': ('Swift.UInt64',),
    'GLuint': ('Swift.UInt32',), 'GLint': ('Swift.Int32',), 'GLenum': ('Swift.UInt32',), 'GLsizei': ('Swift.Int32',),
    'GLubyte': ('Swift.UInt8',), 'GLfloat': ('Swift.Float',),
    'char': ('Swift.Int8',), 'signed char': ('Swift.Int8',), 'unsigned char': ('Swift.UInt8',),
    'float': ('Swift.Float',), 'double': ('Swift.Double',), 'NSTimeInterval': ('Swift.Double',),
    # The module that declares CGFloat changed between SDKs of the system.
    'CGFloat': ('CoreGraphics.CGFloat', 'CoreFoundation.CGFloat'),
    'BOOL': ('Swift.Bool',),
    # Typedefs of a number in the system's headers, which Swift names by what
    # they are.
    'CFSocketNativeHandle': ('Swift.Int32',), 'NSStringEncoding': ('Swift.UInt',),
    # The boolean and the enumerations of DCMTK's C++ headers in the SDK's
    # declarations, which Swift does not import: a byte, and the size of an int.
    'OFBool': ('Swift.Bool',), 'E_TransferSyntax': ('Swift.Int32',), 'T_DIMSE_BlockingMode': ('Swift.Int32',),
    'DVPSFilmOrientation': ('Swift.Int32',), 'DVPSTrimMode': ('Swift.Int32',), 'DVPSDecimateCropBehaviour': ('Swift.Int32',),
}
# The references to Core Foundation objects in the SDK's declarations. Swift
# imports each as a class, and the demangled name keeps the C one.
CF_REFERENCES = ('CFSocketRef', 'CFReadStreamRef', 'CFWriteStreamRef', 'CFRunLoopSourceRef', 'CFRunLoopRef', 'CFHTTPMessageRef')
# The smart pointers of C++ libraries in the SDK's declarations, each one
# pointer in memory, which Swift cannot name.
# OFCondition, in the DCMTK the SDK was built with, has one member, the pointer
# to its condition.
CXX_POINTERS = ('ImportFilterType::Pointer', 'OFCondition')
# The typedefs of an untyped pointer in the system's headers (vImage's
# GammaFunction is void *, and the Component Manager's ComponentInstance,
# which the system no longer declares, was a pointer to a record).
POINTER_TYPEDEFS = ('GammaFunction', 'ComponentInstance')
# The classes of the SDK that an internal module declares under another name
# in Swift: the owner of their fields in a symbol, and the class's name.
MODULE_CLASSES = {'IsiXImaging.USRegion': 'DCMUSRegion',
                  'IsiXDICOMFile.DICOMSOPClass': 'DCMAbstractSyntaxUID', 'IsiXDICOMFile.DICOMAttributeTag': 'DCMAttributeTag',
                  'IsiXDICOMFile.DICOMCalendarDate': 'DCMCalendarDate', 'IsiXDICOMFile.DICOMCharacterSet': 'DCMCharacterSet',
                  'IsiXDICOMDataset.DCMAttribute': 'DCMAttribute', 'IsiXDICOMDataset.DCMObject': 'DCMObject',
                  'IsiXDICOMDataset.DCMPixelDataAttribute': 'DCMPixelDataAttribute',
                  'IsiXDICOMDataset.DCMSequenceAttribute': 'DCMSequenceAttribute',
                  'IsiXDICOMDataset.DCMTransferSyntax': 'DCMTransferSyntax'}
# The classes of the SDK that Swift declares under another name, exposed to
# Objective-C with the SDK's: the name a field's type has in a symbol.
SWIFT_NAMES = {'DCMAttributeTag': 'DICOMAttributeTag', 'DCMCharacterSet': 'DICOMCharacterSet',
               'DCMCalendarDate': 'DICOMCalendarDate', 'HorosRetrievePlan': 'RetrievePlan', 'HorosStoreReport': 'StoreReport'}
# The C structs the SDK's headers name through an AppKit alias.
VALUES = {'NSPoint': '__C.CGPoint', 'CGPoint': '__C.CGPoint', 'NSSize': '__C.CGSize', 'CGSize': '__C.CGSize',
          'NSRect': '__C.CGRect', 'CGRect': '__C.CGRect', 'NSRange': '__C._NSRange',
          # A typedef of CATransform3D, which Swift names, and two pointers to
          # a struct the headers leave incomplete.
          'N3AffineTransform': '__C.CATransform3D', 'N3MutableBezierCoreRef': 'Swift.OpaquePointer?',
          'N3BezierCoreRandomAccessorRef': 'Swift.OpaquePointer?'}
# The dimensions the SDK's headers write as a macro.
ARRAY_SIZES = {'MAX4D': 500}
QUALIFIERS = re.compile(r'\b(?:IBOutlet|__unsafe_unretained|__strong|__weak|_Nullable|_Nonnull|_Null_unspecified|'
                        r'__nullable|__nonnull|__kindof|volatile)\b')
QUALIFIED = r'(?:[A-Za-z_]\w*|\(extension in [A-Za-z_]\w*\):__C)\.'
OFFSET = re.compile(r'direct field offset for (?P<owner>\S.*?)\.(?P<open>\(?)(?P<field>[A-Za-z_]\w*)'
                    r'(?P<private> in _[0-9A-F]+\))? : (?P<type>.+)')
STRUCT = re.compile(r'typedef\s+struct\s*\{\s*([^;{}]+?)\bv\s*((?:\[\s*\w+\s*\]\s*)+);\s*\}\s*([A-Za-z_]\w*)\s*;')


class TableError(Exception):
    """A table, a fragment or a build that cannot be read."""


def run(command, **options):
    return subprocess.run(command, capture_output=True, text=True, **options)


def relative(path):
    path = Path(path)
    return str(path.relative_to(ROOT)) if path.is_absolute() and ROOT in path.parents else str(path)


def render_aliases(ivars):
    """The linker response file of a table: per entry, in its order, the alias and the line that keeps it."""
    return ''.join(f'-alias {entry["symbol"]} {PREFIX}{name}\n-u {PREFIX}{name}\n' for name, entry in ivars.items())


def render_table(table):
    """The table's text: the paragraphs of about, then one entry per line, its fields in the order of ENTRY_FIELDS."""
    lines = ['{', ' "about": [']
    lines += [f'  {json.dumps(paragraph, ensure_ascii=False)}' + (',' if i < len(table['about']) - 1 else '')
              for i, paragraph in enumerate(table['about'])]
    lines += [' ],', ' "ivars": {']
    names = list(table['ivars'])
    for i, name in enumerate(names):
        entry = table['ivars'][name]
        fields = ', '.join(f'{json.dumps(key)}: {json.dumps(entry[key], ensure_ascii=False)}' for key in ENTRY_FIELDS)
        lines.append(f'  {json.dumps(name)}: {{{fields}}}' + (',' if i < len(names) - 1 else ''))
    lines += [' }', '}']
    return '\n'.join(lines) + '\n'


def read_json(path):
    """A JSON object of the table's kind, in the order of the file, refusing a name written twice."""
    def without_duplicates(pairs):
        names = [name for name, _ in pairs]
        twice = sorted({name for name in names if names.count(name) > 1})
        if twice:
            raise TableError(f'{relative(path)} has {twice[0]!r} more than once')
        return dict(pairs)
    try:
        return json.loads(Path(path).read_text(encoding='utf-8'), object_pairs_hook=without_duplicates)
    except (OSError, ValueError) as error:
        raise TableError(f'{relative(path)} is not read: {error}') from error


def read_table(path=TABLE):
    table = read_json(path)
    ivars = table.get('ivars') if isinstance(table, dict) else None
    about = table.get('about') if isinstance(table, dict) else None
    if not isinstance(ivars, dict) or not ivars or not isinstance(about, list) or not about or set(table) != {'about', 'ivars'}:
        raise TableError(f'{relative(path)} does not have "about", a list of paragraphs, and "ivars", and nothing else')
    return table


def storage_structs(text):
    """{struct: (element type, dimensions)} of the C structs of one array member that a header declares."""
    found = {}
    for element, dimensions, name in STRUCT.findall(re.sub(r'//[^\n]*|/\*.*?\*/', ' ', text, flags=re.S)):
        try:
            base, pointers, sizes = c_type(element + dimensions)
        except TableError:
            continue
        found[name] = (base, pointers, sizes)
    return found


def c_type(text):
    """A C type as the table writes it, taken apart: the name of what it is made of, the stars, the dimensions.

    'unsigned char[256]' is ('unsigned char', 0, (256,)), 'NSMutableArray<DCMPix *> *[MAX4D]' ('NSMutableArray', 1, (500,))."""
    text = QUALIFIERS.sub(' ', text)
    sizes = []
    arrays = re.search(r'((?:\[\s*\w+\s*\]\s*)+)$', text)
    if arrays:
        for size in re.findall(r'\[\s*(\w+)\s*\]', arrays.group(1)):
            if not size.isdigit() and size not in ARRAY_SIZES:
                raise TableError(f'the dimension {size} of {text.strip()!r} is not a number')
            sizes.append(int(size) if size.isdigit() else ARRAY_SIZES[size])
        text = text[:arrays.start()]
    # The parameters of a generic class and the protocols of an id say nothing of the size.
    while '<' in text:
        narrowed = re.sub(r'<[^<>]*>', ' ', text)
        if narrowed == text:
            break
        text = narrowed
    text = re.sub(r'\b(?:const|struct|enum)\b', ' ', text)
    pointers = text.count('*')
    base = ' '.join(text.replace('*', ' ').split())
    if not base or not re.fullmatch(r'[A-Za-z_]\w*(?: [A-Za-z_]\w*)*', base):
        raise TableError(f'{text.strip()!r} is not a C type')
    return base, pointers, tuple(sizes)


def type_problem(entry, swift, structs):
    """Why the Swift type of the entry's field does not correspond to its sdk, or None when it does."""
    sdk, state, ownership = entry['sdk'], entry['state'], entry['ownership']
    if sdk in CXX_POINTERS:
        if swift != 'Swift.UnsafeMutableRawPointer?':
            return f'the SDK\'s {sdk} is one pointer, Swift.UnsafeMutableRawPointer? in memory, and the field is {swift}'
        return None if ownership == 'value' else f'the SDK\'s {sdk} is not an object: its ownership is value, not {ownership}'
    try:
        base, pointers, sizes = c_type(sdk)
    except TableError as error:
        return str(error)
    is_object = base not in SCALARS and base != 'void' and base not in VALUES and base not in POINTER_TYPEDEFS and (
        pointers == 1 or base in ('id', 'Class') or (pointers == 0 and base in CF_REFERENCES))
    if sizes:
        name = swift.rsplit('.', 1)[-1]
        if not re.fullmatch(QUALIFIED + r'[A-Za-z_]\w*', swift) or name not in structs:
            return (f'the SDK\'s {sdk} is an array inside the object, kept as a C struct of one member that '
                    f'{relative(STORAGE)} declares, and the field is {swift}')
        # An array of object pointers is kept as untyped pointers of the same
        # number and size: Swift imports an array of unretained object
        # pointers as strong references, and would release what a slot holds.
        held = ('void', 1, sizes) if is_object else (base, pointers, sizes)
        if structs[name] not in ((base, pointers, sizes), held):
            element, stars, dimensions = structs[name]
            return (f'the SDK\'s {sdk} is not what the struct {name} holds, '
                    f'{element}{" " + "*" * stars if stars else ""}{"".join(f"[{size}]" for size in dimensions)}')
        expected = None
    elif pointers == 0 and base in SCALARS:
        expected = SCALARS[base]
    elif pointers == 0 and base in VALUES:
        expected = (VALUES[base],)
    elif pointers == 1 and base in VALUES:
        expected = tuple(f'{pointer}<{VALUES[base]}>?' for pointer in ('Swift.UnsafeMutablePointer', 'Swift.UnsafePointer'))
    elif pointers == 0 and base in POINTER_TYPEDEFS:
        expected = ('Swift.UnsafeMutableRawPointer?', 'Swift.UnsafeRawPointer?')
    elif base == 'id':
        expected = ('Swift.AnyObject?',) if pointers == 0 else ()
    elif base == 'Class':
        expected = ('Swift.AnyObject.Type?',) if pointers == 0 else ()
    elif base == 'SEL':
        expected = ('ObjectiveC.Selector?',) if pointers == 0 else ()
    elif pointers == 0 and base in CF_REFERENCES:
        expected = (f'__C.{base}?',)
    elif pointers == 0:
        # A C struct or a C enum, by its name, in whatever module Swift finds it.
        expected = () if not re.fullmatch(QUALIFIED + re.escape(base), swift) else (swift,)
    elif base == 'void':
        expected = ('Swift.UnsafeMutableRawPointer?', 'Swift.UnsafeRawPointer?') if pointers == 1 else ()
    elif base in SCALARS:
        expected = []
        for inner in SCALARS[base]:
            for pointer in ('Swift.UnsafeMutablePointer', 'Swift.UnsafePointer'):
                nested = f'{pointer}<{inner}>?'
                for _ in range(pointers - 1):
                    nested = f'Swift.UnsafeMutablePointer<{nested}>?'
                expected.append(nested)
    elif pointers == 1:
        # The parameters Swift keeps of a generic Objective-C class change nothing of the pointer.
        named = QUALIFIED + '(?:' + re.escape(base) + '|' + re.escape(SWIFT_NAMES.get(base, base)) + ')' + r'(?:<.*>)?'
        if re.fullmatch(named + r'\?', swift):
            expected = (swift,)
        elif swift == 'Swift.AnyObject?' and state == 'inert':
            expected = (swift,)
        elif ownership == 'manual' and re.fullmatch(QUALIFIED + r'ManuallyRetained<' + named + '>', swift):
            expected = (swift,)
        elif re.fullmatch(r'Swift\.UnsafeMutablePointer<' + named + r'>\?', swift):
            # A pointer to a C struct, which the table cannot tell from a class by its name.
            expected, is_object = (swift,), False
        else:
            expected = ()
    else:
        expected = ()
    if expected is not None and swift not in expected:
        if is_object and re.fullmatch(QUALIFIED + re.escape(base) + r'(?:<.*>)?', swift):
            return f'the SDK\'s {sdk} may be nil, and the field is the non-optional {swift}'
        wanted = ' or '.join(expected) if expected else {
            True: f'{base}? (AnyObject? when the state is inert, ManuallyRetained<{base}> when the ownership is manual)',
            False: f'the imported type {base}'}[is_object]
        return f'the SDK\'s {sdk} is {wanted} in memory, and the field is {swift}'
    if is_object and ownership == 'value':
        return f'the SDK\'s {sdk} is an object, whose ownership is strong, unowned or manual, not value'
    if not is_object and ownership != 'value':
        return f'the SDK\'s {sdk} is not an object: its ownership is value, not {ownership}'
    return None


def demangle(symbols):
    """What xcrun swift-demangle says of each symbol, in their order."""
    symbols = list(symbols)
    if not symbols:
        return []
    demangled = run(['xcrun', 'swift-demangle'], input='\n'.join(symbols) + '\n')
    lines = demangled.stdout.splitlines()
    if demangled.returncode != 0 or len(lines) != len(symbols):
        raise TableError(f'xcrun swift-demangle did not demangle {len(symbols)} symbols: {demangled.stderr.strip()[-500:]}')
    return lines


def table_problems(ivars, where, structs=None):
    """What the entries of a table must be, whatever the classes a build has: one line per entry at fault.

    With structs, the C structs that hold the arrays, the type of each field must also correspond to its sdk."""
    problems = []
    for name, entry in ivars.items():
        if not re.fullmatch(r'[A-Za-z_]\w*\.[A-Za-z_]\w*', name):
            problems.append(f'{name!r} is not Class.ivar')
        elif not isinstance(entry, dict) or tuple(sorted(entry)) != tuple(sorted(ENTRY_FIELDS)):
            problems.append(f'{name} does not have exactly {", ".join(ENTRY_FIELDS)}')
        elif not all(isinstance(entry[key], str) and entry[key].strip() == entry[key] and entry[key] for key in ENTRY_FIELDS):
            problems.append(f'{name} has an empty or padded value')
        elif entry['state'] not in STATES:
            problems.append(f'{name}: state {entry["state"]!r} is not one of {", ".join(STATES)}')
        elif entry['ownership'] not in OWNERSHIPS:
            problems.append(f'{name}: ownership {entry["ownership"]!r} is not one of {", ".join(OWNERSHIPS)}')
        elif not re.fullmatch(r'_\$s[A-Za-z0-9_]+Wvd', entry['symbol']):
            problems.append(f'{name}: {entry["symbol"]!r} is not a Swift field offset symbol (_$s...Wvd)')
    if problems:
        return [f'{where}: {problem}' for problem in problems]
    by_symbol = {}
    for name, entry in ivars.items():
        by_symbol.setdefault(entry['symbol'], []).append(name)
    problems += ['instance variables given the same field: ' + ' and '.join(names)
                 for names in by_symbol.values() if len(names) > 1]
    # The symbol is the offset of the field the entry names, and of a field an alias can reach.
    for (name, entry), text in zip(ivars.items(), demangle(entry['symbol'] for entry in ivars.values())):
        found = OFFSET.fullmatch(text)
        if found is None:
            problems.append(f'{name}: {entry["symbol"]} is not a direct field offset ({text})')
        elif found.group('open') or found.group('private'):
            problems.append(f'{name}: {found.group("field")} is a private field, whose symbol is local to its object file ({text})')
        elif found.group('field') != entry['field']:
            problems.append(f'{name}: the symbol is the offset of {found.group("field")}, not of {entry["field"]}')
        elif structs is not None:
            wrong = type_problem(entry, found.group('type'), structs)
            if wrong:
                problems.append(f'{name}: the type of {entry["field"]} does not correspond to sdk: {wrong}')
    return [f'{where}: {problem}' for problem in problems]


def object_files(paths):
    files = []
    for path in paths:
        path = Path(path)
        if path.is_dir():
            inside = sorted(path.glob('*.o')) or sorted(path.rglob('*.o'))
            if not inside:
                raise TableError(f'{path} has no object file')
            files += inside
        elif path.is_file():
            files.append(path)
        else:
            raise TableError(f'{path} is neither a folder of object files nor a file')
    return files


def field_offsets(paths, module=MODULE):
    """{(class, field): [(symbol, Swift type, private)]} of the stored fields of the module's classes in a build."""
    symbols = set()
    files = object_files(paths)
    for start in range(0, len(files), 200):
        listing = run(['xcrun', 'nm', '-j', *[str(path) for path in files[start:start + 200]]])
        if listing.returncode != 0:
            raise TableError(f'nm does not list the objects: {listing.stderr.strip()[-500:]}')
        symbols.update(line for line in listing.stdout.split('\n') if line.endswith('Wvd') and line.startswith('_$s'))
    symbols = sorted(symbols)
    fields = {}
    for symbol, text in zip(symbols, demangle(symbols)):
        found = OFFSET.fullmatch(text)
        if found is None:
            continue
        owner = found.group('owner')
        if owner in MODULE_CLASSES:
            fields.setdefault((MODULE_CLASSES[owner], found.group('field')), []).append(
                (symbol, found.group('type'), bool(found.group('open') or found.group('private'))))
        for prefix in (f'{module}.', f'(extension in {module}):__C.'):
            if owner.startswith(prefix) and re.fullmatch(r'[A-Za-z_]\w*', owner[len(prefix):]):
                fields.setdefault((owner[len(prefix):], found.group('field')), []).append(
                    (symbol, found.group('type'), bool(found.group('open') or found.group('private'))))
    return fields


def read_fragment(path):
    fragment = read_json(path)
    problems = []
    if not isinstance(fragment, dict):
        raise TableError(f'{relative(path)} is not a JSON object of entries')
    for name, entry in fragment.items():
        if not re.fullmatch(r'[A-Za-z_]\w*\.[A-Za-z_]\w*', name):
            problems.append(f'{name!r} is not Class.ivar')
        elif not isinstance(entry, dict) or not set(FRAGMENT_FIELDS) <= set(entry) <= set(ENTRY_FIELDS):
            problems.append(f'{name} does not have exactly {", ".join(FRAGMENT_FIELDS)}')
        elif not all(isinstance(entry[key], str) and entry[key].strip() == entry[key] and entry[key] for key in FRAGMENT_FIELDS):
            problems.append(f'{name} has an empty or padded value')
        elif entry['state'] not in STATES:
            problems.append(f'{name}: state {entry["state"]!r} is not one of {", ".join(STATES)}')
        elif entry['ownership'] not in OWNERSHIPS:
            problems.append(f'{name}: ownership {entry["ownership"]!r} is not one of {", ".join(OWNERSHIPS)}')
    return fragment, [f'{relative(path)}: {problem}' for problem in problems]


def complete(ivars, fragments, fields, structs):
    """The entries of a table with those of the fragments, each with the symbol the build has for its field.

    Answers the entries and the problems; with problems the entries are not to be written."""
    problems, merged, added, origin = [], {name: dict(entry) for name, entry in ivars.items()}, {}, {}
    for path, fragment in fragments:
        for name, entry in fragment.items():
            if name in origin:
                problems.append(f'{name} is in {origin[name]} and in {relative(path)}')
                continue
            origin[name] = relative(path)
            wanted = {key: entry[key] for key in FRAGMENT_FIELDS}
            if name in merged:
                merged[name].update(wanted)
            else:
                added.setdefault(name.split('.')[0], {})[name] = wanted
    for entries in added.values():
        merged.update(entries)
    classes = {cls for cls, _ in fields}
    for name, entry in merged.items():
        cls, field = name.split('.')[0], entry['field']
        found = fields.get((cls, field), [])
        reachable = sorted({(symbol, kind) for symbol, kind, private in found if not private})
        if not found:
            near = sorted(other for owner, other in fields if owner == cls and other.lower().endswith(name.split('.', 1)[1].lower()))
            problems.append(f'{name}: the objects have no stored field {field} of {cls}'
                            + ('' if cls in classes else f', nor any field of a class {cls}')
                            + (f' (it has {", ".join(near[:4])})' if near else ''))
        elif not reachable:
            problems.append(f'{name}: {field} is a private field of {cls}, whose symbol is local to its object file')
        elif len(reachable) > 1:
            problems.append(f'{name}: the objects have more than one field {field} of {cls}: '
                            + ', '.join(symbol for symbol, _ in reachable))
        else:
            entry['symbol'], kind = reachable[0]
            wrong = type_problem(entry, kind, structs)
            if wrong:
                problems.append(f'{name}: the type of {field} does not correspond to sdk: {wrong}')
    by_symbol = {}
    for name, entry in merged.items():
        if 'symbol' in entry:
            by_symbol.setdefault(entry['symbol'], []).append(name)
    problems += ['instance variables given the same field: ' + ' and '.join(names) for names in by_symbol.values() if len(names) > 1]
    return merged, problems


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)
    completion = commands.add_parser('complete', help='write the table with the entries of the fragments and the symbols of a build')
    completion.add_argument('fragments', nargs='*', type=Path, metavar='FRAGMENT',
                            help='{"Class.ivar": {"sdk", "field", "state", "ownership"}}; none: only the symbols are read again')
    completion.add_argument('--objects', action='append', required=True, type=Path,
                            help='folder of the object files of the build, object files or a linked executable (repeatable)')
    completion.add_argument('--table', type=Path, default=TABLE, help='the table to complete (default: the application\'s)')
    completion.add_argument('--storage', action='append', type=Path,
                            help='header that declares the C structs of the arrays (default: LegacyPluginIvarStorage.h; repeatable)')
    completion.add_argument('--module', default=MODULE, help='the Swift module of the classes (default: Horos)')
    args = parser.parse_args(argv)
    try:
        table = read_table(args.table)
        structs = {}
        for header in args.storage or [STORAGE]:
            structs.update(storage_structs(Path(header).read_text(encoding='utf-8', errors='replace')))
        fragments, problems = [], []
        for path in args.fragments:
            fragment, wrong = read_fragment(path)
            fragments.append((path, fragment))
            problems += wrong
        merged = table['ivars']
        if not problems:
            merged, problems = complete(table['ivars'], fragments, field_offsets(args.objects, args.module), structs)
        if not problems:
            problems = table_problems(merged, relative(args.table), structs)
    except TableError as error:
        print(f'FAIL: {error}')
        return 1
    if problems:
        for problem in problems:
            print('FAIL: ' + problem)
        print(f'FAIL: {len(problems)} entries at fault; {relative(args.table)} is as it was')
        return 1
    before = len(table['ivars'])
    table['ivars'] = merged
    Path(args.table).write_text(render_table(table), encoding='utf-8')
    by_class = {}
    for name in merged:
        by_class[name.split('.')[0]] = by_class.get(name.split('.')[0], 0) + 1
    print(f'{relative(args.table)}: {len(merged)} entries, {len(merged) - before} of them new, each with the symbol of its field in the '
          f'build ({", ".join(f"{cls} {count}" for cls, count in by_class.items())}); write the response file with '
          f'python3 tests/test-legacy-plugin-instance-variables.py --write-aliases')
    return 0


if __name__ == '__main__':
    sys.exit(main())
