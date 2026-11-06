#!/usr/bin/env python3
"""A path that cannot be used is refused before it reaches the scanner.

Every crash report gathered under this heading ends in `strlen` inside
`+[DicomFile isDICOMFile:compressed:image:]`. The method built its argument like
this:

    filenames.push_back( std::string([filePath UTF8String]) );

`-UTF8String` returns NULL for a nil path, and for a name holding characters it
cannot encode. `std::string(NULL)` reads until it finds a zero byte - that is the
strlen - and the `try { } catch (...)` around it cannot catch a segmentation
fault.

Nothing that is not a usable path can be a DICOM file, so the method now says so
and returns.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
failures = []
# The guard was in +isDICOMFile: of DicomFile.mm; it is in the DCMTK adapter the
# Swift method calls now (Adapters/DCMTK/IsiXDCMTKFileProbe.mm).
legacy = root / 'Horos/Sources/DicomFile.mm'
if legacy.exists():
    source = legacy.read_bytes().decode('latin1')
    signature = '+ (BOOL) isDICOMFile:(NSString *) filePath compressed:(BOOL*) compressed image:(BOOL*) image mayTranscode:'
    call, refusal, catch = ('HorosDICOMProbe::inspect(path)', 'if (!path || !*path) return NO;',
                            '@catch (NSException *exception) { return NO; }')
else:
    source = (root / 'Horos/Sources/Adapters/DCMTK/IsiXDCMTKFileProbe.mm').read_text()
    signature = '+ (IsiXDCMTKFileProbeResult)inspectFileAtPath:(NSString *)path error:(NSError **)error'
    call, refusal, catch = ('HorosDICOMProbe::inspect(fileSystemPath)', 'if (!fileSystemPath || !*fileSystemPath) {',
                            '@catch (NSException *exception) { fileSystemPath = NULL; }')
    classification = (root / 'Horos/Sources/DicomFile+Classification.swift').read_text()
    if 'IsiXDCMTKFileProbe.inspectFile(atPath: file)' not in classification:
        failures.append('+isDICOMFile: does not ask the guarded adapter')

at = source.find(signature)
if at < 0:
    failures.append('the method the crash reports name is gone')
else:
    opening = source.index('{', at)
    depth, index, body = 0, opening, ''
    while index < len(source):
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                body = source[opening:index + 1]
                break
        index += 1

    guard = body.find('fileSystemRepresentation')
    probe = body.find(call)
    if not (0 <= guard < probe):
        failures.append('the native path conversion must precede the probe')
    if refusal not in body[:probe]:
        failures.append('an unusable path is not refused before the parser')
    if catch not in body[:probe]:
        failures.append('an unrepresentable NSString can escape as an exception')
    if 'std::string([filePath UTF8String])' in body or 'gdcm::Scanner' in body:
        failures.append('the unsafe legacy scanner path remains')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: nil, empty and unrepresentable native paths are guarded before the lazy probe; runtime coverage lives in the transfer-syntax test')
