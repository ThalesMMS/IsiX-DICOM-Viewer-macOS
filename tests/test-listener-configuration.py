#!/usr/bin/env python3
"""The listener reads its DCMTK configuration whatever its AE title and folders hold.

DCMTK's Q/R configuration parser ends a value at a space, '=' or ',', and a
quoted one at any quote or parenthesis. When the listener wrote the user's AE
title and the database's INCOMING folder into that file, an AE title with a
space, or a database in a folder such as "Data (2)" or "Joe's Files", made it
fail with "Unable to read DICOM listener configuration." at every launch.

The DCMTK adapter's configuration loader and association check, from
IsiXDCMTKQueryRetrieveSCP.mm, run here against the real DCMTK archives, with
the listener's AE title rules from IsiXDICOMNetwork, as the app's listener
host answers the check, and temporary folders with such names:

- each valid AE title (with a space, quote, apostrophe, parenthesis, '=',
  ',', '#' or '/', of 16 characters, padded with spaces) is accepted by the
  rules, and DCMTK reads the configuration with no error and no file left in
  the temporary folder; storage is writable;
- the association check accepts that AE title as the peer sends it (without
  the padding, or padded) with nothing logged, and accepts any other called
  title too - another one, a prefix, a different case, an empty one, or the
  question marks a PACS sent after replacing its own characters - as Horos
  did, logging the title received and the one configured;
- an empty or blank AE title, or one of 17 characters, is refused with a
  message that says where to set it and how to turn the listener off, before
  DCMTK is configured.
"""
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dcmtk_build import ROOT, dcmtk_flags  # noqa: E402
import isix_modules  # noqa: E402


def between(text, start, end, include_end=False):
    a = text.index(start)
    b = text.index(end, a + len(start))
    return text[a:b + (len(end) if include_end else 0)]


adapter = (ROOT / 'Horos/Sources/Adapters/DCMTK/IsiXDCMTKQueryRetrieveSCP.mm').read_text()
loader = between(adapter, 'static const char* const IsiXDCMTKListenerConfigurationAETitle', '\n}\n', include_end=True)
check = between(adapter, '    OFBool checkCalledAETitleAccepted(const OFString& calledAE) override',
                '\n    }\n', include_end=True).replace(' override', '')

# The listener's own configuration: the AE title is checked before DCMTK is
# configured, and the host matches the trimmed title the settings hold.
scp = (ROOT / 'Horos/Sources/DCMTKQueryRetrieveSCP.swift').read_text()
configure = between(scp, 'private func configure(_ listener: IsiXDCMTKListener, aeTitle: String) -> String? {', '\n    }\n')
failures = []
if configure.find('ListenerAETitleRules.problem(with: aeTitle)') < 0 or \
        configure.find('ListenerAETitleRules.problem(with: aeTitle)') > configure.find('listener.configure()'):
    failures.append('the AE title is not checked before DCMTK is configured')
if 'return problem + ListenerAETitleRules.turnOffAdvice' not in configure:
    failures.append('a refused AE title does not say how to turn the listener off')
if not re.search(r'settings\.aeTitle = ListenerAETitleRules\.trimmed\(listenerAETitle\)', scp) or \
        'ListenerHost(aeTitle: settings.aeTitle)' not in scp:
    failures.append('the listener and its host do not use the trimmed AE title')
host = (ROOT / 'Horos/Sources/ListenerHost.swift').read_text()
if 'ListenerAETitleRules.matches(called: Array(calledAETitle), configured: aeTitle)' not in host:
    failures.append('the host does not match called titles with ListenerAETitleRules')

code = r'''
#include <dcmtk/config/osconfig.h>
#include <dcmtk/dcmqrdb/dcmqrcnf.h>
#include <dcmtk/dcmqrdb/dcmqropt.h>
#include <dcmtk/dcmnet/assoc.h>
#import <Foundation/Foundation.h>
#include <string>
#import "harness.h"

static NSString *testTemporaryDirectory = nil;
static NSString *logged = nil;
#define NSLog(...) (logged = [NSString stringWithFormat:__VA_ARGS__])
#define NSTemporaryDirectory() testTemporaryDirectory

LOADER

@interface Host : NSObject
@property HorosTestMatches matches;
@property const char *configured;
- (BOOL)isListenerAETitle:(NSData *)called;
@end
@implementation Host
- (BOOL)isListenerAETitle:(NSData *)called
{
    std::string text((const char *)called.bytes, called.length);
    return self.matches(text.c_str(), self.configured);
}
@end

struct ListenerContext { Host *host; OFString aeTitle; DcmQueryRetrieveConfig config; };
struct Parameters { struct { char callingAPTitle[65]; char callingPresentationAddress[65]; } DULparams; };
struct T_ASC_Association_ { Parameters *params; };
struct Association {
    T_ASC_Association_ *association_;
    ListenerContext &listener_;
CHECK
};

static ListenerContext *context = nullptr;

const char *HorosTestLoad(const char *temporary, int port, int *tcpPort, BOOL *writable)
{
    testTemporaryDirectory = [NSString stringWithUTF8String:temporary];
    delete context;
    context = new ListenerContext();
    NSString *problem = IsiXDCMTKLoadListenerConfiguration(context->config, port, 16384, 8);
    *tcpPort = context->config.getNetworkTCPPort();
    *writable = context->config.writableStorageArea(IsiXDCMTKListenerConfigurationAETitle);
    return problem ? strdup(problem.UTF8String) : NULL;
}

BOOL HorosTestAccepts(HorosTestMatches matches, const char *configured, const char *called, const char **message)
{
    Host *host = [Host new];
    host.matches = matches;
    host.configured = configured;
    context->host = host;
    context->aeTitle = OFString(configured);
    Parameters parameters = {};
    strcpy(parameters.DULparams.callingAPTitle, "PEER");
    strcpy(parameters.DULparams.callingPresentationAddress, "127.0.0.1");
    T_ASC_Association_ association = {&parameters};
    Association worker = {&association, *context};
    logged = nil;
    const BOOL accepted = worker.checkCalledAETitleAccepted(OFString(called));
    *message = logged ? strdup(logged.UTF8String) : NULL;
    return accepted;
}
'''.replace('LOADER', loader).replace('CHECK', check)

HEADER = r'''
#import <Foundation/Foundation.h>
typedef BOOL (*HorosTestMatches)(const char *called, const char *configured);
#ifdef __cplusplus
extern "C" {
#endif
const char *HorosTestLoad(const char *temporary, int port, int *tcpPort, BOOL *writable);
BOOL HorosTestAccepts(HorosTestMatches matches, const char *configured, const char *called, const char **message);
#ifdef __cplusplus
}
#endif
'''

DRIVER = r'''
import Foundation
import IsiXDICOMNetwork

var failures = 0
func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
    if !condition { failures += 1; FileHandle.standardError.write(("FAIL: " + message() + "\n").data(using: .utf8)!) }
}
let matches: HorosTestMatches = { called, configured in
    ObjCBool(ListenerAETitleRules.matches(called: Array(String(cString: called!).utf8), configured: Array(String(cString: configured!).utf8)))
}
func accepts(_ configured: String, _ called: String) -> (Bool, String?) {
    var message: UnsafePointer<CChar>?
    let accepted = HorosTestAccepts(matches, configured, called, &message)
    return (accepted, message.map { String(cString: $0) })
}

let folders = CommandLine.arguments[1].components(separatedBy: "\n")
let valid: [(String, String)] = [
    ("ISIX", "ISIX"), ("ISIX VIEWER", "ISIX VIEWER"), ("O'BRIEN", "O'BRIEN"), ("ISIX (2)", "ISIX (2)"), ("A\"B", "A\"B"),
    ("A=B,C", "A=B,C"), ("#COMMENT", "#COMMENT"), ("AETable END", "AETable END"), ("ABCDEFGHIJKLMNOP", "ABCDEFGHIJKLMNOP"),
    ("  PADDED  ", "PADDED"), ("WITH/SLASH", "WITH/SLASH"),
]
for folder in folders {
    var port: Int32 = 0
    var writable: ObjCBool = false
    let problem = HorosTestLoad(folder, 11112, &port, &writable)
    expect(problem == nil, "folder [\(folder)]: \(problem.map { String(cString: $0) } ?? "")")
    expect(port == 11112, "folder [\(folder)]: port \(port)")
    expect(writable.boolValue, "folder [\(folder)]: storage is not writable")
    let left = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasPrefix("Horos-dcmqrscp-") }
    expect(left.isEmpty, "folder [\(folder)]: \(left.count) configuration files left")
    for (title, peer) in valid {
        let aeTitle = ListenerAETitleRules.trimmed(title)
        expect(ListenerAETitleRules.problem(with: aeTitle) == nil, "AE [\(title)] is refused")
        var (accepted, logged) = accepts(aeTitle, peer)
        expect(accepted && logged == nil, "AE [\(title)] refuses or logs its own title [\(peer)]: \(logged ?? "")")
        (accepted, logged) = accepts(aeTitle, "  \(peer)  ")
        expect(accepted && logged == nil, "AE [\(title)] refuses or logs its padded title")
        for other in ["OTHER", "", "WS_???_??", "LISTENER", String(aeTitle.dropLast()), aeTitle.lowercased()] where other != aeTitle {
            (accepted, logged) = accepts(aeTitle, other)
            expect(accepted, "AE [\(title)] refuses the called title [\(other)]")
            let expected = "calls AE title \"\(other)\", not \"\(aeTitle)\"; accepted"
            expect(logged?.contains(expected) == true && logged?.contains("PEER") == true,
                   "AE [\(title)], called [\(other)]: logged \(logged ?? "nothing")")
        }
    }
}
for title in ["", "   ", "ABCDEFGHIJKLMNOPQ"] {
    let problem = ListenerAETitleRules.problem(with: ListenerAETitleRules.trimmed(title))
    let message = (problem ?? "") + ListenerAETitleRules.turnOffAdvice
    expect(problem != nil, "AE [\(title)] was accepted")
    expect(message.contains("Preferences > Listener") && message.contains("turn it off"),
           "AE [\(title)]: the message does not say where to set it or turn the listener off: \(message)")
    expect(!message.contains("Unable to read"), "AE [\(title)]: the generic message")
}
if failures > 0 { exit(1) }
print("PASS: \(folders.count) temporary folders x \(valid.count) AE titles read by DCMTK; own title accepted quietly, "
      + "others accepted and logged; empty and long titles refused with directions")
'''

flags = dcmtk_flags('dcmqrdb', 'dcmnet', 'dcmtls')
with tempfile.TemporaryDirectory(prefix='horos-listener-configuration-') as folder:
    folder = Path(folder)
    (folder / 'harness.h').write_text(HEADER)
    (folder / 'loader.mm').write_text(code)
    (folder / 'driver.swift').write_text(DRIVER)
    subprocess.run(['xcrun', 'clang++', '-std=c++17', '-fobjc-arc', '-w', '-c', '-I', str(folder),
                    *[flag for flag in flags if flag.startswith('-I')], str(folder / 'loader.mm'),
                    '-o', str(folder / 'loader.o')], check=True)
    modules = isix_modules.module_flags('IsiXDICOMNetwork', folder / 'modules')
    binary = folder / 'test'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-suppress-warnings', '-import-objc-header', str(folder / 'harness.h'),
                    '-module-cache-path', str(folder / 'module-cache'), *modules, str(folder / 'driver.swift'),
                    str(folder / 'loader.o'), *[flag for flag in flags if not flag.startswith('-I')], '-lc++',
                    '-framework', 'Foundation', '-framework', 'Security', '-o', str(binary)], check=True)
    hostile = ["Data (2)", "Joe's Files", 'Quote " here', 'A=B, C', 'Café Ünïcode', 'x' * 200]
    temporary = []
    for name in hostile:
        path = folder / 'tmp' / name / 'T'
        path.mkdir(parents=True)
        temporary.append(str(path))
    result = subprocess.run([str(binary), '\n'.join(temporary)], text=True, capture_output=True)
    sys.stdout.write(result.stdout)
    sys.stderr.write(result.stderr)
    if result.returncode:
        failures.append('the driver failed')

for failure in failures:
    print('FAIL:', failure)
if failures:
    raise SystemExit(1)
