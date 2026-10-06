#!/usr/bin/env python3
"""Saving the WADO sheet leaves the node's DIMSE TLS settings alone, and its password in the Keychain.

The commit block of -editWADO: is extracted and run against a node dictionary,
so what the sheet writes is read off the production source rather than described.
OSILocationsPreferencePanePref is Swift: the block is compiled as Swift.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_text  # noqa: E402
source = source_text('OSILocationsPreferencePanePref')

action = source[source.index('public func editWADO(_ sender: Any?)'):]
# The method ends at the first closing brace at the method's own indentation.
action = action[:action.index('\n    }\n')]
commit = action[action.index('if result == .stop'):]
# The sheet's own persistence is not what this test drives.
persistence = 'UserDefaults.standard.set(dicomNodes?.arrangedObjects, forKey: "SERVERS")'
if persistence not in commit:
    print('FAIL: the WADO sheet no longer writes SERVERS from the controller array; this test is stale')
    sys.exit(1)
commit = commit.replace(persistence, '')

failures = []

# The TLS keys the DIMSE association reads, from the code that reads them.
users = [root / 'Horos/Sources/QueryController.mm',
         root / 'Horos/Sources/DCMTKStoreSCU.mm',
         root / 'Horos/Sources/DCMTKServiceClassUser.mm']
reads_tls = any('TLSEnabled' in path.read_bytes().decode('latin1') for path in users)
if not reads_tls:
    failures.append('no DIMSE client reads TLSEnabled any more; this test is stale')

# Static: the WADO sheet must not write any TLS key at all.
for key in re.findall(r'forKey:\s*"(\w+)"', commit):
    if key.startswith('TLS'):
        failures.append('the WADO sheet still writes %s' % key)

code = r'''
import AppKit

var failures = 0
func check(_ c: @autoclosure () -> Bool, _ line: Int = #line) {
    if !c() { print("FAIL main.swift:\(line)"); failures += 1 }
}

// The sheet keeps the password in the Keychain; an in-memory one stands in for it.
var keychain: [String: Data] = [:]
DICOMwebCredentials.backend = DICOMwebCredentials.Backend(
    read: { id, wantData in keychain[id].map { (wantData ? $0 : nil, nil) } },
    add: { id, data, _ in keychain[id] = data },
    update: { id, data, _ in
        guard keychain[id] != nil else { return false }
        if let data { keychain[id] = data }
        return true
    },
    delete: { id in keychain[id] = nil })
enum HorosAlertPanel {
    static func runCritical(title: String, message: String, defaultButton: String?, alternateButton: String?, otherButton: String?) -> Int {
        print("FAIL: the sheet reported \(message)"); failures += 1; return 0
    }
}

// A node configured for TLS only: authenticated DIMSE, a chosen cipher suite,
// a peer certificate rule, and no WADO settings yet.
func tlsNode() -> NSMutableDictionary {
    return (["Address": "pacs.example.org",
             "Port": 11112,
             "AETitle": "SECUREPACS",
             "retrieveMode": 0,                 // C-MOVE
             "TLSEnabled": true,
             "TLSAuthenticated": true,
             "TLSCipherSuites": [["Cipher": "TLS_RSA_WITH_AES_128_CBC_SHA", "Supported": true]],
             "TLSCertificateVerification": 1,
             "TLSUseDHParameterFileURL": true,
             "TLSDHParameterFileURL": "/tmp/dh.pem"] as NSDictionary).mutableCopy() as! NSMutableDictionary
}

// What the sheet leaves in its fields when the user clicks OK.
func commitWADO(_ aServer: NSMutableDictionary, _ WADOPort: Int32, _ WADOTransferSyntax: Int32,
                _ WADOhttps: Int32, _ WADOUrl: String?, _ WADOUsername: String?, _ WADOPassword: String?) {
    let result = NSApplication.ModalResponse.stop
    let WADOMaxRequests: Int32 = 10
    let WADOSeriesOrder: Int32 = 0
    let WADOExcludeSeries: String? = nil
    let WADOAdaptiveRequests = false
    let wadoPasswordUnavailable = false
    COMMIT
}

func number(_ node: NSDictionary, _ key: String) -> NSNumber? { return node[key] as? NSNumber }

let node = tlsNode()
let before = node.copy() as! NSDictionary

commitWADO(node, 8443, -1, 1, "wado", "reader", "secret")

// WADO is configured.
check(number(node, "retrieveMode")?.intValue == 2)
check(number(node, "WADOPort")?.intValue == 8443)
check(number(node, "WADOhttps")?.intValue == 1)
check((node["WADOUrl"] as AnyObject?)?.isEqual("wado") == true)
check((node["WADOUsername"] as AnyObject?)?.isEqual("reader") == true)
// The password is in the Keychain, not in the entry.
check(node["WADOPassword"] == nil)
let credential = node["WADOCredential"] as? String ?? ""
check(UUID(uuidString: credential) != nil)
check(keychain[credential].flatMap { String(data: $0, encoding: .utf8) } == "Basic " + Data("reader:secret".utf8).base64EncodedString())
check(number(node, "WADOTransferSyntax")?.intValue == -1)

// Every TLS setting the DIMSE association reads survives untouched.
for case let key as String in before.allKeys where key.hasPrefix("TLS") {
    check((node[key] as AnyObject?)?.isEqual(before[key]) == true)
}
check(number(node, "TLSEnabled")?.boolValue == true)
check(number(node, "TLSAuthenticated")?.boolValue == true)
check((node["TLSCipherSuites"] as? NSArray)?.count == 1)
check(number(node, "TLSCertificateVerification")?.intValue == 1)

// So does the identity of the node itself.
check((node["Address"] as AnyObject?)?.isEqual(before["Address"]) == true)
check((node["Port"] as AnyObject?)?.isEqual(before["Port"]) == true)
check((node["AETitle"] as AnyObject?)?.isEqual(before["AETitle"]) == true)

// Committing again is not a second chance to lose it.
commitWADO(node, 8080, 0, 0, "wado2", nil, nil)
check(number(node, "TLSEnabled")?.boolValue == true)
check(number(node, "WADOPort")?.intValue == 8080)
check(number(node, "WADOhttps")?.intValue == 0)
// Fields the sheet leaves empty do not erase the stored username; an empty
// password field, read from the Keychain when the sheet opened, removes it.
check((node["WADOUsername"] as AnyObject?)?.isEqual("reader") == true)
check(node["WADOCredential"] == nil && keychain.isEmpty)

// A plain node is unaffected either way.
let plain = (["retrieveMode": 0, "TLSEnabled": false] as NSDictionary).mutableCopy() as! NSMutableDictionary
commitWADO(plain, 8080, -1, 0, "wado", nil, nil)
check(number(plain, "TLSEnabled")?.boolValue == false)
check(number(plain, "retrieveMode")?.intValue == 2)

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("ok")
exit(0)
'''

code = code.replace('COMMIT', commit)

with tempfile.TemporaryDirectory() as directory:
    path = Path(directory)
    (path / 'main.swift').write_text(code)
    # The sheet clamps the node's request limit with NodeRequestLimiter, reads
    # its series order with RetrievePlan and keeps the password with
    # WADOCredentials.
    sources = [root / 'Horos/Sources' / name for name in ('NodeRequestLimiter.swift', 'RetrievePlan.swift', 'WADOCredentials.swift',
                                                          'DICOMwebCredentials.swift', 'NonInteractiveKeychainRead.swift')]
    build = subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', str(path / 'main.swift'), *map(str, sources),
                            '-o', str(path / 'test')], capture_output=True, text=True)
    if build.returncode != 0:
        print(build.stderr)
        sys.exit(1)
    result = subprocess.run([str(path / 'test')])

for failure in failures:
    print('FAIL: %s' % failure)
sys.exit(1 if (failures or result.returncode) else 0)
