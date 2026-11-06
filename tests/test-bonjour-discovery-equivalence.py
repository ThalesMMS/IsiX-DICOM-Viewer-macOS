#!/usr/bin/env python3
"""What Bonjour finds is decoded as the previous revision decoded it.

The TXT record of a shared database moved to IsiXDICOMNetwork
(SharedDatabaseServiceRecord, behind +[BonjourPublisher
dictionaryFromXTRecordData:]). The methods of the revision before that move
and of this tree are compiled with the same stand-ins and fed the same TXT
records, made by Foundation and by hand: the three text keys (AE title, port,
identifier) with text, empty and byte values, a key without a value, other
keys with binary values, an empty record, a malformed one, none.

(The address decoding this test compared as well went with BonjourBrowser's
own resolution, which nothing started: the Sources list resolves what it
finds itself.)

The dictionaries and the exceptions raised must be the same, but for one
intended difference: a
text key that comes without "=" (what NSNetService's encoder writes for an
empty value, and the same written by hand) raised before, so the source had
no dictionary; it is now read as empty text, with the rest of the record.
Those two records must give exactly the old exception before and the new
dictionary now.

Exit 2 when the history does not reach the revision before the move.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import history_reference  # noqa: E402
import isix_modules  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
PUBLISHER = 'Horos/Sources/BonjourPublisher.swift'
# The decoding as the publisher did it before SharedDatabaseServiceRecord.
MARK = 'private static func utf8String(_ data: Any, key: NSString) -> NSString {'
reference = ('HEAD' if MARK in history_reference.show('HEAD', PUBLISHER).decode('utf-8')
             else history_reference.before_text_removed(PUBLISHER, MARK))
if reference is None:
    print('skipped: the history does not reach the revision before the decoding moved')
    sys.exit(2)
if MARK in (ROOT / PUBLISHER).read_text(encoding='utf-8'):
    print('skipped: this tree still decodes in the publisher')
    sys.exit(2)


def method(source, signature):
    start = source.index(signature)
    start = source.rindex('\n', 0, start) + 1
    depth = 0
    for end in range(source.index('{', start), len(source)):
        if source[end] == '{':
            depth += 1
        elif source[end] == '}':
            depth -= 1
            if depth == 0:
                return source[start:end + 1]


def methods(source, signatures):
    return '\n'.join(method(source, each) for each in signatures if each in source)


CATCH_HEADER = r'''
#import <Foundation/Foundation.h>
NSString *_Nullable ProbeRaised(void (NS_NOESCAPE ^_Nonnull block)(void));
'''
CATCH = r'''
#import "catch.h"
NSString *ProbeRaised(void (NS_NOESCAPE ^block)(void)) {
    @try { block(); return nil; } @catch (NSException *e) { return [NSString stringWithFormat:@"%@: %@", e.name, e.reason]; }
}
'''

STANDINS = r'''
import Foundation
import Darwin
import IsiXDICOMNetwork

// Exceptions are caught by the probe itself; nothing in these paths raises past it.
enum HorosObjCException { static func perform(_ body: () -> Void) throws { body() } }
let HorosObjCExceptionKey = "HorosObjCExceptionKey"
func _N2LogExceptionImpl(_ e: NSException, _ stack: Bool, _ function: String) { print("logged: \(e.reason ?? "")") }

final class BonjourPublisher: NSObject {
PUBLISHER_METHODS
}

func describe(_ value: Any) -> String {
    switch value {
    case let data as Data: return "data \(data.map { String(format: "%02x", $0) }.joined())"
    case is NSNull: return "null"
    case let string as String: return "text \(string.debugDescription)"
    default: return "\(type(of: value)) \(value)"
    }
}

func record(_ pairs: [String: Data]) -> Data { NetService.data(fromTXTRecord: pairs) }
func raw(_ items: [[UInt8]]) -> Data { Data(items.flatMap { [UInt8($0.count)] + $0 }) }
let records: [(String, Data?)] = [
    ("text keys", record(["AETitle": Data("PEER".utf8), "port": Data("11112".utf8), "UID": Data("1.2.3".utf8)])),
    ("text keys with others", record(["AETitle": Data("A".utf8), "HorosDirectTransferPort": Data("8781".utf8),
                                      "bin": Data([0, 255, 1])])),
    ("empty texts", record(["AETitle": Data(), "port": Data()])),
    ("only others", record(["other": Data("x".utf8)])),
    ("text key not UTF-8", record(["AETitle": Data([0xc3, 0x28]), "other": Data("y".utf8)])),
    ("text key without value", raw([Array("UID".utf8), Array("AETitle=A".utf8)])),
    ("other key without value", raw([Array("flag".utf8), Array("port=104".utf8)])),
    ("byte order mark", record(["AETitle": Data([0xef, 0xbb, 0xbf, 0x41])])),
    ("empty", Data()),
    ("malformed", Data([9, 0x41])),
    ("none", nil),
]
for (name, data) in records {
    var result: NSDictionary?
    let raised = ProbeRaised { result = BonjourPublisher.dictionaryFromXTRecordData(data) }
    if let raised {
        print("record \(name): raised \(raised)")
    } else {
        let entries = (result as? [String: Any] ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\(describe($0.value))" }
        print("record \(name): \(entries)")
    }
}
'''

outputs = {}
with tempfile.TemporaryDirectory(prefix='horos-bonjour-discovery-') as directory:
    folder = Path(directory)
    modules = isix_modules.module_flags('IsiXDICOMNetwork', folder / 'modules')
    (folder / 'catch.h').write_text(CATCH_HEADER)
    (folder / 'catch.m').write_text(CATCH)
    subprocess.run(['xcrun', 'clang', '-c', '-fobjc-arc', str(folder / 'catch.m'), '-o', str(folder / 'catch.o')],
                   check=True, capture_output=True)
    for label, revision in (('previous', reference), ('current', None)):
        if revision:
            publisher = history_reference.show(revision, PUBLISHER).decode('utf-8')
        else:
            publisher = (ROOT / PUBLISHER).read_text(encoding='utf-8')
        source = STANDINS.replace('PUBLISHER_METHODS', methods(publisher, (
            'class func dictionaryFromXTRecordData(', 'private static func utf8String(')))
        # Members of a main-actor class in the tree, of a plain class here.
        source = source.replace('public nonisolated class func', 'public class func')
        (folder / label).mkdir()
        (folder / label / 'main.swift').write_text(source)
        built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', *modules, '-import-objc-header', str(folder / 'catch.h'),
                                str(folder / label / 'main.swift'), str(folder / 'catch.o'), '-o', str(folder / label / 'probe')],
                               capture_output=True, text=True)
        if built.returncode != 0:
            print(f'FAIL: the {label} decoding does not compile:\n{built.stderr[-3000:]}')
            sys.exit(1)
        ran = subprocess.run([str(folder / label / 'probe')], capture_output=True, text=True, timeout=60)
        if ran.returncode != 0:
            print(f'FAIL: the {label} decoding did not finish:\n{(ran.stdout + ran.stderr)[-2000:]}')
            sys.exit(1)
        outputs[label] = ran.stdout.splitlines()

# The intended difference: a text key without "=" is empty text now; before,
# the decoding raised and the source was listed without its record.
BARE_KEY_RAISED = 'raised NSInvalidArgumentException: -[NSNull bytes]: unrecognized selector sent to instance'
INTENDED = {
    'record empty texts': (BARE_KEY_RAISED, '["AETitle=text \\"\\"", "port=text \\"\\""]'),
    'record text key without value': (BARE_KEY_RAISED, '["AETitle=text \\"A\\"", "UID=text \\"\\""]'),
}
failures = []
seen = set()
for before, after in zip(outputs['previous'], outputs['current']):
    name = after.split(': ', 1)[0]
    if name in INTENDED:
        seen.add(name)
        expected_before, expected_after = INTENDED[name]
        if before != f'{name}: {expected_before}' or after != f'{name}: {expected_after}':
            failures.append((before, after))
    elif before != after:
        failures.append((before, after))
if seen != set(INTENDED):
    print(f'FAIL: the intended difference was not compared: {sorted(set(INTENDED) - seen)}')
    sys.exit(1)
if len(outputs['previous']) != len(outputs['current']) or failures:
    for before, after in failures:
        print(f'FAIL:\n  previous: {before}\n  current:  {after}')
    sys.exit(1)
for line in outputs['current']:
    print(' ', line)
print(f'PASS: {len(outputs["current"])} records decoded as at {reference[:10]}, '
      f'but for the {len(INTENDED)} with a text key without "=", now read as empty text')
