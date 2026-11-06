#!/usr/bin/env python3
"""The web portal and XML-RPC of two app bundles, compared over HTTP.

Each bundle is launched in turn, isolated, with a fresh private database, the
web portal (password required) and XML-RPC on free loopback ports. A synthetic
CT study is imported through INCOMING and a synthetic portal account is written
into the portal's own accounts store while the app is stopped. The same requests
are then sent to each bundle, over HTTP and, with --https, over HTTPS:

  login     the index, a protected page without a session (401 login page), a
            wrong password, the right one (session cookie), then the study list
            (HTML and JSON) and the study page
  download  a DICOM object by WADO, the study as a ZIP, a single range, several
            ranges, a suffix range and a range out of the body
  upload    a DICOM file under and one over the 2 MiB upload piece, posted as the
            portal's upload form does
  http      HEAD, two requests on one kept-alive connection, HTTP/1.0 (505), a GET
            with a body (400, closed), an unknown method (405, closed)
  xmlrpc    GetDisplayed2DViewerStudies, FindObject, a method that does not exist
            and a body that is not XML
  methods   with --xmlrpc-methods, the interface's methods one by one, each
            answer and what it did: opening a series and a study (the viewers
            listed after it, closed by UID), their bad requests (400) and misses
            (-1), FindObject's Select and an unreadable request, SelectAlbum,
            OpenDB, the browser's search, Retrieve and CMove against a synthetic
            C-GET node (tools/serve-cget-fixture.py, the images it sends),
            unknown nodes, DownloadURL of a synthetic file served over HTTP (the
            image imported and its study opened), the method names in lowercase
            and PathToFrontDCM

Each answer is reduced to its status, its header fields and a digest of its
body, with what differs by nature between two runs (dates, session ids, tokens,
the multipart boundary, the order of a ZIP's entries) normalised. The two
bundles' answers must match; the differences are listed.

    local-validation/venv/bin/python tools/compare-web-portal-http.py \\
        --a OLD.app --b NEW.app --out local-validation/portal-equivalence [--xmlrpc-methods]

Needs a Python with pydicom and numpy. Windows are not clicked.
"""
import argparse
import hashlib
import http.client
import io
import json
import re
import shutil
import socket
import subprocess
import sqlite3
import ssl
import sys
import time
import urllib.parse
import xmlrpc.client
import zipfile
from pathlib import Path

import numpy
from pydicom.dataset import Dataset, FileMetaDataset
from pydicom.uid import CTImageStorage, ExplicitVRLittleEndian

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import native_app  # noqa: E402

USER, PASSWORD = "synthetic", "Synthetic-QA-1467"
STUDY_UID = "1.2.826.0.1.3680043.8.498.1467"
DOWNLOAD_UID = "1.2.826.0.1.3680043.8.498.1482"
PEER = "synthetic C-GET peer"


def synthetic(folder: Path):
    """A deterministic CT study of two series, and two upload files around 2 MiB."""
    folder.mkdir(parents=True)
    objects = []
    for series_number, rows in ((1, 64), (2, 96)):
        series = f"{STUDY_UID}.{series_number}"
        for number in range(1, 4):
            ds = Dataset()
            ds.file_meta = FileMetaDataset()
            ds.file_meta.TransferSyntaxUID = ExplicitVRLittleEndian
            ds.SOPClassUID, ds.SOPInstanceUID = CTImageStorage, f"{series}.{number}"
            ds.StudyInstanceUID, ds.SeriesInstanceUID = STUDY_UID, series
            ds.PatientName, ds.PatientID = "SYNTHETIC^EQUIVALENCE", "SYN-1467"
            ds.StudyDate, ds.StudyTime, ds.StudyID = "20261028", "120000", "1467"
            ds.StudyDescription, ds.SeriesDescription = "Synthetic transport", f"series {series_number}"
            ds.Modality, ds.InstanceNumber, ds.SeriesNumber = "CT", number, series_number
            ds.Rows = ds.Columns = rows
            ds.SamplesPerPixel, ds.PhotometricInterpretation = 1, "MONOCHROME2"
            ds.BitsAllocated, ds.BitsStored, ds.HighBit, ds.PixelRepresentation = 16, 12, 11, 0
            ds.WindowCenter, ds.WindowWidth = 2000, 4000
            ds.ImageOrientationPatient, ds.ImagePositionPatient = [1, 0, 0, 0, 1, 0], [0, 0, number]
            ds.PixelSpacing, ds.SliceThickness = [0.5, 0.5], 1
            ds.PixelData = (numpy.arange(rows * rows, dtype=numpy.uint16) % 4000).tobytes()
            path = folder / f"s{series_number}-{number}.dcm"
            ds.save_as(path, enforce_file_format=True)
            objects.append((series, f"{series}.{number}"))
    uploads = {}
    for label, side in (("small", 512), ("large", 1100)):
        ds = Dataset()
        ds.file_meta = FileMetaDataset()
        ds.file_meta.TransferSyntaxUID = ExplicitVRLittleEndian
        uid = f"{STUDY_UID}.9{side}"
        ds.SOPClassUID, ds.SOPInstanceUID = CTImageStorage, f"{uid}.1"
        ds.StudyInstanceUID, ds.SeriesInstanceUID = uid, f"{uid}.0"
        ds.PatientName, ds.PatientID = "SYNTHETIC^UPLOAD", f"SYN-UP-{label}"
        ds.StudyDate, ds.Modality, ds.InstanceNumber = "20261028", "CT", 1
        ds.Rows = ds.Columns = side
        ds.SamplesPerPixel, ds.PhotometricInterpretation = 1, "MONOCHROME2"
        ds.BitsAllocated, ds.BitsStored, ds.HighBit, ds.PixelRepresentation = 16, 12, 11, 0
        ds.PixelData = (numpy.arange(side * side, dtype=numpy.uint16) % 4000).tobytes()
        path = folder.parent / f"upload-{label}.dcm"
        ds.save_as(path, enforce_file_format=True)
        uploads[label] = path
    # What DownloadURL fetches over HTTP: one image of a study of its own.
    ds = Dataset()
    ds.file_meta = FileMetaDataset()
    ds.file_meta.TransferSyntaxUID = ExplicitVRLittleEndian
    ds.SOPClassUID, ds.SOPInstanceUID = CTImageStorage, f"{DOWNLOAD_UID}.1.1"
    ds.StudyInstanceUID, ds.SeriesInstanceUID = DOWNLOAD_UID, f"{DOWNLOAD_UID}.1"
    ds.PatientName, ds.PatientID = "SYNTHETIC^DOWNLOAD", "SYN-DL-1482"
    ds.StudyDate, ds.Modality, ds.InstanceNumber, ds.SeriesNumber = "20261028", "CT", 1, 1
    ds.Rows = ds.Columns = 64
    ds.SamplesPerPixel, ds.PhotometricInterpretation = 1, "MONOCHROME2"
    ds.BitsAllocated, ds.BitsStored, ds.HighBit, ds.PixelRepresentation = 16, 12, 11, 0
    ds.PixelData = (numpy.arange(64 * 64, dtype=numpy.uint16) % 4000).tobytes()
    served = folder.parent / "served"
    served.mkdir()
    ds.save_as(served / "download.dcm", enforce_file_format=True)
    return objects, uploads


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def add_portal_user(store: Path):
    """The synthetic account, in the portal's Core Data store: admin, uploads and ZIP."""
    digest = hashlib.sha1((PASSWORD + USER).encode()).hexdigest()
    with sqlite3.connect(store) as db:
        entity, maximum = db.execute("SELECT Z_ENT, Z_MAX FROM Z_PRIMARYKEY WHERE Z_NAME = 'User'").fetchone()
        db.execute("INSERT INTO ZUSER (Z_PK, Z_ENT, Z_OPT, ZNAME, ZPASSWORD, ZPASSWORDHASH, ZISADMIN, ZUPLOADDICOM,"
                   " ZDOWNLOADZIP, ZENCRYPTEDZIP, ZCANSEEALBUMS, ZAUTODELETE, ZCREATIONDATE)"
                   " VALUES (?, ?, 1, ?, '**********', ?, 1, 1, 1, 0, 1, 0, 0)",
                   (maximum + 1, entity, USER, digest))
        db.execute("UPDATE Z_PRIMARYKEY SET Z_MAX = ? WHERE Z_NAME = 'User'", (maximum + 1,))


NORMALISE = [
    (re.compile(rb"[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"), b"<UUID>"),
    (re.compile(rb"OSID=[0-9A-Za-z]+"), b"OSID=<SID>"),
    (re.compile(rb"\b[0-9A-F]{32}\b"), b"<HEX32>"),
    (re.compile(rb"(token|sid)=[^&\"'<> ]+"), rb"\1=<TOKEN>"),
    (re.compile(rb"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4}"), b"<DATE>"),
    (re.compile(rb"x-coredata://[^\"'<>& ]+"), b"<OBJECTID>"),
    # The database numbers objects in the order it imports them, which the
    # two series of the fixture do not keep from one run to the next.
    (re.compile(rb"<UUID>/(Study|Series|Image)/p\d+"), rb"<UUID>/\1/p<N>"),
    (re.compile(rb"xid=[^&\"'<> ]+"), b"xid=<XID>"),
    (re.compile(rb"127\.0\.0\.1:\d+"), b"127.0.0.1:<PORT>"),
]


def normalise(body: bytes) -> bytes:
    for pattern, replacement in NORMALISE:
        body = pattern.sub(replacement, body)
    return body


def summary(status, headers, body):
    fields = {}
    for name, value in headers:
        key = name.lower()
        if key == "date":
            value = "<DATE>"
        value = normalise(value.encode()).decode()
        fields.setdefault(key, []).append(value)
    if body.startswith(b"<?xml") and b"<methodResponse>" in body:
        # An XML-RPC answer: its structs' members come in no set order.
        try:
            value = xmlrpc.client.loads(body.decode())[0]
            body = json.dumps(value, sort_keys=True, default=str).encode()
        except xmlrpc.client.Fault as fault:
            body = json.dumps({"fault": fault.faultCode, "string": fault.faultString}).encode()
        except Exception:
            pass
    if body[:2] == b"PK":
        try:
            with zipfile.ZipFile(io.BytesIO(body)) as archive:
                entries = sorted((info.filename, hashlib.sha256(archive.read(info)).hexdigest()) for info in archive.infolist())
            digest = "zip:" + hashlib.sha256(json.dumps(entries).encode()).hexdigest()
        except zipfile.BadZipFile:
            digest = "bad-zip:" + hashlib.sha256(body).hexdigest()
    else:
        digest = hashlib.sha256(normalise(body)).hexdigest()
    return {"status": status, "headers": fields, "length": len(body), "body": digest}


class Client:
    def __init__(self, port, tls):
        self.port, self.tls = port, tls
        self.context = ssl._create_unverified_context() if tls else None

    def connect(self):
        if self.tls:
            return http.client.HTTPSConnection("127.0.0.1", self.port, timeout=60, context=self.context)
        return http.client.HTTPConnection("127.0.0.1", self.port, timeout=60)

    def request(self, method, path, body=None, headers=None):
        connection = self.connect()
        try:
            connection.request(method, path, body=body, headers=headers or {})
            response = connection.getresponse()
            data = response.read()
            return response.status, response.getheaders(), data
        finally:
            connection.close()

    def raw(self, payload: bytes, read_timeout=15):
        """Bytes written as they are; everything the server sends until it closes or goes quiet."""
        sock = socket.create_connection(("127.0.0.1", self.port), timeout=read_timeout)
        if self.tls:
            sock = self.context.wrap_socket(sock, server_hostname="127.0.0.1")
        sock.sendall(payload)
        chunks = []
        try:
            while True:
                chunk = sock.recv(65536)
                if not chunk:
                    chunks.append(b"<closed>")
                    break
                chunks.append(chunk)
        except (socket.timeout, TimeoutError):
            chunks.append(b"<open>")
        finally:
            sock.close()
        return b"".join(chunks)


def raw_summary(data: bytes):
    """Each response of a raw exchange: status line, field names, length; and whether the server closed."""
    closed = data.endswith(b"<closed>")
    responses = []
    for block in re.split(rb"(?=HTTP/1\.[01] \d{3})", data):
        if not block.startswith(b"HTTP/"):
            continue
        head, _, body = block.partition(b"\r\n\r\n")
        lines = head.split(b"\r\n")
        names = sorted(line.split(b":", 1)[0].decode().lower() for line in lines[1:])
        responses.append({"status": lines[0].decode().split(" ", 2)[1], "fields": names})
    return {"responses": responses, "closed": closed}


def multipart(path: Path):
    boundary = "----IsiXEquivalenceBoundary1467"
    data = path.read_bytes()
    body = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"fileToUpload\"; filename=\"{path.name}\"\r\n"
            f"Content-Type: application/dicom\r\n\r\n").encode() + data + f"\r\n--{boundary}--\r\n".encode()
    return body, {"Content-Type": f"multipart/form-data; boundary={boundary}"}


def xmlrpc_call(client, method, params="<param><value><struct></struct></value></param>"):
    body = f'<?xml version="1.0"?><methodCall><methodName>{method}</methodName><params>{params}</params></methodCall>'
    return client.request("POST", "/", body.encode(), {"Content-Type": "text/xml"})


def exercise(app: Path, out: Path, fixture: Path, uploads, tls: bool, methods: bool = False):
    root = out / "database"
    portal, rpc = free_port(), free_port()
    arguments = ["-httpWebServer", "YES", "-httpWebServerPort", str(portal), "-wadoServer", "YES",
                 "-encryptedWebServer", "YES" if tls else "NO", "-passwordWebServer", "YES",
                 "-wadoRequestRequireValidToken", "NO", "-webServerAddress", "127.0.0.1",
                 "-httpXMLRPCServer", "YES", "-httpXMLRPCServerPort", str(rpc),
                 "-httpXMLRPCServerHTTPS", "YES" if tls else "NO"]
    peer = None
    if methods:
        # A synthetic C-GET node for Retrieve and CMove; the app asks it
        # without a DICOM listener of its own.
        peer_port = free_port()
        out.mkdir(parents=True, exist_ok=True)
        peer = subprocess.Popen([sys.executable, str(ROOT / "tools/serve-cget-fixture.py"), str(out / "peer"),
                                 "--port", str(peer_port), "--instances", "6"],
                                stdout=open(out / "peer.log", "w"), stderr=subprocess.STDOUT)
        native_app.wait_for(lambda: socket.socket().connect_ex(("127.0.0.1", peer_port)) == 0, 60,
                            description="the C-GET peer")
        node = (f'({{Address = "127.0.0.1"; Port = {peer_port}; AETitle = CGETFIX; TransferSyntax = 0; retrieveMode = 1; '
                f'Description = "{PEER}"; Activated = 1; QR = 1; Send = 0;}})')
        arguments += ["-STORESCP", "NO", "-USESTORESCP", "NO", "-hideListenerError", "YES", "-syncDICOMNodes", "NO",
                      "-publishDICOMBonjour", "NO", "-searchDICOMBonjour", "NO", "-AETITLE", "HOROSDEV",
                      "-SERVERS", node, "-DICOMTimeout", "8", "-DICOMConnectionTimeout", "5"]
    native_app.stop_all(app)
    process = native_app.launch(root, out / "horos-1.log", arguments, app=app)
    try:
        data = native_app.database_folder(root)
        native_app.wait_for(lambda: (data / "INCOMING.noindex").is_dir(), 120, description="the database")
        for path in sorted(fixture.glob("*.dcm")):
            staging = data / "INCOMING.noindex" / f".{path.name}.part"
            shutil.copyfile(path, staging)
            staging.rename(data / "INCOMING.noindex" / path.name)
        native_app.wait_for(lambda: (native_app.image_count(root) or 0) >= 6, 120, description="the import")
        native_app.wait_for(lambda: (root / "WebUsers.sql").is_file(), 60, description="the portal accounts")
        time.sleep(2)
    finally:
        native_app.stop(process)
    add_portal_user(root / "WebUsers.sql")

    results = {}
    process = native_app.launch(root, out / "horos-2.log", arguments, app=app)
    try:
        native_app.wait_for(lambda: socket.socket().connect_ex(("127.0.0.1", portal)) == 0, 90, description="the portal")
        native_app.wait_for(lambda: socket.socket().connect_ex(("127.0.0.1", rpc)) == 0, 60, description="XML-RPC")
        time.sleep(2)
        client = Client(portal, tls)

        bodies = out / "bodies"
        bodies.mkdir(exist_ok=True)

        def record(name, response):
            status, headers, body = response
            # The database of each run is in its own folder: its path is the run's.
            body = body.replace(str(root).encode(), b"<ROOT>")
            (bodies / name).write_bytes(body)
            results[name] = summary(status, headers, body)
            return response

        record("index", client.request("GET", "/"))
        record("studyList-anonymous", client.request("GET", "/studyList"))
        login = urllib.parse.urlencode({"username": USER, "password": "", "login": "Login",
                                        "sha1": hashlib.sha1(("wrong" + USER).encode()).hexdigest()})
        record("login-wrong", client.request("POST", "/studyList", login.encode(),
                                             {"Content-Type": "application/x-www-form-urlencoded"}))
        login = urllib.parse.urlencode({"username": USER, "password": "", "login": "Login",
                                        "sha1": hashlib.sha1((PASSWORD + USER).encode()).hexdigest()})
        status, headers, body = record("login", client.request("POST", "/studyList", login.encode(),
                                                               {"Content-Type": "application/x-www-form-urlencoded"}))
        cookie = next((v.split(";")[0] for k, v in headers if k.lower() == "set-cookie"), "")
        session = {"Cookie": cookie}
        status, headers, page = record("studyList", client.request("GET", "/studyList", headers=session))
        record("studyList.json", client.request("GET", "/studyList.json", headers=session))
        found = re.search(rb"study\?&?xid=([^&\"'<> ]+)", page)
        xid = urllib.parse.unquote(found.group(1).decode()) if found else None
        results["study-xid-found"] = bool(xid)
        if xid:
            record("study", client.request("GET", "/study?" + urllib.parse.urlencode({"xid": xid}), headers=session))
            record("study.zip", client.request("GET", "/study.zip?" + urllib.parse.urlencode({"xid": xid}), headers=session))
        wado = "/wado?" + urllib.parse.urlencode({"requestType": "WADO", "studyUID": STUDY_UID,
                                                  "seriesUID": f"{STUDY_UID}.1", "objectUID": f"{STUDY_UID}.1.2",
                                                  "contentType": "application/dicom"})
        record("wado-dicom", client.request("GET", wado))
        record("range-single", client.request("GET", wado, headers={"Range": "bytes=0-99"}))
        record("range-suffix", client.request("GET", wado, headers={"Range": "bytes=-50"}))
        record("range-outside", client.request("GET", wado, headers={"Range": "bytes=99999999-"}))
        status, headers, body = client.request("GET", wado, headers={"Range": "bytes=0-9,200-209"})
        # The boundary is random: the parts are compared without it.
        boundary = next((v.split("boundary=")[-1] for k, v in headers if "boundary=" in v), None)
        if boundary:
            body = body.replace(boundary.encode(), b"<BOUNDARY>")
            headers = [(k, v.replace(boundary, "<BOUNDARY>")) for k, v in headers]
        record("range-multiple", (status, headers, body))
        record("head-index", client.request("HEAD", "/"))
        record("head-wado", client.request("HEAD", wado))
        for label, path in uploads.items():
            body, headers = multipart(path)
            headers.update(session)
            record(f"upload-{label}", client.request("POST", "/main", body, headers))
        # Each upload is a study of one image of its own, imported by the database.
        try:
            native_app.wait_for(lambda: (native_app.image_count(root) or 0) >= 8, 60, description="the uploads")
        except TimeoutError:
            pass
        results["images-after-uploads"] = native_app.image_count(root)
        results["keep-alive"] = raw_summary(client.raw(b"GET /testdbalive HTTP/1.1\r\nHost: x\r\n\r\n"
                                                       b"GET /index HTTP/1.1\r\nHost: x\r\n\r\n", read_timeout=5))
        results["http-1.0"] = raw_summary(client.raw(b"GET / HTTP/1.0\r\n\r\n", read_timeout=5))
        results["get-with-body"] = raw_summary(client.raw(b"GET / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello"))
        results["unknown-method"] = raw_summary(client.raw(b"DELETE / HTTP/1.1\r\nHost: x\r\n\r\n"))
        results["post-without-length"] = raw_summary(client.raw(b"POST / HTTP/1.1\r\nHost: x\r\n\r\n"))

        rpc_client = Client(rpc, tls)
        record("xmlrpc-displayed", xmlrpc_call(rpc_client, "GetDisplayed2DViewerStudies"))
        record("xmlrpc-find", xmlrpc_call(rpc_client, "FindObject", "<param><value><struct>"
                                     "<member><name>request</name><value>(patientID == 'SYN-1467')</value></member>"
                                     "<member><name>table</name><value>Study</value></member>"
                                     "<member><name>execute</name><value>Nothing</value></member>"
                                     "</struct></value></param>"))
        record("xmlrpc-unknown", xmlrpc_call(rpc_client, "NoSuchMethod"))
        record("xmlrpc-not-xml", rpc_client.request("POST", "/", b"not xml", {"Content-Type": "text/xml"}))
        if methods:
            exercise_methods(rpc_client, record, results, root, fixture.parent / "served")
    finally:
        native_app.stop(process)
        if peer is not None:
            peer.terminate()
            peer.wait(timeout=10)
    return results


def struct(**members):
    """An XML-RPC struct parameter of string members."""
    text = "".join(f"<member><name>{name}</name><value>{value}</value></member>" for name, value in members.items())
    return f"<param><value><struct>{text}</struct></value></param>"


def exercise_methods(rpc_client, record, results, root: Path, served: Path):
    """The interface's methods, each answer and what it did."""
    def call(label, method, **members):
        try:
            return record(label, xmlrpc_call(rpc_client, method, struct(**members)))
        except (ConnectionError, http.client.HTTPException, OSError) as error:
            # No answer: the connection closed (the app may have ended).
            results[label] = {"no-answer": type(error).__name__}
            return None

    def displayed(label, method="GetDisplayed2DViewerSeries"):
        # Let the main thread open or close what the last call asked for.
        time.sleep(3)
        call(label, method)

    series, other = f"{STUDY_UID}.1", f"{STUDY_UID}.2"
    # Opening a series, the viewers it leaves, closing it by series UID.
    call("m-displayseries", "DisplaySeries", SeriesInstanceUID=series)
    displayed("m-displayed-series-after-open")
    call("m-close-series", "Close2DViewerWithSeriesUID", uid=series)
    displayed("m-displayed-series-after-close")
    call("m-displayseries-patient", "DisplaySeries", PatientID="SYN-1467", SeriesInstanceUID=other)
    displayed("m-displayed-series-after-second-open")
    call("m-closeall", "CloseAllWindows")
    displayed("m-displayed-series-after-closeall")
    # Opening a study by each identifier and alias; closing it by study UID.
    call("m-displaystudy", "DisplayStudy", StudyInstanceUID=STUDY_UID)
    displayed("m-displayed-studies-after-open", "GetDisplayed2DViewerStudies")
    call("m-close-study", "Close2DViewerWithStudyUID", uid=STUDY_UID)
    displayed("m-displayed-studies-after-close", "GetDisplayed2DViewerStudies")
    call("m-displaystudy-alias", "displaystudy", patientID="SYN-1467", StudyID="1467")
    displayed("m-displayed-studies-after-alias", "getdisplayed2dviewerstudies")
    call("m-closeall-2", "closeallwindows")
    # Requests the methods cannot read, and misses.
    call("m-displaystudy-empty", "DisplayStudy")
    call("m-displaystudy-missing", "DisplayStudy", PatientID="NOBODY")
    call("m-displayseries-empty", "DisplaySeries")
    call("m-displayseries-missing", "DisplaySeries", SeriesInstanceUID="1.2.3.4.5.6")
    call("m-close-series-empty", "Close2DViewerWithSeriesUID")
    call("m-close-study-empty", "Close2DViewerWithStudyUID")
    # FindObject: select, a request that is not a predicate, missing parameters.
    call("m-find-select", "DBWindowFind", request="studyInstanceUID == '%s'" % STUDY_UID, table="Study", execute="Select")
    call("m-find-series", "FindObject", request="seriesDICOMUID == '%s'" % series, table="Series")
    call("m-find-empty", "FindObject")
    call("m-find-missing-open", "FindObject", request="patientID == 'NOBODY'", table="Study", execute="Open")
    # The browser.
    call("m-selectalbum-missing", "SelectAlbum", name="No such album")
    call("m-selectalbum-empty", "SelectAlbum")
    call("m-opendb-missing", "OpenDB", path="/nonexistent/IsiX equivalence")
    call("m-opendb-empty", "OpenDB")
    call("m-search-name", "DisplayStudyListByPatientName", PatientName="SYNTHETIC")
    call("m-search-name-empty", "DisplayStudyListByPatientName")
    call("m-search-id", "DisplayStudyListByPatientId", PatientID="SYN-1467")
    call("m-search-id-empty", "DisplayStudyListByPatientId")
    call("m-default-db", "SwitchToDefaultDBIfNeeded")
    # Retrieve and CMove: a node that does not exist, a request without one,
    # nothing found, and the synthetic study retrieved by C-GET.
    before = native_app.image_count(root) or 0
    call("m-retrieve-empty", "Retrieve")
    call("m-retrieve-unknown-node", "Retrieve", serverName="No such node", filterKey="PatientID", filterValue="X")
    call("m-cmove-empty", "CMove")
    call("m-cmove-unknown-node", "CMove", accessionNumber="A1482", server="No such node")
    call("m-retrieve-nothing", "Retrieve", serverName=PEER, filterKey="PatientID", filterValue="NOBODY")
    call("m-retrieve", "Retrieve", serverName=PEER, filterKey="PatientID", filterValue="CGET-27")
    try:
        native_app.wait_for(lambda: (native_app.image_count(root) or 0) >= before + 6, 90, interval=0.5,
                            description="the retrieved images")
    except TimeoutError:
        pass
    results["m-images-retrieved"] = (native_app.image_count(root) or 0) - before
    call("m-cmove", "CMove", accessionNumber="A1482", server=PEER)
    time.sleep(5)
    results["m-images-after-cmove"] = (native_app.image_count(root) or 0) - before
    # DownloadURL: a file served over HTTP, imported, and its study opened.
    import functools
    import http.server
    import threading
    sys.path.insert(0, str(ROOT / "tools"))
    from local_http import ThreadingLocalHTTPServer
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(served))
    with ThreadingLocalHTTPServer(("127.0.0.1", 0), handler) as server:
        threading.Thread(target=server.serve_forever, daemon=True).start()
        url = (f"http://127.0.0.1:{server.server_address[1]}/download.dcm?requestType=WADO"
               f"&amp;studyUID={DOWNLOAD_UID}&amp;seriesUID={DOWNLOAD_UID}.1")
        before = native_app.image_count(root) or 0
        call("m-downloadurl-empty", "DownloadURL")
        call("m-downloadurl", "DownloadURL", URL=url, Display="1")
        try:
            native_app.wait_for(lambda: (native_app.image_count(root) or 0) >= before + 1, 60, interval=0.5,
                                description="the downloaded image")
        except TimeoutError:
            pass
        results["m-images-downloaded"] = (native_app.image_count(root) or 0) - before
        displayed("m-displayed-studies-after-download", "GetDisplayed2DViewerStudies")
        server.shutdown()
    # The path of the front viewer's image, last.
    call("m-displayseries-for-path", "DisplaySeries", SeriesInstanceUID=series)
    time.sleep(3)
    call("m-path-front", "PathToFrontDCM", onlyfilename="yes")
    call("m-path-front-full", "PathToFrontDCM")
    # Last: a request that is not a predicate format, which raises in the
    # method (the app before the Swift interface ended there).
    call("m-find-unreadable", "FindObject", request="((", table="Study")
    time.sleep(2)
    call("m-alive-after-unreadable", "GetDisplayed2DViewerStudies")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--a", type=Path, required=True)
    parser.add_argument("--b", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--https", action="store_true", help="also compare over HTTPS")
    parser.add_argument("--xmlrpc-methods", action="store_true",
                        help="also call the XML-RPC methods one by one against a synthetic C-GET node")
    arguments = parser.parse_args()
    # The app resolves its database folder from the root it is given, not from
    # this directory.
    arguments.out, arguments.a, arguments.b = arguments.out.resolve(), arguments.a.resolve(), arguments.b.resolve()
    if arguments.out.exists():
        shutil.rmtree(arguments.out)
    arguments.out.mkdir(parents=True)
    fixture = arguments.out / "fixture" / "dicom"
    _, uploads = synthetic(fixture)
    report = {}
    for scheme in (["http", "https"] if arguments.https else ["http"]):
        tls = scheme == "https"
        runs = {}
        for label, app in (("a", arguments.a), ("b", arguments.b)):
            runs[label] = exercise(app, arguments.out / scheme / label, fixture, uploads, tls, arguments.xmlrpc_methods)
        differences = {name: {"a": runs["a"].get(name), "b": runs["b"].get(name)}
                       for name in sorted(set(runs["a"]) | set(runs["b"])) if runs["a"].get(name) != runs["b"].get(name)}
        report[scheme] = {"a": runs["a"], "differences": differences}
        print(f"{scheme}: {len(runs['a'])} answers compared, {len(differences)} differ")
        for name, pair in differences.items():
            print(f"  {name}:\n    a: {json.dumps(pair['a'])}\n    b: {json.dumps(pair['b'])}")
    (arguments.out / "report.json").write_text(json.dumps(report, indent=1))
    return 0 if all(not part["differences"] for part in report.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
