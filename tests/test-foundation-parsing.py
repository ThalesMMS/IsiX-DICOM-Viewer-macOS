#!/usr/bin/env python3
"""Current Foundation consumers keep hex, bounded UTF-8 and plist contracts.

Compiles the actual hexadecimal formatter, and the bounded-array and optional
plist expressions used by the consumers. Exercises overflowing/invalid numbers,
unterminated and malformed UTF-8 arrays, binary/XML round trips and truncation.
No app, private defaults or network is needed.
"""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
formatter = root / 'Nitrogen/Sources/N2HexadecimalNumberFormatter.swift'
arrays = {
    'Nitrogen/Sources/SMTPClient.swift': 'hostname',
    'Horos/Sources/NetworkDiagnosis.swift': 'name',
    'Horos/Sources/CloudFileAccess.swift': 'buffer',
    'Horos/Sources/RemoteDataNodeIdentifier.swift': 'buffer',
    'Horos/Sources/DICOMNodeService.swift': 'buffer',
    'Horos/Sources/BonjourBrowser.swift': 'buffer',
}
functions = []
for i, (path, name) in enumerate(arrays.items()):
    text = (root / path).read_text()
    expression = re.search(r'String\(decoding: ' + name + r'\.prefix \{[^}]+\}\.map \{[^}]+\}, as: UTF8\.self\)', text)
    assert expression, f'{path}: bounded array decoder is missing'
    assert f'String(cString: {name})' not in text, f'{path}: legacy array decoder remains'
    functions.append(f'func decode{i}(_ {name}: [CChar]) -> String {{ {expression[0]} }}')
bonjour = (root / 'Horos/Sources/BonjourDiscovery.swift').read_text()
for name in ('host', 'key'):
    expression = re.search(r'String\(decoding: ' + name + r'\.prefix \{[^}]+\}\.map \{[^}]+\}, as: UTF8\.self\)', bonjour)
    assert expression, f'Bonjour {name}: bounded array decoder missing'
    functions.append(f'func decode{len(functions)}(_ {name}: [CChar]) -> String {{ {expression[0]} }}')
remote = (root / 'Horos/Sources/RemoteDicomDatabase.swift').read_text()
encoder = re.search(r'let data = message\.flatMap \{ (.*?) \}', remote)[1]
application = (root / 'Horos/Sources/AppController.swift').read_text()
xml_encoder = re.search(r'let windowsState: Data\? = state\.flatMap \{ (.*?) \}', application)[1]
viewer = (root / 'Horos/Sources/ViewerController+RetrieveAndView.swift').read_text()
mapped = re.search(r'let content = try objc \{ (.*?) \}', (root / 'Horos/Sources/BonjourPublisher.swift').read_text())[1]
decoder = re.search(r'viewers = (try\? PropertyListSerialization\.propertyList\(from: state, options: \[\], format: nil\))', viewer)[1]

program = r'''
import Cocoa
// Only the formatting category's width is doubled; parsing is the real class.
extension NumberFormatter { var formatWidth: Int { 4 } }
func check(_ condition: Bool, _ label: String) { if !condition { fatalError(label) } }
let formatter = N2HexadecimalNumberFormatter()
for (input, expected) in [("", nil), ("xyz", nil), ("0x", UInt32(0)), ("0x0008", UInt32(8)),
                          (" FFFE trailing", UInt32(65534)), ("ffffffff", UInt32.max),
                          ("100000000", UInt32.max), ("ffffffffffffffffffff", UInt32.max),
                          ("-1", nil), ("+AA", nil), ("0Xab", UInt32(171))] {
    var value: AnyObject? = NSNumber(value: 42)
    var error: NSString?
    let success = formatter.getObjectValue(&value, for: input, errorDescription: &error)
    check(success == (expected != nil), "hex success: \(input)")
    check((value as? NSNumber)?.uint32Value == (expected ?? 42), "hex value/failure output: \(input)")
}
check(formatter.string(for: NSNumber(value: 8)) == "0x0008", "hex representation")
'''
program += '\n'.join(functions) + '\n'
program += 'let decoders: [([CChar]) -> String] = [' + ','.join(f'decode{i}' for i in range(len(functions))) + ']\n'
program += r'''
for decode in decoders {
    check(decode([]) == "", "empty buffer")
    check(decode([65, 0, 66]) == "A", "null termination")
    check(decode([65, 66]) == "AB", "unterminated buffer")
    check(decode([-1, -2, 0]) == "\u{FFFD}\u{FFFD}", "invalid UTF-8")
    check(decode([-61, -87, 0]) == "é", "non-ASCII UTF-8")
}
'''
program += f'func encode(_ message: NSDictionary?) -> Data? {{ message.flatMap {{ {encoder} }} }}\n'
program += f'func encodeXML(_ state: NSArray?) -> Data? {{ state.flatMap {{ {xml_encoder} }} }}\n'
program += f'func decodePlist(_ state: Data) -> Any? {{ {decoder} }}\n'
program += f'func mappedData(_ path: String) -> Data? {{ {mapped} }}\n'
program += r'''
let fixture = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("mapped-data")
let bytes = Data([0, 255, 65, 0, 66])
try bytes.write(to: fixture)
check(mappedData(fixture.path) == bytes, "mapped file bytes")
check(mappedData(fixture.path + ".missing") == nil, "missing mapped file")
let reference: NSDictionary = ["port": 11112, "description": "é PACS", "enabled": true, "bytes": Data([0, 255])]
let binary = encode(reference)!
check((decodePlist(binary) as? NSDictionary)?.isEqual(to: reference as! [AnyHashable: Any]) == true, "binary values")
let state: NSArray = [reference]
let xml = encodeXML(state)!
check((decodePlist(xml) as? NSArray)?.isEqual(to: state as! [Any]) == true, "XML values")
check(encode(nil) == nil && encodeXML(nil) == nil, "absent state")
check(encode(["unsupported": NSObject()]) == nil, "unsupported plist value")
for n in [0, 8, binary.count / 2, binary.count - 1] {
    check(!(decodePlist(binary.prefix(n)) is NSDictionary), "truncated binary cannot recover the saved dictionary \(n)")
}
check(decodePlist(Data([255, 0, 254])) == nil, "invalid plist")
print("PASS: formatter saturation/failure, 9 bounded UTF-8 consumers, binary/XML values and malformed plists")
'''
# The Distributed Objects endpoint stays Objective-C, in BrowserController+CAPI.m.
browser_source = (root / 'Horos/Sources/BrowserController+CAPI.m').read_bytes().decode('latin1')
def browser_function(name):
    start = browser_source.index('void ' + name + '(')
    opening = browser_source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += {'{': 1, '}': -1}.get(browser_source[end], 0)
        end += 1
    return browser_source[start:end]

native = r'''
#import <Foundation/Foundation.h>
#define check(value) do { if (!(value)) { fprintf(stderr, "FAIL: line %d: %s\n", __LINE__, #value); abort(); } } while (0)
FUNCTIONS
static id invoke(id target, NSString *name, id argument) {
    SEL selector = NSSelectorFromString(name);
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    check(signature != nil);
    NSInvocation *call = [NSInvocation invocationWithMethodSignature:signature];
    call.target = target; call.selector = selector;
    if (signature.numberOfArguments > 2) [call setArgument:&argument atIndex:2];
    [call invoke]; id result = nil; [call getReturnValue:&result]; return result;
}
int main(int argc, char **argv) { @autoreleasepool {
    check(argc == 2);
    NSURL *directory = [NSURL fileURLWithPath:@(argv[1]) isDirectory:YES];
    NSObject *root = [[[NSObject alloc] init] autorelease];
    HorosBrowserRegisterLegacyDistributedBrowser(root);
    id connection = invoke(NSClassFromString(@"NSConnection"), @"defaultConnection", nil);
    check(invoke(connection, @"rootObject", nil) == root);
    id server = invoke(NSClassFromString(@"NSPortNameServer"), @"systemDefaultPortNameServer", nil);
    check(invoke(server, @"portForName:", @"ENDPOINT") != nil);
    [connection performSelector:NSSelectorFromString(@"invalidate")];
    puts("PASS: Foundation distributed root/registered port, isolated endpoint");
} }
'''
ALIAS_DRIVER = r'''
func check(_ ok: Bool, _ message: String) { if !ok { print("FAIL: " + message); exit(1) } }
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let target = directory.appendingPathComponent("target é.txt")
try! "synthetic alias target".write(to: target, atomically: true, encoding: .utf8)
check(aliasDestination(nil) == nil, "nil path")
check(aliasDestination(target.path) == nil, "a plain file is not an alias")
check(aliasDestination(directory.appendingPathComponent("missing").path) == nil, "a missing file is not an alias")
var previous = target
for name in ["alias", "alias-chain"] {
    let alias = directory.appendingPathComponent(name)
    let bookmark = try! previous.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
    try! URL.writeBookmarkData(bookmark, to: alias)
    let resolved = aliasDestination(alias.path)
    check(resolved != nil, "alias resolved")
    check(URL(fileURLWithPath: resolved!).resolvingSymlinksInPath() == target.resolvingSymlinksInPath(), "alias target")
    previous = alias
}
print("PASS: real alias bookmarks and an alias chain resolve to their target; files and missing paths are not aliases")
'''
endpoint = 'horos-foundation-test-' + __import__('uuid').uuid4().hex
native = native.replace('FUNCTIONS', browser_function('HorosBrowserRegisterLegacyDistributedBrowser').replace('@"OsiriX"', '@"' + endpoint + '"')).replace('ENDPOINT', endpoint)

# The orthogonal MPR viewers' main-queue check, MainQueueTag of
# OrthogonalMPRViewer.swift, compiled as it is: the main queue is the current
# queue on the main thread and in a block sent to it, not in a block that
# another queue runs.
viewer_source = (root / 'Horos/Sources/OrthogonalMPRViewer.swift').read_text()
at = viewer_source.index('private enum MainQueueTag {')
end = viewer_source.index('\n}\n', at) + 3
main_queue_probe = viewer_source[at:end] + r'''
func check(_ condition: Bool, _ what: String) {
    if !condition { print("FAIL: main queue check: " + what); exit(1) }
}
DispatchQueue.global().sync { check(!MainQueueTag.isCurrent, "a global queue is not the main queue") }
check(MainQueueTag.isCurrent, "the main thread runs the main queue")
nonisolated(unsafe) var mainChecked = false
DispatchQueue.main.async { check(MainQueueTag.isCurrent, "a block sent to the main queue"); mainChecked = true }
let deadline = Date(timeIntervalSinceNow: 5)
while !mainChecked && deadline.timeIntervalSinceNow > 0 { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
check(mainChecked, "the block sent to the main queue ran")
print("PASS: the main queue check tells the main queue from a global queue")
'''

with tempfile.TemporaryDirectory(prefix='horos-foundation-parsing-') as directory:
    work = Path(directory)
    # The calibration parser: the Objective-C HorosCalibrationFloat of
    # ViewerController.m, compiled (Swift imports only its public declaration,
    # so NSScanner's Swift-only deprecation cannot leak through), or, once it
    # moved, IsiXImaging's CalibrationNumber behind a function of that form.
    calibration_source = (((root / 'Horos/Sources/ViewerController.m').read_bytes()) if (root / 'Horos/Sources/ViewerController.m').exists() else b'').decode('latin1')
    calibration_objc = 'BOOL HorosCalibrationFloat(' in calibration_source
    if calibration_objc:
        at = calibration_source.index('BOOL HorosCalibrationFloat(')
        opening = calibration_source.index('{', at)
        depth = 1
        end = opening + 1
        while depth:
            depth += {'{': 1, '}': -1}.get(calibration_source[end], 0)
            end += 1
        # The declaration HorosCalibration.h held.
        (work / 'Calibration.h').write_text('#import <Foundation/Foundation.h>\n#include <math.h>\n#include <float.h>\n'
                                            'FOUNDATION_EXPORT BOOL HorosCalibrationFloat(NSString *text, NSLocale *locale, float *value);\n')
        (work / 'Calibration.m').write_text('#import "Calibration.h"\n' + calibration_source[at:end])
        subprocess.run(['xcrun', 'clang', '-Werror', '-c', str(work / 'Calibration.m'),
                        '-I', str(work), '-o', str(work / 'Calibration.o')], check=True)
        calibration_inputs = ['-import-objc-header', str(work / 'Calibration.h'), str(work / 'Calibration.o')]
    else:
        (work / 'Calibration.swift').write_text('''import Foundation
func HorosCalibrationFloat(_ text: String?, _ locale: Locale, _ value: inout Float) -> Bool {
    guard let text, let parsed = CalibrationNumber.parse(text, locale: locale) else { return false }
    value = parsed
    return true
}
''')
        calibration_inputs = [str(root / 'Modules/IsiXImaging/Sources/Calibration/CalibrationNumber.swift'), str(work / 'Calibration.swift')]
    program += r'''
for (input, locale, expected) in [
    ("1,25", "fr_FR", Float(1.25)), ("1.25", "fr_FR", Float(1.25)),
    ("  -2.5\n", "en_US", Float(-2.5)), ("0", "de_DE", Float(0)),
    ("1e-40", "en_US_POSIX", Float(1e-40)),
    (String(Double(Float.greatestFiniteMagnitude)), "en_US_POSIX", Float.greatestFiniteMagnitude),
    (String(-Double(Float.greatestFiniteMagnitude)), "en_US_POSIX", -Float.greatestFiniteMagnitude),
    (String(Double(Float.leastNonzeroMagnitude)), "en_US_POSIX", Float.leastNonzeroMagnitude)
] {
    var value: Float = 42
    check(HorosCalibrationFloat(input, Locale(identifier: locale), &value), "calibration success: \(input)")
    check(value == expected, "calibration locale/POSIX/subnormal: \(input)")
}
for input in ["", " \n", "1.25 trailing", "nan", "inf", "-inf", "1e100", "-1e100", "3.4028235e38", "1e-100", "1e-46"] {
    var value: Float = 42
    check(!HorosCalibrationFloat(input, Locale(identifier: "en_US_POSIX"), &value), "calibration refusal: \(input)")
    check(value == 42, "calibration failure changed output: \(input)")
}
print("PASS: calibration parser preserves locale/POSIX, complete input, finite/range checks and failure output")
'''
    (work / 'main.swift').write_text(program)
    subprocess.run(['xcrun', 'swiftc', '-warnings-as-errors', str(formatter), str(work / 'main.swift'), *calibration_inputs,
                    '-o', str(work / 'check')], check=True)
    subprocess.run([str(work / 'check'), str(work)], check=True)

    # The browser's alias resolution is Swift (BrowserController+Files.swift).
    files_source = (root / 'Horos/Sources/BrowserController+Files.swift').read_text()
    at = files_source.index('private func aliasDestination(')
    alias_function = files_source[at:files_source.index('\n}\n', at) + 3]
    (work / 'alias.swift').write_text('import Foundation\n' + alias_function + ALIAS_DRIVER)
    subprocess.run(['xcrun', 'swiftc', str(work / 'alias.swift'), '-o', str(work / 'alias')], check=True)
    subprocess.run([str(work / 'alias'), str(work)], check=True)

    (work / 'main-queue.swift').write_text('import Foundation\n' + main_queue_probe)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-warnings-as-errors', str(work / 'main-queue.swift'),
                    '-o', str(work / 'main-queue')], check=True, timeout=300)
    subprocess.run([str(work / 'main-queue')], check=True, timeout=60)

    (work / 'BrowserFoundation.m').write_text(native)
    subprocess.run(['xcrun', 'clang', '-fblocks', '-Werror', '-Wdeprecated-declarations',
                    str(work / 'BrowserFoundation.m'), '-framework', 'Foundation', '-o', str(work / 'browser-foundation')], check=True)
    subprocess.run([str(work / 'browser-foundation'), str(work)], check=True)
