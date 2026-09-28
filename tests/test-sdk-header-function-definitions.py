#!/usr/bin/env python3
"""A plugin that includes <Horos/Horos.h> gets no function definition (#813).

Several headers of Horos/Sources, which API-Headers.pl publishes and the
umbrella includes, defined `static` functions with a body: HorosContentBounds,
HorosFileCopy, HorosPluginInstall, HorosPluginLoadDiagnostics,
HorosPluginSignature and HorosRasterSeriesFolder. They are now `static inline`,
like the others of their kind; a function the SDK publishes with a body is
inline, or it lives in a source file.

1. The real API-Headers.pl publishes the revision's headers into a temporary
   framework. No header the umbrella includes defines, at file scope, a
   function that is not inline: a lexical scan of every published header, since
   most of them only compile with the application's DCMTK, VTK and Swift
   headers. The scan is first checked against snippets whose answer is known.
2. Clang, as a plugin would: every published header that compiles on its own,
   with Cocoa and a stand-in Horos-Swift.h, is compiled into an object. None
   draws an "unused function" warning from a published header and none leaves
   an external function in the object; whatever clang reports, the scan of 1
   reported too.

`<git revision>` as an optional argument reads that revision's tree, the
negative control: on the revision before the fix, 1 and 2 fail.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs (#803)
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import io
import os
import re
import subprocess
import sys
import tarfile
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
failures = []

if subprocess.run(['xcrun', '--find', 'clang'], capture_output=True).returncode != 0:
    print('SKIP: no clang here')
    sys.exit(2)

INLINE = re.compile(r'\b(inline|__inline|__inline__|NS_INLINE|CF_INLINE|CG_INLINE|FORCE_INLINE|constexpr)\b')
TYPES = re.compile(r'\b(class|struct|union|enum|typedef|NS_ENUM|NS_OPTIONS|NS_CLOSED_ENUM|NS_ERROR_ENUM)\b')


def blank(match):
    return re.sub(r'[^\n]', ' ', match.group(0))


def code(text):
    """Without comments, literals and preprocessor lines, line numbers kept."""
    text = re.sub(r'/\*.*?\*/', blank, text, flags=re.S)
    text = re.sub(r'//[^\n]*', blank, text)
    text = re.sub(r'"(\\.|[^"\\\n])*"', '""', text)
    text = re.sub(r"'(\\.|[^'\\\n])*'", "''", text)
    return re.sub(r'^[ \t]*#(?:[^\n]*\\\n)*[^\n]*', blank, text, flags=re.M)


def definitions(text):
    """(line, name) of each function body at file scope that is not inline.

    Braces of extern "C" and namespaces are transparent; a body inside a class,
    struct, enum or initializer is not at file scope, and a C++ member defined
    in its class or a template is inline. Objective-C @interface, @protocol and
    @implementation blocks are skipped (test-html-print-sdk-header.py covers
    @implementation)."""
    text = code(text)
    found, stack = [], []
    start, index, objc = 0, 0, False
    while index < len(text):
        character = text[index]
        if character == '@':
            if re.match(r'@(interface|implementation)\b|@protocol\s+\w+\s*[<\n{]', text[index:]):
                objc = True
            elif objc and text.startswith('@end', index):
                objc, start = False, index + 4
        elif objc:
            pass
        elif character == ';' and all(kind == 'scope' for kind in stack):
            start = index + 1
        elif character == '{':
            head = text[start:index]
            kind = 'nested'
            if all(kind == 'scope' for kind in stack):
                if re.search(r'\bextern\s*""\s*$|\bnamespace\b[\w\s:]*$', head):
                    kind = 'scope'
                elif TYPES.search(head.split('(')[0]) or re.search(r'\b(class|struct|union|enum)\b[^()]*$', head) \
                        or '=' in head.split('(')[0] or re.search(r'=\s*$', head):
                    kind = 'type'
                elif re.search(r'\)[\s\w:]*(\(\([^;]*\)\))?[\s\w]*$', head) or re.search(r'\)\s*:[^;]*$', head):
                    if not INLINE.search(head) and not re.search(r'\btemplate\s*<', head):
                        name = re.search(r'([~\w:]+)\s*\((?:[^()]|\([^()]*\))*\)[^()]*$', head, re.S)
                        at = start + (name.start(1) if name else len(head) - len(head.lstrip()))
                        found.append((text.count('\n', 0, at) + 1, name.group(1) if name else '?'))
                    kind = 'function'
            stack.append(kind)
            if kind == 'scope':
                start = index + 1
        elif character == '}':
            if stack:
                stack.pop()
            if all(kind == 'scope' for kind in stack):
                start = index + 1
        index += 1
    return found


# --- 0: the scan answers what it should on known snippets ----------------------
KNOWN = {
    'static int a(void) { return 0; }': ['a'],
    'static inline int a(void) { return 0; }': [],
    'NS_INLINE int a(void) { return 0; }\nCG_INLINE int b(void) { return 0; }': [],
    'int a(void)\n{\n    return 0;\n}': ['a'],
    'static NSString *a(NSString *s,\n    id b)\n{ return s; }': ['a'],
    '__attribute__((unused)) static void a(void) { }': ['a'],
    'extern "C" { static void a(void) { } }': ['a'],
    'namespace n { inline void a() { } void b() { } }': ['b'],
    'class C { public: static int a() { return 0; } void b() const { } };': [],
    'struct S { int x; };\nstatic const S s[] = { {1}, {2} };': [],
    'typedef NS_ENUM(short, T) { A, B };\ntypedef struct { int x; } U;': [],
    'template <typename T> T a(T x) { return x; }': [],
    'inline C::C() : x(0) { }\nC::~C() { }': ['C::~C'],
    '@interface I : NSObject { int x; }\n- (void)a;\n@end\nvoid b(void) { }': ['b'],
    '@protocol P;\nstatic void a(void) { }': ['a'],
    '// static void a(void) { }\n/* void b(void) { } */\n#define C(x) { x; }': [],
    'static void (^a)(void) = ^{ };': [],
}
for snippet, expected in KNOWN.items():
    names = [name for _, name in definitions(snippet)]
    if names != expected:
        failures.append('0: the scan of %r found %s, not %s' % (snippet, names, expected))

folder = Path(tempfile.mkdtemp(prefix='horos-sdk-definitions-'))
PUBLISHED = ('Nitrogen/Sources', 'Horos/Sources', 'cocoahttpserver/DDKeychain.h',
             'Horos/Scripts/Horos/API-Headers.pl')

# The tree under test: the checkout, or the revision's files extracted.
if revision:
    tree = folder / 'tree'
    tree.mkdir()
    archive = subprocess.run(['git', '-C', str(root), 'archive', revision, '--'] + list(PUBLISHED),
                             capture_output=True)
    if archive.returncode != 0:
        print('FAIL: cannot read %s: %s' % (revision, archive.stderr.decode(errors='replace')[-500:]))
        sys.exit(1)
    tarfile.open(fileobj=io.BytesIO(archive.stdout)).extractall(tree)
else:
    tree = root

# --- 1: what the umbrella includes -----------------------------------------------
build = folder / 'build'
frameworks = build / 'Frameworks'
headers = frameworks / 'Horos.framework/Versions/A/Headers'
headers.mkdir(parents=True)
(frameworks / 'Horos.framework/Versions/Current').symlink_to('A')
environment = dict(os.environ, PROJECT_DIR=str(tree), TARGET_BUILD_DIR=str(build),
                   FULL_PRODUCT_NAME='Frameworks/Horos.framework',
                   PUBLIC_HEADERS_FOLDER_PATH='Frameworks/Horos.framework/Versions/A/Headers')
published = subprocess.run(['perl', str(tree / 'Horos/Scripts/Horos/API-Headers.pl')], cwd=build,
                           env=environment, capture_output=True, text=True)
if published.returncode != 0:
    print('FAIL: API-Headers.pl failed:\n' + published.stderr[-1500:])
    sys.exit(1)

umbrella = (headers / 'Horos.h').read_text(encoding='latin1')
included = ['Horos.h'] + re.findall(r'^#include <Horos/([^>]+)>', umbrella, re.M)
missing = [name for name in included if not (headers / name).is_file()]
if missing or len(included) < 100:
    print('FAIL: the umbrella includes %d headers, %d of them not published: %s'
          % (len(included), len(missing), ', '.join(missing[:10])))
    sys.exit(1)

scanned = {}
for name in included:
    for line, function in definitions((headers / name).read_bytes().decode('latin1')):
        scanned.setdefault(name, []).append('%s:%d %s' % (name, line, function))
if scanned:
    failures.append('1: %d published headers define functions that are not inline: %s'
                    % (len(scanned), '; '.join(', '.join(found) for found in scanned.values())))

# --- 2: clang, as a plugin -------------------------------------------------------
# Horos-Swift.h is generated by the build; a stand-in lets the headers that only
# import it for declarations compile, and the others are left to the scan.
(headers / 'Horos-Swift.h').write_text('// generated interface stand-in\n')
objects = folder / 'objects'
objects.mkdir()


def compile_plugin(name):
    """(language, warned functions, external functions), or None when the header
    needs more than Cocoa."""
    for language, suffix in (('objective-c', '.m'), ('objective-c++', '.mm')):
        stem = re.sub(r'\W', '_', name)
        source = objects / (stem + suffix)
        source.write_text('#import <Cocoa/Cocoa.h>\n#import <Horos/%s>\n' % name)
        built = subprocess.run(['xcrun', 'clang', '-x', language, '-fno-objc-arc', '-fblocks', '-Wno-everything',
                                '-Wunused-function', '-F', str(frameworks), '-c', str(source),
                                '-o', str(objects / (stem + '.o'))],
                               capture_output=True, text=True, timeout=300)
        if built.returncode == 0:
            warned = sorted(set(re.findall(r'Headers/([^:\s]+):\d+:\d+: warning: unused function \'(\w+)\'',
                                           built.stderr)))
            symbols = subprocess.run(['xcrun', 'nm', '-m', str(objects / (stem + '.o'))],
                                     capture_output=True, text=True).stdout
            external = sorted(line.split()[-1] for line in symbols.splitlines()
                              if '(__TEXT,__text)' in line and ' external ' in line)
            return language, warned, external
    return None


# The check itself sees both kinds, on a header that is not published.
(headers / 'SDKDefinitionProbe.h').write_text('static void probeStatic(void) { }\n'
                                              'static inline void probeInline(void) { }\n'
                                              'int probeExternal(void) { return 0; }\n')
probe = compile_plugin('SDKDefinitionProbe.h')
if not probe or probe[1] != [('SDKDefinitionProbe.h', 'probeStatic')] or probe[2] != ['_probeExternal']:
    failures.append('2: clang does not report what a probe header defines: %s' % (probe,))
(headers / 'SDKDefinitionProbe.h').unlink()

with ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as pool:
    results = dict(zip(included[1:], pool.map(compile_plugin, included[1:])))
compiled = {name: result for name, result in results.items() if result}
if len(compiled) < 50:
    failures.append('2: only %d published headers compile on their own; the check would say nothing'
                    % len(compiled))
for name, (language, warned, external) in sorted(compiled.items()):
    if warned or external:
        failures.append('2: a plugin (%s) including %s gets its own %s' % (
            language, name, ', '.join(['static %s in %s' % (function, header) for header, function in warned] +
                                      ['external %s' % symbol for symbol in external])))
    for header, function in warned:
        if not any(entry.endswith(' ' + function) for entry in scanned.get(header, [])):
            failures.append('2: clang reports %s in %s, which the scan of 1 missed' % (function, header))

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('PASS: the scan answers %d known snippets; none of the %d headers <Horos/Horos.h> includes defines a '
      'function that is not inline, and a plugin compiling the %d that build with Cocoa alone gets no '
      'function of its own' % (len(KNOWN), len(included), len(compiled)))
