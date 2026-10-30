#!/usr/bin/env python3
"""Hardcopy objects are pictures: the browser must list them, empty or not.

A hardcopy grayscale instance sitting in a mammography study is the shape of the
crash report behind this check. It did not crash here — it disappeared: the SOP class
was not among the ones the application lists as images, so
-[DicomStudy imageSeries] left the series out of the browser entirely, while the
study still counted its modality. Neither a supported representation nor a
diagnosis reached the user.
"""
from pathlib import Path
import subprocess, sys, tempfile

from sources import source_text

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from isix_modules import build_module  # noqa: E402

# The SOP classes are the IsiXDICOMFile module's.
syntaxes = (root / 'Modules/IsiXDICOMFile/Sources/DICOMSOPClass.swift').read_text()
images = syntaxes[syntaxes.index('static let defaultImageSyntaxes = ['):]
images = images[:images.index(']')]
for name, uid in (('hardcopyGrayscaleImageStorage', '1.2.840.10008.5.1.1.29'),
                  ('hardcopyColorImageStorage', '1.2.840.10008.5.1.1.30')):
    assert f'static let {name} = "{uid}"' in syntaxes, f'{name} is not declared'
    assert f'{name},' in images, f'{name} is not in the image syntaxes'
# The listing decision reads that list, so keep the path intact.
# DicomStudy is Swift; the assertion reads its Swift spelling.
study = source_text('DicomStudy')
assert 'DICOMSOPClass.isImageStorage(uid)' in study, 'the browser no longer lists series by SOP class'

program = r"""
import Foundation
import IsiXDICOMFile
let cases: [(String, Bool, String)] = [
    ("1.2.840.10008.5.1.1.29", true, "hardcopy grayscale"),
    ("1.2.840.10008.5.1.1.30", true, "hardcopy colour"),
    ("1.2.840.10008.5.1.4.1.1.1.2", true, "digital mammography"),
    ("1.3.12.2.1107.5.9.1", false, "a private Siemens non-image class"),
    ("1.2.840.10008.5.1.1.9", false, "the grayscale print management meta class"),
]
for (uid, image, what) in cases where DICOMSOPClass.isImageStorage(uid) != image {
    print("FAIL: \(what) (\(uid)) reported \(image ? "not image storage" : "image storage")")
    exit(1)
}
print("PASS: both hardcopy classes are image storage, the print meta class and the private Siemens class are not")
"""
with tempfile.TemporaryDirectory(prefix='horos-hardcopy-') as tmp:
    p = Path(tmp)
    modules = p / 'modules'
    build_module('IsiXImaging', modules)
    build_module('IsiXDICOMFile', modules, ['-I', str(modules)])
    (p / 'main.swift').write_text(program)
    subprocess.run(['xcrun', 'swiftc', '-I', str(modules), '-L', str(modules), '-lIsiXDICOMFile', '-lIsiXImaging',
                    str(p / 'main.swift'), '-o', str(p / 'test')], check=True)
    done = subprocess.run([str(p / 'test')], capture_output=True, text=True)
    print(done.stdout.strip() or done.stderr.strip())
    if done.returncode: sys.exit(1)
