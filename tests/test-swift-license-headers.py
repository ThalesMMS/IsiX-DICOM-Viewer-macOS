#!/usr/bin/env python3
"""Protect fork attribution and inherited credits in every checkout Swift file.

Discovered by tools/run-tests.py, with no build, fixture or Git history needed.
Git supplies tracked AND non-ignored new files; generated/ignored build outputs
are outside the checkout contract. Exceptions name individual vendored files,
so adding our own Swift source under a vendor directory does not bypass this.

swift-converted-headers.json records which files were converted (including
helpers) and pins their original comment blocks. This prevents replacing a
conversion's inherited credits with the otherwise-valid new-file header.
For a new conversion, add its path and the SHA-256 of the ORIGINAL .m/.mm
leading comment, through */. Do not refresh hashes to accept changed credits.
Years stay with the files: a future calendar year must not invalidate old work.
"""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
AUTHOR = "Thales Matheus M Santos (ThalesMMS)"
YEAR = r"20\d{2}"
NEW_HEADER = re.compile(
    rf"//  Copyright \(c\) {YEAR} {re.escape(AUTHOR)}\n"
    r"//\n"
    r"//  This file is part of a fork of Horos \(https://github.com/ThalesMMS/horos\).\n"
    r"//\n"
    r"//  It is free software: you can redistribute it and/or modify it under the\n"
    r"//  terms of the GNU Lesser General Public License as published by the Free\n"
    r"//  Software Foundation, version 3 of the License.\n"
    r"//\n"
    r"//  It is distributed in the hope that it will be useful, but WITHOUT ANY\n"
    r"//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR\n"
    r"//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.\n"
)
MODIFICATIONS = re.compile(
    rf"\n//\n//  Copyright \(c\) {YEAR} {re.escape(AUTHOR)} — modifications in this fork\n"
)

# Each exception carries its origin and a checked-in license/provenance reference.
# Keep paths exact; no directory globs or automatic 'ThirdParty' exemptions.
EXCEPTIONS = {}



def swift_files(root):
    result = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", "*.swift"],
        cwd=root, capture_output=True, check=True,
    )
    return sorted(set(result.stdout.decode("utf-8").split("\0")) - {""})


def converted_headers():
    manifest = json.loads((ROOT / "tests/swift-converted-headers.json").read_text(encoding="utf-8"))
    headers = {}
    for group in manifest["headers"]:
        if not re.fullmatch(r"[0-9a-f]{64}", group["sha256"]):
            raise ValueError("invalid converted-header SHA-256")
        for path in group["files"]:
            if path in headers or path in EXCEPTIONS:
                raise ValueError(f"duplicate/conflicting converted-header entry: {path}")
            headers[path] = group["sha256"]
    if not headers:
        raise ValueError("empty converted-header inventory")
    return headers


def header_error(data, original_digest=None):
    # A shebang is permitted only for executable Swift scripts. The notice must
    # immediately follow it; no whitespace, BOM, code or other comments before it.
    if data.startswith(b"#!/usr/bin/env swift\n"):
        data = data.split(b"\n", 1)[1]
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return "source is not UTF-8"
    if original_digest is not None:
        end = data.find(b"*/") + 2
        if not data.startswith(b"/*") or end < 2:
            return "converted file must start with its inherited Horos/OsiriX block"
        if hashlib.sha256(data[:end]).hexdigest() != original_digest:
            return "inherited Horos/OsiriX block changed (restore original credits/header)"
        if not MODIFICATIONS.match(data[end:].decode("utf-8")):
            return "missing fork modifications attribution immediately after inherited block"
    else:
        match = NEW_HEADER.match(text)
        if not match:
            return "expected complete ThalesMMS LGPLv3 new-file header; register conversions in the inventory"
        comments = re.match(r"(?:\s+|//[^\n]*(?:\n|$)|/\*.*?\*/)*",
                            text[match.end():], re.DOTALL).group()
        if re.search(r"Copyright\s*(?:\([cC]\)|©)", comments, re.IGNORECASE):
            return "new-file header must contain only the fork author's copyright"
    return None


def check_rejections():
    """In-memory mutations prove that the check detects the requested regressions."""
    native = f"""//  Copyright (c) 2026 {AUTHOR}
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.
""".encode("utf-8")
    # Synthetic notice: this tests preservation, not a particular app filename.
    legacy = b"/* Original Horos/OsiriX notice: Copyright (c) OsiriX Team. */"
    converted = legacy + f"\n//\n//  Copyright (c) 2026 {AUTHOR} — modifications in this fork\n".encode("utf-8")
    digest = hashlib.sha256(legacy).hexdigest()
    assert header_error(native) is None
    assert header_error(b"#!/usr/bin/env swift\n" + native) is None
    assert header_error(converted, digest) is None
    assert header_error(native.replace(b"2026", b"2027", 1)) is None
    mutations = (
        (b"import Foundation\n" + native, None),
        (b"\n" + native, None),
        (b"\xef\xbb\xbf" + native, None),
        (native.replace(AUTHOR.encode(), b"Horos Project", 1), None),
        (native.replace(b"version 3", b"version 2", 1), None),
        (native.replace(b"WITHOUT ANY", b"WITH", 1), None),
        (native.replace(b"https://github.com/ThalesMMS/horos", b"https://example.org", 1), None),
        (native + b"// Copyright (c) Horos Project\n", None),
        (converted.replace(b"Copyright (c) OsiriX Team", b"Copyright (c) Someone", 1), digest),
        (converted.replace(b"modifications in this fork", b"", 1), digest),
        (converted.replace(AUTHOR.encode(), b"Horos Project", 1), digest),
        (native, digest),  # Removing inherited credits cannot reclassify a conversion.
        (converted, None),  # New conversions need an explicit provenance entry.
    )
    for index, (data, expected_digest) in enumerate(mutations, 1):
        if header_error(data, expected_digest) is None:
            raise AssertionError(f"header check accepted invalid mutation {index}")
    return len(mutations)


def main():
    original = converted_headers()
    files = swift_files(ROOT)
    if not files:
        raise ValueError("no Swift files found; refusing a vacuous pass")
    rejected = check_rejections()
    failures = []
    for path in sorted((original.keys() | EXCEPTIONS.keys()) - set(files)):
        failures.append(f"{path}: stale inventory/exception; update it after removing or moving this file")
    for path in files:
        if path in EXCEPTIONS:
            reason, *references = EXCEPTIONS[path]
            if not reason or any(not (ROOT / ref).is_file() for ref in references):
                failures.append(f"{path}: exception lacks origin/license evidence")
            continue
        try:
            error = header_error((ROOT / path).read_bytes(), original.get(path))
        except OSError as exc:
            error = str(exc)
        if error:
            failures.append(f"{path}: {error}")
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    if failures:
        return 1
    print(f"PASS: Swift license headers: {len(original)} converted, "
          f"{len(files) - len(original) - len(EXCEPTIONS)} new, "
          f"{len(EXCEPTIONS)} explicit vendor exceptions; {rejected} invalid mutations rejected")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
