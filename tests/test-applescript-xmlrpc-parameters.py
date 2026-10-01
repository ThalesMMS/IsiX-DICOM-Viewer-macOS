#!/usr/bin/env python3
"""AppleScript "invoke XMLRPC method" with parameters, through Cocoa Scripting.

Builds a small application bundle with the real Horos.sdef, the real
OsiriXScripts command (Scripting_Additions.swift) and the real record
conversion (NSAppleEventDescriptor+N2.swift); only BrowserController,
AppController and the XML-RPC interface are stubs, and the stub records what
the method received. Each case is compiled by AppleScript against the bundle's
dictionary and sent to the running bundle, in its own process, so a case that
kills the process shows as such.

Optional argument: a git revision whose three sources are used instead of the
working tree's (a negative control; before #804 a list item that is not a
record trapped a forced cast and killed the process, and before #812 a key that
is a term, as name, path or URL, was refused with -1708, and before #815 an
'ObjC' descriptor was unarchived whatever classes it held, so the probe's
marker class was instantiated). The expected names of the term keys always
come from the working tree's conversion.
"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
SOURCES = ('Horos/Resources/Horos.sdef', 'Horos/Sources/Scripting_Additions.swift',
           'Nitrogen/Sources/NSAppleEventDescriptor+N2.swift')

STUBS = r'''
import Cocoa

let HorosObjCExceptionKey = "HorosObjCException"
final class HorosObjCException: NSObject {
    static func perform(_ block: () -> Void) throws { block() }
}

final class BrowserController: NSObject {
    static func currentBrowser() -> BrowserController? { nil }
    func addFilesAndFolder(toDatabase: [String]) {}
    @discardableResult func findAndSelectFile(_ path: String?, image: Any?, shouldExpand: Bool) -> Bool { false }
    func importURLs(_ urls: [NSURL], completion: @escaping ([Any]?, String?, Bool) -> Void) {}
    func viewerDICOM(_ sender: Any?) {}
    func delItem(_ sender: Any?) {}
}

var calls: [[String: Any]] = []
var markerInstantiated = false

/// A class outside the property-list classes: an 'ObjC' descriptor that holds
/// one must be refused without it being instantiated (#815).
@objc(HorosArchiveProbeMarker)
final class ArchiveMarker: NSObject, NSCoding {
    override init() { super.init() }
    init?(coder: NSCoder) { markerInstantiated = true; super.init() }
    func encode(with coder: NSCoder) { coder.encode("marker", forKey: "marker") }
}

/// A value as JSON can hold it: a date as "date <seconds since 1970>", data as
/// "data <hex>".
func jsonValue(_ value: Any) -> Any {
    switch value {
    case let date as NSDate: return "date \(date.timeIntervalSince1970)"
    case let data as NSData: return "data " + (data as Data).map { String(format: "%02x", $0) }.joined()
    case let list as NSArray: return list.map(jsonValue)
    case let record as NSDictionary:
        var out: [String: Any] = [:]
        for (key, item) in record { out["\(key)"] = jsonValue(item) }
        return out
    case is NSString, is NSNumber, is NSNull: return value
    case let object as NSObject: return "object " + object.className
    default: return value
    }
}

final class XMLRPCInterface: NSObject {
    func methodCall(_ name: String?, parameters: [AnyHashable: Any]?) throws -> Any {
        var call: [String: Any] = ["method": name ?? NSNull()]
        if let parameters {
            var received: [String: Any] = [:]
            for (key, value) in parameters { received["\(key)"] = jsonValue(value) }
            call["parameters"] = received
        }
        calls.append(call)
        if name == "EchoDate" {
            // A value with no Apple Event type of its own: the reply carries
            // it as an 'ObjC' descriptor, which must still read back.
            return ["error": "0", "method": name!, "date": NSDate(timeIntervalSince1970: 1_000_000_000),
                    "data": NSData(bytes: [1, 2, 255] as [UInt8], length: 3)] as NSDictionary
        }
        return ["error": "0", "method": name ?? ""] as NSDictionary
    }
}

final class AppController: NSObject {
    static let instance = AppController()
    let xmlrpcServer: XMLRPCInterface? = XMLRPCInterface()
    static func shared() -> AppController? { instance }
}

final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard CommandLine.arguments.count > 1 else { exit(0) }
        if CommandLine.arguments[1] == "--archives" {
            // The data of the 'ObjC' descriptors +descriptorWithObject: makes,
            // and, for a list (which it makes a 'list'), the same archive.
            func hex(_ data: Data) -> String { data.map { String(format: "%02X", $0) }.joined() }
            func hex(_ object: Any) -> String {
                let descriptor = NSAppleEventDescriptor.descriptor(withObject: object)!
                precondition(descriptor.descriptorType == 0x4F626A43 /* 'ObjC' */)
                return hex(descriptor.data)
            }
            let list = try! NSKeyedArchiver.archivedData(withRootObject: ["x", ArchiveMarker()] as NSArray, requiringSecureCoding: false)
            let archives = ["marker": hex(ArchiveMarker()), "markers": hex(list),
                            "date": hex(NSDate(timeIntervalSince1970: 1_000_000_000)),
                            "data": hex(NSData(bytes: [1, 2, 255] as [UInt8], length: 3)),
                            "url": hex(NSURL(string: "http://localhost/a")!)]
            let data = try! JSONSerialization.data(withJSONObject: archives, options: [.sortedKeys])
            print("ARCHIVES " + String(data: data, encoding: .utf8)!)
            exit(0)
        }
        let source = "tell application \"\(Bundle.main.bundlePath)\"\n\(CommandLine.arguments[1])\nend tell"
        var error: NSDictionary?
        let result = NSAppleScript(source: source)!.executeAndReturnError(&error)
        var report: [String: Any] = ["calls": calls]
        if let error { report["error"] = error[NSAppleScript.errorNumber] ?? 0 }
        else { report["reply"] = jsonValue(result.object() ?? NSNull()) }
        if markerInstantiated { report["instantiated"] = "HorosArchiveProbeMarker" }
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("REPORT " + String(data: data, encoding: .utf8)!)
        exit(0)
    }
}

let delegate = Delegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.setActivationPolicy(.prohibited)
NSApplication.shared.run()
'''

INFO = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>test.horos.xmlrpc-parameters-probe</string>
<key>CFBundleExecutable</key><string>Probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSAppleScriptEnabled</key><true/>
<key>OSAScriptingDefinition</key><string>Horos.sdef</string>
</dict></plist>
'''

REPLY = {'error': '0', 'method': 'Echo'}
# (description, AppleScript, expected report); None as the report means only
# "the process survived and the script got an error, with no call made".
CASES = [
    ('no parameters', 'invoke XMLRPC method "Echo"',
     {'calls': [{'method': 'Echo'}], 'reply': REPLY}),
    ('a lone record', 'invoke XMLRPC method "Echo" with parameters {PatientID:"P1"}',
     {'calls': [{'method': 'Echo', 'parameters': {'PatientID': 'P1'}}], 'reply': REPLY}),
    ('a record in a list', 'invoke XMLRPC method "DisplaySeries" with parameters '
                           '{{PatientID:"P1", SeriesInstanceUID:"1.2.3"}}',
     {'calls': [{'method': 'DisplaySeries', 'parameters': {'PatientID': 'P1', 'SeriesInstanceUID': '1.2.3'}}],
      'reply': {'error': '0', 'method': 'DisplaySeries'}}),
    ('the first of two records, with nested values',
     'invoke XMLRPC method "Echo" with parameters {{a:1, b:2.5, c:true, d:{1, "x"}}, {e:2}}',
     {'calls': [{'method': 'Echo', 'parameters': {'a': 1, 'b': 2.5, 'c': True, 'd': [1, 'x']}}], 'reply': REPLY}),
    ('a key spelled as a user identifier', 'invoke XMLRPC method "SelectAlbum" with parameters {|name|:"Today"}',
     {'calls': [{'method': 'SelectAlbum', 'parameters': {'name': 'Today'}}],
      'reply': {'error': '0', 'method': 'SelectAlbum'}}),
    ('an empty list', 'invoke XMLRPC method "Echo" with parameters {}',
     {'calls': [{'method': 'Echo'}], 'reply': REPLY}),
    ('a text item', 'invoke XMLRPC method "Echo" with parameters {"x"}', {'calls': [], 'error': -1700}),
    ('a number item', 'invoke XMLRPC method "Echo" with parameters {1}', {'calls': [], 'error': -1700}),
    ('a text first, a record second', 'invoke XMLRPC method "Echo" with parameters {"x", {a:1}}',
     {'calls': [], 'error': -1700}),
    # Keys that are terms compile to codes ('pnam', 'FTPc', 'url ', 'ID  '),
    # not to user fields; before #812 they were refused with -1708.
    ('a key that is a term', 'invoke XMLRPC method "SelectAlbum" with parameters {name:"Today"}',
     {'calls': [{'method': 'SelectAlbum', 'parameters': {'name': 'Today'}}],
      'reply': {'error': '0', 'method': 'SelectAlbum'}}),
    ('a term key in a list', 'invoke XMLRPC method "SelectAlbum" with parameters {{name:"Today"}}',
     {'calls': [{'method': 'SelectAlbum', 'parameters': {'name': 'Today'}}],
      'reply': {'error': '0', 'method': 'SelectAlbum'}}),
    ('path', 'invoke XMLRPC method "Echo" with parameters {path:"/tmp/a.dcm"}',
     {'calls': [{'method': 'Echo', 'parameters': {'path': '/tmp/a.dcm'}}], 'reply': REPLY}),
    ('URL beside a user field', 'invoke XMLRPC method "Echo" with parameters '
                                '{URL:"http://localhost/a.zip", Display:true}',
     {'calls': [{'method': 'Echo', 'parameters': {'URL': 'http://localhost/a.zip', 'Display': True}}],
      'reply': REPLY}),
    ('id and version beside a user field', 'invoke XMLRPC method "Echo" with parameters '
                                           '{id:7, version:"2", PatientID:"P1"}',
     {'calls': [{'method': 'Echo', 'parameters': {'id': 7, 'version': '2', 'PatientID': 'P1'}}],
      'reply': REPLY}),
    ('a term key in a nested record', 'invoke XMLRPC method "Echo" with parameters {a:{name:"n", b:1}}',
     {'calls': [{'method': 'Echo', 'parameters': {'a': {'name': 'n', 'b': 1}}}], 'reply': REPLY}),
    ('the term and the user field of one name', 'invoke XMLRPC method "Echo" with parameters '
                                                '{name:"term", |name|:"user"}',
     {'calls': [{'method': 'Echo', 'parameters': {'name': 'user'}}], 'reply': REPLY}),
    ('an unknown code', 'invoke XMLRPC method "Echo" with parameters {«class zzzz»:1}',
     {'calls': [{'method': 'Echo', 'parameters': {'zzzz': 1}}], 'reply': REPLY}),
]


def archive_cases(archives: dict) -> list:
    """'ObjC' descriptors, whose data is a keyed archive (#815): made by the
    working tree's +descriptorWithObject:, sent as «data ObjC…» literals. Before
    #815 any class was unarchived, and the marker's -initWithCoder: ran."""
    def echo(value: str) -> str:
        return f'invoke XMLRPC method "Echo" with parameters {value}'
    # A refused descriptor raises; Cocoa Scripting hands the script
    # errAEEventNotHandled, the process survives, and no method is called.
    refused = {'calls': [], 'error': -1708}
    return [
        ('an archived object of another class', echo(f'{{a:«data ObjC{archives["marker"]}»}}'), refused),
        ('an archived list holding another class', echo(f'{{a:«data ObjC{archives["markers"]}»}}'), refused),
        ('another class, archived, in a nested list',
         echo(f'{{a:{{1, «data ObjC{archives["marker"]}»}}}}'), refused),
        ('an archived NSURL', echo(f'{{a:«data ObjC{archives["url"]}»}}'), refused),
        ('data that is no archive', echo('{a:«data ObjC00FF»}'), refused),
        ('an archived date and data', echo(f'{{a:«data ObjC{archives["date"]}», b:«data ObjC{archives["data"]}»}}'),
         {'calls': [{'method': 'Echo', 'parameters': {'a': 'date 1000000000.0', 'b': 'data 0102ff'}}],
          'reply': REPLY}),
        ('a reply with a date and data', 'invoke XMLRPC method "EchoDate"',
         {'calls': [{'method': 'EchoDate'}],
          'reply': {'error': '0', 'method': 'EchoDate', 'date': 'date 1000000000.0', 'data': 'data 0102ff'}}),
    ]


def term_names() -> list:
    """The names of the conversion's term table, from the working tree."""
    import re
    source = (root / SOURCES[2]).read_text()
    table = re.search(r'recordKeyNames: \[DescType: String\] = \{(.*?)\n    \]', source, re.S)
    return re.findall(r'"[^"]{4}": "([^"]+)"', table.group(1)) if table else []


def every_term_case():
    """Every term of the table, as a key that AppleScript itself compiles here:
    a name that compiles to another code than the table's comes back under
    another key. ("class" is not in the table: AppleScript makes a record
    with a class key a record of that class, which Cocoa refuses with -1700
    before any conversion.)"""
    # Written in swapped case: a term is found whatever its case and comes
    # back as the table spells it, while a name that is no term would come
    # back as a user field, in the case written, and fail.
    names = term_names()
    record = ', '.join(f'{name.swapcase()}:0' for name in names)
    expected = {name: 0 for name in names}
    return ('every term of the table', f'invoke XMLRPC method "Echo" with parameters {{{record}}}',
            {'calls': [{'method': 'Echo', 'parameters': expected}], 'reply': REPLY})


def main() -> int:
    revision = sys.argv[1] if len(sys.argv) > 1 else None
    with tempfile.TemporaryDirectory(prefix='horos-xmlrpc-parameters-') as temp:
        directory = Path(temp)
        sources = {}
        for relative in SOURCES:
            path = directory / 'src' / Path(relative).name
            path.parent.mkdir(exist_ok=True)
            if revision:
                path.write_bytes(subprocess.run(['git', '-C', str(root), 'show', f'{revision}:{relative}'],
                                                check=True, capture_output=True).stdout)
            else:
                path.write_bytes((root / relative).read_bytes())
            sources[relative] = path
        (directory / 'src/main.swift').write_text(STUBS)
        app = directory / 'Probe.app'
        (app / 'Contents/MacOS').mkdir(parents=True)
        (app / 'Contents/Resources').mkdir(parents=True)
        (app / 'Contents/Info.plist').write_text(INFO)
        (app / 'Contents/Resources/Horos.sdef').write_bytes(sources[SOURCES[0]].read_bytes())
        binary = app / 'Contents/MacOS/Probe'
        build = subprocess.run(['xcrun', 'swiftc', '-Onone', '-suppress-warnings', '-o', str(binary),
                                str(directory / 'src/main.swift'), str(sources[SOURCES[1]]), str(sources[SOURCES[2]]),
                                # The command's main-actor hop (#961).
                                str(root / 'Horos/Sources/MainActorCallbacks.swift'),
                                '-framework', 'Cocoa', '-framework', 'Carbon'], capture_output=True, text=True)
        if build.returncode:
            print(build.stderr, file=sys.stderr)
            print('FAIL: the probe bundle did not compile')
            return 1

        archives = subprocess.run([str(binary), '--archives'], capture_output=True, text=True, timeout=60)
        lines = [line for line in archives.stdout.splitlines() if line.startswith('ARCHIVES ')]
        if archives.returncode or not lines:
            print(f'FAIL: the probe made no archives (status {archives.returncode}): {archives.stderr.strip()[-400:]}')
            return 1
        archives = json.loads(lines[-1][len('ARCHIVES '):])

        failures = 0
        if not term_names():
            print('FAIL: no term table in the conversion')
            failures += 1
        for description, script, expected in CASES + [every_term_case()] + archive_cases(archives):
            run = subprocess.run([str(binary), script], capture_output=True, text=True, timeout=60)
            lines = [line for line in run.stdout.splitlines() if line.startswith('REPORT ')]
            if run.returncode or not lines:
                print(f'FAIL: {description}: the process ended with status {run.returncode} '
                      f'({run.stderr.strip().splitlines()[-1] if run.stderr.strip() else "no output"})')
                failures += 1
                continue
            report = json.loads(lines[-1][len('REPORT '):])
            if report != expected:
                received = (report.get('calls') or [{}])[0].get('parameters')
                wanted = expected['calls'][0].get('parameters') if expected.get('calls') else None
                if isinstance(received, dict) and isinstance(wanted, dict) and len(wanted) > 8:
                    report = {'missing': sorted(set(wanted) - set(received)),
                              'unexpected': sorted(set(received) - set(wanted)),
                              'different': sorted(k for k in set(wanted) & set(received) if wanted[k] != received[k])}
                    expected = 'the same keys and values'
                print(f'FAIL: {description}: {report} (expected {expected})')
                failures += 1
            else:
                print(f'PASS: {description}')
        return 1 if failures else 0


if __name__ == '__main__':
    raise SystemExit(main())
