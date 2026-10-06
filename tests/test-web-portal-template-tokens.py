#!/usr/bin/env python3
"""The portal's templates survive malformed tokens and distant studies.

- `%%` is an empty token: -evaluateTokens: read its first character and
  raised. It is not a token now, and stays in the page as it is.
- An IF or a FOREACH without its parts (`%IF%`, `%IF:%`, `%FOREACH%`,
  `%FOREACH:list%`), an IF operand that is a lone `"`, and a FOREACH that is
  not a block raised on the missing part, on the first character of an empty
  condition, on a negative range, or on -appendString: nil. An empty condition
  is not satisfied; such a FOREACH lists nothing.
- A FOREACH over what is not a collection sent it
  -countByEnumeratingWithState:objects:count: and raised. It lists nothing.
- With PACS On Demand, the other studies of a patient are cached as
  `[otherStudies valueForKey:@"objectID"]`, which raised on the first distant
  (DCMTK) study; the transformer answered nil and the page lost the whole list,
  local studies included. The cache now keeps the IDs of the local studies and
  the distant studies themselves (+[WebPortalUser cachedArrayForArray:]),
  which -objectsWithIDs: answers as they are; a patient without an ID is not
  cached, and a failure to cache no longer loses the list.
- The log said "WebPortalRosponse".

The template engine (WebPortalResponse's token evaluation and its helpers) and
-[DicomStudyTransformer otherStudiesForStudy:] are taken as they are from
WebPortalResponse.swift, with +cachedArrayForArray: from WebPortalUser.swift,
and compiled with the real HorosObjCException and stubs for the application
classes around them. Every template is evaluated on its own, so an exception
shows as that case failing.

`<git revision>` as an optional argument reads the sources from that revision,
the negative control.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def read(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode()
    return (root / path).read_text()


def between(text, start, end, name):
    at = text.find(start)
    stop = text.find(end, at + len(start)) if at >= 0 else -1
    if at < 0 or stop < 0:
        print(f'FAIL: {name} is not where the test expects it')
        sys.exit(1)
    return text[at:stop]


response = read('Horos/Sources/WebPortalResponse.swift')
connection = read('Horos/Sources/WebPortalConnection.swift')
parameter_helpers = '\n'.join(between(connection, signature, '\n}\n', signature) + '\n}\n' for signature in (
    'private func messagePercentEscaped(', 'private func setObject(', 'private func addObject('))
parameter_codec = between(connection, '    @objc(FormatParams:)', '    @objc(alive:)', 'portal parameter codec')
portal_data = read('Horos/Sources/WebPortalConnection+Data.swift')
destination_decode = between(portal_data, '                let dicomDestinationArray =',
                             '                if (dicomDestinationArray', 'nested destination decoder').replace(
                                 'self.stringParameter("dicomDestination")', 'formDestination')
user = read('Horos/Sources/WebPortalUser.swift')
# The lock is an NSRecursiveLock; an earlier revision names it otherwise.
helpers_start = ('/// The former `@synchronized(WebPortalResponseLock)`' if '/// The former `@synchronized(WebPortalResponseLock)`' in response
                 else '/// The object of the former `@synchronized(WebPortalResponseLock)`.')
helpers = between(response, helpers_start,
                  '// MARK: - WebPortalResponse', 'the template helpers')
engine = between(response, '    /// Not in the header; kept under its former selector.\n    @objc(object:valueForKeyPath:context:)',
                 '\n}\n\n// MARK: - WebPortalProxy', 'the template engine')
other_studies = between(response, '    private func otherStudies(for study: DicomStudy?, wpc: WebPortalConnection?)',
                        '\n    }\n', 'otherStudies(for:wpc:)') + '\n    }\n'
cached_array = between(user, '    @objc(cachedArrayForArray:)', '\n    }\n', 'cachedArray(for:)') + '\n    }\n'
user_helpers = '\n'.join(between(user, signature, '\n}\n', signature) + '\n}\n' for signature in (
    'fileprivate func webPortalUserReplace(', 'fileprivate func webPortalUserSend('))

BRIDGING = '#import <Foundation/Foundation.h>\n#import "HorosObjCException.h"\n'

ENGINE_MAIN = r'''
import CoreData
import Foundation

class WebPortalUser: NSObject {}
class DicomStudy: NSObject {}
class DicomSeries: NSObject {}
class WebPortalProxyObjectTransformer: NSObject {
    required override init() { super.init() }
    class func create() -> Any! { self.init() }
}
final class StringTransformer: WebPortalProxyObjectTransformer {}
final class DateTransformer: WebPortalProxyObjectTransformer {}
final class WebPortalUserTransformer: WebPortalProxyObjectTransformer {}
final class DicomStudyTransformer: WebPortalProxyObjectTransformer {}
final class DicomSeriesTransformer: WebPortalProxyObjectTransformer {}
/// The proxy answers the object's own values; the transformers are not under test.
final class WebPortalProxy: NSObject {
    let object: NSObject?
    init(_ o: NSObject?) { object = o }
    class func create(with o: NSObject!, transformer t: Any!) -> Any! { WebPortalProxy(o) }
    func valueCatchingException(forKey key: String?, context: Any?) -> (AnyObject?, NSException?) {
        var value: AnyObject?
        do {
            try HorosObjCException.perform { value = self.object?.value(forKey: key ?? "") as AnyObject? }
        } catch {
            return (nil, (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException)
        }
        return (value, nil)
    }
}

HELPERS

// NSString+N2, as the engine uses it.
extension NSString {
    func xmlEscapedString() -> NSString { self }
    func components(withLength length: Int) -> NSArray { [self] }
}

final class WebPortalResponse: NSObject {
ENGINE
}

PARAMETER_HELPERS
final class ParameterCodec: NSObject {
PARAMETER_CODEC
}
let special = "space é 日本 +%&=/?:#[]@!$'()*,;"
let formatted = ParameterCodec.FormatParams(["key +&=": special, "repeat": ["first+", "second%"], "empty": ""])
let decoded = ParameterCodec.ExtractParams(formatted)!
precondition(decoded["key +&="] as? String == special && decoded["empty"] as? String == "")
precondition(decoded["repeat"] as? [String] == ["first+", "second%"])
let raw = ParameterCodec.ExtractParams("a=one=two&plus=a+b&literal=a%2Bb&percent=%2520&missing&empty=")!
precondition(raw["a"] as? String == "one=two" && raw["plus"] as? String == "a b")
precondition(raw["literal"] as? String == "a+b" && raw["percent"] as? String == "%20")
precondition(raw["missing"] is NSNull && raw["empty"] as? String == "")
precondition(ParameterCodec.ExtractParams("%GG=value")!.count == 0)
var invalidRaised = false
do { try HorosObjCException.perform { _ = ParameterCodec.ExtractParams("a=%GG") } }
catch { invalidRaised = true }
precondition(invalidRaised)
let destination = "fe80%3A%3A1:104:AE%20%2B%2520:1.2.840"
let outer = ParameterCodec.FormatParams(["dicomDestination": destination])
let formDestination = ParameterCodec.ExtractParams(outer)!["dicomDestination"] as? String
DESTINATION_DECODE
precondition(dicomDestinationArray as? [String] == ["fe80::1", "104", "AE +%20", "1.2.840"])
print("PASS: actual portal FormatParams/ExtractParams preserve reserved characters, repeated/empty fields, form plus and one decoding layer")
let tokens: NSDictionary = ["name": "Ann", "special": special, "list": [1, 2], "flag": true, "off": false, "count": 2]
let cases: [(String, String)] = [
    ("100%% sure %name%", "100%% sure Ann"),
    ("<%%>", "<%%>"),
    ("a%IF%b", "ab"),
    ("a%[IF:%yes%]IF:%b", "ab"),
    ("a%[IF%yes%ELSE:%no%]IF%b", "anob"),
    ("a%[IF:\"==x%yes%]IF:\"==x%b", "ab"),
    ("a%[FOREACH%x%]FOREACH%b", "ab"),
    ("a%[FOREACH:list%x%]FOREACH:list%b", "ab"),
    ("<%FOREACH:list:i%>", "<>"),
    ("<%[FOREACH:name:i%[%i%]%]FOREACH:name:i%>", "<>"),
    // What well-formed templates do is unchanged.
    ("<%[FOREACH:list:i%(%i%)%]FOREACH:list:i%>", "<(1)(2)>"),
    ("%[IF:flag%Y%ELSE:flag%N%]IF:flag%%[IF:off%Y%ELSE:off%N%]IF:off%%[IF:!off%!%]IF:!off%", "YN!"),
    ("%[IF:count>1%many%]IF:count>1%%[IF:name==\"Ann\"%=%]IF:name==\"Ann\"%", "many="),
    ("%X:name%%U:name% 50% off", "AnnAnn 50% off"),
    ("%U:special%", "space%20%C3%A9%20%E6%97%A5%E6%9C%AC%20%2B%25%26%3D%2F%3F%3A%23%5B%5D%40%21%24%27%28%29%2A%2C%3B"),
    ("%URLENC:special%", "space%20%C3%A9%20%E6%97%A5%E6%9C%AC%20%2B%25%26%3D%2F%3F%3A%23%5B%5D%40%21%24%27%28%29%2A%2C%3B"),
]
for (template, expected) in cases {
    let string = NSMutableString(string: template)
    var raised: String? = nil
    do {
        try HorosObjCException.perform {
            WebPortalResponse.mutableString(string, evaluateTokensWith: tokens, context: nil)
        }
    } catch {
        let e = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
        raised = "\(e?.name.rawValue ?? "?"): \(e?.reason ?? "")"
    }
    if let raised {
        print("case \(template) => raised \(raised)")
    } else if (string as String) != expected {
        print("case \(template) => \(string), expected \(expected)")
    } else {
        print("ok \(template)")
    }
}
'''.replace('DESTINATION_DECODE', destination_decode).replace('PARAMETER_HELPERS', parameter_helpers).replace('PARAMETER_CODEC', parameter_codec).replace('HELPERS', helpers).replace('ENGINE', engine)

# The cache is made once, where it was a lazy optional before.
cache_declaration = ('    private static let otherStudiesForThisPatientCache = NSMutableDictionary()'
                     if 'static let otherStudiesForThisPatientCache' in response
                     else '    private static var otherStudiesForThisPatientCache: NSMutableDictionary?')
CACHE_MAIN = r'''
import CoreData
import Foundation

HELPERS

func _N2LogExceptionImpl(_ e: NSException, _ log: Bool, _ where_: String) {
    print("logged: \(e.name.rawValue)")
}

@objc(DCMTKStudyQueryNode)
final class DCMTKStudyQueryNode: NSObject {
    @objc let name: NSString
    @objc let studyInstanceUID: NSString
    @objc let date: NSDate
    @objc let noFiles: NSNumber
    @objc let rawNoFiles: NSNumber
    init(_ name: NSString, _ uid: NSString, _ date: Double, _ files: Int) {
        self.name = name; studyInstanceUID = uid; self.date = NSDate(timeIntervalSince1970: date)
        noFiles = NSNumber(value: files); rawNoFiles = noFiles
    }
}
/// A local study: a managed object has an objectID; this one's is its name.
final class DicomStudy: NSObject {
    @objc let name: NSString
    @objc let patientID: String?
    @objc let studyInstanceUID: NSString
    @objc let date: NSDate
    @objc let noFiles: NSNumber
    @objc let rawNoFiles: NSNumber
    @objc var objectID: NSString { name }
    init(_ name: NSString, _ patientID: String?, _ uid: NSString, _ date: Double) {
        self.name = name; self.patientID = patientID; studyInstanceUID = uid
        self.date = NSDate(timeIntervalSince1970: date); noFiles = 2; rawNoFiles = 2
    }
}
var localStudies: [DicomStudy] = []
var distantStudies: [DCMTKStudyQueryNode] = []
var fetches = 0

final class WebPortalConnection: NSObject { var user: WebPortalUser? }
final class WebPortalUser: NSObject {
    class func studies(for user: WebPortalUser!, predicate: NSPredicate!, sortBy sortValue: String!) -> [Any]! {
        fetches += 1
        return localStudies
    }
CACHED_ARRAY
}
USER_HELPERS
final class BrowserController: NSObject {
    class func comparativeServers() -> [Any]! { ["PACS"] }
}
final class QueryController: NSObject {
    class func queryStudies(forPatient study: DicomStudy!, usePatientID: Bool, usePatientName: Bool, usePatientBirthDate: Bool, servers: [Any]!, showErrors: Bool) -> [Any]! {
        distantStudies
    }
}
/// -[N2ManagedDatabase objectsWithIDs:]: an ID is looked up, a DCMTKQueryNode
/// is answered as it is, anything else is skipped.
final class DicomDatabase: NSObject {
    func independentDatabase() -> Any! { self }
    func objects(withIDs ids: [Any]!) -> [Any]! {
        (ids ?? []).compactMap { id -> Any? in
            if id is DCMTKStudyQueryNode { return id }
            if let id = id as? NSString { return localStudies.first { $0.name == id } }
            return nil
        }
    }
}
final class WebPortal: NSObject {
    static let shared = WebPortal()
    let dicomDatabase: DicomDatabase? = DicomDatabase()
    class func `default`() -> WebPortal! { shared }
    /// The database of this thread: here the one database.
    func threadDicomDatabase() -> DicomDatabase? { dicomDatabase }
}

final class DicomStudyTransformer: NSObject {
CACHE_DECLARATION
    private static let CACHETIMEOUT: TimeInterval = -30
    private static var pacsOnDemand: Bool { true }
OTHER_STUDIES
    func run(_ study: DicomStudy?) -> String {
        guard let list = otherStudies(for: study, wpc: nil) else { return "nil" }
        return list.map { ($0 as AnyObject).value(forKey: "name") as! String }.joined(separator: ",")
    }
}

let local = DicomStudy("LOCAL", "P1", "1.1", 1_000)
let transformer = DicomStudyTransformer()
localStudies = [local]
distantStudies = [DCMTKStudyQueryNode("DISTANT", "1.2", 2_000, 3)]
print("first: \(transformer.run(local))")
let before = fetches
print("cached: \(transformer.run(local)) fetched: \(fetches - before)")
localStudies = [DicomStudy("NOID", nil, "2.1", 1_000)]
distantStudies = []
print("no patient ID: \(transformer.run(localStudies[0]))")
'''.replace('CACHE_DECLARATION', cache_declaration).replace('CACHED_ARRAY', cached_array).replace('USER_HELPERS', user_helpers).replace('OTHER_STUDIES', other_studies).replace('HELPERS', helpers)


def build_and_run(tmp, name, main):
    p = Path(tmp)
    (p / f'{name}.swift').write_text(main)
    build = subprocess.run(['xcrun', 'swiftc', '-module-name', 'Horos', '-import-objc-header', str(p / 'bridging.h'),
                            '-Xcc', '-I' + str(root / 'Horos/Sources'), str(p / f'{name}.swift'),
                            str(p / 'HorosObjCException.o'), '-o', str(p / name)], capture_output=True, text=True)
    if build.returncode != 0:
        print(build.stderr[-4000:])
        print(f'FAIL: the {name} harness did not compile')
        sys.exit(1)
    run = subprocess.run([str(p / name)], capture_output=True, text=True, timeout=120)
    print(run.stdout.strip())
    if run.returncode != 0:
        print(run.stderr[-2000:])
    return run


with tempfile.TemporaryDirectory(prefix='horos-portal-tokens-') as tmp:
    (Path(tmp) / 'bridging.h').write_text(BRIDGING)
    subprocess.run(['xcrun', 'clang', '-c', '-fno-objc-arc', '-I', str(root / 'Horos/Sources'),
                    str(root / 'Horos/Sources/HorosObjCException.m'), '-o', str(Path(tmp) / 'HorosObjCException.o')],
                   check=True)
    engine_run = build_and_run(tmp, 'engine', ENGINE_MAIN)
    cache_run = build_and_run(tmp, 'cache', CACHE_MAIN)

failures = []
if engine_run.returncode != 0:
    failures.append('the template harness crashed')
for line in re.findall(r'^case (.*)$', engine_run.stdout, re.M):
    failures.append(f'template {line}')
if len(re.findall(r'^ok ', engine_run.stdout, re.M)) != 16:
    failures.append('not every template was evaluated')

expected = {'first': 'DISTANT,LOCAL', 'cached': 'DISTANT,LOCAL fetched: 0', 'no patient ID': 'NOID'}
for key, value in expected.items():
    found = re.search(rf'^{key}: (.*)$', cache_run.stdout, re.M)
    if not found or found.group(1) != value:
        failures.append(f'other studies {key}: {found.group(1) if found else "nothing"}, expected {value}')

if 'WebPortalRosponse' in response:
    failures.append('the log still says WebPortalRosponse')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: malformed IF/FOREACH tokens and %% render instead of raising; distant studies are cached and '
      'listed with the local ones; the log names WebPortalResponse')
