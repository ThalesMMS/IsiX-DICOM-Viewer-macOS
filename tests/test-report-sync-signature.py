#!/usr/bin/env python3
"""Activating the app re-checks open reports only when their files changed.

Each time the app becomes active, BrowserController.syncReportsIfNecessary
checks every report opened in the session against its archived DICOM SR. The
check extracts the SR and compares contents on the main thread, which costs
milliseconds per megabyte of every report. It now runs only when the
ReportFileSignature of the report and its SR differs from the one recorded at
the last successful check.

Compiles the production ReportFileSignature.swift and verifies that the
signature is stable while nothing changes and differs after an edit that keeps
the modification date, after a change inside a document package, after an
atomic save and after a new SR, and that the browser skips the extraction only
on an equal signature. `<git revision>` as an optional argument reads the
sources from that revision, the negative control.
"""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
failures = []


def read(path):
    if revision:
        result = subprocess.run(['git', '-C', str(root), 'show', f'{revision}:{path}'], capture_output=True)
        return result.stdout.decode('utf-8') if result.returncode == 0 else None
    file = root / path
    return file.read_text() if file.exists() else None


def body(text, signature):
    at = text.find(signature)
    if at < 0:
        return ''
    opening = text.index('{', at)
    depth = 0
    for index in range(opening, len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[opening:index + 1]
    return ''


source = read('Horos/Sources/ReportFileSignature.swift')
reports = read('Horos/Sources/BrowserController+Reports.swift') or ''
project = read('Horos.xcodeproj/project.pbxproj') or ''

sync = body(reports, 'func syncReportsIfNecessary()')
skip = sync.find('ReportFileSignature.signature(')
extract = sync.find('extractReportSR(')
if skip < 0 or extract < 0 or skip > extract or 'continue' not in sync[skip:extract]:
    failures.append('syncReportsIfNecessary extracts every report SR without checking its signature first')
if 'forKey: "signature"' not in sync or '!archived' not in sync:
    failures.append('syncReportsIfNecessary does not record the signature of a verified report')
if 'ReportFileSignature.swift in Sources' not in project:
    failures.append('ReportFileSignature.swift is not compiled into the app')

if source is None:
    failures.append('ReportFileSignature.swift does not exist')
else:
    driver = 'print(ReportFileSignature.signature(ofPaths: Array(CommandLine.arguments.dropFirst())) ?? "nil")\n'
    with tempfile.TemporaryDirectory(prefix='horos-report-signature-') as directory:
        work = Path(directory)
        (work / 'ReportFileSignature.swift').write_text(source)
        (work / 'main.swift').write_text(driver)
        subprocess.run(['xcrun', 'swiftc', str(work / 'ReportFileSignature.swift'), str(work / 'main.swift'),
                        '-o', str(work / 'signature')], check=True)

        def signature(*paths):
            return subprocess.run([str(work / 'signature'), *map(str, paths)], check=True,
                                  capture_output=True, text=True).stdout.strip()

        report = work / 'report.docx'
        report.write_bytes(b'first version')
        sr = work / 'report.dcm'
        sr.write_bytes(b'archived')
        package = work / 'report.pages'
        (package / 'Data').mkdir(parents=True)
        (package / 'Index.zip').write_bytes(b'index')
        (package / 'Data' / 'image.jpg').write_bytes(b'image')

        first = signature(report, sr)
        if first == 'nil' or first != signature(report, sr):
            failures.append('the signature of unchanged files is not stable')

        stat = report.stat()
        report.write_bytes(b'other version')
        os.utime(report, ns=(stat.st_atime_ns, stat.st_mtime_ns))
        if report.stat().st_mtime_ns != stat.st_mtime_ns or signature(report, sr) == first:
            failures.append('an edit that keeps the modification date keeps the signature')

        before = signature(report, sr)
        replacement = work / 'saved.tmp'
        replacement.write_bytes(b'other version')
        os.utime(replacement, ns=(stat.st_atime_ns, stat.st_mtime_ns))
        os.replace(replacement, report)
        if signature(report, sr) == before:
            failures.append('an atomic save keeps the signature')

        before = signature(report, sr)
        newer = work / 'newer.dcm'
        newer.write_bytes(b'archived')
        if signature(report, newer) == before:
            failures.append('a new SR keeps the signature')

        packaged = signature(package, sr)
        directory_times = package.stat()
        (package / 'Data' / 'image.jpg').write_bytes(b'IMAGE')
        os.utime(package, ns=(directory_times.st_atime_ns, directory_times.st_mtime_ns))
        os.utime(package / 'Data', ns=(directory_times.st_atime_ns, directory_times.st_mtime_ns))
        if packaged == 'nil' or signature(package, sr) == packaged:
            failures.append('a change inside a document package keeps the signature')

        if signature(work / 'missing.docx', sr) != 'nil':
            failures.append('a missing report has a signature')

for failure in failures:
    print(f'FAIL: {failure}')
if failures:
    sys.exit(1)
print('PASS: open reports are re-checked on activation only when the report or its SR changed')
