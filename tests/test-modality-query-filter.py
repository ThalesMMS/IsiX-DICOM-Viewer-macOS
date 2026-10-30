#!/usr/bin/env python3
"""Several modalities go out as several values in one C-FIND key.

The reports say picking CT+MR returns only the first modality. Horos joins the
selected modalities with a backslash and sends them in ModalitiesInStudy, which
is the DICOM way to ask for a list - but only if the join survives the filter and
the join really becomes a multi-valued element rather than one five-character
string.

The QueryFilter and the DICOM encoding here are the ones the application ships:
the test compiles the production QueryFilter and its Horos date dependency.
QueryFilter is Swift: its Objective-C interface is generated here
from that same source. DCM and DCMTK come from the requested app build.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
from dcmtk_build import dcmtk_flags, CONFIGURATION
from sources import class_text, is_swift, source_path
from isix_modules import build_module, link_flags
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
failures = []

# Use the same explicit configuration for application frameworks and DCMTK.
configuration = CONFIGURATION
products = next((base / 'Products' / configuration
                 for base in (root / 'build', root / 'build/Build')
                 if (base / 'Products' / configuration).is_dir()), None)
if products is None:
    print('skipped: build the requested Horos target configuration')
    raise SystemExit(2)


# --- what the query window builds -------------------------------------------
# The rule is IsiXDICOMNetwork's QueryModalityFilter: one join, and the key
# that carries it. The window's filter and the study queries of the portal and
# the browser both take it from there.
rules = (root / 'Modules/IsiXDICOMNetwork/Sources/QueryWindowRules.swift').read_text()
controller = class_text('QueryController')
joins = re.findall(r'joined\(separator: "\\\\"\)', rules)
if len(joins) != 1:
    failures.append('%d modality joins found in the Query window rules; expected one, '
                    'QueryModalityFilter.value' % len(joins))
modality = rules[rules.index('public enum QueryModalityFilter'):rules.index('// MARK: - Search fields')]
if 'modalities.joined(separator: "\\\\")' not in modality:
    failures.append('QueryModalityFilter.value no longer joins the modalities with a backslash')
routed = re.findall(r'"(ModalitiesinStudy|Modality)"', modality)
if sorted(routed) != sorted(['Modality', 'ModalitiesinStudy']):
    failures.append('QueryModalityFilter.key no longer routes the modalities to ModalitiesinStudy or Modality')
build = rules[rules.index('public static func build('):rules.index('private static func intValue(')]
if 'QueryModalityFilter.value(' not in build or 'QueryModalityFilter.key(' not in build:
    failures.append('the study queries of the portal and the browser no longer take the modalities from QueryModalityFilter')
window_filter = controller[controller.index('public nonisolated func getModalityQueryFilter('):]
window_filter = window_filter[:window_filter.index('\n    }\n')]
if 'QueryModalityFilter.value(' not in window_filter or 'QueryModalityFilter.key(' not in window_filter:
    failures.append('the Query window\'s modality filter no longer comes from QueryModalityFilter')
if 'QueryStudyFilters.build(' not in controller:
    failures.append('the study queries of the portal and the browser no longer build their filters with QueryStudyFilters')
# The join must not be split up again or quoted anywhere on the way out.
if re.search(r'components\(separatedBy: "\\\\"\)[^\n]*[Mm]odalit', controller):
    failures.append('QueryController splits the joined modality list again before sending it')

# And the C-FIND dataset maps those two keys onto the two real tags.
# The query node is Swift: it takes the attribute of each filter key from
# IsiXDICOMNetwork's QueryFilterAttribute.
keys = (root / 'Modules/IsiXDICOMNetwork/Sources/QueryKeys.swift').read_text()
node = (root / 'Horos/Sources/DCMTKQueryNode+Query.swift').read_text()
if 'key.flatMap(QueryFilterAttribute.named)' not in node:
    failures.append('the C-FIND dataset no longer takes its attributes from QueryFilterAttribute')
for key, tag in (('ModalitiesinStudy', '.modalitiesInStudy'), ('Modality', '.modality')):
    branch = re.search(r'case "%s": return (.*)' % key, keys)
    if not branch:
        failures.append('the C-FIND dataset no longer handles %s' % key)
    elif branch.group(1).strip() != '.text(%s)' % tag:
        failures.append('%s no longer goes into %s' % (key, tag))
# ModalitiesInStudy is asked for by default, and the empty key is requested so
# the SCP has somewhere to answer.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import default_preferences  # noqa: E402
defaults = default_preferences.registered()
if defaults.get('SupportQRModalitiesinStudy') != '1':
    failures.append('SupportQRModalitiesinStudy is no longer on by default')
rootnode = (root / 'Horos/Sources/DCMTKRootQueryNode.swift').read_text()
identifiers = (root / 'Modules/IsiXDICOMNetwork/Sources/QueryIdentifier.swift').read_text()
if 'modalitiesInStudy: defaults.bool(forKey: "SupportQRModalitiesinStudy")' not in rootnode \
        or 'identifier.requestReturn(options.modalitiesInStudy ? .modalitiesInStudy : .modality)' not in identifiers:
    failures.append('the query no longer asks the SCP to return ModalitiesInStudy')

# --- what those two steps actually produce ----------------------------------
program = r'''
#import <Foundation/Foundation.h>
#import "QueryFilter.h"
#include <dcmtk/config/osconfig.h>
#include <dcmtk/dcmdata/dcdeftag.h>
#include <dcmtk/dcmdata/dcdatset.h>
#include <dcmtk/dcmdata/dcelem.h>
#include <dcmtk/dcmdata/dcistrmb.h>
#include <dcmtk/dcmdata/dcostrmb.h>
#include <cstdio>
#include <cstring>
#include <cstdarg>

static int failed = 0;
static void fail(const char *format, ...) {
    va_list arguments; va_start(arguments, format);
    fputs("FAIL: ", stderr); vfprintf(stderr, format, arguments); fputc('\n', stderr);
    va_end(arguments); failed = 1;
}

// The dataset a C-FIND carries, built the way -queryWithValues:dataset: builds
// it, then encoded and read back the way the association would carry it.
static void check(NSArray *modalities) {
    NSString *joined = [modalities componentsJoinedByString:@"\\"];
    QueryFilter *filter = [QueryFilter queryFilterWithObject:joined
                                                ofSearchType:searchExactMatch
                                                      forKey:@"ModalitiesinStudy"];
    NSString *value = [filter filteredValue];
    if (![value isEqualToString:joined])
        fail("the filter changed %s into %s", joined.UTF8String, value.UTF8String);
    // The query window drops any key that is only wildcards; a modality list has
    // none, so it must survive that rule.
    if ([value rangeOfString:@"*"].location != NSNotFound)
        fail("%s contains a wildcard and would be dropped as too small a query", value.UTF8String);

    DcmDataset dataset;
    dataset.putAndInsertString(DCM_ModalitiesInStudy, [value cStringUsingEncoding:NSISOLatin1StringEncoding]);

    // Encode explicit VR little endian and read it back, so what is checked is
    // what the peer would parse rather than what was put in.
    Uint32 size = 8192; char *buffer = new char[size];
    DcmOutputBufferStream out(buffer, size);
    dataset.transferInit();
    if (dataset.write(out, EXS_LittleEndianExplicit, EET_ExplicitLength, NULL).bad())
        fail("%s could not be encoded", value.UTF8String);
    dataset.transferEnd();
    void *encoded = NULL; offile_off_t written = 0;
    out.flushBuffer(encoded, written);

    DcmDataset parsed;
    DcmInputBufferStream in;
    in.setBuffer(buffer, written); in.setEos();
    parsed.transferInit();
    if (parsed.read(in, EXS_LittleEndianExplicit).bad())
        fail("%s could not be read back", value.UTF8String);
    parsed.transferEnd();

    DcmElement *element = NULL;
    if (parsed.findAndGetElement(DCM_ModalitiesInStudy, element).bad() || element == NULL) {
        fail("%s did not arrive as ModalitiesInStudy", value.UTF8String);
        delete[] buffer; return;
    }
    if (element->getVM() != (unsigned long)modalities.count)
        fail("%s arrived with %lu values, expected %lu", value.UTF8String,
             (unsigned long)element->getVM(), (unsigned long)modalities.count);
    for (unsigned long i = 0; i < element->getVM() && i < modalities.count; i++) {
        OFString one;
        element->getOFString(one, i);
        if (strcmp(one.c_str(), [modalities[i] UTF8String]) != 0)
            fail("%s arrived with [%lu] = %s, expected %s", value.UTF8String, i,
                 one.c_str(), [modalities[i] UTF8String]);
    }
    delete[] buffer;
}

int main() { @autoreleasepool {
    check(@[@"CT"]);
    check(@[@"CT", @"MR"]);
    check(@[@"MR", @"CT"]);
    check(@[@"CR", @"CT"]);
    check(@[@"CT", @"MR", @"US", @"PT"]);
    // A modality list is never trimmed to its first value.
    DcmDataset dataset;
    dataset.putAndInsertString(DCM_ModalitiesInStudy, "CT\\MR");
    OFString whole;
    dataset.findAndGetOFStringArray(DCM_ModalitiesInStudy, whole);
    if (strcmp(whole.c_str(), "CT\\MR") != 0)
        fail("the whole element reads back as %s", whole.c_str());
    if (failed) return 1;
    puts("PASS: five modality selections survive the filter and arrive as one multi-valued "
         "ModalitiesInStudy, in order, after an explicit VR round trip");
    return 0;
}}
'''

assert is_swift('QueryFilter'), 'QueryFilter is expected in Swift'

# What the Swift of QueryFilter sees of the app: the DICOM date type of the
# IsiXDICOMFile module, which depends on IsiXImaging.
with tempfile.TemporaryDirectory(prefix='horos-modality-filter-') as directory:
    path = Path(directory)
    (path / 'bin').mkdir()
    modules = path / 'modules'
    build_module('IsiXImaging', modules)
    build_module('IsiXDICOMFile', modules, ['-I', str(modules)])
    # QueryFilter.h imports Horos-Swift.h for the class: the interface Swift
    # generates for QueryFilter.swift, the same the app's header declares.
    (path / 'include').mkdir()
    interface = subprocess.run(
        ['xcrun', 'swiftc', '-emit-object', '-parse-as-library', '-module-name', 'Horos', '-I', str(modules),
         str(source_path('QueryFilter')), '-emit-objc-header-path', str(path / 'include/Horos-Swift.h'),
         '-o', str(path / 'QueryFilter.o')], capture_output=True, text=True)
    if interface.stderr:
        print(interface.stderr.strip())
    if interface.returncode != 0:
        failures.append('the production QueryFilter.swift no longer compiles with its date interface')
    (path / 'test.mm').write_text(program)
    compiled = interface.returncode == 0 and subprocess.run(
        ['xcrun', 'clang++', '-std=c++14', '-fobjc-arc', '-c', str(path / 'test.mm'), '-iquote', str(path / 'include'),
         '-I', str(modules), *[flag for flag in dcmtk_flags('dcmnet') if flag.startswith('-I')], '-o', str(path / 'test.o')],
        capture_output=True, text=True)
    # swiftc links, so the Swift runtime the Swift object needs is found.
    linked = compiled and compiled.returncode == 0 and subprocess.run(
        ['xcrun', 'swiftc', str(path / 'test.o'), str(path / 'QueryFilter.o'),
         *link_flags('IsiXDICOMFile', modules), *link_flags('IsiXImaging', modules),
         *[flag for flag in dcmtk_flags('dcmnet') if not flag.startswith('-I')], '-lc++',
         '-framework', 'Foundation', '-o', str(path / 'bin/test')],
        capture_output=True, text=True)
    if compiled and compiled.stderr:
        print(compiled.stderr.strip())
    if linked and linked.stderr:
        print(linked.stderr.strip())
    if not (linked and linked.returncode == 0):
        failures.append('the shipped filter and encoding no longer link on their own')
    else:
        run = subprocess.run([str(path / 'bin/test')], capture_output=True, text=True)
        print((run.stdout or run.stderr).strip())
        if run.returncode != 0:
            failures.append('a modality selection does not arrive as several values')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: the modality selection is joined once, routed to ModalitiesInStudy, and reaches the '
      'peer as one multi-valued element (%s build dependencies)' % configuration)
