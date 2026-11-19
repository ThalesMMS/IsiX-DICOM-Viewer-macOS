#!/usr/bin/env python3
"""The table an object carries instead of a window is read, and applied.

PS 3.3 C.11.2: when an object has a VOI LUT Sequence, that table is how its
values are meant to be shown and Window Center and Width are the alternative.
Horos read neither. Three things were in the way, and all three are checked
here: the name dictionary spelled the tag's name with its value representations
stuck on the end, so no lookup by name could find it; the preference that turns
the feature on switched itself off on the first image loaded, and wrote the
answer back into the defaults so the menu item could not turn it on again; and
nothing on the path that actually runs ever called the code that applies a table.
"""
from pathlib import Path
import re
import subprocess
import tempfile
import sys
from dcmtk_build import dcmtk_dictionary
from sources import class_text

root = Path(__file__).resolve().parents[1]

# The tag's name, which is how every lookup in the framework reaches it. The
# names come from DCMTK's dictionary, plus the legacy spellings that differ
# from its keywords (the framework's own plists are gone). The dictionary is
# the one of the pinned DCMTK source archive, the file the build ships.
dictionary = dcmtk_dictionary().read_text(errors='replace')
assert re.search(r'^\(0028,3006\)\s+\S+\s+LUTData\s', dictionary, re.M), \
    'LUT Data cannot be looked up by name, so a VOI LUT is never read'
legacy = (root / 'Horos/Sources/Adapters/DCMTK/HorosDICOMLegacyNames.hpp').read_text(errors='replace')
assert 'LUTDataUS/SS/OW' not in legacy and '"LUTData' not in legacy, \
    'a legacy spelling shadows the keyword, or still carries its value representations'

pix = class_text('DCMPix')
assert 'VOILUT is not supported with DCMFramework' not in pix, \
    'the preference still turns itself off on the first image loaded'
settings = (root / 'Horos/Sources/DCMPixSettings.swift').read_text(errors='replace')
# Every input value has an output (PS 3.3 C.11.2.1.1): a frame wholly outside
# the table, or on its first entry, is a uniform one. Reading it as a corrupted
# table turned the preference off for every image after it.
assert 'forKey: "UseVOILUT")' not in pix and 'ViewerPreferences.useVOILUT)' not in settings \
    and 'turnOffVOILUT' not in pix + settings, \
    'loading an image writes the preference away from what the user chose'
# The frame loading, in the IsiXImaging module, hands the samples of a whole
# frame to the step DCMPix gives it; tests/test-dcmpix-frame-loading.py checks
# when it runs and on what.
loader = (root / 'Modules/IsiXImaging/Sources/FrameLoader.swift').read_text()
assert 'self.applyVOILUT(from: dcmObject, to: samples)' in pix and 'applyingVOILUT: voiLUT)' in pix \
    and 'voiLUT(samples!' in loader, \
    'nothing applies the table on the path that runs'
# The table's input is the output of the modality LUT: a sample enters it by
# its rescaled value, and what comes out is not rescaled again.
assert 'slope: horos_slope == 0 ? 1 : Double(horos_slope), offset: Double(horos_offset))' in pix \
    and 'holdsTableOutput ? 1 : layout.slope' in loader and 'layout.isSigned && !holdsTableOutput' in loader, \
    "the table is entered by the stored value where the object rescales it, or its output is rescaled or read signed"

# The preference ships as on; nothing should quietly disagree with that.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import default_preferences  # noqa: E402
assert default_preferences.registered().get('UseVOILUT') == '1'

source = r'''
import Foundation

func table(_ values: [UInt16]) -> Data {
    var out = Data()
    for value in values { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }
    return out
}

// Sixteen bits per entry, written as OW, which is the common shape.
let ramp = (0..<4096).map { UInt16($0) }
let lut = VOILookupTable(descriptor: [4096, 0, 16] as [NSNumber],
                         data: table(ramp), signed: false)!
precondition(lut.entries == 4096 && lut.depth == 16 && lut.firstMapped == 0)
precondition(lut.smallest == 0 && lut.largest == 4095)
precondition(lut.table.count == 4096 * 4, "\(lut.table.count)")
lut.table.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
    let entries = raw.bindMemory(to: UInt32.self)
    precondition(entries[0] == 0 && entries[1] == 1 && entries[4095] == 4095)
}
// The window that shows the whole of what the table produces.
precondition(lut.windowCenter == 2047.5, "\(lut.windowCenter)")
precondition(lut.windowWidth == 4096, "\(lut.windowWidth)")

// A table that answers the same value for everything: a flat field, on purpose.
let flat = VOILookupTable(descriptor: [4096, 0, 16] as [NSNumber],
                          data: table([UInt16](repeating: 2048, count: 4096)), signed: false)!
precondition(flat.smallest == 2048 && flat.largest == 2048)
precondition(flat.windowWidth == 1, "\(flat.windowWidth)")

// Eight bits per entry written one to a byte, which is what OB gives.
let bytes = VOILookupTable(descriptor: [256, 0, 8] as [NSNumber],
                           data: Data((0..<256).map { UInt8($0) }), signed: false)!
precondition(bytes.entries == 256 && bytes.depth == 8 && bytes.largest == 255)

// Zero entries means 65536: the count is stored in sixteen bits and the largest
// table there is does not fit in them.
let full = VOILookupTable(descriptor: [0, 0, 16] as [NSNumber],
                          data: table([UInt16](repeating: 7, count: 65536)), signed: false)!
precondition(full.entries == 65536)

// The first mapped value is signed when the object's pixels are.
let below = VOILookupTable(descriptor: [16, 64512, 16] as [NSNumber],   // -1024
                           data: table([UInt16](repeating: 1, count: 16)), signed: true)!
precondition(below.firstMapped == -1024, "\(below.firstMapped)")
let above = VOILookupTable(descriptor: [16, 64512, 16] as [NSNumber],
                           data: table([UInt16](repeating: 1, count: 16)), signed: false)!
precondition(above.firstMapped == 64512)

// Values that came back as numbers rather than bytes.
let numbers = VOILookupTable(descriptor: [4, 0, 16] as [NSNumber],
                             data: [1, 2, 3, 4] as [NSNumber], signed: false)!
precondition(numbers.largest == 4)

// And everything that is not a table this can use.
precondition(VOILookupTable(descriptor: nil, data: table(ramp), signed: false) == nil)
precondition(VOILookupTable(descriptor: [4096, 0] as [NSNumber], data: table(ramp), signed: false) == nil)
precondition(VOILookupTable(descriptor: [4096, 0, 16] as [NSNumber], data: nil, signed: false) == nil)
precondition(VOILookupTable(descriptor: [4096, 0, 16] as [NSNumber],
                            data: table([1, 2, 3]), signed: false) == nil,
             "a table shorter than its descriptor says was accepted")
precondition(VOILookupTable(descriptor: [4096, 0, 4] as [NSNumber],
                            data: table(ramp), signed: false) == nil, "four bits per entry")
precondition(VOILookupTable(descriptor: [4096, 0, 32] as [NSNumber],
                            data: table(ramp), signed: false) == nil, "thirty-two bits per entry")
precondition(VOILookupTable(descriptor: [4, 0, 16] as [NSNumber], data: [] as [NSNumber], signed: false) == nil, "no entry")

// A table of one entry answers that entry for every value.
let single = VOILookupTable(descriptor: [1, 300, 16] as [NSNumber], data: table([777]), signed: false)!
precondition(single.entries == 1 && single.firstMapped == 300 && single.smallest == 777 && single.largest == 777)
precondition(single.windowCenter == 777 && single.windowWidth == 1)

// What a frame becomes through a table, from the descriptor to the samples.
func mapped(_ lut: VOILookupTable, _ samples: [UInt16], signed: Bool = false) -> [UInt16] {
    var samples = samples
    lut.table.withUnsafeBytes { raw in
        samples.withUnsafeMutableBufferPointer {
            VOILUTMapping.apply(first: lut.firstMapped, number: lut.entries, table: raw.bindMemory(to: UInt32.self).baseAddress!,
                                to: $0.baseAddress!, count: $0.count, signed: signed)
        }
    }
    return samples
}
precondition(mapped(single, [0, 300, 301, 65535]) == [777, 777, 777, 777])
// Entries 1000, 1010 ... 1030 for the values 100 to 103.
let steps = VOILookupTable(descriptor: [4, 100, 16] as [NSNumber], data: table([1000, 1010, 1020, 1030]), signed: false)!
precondition(mapped(steps, [100, 100, 100]) == [1000, 1000, 1000], "a frame on the first entry")
precondition(mapped(steps, [0, 50, 99]) == [1000, 1000, 1000], "a frame wholly below the table")
precondition(mapped(steps, [104, 4095, 65535]) == [1030, 1030, 1030], "a frame wholly above the table")
precondition(mapped(steps, [99, 100, 101, 102, 103, 104]) == [1000, 1000, 1010, 1020, 1030, 1030])
precondition(mapped(below, [UInt16(bitPattern: -2000), UInt16(bitPattern: -1024), 500], signed: true) == [1, 1, 1])

// A rescale of 2 x - 1024 in the way: the stored values 562, 563 and 564 are 100, 102 and 104.
func rescaled(_ lut: VOILookupTable, _ samples: [UInt16], slope: Double, offset: Double, signed: Bool = false) -> [UInt16] {
    var samples = samples
    lut.table.withUnsafeBytes { raw in
        samples.withUnsafeMutableBufferPointer {
            VOILUTMapping.apply(first: lut.firstMapped, number: lut.entries, table: raw.bindMemory(to: UInt32.self).baseAddress!,
                                to: $0.baseAddress!, count: $0.count, signed: signed, slope: slope, offset: offset)
        }
    }
    return samples
}
precondition(rescaled(steps, [0, 562, 563, 564, 4000], slope: 2, offset: -1024) == [1000, 1000, 1020, 1030, 1030])
// The nearest integer: 100.4 is 100, 101.5 is 102, 102.6 is 103.
precondition(rescaled(steps, [1004, 1015, 1026], slope: 0.1, offset: 0) == [1000, 1020, 1030])

print("PASS: the table is read from bytes or numbers, at eight or sixteen bits, "
      + "with a signed first value, and its own window comes out of it; "
      + "a frame on its first entry or wholly outside it takes its first or last entry")
'''
with tempfile.TemporaryDirectory(prefix='horos-voi-lut-') as tmp:
    p = Path(tmp)
    (p / 'main.swift').write_text(source)
    subprocess.run(['xcrun', 'swiftc', str(root / 'Horos/Sources/VOILookupTable.swift'),
                    str(root / 'Modules/IsiXImaging/Sources/VOILUTMapping.swift'), str(p / 'main.swift'), '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True)
