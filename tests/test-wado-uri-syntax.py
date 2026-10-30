#!/usr/bin/env python3
"""Exercise the actual WADO-URI policy and Locations bridge against negotiated bytes.

The loopback fixture is not a dcm4chee installation. It models the identified
syntax decision, and preserves a separate legacy-useOrig compatibility case.
"""
from pathlib import Path
import hashlib
import io
import json
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parent))
import python_with
python_with.require('import pydicom, numpy, pynetdicom', 'from openjpeg import encode, decode',
                    packages="'pydicom>=3,<4' numpy pynetdicom pylibjpeg pylibjpeg-openjpeg")
import numpy as np
from pydicom import dcmread
from pydicom.uid import ExplicitVRLittleEndian, JPEG2000Lossless
root = Path(__file__).resolve().parents[1]
# The query node is Swift; its WADO-URI syntax rule is in IsiXDICOMNetwork.
source = (root / 'Horos/Sources/DCMTKQueryNode+WADO.swift').read_text()
rules = root / 'Modules/IsiXDICOMNetwork/Sources/RetrieveRules.swift'
pane = (root / 'Preference Panes/OSILocationsPreferencePane/OSILocationsPreferencePanePref.swift').read_text()


def block(text, start):
    at = text.index(start)
    opening = text.index('{', at)
    end, depth = opening + 1, 1
    while depth:
        depth += {'{': 1, '}': -1}.get(text[end], 0)
        end += 1
    return text[at:end]


# Actual definitions, not a duplicate map in the test: the UIDs and codes the
# module maps are DCMTK's and the Send sheet's.
enum = re.search(r'enum TransferSyntaxCodes\s*\{(.*?)\};',
                 (root / 'Horos/Sources/SendController.h').read_text(), re.S)[1]
codes, value = {}, -1
for item in [part.strip() for part in re.sub(r'//[^\n]*', '', enum).split(',') if part.strip()]:
    name, _, explicit = item.partition('=')
    value = int(explicit) if explicit.strip() else value + 1
    codes[name.strip()] = value
uids = dict(re.findall(r'^#define\s+(UID_\w+TransferSyntax)\s+"([^"]+)"',
                       (root / 'DCMTK/dcmdata/include/dcmtk/dcmdata/dcuid.h').read_text(), re.M))
assert 'Self.wadoSyntaxQuery(WADOTransferSyntax)' in block(pane, '    @IBAction public func testWADOUrl')
assert '"1", "1", "1", syntax' in block(pane, '    @IBAction public func testWADOUrl')
assert 'with test UIDs' in pane  # Test does not claim verified instance encoding.
assert 'syntaxString(for: Self.int32(parameters["WADOTransferSyntax"]), imageQuality: &quality)' in \
    block(source, '    func wadoRetrieve(study: DCMTKQueryNode?, listing: [String: String]?)')

with tempfile.TemporaryDirectory(prefix='horos-wado-syntax-') as directory:
    work = Path(directory)
    # The node's class method, under its Objective-C name, as Locations finds it.
    policy = 'import Foundation\n@objc(DCMTKQueryNode) final class DCMTKQueryNode: NSObject {\n'
    policy += block(source, '    @objc(syntaxStringFor:imageQuality:)\n    class func syntaxString') + '\n}\n'
    (work / 'Policy.swift').write_text(policy)
    swift = 'import Foundation\nimport ObjectiveC\nfinal class Pane {\n'
    swift += block(pane, '    static func wadoSyntaxQuery') + '\n}\n'
    # Exercise the exact save/reload expressions against an isolated suite.
    save = re.search(r'aServer.setObject\(NSNumber\(value: WADOTransferSyntax\).*', pane)[0]
    load = re.search(r'self.WADOTransferSyntax = objcIntValue\(aServer.value\(forKey: "WADOTransferSyntax"\)\)', pane)[0]
    swift += '''
final class Settings {
    var WADOTransferSyntax: Int32 = -1
    func roundTrip(_ selected: Int32, _ defaults: UserDefaults) -> Int32 {
        WADOTransferSyntax = selected
        let aServer = NSMutableDictionary()
        SAVE
        defaults.set([aServer], forKey: "SERVERS")
        let reloaded = UserDefaults(suiteName: CommandLine.arguments[1])!
        let aServerLoaded = (reloaded.array(forKey: "SERVERS")![0] as! NSDictionary)
        LOAD
        return WADOTransferSyntax
    }
}
func objcIntValue(_ value: Any?) -> Int32 { (value as? NSNumber)?.int32Value ?? 0 }
let suite = CommandLine.arguments[1]
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
var result: [String: String] = [:]
for selected: Int32 in [-1, 0, 1, 10] {
    let loaded = Settings().roundTrip(selected, defaults)
    precondition(loaded == selected, "selected syntax persistence")
    result[String(selected)] = Pane.wadoSyntaxQuery(loaded)!
}
precondition(result["-1"] == "&transferSyntax=*&useOrig=true")
precondition(result["1"] == "&transferSyntax=1.2.840.10008.1.2.4.90")
precondition(result["0"] == "&transferSyntax=1.2.840.10008.1.2.1")
print(String(data: try JSONSerialization.data(withJSONObject: result), encoding: .utf8)!)
'''.replace('SAVE', save).replace('LOAD', load.replace('aServer.value', 'aServerLoaded.value'))
    (work / 'main.swift').write_text(swift)
    # Every code of the Send sheet against the UID DCMTK defines for it.
    expected = {'SendExplicitLittleEndian': 'UID_LittleEndianExplicitTransferSyntax',
                'SendJPEG2000Lossless': 'UID_JPEG2000LosslessOnlyTransferSyntax',
                'SendJPEG2000Lossy10': 'UID_JPEG2000TransferSyntax', 'SendJPEG2000Lossy20': 'UID_JPEG2000TransferSyntax',
                'SendJPEG2000Lossy50': 'UID_JPEG2000TransferSyntax',
                'SendJPEGLSLossless': 'UID_JPEGLSLosslessTransferSyntax', 'SendJPEGLSLossy10': 'UID_JPEGLSLossyTransferSyntax',
                'SendJPEGLSLossy20': 'UID_JPEGLSLossyTransferSyntax', 'SendJPEGLSLossy50': 'UID_JPEGLSLossyTransferSyntax',
                'SendJPEGLossless': 'UID_JPEGProcess14SV1TransferSyntax', 'SendJPEGLossy9': 'UID_JPEGProcess2_4TransferSyntax',
                'SendJPEGLossy8': 'UID_JPEGProcess2_4TransferSyntax', 'SendJPEGLossy7': 'UID_JPEGProcess2_4TransferSyntax',
                'SendImplicitLittleEndian': 'UID_LittleEndianImplicitTransferSyntax', 'SendRLE': 'UID_RLELosslessTransferSyntax',
                'SendExplicitBigEndian': 'UID_BigEndianExplicitTransferSyntax'}
    table = 'let codes: [String: Int] = [' + ', '.join('"%s": %d' % (name, codes[name]) for name in expected) + ']\n'
    table += 'let uids: [String: String] = [' + ', '.join('"%s": "%s"' % (name, uids[uid]) for name, uid in expected.items()) + ']\n'
    table += '''for (name, code) in codes {
    var quality: Int32 = 0
    precondition(DCMTKQueryNode.syntaxString(for: Int32(code), imageQuality: &quality) == "&transferSyntax=" + uids[name]!, name)
}
'''
    (work / 'main.swift').write_text((work / 'main.swift').read_text().replace('var result: [String: String] = [:]\n', table + 'var result: [String: String] = [:]\n'))
    subprocess.run(['xcrun', 'swiftc', '-warnings-as-errors', str(work / 'main.swift'), str(work / 'Policy.swift'),
                    str(rules), '-o', str(work / 'policy')], check=True)
    queries = json.loads(subprocess.check_output([str(work / 'policy'), 'org.horos.test.wado.' + work.name], text=True))
    fixture = work / 'fixture'
    subprocess.run([sys.executable, str(root / 'tools/generate-jpeg2000-multiframe-fixture.py'),
                    str(fixture), '--frames', '4', '--size', '32'], check=True, capture_output=True)
    original = dcmread(fixture / 'wado.dcm')
    original_bytes = (fixture / 'wado.dcm').read_bytes()
    original_pixels = original.pixel_array
    for mode in ('dcm4chee', 'legacy-useOrig'):
        evidence = work / mode
        server = subprocess.Popen([sys.executable, str(root / 'tools/serve-wado-fixture.py'),
                                   str(fixture), str(evidence), '--dicom-port', '0', '--wado-port', '0',
                                   '--negotiate-transfer-syntax', mode], stdout=subprocess.DEVNULL,
                                  stderr=subprocess.PIPE, text=True)
        try:
            state = None
            for _ in range(200):
                if server.poll() is not None:
                    raise AssertionError(server.stderr.read())
                try:
                    state = json.loads((evidence / 'wado-results.json').read_text())
                    if state['ready']:
                        break
                except (FileNotFoundError, json.JSONDecodeError):
                    pass
                time.sleep(.05)
            assert state and state['ready'], 'fixture readiness'
            parameters = dict(requestType='WADO', studyUID=str(original.StudyInstanceUID),
                              seriesUID=str(original.SeriesInstanceUID), objectUID=str(original.SOPInstanceUID),
                              contentType='application/dicom')
            base = f"http://127.0.0.1:{state['wado_port']}/wado?" + urllib.parse.urlencode(parameters)
            cases = [(-1, str(JPEG2000Lossless)), (0, str(ExplicitVRLittleEndian))]
            if mode == 'dcm4chee':
                cases += [(1, str(JPEG2000Lossless)), ('old', str(ExplicitVRLittleEndian))]
            for selected, syntax in cases:
                query = '&useOrig=true' if selected == 'old' else queries[str(selected)]
                with urllib.request.urlopen(base + query) as response:
                    assert response.status == 200
                    assert response.headers.get_content_type() == 'application/dicom'
                    body = response.read()  # Before any importer.
                received = dcmread(io.BytesIO(body))
                assert str(received.file_meta.TransferSyntaxUID) == syntax
                for uid in ('StudyInstanceUID', 'SeriesInstanceUID', 'SOPInstanceUID'):
                    assert getattr(received, uid) == getattr(original, uid)
                assert int(received.NumberOfFrames) == 4
                assert np.array_equal(received.pixel_array, original_pixels)
                if syntax == str(JPEG2000Lossless):
                    assert received.PixelData == original.PixelData, 'encapsulated fragments'
                    assert hashlib.sha256(body).digest() == hashlib.sha256(original_bytes).digest()
                else:
                    assert not received['PixelData'].is_undefined_length
            if mode == 'dcm4chee':
                try:
                    urllib.request.urlopen(base + queries['10'])
                    raise AssertionError('unsupported syntax silently succeeded')
                except urllib.error.HTTPError as error:
                    assert error.code == 406
                    assert error.headers.get_content_type() == 'text/plain'
                    assert not error.read()[128:132] == b'DICM'
                state = json.loads((evidence / 'wado-results.json').read_text())
                assert state['refused'][-1]['status'] == 406
        finally:
            server.terminate()
            server.communicate(timeout=10)
print('PASS: actual node policy + Swift bridge/persistence; wildcard/.90 preserve file, fragments, UIDs, 4 frames and pixels; Explicit LE and old request decompress; unsupported=406; legacy useOrig compatibility')
