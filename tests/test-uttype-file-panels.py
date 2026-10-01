#!/usr/bin/env python3
"""File panels retain extension-specific filters, including dynamic/custom types.

Compile the actual migrated filter expressions against both Swift and Objective-C
SDK APIs, without opening panels or touching the shared application/database.
Check filename tags, unrelated-type rejection, RTFD package conformance and the
short JPEG/TIFF extension used for suggested export names. Interactive selection,
cancellation and export/reimport remain integration checks in the application.
"""
from pathlib import Path
import json
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
# Inventory of the 54 pre-migration filters; values are extensions, not UTIs.
EXPECTED = json.loads(r'''{
  "Preference Panes/AYDicomPrintPreferencePane/AYDicomPrintPref.swift": [
    [
      "plist"
    ],
    [
      "plist"
    ]
  ],
  "Preference Panes/OSIGeneralPreferencePane/OSIGeneralPreferencePanePref.swift": [
    [
      "plist"
    ]
  ],
  "Horos/Sources/QueryController.mm": [
    [
      "txt"
    ]
  ],
  "Horos/Sources/EndoscopyMPRView.swift": [
    [
      "jpg"
    ]
  ],
  "Horos/Sources/BrowserController+SplitView.swift": [
    [
      "albums"
    ],
    [
      "albums"
    ]
  ],
  "Horos/Sources/BrowserController+DatabaseDragExport+Selection.swift": [
    [
      "txt",
      "csv",
      "text"
    ],
    [
      "csv"
    ],
    [
      "txt"
    ]
  ],
  "Preference Panes/OSILocationsPreferencePane/OSILocationsPreferencePanePref.swift": [
    [
      "plist"
    ],
    [
      "plist"
    ],
    [
      "plist"
    ],
    [
      "plist"
    ],
    [
      "sql"
    ]
  ],
  "Preference Panes/OSICustomImageAnnotations/OSICustomImageAnnotations.swift": [
    [
      "plist"
    ],
    [
      "plist"
    ]
  ],
  "Horos/Sources/QuicktimeExport.swift": [
    [
      "mov"
    ]
  ],
  "Horos/Sources/BrowserController+Reports.swift": [
    [
      "pdf"
    ]
  ],
  "Horos/Sources/BurnerWindowController.swift": [
    [
      "dmg"
    ]
  ],
  "Horos/Sources/SRView.mm": [
    [
      "rib"
    ],
    [
      "wrl"
    ],
    [
      "iv"
    ],
    [
      "obj"
    ],
    [
      "stl"
    ]
  ],
  "Horos/Sources/DCMView.m": [
    [
      "roi"
    ]
  ],
  "Horos/Sources/CPRController.swift": [
    [
      "jpg"
    ],
    [
      "tif"
    ],
    [
      "curvedPath"
    ],
    [
      "curvedPath",
      "txt",
      "xyz",
      "csv"
    ]
  ],
  "Horos/Sources/ViewerController+ROIInterchange.swift": [
    [
      "json"
    ]
  ],
  "Horos/Sources/XMLController.swift": [
    [
      "xml"
    ],
    [
      "txt"
    ]
  ],
  "Horos/Sources/ROIVolumeView.mm": [
    [
      "jpg"
    ]
  ],
  "Horos/Sources/BrowserController.m": [
    [
      "sql"
    ],
    [
      "csv",
      "txt",
      "numbers"
    ],
    [
      "pdf",
      "rtf",
      "rtfd",
      "doc",
      "docx",
      "pages",
      "odt",
      "txt"
    ]
  ],
  "Horos/Sources/OrthogonalMPRPETCTViewer.swift": [
    [
      "jpg"
    ]
  ],
  "Horos/Sources/SRController.mm": [
    [
      "jpg"
    ],
    [
      "tif"
    ]
  ],
  "Horos/Sources/LogWindowController.swift": [
    [
      "csv"
    ]
  ],
  "Horos/Sources/VRController.mm": [
    [
      "jpg"
    ],
    [
      "tif"
    ]
  ],
  "Horos/Sources/ROIWindow.swift": [
    [
      "roi"
    ],
    [
      "xml"
    ]
  ],
  "Horos/Sources/FlyThruStepsArrayController.swift": [
    [
      "xml"
    ],
    [
      "xml"
    ]
  ],
  "Horos/Sources/MPRController.swift": [
    [
      "jpg"
    ],
    [
      "tif"
    ]
  ],
  "Horos/Sources/ViewerController+Export.swift": [
    [
      "jpg"
    ],
    [
      "tif"
    ]
  ],
  "Horos/Sources/ViewerController+ROI.swift": [
    [
      "roi",
      "rois_series",
      "xml",
      "json"
    ],
    [
      "rois_series"
    ]
  ],
  "Horos/Sources/OrthogonalMPRViewer.swift": [
    [
      "jpg"
    ]
  ]
}''')

swift = ['import AppKit', 'import UniformTypeIdentifiers']
objc = ['#import <AppKit/AppKit.h>', '#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>',
        'int main(void) { @autoreleasepool {']
count = 0
for filename, extension_lists in EXPECTED.items():
    source = (ROOT / filename).read_text(errors='surrogateescape')
    assert not re.search(r'allowedFileTypes|setAllowedFileTypes', source), filename
    assert 'UniformTypeIdentifiers' in source, filename
    if filename.endswith('.swift'):
        filters = re.findall(r'allowedContentTypes = (\[[^\n]+\])', source)
        assert len(filters) == len(extension_lists), filename
        for expression, extensions in zip(filters, extension_lists):
            expression = expression.replace('selected.value(forKey: "extension") as! String', '"mov"')
            expression = expression.replace('ROIInterchange.fileExtension', '"json"')
            assert re.findall(r'filenameExtension: "([^"]+)"', expression) == extensions, filename
            swift.append(f'let types{count}: [UTType] = {expression}')
            swift.append(f'@MainActor func apply{count}(_ panel: NSSavePanel) {{ panel.allowedContentTypes = types{count} }}')
            for index, ext in enumerate(extensions):
                swift.append(f'assert(types{count}[{index}].tags[.filenameExtension]!.map {{ $0.lowercased() }}.contains("{ext.lower()}"))')
                swift.append(f'assert(types{count}[{index}] != .data && !UTType.png.conforms(to: types{count}[{index}]))')
            count += 1
        # Exercise the actual naming guard in isolation with a stand-in panel.
        for block in re.findall(r'        if !\["(?:jpg|tif)"[^\n]+\n[^\n]+\n        }', source):
            ext = re.search(r'\+= "\.(jpg|tif)"', block)[1]
            swift.append('do { let panel = NamePanel(); panel.nameFieldStringValue = "Study.0001"')
            swift.append(block)
            swift.append(f'assert(panel.nameFieldStringValue == "Study.0001.{ext}") }}')
            swift.append(f'do {{ let panel = NamePanel(); panel.nameFieldStringValue = "Study.{ext}"')
            swift.append(block)
            swift.append(f'assert(panel.nameFieldStringValue == "Study.{ext}") }}')
    else:
        filters = [expression[:-1] if setter else expression for setter, expression in
                   re.findall(r'(?:allowedContentTypes = |(setAllowedContentTypes:))(@[^\n;]+);', source)]
        assert len(filters) == len(extension_lists), filename
        for expression, extensions in zip(filters, extension_lists):
            actual = re.findall(r'typeWithFilenameExtension:@"([^"]+)"|\b(UTTypeRTFD)\b', expression)
            assert [a or 'rtfd' for a, b in actual] == extensions, filename
            objc.append(f'NSArray<UTType *> *types{count} = {expression};')
            objc.append(f'if (NO) {{ NSSavePanel *panel = nil; panel.allowedContentTypes = types{count}; }}')
            for index, ext in enumerate(extensions):
                objc.append(f'NSCAssert([types{count}[{index}].tags[UTTagClassFilenameExtension] containsObject:@"{ext}"], @"filename tag");')
                objc.append(f'NSCAssert(![types{count}[{index}] isEqual:UTTypeData] && ![UTTypePNG conformsToType:types{count}[{index}]], @"specific filter");')
                if ext == 'rtfd':
                    objc.append(f'NSCAssert([types{count}[{index}] conformsToType:UTTypePackage], @"RTFD package");')
            count += 1
assert count == 54, count
swift.append('class NamePanel { var nameFieldStringValue = "" }')
# Unknown/custom extensions must resolve to a constrained dynamic type, never
# disappear through compactMap and turn the panel into an unrestricted filter.
swift.append('let unknown = UTType(filenameExtension: "horos_1037_unknown")!')
swift.append('assert(unknown.isDynamic && unknown != .data && !UTType.png.conforms(to: unknown))')
# Both codec choices of the movie accessory have a concrete filename type.
swift.append('assert(UTType(filenameExtension: "mp4")!.preferredFilenameExtension == "mp4")')
objc.append('} return 0; }')
if sys.platform != 'darwin' or not shutil.which('xcrun'):
    print('SKIP: runtime SDK validation requires macOS and xcrun')
    sys.exit(2)
with tempfile.TemporaryDirectory(prefix='horos-uttype-') as folder:
    tmp = Path(folder)
    (tmp / 'main.swift').write_text('\n'.join(swift))
    (tmp / 'main.m').write_text('\n'.join(objc))
    subprocess.run(['xcrun', 'swiftc', str(tmp / 'main.swift'), '-o', str(tmp / 'swift-test')], check=True)
    subprocess.run([str(tmp / 'swift-test')], check=True)
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', str(tmp / 'main.m'), '-framework', 'AppKit',
                    '-framework', 'UniformTypeIdentifiers', '-o', str(tmp / 'objc-test')], check=True)
    subprocess.run([str(tmp / 'objc-test')], check=True)
print('PASS: 54 migrated panel filters, custom filename tags, package conformance and export suffixes')
