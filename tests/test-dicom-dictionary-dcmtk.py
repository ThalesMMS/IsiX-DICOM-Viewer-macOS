#!/usr/bin/env python3
"""The DCM tag dictionaries built from DCMTK answer as the former plists did.

Compiles Horos/Sources/DICOMDataDictionary.mm with the DCMTK archives of a
current build, loads the dicom.dic the application ships (as the application
does, from beside the executable) and dumps +[HorosDICOMDictionaries
tagDictionary] and +tagForNameDictionary. Against the DCM Framework's former
tagDictionary.plist and nameDictionary.plist, for the whole dictionary:

- every former name resolves to the same tag;
- every former tag carries the same name;
- every former tag carries the same VR, except where DCMTK corrects it (listed
  below; the list is closed, so a new difference fails);
- tags the former dictionary lacked are counted, not compared.

With --dump FILE the two dictionaries are also written there as JSON, which is
how HorosDICOMLegacyNames.h was made.

The former plists left the repository; by default they are read from
the removal commit available in Git history (legacy_dictionary.py).

Usage: python test-dicom-dictionary-dcmtk.py [--legacy DIR] [--dump FILE]
       DIR holds tagDictionary.plist and nameDictionary.plist (default: from Git history)
"""
import argparse
import json
import plistlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dcmtk_build import BUILD, ROOT, dcmtk_flags
import legacy_dictionary

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument('--legacy', type=Path)
parser.add_argument('--dump', type=Path)
args = parser.parse_args()

if args.legacy:
    legacy_tags_bytes = (args.legacy / 'tagDictionary.plist').read_bytes()
    legacy_names_bytes = (args.legacy / 'nameDictionary.plist').read_bytes()
else:
    legacy_tags_bytes = legacy_dictionary.legacy_bytes('tagDictionary.plist')
    legacy_names_bytes = legacy_dictionary.legacy_bytes('nameDictionary.plist')
if not legacy_tags_bytes or not legacy_names_bytes:
    print('skipped: needs the former DCM dictionaries (Git history): --legacy DIR', file=sys.stderr)
    raise SystemExit(2)
dictionary_file = BUILD.parent.parent.parent / 'Products' / BUILD.name / 'DCMTK/dicom.dic'
if not dictionary_file.is_file():
    dictionary_file = ROOT / 'DCMTK/dcmdata/data/dicom.dic'
flags = dcmtk_flags()

# DCMTK knows these tags better than the 2005 table did: URIs are UR, some
# former strings are sequences, curve and overlay data are OB/OW. Each pair is
# (former VR, DCMTK VR as the DCM Framework spells it). The list is closed.
CORRECTED_VR = {
    '0000,0010': ('CS', 'SH'), '0000,4000': ('AT', 'LT'), '0000,4010': ('AT', 'LT'),
    '0000,5110': ('AT', 'LT'), '0000,5120': ('AT', 'LT'), '0004,1504': ('up', 'UL'),
    '0008,0010': ('CS', 'SH'), '0008,0062': ('CS', 'UI'), '0008,1000': ('LO', 'AE'),
    '0010,1050': ('LT', 'LO'), '0014,3022': ('DS', 'ST'), '0014,3050': ('ox', 'OB/OW'),
    '0014,3070': ('ox', 'OB/OW'), '0018,603D': ('X0', 'SL'), '0018,603F': ('Y0', 'SL'),
    '0020,0080': ('LO', 'CS'), '0020,3100': ('LO', 'CS'), '0020,3401': ('LO', 'CS'),
    '0020,3402': ('LO', 'CS'), '0028,005F': ('CS', 'LO'), '0028,0062': ('SH', 'LO'),
    '0028,0400': ('CS', 'LO'), '0028,0401': ('CS', 'LO'), '0028,0403': ('CS', 'LO'),
    '0028,0412': ('CS', 'LO'), '0028,0700': ('CS', 'LO'), '0028,7FE0': ('UT', 'UR'),
    '0040,E010': ('UT', 'UR'), '0068,62F0': ('FD', 'SQ'), '0074,100A': ('ST', 'UR'),
    '0076,0034': ('CS', 'SQ'), '5000,3000': ('FL', 'OB/OW'), '5002,3000': ('FL', 'OB/OW'),
    '5004,3000': ('FL', 'OB/OW'), '5006,3000': ('FL', 'OB/OW'), '5008,3000': ('FL', 'OB/OW'),
    '5010,3000': ('FL', 'OB/OW'), '5012,3000': ('FL', 'OB/OW'), '5014,3000': ('FL', 'OB/OW'),
    '6000,3000': ('ox', 'OB/OW'),
}
# The former table also wrote DCMTK's own "xs" where the DCM parser means US/SS.
SAME_VR = {('xs', 'US/SS'), ('xs', 'US/SS/OW')}
# Keys that are ranges, not tags ("0000,u-ff"); no tag lookup reaches them.
def is_tag(key):
    return len(key) == 9 and all(c in '0123456789ABCDEF,' for c in key)

driver = r'''
#import <Foundation/Foundation.h>
#import "DICOMDataDictionary.h"
int main(int argc, char **argv) { @autoreleasepool {
    NSDictionary *both = @{@"tags": [HorosDICOMDictionaries tagDictionary],
                           @"names": [HorosDICOMDictionaries tagForNameDictionary]};
    NSData *json = [NSJSONSerialization dataWithJSONObject: both options: NSJSONWritingSortedKeys error: NULL];
    fwrite(json.bytes, 1, json.length, stdout);
    return 0;
}}
'''

with tempfile.TemporaryDirectory(prefix='horos-dictionary-') as work:
    work = Path(work)
    (work / 'driver.mm').write_text(driver)
    subprocess.run(['xcrun', 'clang++', '-std=c++17', '-fobjc-arc', '-w', *flags[:2],
                    str(work / 'driver.mm'), str(ROOT / 'Horos/Sources/DICOMDataDictionary.mm'),
                    '-framework', 'Foundation', *flags[2:], '-o', str(work / 'driver')], check=True)
    shutil.copy(dictionary_file, work / 'dicom.dic')  # beside the executable, as for Decompress
    built = json.loads(subprocess.run([str(work / 'driver')], capture_output=True, check=True).stdout)

if args.dump:
    args.dump.write_text(json.dumps(built, indent=1))
tags, names = built['tags'], built['names']
legacy_tags = plistlib.loads(legacy_tags_bytes)
legacy_names = plistlib.loads(legacy_names_bytes)

failures = []
for name, tag in sorted(legacy_names.items()):
    if is_tag(tag) and names.get(name) != tag:
        failures.append('name %s: %s, formerly %s' % (name, names.get(name), tag))
vr_corrected = 0
for tag, entry in sorted(legacy_tags.items()):
    if not is_tag(tag):
        continue
    now = tags.get(tag)
    if now is None:
        failures.append('tag %s (%s) is missing' % (tag, entry['Description']))
        continue
    if now['Description'] != entry['Description']:
        failures.append('tag %s is named %s, formerly %s' % (tag, now['Description'], entry['Description']))
    if now['VR'] != entry.get('VR'):
        if (entry.get('VR'), now['VR']) in SAME_VR:
            pass
        elif CORRECTED_VR.get(tag) == (entry.get('VR'), now['VR']):
            vr_corrected += 1
        else:
            failures.append('tag %s (%s) has VR %s, formerly %s' % (tag, entry['Description'], now['VR'], entry.get('VR')))

new = len(set(tags) - set(legacy_tags))
print('%d former names and %d former tags compared; %d VRs corrected by DCMTK; %d tags only DCMTK knows'
      % (len(legacy_names), len(legacy_tags), vr_corrected, new))
for failure in failures[:40]:
    print('FAIL: ' + failure)
if len(failures) > 40:
    print('... and %d more' % (len(failures) - 40))
sys.exit(1 if failures else 0)
