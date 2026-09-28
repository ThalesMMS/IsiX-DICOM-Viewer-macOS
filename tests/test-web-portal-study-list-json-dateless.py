#!/usr/bin/env python3
"""The portal's /studyList.json lists a study without a date (#759).

-processStudyListJson put the study's formatted date in each study's dictionary
with setObject:forKey:, which raises for nil. A study without a date (a DICOMDIR
imported without StudyDate, whose ZDATE is null) raised inside the list's @try;
the @catch only logged it, the response kept no data and the portal answered
404 for the whole list. The date now goes through N2NonNullString like the
other fields, so that study is listed with an empty date and the others too.

The date statement is taken as it is from processStudyListJson in
WebPortalConnection+Data.swift and compiled with that file's own helpers
(objcNonNull, objcSetObject, objcStringFromDate, objcTry) and the real
HorosObjCException, in the list's loop over three studies, the middle one
without a date. The list must come out whole, the dateless study with "".

`<git revision>` as an optional argument reads the source from that revision,
the negative control.
"""
from pathlib import Path
import json
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
path = 'Horos/Sources/WebPortalConnection+Data.swift'
source = (subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode()
          if revision else (root / path).read_text())


def function(signature):
    """A top-level function of the file, from its signature to its closing brace."""
    at = source.find(signature)
    if at < 0:
        print(f'FAIL: {signature!r} is not in {path}')
        sys.exit(1)
    end = source.find('\n}\n', at)
    return source[at:end + 3]


helpers = [function(s) for s in ('private func objcNonNull(_ s: String?)',
                                 'private func objcSetObject(_ dictionary: NSMutableDictionary?, _ object: Any?',
                                 'private func objcStringFromDate(_ formatter: DateFormatter?',
                                 'private func objcTry(_ body: () -> Void')]

at = source.find('public func processStudyListJson()')
body = source[at:source.find('\n    }\n', at)] if at >= 0 else ''
statements = [line.strip() for line in body.split('\n') if 'forKey: "date"' in line and not line.strip().startswith('//')]
if len(statements) != 1:
    print(f'FAIL: processStudyListJson has {len(statements)} statements that set "date", expected one')
    sys.exit(1)

main = r'''
import Foundation

extension UserDefaults {
    @objc class func dateTimeFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }
}

/// DicomStudy's name and date (NSDate*, nil when the study has none).
final class Study {
    let name: String?
    let date: Date?
    init(_ name: String, _ date: Date?) { self.name = name; self.date = date }
}

let studies = [Study("DATED^ONE", Date(timeIntervalSince1970: 0)),
               Study("SYNTHETIC^DICOMDIR", nil),
               Study("DATED^TWO", Date(timeIntervalSince1970: 86400))]
var data: String? = nil
objcTry({
    let r = NSMutableArray()
    for study in studies {
        let s = NSMutableDictionary()
        s.setObject(objcNonNull(study.name), forKey: "name" as NSString)
        STATEMENT
        r.add(s)
    }
    data = String(data: try! JSONSerialization.data(withJSONObject: r), encoding: .utf8)
}, catch: { e in
    print("raised: \(e.name.rawValue): \(e.reason ?? "")")
})
print("data: \(data ?? "none")")

// The helpers, private to the file as in WebPortalConnection+Data.swift.
HELPERS
'''.replace('STATEMENT', statements[0]).replace('HELPERS', '\n'.join(helpers))

with tempfile.TemporaryDirectory(prefix='horos-study-list-json-') as tmp:
    p = Path(tmp)
    (p / 'main.swift').write_text(main)
    (p / 'bridging.h').write_text('#import <Foundation/Foundation.h>\n#import "HorosObjCException.h"\n')
    subprocess.run(['xcrun', 'clang', '-c', '-fno-objc-arc', '-I', str(root / 'Horos/Sources'),
                    str(root / 'Horos/Sources/HorosObjCException.m'), '-o', str(p / 'HorosObjCException.o')], check=True)
    build = subprocess.run(['xcrun', 'swiftc', '-module-name', 'Horos', '-import-objc-header', str(p / 'bridging.h'),
                            '-Xcc', '-I' + str(root / 'Horos/Sources'), str(p / 'main.swift'),
                            str(p / 'HorosObjCException.o'), '-o', str(p / 'list')], capture_output=True, text=True)
    if build.returncode != 0:
        print(build.stderr)
        print('FAIL: the harness did not compile')
        sys.exit(1)
    run = subprocess.run([str(p / 'list')], capture_output=True, text=True, timeout=60)

print(run.stdout.strip())
failures = []
raised = re.search(r'^raised: (.*)$', run.stdout, re.M)
if raised:
    failures.append(f'building the list raised ({raised.group(1)}); the response has no data and the portal answers 404')
listed = re.search(r'^data: (.*)$', run.stdout, re.M)
studies = json.loads(listed.group(1)) if listed and listed.group(1) != 'none' else []
dates = {s.get('name'): s.get('date') for s in studies}
expected = {'DATED^ONE': '1970-01-01 00:00', 'SYNTHETIC^DICOMDIR': '', 'DATED^TWO': '1970-01-02 00:00'}
if dates != expected:
    failures.append(f'listed {dates or "nothing"}, expected {expected}')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: /studyList.json lists a study without a date with an empty date, and the studies around it')
