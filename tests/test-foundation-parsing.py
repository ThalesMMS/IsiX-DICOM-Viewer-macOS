#!/usr/bin/env python3
"""Current Foundation consumers keep hex, bounded UTF-8 and plist contracts (#1051).

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
    'Nitrogen/Sources/N2ConnectionListener.swift': 'tmp',
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
browser_source = (root / 'Horos/Sources/BrowserController.m').read_bytes().decode('mac_roman')
def browser_function(name):
    start = browser_source.index('static ', browser_source.index(name) - 30)
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
    NSURL *target = [directory URLByAppendingPathComponent:@"target é.txt"];
    check([@"synthetic alias target" writeToURL:target atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    check(HorosBrowserAliasDestination(nil) == nil);
    check(HorosBrowserAliasDestination(target.path) == nil);
    check(HorosBrowserAliasDestination([directory URLByAppendingPathComponent:@"missing"].path) == nil);
    NSURL *previous = target;
    for (NSString *name in @[@"alias", @"alias-chain"]) {
        NSURL *alias = [directory URLByAppendingPathComponent:name];
        NSData *bookmark = [previous bookmarkDataWithOptions:NSURLBookmarkCreationSuitableForBookmarkFile includingResourceValuesForKeys:nil relativeToURL:nil error:NULL];
        check(bookmark != nil);
        check([NSURL writeBookmarkData:bookmark toURL:alias options:0 error:NULL]);
        NSString *resolved = HorosBrowserAliasDestination(alias.path);
        check(resolved != nil);
        check([[NSURL fileURLWithPath:resolved].URLByResolvingSymlinksInPath isEqual:target.URLByResolvingSymlinksInPath]);
        previous = alias;
    }
    NSObject *root = [[[NSObject alloc] init] autorelease];
    HorosRegisterLegacyDistributedBrowser(root);
    id connection = invoke(NSClassFromString(@"NSConnection"), @"defaultConnection", nil);
    check(invoke(connection, @"rootObject", nil) == root);
    id server = invoke(NSClassFromString(@"NSPortNameServer"), @"systemDefaultPortNameServer", nil);
    check(invoke(server, @"portForName:", @"ENDPOINT") != nil);
    [connection performSelector:NSSelectorFromString(@"invalidate")];
    puts("PASS: real alias bookmarks/chain and Foundation distributed root/registered port, isolated endpoint");
} }
'''
endpoint = 'horos-foundation-test-' + __import__('uuid').uuid4().hex
native = native.replace('FUNCTIONS', browser_function('HorosBrowserAliasDestination') + '\n' + browser_function('HorosRegisterLegacyDistributedBrowser').replace('@"OsiriX"', '@"' + endpoint + '"')).replace('ENDPOINT', endpoint)

queue_source = (root / 'Horos/Sources/OrthogonalMPRViewer+CAPI.m').read_text()
at = queue_source.index('BOOL HorosOrthogonalMPRIsCurrentQueueMain(void)\n{')
end = queue_source.index('\n}\n', at) + 3
native = native.replace('int main(', queue_source[at:end] + '\nint main(')
native = native.replace('    check(argc == 2);', r'''
    check(argc == 2);
    dispatch_sync(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ check(!HorosOrthogonalMPRIsCurrentQueueMain()); });
    check(HorosOrthogonalMPRIsCurrentQueueMain());
    __block BOOL mainChecked = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ check(HorosOrthogonalMPRIsCurrentQueueMain()); mainChecked = YES; });
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!mainChecked && deadline.timeIntervalSinceNow > 0) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    check(mainChecked);
''')

with tempfile.TemporaryDirectory(prefix='horos-foundation-parsing-') as directory:
    work = Path(directory)
    # Compile the actual Objective-C parser body; Swift imports only its public
    # declaration, so NSScanner's Swift-only deprecation cannot leak through.
    calibration_source = (root / 'Horos/Sources/ViewerController.m').read_bytes().decode('latin1')
    at = calibration_source.index('BOOL HorosCalibrationFloat(')
    opening = calibration_source.index('{', at)
    depth = 1
    end = opening + 1
    while depth:
        depth += {'{': 1, '}': -1}.get(calibration_source[end], 0)
        end += 1
    (work / 'Calibration.m').write_text('#import "HorosCalibration.h"\n' + calibration_source[at:end])
    subprocess.run(['xcrun', 'clang', '-Werror', '-c', str(work / 'Calibration.m'),
                    '-I', str(root / 'Horos/Sources'), '-o', str(work / 'Calibration.o')], check=True)
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
print("PASS: imported Objective-C calibration parser preserves locale/POSIX, complete input, finite/range checks and failure output")
'''
    (work / 'main.swift').write_text(program)
    subprocess.run(['xcrun', 'swiftc', '-warnings-as-errors', str(formatter), str(work / 'main.swift'),
                    '-import-objc-header', str(root / 'Horos/Sources/HorosCalibration.h'), str(work / 'Calibration.o'),
                    '-o', str(work / 'check')], check=True)
    subprocess.run([str(work / 'check'), str(work)], check=True)

    (work / 'BrowserFoundation.m').write_text(native)
    subprocess.run(['xcrun', 'clang', '-fblocks', '-Werror', '-Wdeprecated-declarations',
                    str(work / 'BrowserFoundation.m'), '-framework', 'Foundation', '-o', str(work / 'browser-foundation')], check=True)
    subprocess.run([str(work / 'browser-foundation'), str(work)], check=True)
