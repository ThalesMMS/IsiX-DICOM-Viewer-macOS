#!/usr/bin/env python3
"""Consume native Word/Pages report evidence; never drive an editor.

Missing --proof-manifest is a skip. The JSON contract is local and self-contained:
{"schema": 1, "origin": "horos-cua-native", "source_revision": "40 hex chars",
 "preserved": [{"path": "original source/template", "sha256": "before hash"}],
 "editors": {"Word": RECORD, "Pages": RECORD}}
Each RECORD contains bundle (installed .app), source_image (synthetic raster),
master_template (untouched native original, also listed in preserved),
native_before/native_after/native_reopened, inspection_before/inspection_after/
inspection_reopened (DOCX; Pages exports these through the actual GUI), and
pdf_before/pdf_after/pdf_reopened. Each artifact is {"path": "...", "sha256":
"hash recorded at collection"}; paths are relative to the manifest or absolute.
Native snapshots must be distinct, immutable copies from a real Horos insertion,
then an actual save/close/reopen. Directory .pages snapshots use a tree hash:
SHA256 of sorted relative POSIX path, NUL, file bytes, NUL for each regular file.
Symlinks are rejected. CUA collection/provenance remains the coordinator's job;
a marker in JSON is not independent proof of GUI execution.

Word's DOCX is inspected directly; Pages' DOCX export is an observable surrogate,
not an IWA parser. PDF rendering before/after/reopen checks the observed layout.
Original source/template hashes are checked; the successfully edited working
report is expected to change. JPEG conversion/downsampling is allowed with a
bounded decoded-pixel tolerance, never a fabricated native pass.
--check-negative-controls exercises synthetic corrupt data only, not native QA.
"""
import argparse
from collections import Counter
import hashlib
import io
import json
import math
from pathlib import Path
import plistlib
import posixpath
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile

NS = {"w": "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
      "wp": "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
      "a": "http://schemas.openxmlformats.org/drawingml/2006/main",
      "r": "http://schemas.openxmlformats.org/officeDocument/2006/relationships"}
MAX_IMAGE_MAE = 5.0  # RGB byte units; permits the production quality-0.9 JPEG.
EMU_PER_POINT = 12700


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    require(path.exists() and not path.is_symlink(), f"Missing/linked artifact: {path}")
    if path.is_file():
        return hashlib.sha256(path.read_bytes()).hexdigest()
    result = hashlib.sha256()
    files = sorted(path.rglob("*"), key=lambda p: p.relative_to(path).as_posix())
    require(files, "Empty native package")
    for item in files:
        require(not item.is_symlink(), "Linked native package member")
        if item.is_file():
            result.update(item.relative_to(path).as_posix().encode())
            result.update(b"\0"); result.update(item.read_bytes()); result.update(b"\0")
    return result.hexdigest()


def artifact(record, base):
    require(isinstance(record, dict) and set(record) == {"path", "sha256"},
            "Artifact requires exactly path and sha256")
    path = (base / record["path"]).resolve()
    require(re.fullmatch(r"[0-9a-f]{64}", record["sha256"]) is not None,
            "Invalid recorded SHA256")
    require(digest(path) == record["sha256"], f"Changed artifact: {path.name}")
    return path


def read_docx(path):
    require(path.is_file() and zipfile.is_zipfile(path), "Inspection must be DOCX")
    with zipfile.ZipFile(path) as package:
        require(all(i.file_size < 32 * 1024 * 1024 for i in package.infolist()),
                "Oversized DOCX member")
        root = ET.fromstring(package.read("word/document.xml"))
        rels = ET.fromstring(package.read("word/_rels/document.xml.rels"))
        targets = {r.get("Id"): r for r in rels}
        paragraphs = ["".join(p.itertext()) for p in root.findall(".//w:p", NS)]
        drawings = []
        for kind in ("inline", "anchor"):
            for drawing in root.findall(".//wp:" + kind, NS):
                extent = drawing.find("wp:extent", NS)
                blip = drawing.find(".//a:blip", NS)
                require(extent is not None and blip is not None, "Incomplete picture")
                rel = targets.get(blip.get("{" + NS["r"] + "}embed"))
                require(rel is not None and rel.get("TargetMode") != "External",
                        "Picture must be embedded")
                name = posixpath.normpath(posixpath.join("word", rel.get("Target", "")))
                require(name.startswith("word/media/"), "Unexpected media relationship")
                width, height = int(extent.get("cx")), int(extent.get("cy"))
                require(width > 0 and height > 0, "Invalid picture size")
                payload = package.read(name)
                drawings.append((kind, width, height, hashlib.sha256(payload).hexdigest(), payload))
    return paragraphs, drawings


def compare_documents(before, after, reopened, source):
    from PIL import Image, ImageChops, ImageStat
    first, updated, loaded = (read_docx(p) for p in (before, after, reopened))
    require(any(p.strip() for p in first[0]), "Before report must contain identifiable text")
    require([p for p in first[0] if p.strip()] == [p for p in updated[0] if p.strip()],
            "Insertion changed original report text")
    require(updated[0] == loaded[0], "Reopen changed report text")
    signature = lambda rows: Counter(row[:4] for row in rows)
    previous, current = signature(first[1]), signature(updated[1])
    require(not previous - current, "Insertion removed/replaced an existing picture")
    additions = list((current - previous).elements())
    require(len(additions) == 1 and additions[0][0] == "inline",
            "Expected exactly one new inline picture, not a floating anchor")
    require(signature(updated[1]) == signature(loaded[1]), "Reopen changed pictures/layout")
    picture = next(row for row in updated[1] if row[:4] == additions[0])
    with Image.open(source) as raw:
        original = raw.convert("RGBA")
        white = Image.new("RGBA", original.size, "white")
        white.alpha_composite(original); original = white.convert("RGB")
    require(min(original.size) > 0, "Invalid source image")
    require(max(ImageStat.Stat(original).stddev) >= 10,
            "Use a distinguishable synthetic image, not a uniform patch")
    scale = min(340 / original.width, 255 / original.height)
    expected = original.width * scale, original.height * scale
    for actual, wanted in zip(picture[1:3], expected):
        require(abs(actual / EMU_PER_POINT - wanted) <= 1,
                "Inline size/aspect differs from the production 340x255-point box")
    with Image.open(io.BytesIO(picture[4])) as raw:
        embedded = raw.convert("RGB")
    require(abs(embedded.width / embedded.height - original.width / original.height) <= 0.01,
            "Embedded image aspect changed")
    reference = original.resize(embedded.size, Image.Resampling.LANCZOS)
    error = sum(ImageStat.Stat(ImageChops.difference(reference, embedded)).mean) / 3
    require(math.isfinite(error) and error <= MAX_IMAGE_MAE,
            f"Embedded picture is not the selected source (RGB MAE {error:.3f})")
    return {"inlinePicturesAdded": 1, "widthPoints": picture[1] / EMU_PER_POINT,
            "heightPoints": picture[2] / EMU_PER_POINT, "imageMAE": error}


def pdf_pixels(path, folder, label):
    require(path.is_file() and path.read_bytes().startswith(b"%PDF-"), "Invalid PDF evidence")
    info = subprocess.run(["pdfinfo", str(path)], capture_output=True, text=True, check=True)
    match = re.search(r"^Pages:\s+(\d+)", info.stdout, re.M)
    require(match is not None and 0 < int(match[1]) <= 20, "Invalid/oversized PDF page count")
    prefix = folder / label
    subprocess.run(["pdftoppm", "-r", "72", "-png", str(path), str(prefix)],
                   capture_output=True, check=True)
    from PIL import Image
    result = []
    for page in sorted(folder.glob(label + "-*.png"),
                       key=lambda p: int(p.stem.rsplit("-", 1)[1])):
        with Image.open(page) as image:
            rgb = image.convert("RGB")
            result.append((rgb.size, hashlib.sha256(rgb.tobytes()).hexdigest()))
    require(len(result) == int(match[1]), "Missing rendered PDF page")
    return result


def verify(proof, base):
    require(proof.get("schema") == 1 and proof.get("origin") == "horos-cua-native",
            "Requires the native CUA collection contract")
    require(re.fullmatch(r"[0-9a-f]{40}", proof.get("source_revision", "")) is not None,
            "Missing full source revision")
    require(set(proof.get("editors", {})) == {"Word", "Pages"}, "Both editors required")
    originals = proof.get("preserved", [])
    require(len(originals) >= 2, "Preserve source image and master template hashes")
    preserved = {artifact(item, base) for item in originals}
    results = {}
    with tempfile.TemporaryDirectory(prefix="horos-native-report-artifacts-") as temporary:
        folder = Path(temporary)
        for name, record in proof["editors"].items():
            bundle = (base / record["bundle"]).resolve()
            with (bundle / "Contents/Info.plist").open("rb") as file:
                info = plistlib.load(file)
            ids = {"Word": {"com.microsoft.Word"},
                   "Pages": {"com.apple.Pages", "com.apple.iWork.Pages"}}
            require(info.get("CFBundleIdentifier") in ids[name], "Incorrect editor bundle")
            keys = ["source_image", "master_template", "native_before", "native_after", "native_reopened",
                    "inspection_before", "inspection_after", "inspection_reopened",
                    "pdf_before", "pdf_after", "pdf_reopened"]
            paths = {key: artifact(record[key], base) for key in keys}
            require(paths["source_image"] in preserved, "Source image not hash-protected")
            require(paths["master_template"] in preserved, "Master template not hash-protected")
            require(paths["master_template"] != paths["source_image"], "Template is not an image")
            native = [paths[k] for k in ("native_before", "native_after", "native_reopened")]
            require(len(set(native)) == 3, "Use three distinct immutable native snapshots")
            require(not preserved.intersection(native), "Native work must not overwrite originals")
            require(digest(native[0]) != digest(native[1]), "Native report did not change")
            expected_suffix = ".docx" if name == "Word" else ".pages"
            require(all(p.suffix.lower() == expected_suffix for p in native), "Wrong native format")
            if name == "Word":
                require(all(digest(paths["inspection_" + stage]) == digest(paths["native_" + stage])
                            for stage in ("before", "after", "reopened")),
                        "Word inspection must be the actual native snapshot")
            else:
                for path in native:
                    if path.is_dir():
                        require((path / "Index/Document.iwa").is_file(), "Invalid modern Pages package")
                    else:
                        require(zipfile.is_zipfile(path), "Native Pages snapshot is not a package")
                        with zipfile.ZipFile(path) as package:
                            require("Index/Document.iwa" in package.namelist(), "Missing native Pages document")
            results[name] = compare_documents(paths["inspection_before"], paths["inspection_after"],
                                               paths["inspection_reopened"], paths["source_image"])
            pdf = [pdf_pixels(paths["pdf_" + stage], folder, name + "-" + stage)
                   for stage in ("before", "after", "reopened")]
            require(pdf[0] != pdf[1], "PDF did not show the inserted image")
            require(pdf[1] == pdf[2], "Save/reopen changed the rendered PDF layout")
            results[name]["pdfPages"] = len(pdf[1])
            results[name]["editorVersion"] = info.get("CFBundleShortVersionString", "")
    return results


def negative_controls():
    # Deliberately synthetic XML ZIPs exercise rejection only; no native proof.
    from PIL import Image
    with tempfile.TemporaryDirectory(prefix="horos-report-negative-controls-") as temporary:
        folder = Path(temporary); source = folder / "source.png"
        image = Image.new("RGB", (800, 600), "black")
        for x in range(300):
            for y in range(200): image.putpixel((x, y), (255, 64, 16))
        image.save(source); encoded = io.BytesIO(); image.save(encoded, format="PNG")
        def package(name, kind="inline", width=340, height=255, pixels=None, text="Synthetic control"):
            path = folder / name
            drawing = "" if kind is None else (f'<w:drawing><wp:{kind}><wp:extent cx="{int(width*EMU_PER_POINT)}" cy="{int(height*EMU_PER_POINT)}"/><a:blip r:embed="r1"/></wp:{kind}></w:drawing>')
            xml = f'<w:document xmlns:w="{NS["w"]}" xmlns:wp="{NS["wp"]}" xmlns:a="{NS["a"]}" xmlns:r="{NS["r"]}"><w:body><w:p><w:r><w:t>{text}</w:t>{drawing}</w:r></w:p></w:body></w:document>'
            rels = '<Relationships><Relationship Id="r1" Target="media/image.png"/></Relationships>'
            with zipfile.ZipFile(path, "w") as z:
                z.writestr("word/document.xml", xml); z.writestr("word/_rels/document.xml.rels", rels)
                z.writestr("word/media/image.png", pixels or encoded.getvalue())
            return path
        before = package("before.docx", kind=None); good = package("good.docx")
        # This is an internal synthetic sanity check, never native provenance.
        compare_documents(before, good, good, source)
        wrong = io.BytesIO(); Image.new("RGB", (800, 600), "white").save(wrong, format="PNG")
        cases = {"floating picture": package("anchor.docx", kind="anchor"),
                 "wrong size": package("size.docx", width=100),
                 "changed text": package("text.docx", text="Changed"),
                 "wrong pixels": package("pixels.docx", pixels=wrong.getvalue())}
        count = 0
        for label, altered in cases.items():
            try: compare_documents(before, altered, altered, source)
            except ValueError: count += 1
            else: raise AssertionError("Accepted synthetic corruption: " + label)
        try: compare_documents(before, good, cases["wrong size"], source)
        except ValueError: count += 1
        else: raise AssertionError("Accepted changed reopen layout")
        try: artifact({"path": str(source), "sha256": "0" * 64}, folder)
        except ValueError: count += 1
        else: raise AssertionError("Accepted changed original")
        for proof in ({"schema": 1, "origin": "synthetic"},
                      {"schema": 1, "origin": "horos-cua-native", "source_revision": "1" * 40,
                       "editors": {"Word": {}}}):
            try: verify(proof, folder)
            except ValueError: count += 1
            else: raise AssertionError("Accepted missing native provenance/editor")
    print(f"PASS: {count} synthetic negative controls rejected; NON_NATIVE, no editor QA")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--proof-manifest", type=Path)
    parser.add_argument("--check-negative-controls", action="store_true")
    args = parser.parse_args()
    if not args.proof_manifest and not args.check_negative_controls:
        parser.exit(2, "skipped: needs --proof-manifest with real CUA Word/Pages artifacts\n")
    try:
        import PIL  # Artifact decoding only; no editor automation.
        if args.check_negative_controls:
            negative_controls()
        if args.proof_manifest:
            if not shutil.which("pdfinfo") or not shutil.which("pdftoppm"):
                parser.exit(2, "skipped: needs existing pdfinfo/pdftoppm readers\n")
            results = verify(json.loads(args.proof_manifest.read_text()), args.proof_manifest.resolve().parent)
            print("PASS: native Word/Pages artifact insertion, size, reopen layout and originals: " + json.dumps(results, sort_keys=True))
    except ImportError:
        parser.exit(2, "skipped: artifact decoding needs Pillow\n")
    except (ValueError, KeyError, OSError, ET.ParseError, zipfile.BadZipFile,
            subprocess.CalledProcessError) as error:
        parser.exit(1, f"FAIL: {error}\n")


if __name__ == "__main__":
    main()
