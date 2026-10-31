#!/usr/bin/env python3
"""The shared-database server answers every request as the previous revision did.

The server's parsing moved from the resume stack of O2DatabaseConnection to
IsiXDICOMNetwork's SharedDatabaseRequestParser, and its answers to
SharedDatabaseReply. This test links the application's own server twice, as
tests/test-shared-database-parser.py does (tools/shared_database_probe.py, the
database replaced by the probe's recorder): once from the objects of a build of
the previous revision, once from this checkout's build. Since BonjourPublisher is
Swift, a revision of it cannot be recompiled alone, so the previous revision is
given as the objects of its build:

    python3 tests/test-shared-database-server-equivalence.py --baseline-objects-root <checkout or copied objects>

Both servers, open and protected by a password, receive the same corpus - every
command, valid and malformed, whole, cut at chosen boundaries and byte by byte -
and must give, request by request, the same answer, the same closing of the
connection and the same changes to the database (what the recorder saw, with
the scratch folder of each server written the same way).

Exit 2 when either build, or the baseline objects, are missing.
"""
import argparse
import atexit
import json
import os
import queue
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import shared_database_probe  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--baseline-objects-root", type=Path, default=os.environ.get("HOROS_SDB_BASELINE_OBJECTS"))
parser.add_argument("--configuration", default="Debug")
arguments = parser.parse_args()
if not arguments.baseline_objects_root:
    print("needs --baseline-objects-root (the objects of a build of the previous revision)", file=sys.stderr)
    raise SystemExit(2)

work = Path(tempfile.mkdtemp(prefix="horos-sdb-equivalence-"))
atexit.register(shutil.rmtree, work, ignore_errors=True)
probes = {}
for label, root in (("baseline", arguments.baseline_objects_root.resolve()), ("candidate", ROOT)):
    try:
        objects = shared_database_probe.app_objects(arguments.configuration, root, swift_publisher=True)
    except shared_database_probe.MissingObject as missing:
        print(f"{label}: needs a built {missing.name}.o ({arguments.configuration}) under {root}", file=sys.stderr)
        raise SystemExit(2)
    probes[label] = shared_database_probe.link(objects, True, work / label, work / f"probe-{label}")
    print(f"{label}: {objects[0]}")


def i32(value):
    return struct.pack(">i", value)


def text(value):
    if value is None:
        return i32(0)
    data = value.encode() + b"\0"
    return i32(len(data)) + data


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Server:
    def __init__(self, label, scratch, password=None):
        self.scratch = scratch
        self.port = free_port()
        env = dict(os.environ)
        env.pop("HOROS_PROBE_PASSWORD", None)
        if password:
            env["HOROS_PROBE_PASSWORD"] = password
        self.process = subprocess.Popen([str(probes[label]), str(self.port), str(scratch)], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=open(work / f"{label}.log", "ab"), env=env)
        self.events = queue.Queue()
        threading.Thread(target=self._read, daemon=True).start()
        ready = self.next_event(10)
        assert ready and ready["event"] == "ready", (label, ready)

    def _read(self):
        for line in self.process.stdout:
            try:
                self.events.put(json.loads(line))
            except json.JSONDecodeError:
                pass

    def next_event(self, timeout):
        try:
            return self.events.get(timeout=timeout)
        except queue.Empty:
            return None

    def drain(self, settle):
        time.sleep(settle)
        found = []
        while True:
            try:
                event = self.events.get_nowait()
            except queue.Empty:
                return found
            if event["event"] not in ("threads", "ready"):
                found.append(event)

    def exchange(self, chunks, timeout=2.0):
        """The answer and whether the server closed the connection, then what the database saw."""
        if self.process.poll() is not None:
            return {"dead": True}
        response, closed = bytearray(), False
        try:
            with socket.create_connection(("127.0.0.1", self.port), timeout=5) as s:
                s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                for chunk in chunks:
                    if chunk:
                        s.sendall(chunk)
                    if len(chunks) > 1:
                        time.sleep(0.005)
                s.settimeout(timeout)
                try:
                    while True:
                        data = s.recv(1 << 20)
                        if not data:
                            closed = True
                            break
                        response.extend(data)
                except socket.timeout:
                    pass
                except ConnectionResetError:
                    closed = True
        except (ConnectionRefusedError, BrokenPipeError, ConnectionResetError):
            closed = True
        # A send ordered by DCMSE runs after the answer, on its own thread or queue.
        events = json.loads(json.dumps(self.drain(0.3)).replace(str(self.scratch), "<scratch>"))
        return {"response": bytes(response).replace(str(self.scratch).encode(), b"<scratch>").hex(),
                "closed": closed, "events": events}

    def stop(self):
        try:
            self.process.stdin.write(b"quit\n")
            self.process.stdin.flush()
            self.process.wait(timeout=5)
        except (BrokenPipeError, subprocess.TimeoutExpired):
            self.process.kill()


def scratch_folder(name):
    """The same database for every server: two images, a linked file, a report, an index."""
    folder = work / name
    data = folder / "DATABASE.noindex" / "10000"
    data.mkdir(parents=True)
    (data / "1.dcm").write_bytes(b"DICM" * 300)
    (data / "2.dcm").write_bytes(b"\x00\x01" * 700)
    (folder / "ROIs").mkdir()
    (folder / "ROIs" / "a.roi").write_bytes(b"roi")
    (folder / "REPORTS").mkdir()
    (folder / "REPORTS" / "r.pages").write_bytes(b"report")
    linked = folder / "elsewhere"
    linked.mkdir()
    (linked / "linked.dcm").write_bytes(b"linked")
    # Same dates everywhere: MFILE answers with one.
    for each in (data / "1.dcm", data / "2.dcm", folder / "ROIs" / "a.roi", linked / "linked.dcm"):
        os.utime(each, (1700000000, 1700000000))
    (folder / "index.json").write_text(json.dumps({
        "linked": [str(linked / "linked.dcm")],
        "values": {"x-coredata://probe/Study/p2": {"reportURL": str(folder / "REPORTS" / "r.pages")}},
    }))
    (folder / "Database.sql").write_bytes(b"SQLite format 3\0" + bytes(range(256)) * 4)
    os.utime(folder / "Database.sql", (1700000000, 1700000000))
    return folder


def plist(dictionary_body):
    return ('<?xml version="1.0" encoding="UTF-8"?><plist version="1.0">' + dictionary_body + '</plist>')


def corpus(scratch):
    """(name, request) pairs; each request is sent whole, and the fragmented ones also cut."""
    linked = str(scratch / "elsewhere" / "linked.dcm")
    album = plist('<dict><key>albumUID</key><string>x-coredata://probe/Album/a1</string>'
                  '<key>albumStudies</key><array><string>x-coredata://probe/Study/s1</string>'
                  '<string>x-coredata://probe/Study/s2</string></array></dict>')
    requests = [
        ("AUTHV", b"AUTHV\0"), ("ISPWD", b"ISPWD\0"), ("DBVER", b"DBVER\0"), ("GETDI", b"GETDI\0"),
        ("VERSI", b"VERSI\0"), ("DBSIZ", b"DBSIZ\0"), ("DATAB", b"DATAB\0"),
        ("PASWD", b"PASWD\0" + i32(4) + b"abc\0"), ("PASWD not UTF-8", b"PASWD\0" + i32(3) + b"\xc3\x28\0"),
        ("PASWD unterminated", b"PASWD\0" + i32(3) + b"abc"), ("PASWD empty", b"PASWD\0" + i32(0)),
        ("PASWD too long", b"PASWD\0" + i32(4098) + b"a" * 4097 + b"\0"),
        ("SETVA text", b"SETVA\0" + text("x-coredata://probe/Study/p1") + text("ré value") + text("comment")),
        ("SETVA nil", b"SETVA\0" + text("x-coredata://probe/Study/p1") + text(None) + text("comment2")),
        ("SETVA empty", b"SETVA\0" + text("x-coredata://probe/Study/p1") + text("") + text("comment3")),
        ("SETVA number", b"SETVA\0" + text("x-coredata://probe/Study/p1") + text("12abc") + text("stateText")),
        ("SETVA refused key", b"SETVA\0" + text("x-coredata://probe/Study/p1") + text("v") + text("patientID")),
        ("SETVA report name", b"SETVA\0" + text("x-coredata://probe/Study/p1") + text("../../escape.pages") + text("reportURL")),
        ("SETVA report clear", b"SETVA\0" + text("x-coredata://probe/Study/p2") + text(None) + text("reportURL")),
        ("SETVA missing object", b"SETVA\0" + text(None) + text("v") + text("comment")),
        ("SETVA missing key", b"SETVA\0" + text("o") + text("v") + text(None)),
        ("ADDAL", b"ADDAL\0" + text(album)),
        ("REMAL", b"REMAL\0" + text(album)),
        ("ADDAL not a dictionary", b"ADDAL\0" + text(plist("<array><string>x</string></array>"))),
        ("ADDAL unparsable", b"ADDAL\0" + text("<<<")),
        ("ADDAL no studies", b"ADDAL\0" + text(plist('<dict><key>albumUID</key><string>x-coredata://probe/Album/a1</string></dict>'))),
        ("ADDAL missing", b"ADDAL\0" + text(None)),
        ("NEWMS", b"NEWMS\0" + i32(5) + b"hello"), ("NEWMS empty", b"NEWMS\0" + i32(0)),
        ("NEWMS negative", b"NEWMS\0" + i32(-3)),
        ("SENDD", b"SENDD\0" + i32(2) + i32(3) + b"abc" + i32(0)),
        ("SENDG", b"SENDG\0" + i32(1) + i32(4) + b"wxyz"), ("SENDD none", b"SENDD\0" + i32(0)),
        ("SENDD negative count", b"SENDD\0" + i32(-1)), ("SENDD negative length", b"SENDD\0" + i32(1) + i32(-7)),
        ("DICOM", b"DICOM\0" + i32(3) + text("1.dcm") + text("2.dcm") + text("ROIs/a.roi")
         + text("/client/1") + text("/client/2") + text("/client/3")),
        ("DICOM linked", b"DICOM\0" + i32(1) + text(linked) + text("/client/linked")),
        ("DICOM outside", b"DICOM\0" + i32(2) + text("1.dcm") + text("/etc/hosts") + text("/c/1") + text("/c/2")),
        ("DICOM climbing", b"DICOM\0" + i32(1) + text("../Database.sql") + text("/c/1")),
        ("DICOM none", b"DICOM\0" + i32(0)),
        ("DICOM missing destination", b"DICOM\0" + i32(1) + text("1.dcm") + text(None)),
        ("DCMSE", b"DCMSE\0" + text("PEER") + text("10.0.0.9") + text("11112") + text("1") + i32(2)
         + text("1.dcm") + text(linked)),
        ("DCMSE loopback", b"DCMSE\0" + text("PEER") + text("127.0.0.1") + text("104") + text("2") + i32(1) + text("2.dcm")),
        ("DCMSE refused path", b"DCMSE\0" + text("PEER") + text("10.0.0.9") + text("11112") + text("1") + i32(1) + text("a/b")),
        ("DCMSE missing", b"DCMSE\0" + text("PEER") + text(None)),
        ("MFILE", b"MFILE\0" + text("1.dcm")), ("MFILE absolute", b"MFILE\0" + text(str(scratch / "ROIs" / "a.roi"))),
        ("MFILE refused", b"MFILE\0" + text("/etc/hosts")), ("MFILE missing", b"MFILE\0" + text(None)),
        ("unknown", b"XXXXX\0"), ("unterminated command", b"DATABX"), ("command not UTF-8", b"\xff\xfeAAA\0"),
        ("string length negative", b"MFILE\0" + i32(-1)),
        ("string too long", b"MFILE\0" + i32((64 << 20) + 1)),
        ("string unterminated", b"MFILE\0" + i32(3) + b"abc"),
        ("string embedded terminator", b"MFILE\0" + i32(4) + b"a\0b\0"),
        ("string not UTF-8", b"MFILE\0" + i32(3) + b"\xc3\x28\0"),
        ("count too large", b"DICOM\0" + i32((1 << 20) + 1)),
    ]
    return requests


FRAGMENTED = {"SETVA text", "ADDAL", "SENDD", "DICOM", "DCMSE", "PASWD", "NEWMS"}


def transcript(label, password=None):
    # Folders of the same length: requests that name them are cut at the same places.
    scratch = scratch_folder(f"scratch-{label[0]}-{'protected' if password else 'open'}")
    server = Server(label, scratch, password)
    found = {}
    try:
        for name, request in corpus(scratch):
            if password:
                # Without the envelope, and inside one with the password.
                found[name + " bare"] = server.exchange([request])
                wrapped = (b"AUTHR\0" + struct.pack(">I", len(password.encode())) + password.encode() + request
                           if len(request) >= 6 else request)
                found[name + " authorized"] = server.exchange([wrapped])
                wrong = b"AUTHR\0" + struct.pack(">I", 5) + b"wrong" + request
                found[name + " wrong password"] = server.exchange([wrong])
                continue
            found[name] = server.exchange([request])
            if name in FRAGMENTED:
                for cut in sorted({1, 3, 5, 6, 7, 9, len(request) // 2, len(request) - 1}):
                    if 0 < cut < len(request):
                        found[f"{name} cut at {cut}"] = server.exchange([request[:cut], request[cut:]])
                if len(request) <= 64:
                    found[f"{name} byte by byte"] = server.exchange([request[i:i + 1] for i in range(len(request))])
    finally:
        server.stop()
    return found


failures = []
for password in (None, "synthetic-é"):
    baseline = transcript("baseline", password)
    candidate = transcript("candidate", password)
    for name in baseline:
        if baseline[name] != candidate.get(name):
            failures.append(name)
            print(f"FAIL: {name} ({'protected' if password else 'open'})\n  baseline:  {baseline[name]}\n  candidate: {candidate.get(name)}")
    print(f"{'protected' if password else 'open'}: {len(baseline)} exchanges compared")

if failures:
    sys.exit(1)
print("PASS: the server answers, closes and changes the database as the previous revision's for every request of the corpus, "
      "open and protected, whole and fragmented")
