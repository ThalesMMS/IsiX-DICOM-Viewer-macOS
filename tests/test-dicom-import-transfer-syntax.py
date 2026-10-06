#!/usr/bin/env python3
"""Incoming gates agree on native byte order/VR, SR and embedded icons."""
from pathlib import Path
import struct
import subprocess
import tempfile
import sys
from dcmtk_build import dcmtk_flags

root = Path(__file__).resolve().parents[1]

def element(tag, vr, value, order='<', implicit=False):
    header = struct.pack(order + 'HH', *tag)
    if implicit:
        return header + struct.pack(order + 'I', len(value)) + value
    if vr in ('OB', 'OW', 'SQ', 'UN', 'UT'):
        return header + vr.encode() + b'\0\0' + struct.pack(order + 'I', len(value)) + value
    return header + vr.encode() + struct.pack(order + 'H', len(value)) + value

def fixture(syntax, sop='1.2.840.10008.5.1.4.1.1.2', image=True, frame_count=None, private=b''):
    implicit = syntax == '1.2.840.10008.1.2'
    order = '>' if syntax.endswith('.2.2') else '<'
    def entry(tag, vr, value):
        if isinstance(value, int):
            value = struct.pack(order + 'H', value)
        elif isinstance(value, str):
            value = value.encode(); value += b'\0' * (len(value) % 2)
        return element(tag, vr, value, order, implicit)
    uid = syntax.encode(); uid += b'\0' * (len(uid) % 2)
    data = b'\0' * 128 + b'DICM' + element((2, 0x10), 'UI', uid)
    data += entry((8, 0x16), 'UI', sop)
    data += private
    if frame_count is not None:
        data += entry((0x28, 8), 'IS', str(frame_count))
    if image:
        for tag, value in [(2, 1), (0x10, 7), (0x11, 9), (0x100, 16), (0x101, 12)]:
            data += entry((0x28, tag), 'US', value)
        data += entry((0x7FE0, 0x10), 'OW', b'\0' * 126)
    return data


def item(payload, undefined=False, order='<'):
    return (struct.pack(order + 'HHI', 0xFFFE, 0xE000, 0xFFFFFFFF if undefined else len(payload))
            + payload + (struct.pack(order + 'HHI', 0xFFFE, 0xE00D, 0) if undefined else b''))


def unknown_sequence(syntax, undefined_item=False, nesting=0):
    # CP-246: UN's value, including item headers, is Implicit VR Little Endian
    # even when the enclosing dataset is Explicit VR Big Endian.
    payload = element((0x11, 0x10), 'LO', b'SYNTHETIC ', implicit=True)
    # Nested image dimensions must not replace the root's dimensions.
    payload += element((0x28, 0x10), 'US', struct.pack('<H', 1), implicit=True)
    for _ in range(nesting):
        payload = (struct.pack('<HHI', 0x11, 0x1010, 0xFFFFFFFF) + item(payload, True)
                   + struct.pack('<HHI', 0xFFFE, 0xE0DD, 0))
    order = '>' if syntax.endswith('.2.2') else '<'
    return (struct.pack(order + 'HH', 9, 0x105F) + b'UN\0\0' + struct.pack(order + 'I', 0xFFFFFFFF)
            + item(payload, undefined_item) + struct.pack('<HHI', 0xFFFE, 0xE0DD, 0))


def icon_sequence(order='<', fragments=None):
    # An Icon Image Sequence whose Pixel Data is encapsulated, as the incoming
    # compressor writes it: the fragments are not a dataset.
    if fragments is None:
        fragments = (struct.pack(order + 'HHI', 0xFFFE, 0xE000, 0)
                     + struct.pack(order + 'HHI', 0xFFFE, 0xE000, 4) + b'\xffO\xffQ'
                     + struct.pack(order + 'HHI', 0xFFFE, 0xE0DD, 0))
    payload = element((0x28, 0x10), 'US', struct.pack(order + 'H', 64), order)
    payload += element((0x28, 0x11), 'US', struct.pack(order + 'H', 64), order)
    payload += struct.pack(order + 'HH', 0x7FE0, 0x10) + b'OB\0\0' + struct.pack(order + 'I', 0xFFFFFFFF) + fragments
    return element((0x88, 0x200), 'SQ', item(payload, order=order), order)


main = r'''
import Foundation
let path = CommandLine.arguments[1]
for name in ["implicit", "explicit", "big"] {
    let result = EnhancedImportTriage.assessPath(path + "/" + name)
    precondition(result.rows == 7 && result.columns == 9 && result.bitsAllocated == 16)
    precondition(result.pixelDataBytes == 126 && result.mayMergeIntoIncoming)
    let ultrasound = IVUSImportTriage.assessPath(path + "/us-" + name)
    precondition(ultrasound.rows == 7 && ultrasound.columns == 9 && ultrasound.mayMergeIntoIncoming)
}
let sr = EnhancedImportTriage.assessPath(path + "/sr")
precondition(sr.mayMergeIntoIncoming && sr.rows == 0 && sr.columns == 0)
let huge = EnhancedImportTriage.assessPath(path + "/overflow")
precondition(!huge.mayMergeIntoIncoming && huge.recordedError?.contains("byte count") == true)
let missing = EnhancedImportTriage.assessPath(path + "/missing")
precondition(!missing.mayMergeIntoIncoming)
for name in try FileManager.default.contentsOfDirectory(atPath: path) where name.hasPrefix("un-") || name.hasPrefix("sq-") {
    let result = EnhancedImportTriage.assessPath(path + "/" + name)
    precondition(result.mayMergeIntoIncoming && result.rows == 7 && result.columns == 9,
                 "UN/SQ sequence lost the outer dataset: \(name)")
    precondition(result.pixelDataBytes == 126)
    let ultrasound = IVUSImportTriage.assessPath(path + "/" + name)
    precondition(ultrasound.mayMergeIntoIncoming && ultrasound.rows == 7 && ultrasound.columns == 9)
}
let icon = EnhancedImportTriage.assessPath(path + "/icon-encapsulated")
precondition(icon.detectedDICOM && icon.mayMergeIntoIncoming && icon.rows == 7 && icon.columns == 9,
             "an encapsulated icon made the file unreadable or replaced the root size")
for name in ["icon-unterminated", "icon-fragment-overrun", "icon-undefined-fragment"] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path + "/" + name))
    precondition(DICOMTriageMetadata.parse(data) == nil, "Malformed icon fragments accepted: \(name)")
}
for name in try FileManager.default.contentsOfDirectory(atPath: path) where name.hasPrefix("invalid-un-") {
    let data = try Data(contentsOf: URL(fileURLWithPath: path + "/" + name))
    precondition(DICOMTriageMetadata.parse(data) == nil, "Malformed UN sequence accepted: \(name)")
}
// Deflated Explicit VR Little Endian is DICOM, only not readable here until it
// is inflated: it is recognised as such, never as "not DICOM".
let deflated = EnhancedImportTriage.assessPath(path + "/deflated")
precondition(deflated.detectedDICOM && !deflated.mayMergeIntoIncoming,
             "a deflated file was called not DICOM, or merged unread")
precondition(deflated.transferSyntaxUID == "1.2.840.10008.1.2.1.99")
precondition(EnhancedImportTriage.isDeflatedDICOM(atPath: path + "/deflated"))
precondition(!EnhancedImportTriage.isDeflatedDICOM(atPath: path + "/explicit"))
precondition(!EnhancedImportTriage.isDeflatedDICOM(atPath: path + "/missing-file"))
print("PASS: incoming gates accept native transfer syntaxes and CP-246 UN sequences; malformed lengths, delimiters and excessive nesting are refused; a deflated file is recognised")
'''
with tempfile.TemporaryDirectory(prefix='horos-import-syntax-') as directory:
    p = Path(directory)
    for name, syntax in [('implicit', '1.2.840.10008.1.2'), ('explicit', '1.2.840.10008.1.2.1'), ('big', '1.2.840.10008.1.2.2')]:
        (p/name).write_bytes(fixture(syntax))
        (p/('us-'+name)).write_bytes(fixture(syntax, '1.2.840.10008.5.1.4.1.1.6.1'))
    (p/'sr').write_bytes(fixture('1.2.840.10008.1.2', '1.2.840.10008.5.1.4.1.1.88.11', image=False))
    (p/'missing').write_bytes(fixture('1.2.840.10008.1.2.1', image=False))
    (p/'overflow').write_bytes(fixture('1.2.840.10008.1.2.1', frame_count=9223372036854775807))
    ultrasound_sop = '1.2.840.10008.5.1.4.1.1.6.1'
    for name, syntax in [('le', '1.2.840.10008.1.2.1'), ('be', '1.2.840.10008.1.2.2')]:
        for undefined in (False, True):
            for nesting in (0, 2):
                private = unknown_sequence(syntax, undefined, nesting)
                (p/f'un-{name}-{undefined}-{nesting}').write_bytes(fixture(syntax, ultrasound_sop, private=private))
        order = '>' if name == 'be' else '<'
        (p/f'un-{name}-opaque').write_bytes(fixture(syntax, ultrasound_sop,
            private=element((9, 0x105F), 'UN', b'opaque value', order)))
        explicit_item = item(element((0x28, 0x10), 'US', struct.pack(order + 'H', 1), order), order=order)
        (p/f'sq-{name}-explicit').write_bytes(fixture(syntax, ultrasound_sop,
            private=element((9, 0x105F), 'SQ', explicit_item, order)))
        valid = unknown_sequence(syntax, True)
        bad_item_length = valid[:16] + struct.pack('<I', len(valid) * 8) + valid[20:]
        bad_item_delimiter = valid[:-12] + struct.pack('<I', 1) + valid[-8:]
        malformed = {'missing-sequence-delimiter': valid[:-8],
                     'missing-item-delimiter': valid[:-16] + valid[-8:],
                     'item-overrun': bad_item_length, 'bad-item-delimiter': bad_item_delimiter,
                     'nesting': unknown_sequence(syntax, True, 17)}
        for case, private in malformed.items():
            (p/f'invalid-un-{name}-{case}').write_bytes(fixture(syntax, ultrasound_sop, private=private))
    (p/'icon-encapsulated').write_bytes(fixture('1.2.840.10008.1.2.1', private=icon_sequence()))
    frag = lambda tag, length: struct.pack('<HHI', 0xFFFE, tag, length)
    for case, fragments in {'icon-unterminated': frag(0xE000, 0) + frag(0xE000, 4) + b'abcd',
                            'icon-fragment-overrun': frag(0xE000, 0) + frag(0xE000, 4096) + b'abcd' + frag(0xE0DD, 0),
                            'icon-undefined-fragment': frag(0xE000, 0xFFFFFFFF) + frag(0xE0DD, 0)}.items():
        (p/case).write_bytes(fixture('1.2.840.10008.1.2.1', private=icon_sequence(fragments=fragments)))
    # Meta with the deflated syntax, then the explicit dataset as one raw deflate stream.
    import zlib
    uid = b'1.2.840.10008.1.2.1.99'; uid += b'\0' * (len(uid) % 2)
    body = fixture('1.2.840.10008.1.2.1')
    explicit_uid = b'1.2.840.10008.1.2.1\0'
    dataset = body[132 + len(element((2, 0x10), 'UI', explicit_uid)):]
    squeeze = zlib.compressobj(9, zlib.DEFLATED, -15)
    (p/'deflated').write_bytes(b'\0' * 128 + b'DICM' + element((2, 0x10), 'UI', uid)
                               + squeeze.compress(dataset) + squeeze.flush())
    (p/'main.swift').write_text(main)
    sources = [root/'Horos/Sources'/name for name in ['DICOMTriageMetadata.swift', 'EnhancedImportTriage.swift', 'IVUSImportTriage.swift',
                                                          'WrappedImageFragments.swift']]
    subprocess.run(['xcrun', 'swiftc', *map(str, sources), str(p/'main.swift'), '-o', str(p/'check')], check=True)
    subprocess.run([str(p/'check'), str(p)], check=True)

# The incoming scan sends a deflated file to the decompression helper before the
# probe and the gates, whatever the listener's compression setting, and the
# probe recognises one: a valid deflated file was moved aside as "not
# DICOM" or, with DELETEFILELISTENER, deleted.
database = (root/'Horos/Sources/DicomDatabase.mm').read_bytes().decode('latin1')
routed = database.find('isDeflatedDICOMAtPath: srcPath')
checked = database.find('isDicomFile = [DicomFile isDICOMFile:srcPath compressed:')
assert 0 <= routed < checked, 'deflated files are not routed before the probe'
assert '[_decompressQueue addObjectsFromArray:deflatedPathArray]' in database, \
    'deflated files are not queued for decompression whatever the compression setting'
dicom_file = (root/'Horos/Sources/DicomFile.mm').read_bytes().decode('latin1')
assert 'HorosDICOMProbe::inspect(path)' in dicom_file
assert 'mayTranscode && (' in database
assert 'gdcm::' not in dicom_file
print('PASS: the incoming scan inflates deflated files instead of refusing them')

# +isDICOMFile:compressed:image: calls a file compressed when the app and the
# decompression helper both decode its syntax. The viewer loads such a series
# through its parallel queue, and the incoming scan decompresses it when the
# listener is set to. High-Throughput JPEG 2000 (decoded), RLE and
# JPEG .51/.57 were missing: an HTJ2K series loaded one image at a time and
# stayed compressed. JPEG XL and video have no decoder: never here.
htj2k = {'1.2.840.10008.1.2.4.201', '1.2.840.10008.1.2.4.202', '1.2.840.10008.1.2.4.203'}
jpeg = {'1.2.840.10008.1.2.4.50', '1.2.840.10008.1.2.4.51', '1.2.840.10008.1.2.4.57', '1.2.840.10008.1.2.4.70'}
jpeg_ls = {'1.2.840.10008.1.2.4.80', '1.2.840.10008.1.2.4.81'}
jpeg_2000 = {'1.2.840.10008.1.2.4.90', '1.2.840.10008.1.2.4.91'}
rle = {'1.2.840.10008.1.2.5'}
# Execute the production probe and Objective-C selectors with every optional
# pointer combination. The private Swift fallback remains covered separately.
flags = dcmtk_flags()
with tempfile.TemporaryDirectory(prefix='horos-dcmdata-probe-') as directory:
    p = Path(directory)
    methods = dicom_file[dicom_file.index('+ (BOOL) isDICOMFile:(NSString *) filePath compressed:'):
                         dicom_file.index('+ (BOOL) isDICOMFile:(NSString *) file compressed:')]
    (p/'methods.inc').write_text('unsigned HorosTestPrivateFallbackCalls = 0;\n@implementation DicomFile\n' + methods +
        '+ (BOOL)isDICOMFileWithPrivateTransferSyntax:(NSString *)p compressed:(BOOL *)c image:(BOOL *)i { ++HorosTestPrivateFallbackCalls; return NO; }\n@end\n')
    binary = p/'probe'
    subprocess.run(['xcrun', 'clang++', '-std=c++11', '-x', 'objective-c++',
                    '-DHOROS_TEST_DICOM_METHODS="' + str(p/'methods.inc') + '"',
                    str(root/'tools/exercise-dicom-parser.cc'), '-x', 'none', *flags,
                    '-framework', 'Foundation', '-o', str(binary)], check=True)
    expected = {}
    def put(name, data, recognized=1, readable=1, image=1, compressed=0, transcode=1, inflation=0):
        (p/name).write_bytes(data)
        expected[name] = (recognized, readable, image, compressed, transcode, inflation)
    native = '1.2.840.10008.1.2.1'
    for name, syntax in [('native-implicit', '1.2.840.10008.1.2'), ('native-explicit', native),
                         ('native-big', '1.2.840.10008.1.2.2')]:
        put(name, fixture(syntax))
    no_pixel_sops = ['88.11', '104.1', '11.1', '481.3', '9.1.1', '66', '66.1']
    for suffix in no_pixel_sops:
        put('no-pixels-' + suffix, fixture(native, '1.2.840.10008.5.1.4.1.1.' + suffix, image=False), image=0, transcode=0)
    header = fixture(native, image=False)
    dataset = header[132 + len(element((2, 0x10), 'UI', native.encode() + b'\0')):]
    put('no-preamble', dataset, image=0, transcode=0)
    implicit_dataset = element((8, 0x16), 'UI', b'1.2.840.10008.5.1.4.1.1.88.11\0', implicit=True)
    put('no-preamble-implicit', implicit_dataset, image=0, transcode=0)
    put('identity-after-pixels', header[:len(header)-len(dataset)] + element((0x7fe0, 0x10), 'OW', b'\0'*126) + dataset)
    put('icon-only', fixture(native, image=False, private=icon_sequence()), image=0, transcode=0)
    put('icon-root', fixture(native, private=icon_sequence()))
    fragment = lambda length: struct.pack('<HHI', 0xfffe, 0xe000, length)
    pixels = (element((0x7fe0, 0x10), 'OB', b'')[:-4] + struct.pack('<I', 0xffffffff)
              + fragment(0) + fragment(4) + b'abcd' + fragment(4) + b'efgh'
              + struct.pack('<HHI', 0xfffe, 0xe0dd, 0))
    supported = jpeg | jpeg_ls | jpeg_2000 | htj2k | rle
    unsupported = {'1.2.840.10008.1.2.4.' + str(n) for n in [92, 93, 100, 101, 102, 103, 104, 105, 106, 107, 108, 110, 111, 112]}
    unsupported |= {'1.2.840.10008.1.2.4.' + str(n) + '.1' for n in range(100, 107)}
    unsupported |= {'1.2.276.0.19.1.2.55.3', '9.8.7.6.5'}
    for syntax in sorted(supported | unsupported):
        put('syntax-' + syntax, fixture(syntax, image=False) + pixels,
            compressed=int(syntax in supported), transcode=int(syntax in supported))
    put('out-of-order', fixture(native) + element((8, 0x18), 'UI', b'1.2.3\0'))
    put('trailing-junk', fixture(native) + b'not a dicom element', readable=0, transcode=0)
    put('text', b'arbitrary text', recognized=0, readable=0, image=0, transcode=0)
    put('pixel-without-identity', element((0x7fe0, 0x10), 'OW', b'\0'*126), recognized=0, readable=0, image=0, transcode=0)
    put('arbitrary-elements', element((0x10, 0x10), 'PN', b'SYNTHETIC '), recognized=0, readable=0, image=0, transcode=0)
    put('meta-only', header[:len(header)-len(dataset)], recognized=0, readable=0, image=0, transcode=0)
    identified_meta = (b'\0'*128 + b'DICM' + element((2, 2), 'UI', b'1.2.840.10008.5.1.4.1.1.2\0')
                       + element((2, 0x10), 'UI', native.encode() + b'\0'))
    put('identified-meta-only', identified_meta, recognized=0, readable=0, image=0, transcode=0)
    lying_private = element((0x29, 0x1000), 'OB', b'')[:-4] + struct.pack('<I', 0xfffffff0) + b'abcd'
    put('damage-before-identity', identified_meta + lying_private, readable=0, image=0, transcode=0)
    put('private-no-identity', fixture('9.8.7.6.5', sop='not-a-uid', image=False),
        recognized=0, readable=0, image=0, transcode=0)
    put('invalid-uid', header[:len(header)-len(dataset)] + element((8, 0x16), 'UI', b'not-a-uid\0'),
        recognized=0, readable=0, image=0, transcode=0)
    deflated_meta = b'\0'*128 + b'DICM' + element((2, 0x10), 'UI', b'1.2.840.10008.1.2.1.99')
    squeeze = zlib.compressobj(9, zlib.DEFLATED, -15)
    put('valid-deflated', deflated_meta + squeeze.compress(dataset) + squeeze.flush(), readable=0, image=0, compressed=1, transcode=0, inflation=1)
    put('invalid-deflated', deflated_meta + b'invalid deflate', readable=0, image=0, compressed=1, transcode=0, inflation=1)
    put('truncated-binary-meta-uid', b'\0'*128 + b'DICM'
        + element((2, 0x10), 'OB', b'')[:-4] + struct.pack('<I', 0xfffffff0) + b'abcd',
        recognized=0, readable=0, image=0, transcode=0)
    put('invalid-long-meta-uid', b'\0'*128 + b'DICM' + element((2, 0x10), 'UI', b'1.'*512) + dataset,
        recognized=0, readable=0, image=0, transcode=0)
    large_meta = p/'large-binary-meta-uid'
    with large_meta.open('wb') as f:
        f.write(b'\0'*128 + b'DICM' + element((2, 0x10), 'OB', b'')[:-4] + struct.pack('<I', 256*1024*1024))
        f.seek(256*1024*1024-1, 1); f.write(b'\0'); f.write(dataset)
    expected[large_meta.name] = (0, 0, 0, 0, 0, 0)
    # Sparse native Pixel Data and many large fragments must stay deferred.
    large = p/'large-native'
    with large.open('wb') as f:
        f.write(header + element((0x7fe0, 0x10), 'OW', b'')[:-4] + struct.pack('<I', 512*1024*1024))
        f.seek(512*1024*1024 - 1, 1); f.write(b'\0')
    expected[large.name] = (1, 1, 1, 0, 1, 0)
    large = p/'large-fragments'
    with large.open('wb') as f:
        f.write(fixture('1.2.840.10008.1.2.4.90', image=False))
        f.write(pixels[:12] + fragment(0))
        for _ in range(16):
            f.write(fragment(16*1024*1024)); f.seek(16*1024*1024-1, 1); f.write(b'\0')
        f.write(struct.pack('<HHI', 0xfffe, 0xe0dd, 0))
    expected[large.name] = (1, 1, 1, 1, 1, 0)
    corpus = p/'malformed'
    subprocess.run([sys.executable, str(root/'tools/generate-malformed-dicom-fixture.py'), str(corpus)], check=True, capture_output=True)
    files = [p/name for name in expected] + sorted(corpus.glob('*.dcm'))
    result = subprocess.run([str(binary), '--probe', *map(str, files)], capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, (result.returncode, result.stdout[-2000:], result.stderr[-4000:])
    actual = {}
    for line in result.stdout.splitlines():
        path, *values = line.split('\t')
        name = Path(path).name
        actual[name] = tuple(map(int, values[:6]))
        if name.startswith('syntax-'):
            assert values[6] == name.removeprefix('syntax-'), (name, values[6])
    for name, flags_expected in expected.items():
        assert actual[name] == flags_expected, (name, actual[name], flags_expected, result.stderr[-2000:])
    for name in ['length-almost-4g.dcm', 'truncated-mid-element.dcm', 'fragment-almost-4g.dcm',
                 'sequence-never-ends.dcm', 'nested-2000-deep.dcm', 'ob-almost-4g.dcm']:
        assert actual[name][0] == 1 and actual[name][1] == 0 and actual[name][4] == 0, (name, actual[name])
    assert actual['meta-only.dcm'][0] == 0 and actual['not-dicom-at-all.dcm'][0] == 0
    import re
    peak = int(re.search(r'probe peak RSS bytes=(\d+)', result.stderr).group(1))
    assert peak < 128*1024*1024, f'probe materialized pixel payload: {peak}'
    print(f'PASS: production lazy probe + optional selectors, {len(files)} inputs, peak RSS {peak} bytes')
# Each of those families has a decoder in the app and in the helper.
codec = (root/'Horos/Sources/HorosJPEG2000Codec.cpp').read_text()
for syntax in ['EXS_JPEG2000LosslessOnly', 'EXS_JPEG2000', 'EXS_HighThroughputJPEG2000LosslessOnly',
               'EXS_HighThroughputJPEG2000withRPCLOptionsLosslessOnly', 'EXS_HighThroughputJPEG2000']:
    assert f'new Decoder({syntax})' in codec, f'no JPEG 2000 decoder for {syntax}'
for path in ['Horos/Sources/AppControllerDCMTKCategory.mm', 'Decompress/Decompress.mm']:
    source = (root/path).read_bytes().decode('latin1')
    for registration in ['DJDecoderRegistration::registerCodecs(', 'DJLSDecoderRegistration::registerCodecs(',
                         'DcmRLEDecoderRegistration::registerCodecs(', 'HorosJPEG2000Registration::registerCodecs(']:
        assert registration in source, f'{path} does not register {registration}'
# Both consumers take their decision from it.
viewer = (root/'Horos/Sources/ViewerController.m').read_bytes().decode('latin1')
assert '[DicomFile isDICOMFile: [firstPix srcFile] compressed: &compressed];' in viewer
assert 'isJPEGCompressed == YES && listenerCompressionSettings == 1' in database
print('PASS: HTJ2K, RLE and every JPEG family with a decoder count as compressed; JPEG XL and video do not')

# Neither consumer depends on the retired backend: inspect the project graph.
import plistlib
project = plistlib.loads(subprocess.check_output(['plutil', '-convert', 'xml1', '-o', '-',
                                                 str(root/'Horos.xcodeproj/project.pbxproj')]))['objects']
for name in ['Horos', 'Decompress']:
    target = next(v for v in project.values() if v.get('isa') == 'PBXNativeTarget' and v.get('name') == name)
    dependencies = [project[project[d]['target']].get('name') for d in target['dependencies'] if 'target' in project[d]]
    assert 'GDCM' not in dependencies, (name, dependencies)
    configs = project[target['buildConfigurationList']]['buildConfigurations']
    for config in configs:
        settings = project[config]['buildSettings']
        mentions = any('GDCM' in str(settings.get(key, '')) for key in
                       ['HEADER_SEARCH_PATHS', 'SYSTEM_HEADER_SEARCH_PATHS', 'LIBRARY_SEARCH_PATHS', 'OTHER_LDFLAGS'])
        assert not mentions, (name, project[config]['name'])
print('PASS: Horos and Decompress Debug/Release have no GDCM paths, link flag or dependency')
