#!/usr/bin/env python3
"""Files a peer sends to the shared database land in the folder of the database they are indexed in.

A peer of the shared database reads one database: the index it copies (DATAB),
its size (DBSIZ), its date (VERSI) and the files it names (DICOM, DCMSE, MFILE)
are all of the default database. The files it sends (SENDD, SENDG) are written
into a database's folder and indexed. This test runs the application's own
server (tools/shared_database_probe.py, the database and the browser replaced
by the probe's recorders) with two local databases, the browser showing the one
that is not the default, and checks that every file of SENDD and SENDG is
written into the folder of the database whose index receives it, and that this
is the database the peer reads (DBSIZ answers the size of its index). With no
other database shown, the same holds.

    python3 tests/test-shared-database-send-target.py
    python3 tests/test-shared-database-send-target.py --baseline-objects-root <objects of a build of the previous revision>

The second form also links the server of the previous revision, which wrote the
files into the folder of the database the browser shows and indexed them in the
default one: the test then requires that it sees that divergence there, so it is
known to reproduce it.

Exit 2 when a needed build is missing.
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

work = Path(tempfile.mkdtemp(prefix="horos-sdb-send-target-"))
atexit.register(shutil.rmtree, work, ignore_errors=True)

sides = [("candidate", ROOT)]
if arguments.baseline_objects_root:
    sides.insert(0, ("baseline", arguments.baseline_objects_root.resolve()))
probes = {}
for label, root in sides:
    try:
        objects = shared_database_probe.app_objects(arguments.configuration, root, swift_publisher=True)
    except shared_database_probe.MissingObject as missing:
        print(f"{label}: needs a built {missing.name}.o ({arguments.configuration}) under {root}", file=sys.stderr)
        raise SystemExit(2)
    probes[label] = shared_database_probe.link(objects, True, work / label, work / f"probe-{label}")
    print(f"{label}: {objects[0]}")


def i32(value):
    return struct.pack(">i", value)


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def database_folder(name, index_size):
    """A local database: its folder and an index of its own size."""
    folder = work / name
    (folder / "DATABASE.noindex").mkdir(parents=True)
    (folder / "Database.sql").write_bytes(b"SQLite format 3\0" + b"\0" * (index_size - 16))
    return folder


class Server:
    def __init__(self, label, default, shown):
        self.port = free_port()
        env = dict(os.environ)
        env.pop("HOROS_PROBE_PASSWORD", None)
        env.pop("HOROS_PROBE_SHOWN_DATABASE", None)
        if shown:
            env["HOROS_PROBE_SHOWN_DATABASE"] = str(shown)
        self.process = subprocess.Popen([str(probes[label]), str(self.port), str(default)], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=open(work / f"{label}.log", "ab"), env=env)
        self.events = queue.Queue()
        threading.Thread(target=self._read, daemon=True).start()
        ready = self.events.get(timeout=10)
        assert ready["event"] == "ready", (label, ready)

    def _read(self):
        for line in self.process.stdout:
            try:
                self.events.put(json.loads(line))
            except json.JSONDecodeError:
                pass

    def exchange(self, request):
        response = bytearray()
        with socket.create_connection(("127.0.0.1", self.port), timeout=10) as s:
            s.sendall(request)
            while True:
                data = s.recv(1 << 16)
                if not data:
                    break
                response.extend(data)
        time.sleep(0.2)
        found = []
        while True:
            try:
                found.append(self.events.get_nowait())
            except queue.Empty:
                return bytes(response), found

    def stop(self):
        try:
            self.process.stdin.write(b"quit\n")
            self.process.stdin.flush()
            self.process.wait(timeout=5)
        except (BrokenPipeError, subprocess.TimeoutExpired):
            self.process.kill()


def inside(path, folder):
    return Path(path).resolve().is_relative_to(folder.resolve())


def run(label, shows_other):
    """Where SENDD and SENDG wrote their files and where they indexed them."""
    tag = f"{label}-{'other' if shows_other else 'default'}"
    default = database_folder(f"default-{tag}", 4096)
    shown = database_folder(f"shown-{tag}", 8192) if shows_other else None
    server = Server(label, default, shown)
    outcome = {"default": default, "shown": shown, "uploads": []}
    try:
        response, _ = server.exchange(b"DBSIZ\0")
        outcome["dbsiz"] = struct.unpack(">I", response)[0] if len(response) == 4 else None
        for command, generated in (("SENDD", False), ("SENDG", True)):
            files = [os.urandom(700 + n) for n in range(2 if command == "SENDD" else 1)]
            request = command.encode() + b"\0" + i32(len(files)) + b"".join(i32(len(f)) + f for f in files)
            response, events = server.exchange(request)
            added = [e for e in events if e["event"] == "addFiles"]
            outcome["uploads"].append({"command": command, "files": files, "generated": generated,
                                       "response": response, "added": added})
    finally:
        server.stop()
    return outcome


def divergences(outcome):
    """What makes the files and their index part, or the peer not read them."""
    found = []
    default = outcome["default"]
    if outcome["dbsiz"] != (default / "Database.sql").stat().st_size:
        found.append(f"DBSIZ answered {outcome['dbsiz']}, not the size of the default database's index")
    for upload in outcome["uploads"]:
        command, added = upload["command"], upload["added"]
        if len(added) != 1:
            found.append(f"{command}: {len(added)} additions to an index")
            continue
        index = Path(added[0]["database"])
        written = added[0]["paths"]
        if [Path(p).read_bytes() for p in written] != upload["files"]:
            found.append(f"{command}: the files written are not the files sent")
        if added[0]["generatedByOsiriX"] != upload["generated"]:
            found.append(f"{command}: generatedByOsiriX {added[0]['generatedByOsiriX']}")
        if len(upload["response"]) != 4 + 4 * len(upload["files"]):
            found.append(f"{command}: answer of {len(upload['response'])} bytes")
        for path in written:
            if not inside(path, index):
                where = "the shown database" if outcome["shown"] and inside(path, outcome["shown"]) else "another folder"
                found.append(f"{command}: {Path(path).name} written into {where}, indexed in {index.name}")
        if index.resolve() != default.resolve():
            found.append(f"{command}: indexed in {index.name}, not in the database the peer reads ({default.name})")
    return found


failures = []
for label, _ in sides:
    for shows_other in (True, False):
        outcome = run(label, shows_other)
        found = divergences(outcome)
        case = f"{label}, browser showing {'another local database' if shows_other else 'the default database'}"
        print(f"{case}: " + ("; ".join(found) if found else "files and index in the default database"))
        if label == "candidate" and found:
            failures.append(case)
        if label == "baseline" and shows_other and not any("written into the shown database" in f for f in found):
            failures.append(f"{case}: the previous revision should write into the shown database and index in the "
                            "default one; the test does not reproduce the divergence")
        if label == "baseline" and not shows_other and found:
            failures.append(f"{case}: unexpected divergence")

for failure in failures:
    print("FAIL:", failure)
if failures:
    sys.exit(1)
print("PASS: SENDD and SENDG write every file into the folder of the database that indexes it, the default "
      "database the peer reads, whichever local database the browser shows"
      + (" (and the previous revision showed the divergence)" if arguments.baseline_objects_root else ""))
