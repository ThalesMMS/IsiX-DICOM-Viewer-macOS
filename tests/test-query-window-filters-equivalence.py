#!/usr/bin/env python3
"""The Query window asks each node for what it asked before its filters were typed.

The window used to read its filters from the preset dictionary by key, on the
thread of the query, and give them one by one to the query manager
(-[QueryController addFilter:of:from:to:showError:] and the loop of
queryAnswers:preset:showing: in QueryController+Query.swift). They are now a
value, IsiXDICOMNetwork's QueryWindowFilters, that QueryWindowFilters.query
turns into the C-FIND's filters, and that a query thread receives in a
QueryWindowRun made on the main thread (queryRun and addFilters of the same
file). This compares the two, from the last revision with the dictionary code:

- the old loop and the members it calls (the field switch, the date and
  modality filters, the reading of numbers) are compiled as they were; the new
  queryRun, customFieldKeyword and addFilters are compiled from the current
  sources. Both run against the same query manager, whose addFilter records
  each call and stores the filter as QueryArrayController does (its addFilter
  is compiled from the same revision), with "now" fixed;
- both receive the same preset dictionaries, as the window writes them and as
  the automatic query's instance shown in the window hands them back (on the
  new side through AutoQueryInstance.queryFilters and queryRun(dated:), as
  prepareAutoQueryRun makes its run), under random allow_qr_* preferences,
  character sets and date choices, in several time zones and at instants
  around midnight;
- for each case both print the filters given, in order, the filters the
  manager keeps, whether the query asks for something, the other spellings of
  the name, and the C-FIND identifier those filters make (the attribute and
  bytes of each, as the query node writes them). The outputs must be the same.

The query with the window's encoding alert (showError on the main thread) is
not run: the alert is modal. An instance of the automatic query that is not
the one shown is not compared: it used to query with the window's date
pickers too, and now queries with the dates it saved, by design (the module
test AutoQueryInstanceTests covers two such instances). A control checks that the comparison sees a
difference when there is one.

Exits 2 when the history does not reach a revision with the dictionary code.
"""
import private_tmpdir  # noqa: F401
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import harness_defaults  # noqa: E402
import history_reference  # noqa: E402
from isix_modules import build_module, link_flags  # noqa: E402
import process_graph_stand_in  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
QUERY = 'Horos/Sources/QueryController+Query.swift'
MARKER = 'nonisolated func queryAnswers(_ showError: Bool, preset: [String: Any], showing: Bool) -> [Any] {'


def has_marker(revision):
    try:
        return MARKER in history_reference.show(revision, QUERY).decode()
    except subprocess.CalledProcessError:
        return False


reference = 'HEAD' if has_marker('HEAD') else history_reference.before_text_removed(QUERY, MARKER)
if reference is None or not has_marker(reference):
    print('skipped: the history does not reach a revision with the dictionary filters of ' + QUERY)
    sys.exit(2)


def old(path):
    return history_reference.show(reference, path).decode()


def current(path):
    return (ROOT / path).read_text()


def braced_end(text, start):
    """The index just past the block that opens at the first brace at or after `start`."""
    depth = 0
    for index in range(text.index('{', start), len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return index + 1
    raise ValueError(start)


def member(text, signature):
    """A Swift member from its signature to its closing brace."""
    at = text.index(signature)
    assert text.count(signature) == 1, signature
    return text[at:braced_end(text, at)]


def fixed_now(code, count):
    assert code.count('now: Date(),') == count, code
    return code.replace('now: Date(),', 'now: QueryController.testNow,')


# --- The old window ---------------------------------------------------------

old_query, old_filters, old_core = old(QUERY), old('Horos/Sources/QueryController+Filters.swift'), old('Horos/Sources/QueryController.swift')
loop_start = old_query.index('                    // add filters as needed\n')
loop_end = old_query.index('                    if queryItem {', loop_start)
old_loop = old_query[loop_start:loop_end]
for needed in ('self.addFilter(of: field, from: instance, to: manager, showError: showError)', 'dates.from, to: dates.to',
               'self.getModalityQueryFilter(instance.object(forKey: "modalityStrings")'):
    assert needed in old_loop, needed
OLD_CONTROLLER = '''
final class QueryController: NSObject {
    nonisolated(unsafe) static var testNow = Date()
    var dicomFields: [CIADICOMField] = Fixture.fields
    var currentQueryKey: String?
''' + '\n'.join((member(old_core, 'nonisolated static func int32('),
                 member(old_filters, 'nonisolated static func double('),
                 fixed_now(member(old_filters, 'nonisolated static func dateAndTimeQueryFilters('), 1),
                 member(old_filters, 'public nonisolated func getModalityQueryFilter('),
                 member(old_query, 'private nonisolated func addFilter(of field: QueryWindowField'),
                 member(old_query, 'private nonisolated static func presetKey(of field:'))) + '''
    func caseFilters(_ preset: [String: Any], from: Date, to: Date, manager: QueryArrayController,
                     shownInstance: Bool) -> (Bool, [String]) {
        let instance = NSMutableDictionary(dictionary: preset)
        let dates: (from: Date, to: Date) = (from, to)
        let showError = false
        var atLeastOneSource = false
''' + old_loop + '''
        _ = atLeastOneSource
        return (queryItem, nameAlternatives)
    }
}
'''

# --- The new window ---------------------------------------------------------

new_query, new_core = current(QUERY), current('Horos/Sources/QueryController.swift')
assert MARKER not in new_query or reference == 'HEAD'
# The run of the instance shown, as prepareAutoQueryRun makes it; the harness
# below makes it the same way.
SHOWN_RUN = ('let windowDates = (from: fromDate?.dateValue ?? Date(), to: toDate?.dateValue ?? Date())',
             'let run = queryRun(dated: current.queryFilters(windowDates: windowDates, shown: shownAutoQRInstance?.id == current.id))')
prepare = member(current('Horos/Sources/QueryController+AutoQuery.swift'), 'func prepareAutoQueryRun(of instance: AutoQueryInstance)')
for line in SHOWN_RUN:
    assert line in prepare, 'prepareAutoQueryRun no longer makes its run with: ' + line
NEW_CONTROLLER = '''
final class Picker { var dateValue: Date; init(_ date: Date) { dateValue = date } }
final class QueryController: NSObject {
    nonisolated(unsafe) static var testNow = Date()
    var dicomFields: [CIADICOMField] = Fixture.fields
    var sourcesArray = NSMutableArray()
    var queryArrayPrefs = "SavedQueryArray"
    var fromDate: Picker?
    var toDate: Picker?
    var preferences: UserDefaults { UserDefaults.standard }
    func currentSources() -> [QueryWindowSource] { [] }
''' + '\n'.join((member(new_query, 'func queryRun(_ filters: QueryWindowFilters) -> QueryWindowRun {'),
                 member(new_query, 'func queryRun(dated filters: QueryWindowFilters) -> QueryWindowRun {'),
                 member(new_query, 'func customFieldKeyword(forAttribute title: String?) -> String? {'),
                 fixed_now(member(new_query, 'nonisolated func addFilters(of run: QueryWindowRun, to manager: QueryArrayController'), 1))) + '''
    func caseFilters(_ preset: [String: Any], from: Date, to: Date, manager: QueryArrayController,
                     shownInstance: Bool) -> (Bool, [String]) {
        fromDate = Picker(from)
        toDate = Picker(to)
        if shownInstance, let current = AutoQueryInstance(propertyList: preset) {
            ''' + SHOWN_RUN[0] + '''
            ''' + SHOWN_RUN[1].replace('shownAutoQRInstance?.id == current.id', 'true') + '''
            return addFilters(of: run, to: manager, showError: false)
        }
        return addFilters(of: queryRun(QueryWindowFilters(propertyList: preset)), to: manager, showError: false)
    }
}
'''

# --- What both run against --------------------------------------------------

manager_store = member(old('Horos/Sources/QueryArrayController.swift'), 'public func addFilter(_ filter: Any!, forDescription description: String!)')
manager_store = manager_store.replace('public func addFilter(', 'func storeFilter(', 1)
query_filter = current('Horos/Sources/QueryFilter.swift')
assert query_filter.count('DICOMCalendarDate.string(from: Date(), calendarFormat: "%Y%m%d")') == 1
query_filter = query_filter.replace('DICOMCalendarDate.string(from: Date(), calendarFormat: "%Y%m%d")',
                                    'DICOMCalendarDate.string(from: QueryController.testNow, calendarFormat: "%Y%m%d")')

COMMON = r'''
import Foundation
import IsiXDICOMNetwork
import IsiXDICOMFile

/// The custom field's menu: three attributes with a keyword, one without.
enum Fixture {
    static let fields = [CIADICOMField("Body Part Examined", 0x0018, 0x0015), CIADICOMField("Station Name", 0x0008, 0x1010),
                         CIADICOMField("Operators Name", 0x0008, 0x1070), CIADICOMField("Private Thing", 0x0009, 0x0010)]
    static let keywords: [UInt32: String] = [0x0018_0015: "BodyPartExamined", 0x0008_1010: "StationName", 0x0008_1070: "OperatorsName"]
}
final class CIADICOMField: NSObject {
    let name: String, groupNumber: Int32, elementNumber: Int32
    init(_ name: String, _ group: Int32, _ element: Int32) { self.name = name; groupNumber = group; elementNumber = element }
    func title() -> String? { name }
    func group() -> Int32 { groupNumber }
    func element() -> Int32 { elementNumber }
}
struct NoKeyword: Error {}
enum IsiXDCMTKDictionary {
    static func keyword(forTag tag: UInt32) throws -> String {
        guard let keyword = Fixture.keywords[tag] else { throw NoKeyword() }
        return keyword
    }
}
enum QueryLog {
    static func term(key: String?, value: Any?) -> String { "\(key ?? "?")=\(value.map { "\($0)" } ?? "nil")" }
}
let HorosAlertDefaultResponse = 1
enum HorosAlertPanel {
    static func runCritical(title: String, message: String, defaultButton: String?, alternateButton: String?, otherButton: String?) -> Int {
        fatalError("no alert in the harness")
    }
}
extension NSString {
    class func encoding(forDICOMCharacterSet characterSet: String!) -> UInt {
        DICOMCharacterSet.encoding(forDICOMCharacterSet: characterSet)
    }
}
/// The query manager: records each filter it is given, and keeps it as
/// QueryArrayController does.
final class QueryArrayController: NSObject {
    var filtersValue: NSMutableDictionary? = NSMutableDictionary()
    var calls: [String] = []
    func addFilter(_ filter: Any!, forDescription description: String!) {
        calls.append("\(description ?? "nil")=\(filter.map { "\($0)" } ?? "nil")")
        storeFilter(filter, forDescription: description)
    }
''' + manager_store + '''
}
'''

DRIVER = harness_defaults.SWIFT + r'''
import Foundation
import IsiXDICOMNetwork
import IsiXDICOMFile

var seed: UInt64 = 0x2545_F491_4F6C_DD1D
func random(_ bound: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(bound)) }
func pick<T>(_ values: [T]) -> T { values[random(values.count)] }

/// The identifier the filters make: each attribute and its bytes, as the query node writes them.
func identifier(_ filters: NSDictionary, characterSet: String?) -> [String] {
    let encoding = String.Encoding(rawValue: DICOMCharacterSet.encoding(forDICOMCharacterSet: characterSet))
    func bytes(_ text: String?, _ encoding: String.Encoding) -> String {
        guard let text else { return "nil" }
        guard let characters = text.cString(using: encoding) else { return "unwritable" }
        return characters.prefix { $0 != 0 }.map { String(format: "%02x", UInt8(bitPattern: $0)) }.joined()
    }
    var elements: [String] = []
    for case let (key as String, value) in filters {
        switch QueryFilterAttribute.named(key) {
        case .text(let tag)?:
            elements.append("\(tag) \(bytes(value as? String, encoding))")
        case .dateRange(let tag)?:
            elements.append("\(tag) \(bytes((value as? DICOMCalendarDate)?.queryString(), .isoLatin1))")
        case nil:
            elements.append("keyword \(key) \(bytes(value as? String, encoding))")
        }
    }
    return elements.sorted()
}

func describe(_ value: Any) -> String {
    if let date = value as? DICOMCalendarDate { return date.isQuery() ? "query \(date.queryString() ?? "")" : "date \(date.timeIntervalSinceReferenceDate)" }
    if let text = value as? String { return "text \(text)" }
    return "\(type(of: value as AnyObject)) \(value)"
}

let defaults = UserDefaults.standard
let fieldPreferences = ["allow_qr_name", "allow_qr_id", "allow_qr_accession_number", "allow_qr_birthdate", "allow_qr_description",
                        "allow_qr_referring_physician", "allow_qr_comments", "allow_qr_institution", "allow_qr_custom_dicom_field",
                        "allow_qr_status"]
let characterSets: [String?] = [nil, "ISO_IR 100", "ISO_IR 192", "ISO_IR 6", "ISO_IR 144"]
let texts: [String?] = [nil, "", "   ", "doe", " Doe^John ", "élodie*", "12*", "A1", "chest\n", "*", "ab", "王", "Ñandú^José"]
let textKeys = ["searchFieldName", "searchFieldRefPhysician", "searchInstitutionName", "searchFieldID", "searchFieldAN",
                "searchFieldStudyDescription", "searchFieldComments", "searchCustomField"]
let tags: [Int32] = Array(0...16) + [100, 101, 124, 199, 200, 201, 230, 299, 300, -1]
let nows: [TimeInterval] = [783_650_000, 783_651_599.75, 731_746_800, 752_306_399, 788_918_399.999]
let pickers: [TimeInterval] = [783_000_000, 783_600_000, 783_561_600, 731_746_799.5, -86_400]
let modalities: [Any?] = [nil, [String](), ["CT"], ["CT", "MR"], ["", "US"], "1 0 2 1 "]

let controller = QueryController()
var cases = 0, asking = 0, withDates = 0, withModality = 0
var fieldsSent = Set<String>()
for _ in 0..<1200 {
    for name in fieldPreferences { defaults.set(random(4) != 0, forKey: name) }
    for name in ["allow_qr_study_date", "allow_qr_modality", "SupportQRModalitiesinStudy", "DICOMQueryAllowFutureQuery"] {
        defaults.set(random(2) == 0, forKey: name)
    }
    let characterSet = pick(characterSets)
    if let characterSet { defaults.set(characterSet, forKey: "STRINGENCODING") } else { defaults.removeObject(forKey: "STRINGENCODING") }

    var preset: [String: Any] = [:]
    preset["PatientModeMatrix"] = random(5) == 0 ? pick([NSNumber(value: 10), NSNumber(value: -1), "2" as NSString, "8" as NSString])
                                                 : NSNumber(value: random(10))
    for key in textKeys { if let text = pick(texts) { preset[key] = text } }
    if random(4) != 0 { preset["searchStatus"] = random(3) == 0 ? "5" as NSString : NSNumber(value: random(4)) }
    if random(5) != 0 { preset["searchCustomFieldDICOM"] = pick(["Body Part Examined", "Station Name", "Private Thing", "Gone"]) }
    preset["birthdateFilterMatrix"] = random(4) == 0 ? "1" as NSString : NSNumber(value: random(5) - 2)
    preset["searchBirth"] = NSNumber(value: Double(random(900_000_000)) - 300_000_000.25)
    preset["dateFilterMatrix"] = NSNumber(value: pick(tags))
    let modality = pick(modalities)
    if let titles = modality as? [String] {
        preset["modalityStrings"] = titles
    } else if let former = modality as? String {
        preset["modalityFilterMatrixString"] = former
    }
    preset["fromDate"] = NSNumber(value: pick(pickers))
    preset["DICOMNodes"] = ["pacs:104"]
    let from = Date(timeIntervalSinceReferenceDate: pick(pickers)), to = Date(timeIntervalSinceReferenceDate: pick(pickers))
    QueryController.testNow = Date(timeIntervalSinceReferenceDate: pick(nows))

    // As the window hands its filters over, and as an automatic query's
    // instance hands them back.
    for (given, shownInstance) in [(preset, false), (AutoQueryInstance(propertyList: preset)?.propertyList ?? [:], true)] {
        let manager = QueryArrayController()
        let (asks, alternatives) = controller.caseFilters(given, from: from, to: to, manager: manager, shownInstance: shownInstance)
        let kept = (manager.filtersValue ?? [:]).map { "\($0.key)=\(describe($0.value))" }.sorted()
        print("case \(cases): calls \(manager.calls) kept \(kept) asks \(asks) alternatives \(alternatives)")
        print("case \(cases): identifier \(identifier(manager.filtersValue ?? [:], characterSet: defaults.string(forKey: "STRINGENCODING")))")
        cases += 1
        if asks { asking += 1 }
        if manager.calls.contains(where: { $0.hasPrefix("StudyDate=") }) { withDates += 1 }
        if manager.calls.contains(where: { $0.hasPrefix("Modality") }) { withModality += 1 }
        for call in manager.calls { fieldsSent.insert(String(call.prefix { $0 != "=" })) }
    }
}
print("summary: \(cases) cases, \(asking) asking, \(withDates) with a study date, \(withModality) with modalities, keys \(fieldsSent.sorted())")
'''

with tempfile.TemporaryDirectory(prefix='isix-query-filters-') as folder:
    work = Path(folder)
    build_module('IsiXDICOMNetwork', work / 'modules')
    build_module('IsiXImaging', work / 'modules')
    build_module('IsiXDICOMFile', work / 'modules', ['-I', str(work / 'modules')])
    (work / 'Common.swift').write_text(COMMON)
    (work / 'QueryFilter.swift').write_text(query_filter)
    (work / 'PatientNameMatching.swift').write_text(current('Horos/Sources/PatientNameMatching.swift'))
    (work / 'main.swift').write_text(DRIVER)
    # QueryFilter reads its preferences from PreferencesSource.
    graph = process_graph_stand_in.source(work)
    outputs = {}
    by_zone = {}
    for side, controller in (('old', OLD_CONTROLLER), ('new', NEW_CONTROLLER)):
        (work / side).mkdir()
        (work / side / 'Controller.swift').write_text('import Foundation\nimport IsiXDICOMNetwork\nimport IsiXDICOMFile\n' + controller)
        built = subprocess.run(['xcrun', 'swiftc', '-I', str(work / 'modules'),
                                str(work / 'Common.swift'), str(work / 'QueryFilter.swift'), str(work / 'PatientNameMatching.swift'), str(graph),
                                str(work / side / 'Controller.swift'), str(work / 'main.swift'),
                                *link_flags('IsiXDICOMNetwork', work / 'modules'), *link_flags('IsiXDICOMFile', work / 'modules'),
                                *link_flags('IsiXImaging', work / 'modules'), '-o', str(work / side / 'test')],
                               capture_output=True, text=True)
        if built.returncode:
            print(built.stderr[-6000:])
            print('FAIL: the %s harness does not compile' % side)
            sys.exit(1)
    for zone in ('America/Sao_Paulo', 'Asia/Tokyo', 'UTC', 'America/New_York'):
        for side in ('old', 'new'):
            try:
                run = subprocess.run([str(work / side / 'test')], capture_output=True, text=True, timeout=120,
                                     env={'TZ': zone, 'PATH': '/usr/bin:/bin'})
            except subprocess.TimeoutExpired:
                print('FAIL: the %s harness did not end within 120 s in %s' % (side, zone))
                sys.exit(1)
            if run.returncode:
                print(run.stdout[-2000:] + run.stderr[-2000:])
                print('FAIL: the %s harness stopped in %s' % (side, zone))
                sys.exit(1)
            outputs[side] = run.stdout.splitlines()
        old_lines, new_lines = outputs['old'], outputs['new']
        if old_lines != new_lines:
            different = [(a, b) for a, b in zip(old_lines, new_lines) if a != b]
            for a, b in different[:6]:
                print('old: ' + a[:600])
                print('new: ' + b[:600])
            print('FAIL: %d of %d lines differ in %s' % (len(different) + abs(len(old_lines) - len(new_lines)), len(old_lines), zone))
            sys.exit(1)
        by_zone[zone] = old_lines
        print('%s: %s' % (zone, old_lines[-1]))
    # The control: the same cases on the other side of the date line ask for
    # other days, and the comparison sees it.
    if by_zone['America/Sao_Paulo'] == by_zone['Asia/Tokyo']:
        print('FAIL: the control: the comparison does not see the study dates of another time zone')
        sys.exit(1)
print('PASS: the filters, the identifier, the request for something and the other spellings of the name of every case '
      'are those the dictionary code gave')
