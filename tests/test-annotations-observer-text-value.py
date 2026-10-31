#!/usr/bin/env python3
"""The 2D view follows ANNOTATIONS as integer(forKey:) reads it.

Every DCMView observes ANNOTATIONS in the standard defaults and moves its
annotation level when the key changes. The key is not always a number: the
application registers the text "2", and `defaults write -string` stores text.
The change dictionary carries the value as it was written, so a level read
from it as a number fell to 0 (None) on text, and on a removed value, while
integer(forKey:) read the level. The observer reads the level from the
preferences through the catalog's key instead.

The body of the observer, as DCMView+WindowLevel.swift has it, is compiled
into a stand-in view with the few members it uses, over the real
PreferencesSource and IsiXPreferences, and the stand-in observes the standard
defaults of its own binary. Text and numbers are written; after each one the
view's level must be what integer(forKey:) reads, including the registered
text once the user's value is removed.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import harness_defaults  # noqa: E402  - the harness's writes stay in its own argument domain
import process_graph_stand_in  # the observer reads the catalog's keys through PreferencesSource

root = Path(__file__).resolve().parents[1]
sources = root / 'Horos/Sources'
source = (sources / 'DCMView+WindowLevel.swift').read_text(encoding='utf-8')

signature = re.search(r'public override dynamic func observeValue\(forKeyPath keyPath: String\?, of object: Any\?, '
                      r'change: \[NSKeyValueChangeKey: Any\]\?, context: UnsafeMutableRawPointer\?\) \{\n', source)
if not signature:
    sys.exit('FAIL: the observer of DCMView+WindowLevel.swift was not found')
end = source.index('\n    }\n', signature.end())
body = source[signature.end():end]

failures = []
if 'newKey' in body or 'change?[' in body:
    failures.append('the observer still reads the level from the change dictionary')
if '"ANNOTATIONS"' in body:
    failures.append('the observer names ANNOTATIONS by text, not through the catalog key')

# The members of DCMView the body uses, nothing more: a different name in the
# body fails to compile here, and the test is updated with it.
stand_in = r'''
import AppKit
import IsiXPreferences

final class ROI: NSObject {
    func updateLabelFont() {}
}

@MainActor
final class DCMView: NSObject {
    var horos_annotationType: Int32 = -1
    var annotationType: Int32 {
        get { horos_annotationType }
        set { horos_annotationType = newValue }
    }
    var needsDisplay = false
    var horos_dcmRoiList: NSArray? = nil

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
''' + body + r'''
    }
}
'''

driver = r'''
import Foundation

func check(_ condition: Bool, _ message: String) {
    if !condition { FileHandle.standardError.write((message + "\n").data(using: .utf8)!); exit(1) }
}

// The binary's own persistent domain, emptied before and after.
let domain = "horos-annotations-observer-check"
let defaults = UserDefaults.standard
defaults.removePersistentDomain(forName: domain)
defaults.register(defaults: ["ANNOTATIONS": "2"])

MainActor.assumeIsolated {
    let view = DCMView()
    defaults.addObserver(view, forKeyPath: "ANNOTATIONS", options: .new, context: nil)
    let writes: [(Any?, String)] = [
        ("1", "the text \"1\""), (3 as NSNumber, "the number 3"), (" 0", "the text \" 0\""),
        ("4", "the text \"4\""), (1 as NSNumber, "the number 1"), (nil, "the user's value removed (registered \"2\")"),
        ("3", "the text \"3\""), ("2", "the text \"2\""),
    ]
    for (value, label) in writes {
        view.needsDisplay = false
        let before = view.horos_annotationType
        if let value { defaults.set(value, forKey: "ANNOTATIONS") } else { defaults.removeObject(forKey: "ANNOTATIONS") }
        let expected = Int32(defaults.integer(forKey: "ANNOTATIONS"))
        check(view.horos_annotationType == expected, "\(label): the view is at \(view.horos_annotationType), integer(forKey:) reads \(expected)")
        check(view.needsDisplay == (before != expected), "\(label): redraw asked \(view.needsDisplay), level changed \(before != expected)")
    }
    check(view.horos_annotationType == 2, "the last level")

    // Another key the view observes leaves the level alone.
    view.horos_annotationType = 7
    view.needsDisplay = false
    view.observeValue(forKeyPath: "LabelFONTSIZE", of: defaults, change: [.newKey: "12"], context: nil)
    check(view.horos_annotationType == 7 && view.needsDisplay == false, "LabelFONTSIZE changed the annotation level")
    defaults.removeObserver(view, forKeyPath: "ANNOTATIONS")
}
defaults.removePersistentDomain(forName: domain)
print("ok")
'''

with tempfile.TemporaryDirectory() as folder:
    folder = Path(folder)
    (folder / 'StandIn.swift').write_text(stand_in)
    (folder / 'main.swift').write_text(harness_defaults.SWIFT + driver)
    binary = folder / 'horos-annotations-observer-check'
    try:
        subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', '-module-cache-path', str(folder / 'modules'),
                        str(sources / 'MainActorCallbacks.swift'), str(folder / 'StandIn.swift'), str(folder / 'main.swift'),
                        *process_graph_stand_in.swift_flags(folder / 'isix'), '-o', str(binary)], check=True)
        result = subprocess.run([str(binary)], capture_output=True, text=True)
        if result.returncode != 0 or result.stdout.strip() != 'ok':
            failures.append((result.stderr or result.stdout).strip() or f'the harness exited with {result.returncode}')
    except subprocess.CalledProcessError as error:
        failures.append(f'the observer slice did not compile ({error.returncode})')
    finally:
        # The binary empties its defaults domain; the empty file goes too.
        (Path.home() / 'Library/Preferences' / f'{binary.name}.plist').unlink(missing_ok=True)

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
print('ANNOTATIONS observer: text and numbers move the view to the level integer(forKey:) reads')
