#!/usr/bin/env python3
"""Movie export failures name a phase and keep a stack.

Encoder, write, finalization, opening the result and viewer-close failures
have to stay distinct. A completed writer followed by the viewer going away is
not an encoder or finalization failure. The log line has to name the phase
and, on failure, keep the stack that was passed in.

QuicktimeExport is Swift: its source is read through
tests/sources.py, and the checks look for the Swift spelling of the same calls.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sources

root = Path(__file__).resolve().parents[1]
helper = root / 'Horos/Sources/MovieExportDiagnostics.swift'
export = sources.source_text('QuicktimeExport')
project = (root / 'Horos.xcodeproj/project.pbxproj').read_bytes().decode('latin1')
failures = []

if not helper.is_file():
    failures.append('Horos/Sources/MovieExportDiagnostics.swift is missing')

if 'MovieExportDiagnostics.logLine(' not in export:
    failures.append('QuicktimeExport.swift does not classify failures through MovieExportDiagnostics')
# The Swift sees MovieExportDiagnostics because both files are in the Horos
# target, where the Objective-C imported Horos-Swift.h.
if 'QuicktimeExport.swift in Sources' not in project:
    failures.append('project.pbxproj does not compile QuicktimeExport.swift with MovieExportDiagnostics.swift')
if 'phase: .encoder' not in export:
    failures.append('QuicktimeExport.swift never logs the encoder phase')
if 'phase: .write' not in export:
    failures.append('QuicktimeExport.swift never logs the write phase')
if 'phase: .finalization' not in export:
    failures.append('QuicktimeExport.swift never logs the finalization phase')
if 'phase: .openingResult' not in export:
    failures.append('QuicktimeExport.swift never logs the opening-result phase')
if 'Thread.callStackSymbols' not in export:
    failures.append('QuicktimeExport.swift does not capture a stack on failure')
if 'MovieExportDiagnostics.swift' not in project:
    failures.append('project.pbxproj does not compile MovieExportDiagnostics.swift')

if helper.is_file():
    driver = r'''
import Foundation

func phase(_ encoderReady: Bool, _ writeFailed: Bool, _ finalized: Bool,
           _ opened: Bool, _ viewerClosed: Bool, _ aborted: Bool) -> MovieExportPhase {
    MovieExportDiagnostics.classify(
        encoderReady: encoderReady,
        writeFailed: writeFailed,
        finalizationCompleted: finalized,
        openSucceeded: opened,
        viewerClosed: viewerClosed,
        aborted: aborted)
}

precondition(phase(false, false, false, true, false, false) == .encoder,
             "missing encoder must be the encoder phase")
precondition(phase(true, true, false, true, false, false) == .write,
             "a rejected frame must be the write phase")
precondition(phase(true, false, false, true, false, false) == .finalization,
             "a writer that never completed must be finalization")
precondition(phase(true, false, true, false, false, false) == .openingResult,
             "a completed file that did not open must be openingResult")
precondition(phase(true, false, true, true, true, false) == .viewerClose,
             "closing the viewer after a completed export is not an export failure")
precondition(phase(true, false, true, true, true, false) != .encoder)
precondition(phase(true, false, true, true, true, false) != .write)
precondition(phase(true, false, true, true, true, false) != .finalization)

precondition(MovieExportDiagnostics.name(for: .encoder) == "encoder")
precondition(MovieExportDiagnostics.name(for: .write) == "write")
precondition(MovieExportDiagnostics.name(for: .finalization) == "finalization")
precondition(MovieExportDiagnostics.name(for: .openingResult) == "openingResult")
precondition(MovieExportDiagnostics.name(for: .viewerClose) == "viewerClose")

let stack = ["0   Horos  MovieExportDiagnostics", "1   Horos  QuicktimeExport"]
let line = MovieExportDiagnostics.logLine(
    phase: .write,
    errorDescription: "rejected pixel buffer",
    stackSymbols: stack)
precondition(line.contains("write"), "log omitted the write phase: \(line)")
precondition(line.contains("rejected pixel buffer"), "log omitted the error: \(line)")
precondition(line.contains("QuicktimeExport"), "log dropped the stack: \(line)")

let success = MovieExportDiagnostics.logLine(
    phase: .finalization,
    errorDescription: "completed",
    stackSymbols: nil)
precondition(success.contains("finalization"), "success log omitted the phase")
precondition(!success.contains("Horos  QuicktimeExport"),
             "a successful completion must not invent a stack")

print("PASS: encoder/write/finalization/openingResult/viewerClose stay distinct; failure keeps stack")
'''
    with tempfile.TemporaryDirectory(prefix='horos-movie-export-phase-') as directory:
        main = Path(directory) / 'main.swift'
        main.write_text(driver)
        binary = Path(directory) / 'phase'
        built = subprocess.run(
            ['xcrun', '--sdk', 'macosx', 'swiftc', '-o', str(binary),
             str(helper), str(main)],
            capture_output=True, text=True)
        if built.returncode != 0:
            failures.append('MovieExportDiagnostics.swift does not compile:\n%s'
                            % (built.stderr or built.stdout)[-1500:])
        else:
            run = subprocess.run([str(binary)], capture_output=True, text=True)
            if run.returncode != 0:
                failures.append('phase classifier failed: %s %s'
                                % (run.stdout[-400:], run.stderr[-800:]))
            elif 'PASS:' not in run.stdout:
                failures.append('phase classifier printed nothing useful: %r' % run.stdout)

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: movie export names encoder, write, finalization, openingResult and '
      'viewerClose; failure logs keep the stack; viewer close is not an encoder '
      'or finalization failure')
