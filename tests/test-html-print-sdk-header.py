#!/usr/bin/env python3
"""The plugin SDK does not implement HorosHTMLPrintSession in plugins (#807).

HorosHTMLPrint.h held the @implementation of HorosHTMLPrintSession and the
bodies of HorosPrintHTMLToPDF and HorosUpdateHTMLReportPDF. It was in
Horos/Sources, whose headers API-Headers.pl publishes and <Horos/Horos.h>
includes: every plugin that included it compiled a class of its own ("Class
HorosHTMLPrintSession is implemented in both"), the defect #779 fixed for
HorosVolumeDiscovery. Only the Decompress helper uses it, so its header and its
implementation now live beside Decompress, and the SDK does not publish them.

1. The real API-Headers.pl publishes the revision's headers into a temporary
   folder: none of them holds an @implementation.
2. A plugin that includes every published HorosHTMLPrint*.h defines no
   HorosHTMLPrintSession and none of the two functions.
3. Decompress still gets them: a .m in the Decompress target implements the
   class and both functions, and an Objective-C++ file like Decompress.mm
   links against them through the header (C linkage).

`<git revision>` as an optional argument reads that revision's tree, the
negative control: on the revision before the fix, 1 and 2 fail.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs (#803)
from pathlib import Path
import os
import re
import subprocess
import sys
import tarfile
import io
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
failures = []

if subprocess.run(['xcrun', '--find', 'clang'], capture_output=True).returncode != 0:
    print('SKIP: no clang here')
    sys.exit(2)

folder = Path(tempfile.mkdtemp(prefix='horos-html-print-sdk-'))
PUBLISHED_DIRS = ('Nitrogen/Sources', 'Horos/Sources', 'cocoahttpserver/DDKeychain.h',
                  'Horos/Scripts/Horos/API-Headers.pl', 'Decompress', 'Horos.xcodeproj/project.pbxproj')

# The tree under test: the checkout, or the revision's files extracted.
if revision:
    tree = folder / 'tree'
    tree.mkdir()
    archive = subprocess.run(['git', '-C', str(root), 'archive', revision, '--'] + list(PUBLISHED_DIRS),
                             capture_output=True)
    if archive.returncode != 0:
        print('FAIL: cannot read %s: %s' % (revision, archive.stderr.decode(errors='replace')[-500:]))
        sys.exit(1)
    tarfile.open(fileobj=io.BytesIO(archive.stdout)).extractall(tree)
else:
    tree = root

# --- 1: what the SDK publishes ------------------------------------------------
build = folder / 'build'
headers = build / 'Frameworks/Horos.framework/Versions/A/Headers'
headers.mkdir(parents=True)
environment = dict(os.environ, PROJECT_DIR=str(tree), TARGET_BUILD_DIR=str(build),
                   FULL_PRODUCT_NAME='Frameworks/Horos.framework',
                   PUBLIC_HEADERS_FOLDER_PATH='Frameworks/Horos.framework/Versions/A/Headers')
published = subprocess.run(['perl', str(tree / 'Horos/Scripts/Horos/API-Headers.pl')], cwd=build,
                           env=environment, capture_output=True, text=True)
if published.returncode != 0:
    print('FAIL: API-Headers.pl failed:\n' + published.stderr[-1500:])
    sys.exit(1)


def code(text):
    """Without comments and string literals."""
    text = re.sub(r'/\*.*?\*/', ' ', text, flags=re.S)
    text = re.sub(r'//[^\n]*', ' ', text)
    return re.sub(r'"(\\.|[^"\\\n])*"', '""', text)


implemented = sorted(path.name for path in headers.glob('*.h')
                     if re.search(r'^\s*@implementation\b', code(path.read_bytes().decode('latin1')), re.M))
if implemented:
    failures.append('1: the SDK publishes headers that implement a class: %s' % ', '.join(implemented))

# --- 2: a plugin that includes what the SDK publishes of HorosHTMLPrint ---------
printing = sorted(path.name for path in headers.glob('HorosHTMLPrint*.h'))
if printing:
    plugin = folder / 'plugin.m'
    plugin.write_text(''.join('#import "%s"\n' % name for name in printing) +
                      '@interface PluginFilter : NSObject @end\n@implementation PluginFilter @end\n')
    built = subprocess.run(['xcrun', 'clang', '-fno-objc-arc', '-fblocks', '-Wno-unused-function',
                            '-I', str(headers), '-c', str(plugin), '-o', str(folder / 'plugin.o')],
                           capture_output=True, text=True)
    if built.returncode != 0:
        failures.append('2: a plugin including %s does not compile:\n%s' % (', '.join(printing), built.stderr[-1500:]))
    else:
        symbols = subprocess.run(['xcrun', 'nm', '-m', str(folder / 'plugin.o')],
                                 capture_output=True, text=True).stdout
        defined = sorted({name for line in symbols.splitlines() if 'undefined' not in line
                          for name in ('_OBJC_CLASS_$_HorosHTMLPrintSession', '_HorosPrintHTMLToPDF',
                                       '_HorosUpdateHTMLReportPDF')
                          if re.search(r'\b%s\b' % re.escape(name), line)})
        if defined:
            failures.append('2: a plugin including %s defines %s of its own' % (', '.join(printing), ', '.join(defined)))

# --- 3: Decompress keeps the class and both functions ---------------------------
project = (tree / 'Horos.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
start = project.index('/* Decompress */ = {\n\t\t\tisa = PBXNativeTarget;')
phase = re.search(r'(\w{24}) /\* Sources \*/', project[start:project.index('};', start)]).group(1)
at = project.index('%s /* Sources */ = {' % phase)
compiled = re.findall(r'/\* (\S+) in Sources \*/', project[at:project.index('};', at)])
candidates = [tree / 'Decompress' / name for name in compiled if name.endswith(('.m', '.mm'))
              and (tree / 'Decompress' / name).is_file()]
implementation = next((path for path in candidates
                       if '@implementation HorosHTMLPrintSession' in code(path.read_bytes().decode('latin1'))
                       and path.name != 'Decompress.mm'), None)
if implementation is None:
    failures.append('3: no file of the Decompress target but Decompress.mm implements HorosHTMLPrintSession')
else:
    caller = folder / 'caller.mm'
    caller.write_text('#import "HorosHTMLPrint.h"\n'
                      'int main(int argc, char **argv) { @autoreleasepool {\n'
                      '    if (argc > 99) return HorosUpdateHTMLReportPDF(@"a", 1) + HorosPrintHTMLToPDF(@"a", @"b", 1);\n'
                      '    return [[[HorosHTMLPrintSession alloc] init] autorelease] ? 0 : 1;\n'
                      '}}\n')
    linked = subprocess.run(['xcrun', 'clang++', '-fno-objc-arc', '-fblocks', '-I', str(implementation.parent),
                             '-x', 'objective-c', str(implementation), '-x', 'objective-c++', str(caller),
                             '-framework', 'AppKit', '-framework', 'WebKit', '-framework', 'Quartz',
                             '-o', str(folder / 'caller')], capture_output=True, text=True)
    if linked.returncode != 0:
        failures.append('3: Decompress\'s Objective-C++ does not link against %s:\n%s'
                        % (implementation.name, linked.stderr[-1500:]))
    elif subprocess.run([str(folder / 'caller')], capture_output=True, timeout=30).returncode != 0:
        failures.append('3: HorosHTMLPrintSession cannot be made from Objective-C++')

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('PASS: the SDK publishes no @implementation (%d headers), a plugin defines no HorosHTMLPrintSession '
      'or print function, and Decompress links them from %s' % (len(list(headers.glob('*.h'))), implementation.name))
