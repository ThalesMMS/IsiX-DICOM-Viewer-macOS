#!/usr/bin/env python3
"""The application's executable defines the zlib functions an older plugin was bound to in it.

The executable this application started from carried a static copy of zlib
1.2.3 under the library's own names and exported them. The static linker bound
the zlib references of a plugin linked with the application's executable as
its bundle loader to the executable ("from executable" in `nm -m`), and dyld
refuses such a plugin when the executable that loads it does not define the
name. Horos/Sources/LegacyPluginZlibExports.c defines every function of that
copy's zlib.h, each as a call into the system's zlib.

The checks, with the file of the working tree:
- the file defines each of the names once, and no other;
- tests/legacy-plugin-abi.json has each of them in symbols, none in missing,
  and says where they come from, with their number; the tool that writes the
  registry (tools/inventory-plugin-api.py --static-zlib-symbols) reads the
  names in a zlib.h, outside its comments, and leaves the registry as it is;
- a small host executable built from the file alone, with hidden visibility
  and dead-code stripping, exports every name;
- a bundle that uses zlib, linked with that host as its bundle loader and
  without the system's zlib, has every zlib reference bound to the executable;
  the host loads it, each reference is the host's own function, and the bundle
  deflates and inflates a buffer, compresses and uncompresses it, computes and
  combines checksums, writes a .gz file with gzprintf and reads it back, and
  reads the table of get_crc_table at the width zlib 1.2.3 declared;
- as the control, a host built without the file refuses the same bundle, and
  dyld names the symbol: without it these checks would not see the defect.

Given the zlib.h of that copy as the first argument, the names it declares
must be the ones here, and the tool must leave the registry as it is with it.

Exits 2 (skipped) without clang and nm.
"""
from collections import Counter
from pathlib import Path
import importlib.util
import json
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'Horos/Sources/LegacyPluginZlibExports.c'
REGISTRY = ROOT / 'tests/legacy-plugin-abi.json'
TOOL = ROOT / 'tools/inventory-plugin-api.py'
SKIPPED = 2
VERSION = '1.2.3'

# Every function the zlib.h of zlib 1.2.3 declares ZEXTERN.
NAMES = '''
zlibVersion zlibCompileFlags zError
deflateInit_ deflateInit2_ deflate deflateEnd deflateSetDictionary deflateCopy deflateReset deflateParams deflateTune
deflateBound deflatePrime deflateSetHeader
inflateInit_ inflateInit2_ inflate inflateEnd inflateSetDictionary inflateSync inflateSyncPoint inflateCopy inflateReset
inflatePrime inflateGetHeader inflateBackInit_ inflateBack inflateBackEnd
compress compress2 compressBound uncompress
gzopen gzdopen gzsetparams gzread gzwrite gzprintf gzputs gzgets gzputc gzgetc gzungetc gzflush gzseek gzrewind gztell
gzeof gzdirect gzclose gzerror gzclearerr
adler32 adler32_combine crc32 crc32_combine get_crc_table
'''.split()

HOST = r'''
#include <dlfcn.h>
#include <stdio.h>

int main(int argc, char **argv)
{
    if (argc < 3)
        return 64;
    void *plugin = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (plugin == NULL) {
        fprintf(stderr, "refused: %s\n", dlerror());
        return 3;
    }
    int (*entry)(const char *) = (int (*)(const char *))dlsym(plugin, "LegacyZlibPluginEntry");
    if (entry == NULL) {
        fprintf(stderr, "the bundle has no entry\n");
        return 4;
    }
    return entry(argv[2]);
}
'''

PLUGIN = r'''
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <zlib.h>
#undef gzgetc

// The table as zlib 1.2.3 declared it: unsigned long entries.
const unsigned long *WideCRCTable(void) __asm__("_get_crc_table");

#define CHECK(condition) \
    do { if (!(condition)) { fprintf(stderr, "bundle: line %d: %s\n", __LINE__, #condition); return 1; } } while (0)

static const struct { const char *name; const void *function; } bound[] = {
BOUND
};

static unsigned char source[65536], packed[70000], restored[65536];

__attribute__((visibility("default"))) int LegacyZlibPluginEntry(const char *directory)
{
    for (size_t index = 0; index < sizeof bound / sizeof bound[0]; index++) {
        if (bound[index].function != dlsym(RTLD_MAIN_ONLY, bound[index].name)) {
            fprintf(stderr, "bundle: %s is not the executable's function\n", bound[index].name);
            return 1;
        }
    }

    for (size_t index = 0; index < sizeof source; index++)
        source[index] = (unsigned char)((index * 7) ^ (index >> 5));

    CHECK(zlibVersion() != NULL && zlibVersion()[0] == ZLIB_VERSION[0]);
    CHECK(strcmp(zError(Z_DATA_ERROR), "data error") == 0);
    (void)zlibCompileFlags();

    z_stream deflated;
    memset(&deflated, 0, sizeof deflated);
    CHECK(deflateInit(&deflated, Z_BEST_COMPRESSION) == Z_OK);
    deflated.next_in = source;
    deflated.avail_in = sizeof source;
    deflated.next_out = packed;
    deflated.avail_out = sizeof packed;
    CHECK(deflateBound(&deflated, sizeof source) <= sizeof packed);
    CHECK(deflate(&deflated, Z_FINISH) == Z_STREAM_END);
    uLong packedLength = deflated.total_out;
    CHECK(packedLength > 0 && packedLength < sizeof source);
    CHECK(deflateEnd(&deflated) == Z_OK);

    z_stream inflated;
    memset(&inflated, 0, sizeof inflated);
    CHECK(inflateInit(&inflated) == Z_OK);
    inflated.next_in = packed;
    inflated.avail_in = (uInt)packedLength;
    inflated.next_out = restored;
    inflated.avail_out = sizeof restored;
    CHECK(inflate(&inflated, Z_FINISH) == Z_STREAM_END);
    CHECK(inflated.total_out == sizeof source && memcmp(source, restored, sizeof source) == 0);
    CHECK(inflateEnd(&inflated) == Z_OK);

    uLongf length = compressBound(sizeof source);
    CHECK(length <= sizeof packed);
    CHECK(compress2(packed, &length, source, sizeof source, 6) == Z_OK);
    memset(restored, 0, sizeof restored);
    uLongf restoredLength = sizeof restored;
    CHECK(uncompress(restored, &restoredLength, packed, length) == Z_OK);
    CHECK(restoredLength == sizeof source && memcmp(source, restored, sizeof source) == 0);
    length = sizeof packed;
    CHECK(compress(packed, &length, source, sizeof source) == Z_OK);

    const Bytef *text = (const Bytef *)"abcdef";
    CHECK(crc32(0, text, 3) == 0x352441c2UL);
    CHECK(adler32(1, text, 3) == 0x024d0127UL);
    CHECK(crc32_combine(crc32(0, text, 3), crc32(0, text + 3, 3), 3) == crc32(0, text, 6));
    CHECK(adler32_combine(adler32(1, text, 3), adler32(1, text + 3, 3), 3) == adler32(1, text, 6));
    const unsigned long *table = WideCRCTable();
    CHECK(table != NULL && table[0] == 0 && table[1] == 0x77073096UL && table[255] == 0x2d02ef8dUL);

    char path[2048], line[64];
    snprintf(path, sizeof path, "%s/round-trip.gz", directory);
    gzFile file = gzopen(path, "wb");
    CHECK(file != NULL);
    CHECK(gzprintf(file, "%s %d\n", "value", 42) == 9);
    CHECK(gzputs(file, "second\n") == 7);
    CHECK(gzputc(file, '!') == '!');
    CHECK(gzwrite(file, source, 100) == 100);
    CHECK(gzclose(file) == Z_OK);

    file = gzopen(path, "rb");
    CHECK(file != NULL);
    CHECK(gzgets(file, line, sizeof line) == line && strcmp(line, "value 42\n") == 0);
    CHECK(gzgetc(file) == 's');
    CHECK(gzungetc('s', file) == 's');
    CHECK(gzread(file, line, 7) == 7 && memcmp(line, "second\n", 7) == 0);
    CHECK(gzgetc(file) == '!');
    CHECK(gztell(file) == 17);
    CHECK(gzread(file, restored, 200) == 100 && memcmp(source, restored, 100) == 0);
    CHECK(gzeof(file));
    CHECK(gzrewind(file) == 0 && gzseek(file, 6, SEEK_SET) == 6 && gzgetc(file) == '4');
    int number = 1;
    CHECK(gzerror(file, &number) != NULL && number == Z_OK);
    gzclearerr(file);
    CHECK(gzclose(file) == Z_OK);
    return 0;
}
'''

failures = []


def fail(message):
    failures.append(message)
    print('FAIL:', message)


def run(*command):
    return subprocess.run([str(part) for part in command], capture_output=True, text=True)


def built(what, *command):
    result = run(*command)
    if result.returncode != 0:
        fail(f'{what} did not build: {result.stderr.strip()[-1500:]}')
    return result.returncode == 0


def load_tool():
    spec = importlib.util.spec_from_file_location('inventory_plugin_api', TOOL)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def check_source():
    """Each name defined once in the file, and no other."""
    text = SOURCE.read_text()
    table = re.findall(r'^\s*F\([^,]+,\s*(\w+)\s*,', text, re.M)
    # A definition written out, under its own name or under the one __asm__ gives its symbol.
    renamed = dict(re.findall(r'\b(\w+)\(void\)\s+__asm__\("_(\w+)"\);', text))
    written = [renamed.get(name, name) for name in re.findall(r'^LEGACY_ZLIB_EXPORT\s[^\n(]*?\b(\w+)\(', text, re.M)]
    defined = Counter(table + written)
    for name in NAMES:
        if defined[name] != 1:
            fail(f'{SOURCE.name} defines {name} {defined[name]} times, not once')
    for name in sorted(set(defined) - set(NAMES)):
        fail(f'{SOURCE.name} defines {name}, which zlib {VERSION} did not declare')
    if 'visibility("default")' not in text or 'used' not in re.search(r'#define LEGACY_ZLIB_EXPORT (.*)', text).group(1):
        fail(f'{SOURCE.name}: LEGACY_ZLIB_EXPORT must keep each definition (used) and export it (default visibility)')


def check_registry(tmp, baseline_header):
    """The registry has the names and says where they come from; the tool writes exactly that."""
    text = REGISTRY.read_text(encoding='utf-8')
    registry = json.loads(text)
    tool = load_tool()
    for name in NAMES:
        if '_' + name not in registry['symbols']:
            fail(f'{REGISTRY.name}: symbols lacks _{name}')
        if 'symbols _' + name in registry['missing']:
            fail(f'{REGISTRY.name}: _{name} is listed as missing: a plugin bound to it in the executable is refused whole')
    said = registry['host_resolution'].get(tool.STATIC_ZLIB, '')
    if said != tool.HOST_STATIC_ZLIB % (VERSION, len(NAMES)):
        fail(f'{REGISTRY.name}: host_resolution["{tool.STATIC_ZLIB}"] is not what the tool writes for the {len(NAMES)} '
             f'functions of zlib {VERSION}')

    # What the tool reads in a header: the declarations outside the comments.
    sample = ('#define ZLIB_VERSION "9.8.7"\n'
              '/*\nZEXTERN int ZEXPORT documentedMacro OF((z_streamp strm));\n*/\n'
              'ZEXTERN int ZEXPORT first OF((z_streamp strm,\n                              int flush));\n'
              'ZEXTERN const char * ZEXPORT second OF((void));\n'
              'ZEXTERN int ZEXPORTVA third OF((gzFile file, const char *format, ...));\n'
              'ZEXTERN uLong ZEXPORT fourth(uLong value);\n')
    if tool.zlib_functions(sample) != ('9.8.7', ['first', 'fourth', 'second', 'third']):
        fail(f'the tool read {tool.zlib_functions(sample)} in a header that declares first, second, third and fourth')
    small = {'symbols': {'_first': 3, '_kept': 1}, 'host_resolution': {'1 executable': 'as it was'}}
    added = tool.enter_static_zlib(small, sample)
    if (added != ['_fourth', '_second', '_third'] or small['symbols'] != {'_first': 3, '_kept': 1, '_fourth': 0, '_second': 0,
                                                                         '_third': 0}
            or small['host_resolution'].get('1 executable') != 'as it was' or '9.8.7' not in small['host_resolution'][tool.STATIC_ZLIB]):
        fail(f'the tool entered {added} and left {small} of a registry that had _first and _kept')

    # The registry is what the tool writes from the header: a run over it changes nothing.
    headers = {'the names of these checks': '#define ZLIB_VERSION "%s"\n%s' % (
        VERSION, ''.join('ZEXTERN int ZEXPORT %s OF((void));\n' % name for name in NAMES))}
    if baseline_header:
        declared = tool.zlib_functions(baseline_header.read_text(errors='replace'))
        if declared != (VERSION, sorted(NAMES)):
            fail(f'{baseline_header} declares zlib {declared[0]} with {sorted(set(declared[1]) ^ set(NAMES))} more or '
                 'less than the names of these checks')
        headers[str(baseline_header)] = baseline_header.read_text(errors='replace')
    for what, header in headers.items():
        copy, path = tmp / 'registry.json', tmp / 'zlib.h'
        copy.write_text(text, encoding='utf-8')
        path.write_text(header)
        result = run(sys.executable, TOOL, '--baseline-zlib-header', path, '--static-zlib-symbols', copy)
        if result.returncode != 0:
            fail(f'the tool exited {result.returncode} with {what}: {result.stderr.strip()[-800:]}')
        elif copy.read_text(encoding='utf-8') != text:
            fail(f'{REGISTRY.name} is not what the tool writes with {what}: write it again with '
                 'tools/inventory-plugin-api.py --baseline-zlib-header ZLIB_H --static-zlib-symbols tests/legacy-plugin-abi.json')
    result = run(sys.executable, TOOL, '--static-zlib-symbols', tmp / 'registry.json')
    if result.returncode == 0 or '--baseline-zlib-header' not in result.stderr:
        fail('the tool was expected to ask for --baseline-zlib-header')


def exported(image):
    return set(run('nm', '-gUj', image).stdout.split())


def check_binaries(tmp):
    """The host exports the names, loads a bundle bound to it and runs it; a host without the file refuses the bundle."""
    (tmp / 'host.c').write_text(HOST)
    bound = ',\n'.join('    {"%s", (const void *)%s}' % (name, 'WideCRCTable' if name == 'get_crc_table' else name)
                       for name in NAMES)
    (tmp / 'plugin.c').write_text(PLUGIN.replace('BOUND', bound))
    host, control, plugin = tmp / 'host', tmp / 'control', tmp / 'plugin.bundle'
    strict = ['-Wall', '-Wextra', '-Werror', '-Os']
    # Hidden visibility and dead-code stripping: nothing but the file's own attributes keeps and exports the names.
    if not (built('the host', 'clang', *strict, '-fvisibility=hidden', '-Wl,-dead_strip', tmp / 'host.c', SOURCE, '-o', host)
            and built('the host without the file', 'clang', *strict, tmp / 'host.c', '-o', control)
            and built('the bundle', 'clang', *strict, '-bundle', '-bundle_loader', host, tmp / 'plugin.c', '-o', plugin)):
        return
    lacking = sorted('_' + name for name in NAMES if '_' + name not in exported(host))
    if lacking:
        fail(f'the host built from {SOURCE.name} does not export {", ".join(lacking)}')
    more = sorted(exported(host) - {'_' + name for name in NAMES} - {'_main', '__mh_execute_header'})
    if more:
        fail(f'the host built from {SOURCE.name} also exports {", ".join(more)}')

    references = dict(re.findall(r'\(undefined\)\s+(?:weak\s+)?external\s+(\S+)\s+\(from ([^)]+)\)', run('nm', '-m', plugin).stdout))
    for name in NAMES:
        if references.get('_' + name) != 'executable':
            fail(f'the bundle\'s reference to _{name} is bound to {references.get("_" + name, "nothing")}, not to the executable')
    if any('libz' in library for library in references.values()) or 'libz' in run('otool', '-L', plugin).stdout:
        fail('the bundle links the system\'s zlib: its references would not show what the executable must define')

    work = tmp / 'work'
    work.mkdir()
    done = run(host, plugin, work)
    if done.returncode != 0:
        fail(f'the host built from {SOURCE.name} did not load and run the bundle ({done.returncode}): {done.stderr.strip()[-800:]}')
    refused = run(control, plugin, work)
    named = re.search(r'[Ss]ymbol not found[^\n]*?(_\w+)', refused.stderr)
    if refused.returncode != 3 or not named or named.group(1)[1:] not in NAMES:
        fail(f'the control, a host without {SOURCE.name}, was expected to refuse the bundle with the symbol dyld misses '
             f'({refused.returncode}): {refused.stderr.strip()[-800:]}')


def main():
    for needed in ('clang', 'nm', 'otool'):
        if shutil.which(needed) is None:
            print(f'skipped: needs {needed} (Xcode command line tools)', file=sys.stderr)
            return SKIPPED
    baseline_header = Path(sys.argv[1]) if len(sys.argv) > 1 else None
    if baseline_header and not baseline_header.is_file():
        print(f'skipped: needs the zlib.h given, {baseline_header}', file=sys.stderr)
        return SKIPPED
    check_source()
    with tempfile.TemporaryDirectory(prefix='legacy-plugin-zlib-') as directory:
        tmp = Path(directory).resolve()
        check_registry(tmp, baseline_header)
        check_binaries(tmp)
    if failures:
        print(f'{len(failures)} failure(s)', file=sys.stderr)
        return 1
    print(f'PASS: {SOURCE.name} defines and exports the {len(NAMES)} functions of zlib {VERSION}, a bundle linked with the '
          'executable as its bundle loader is bound to them, loads and round-trips its data through the system\'s zlib, '
          'a host without the file refuses it with the symbol named, and the registry is what the tool writes'
          + (f' from {baseline_header}' if baseline_header else ''))
    return 0


if __name__ == '__main__':
    sys.exit(main())
