#!/usr/bin/env python3
"""The Query window's rules give what the Objective-C++ QueryController gave.

The Query window was QueryController.mm; it is Swift now, and the rules that
need no window are IsiXDICOMNetwork's QueryDateFilter, QueryModalityFilter,
QueryWindowField, QueryStudyFilters and QueryResultMerge. This compares them
with the revision that still has QueryController.mm:

- the old +getDateAndTimeQueryFilterWithTag:..., -getModalityQueryFilter:,
  +mergeStudies:into:, the merge of the answers of several nodes, and the
  filters +queryStudiesForFilters:servers:showErrors: built, are compiled as
  they were (against the DCMCalendarDate and HorosDateString of that revision
  and the current Swift QueryFilter), with "now" fixed by replacing
  [DCMCalendarDate date] and +dateWithTimeIntervalSinceNow:;
- the app's glue around the module rules (QueryController+Filters.swift and
  QueryController+Network.swift) is compiled from the current sources with the
  same "now";
- both run on every date choice, with the open-ended time on and off, in
  several time zones and at instants around midnight and the daylight-saving
  changes; on the modality choices; on random result lists; and on random
  filter dictionaries under random allow_qr_* preferences. The filters must
  have the same key, search type, object and filtered value; the lists the
  same studies in the same order; the dictionaries the same values.

The old field switch of -queryWithDisplayingErrors: (key, preference, wildcard,
trimming, encoding check, birth date formats) and the date codes of
QueryController.h are read from the old text and checked against the module.
A control checks that the comparison sees a difference when there is one.

Exits 2 when the history does not reach a revision with QueryController.mm.
"""
import private_tmpdir  # noqa: F401
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import harness_defaults  # noqa: E402
import history_reference  # noqa: E402
from isix_modules import build_module, link_flags  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
OLD = 'Horos/Sources/QueryController.mm'
reference = history_reference.before_removal(OLD)
if reference is None and subprocess.run(['git', '-C', str(ROOT), 'cat-file', '-e', 'HEAD:' + OLD],
                                        capture_output=True).returncode == 0:
    reference = 'HEAD'
if reference is None:
    print('skipped: the history does not reach a revision with ' + OLD)
    sys.exit(2)

old = history_reference.show(reference, OLD).decode('mac_roman')
old_header = history_reference.show(reference, 'Horos/Sources/QueryController.h').decode('mac_roman')


def braced(text, start):
    """The block that opens at the first brace at or after `start`, braces included."""
    opening = text.index('{', start)
    depth = 0
    for index in range(opening, len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[opening:index + 1]
    raise ValueError(start)


def method(text, signature):
    return braced(text, text.index(signature))


def swift_member(text, signature):
    """A Swift member from its signature line to its closing brace."""
    at = text.index(signature)
    return text[at:at + len(braced(text, at)) + (text.index('{', at) - at)]


def parenthesized(text, start):
    opening = text.index('(', start)
    depth = 0
    for index in range(opening, len(text)):
        depth += {'(': 1, ')': -1}.get(text[index], 0)
        if depth == 0:
            return text[start:index + 1]
    raise ValueError(start)


def no_query_filter_type(code):
    """The old code with the Swift QueryFilter reached by name, as an untyped object."""
    for a, b in (('QueryFilter**', 'id*'), ('QueryFilter *', 'id '), ('QueryFilter*', 'id'),
                 ('[QueryFilter ', '[NSClassFromString(@"QueryFilter") ')):
        code = code.replace(a, b)
    return code


def fixed_now(code):
    count = code.count('[DCMCalendarDate date]') + code.count('dateWithTimeIntervalSinceNow:')
    code = code.replace('[DCMCalendarDate date]', '[DCMCalendarDate dateWithTimeIntervalSinceReferenceDate: OldNow]')
    code = re.sub(r'\[DCMCalendarDate dateWithTimeIntervalSinceNow: ([^\]]+)\]',
                  r'[DCMCalendarDate dateWithTimeIntervalSinceReferenceDate: OldNow + (\1)]', code)
    assert 'dateWithTimeIntervalSinceNow' not in code and '[DCMCalendarDate date]' not in code
    return code, count


# --- The old code -----------------------------------------------------------

date_signature = '+ (void) getDateAndTimeQueryFilterWithTag: (int) tag fromDate:(NSDate*) from toDate:(NSDate*) to date: (QueryFilter**) dateQueryFilter time: (QueryFilter**) timeQueryFilter'
date_body, replaced = fixed_now(no_query_filter_type(method(old, date_signature)))
assert replaced >= 15, 'the old date filter no longer reads "now" where it did (%d places)' % replaced
modality_signature = '- (QueryFilter*) getModalityQueryFilter:(NSArray*) modalityArray'
modality_body = no_query_filter_type(method(old, modality_signature))
merge_body = method(old, '+ (void) mergeStudies:(NSArray*) found into:(NSMutableArray*) studies')
assert 'DCMTKStudyQueryNode *s = ' in merge_body
merge_body = merge_body.replace('DCMTKStudyQueryNode *s = ', 'id s = ')
answers_at = old.index('else if( [curResult count] < 4000)')
answers_body = braced(old, answers_at)
assert 'NSArray *uidArray = [temporaryCFindResultArray valueForKey: @"uid"];' in answers_body
filters_body = method(old, '+ (NSMutableArray*) queryStudiesForFilters:(NSDictionary*) filters servers: (NSArray*) serversList showErrors: (BOOL) showErrors')
a = filters_body.index('NSMutableDictionary *f = [NSMutableDictionary dictionary];')
b = filters_body.index('[f removeObjectsForKeys: keysToBeRemoved];') + len('[f removeObjectsForKeys: keysToBeRemoved];')
build_body = filters_body[a:b]
for x, y in (('[QueryController getDateAndTimeQueryFilterWithTag:', '[OldQuery getDateAndTimeQueryFilterWithTag:'),
             ('[HorosQueryLog termWithKey: key value: s]', 's'),
             ('dateQueryFilter.filteredValue', '[dateQueryFilter filteredValue]'),
             ('timeQueryFilter.filteredValue', '[timeQueryFilter filteredValue]')):
    assert x in build_body, x
    build_body = build_body.replace(x, y)
build_body = no_query_filter_type(build_body).replace('id dateQueryFilter = nil, *timeQueryFilter = nil;',
                                                       'id dateQueryFilter = nil, timeQueryFilter = nil;')
assert 'id dateQueryFilter = nil, timeQueryFilter = nil;' in build_body
constants = [pair for pair in re.findall(r'^static NSString \*(\w+) = @"(\w+)";$', old, re.M) if not pair[0].startswith('k')]
assert len(constants) == 9, constants
enum = re.search(r'enum\s*\{([^}]*anyDate[^}]*)\};', old_header).group(1)

OLD_HEADER = r'''
#import <Foundation/Foundation.h>
extern NSTimeInterval OldNow;
@interface OldQuery : NSObject
+ (void) getDateAndTimeQueryFilterWithTag: (int) tag fromDate:(NSDate*) from toDate:(NSDate*) to date: (id*) dateQueryFilter time: (id*) timeQueryFilter NS_SWIFT_NAME(oldDate(tag:from:to:date:time:));
+ (id) getModalityQueryFilter:(NSArray*) modalityArray NS_SWIFT_NAME(oldModality(_:));
@end
void OldMerge(NSArray *found, NSMutableArray *studies);
void OldAnswers(NSArray *curResult, NSMutableArray *temporaryCFindResultArray);
NSDictionary *OldBuild(NSDictionary *filters);
'''
OLD_SOURCE = ('''
#import "Old.h"
#import "DCMCalendarDate.h"
#import "Horos.h"
#import "QueryFilter.h"
@interface NSObject (OldQueryFilter)
+ (id)queryFilterWithObject:(id)object ofSearchType:(int)searchType forKey:(id)key;
- (NSString *)filteredValue;
@end
NSTimeInterval OldNow = 0;
enum {''' + enum + '''};
''' + ''.join('static NSString *%s = @"%s";\n' % pair for pair in constants) + '''
@implementation OldQuery
+ (void) getDateAndTimeQueryFilterWithTag: (int) tag fromDate:(NSDate*) from toDate:(NSDate*) to date: (id*) dateQueryFilter time: (id*) timeQueryFilter
''' + date_body + '''
+ (id) getModalityQueryFilter:(NSArray*) modalityArray
''' + modality_body + '''
@end
void OldMerge(NSArray *found, NSMutableArray *studies)
''' + merge_body + '''
void OldAnswers(NSArray *curResult, NSMutableArray *temporaryCFindResultArray)
''' + answers_body + '''
NSDictionary *OldBuild(NSDictionary *filters)
{
''' + build_body + '''
    return f;
}
''')

# --- The current glue -------------------------------------------------------

filters_swift = (ROOT / 'Horos/Sources/QueryController+Filters.swift').read_text()
network_swift = (ROOT / 'Horos/Sources/QueryController+Network.swift').read_text()
query_swift = (ROOT / 'Horos/Sources/QueryController+Query.swift').read_text()
core_swift = (ROOT / 'Horos/Sources/QueryController.swift').read_text()
date_glue = swift_member(filters_swift, 'nonisolated static func dateAndTimeQueryFilters(')
assert date_glue.count('now: Date(),') == 1, 'the date filters no longer take "now" from Date()'
date_glue = date_glue.replace('now: Date(),', 'now: QueryController.testNow,')
modality_glue = swift_member(filters_swift, 'public nonisolated func getModalityQueryFilter(')
merge_glue = swift_member(network_swift, 'nonisolated class func mergeStudies(')
uid_glue = swift_member(network_swift, 'nonisolated static func queryUID(')
images_glue = swift_member(network_swift, 'nonisolated static func queryImageCount(')
answers_glue = swift_member(query_swift, 'nonisolated static func mergeAnswers(')
int_glue = swift_member(core_swift, 'nonisolated static func int32(')
build_at = network_swift.index('QueryStudyFilters.build(')
build_glue = parenthesized(network_swift, build_at)

fields = {}
for number, name in re.findall(r'case (\d):\s+currentQueryKey = (\w+);', old):
    fields[int(number)] = name
assert sorted(fields) == list(range(10)), fields
values = dict(constants)
branches = {}
for match in re.finditer(r'(?:if|else if)\( currentQueryKey == (\w+) && \[\[NSUserDefaults standardUserDefaults\] boolForKey: @"(\w+)"\]\)', old):
    end = old.find('else if( currentQueryKey ==', match.end())
    body = old[match.end():end if end > 0 else len(old)]
    if match.group(1) == 'StudyComments':
        body = braced(old, match.end())
    branches[match.group(1)] = (match.group(2), body)
assert set(branches) == set(fields.values()), (set(branches), set(fields.values()))
field_rows = []
birth_formats = {}
for number in range(10):
    name = fields[number]
    preference, body = branches[name]
    key = 'nil' if name == 'customDICOMField' else '"%s"' % values[name]
    field_rows.append('(%d, %s, "%s", %s, %s, %s)' % (
        number, key, preference, str('stringByTrimmingCharactersInSet' in body).lower(),
        str('stringByAppendingString:@"*"' in body).lower(), str('cStringUsingEncoding' in body).lower()))
    if name == 'PatientBirthDate':
        birth_formats = dict(re.findall(r'if\( tag == (-?\d+)\)\s*\[queryManager addFilter: HorosDateString\(date, @"([^"]+)"\)', body))
assert set(birth_formats) == {'-1', '0', '1'}, birth_formats
enum_checks = []
for name, number in re.findall(r'(\w+)\s*=\s*(\d+)', enum):
    enum_checks.append('check(QueryDateFilter.%s == %s, "the date code %s")' % ({'yesteday': 'yesterday'}.get(name, name), number, name))
assert len(enum_checks) == 15

HARNESS = '''
import Foundation
import IsiXDICOMNetwork
import IsiXDICOMFile
final class QueryController: NSObject {
    nonisolated(unsafe) static var testNow = Date()
''' + '\n'.join((int_glue, date_glue, modality_glue, merge_glue, uid_glue, images_glue, answers_glue)) + '''
    static func newBuild(_ input: [AnyHashable: Any]) -> [String: Any] {
        let filters = input as NSDictionary
        let built = ''' + build_glue + '''
        return built.filters
    }
}
'''

DRIVER = harness_defaults.SWIFT + r'''
import Foundation
import IsiXDICOMNetwork
import IsiXDICOMFile
var failures = 0
var compared = 0
func check(_ condition: Bool, _ what: @autoclosure () -> String) {
    compared += 1
    if !condition { failures += 1; if failures <= 20 { print("FAIL: \(what())") } }
}
func describe(_ value: Any?) -> String {
    guard let value else { return "nil" }
    // The DICOM date type: the old code's DCMCalendarDate, the current
    // code's DICOMCalendarDate (IsiXDICOMFile); one name for both.
    if let date = value as? DCMCalendarDate {
        // A query date is its text; the instant it holds is when it was made.
        return date.isQuery() ? "DCMCalendarDate query \(date.dateString() ?? "")" : "DCMCalendarDate(\(date.timeIntervalSinceReferenceDate))"
    }
    if let date = value as? DICOMCalendarDate {
        return date.isQuery() ? "DCMCalendarDate query \(date.dateString() ?? "")" : "DCMCalendarDate(\(date.timeIntervalSinceReferenceDate))"
    }
    if let date = value as? NSDate { return "\(type(of: date))(\(date.timeIntervalSinceReferenceDate))" }
    if let text = value as? NSString { return "text:\(text)" }
    return "\(type(of: value as AnyObject)):\(value)"
}
func describe(filter: AnyObject?) -> String {
    guard let filter = filter as? QueryFilter else { return filter == nil ? "no filter" : "not a QueryFilter" }
    return "\(filter.key ?? "nil")|\(filter.searchType)|\(describe(filter.object))|\(filter.filteredValue().map { $0 as String } ?? "nil")"
}
let defaults = UserDefaults.standard
func setNow(_ now: Date) { QueryController.testNow = now; OldNow = now.timeIntervalSinceReferenceDate }
func oldDate(_ tag: Int32, _ from: Date, _ to: Date) -> (String, String) {
    var date: AnyObject?, time: AnyObject?
    OldQuery.oldDate(tag: tag, from: from, to: to, date: &date, time: &time)
    return (describe(filter: date), describe(filter: time))
}
func newDate(_ tag: Int32, _ from: Date, _ to: Date) -> (String, String) {
    let (date, time) = QueryController.dateAndTimeQueryFilters(tag: tag, from: from, to: to)
    return (describe(filter: date), describe(filter: time))
}

// The date choices.
let zone = TimeZone.current.identifier
let nows: [TimeInterval] = [783_650_000, 783_651_599.75, 783_644_400.5, 731_746_800, 731_739_599, 752_310_000, 752_306_399, 0.25, 788_918_399.999]
let pickers: [(TimeInterval, TimeInterval)] = [(783_000_000, 783_600_000), (783_600_000, 783_000_000), (783_561_600, 783_561_600),
                                               (731_746_799.5, 752_306_400), (-86_400, 1_000)]
var tags: [Int32] = Array(0...16) + [99, 100, 101, 106, 124, 150, 199, 200, 201, 215, 230, 260, 299, 300, 301, -1]
var dateCases = 0
for future in [false, true] {
    defaults.set(future, forKey: "DICOMQueryAllowFutureQuery")
    for now in nows {
        setNow(Date(timeIntervalSinceReferenceDate: now))
        for (from, to) in pickers {
            for tag in tags {
                let a = oldDate(tag, Date(timeIntervalSinceReferenceDate: from), Date(timeIntervalSinceReferenceDate: to))
                let b = newDate(tag, Date(timeIntervalSinceReferenceDate: from), Date(timeIntervalSinceReferenceDate: to))
                check(a == b, "date \(tag) future \(future) now \(now) from \(from) to \(to) in \(zone): old \(a) new \(b)")
                dateCases += 1
            }
        }
    }
}
// The control: a day later is another answer, and the comparison sees it.
setNow(Date(timeIntervalSinceReferenceDate: nows[0]))
let control = oldDate(QueryDateFilter.last7Days, Date(), Date())
setNow(Date(timeIntervalSinceReferenceDate: nows[0] + 86_400))
check(control != newDate(QueryDateFilter.last7Days, Date(), Date()), "the control: the comparison sees a different answer")

// The modality choices.
for supports in [false, true] {
    defaults.set(supports, forKey: "SupportQRModalitiesinStudy")
    for modalities in [[], ["CT"], ["CT", "MR"], ["MR", "CT", "PT", "SR"], ["", "US"]] as [[String]] {
        let a = describe(filter: OldQuery.oldModality(modalities) as AnyObject?)
        let b = describe(filter: QueryController().getModalityQueryFilter(modalities))
        check(a == b, "modality \(modalities) \(supports): old \(a) new \(b)")
    }
}

// The merges.
final class Row: NSObject {
    @objc var uid: String?
    @objc var numberImages: NSNumber?
    init(_ uid: String?, _ images: Int?) { self.uid = uid; numberImages = images.map { NSNumber(value: $0) } }
}
var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
func random(_ bound: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(bound)) }
func rows(_ count: Int) -> [Row] {
    (0..<count).map { _ in Row(random(6) == 0 ? nil : "1.2.\(random(8))", random(5) == 0 ? nil : random(4)) }
}
for _ in 0..<400 {
    let start = rows(random(6)), found = rows(random(8))
    let oldStudies = NSMutableArray(array: start), newStudies = NSMutableArray(array: start)
    OldMerge(found, oldStudies)
    QueryController.mergeStudies(found, into: newStudies)
    check(oldStudies.isEqual(to: newStudies as! [Any]), "mergeStudies")
    let oldAnswers = NSMutableArray(array: start), newAnswers = NSMutableArray(array: start)
    OldAnswers(found, oldAnswers)
    QueryController.mergeAnswers(found, into: newAnswers)
    check(oldAnswers.isEqual(to: newAnswers as! [Any]), "the answers of one more node")
}

// The filters of a study query.
let preferences = ["allow_qr_accession_number", "allow_qr_description", "allow_qr_comments", "allow_qr_id", "allow_qr_name",
                   "allow_qr_birthdate", "allow_qr_study_date", "allow_qr_modality", "SupportQRModalitiesinStudy", "DICOMQueryAllowFutureQuery"]
let keys = ["AccessionNumber", "accessionNumber", "StudyDescription", "Comments", "StudyID", "studyID", "StudyInstanceUID",
            "studyInstanceUID", "PatientsName", "patientName", "PatientID", "patientID"]
let texts = ["*", "**", "a*", "ab*", "abc*", "*ab*", "abc", "a", "", "DOE^JOHN*", "1.2.3", "**x**", "ÉLODIE*"]
func describeFilters(_ dictionary: [AnyHashable: Any]) -> [String] {
    dictionary.map { "\($0.key)=\(describe($0.value))" }.sorted()
}
setNow(Date(timeIntervalSinceReferenceDate: nows[0]))
for _ in 0..<1500 {
    for name in preferences { defaults.set(random(3) != 0, forKey: name) }
    var filters: [AnyHashable: Any] = [:]
    for key in keys where random(3) == 0 { filters[key] = texts[random(texts.count)] }
    if random(3) == 0 { filters["PatientBirthDate"] = Date(timeIntervalSinceReferenceDate: TimeInterval(random(900_000_000)) - 300_000_000) }
    if random(2) == 0 {
        filters["date"] = NSNumber(value: tags[random(tags.count)])
        filters["fromDate"] = Date(timeIntervalSinceReferenceDate: pickers[random(pickers.count)].0)
        filters["toDate"] = Date(timeIntervalSinceReferenceDate: pickers[random(pickers.count)].1)
    }
    if random(2) == 0 { filters["modality"] = [["CT"], ["CT", "MR"], [], ["*"]][random(4)] }
    let a = describeFilters(OldBuild(filters) ?? [:]), b = describeFilters(QueryController.newBuild(filters))
    check(a == b, "filters \(filters): old \(a) new \(b)")
}

// The fields of the window, as the old switch read them.
let oldFields: [(Int, String?, String, Bool, Bool, Bool)] = [FIELD_ROWS]
for (number, key, preference, trims, star, encoding) in oldFields {
    guard let field = QueryWindowField(rawValue: number) else { check(false, "field \(number) is missing"); continue }
    check(field.key == key, "field \(number) key \(String(describing: field.key)) was \(String(describing: key))")
    check(field.preference == preference, "field \(number) preference \(field.preference) was \(preference)")
    check(field.checksEncoding == encoding, "field \(number) encoding check")
    if field == .patientBirthDate {
        check(field.filterValue(" 2000 ") == nil, "the birth date is no text filter")
        continue
    }
    for typed in [" ab c \n", "   ", "abc", ""] {
        let kept = trims ? typed.trimmingCharacters(in: .whitespacesAndNewlines) : typed
        let wanted: String? = kept.isEmpty ? nil : kept + (star ? "*" : "")
        check(field.filterValue(typed) == wanted, "field \(number) value \(typed.debugDescription): \(String(describing: field.filterValue(typed))) wanted \(String(describing: wanted))")
    }
}
let birthFormats: [Int: String] = [BIRTH_FORMATS]
for tag in -2...2 { check(QueryDateFilter.birthDateFormat(forTag: tag) == birthFormats[tag], "birth date format \(tag)") }
ENUM_CHECKS

print("\(zone): \(dateCases) date choices, \(compared) comparisons, \(failures) different")
exit(failures == 0 ? 0 : 1)
'''.replace('FIELD_ROWS', ', '.join(field_rows)) \
   .replace('BIRTH_FORMATS', ', '.join('%s: "%s"' % item for item in sorted(birth_formats.items()))) \
   .replace('ENUM_CHECKS', '\n'.join(enum_checks))

with tempfile.TemporaryDirectory(prefix='isix-query-rules-') as folder:
    work = Path(folder)
    # The date type and the HorosDateString the old code called, from its
    # revision: they left the application with the DCM framework's date type.
    (work / 'DCM').mkdir()
    for path in ('DCM Framework/DCMCalendarDate.h', 'DCM Framework/DCMCalendarDate.m',
                 'Horos/Sources/Horos.h', 'Horos/Sources/Horos.m'):
        (work / Path(path).name).write_bytes(history_reference.show(reference, path))
    (work / 'DCM/DCMCalendarDate.h').symlink_to(work / 'DCMCalendarDate.h')
    (work / 'DCM.h').write_text('#import <Foundation/Foundation.h>\n#define DCMDEBUG 0\n#import "DCMCalendarDate.h"\n')
    (work / 'Old.h').write_text(OLD_HEADER)
    (work / 'Old.m').write_text(OLD_SOURCE)
    (work / 'Bridge.h').write_text('#import "DCMCalendarDate.h"\n#import "Horos.h"\n#import "Old.h"\n')
    (work / 'Harness.swift').write_text(HARNESS)
    (work / 'main.swift').write_text(DRIVER)
    build_module('IsiXStorage', work / 'modules')
    build_module('IsiXDICOMNetwork', work / 'modules')
    # The current code's DICOM date type.
    build_module('IsiXImaging', work / 'modules')
    build_module('IsiXDICOMFile', work / 'modules', ['-I', str(work / 'modules')])
    flags = ['-I', str(work), '-I', str(work / 'modules'), '-I', str(ROOT / 'Horos/Sources')]
    objects = []
    for source in (work / 'Old.m', work / 'DCMCalendarDate.m', work / 'Horos.m',
                   ROOT / 'Horos/Sources/DicomStudy+CAPI.m'):
        obj = work / (source.stem + '.o')
        built = subprocess.run(['xcrun', 'clang', '-c', '-DHOROS_BRIDGING_HEADER=1', '-Wno-deprecated-declarations', *flags,
                                str(source), '-o', str(obj)], capture_output=True, text=True)
        if built.returncode:
            print(built.stderr[-4000:])
            print('FAIL: %s does not compile' % source.name)
            sys.exit(1)
        objects.append(str(obj))
    built = subprocess.run(['xcrun', 'swiftc', *flags, '-Xcc', '-DHOROS_BRIDGING_HEADER=1', '-import-objc-header', str(work / 'Bridge.h'),
                            str(ROOT / 'Horos/Sources/QueryFilter.swift'), str(work / 'Harness.swift'), str(work / 'main.swift'),
                            *objects, *link_flags('IsiXStorage', work / 'modules'), *link_flags('IsiXDICOMNetwork', work / 'modules'),
                            *link_flags('IsiXDICOMFile', work / 'modules'), *link_flags('IsiXImaging', work / 'modules'),
                            '-o', str(work / 'test')], capture_output=True, text=True)
    if built.returncode:
        print(built.stderr[-6000:])
        print('FAIL: the harness does not compile')
        sys.exit(1)
    for zone in ('America/Sao_Paulo', 'America/New_York', 'Asia/Tokyo', 'UTC'):
        try:
            run = subprocess.run([str(work / 'test')], capture_output=True, text=True, timeout=300,
                                 env={'TZ': zone, 'PATH': '/usr/bin:/bin'})
        except subprocess.TimeoutExpired:
            print('FAIL: the comparison did not end within 300 s in ' + zone)
            sys.exit(1)
        print(run.stdout.strip())
        if run.returncode:
            print('FAIL: the Query window rules differ from the old QueryController in ' + zone)
            sys.exit(1)
print('PASS: date and time filters, modality filter, result merges, study query filters, the fields and the date codes '
      'give what the Objective-C++ QueryController gave')
