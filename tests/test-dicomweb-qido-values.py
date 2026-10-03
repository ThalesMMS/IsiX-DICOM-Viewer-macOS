#!/usr/bin/env python3
"""Run the reader of QIDO-RS results (DICOM JSON) the query node puts into DCMTK.

DICOMwebQueryRecord.swift is compiled as it ships and fed JSON text through
JSONSerialization, as the client's records reach it. The cases:

- a person name with only an Ideographic group, one with "Alphabetic": null,
  and one with only Phonetic, keep the name; Alphabetic still comes first;
- a null in the middle of a multi-valued attribute keeps its empty position,
  so the values after it stay in place once joined with backslashes;
- IS and DS sent as JSON numbers and as strings give the same text;
- an attribute whose every value is null, a sequence, an attribute without a
  Value array and a key that is not a tag are left out.

The query node only joins each list with backslashes and inserts it; that the
node calls this reader is checked in its source.
"""
from pathlib import Path
import json
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]

record = {
    '00100010': {'vr': 'PN', 'Value': [{'Ideographic': '山田^太郎'}]},
    '00081060': {'vr': 'PN', 'Value': [{'Alphabetic': None, 'Ideographic': '佐藤^花子', 'Phonetic': 'さとう^はなこ'}]},
    '00081070': {'vr': 'PN', 'Value': [{'Alphabetic': None, 'Ideographic': None, 'Phonetic': 'すずき^いちろう'}]},
    '00080090': {'vr': 'PN', 'Value': [{'Alphabetic': 'Yamada^Taro', 'Ideographic': '山田^太郎'}, None, {'Alphabetic': 'Doe^Jane'}]},
    '00080061': {'vr': 'CS', 'Value': ['CT', None, 'MR']},
    '00201208': {'vr': 'IS', 'Value': [12]},
    '00201206': {'vr': 'IS', 'Value': ['3']},
    '00280030': {'vr': 'DS', 'Value': [0.5, '0.25']},
    '00180050': {'vr': 'DS', 'Value': [1.5]},
    '00181030': {'vr': 'LO', 'Value': [None]},
    '00081110': {'vr': 'SQ', 'Value': [{'00081150': {'vr': 'UI', 'Value': ['1.2.3']}}]},
    '00100020': {'vr': 'LO'},
    'PatientID': {'vr': 'LO', 'Value': ['not a tag']},
    '+0100010': {'vr': 'LO', 'Value': ['not a tag either']},
}

expected = {
    0x00100010: ['山田^太郎'],
    0x00081060: ['佐藤^花子'],
    0x00081070: ['すずき^いちろう'],
    0x00080090: ['Yamada^Taro', '', 'Doe^Jane'],
    0x00080061: ['CT', '', 'MR'],
    0x00201208: ['12'],
    0x00201206: ['3'],
    0x00280030: ['0.5', '0.25'],
    0x00180050: ['1.5'],
}

check = r'''
import Foundation
@main struct Check {
 static func main() {
  let data = FileManager.default.contents(atPath: CommandLine.arguments[1])!
  let record = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
  let values = DICOMwebQueryRecord.stringValues(of: record)
  var out: [String: [String]] = [:]
  for (tag, strings) in values { out[String(tag.uint32Value)] = strings + [strings.joined(separator: "\\")] }
  let json = try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
  FileManager.default.createFile(atPath: CommandLine.arguments[2], contents: json)
 }
}
'''

failures = []
node = (root / 'Horos/Sources/DCMTKQueryNode.mm').read_text()
query = node[node.index('- (BOOL)queryDICOMwebWithDataset'):]
query = query[:query.index('\n}\n')]
if '[HorosDICOMwebQueryRecord stringValuesOfRecord:record]' not in query or 'componentsJoinedByString:@"\\\\"' not in query:
    failures.append('the query node reads each QIDO-RS result with DICOMwebQueryRecord and joins its values with backslashes')
if '"Alphabetic"' in query or '"Value"' in query:
    failures.append('the query node leaves the DICOM JSON rules to DICOMwebQueryRecord')

with tempfile.TemporaryDirectory(prefix='horos-qido-values-') as tmp:
    p = Path(tmp)
    (p / 'check.swift').write_text(check)
    (p / 'record.json').write_text(json.dumps(record, ensure_ascii=False), encoding='utf-8')
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-suppress-warnings',
                    str(root / 'Horos/Sources/DICOMwebQueryRecord.swift'), str(p / 'check.swift'), '-o', str(p / 'check')],
                   check=True, timeout=300)
    subprocess.run([str(p / 'check'), str(p / 'record.json'), str(p / 'out.json')], check=True, timeout=30)
    result = {int(tag): values for tag, values in json.loads((p / 'out.json').read_text(encoding='utf-8')).items()}

for tag, values in expected.items():
    got = result.get(tag)
    if got is None or got[:-1] != values or got[-1] != '\\'.join(values):
        failures.append(f'{tag:08X}: expected {values}, got {got}')
for tag in sorted(set(result) - set(expected)):
    failures.append(f'{tag:08X} should be left out, got {result[tag]}')

for failure in failures:
    print('FAIL:', failure)
if not failures:
    print('PASS: Ideographic-only, null-Alphabetic and Phonetic-only person names kept; a null keeps its position in a '
          'multi-value; IS and DS as numbers and as strings; all-null, sequence, value-less and non-tag attributes left out')
sys.exit(1 if failures else 0)
