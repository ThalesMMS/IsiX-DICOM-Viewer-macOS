#!/usr/bin/env python3
"""Verify the pinned provider and select the host's framework implementations."""
from pathlib import Path
import argparse
import hashlib
import json
import shutil

PIN = "92230feade69e1298cd5a8cbc0c8ddd2dc939934"
HOST_SOURCES = ("FRConsoleLog.m", "FRUploader.m", "FRFeedbackController.m", "FRCrashLogFinder.m")


def prepare(provider: Path, destination: Path):
    configuration = Path(__file__).resolve().parent
    manifest = json.loads((configuration / "upstream.json").read_text())
    if manifest["revision"] != PIN:
        raise ValueError("FeedbackReporter revision differs from the supported upstream pin")
    actual = {str(path.relative_to(provider)) for path in provider.rglob("*")
              if path.is_file() and path.relative_to(provider).parts[0] != ".git"}
    if actual != set(manifest["files"]):
        expected = set(manifest["files"])
        raise ValueError("FeedbackReporter file set differs from the pinned upstream tree: "
                         f"missing={sorted(expected - actual)}, extra={sorted(actual - expected)}")
    for name, digest in manifest["files"].items():
        path = provider / name
        mode = "100755" if path.stat().st_mode & 0o111 else "100644"
        if path.is_symlink() or mode != manifest["modes"][name] or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise ValueError(f"FeedbackReporter upstream integrity mismatch: {name}")
    if provider == destination or provider in destination.parents or destination in provider.parents:
        raise ValueError("FeedbackReporter workspace must be outside its upstream source tree")
    if destination.exists():
        raise ValueError("FeedbackReporter build workspace must be new")
    destination.mkdir(parents=True)
    # Sources are selected individually. The upstream checkout is never patched,
    # and exactly one implementation of each Objective-C class reaches Sources.
    for path in (provider / "Sources").rglob("*"):
        if not path.is_file():
            continue
        selected = path
        if path.parent.name == "Main" and path.name in HOST_SOURCES:
            selected = configuration.parents[1] / "FeedbackReporter" / path.name
        target = destination / path.relative_to(provider)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.symlink_to(selected.resolve())
    project = destination / "FeedbackReporter.xcodeproj"
    shutil.copytree(provider / "FeedbackReporter.xcodeproj", project)
    shutil.copyfile(configuration / "Framework.project", project / "project.pbxproj")
    shutil.copytree(provider / "Resources", destination / "Resources")
    for resource in (destination / "Resources").rglob("*.xib"):
        text = resource.read_text()
        adapted = text.replace('<deployment version="1090" identifier="macosx"/>',
                               '<deployment identifier="macosx"/>')
        if adapted != text:
            adapted = adapted.replace('<?xml version="1.0" encoding="UTF-8"?>',
                                      '<?xml version="1.0" encoding="UTF-8"?>\n'
                                      '<!-- Modified in this fork: obsolete deployment version removed on a build copy. -->', 1)
        resource.write_text(adapted)
    shutil.copyfile(provider / "dsa_pub.pem", destination / "dsa_pub.pem")
    record = {
        "url": manifest["url"], "revision": PIN, "tree": manifest["tree"],
        "hostSources": {name: hashlib.sha256(
            (configuration.parents[1] / "FeedbackReporter" / name).read_bytes()).hexdigest()
                        for name in HOST_SOURCES},
        "resourceAdjustment": "remove obsolete XIB deployment version from build copies only",
    }
    (destination / "BuildSource.json").write_text(json.dumps(record, indent=2) + "\n")
    return destination


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("provider", type=Path)
    parser.add_argument("destination", type=Path)
    arguments = parser.parse_args()
    prepare(arguments.provider.resolve(), arguments.destination.resolve())
