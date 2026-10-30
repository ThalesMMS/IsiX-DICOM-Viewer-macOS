#!/usr/bin/env python3
"""Check VR measurement labels keep complete digits and units; no VTK rebuild.

The labels come from LengthPresentation.swift with its default preferences:
Automatic unit, three decimal places. The VR's formatting is Swift
(VRView+Measure.swift, an extension of the view): its label function and the
line of -computeLength that makes the label are compiled with
LengthPresentation.swift and run. The 2D labels are checked in a probe of this
checkout's ROI, linked as the application's build compiled it
(tests/roi_harness.py); without a build that part is skipped.
The text actors are the VTK adapter's (IsiXVTKVolumeActors.mm)."""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
import roi_harness  # noqa: E402

measure = (root / 'Horos/Sources/VRView+Measure.swift').read_text()
actors = (root / 'Horos/Sources/Adapters/VTK/IsiXVTKVolumeActors.mm').read_bytes().decode('latin1')
start = actors.index('o->Line2DText = vtkTextActor::New();')
end = actors.index('aRenderer->AddViewProp( o->Line2DActor);', start)
setup = actors[start:end]
if 'SetTextScaleModeToNone()' not in setup:
    raise SystemExit('FAIL: Line2DText must keep SetTextScaleModeToNone so zoom does not scale/clip glyphs')
format_a = measure.index('            let localizedText = vrLengthText(', measure.index('func computeLength()'))
format_b = measure.index('\n', format_a) + 1
vr_format = measure[format_a:format_b]
text_a = measure.index('@MainActor func vrLengthText(_ centimetres: Double) -> String {')
text_b = measure.index('\n}\n', text_a) + 3
vr_text = measure[text_a:text_b].replace('@MainActor ', '')
owner_a = actors.index('    entry->text = vtkTextActor::New();', actors.index('static IsiXVTKStoredLine *IsiXVTKNewStoredLine'))
owner_b = actors.index('    entry->text->GetPositionCoordinate()->SetCoordinateSystemToViewport();', owner_a)
if 'SetTextScaleModeToNone()' not in actors[owner_a:owner_b]:
    raise SystemExit('FAIL: stored VR overlays must copy SetTextScaleModeToNone')
if 'SetInput(sourceText->GetInput())' not in actors[owner_a:owner_b]:
    raise SystemExit('FAIL: stored VR overlays must copy the complete input string')

swift = r'''import Foundation
VR_TEXT
func vrLabel(_ length: Double, _ factor: Float) -> String {
    let horos_factor = factor
VR_FORMAT
    return localizedText
}
UserDefaults.standard.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
func check(_ condition: Bool, _ what: String) { if !condition { print("FAIL: " + what); exit(1) } }
func completeUnit(_ text: String, _ unit: String) -> Bool {
    text.contains("Length:") && text.contains(unit) && text.rangeOfCharacter(from: .decimalDigits) != nil
}
let cm = vrLabel(31, 1)
check(cm == "Length: 3.100 cm ", cm)
check(completeUnit(cm, "cm"), cm)
let small = vrLabel(0.5, 1)
check(small == "Length: 0.500 mm ", small)
check(completeUnit(small, "mm"), small)
check(vrLabel(21.5, 1) == "Length: 2.150 cm ", "native")
check(vrLabel(19.4, 1) == "Length: 1.940 cm ", "zoom")
check(vrLabel(0.05, 1) == "Length: 0.050 mm ", "below 0.1 mm")
print("PASS: VR computeLength labels keep digits and cm/mm units for phantom 3.10/2.15/1.94 cm and 0.50 mm; below 0.1 mm the VR keeps mm, in ASCII")
'''.replace('VR_TEXT', vr_text).replace('VR_FORMAT', vr_format)
with tempfile.TemporaryDirectory(prefix='horos-vr-label-') as directory:
    work = Path(directory)
    (work / 'main.swift').write_text(swift)
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', str(work / 'main.swift'),
                            str(root / 'Horos/Sources/LengthPresentation.swift'), '-o', str(work / 'label')],
                           capture_output=True, text=True)
    if built.returncode:
        raise SystemExit('FAIL: the VR label does not build:\n' + built.stderr[-3000:])
    run = subprocess.run([str(work / 'label')], capture_output=True, text=True)
    sys.stdout.write(run.stdout)
    if run.returncode:
        raise SystemExit(run.returncode)

code = r'''
#define check(...) do{if(!(__VA_ARGS__)){fprintf(stderr, "FAIL: %s\n",#__VA_ARGS__);return 1;}}while(0)
static BOOL completeUnit(NSString *text, NSString *unit) {
 return [text containsString:@"Length:"] && [text containsString:unit]
     && [text rangeOfCharacterFromSet:[NSCharacterSet decimalDigitCharacterSet]].location!=NSNotFound;
}
int main(int argc, const char **argv){@autoreleasepool{
 if( argc > 1 && strcmp( argv[ 1], "--probe-link") == 0) return 0;
 [[NSUserDefaults standardUserDefaults] setVolatileDomain:@{} forName:NSArgumentDomain];
 check([[ROI formattedLength:5.501] isEqualToString:@"5.501 cm"]);
 check([[ROI formattedLength:5.298] hasSuffix:@"cm"]);
 check([[ROI formattedLength:0.05] hasSuffix:@"mm"]);
 NSString *micron=[ROI formattedLength:0.005];
 check([micron hasSuffix:@"m"]);
 check([micron containsString:[NSString stringWithFormat:@"%c",0xb5]]);
 printf("PASS: 2D formattedLength units remain complete; VR text is unscaled\n");
 return 0;
}}
'''

result = roi_harness.run_probe(code)
sys.stdout.write(result.stdout)
sys.stderr.write(result.stderr)
sys.exit(result.returncode)
