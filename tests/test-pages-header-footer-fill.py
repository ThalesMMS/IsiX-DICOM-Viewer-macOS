#!/usr/bin/env python3
"""A modern Pages report fills the placeholders of the header and footer.

Pages' scripting dictionary has no header and no footer, so a letterhead made
there - which is where a template converted from Pages '09 keeps it - came out
with every field still written as a placeholder. The production
PagesHeaderFooterFill is compiled here and given IWA files built below: Snappy
chunks (with copies, and more than one chunk), objects of the header storage
type and others, and a ZIP document holding them.

What is checked:

  * A header or footer storage has its placeholders replaced, and every table
    index after a placeholder is moved by the change in length; an entry that
    started inside a placeholder is dropped, and a value left empty keeps the
    later of two entries brought to one index.
  * A text box storage, a storage with a table it does not understand, a
    message to be merged with another and a placeholder across a paragraph
    break are left alone; a value's line break becomes a space.
  * The other objects and the other entries of the ZIP come out byte for byte,
    in the same order, stored; a document with nothing to fill in is not
    rewritten.
"""
from pathlib import Path
import hashlib
import os
import subprocess
import sys
import tempfile
import zipfile

root = Path(__file__).resolve().parents[1]
failures = []


def check(value, what):
    if not value:
        failures.append(what)


# MARK: protocol buffers and IWA, written independently of the code under test

def varint(n):
    out = bytearray()
    while True:
        b = n & 0x7f
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def read_varint(b, i):
    n = s = 0
    while True:
        c = b[i]
        i += 1
        n |= (c & 0x7f) << s
        s += 7
        if c < 0x80:
            return n, i


def field(number, value):
    if isinstance(value, int):
        return varint(number << 3) + varint(value)
    return varint(number << 3 | 2) + varint(len(value)) + value


def parse(b):
    i, out = 0, []
    while i < len(b):
        key, i = read_varint(b, i)
        if key & 7 == 0:
            v, i = read_varint(b, i)
        else:
            n, i = read_varint(b, i)
            v = b[i:i + n]
            i += n
        out.append((key >> 3, v))
    return out


def table(*entries):
    """Entries of (character index, referenced object id or None)."""
    out = b''
    for index, obj in entries:
        entry = field(1, index) + (field(2, field(1, obj)) if obj else b'')
        out += field(1, entry)
    return out


def read_table(b):
    out = []
    for _, entry in parse(b):
        fs = dict(parse(entry))
        ref = dict(parse(fs[2]))[1] if 2 in fs else None
        out.append((fs[1], ref))
    return out


def storage(kind, text, tables, extra=b''):
    out = field(1, kind) + field(2, field(1, 77)) + field(3, text.encode())
    for number, entries in tables:
        out += field(number, table(*entries))
    return out + field(10, 1) + extra


def obj(identifier, payload, message_type=2001, merge=False):
    info = field(1, identifier) + field(2, field(1, message_type) + field(2, b'\x01\x02\x03') + field(3, len(payload)))
    if merge:
        info += field(3, 1)
    return varint(len(info)) + info + payload


def objects(stream):
    i, out = 0, {}
    while i < len(stream):
        n, i = read_varint(stream, i)
        info = parse(stream[i:i + n])
        i += n
        ident = dict(info)[1]
        payloads = []
        for number, v in info:
            if number == 2:
                ln = dict(parse(v))[3]
                payloads.append(stream[i:i + ln])
                i += ln
        out[ident] = payloads[0]
    return out


def snappy(data):
    """A greedy Snappy block with real copies, so that decompression is tested."""
    out = bytearray(varint(len(data)))
    i = literal_start = 0
    seen = {}

    def literal(end):
        n = end - literal_start
        if n:
            if n - 1 < 60:
                out.append((n - 1) << 2)
            else:
                out.append(61 << 2)
                out.extend((n - 1).to_bytes(2, 'little'))
            out.extend(data[literal_start:end])

    while i + 4 <= len(data):
        key = data[i:i + 4]
        j = seen.get(key)
        seen[key] = i
        if j is not None and 0 < i - j < 65536:
            length = 4
            while i + length < len(data) and data[j + length] == data[i + length] and length < 64:
                length += 1
            literal(i)
            out.append((length - 1) << 2 | 2)
            out.extend((i - j).to_bytes(2, 'little'))
            i += length
            literal_start = i
        else:
            i += 1
    literal(len(data))
    return bytes(out)


def iwa(stream, chunk=65536):
    out = b''
    for k in range(0, len(stream), chunk):
        block = snappy(stream[k:k + chunk])
        out += b'\x00' + len(block).to_bytes(3, 'little') + block
    return out


def unsnappy(b):
    n, i = read_varint(b, 0)
    out = bytearray()
    while i < len(b):
        t = b[i]
        i += 1
        if t & 3 == 0:
            ln = t >> 2
            if ln >= 60:
                nb = ln - 59
                ln = int.from_bytes(b[i:i + nb], 'little')
                i += nb
            ln += 1
            out += b[i:i + ln]
            i += ln
        else:
            if t & 3 == 1:
                ln, off = (t >> 2 & 7) + 4, (t >> 5) << 8 | b[i]
                i += 1
            elif t & 3 == 2:
                ln, off = (t >> 2) + 1, int.from_bytes(b[i:i + 2], 'little')
                i += 2
            else:
                ln, off = (t >> 2) + 1, int.from_bytes(b[i:i + 4], 'little')
                i += 4
            for _ in range(ln):
                out.append(out[-off])
    assert len(out) == n
    return bytes(out)


def un_iwa(data):
    out, i = b'', 0
    while i < len(data):
        assert data[i] == 0
        n = int.from_bytes(data[i + 1:i + 4], 'little')
        out += unsnappy(data[i + 4:i + 4 + n])
        i += 4 + n
    return out


# MARK: the document

header_text = 'Ao Dr(a): «referringPhysician»\nNome: «name» («patientID»)\nConvênio: «DICOM_FIELD:0x0008,0x1050»\nFim'
p = header_text.index
# The placeholders, in UTF-16 units: every character here is in the BMP.
ref, name, pid, conv = p('«ref'), p('«name'), p('«patientID'), p('«DICOM')
ref_end, name_end, pid_end, conv_end = (p('»', x) + 1 for x in (ref, name, pid, conv))
header = storage(1, header_text, [
    (5, [(0, 501), (p('Nome'), 502), (p('Conv'), 501), (p('Fim'), 502)]),            # paragraph styles
    (6, [(0, None)]),                                                                  # paragraph data
    (8, [(0, None), (name, 601), (name + 3, 602), (name_end, None), (p('Fim'), 603)]),  # character styles
    (11, [(0, None), (ref, 701), (ref_end, None), (name, 702), (name_end, None),        # placeholder fields
          (pid, 703), (pid_end, None), (conv, 704), (conv_end, None)]),
])
footer_text = 'Exame em www.example.org com usuário: «patientID»'
footer = storage(1, footer_text, [(5, [(0, 501)]), (8, [(0, None), (footer_text.index('«'), 601)])])
textbox = storage(3, 'Caixa: «name»', [(5, [(0, 501)])])
# Field 25 holds ranges, not indices: a table not understood here.
unknown = storage(1, 'Outro: «name»', [(5, [(0, 501)])], extra=field(25, field(1, field(1, field(1, 0) + field(2, 3)))))
broken = storage(1, 'Quebra: «na\nme»', [(5, [(0, 501), (11, 502)])])
merged = storage(1, 'Merge: «name»', [(5, [(0, 501)])])
filler = bytes(range(256)) * 300  # an unrelated object large enough for a second chunk

stream = (obj(1, b'document root', message_type=10000) + obj(2, filler, message_type=9999) + obj(3, header)
          + obj(4, footer) + obj(5, textbox) + obj(6, unknown) + obj(7, broken) + obj(8, merged, merge=True))
document_iwa = iwa(stream)
plain_iwa = iwa(obj(1, b'document root', message_type=10000) + obj(5, textbox))

program = r'''
import Foundation

let values = ["referringPhysician": "Dr. Sint\u{e9}tico", "name": "Paciente\nSint\u{e9}tico",
              "patientID": "00123", "DICOM_FIELD:0x0008,0x1050": ""]
func substitute(_ token: String) -> String {
    let key = String(token.dropFirst().dropLast())
    return values[key] ?? token
}
let arguments = CommandLine.arguments
switch arguments[1] {
case "iwa":
    let data = [UInt8](try! Data(contentsOf: URL(fileURLWithPath: arguments[2])))
    if let filled = try! PagesHeaderFooterFill.fill(iwa: data, substitute: substitute) {
        try! Data(filled).write(to: URL(fileURLWithPath: arguments[3]))
    } else {
        print("unchanged")
    }
case "garbage":
    let data = [UInt8](try! Data(contentsOf: URL(fileURLWithPath: arguments[2])))
    print((try? PagesHeaderFooterFill.fill(iwa: data, substitute: substitute)) == nil ? "refused" : "accepted")
default:
    print(PagesHeaderFooterFill.fill(documentAt: arguments[2], substitute: substitute) ? "filled" : "failed")
}
'''

with tempfile.TemporaryDirectory(prefix='horos-pages-header-') as folder:
    f = Path(folder)
    (f / 'main.swift').write_text(program)
    (f / 'bridge.h').write_text('#include "%s"\n#include "%s"\n' % (
        root / 'Horos/Sources/ThirdParty/Libarchive/archive.h', root / 'Horos/Sources/ThirdParty/Libarchive/archive_entry.h'))
    built = subprocess.run(['xcrun', 'swiftc', '-sanitize=address', '-import-objc-header', str(f / 'bridge.h'),
                            str(root / 'Horos/Sources/PagesHeaderFooterFill.swift'), str(f / 'main.swift'),
                            '-larchive', '-o', str(f / 'fill')], timeout=600)
    if built.returncode:
        print('FAIL: the production PagesHeaderFooterFill did not compile')
        sys.exit(1)

    def run(*args):
        return subprocess.run([str(f / 'fill'), *args], capture_output=True, text=True, timeout=120)

    (f / 'Document.iwa').write_bytes(document_iwa)
    result = run('iwa', str(f / 'Document.iwa'), str(f / 'filled.iwa'))
    check(result.returncode == 0, 'the fill crashed: %s' % result.stderr[-2000:])
    filled = (f / 'filled.iwa').read_bytes() if (f / 'filled.iwa').exists() else b''
    check(len(filled) > 0, 'nothing was filled in')
    if filled:
        chunks, i = 0, 0
        while i < len(filled):
            chunks += 1
            i += 4 + int.from_bytes(filled[i + 1:i + 4], 'little')
        check(chunks == 2, 'the output is not in chunks of at most 64 KiB: %d' % chunks)
        before, after = objects(stream), objects(un_iwa(filled))
        check(sorted(after) == sorted(before), 'objects were lost or added')
        for unchanged in (1, 2, 5, 6, 7, 8):
            check(after.get(unchanged) == before[unchanged], 'object %d changed' % unchanged)
        h = dict(parse(after[3]))
        new = h[3].decode()
        expected = 'Ao Dr(a): Dr. Sintético\nNome: Paciente Sintético (00123)\nConvênio: \nFim'
        check(new == expected, 'header text: %r' % new)
        q = expected.index
        n_name = q('Paciente')
        n_name_end = n_name + len('Paciente Sintético')
        n_pid = q('00123')
        check(read_table(h[5]) == [(0, 501), (q('Nome'), 502), (q('Conv'), 501), (q('Fim'), 502)], 'paragraph styles: %r' % read_table(h[5]))
        check(read_table(h[6]) == [(0, None)], 'paragraph data')
        # The style that started inside «name» has no character left to start at.
        check(read_table(h[8]) == [(0, None), (n_name, 601), (n_name_end, None), (q('Fim'), 603)], 'character styles: %r' % read_table(h[8]))
        # Each placeholder field now covers its value; the emptied one is gone.
        n_conv = q('\nFim')
        check(read_table(h[11]) == [(0, None), (q('Dr. S'), 701), (q('\nNome'), None), (n_name, 702), (n_name_end, None),
                                    (n_pid, 703), (n_pid + 5, None), (n_conv, None)], 'placeholder fields: %r' % read_table(h[11]))
        check(h[1] == 1 and h[10] == 1 and dict(parse(h[2]))[1] == 77, 'the other fields of the header changed')
        ft = dict(parse(after[4]))
        check(ft[3].decode() == 'Exame em www.example.org com usuário: 00123', 'footer text: %r' % ft[3])

    # Nothing to fill in: no new file.
    (f / 'plain.iwa').write_bytes(plain_iwa)
    check(run('iwa', str(f / 'plain.iwa'), str(f / 'x')).stdout.strip() == 'unchanged', 'a file without header fields was rewritten')
    # A file that is not IWA is refused, not guessed at.
    (f / 'garbage.iwa').write_bytes(b'\x00\xff\xff\x00garbage')
    check(run('garbage', str(f / 'garbage.iwa')).stdout.strip() == 'refused', 'a malformed file was accepted')

    # A single-file document: the ZIP is rewritten in the same order, stored.
    doc = f / 'report.pages'
    others = [('Metadata/Properties.plist', b'<plist/>'), ('Data/logo.png', os.urandom(5000)), ('preview.jpg', os.urandom(3000))]
    with zipfile.ZipFile(doc, 'w', zipfile.ZIP_STORED) as z:
        z.writestr('Index/Document.iwa', document_iwa)
        z.writestr('Index/Other.iwa', plain_iwa)
        for entry, data in others:
            z.writestr(entry, data)
    result = run('document', str(doc))
    check(result.stdout.strip() == 'filled', 'the document was not filled in: %s %s' % (result.stdout, result.stderr[-1000:]))
    with zipfile.ZipFile(doc) as z:
        names = z.namelist()
        check(names == ['Index/Document.iwa', 'Index/Other.iwa'] + [e for e, _ in others], 'entries: %r' % names)
        check(all(i.compress_type == zipfile.ZIP_STORED for i in z.infolist()), 'entries were compressed')
        for entry, data in others:
            check(z.read(entry) == data, '%s changed' % entry)
        check(z.read('Index/Other.iwa') == plain_iwa, 'an index file without header fields changed')
        check(dict(parse(objects(un_iwa(z.read('Index/Document.iwa')))[3]))[3].decode().startswith('Ao Dr(a): Dr. Sint'),
              'the document header was not filled in')
    check(not (f / 'report.pages.filling').exists(), 'the temporary archive was left behind')

    # Nothing to fill in: the document stays byte for byte, with its date.
    quiet = f / 'quiet.pages'
    with zipfile.ZipFile(quiet, 'w', zipfile.ZIP_STORED) as z:
        z.writestr('Index/Document.iwa', plain_iwa)
    stamp = quiet.stat().st_mtime_ns
    digest = hashlib.sha256(quiet.read_bytes()).hexdigest()
    check(run('document', str(quiet)).stdout.strip() == 'filled', 'a document without header fields failed')
    check(hashlib.sha256(quiet.read_bytes()).hexdigest() == digest and quiet.stat().st_mtime_ns == stamp,
          'a document without header fields was rewritten')

    # A package document: its index files are filled in place.
    package = f / 'package.pages'
    (package / 'Index').mkdir(parents=True)
    (package / 'Index/Document.iwa').write_bytes(document_iwa)
    check(run('document', str(package)).stdout.strip() == 'filled', 'the package was not filled in')
    check(dict(parse(objects(un_iwa((package / 'Index/Document.iwa').read_bytes()))[4]))[3].decode().endswith('00123'),
          'the package footer was not filled in')

    # Not a document: refused, and left as it was.
    junk = f / 'junk.pages'
    junk.write_bytes(b'not a zip')
    check(run('document', str(junk)).stdout.strip() == 'failed' and junk.read_bytes() == b'not a zip', 'a file that is not a ZIP was touched')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: header and footer placeholders of a modern Pages document are filled in the file, styles moved with them')
