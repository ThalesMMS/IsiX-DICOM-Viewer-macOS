#!/usr/bin/env python3
"""Exercise the production session outcome registry without loading user plugins."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parent.parent
program = r'''
#import "HorosPluginLoadDiagnostics.h"
int main() { @autoreleasepool {
 NSString *first = @"/one/Synthetic.horosplugin", *other = @"/two/Synthetic.horosplugin";
 NSCAssert([HorosPluginLoadOutcome(first, YES)[@"loadState"] isEqual:@"Not loaded"], @"Installed is not loaded");
 HorosRecordPluginLoad(first, @"Loaded", @"Registered");
 HorosRecordPluginLoad(other, @"Incompatible", @"Wrong architecture");
 NSCAssert([HorosPluginLoadOutcome(first, YES)[@"loadState"] isEqual:@"Loaded"], @"Separate bundle paths");
 NSCAssert([HorosPluginLoadOutcome(other, YES)[@"loadReason"] isEqual:@"Wrong architecture"], @"Preserve reason");
 NSCAssert([HorosPluginLoadOutcome(first, NO)[@"loadState"] isEqual:@"Installed"], @"Disabled takes precedence");
 NSCAssert([HorosPluginLoadOutcome(first, NO)[@"loadReason"] containsString:@"restart"], @"Explain resident code");
 HorosRecordPluginLoad(first, @"Load failed", @"Initialization exception");
 NSCAssert([HorosPluginLoadOutcome(first, YES)[@"loadState"] isEqual:@"Load failed"], @"Failure replaces previous outcome");
 NSString *nfc = @"/unicode/QAHorosLifetime-\u00e9% & +.horosplugin";
 NSString *nfd = @"/unicode/QAHorosLifetime-e\u0301% & +.horosplugin";
 NSString *differentDirectory = @"/elsewhere/QAHorosLifetime-e\u0301% & +.horosplugin";
 NSString *differentCase = @"/unicode/qahoroslifetime-e\u0301% & +.horosplugin";
 HorosRecordPluginLoad(nfc, @"Incompatible", @"The principal class is missing");
 NSDictionary *composed = HorosPluginLoadOutcome(nfc, YES);
 NSDictionary *decomposed = HorosPluginLoadOutcome(nfd, YES);
 if (![composed isEqual:decomposed]) {
     fputs("FAIL: equivalent NFC/NFD path lost the recorded load state or reason\n", stderr);
     return 23;
 }
 NSCAssert([decomposed[@"loadState"] isEqual:@"Incompatible"], @"Actual loader state survives enumeration");
 NSCAssert([decomposed[@"loadReason"] isEqual:@"The principal class is missing"], @"Actual loader reason survives enumeration");
 NSCAssert([HorosPluginLoadOutcome(differentDirectory, YES)[@"loadState"] isEqual:@"Not loaded"], @"Other directory remains separate");
 NSCAssert([HorosPluginLoadOutcome(differentCase, YES)[@"loadState"] isEqual:@"Not loaded"], @"Other case remains separate");
 HorosRecordPluginLoad(differentDirectory, @"Blocked", @"Separate directory policy");
 HorosRecordPluginLoad(differentCase, @"Load failed", @"Separate case failure");
 HorosRecordPluginLoad(nfd, @"Loaded", @"Registered after restart");
 NSCAssert([HorosPluginLoadOutcome(nfc, YES)[@"loadState"] isEqual:@"Loaded"], @"NFD writes update NFC reads");
 NSCAssert([HorosPluginLoadOutcome(nfc, YES)[@"loadReason"] isEqual:@"Registered after restart"], @"Latest reason preserved across normalization");
 NSCAssert([HorosPluginLoadOutcome(differentDirectory, YES)[@"loadReason"] isEqual:@"Separate directory policy"], @"Other directory not overwritten");
 NSCAssert([HorosPluginLoadOutcome(differentCase, YES)[@"loadReason"] isEqual:@"Separate case failure"], @"Other case not overwritten");
 NSCAssert([HorosPluginLoadOutcome(nfd, NO)[@"loadState"] isEqual:@"Installed"], @"Disabled still takes precedence for Unicode");
 puts("PASS: unknown/disabled/loaded/failed, NFC/NFD state and reason, separate directories and case");
} }
'''
with tempfile.TemporaryDirectory(prefix='horos-plugin-outcomes-') as directory:
    p = Path(directory)
    (p/'test.m').write_text(program)
    subprocess.run(['xcrun', 'clang', '-framework', 'Foundation', '-Wall', '-Wextra', '-Werror', '-fsanitize=address', '-I', str(root/'Horos/Sources'), str(p/'test.m'), '-o', str(p/'test')], check=True)
    subprocess.run([str(p/'test')], check=True)
