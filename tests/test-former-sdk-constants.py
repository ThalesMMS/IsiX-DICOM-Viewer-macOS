#!/usr/bin/env python3
"""The constants, globals and vector functions of the Horos and OsiriX plugin
SDK have the values that SDK gave them.

A plugin built for that SDK is not rebuilt: it looks these names up in the
application and reads what is there. They are defined once, with C names, in
Horos/Sources/FormerPluginSDK+CAPI.m, Nitrogen/Sources/Nitrogen+CAPI.m and
Horos/Sources/altivecFunctions.c, because a Swift constant has no C symbol;
tests/test-legacy-plugin-abi.py checks that the built application exports the
names, and this test what they hold.

The three files are compiled alone, as the application compiles them, with the
branch of their headers that does not need the generated Swift interface
(HOROS_BRIDGING_HEADER), and linked with a program that prints each name and
its value through the declaration of its header (or its own, for the names
whose headers the application no longer has). The four N3BezierCore functions
the Bezier callbacks call are stand-ins that say they were called. The output
is compared with the table below, which has the values of Horos (and of the
OsiriX SDK for the names only it had).

As a negative control the same is done on copies of the files with one string,
one number and one vector operation changed: each must be reported.

Exit status 2 without the compiler.
"""
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ('Horos/Sources/FormerPluginSDK+CAPI.m', 'Nitrogen/Sources/Nitrogen+CAPI.m', 'Horos/Sources/altivecFunctions.c')
FLAGS = ['-target', 'arm64-apple-macos15.0', '-fno-objc-arc', '-DHOROS_BRIDGING_HEADER',
         '-I', str(ROOT / 'Nitrogen/Sources'), '-I', str(ROOT / 'Horos/Sources')]

STRINGS = {
    'OsirixErrorDomain': 'OsiriXDomain',
    'OSIROIManagerROIsDidUpdateNotification': 'OSIROIManagerROIsDidUpdateNotification',
    'OSIROIUpdatedROIKey': 'OSIROIUpdatedROIKey', 'OSIROIRemovedROIKey': 'OSIROIRemovedROIKey',
    'OSIROIAddedROIKey': 'OSIROIAddedROIKey',
    'WebPortalDatabaseUserEntityName': 'User', 'WebPortalDatabaseStudyEntityName': 'Study',
    'SessionCookieName': 'OSID', 'SessionUserIDKey': 'UserID', 'SessionUsernameKey': 'Username',
    'SessionTokensDictKey': 'Tokens', 'SessionChallengeKey': 'Challenge', 'SessionLastActivityDateKey': 'LastActivityDate',
    'N2StepDidBecomeActiveNotification': 'N2StepDidBecomeActiveNotification',
    'N2StepDidBecomeInactiveNotification': 'N2StepDidBecomeInactiveNotification',
    'N2StepDidBecomeEnabledNotification': 'N2StepDidBecomeEnabledNotification',
    'N2StepDidBecomeDisabledNotification': 'N2StepDidBecomeDisabledNotification',
    'N2StepTitleDidChangeNotification': 'N2StepTitleDidChangeNotification',
    'N2StepsDidAddStepNotification': 'N2StepsDidAddStepNotification',
    'N2StepsWillRemoveStepNotification': 'N2StepsWillRemoveStepNotification',
    'N2StepsNotificationStep': 'N2StepsNotificationStep',
    'N2ViewBoundsSizeDidChangeNotification': 'N2ViewBoundsSizeDidChangeNotification',
    'N2ViewBoundsSizeDidChangeNotificationOldBoundsSize': 'oldBoundsSize',
    'N2DisclosureBoxDidToggleNotification': 'N2DisclosureBoxDidToggleNotification',
    'N2DisclosureBoxWillExpandNotification': 'N2DisclosureBoxWillExpandNotification',
    'N2DisclosureBoxDidExpandNotification': 'N2DisclosureBoxDidExpandNotification',
    'N2DisclosureBoxDidCollapseNotification': 'N2DisclosureBoxDidCollapseNotification',
    'N2ConnectionStatusDidChangeNotification': 'N2ConnectionStatusDidChangeNotification',
    'N2ConnectionListenerOpenedConnectionNotification': 'N2ConnectionListenerOpenedConnectionNotification',
    'N2ConnectionListenerOpenedConnection': 'N2ConnectionListenerOpenedConnection',
    'N2ErrorDomain': 'N2', 'N2VirtualMethodException': 'N2VirtualMethodException',
    'N2LinesDontInterceptException': 'N2LinesDontInterceptException',
    'NSThreadNameKey': 'name', 'NSThreadUniqueIdKey': 'uniqueId', 'NSThreadIsCancelledKey': 'isCancelled',
    'NSThreadSupportsCancelKey': 'supportsCancel', 'NSThreadSupportsBackgroundingKey': 'supportsBackgrounding',
    'NSThreadStatusKey': 'status', 'NSThreadProgressKey': 'progress', 'NSThreadProgressDetailsKey': 'progressDetails',
    'NSThreadSubthreadsAwareProgressKey': 'subthreadsAwareProgress',
    'SMTPServerAddressKey': 'SMTPServerAddress', 'SMTPServerPortsKey': 'SMTPServerPorts',
    'SMTPServerTLSModeKey': 'SMTPServerTLSMode', 'SMTPFromKey': 'SMTPFrom', 'SMTPServerAuthFlagKey': 'SMTPServerAuthFlag',
    'SMTPServerAuthUsernameKey': 'SMTPServerAuthUsername', 'SMTPServerAuthPasswordKey': 'SMTPServerAuthPassword',
    'SMTPToKey': 'SMTPTo', 'SMTPHeadersKey': 'SMTPHeaders', 'SMTPSubjectKey': 'SMTPSubject', 'SMTPMessageKey': 'SMTPMessage',
    'SBJSONErrorDomain': 'org.brautaset.JSON.ErrorDomain',
}
# Printed with %g, the components of a struct joined by commas.
NUMBERS = {
    'CPRCurvedPathControlTokenNone': '-1',
    'N3VectorZero': '0,0,0', 'N3AffineTransformIdentity': '1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1',
    'N3LineXAxis': '0,0,0,1,0,0', 'N3LineYAxis': '0,0,0,0,1,0', 'N3LineZAxis': '0,0,0,0,0,1', 'N3LineInvalid': '0,0,0,0,0,0',
    'N3PlaneXZero': '0,0,0,1,0,0', 'N3PlaneYZero': '0,0,0,0,1,0', 'N3PlaneZZero': '0,0,0,0,0,1', 'N3PlaneInvalid': '0,0,0,0,0,0',
    'N3BezierDefaultFlatness': '0.1', 'N3BezierDefaultSubdivideSegmentLength': '3',
    'N2Top': '1', 'N2Bottom': '2', 'N2Left': '4', 'N2Right': '8',
    'N2NoMin': 'CGFLOAT_MIN', 'N2NoMax': 'CGFLOAT_MAX',
    'ISO8601DefaultTimeSeparatorCharacter': '58', 'gNSStringGeometricsTypesetterBehavior': '-1', 'Altivec': '0',
    'kdu_available': '0', 'kdu_decompressJPEG2K': 'NULL,0', 'kdu_decompressJPEG2KWithBuffer': 'NULL,0',
    'kdu_compressJPEG2K': 'NULL,0',
    'kN3BezierCoreArrayCallBacks': '0,retain,release,describe,equal',
    'kN3BezierCoreDictionaryValueCallBacks': '0,retain,release,describe,equal',
    # Two vectors of sixteen bytes (size 8 is two of them), a = 0...31 and b = 31...0.
    'vmax8ARM': '31,30,29,28,27,26,25,24,23,22,21,20,19,18,17,16,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31',
    'vmin8ARM': '0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,15,14,13,12,11,10,9,8,7,6,5,4,3,2,1,0',
    'vmax8Intel': '31,30,29,28,27,26,25,24,23,22,21,20,19,18,17,16,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31',
    'vmin8Intel': '0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,15,14,13,12,11,10,9,8,7,6,5,4,3,2,1,0',
    # Two vectors of four floats, a = 0, 1.5, ... and b = 10.5, 9, ...
    'vmaxIntel': '10.5,9,7.5,6,6,7.5,9,10.5', 'vminIntel': '0,1.5,3,4.5,4.5,3,1.5,0',
    # Eight floats, one at a time.
    'vmultiplyNoAltivec': '0,13.5,22.5,27,27,22.5,13.5,0', 'vsubtractNoAltivec': '-10.5,-7.5,-4.5,-1.5,1.5,4.5,7.5,10.5',
    'vsubtractNoAltivecAbs': '10.5,7.5,4.5,1.5,1.5,4.5,7.5,10.5',
    'vmaxNoAltivec': '10.5,9,7.5,6,6,7.5,9,10.5', 'vminNoAltivec': '0,1.5,3,4.5,4.5,3,1.5,0',
}

MAIN = r'''
#import <Cocoa/Cocoa.h>
#import "NSError+OsiriX.h"
#import "OSIROIManager.h"
#import "CPRCurvedPath.h"
#import "WebPortalDatabase.h"
#import "WebPortalSession.h"
#import "N3Geometry.h"
#import "N3BezierCore.h"
#import "N2Alignment.h"
#import "N2MinMax.h"
#import "N2Operators.h"
#import "N2Step.h"
#import "N2Steps.h"
#import "N2View.h"
#import "N2DisclosureBox.h"
#import "N2Exceptions.h"
#import "NSException+N2.h"
#import "NSThread+N2.h"
#import "SMTPClient.h"
#import "NS(Attributed)String+Geometrics.h"
#import "altivecFunctions.h"

// The names whose headers the application no longer has.
extern NSString *N2ConnectionStatusDidChangeNotification, *N2ConnectionListenerOpenedConnectionNotification;
extern NSString *N2ConnectionListenerOpenedConnection, *SBJSONErrorDomain;
extern unichar ISO8601DefaultTimeSeparatorCharacter;
int kdu_available(void);
void *kdu_decompressJPEG2K(void *, long, long *, int *, int);
void *kdu_decompressJPEG2KWithBuffer(void *, void *, long, long *, int *, int);
void *kdu_compressJPEG2K(void *, int, int, int, int, bool, int, long *, int);

// Stand-ins for what the Bezier callbacks call: each says it was called.
static NSMutableString *called;
void *N3BezierCoreRetain(N3BezierCoreRef bezierCore) { [called appendString:@",retain"]; return (void *)bezierCore; }
void N3BezierCoreRelease(N3BezierCoreRef bezierCore) { [called appendString:@",release"]; }
CFStringRef N3BezierCoreCopyDescription(N3BezierCoreRef bezierCore) { [called appendString:@",describe"]; return CFSTR(""); }
bool N3BezierCoreEqualToBezierCore(N3BezierCoreRef bezierCore1, N3BezierCoreRef bezierCore2) { [called appendString:@",equal"]; return true; }

static void floats(const char *name, const void *values, int count, BOOL single) {
    printf("%s=", name);
    for (int i = 0; i < count; i++) printf("%s%g", i ? "," : "", single ? ((const float *)values)[i] : ((const CGFloat *)values)[i]);
    printf("\n");
}

static void limit(const char *name, CGFloat value) {
    if (value == CGFLOAT_MIN) printf("%s=CGFLOAT_MIN\n", name);
    else if (value == CGFLOAT_MAX) printf("%s=CGFLOAT_MAX\n", name);
    else printf("%s=%g\n", name, value);
}

static void bytes(const char *name, void (*function)(vUInt8 *, vUInt8 *, vUInt8 *, long)) {
    unsigned char a[32], b[32], r[32];
    for (int i = 0; i < 32; i++) { a[i] = i; b[i] = 31 - i; r[i] = 99; }
    function((vUInt8 *)a, (vUInt8 *)b, (vUInt8 *)r, 8);
    printf("%s=", name);
    for (int i = 0; i < 32; i++) printf("%s%d", i ? "," : "", r[i]);
    printf("\n");
}

static void singles(const char *name, void (*function)(float *, float *, float *, long)) {
    float a[8], b[8], r[8];
    for (int i = 0; i < 8; i++) { a[i] = 1.5f * i; b[i] = 1.5f * (7 - i); r[i] = 99; }
    function(a, b, r, 8);
    floats(name, r, 8, YES);
}

static void vectors(const char *name, void (*function)(vFloat *, vFloat *, vFloat *, long)) {
    singles(name, (void (*)(float *, float *, float *, long))function);
}

#define STRING(name) printf("%s=%s\n", #name, [(NSString *)name UTF8String]);
#define CALLBACKS(name) called = [NSMutableString string]; \
    name.retain(NULL, NULL); name.release(NULL, NULL); CFRelease(name.copyDescription(NULL)); name.equal(NULL, NULL); \
    printf("%s=%ld%s\n", #name, (long)name.version, called.UTF8String);

int main(void) {
    @autoreleasepool {
@STRINGS@
        printf("CPRCurvedPathControlTokenNone=%d\n", CPRCurvedPathControlTokenNone);
        floats("N3VectorZero", &N3VectorZero, 3, NO);
        floats("N3AffineTransformIdentity", &N3AffineTransformIdentity, 16, NO);
        floats("N3LineXAxis", &N3LineXAxis, 6, NO); floats("N3LineYAxis", &N3LineYAxis, 6, NO);
        floats("N3LineZAxis", &N3LineZAxis, 6, NO); floats("N3LineInvalid", &N3LineInvalid, 6, NO);
        floats("N3PlaneXZero", &N3PlaneXZero, 6, NO); floats("N3PlaneYZero", &N3PlaneYZero, 6, NO);
        floats("N3PlaneZZero", &N3PlaneZZero, 6, NO); floats("N3PlaneInvalid", &N3PlaneInvalid, 6, NO);
        floats("N3BezierDefaultFlatness", &N3BezierDefaultFlatness, 1, NO);
        floats("N3BezierDefaultSubdivideSegmentLength", &N3BezierDefaultSubdivideSegmentLength, 1, NO);
        printf("N2Top=%d\nN2Bottom=%d\nN2Left=%d\nN2Right=%d\n", N2Top, N2Bottom, N2Left, N2Right);
        limit("N2NoMin", N2NoMin); limit("N2NoMax", N2NoMax);
        printf("ISO8601DefaultTimeSeparatorCharacter=%d\n", ISO8601DefaultTimeSeparatorCharacter);
        printf("gNSStringGeometricsTypesetterBehavior=%d\n", gNSStringGeometricsTypesetterBehavior);
        printf("Altivec=%d\n", Altivec);
        long size = 7; int model = 0;
        printf("kdu_available=%d\n", kdu_available());
        printf("kdu_decompressJPEG2K=%s,%ld\n", kdu_decompressJPEG2K(&model, 4, &size, &model, 1) ? "a buffer" : "NULL", size);
        size = 7;
        printf("kdu_decompressJPEG2KWithBuffer=%s,%ld\n", kdu_decompressJPEG2KWithBuffer(&model, &model, 4, &size, &model, 1) ? "a buffer" : "NULL", size);
        size = 7;
        printf("kdu_compressJPEG2K=%s,%ld\n", kdu_compressJPEG2K(&model, 1, 1, 1, 8, false, 0, &size, 1) ? "a buffer" : "NULL", size);
        CALLBACKS(kN3BezierCoreArrayCallBacks)
        CALLBACKS(kN3BezierCoreDictionaryValueCallBacks)
        bytes("vmax8ARM", vmax8ARM); bytes("vmin8ARM", vmin8ARM); bytes("vmax8Intel", vmax8Intel); bytes("vmin8Intel", vmin8Intel);
        vectors("vmaxIntel", vmaxIntel); vectors("vminIntel", vminIntel);
        singles("vmultiplyNoAltivec", vmultiplyNoAltivec); singles("vsubtractNoAltivec", vsubtractNoAltivec);
        singles("vsubtractNoAltivecAbs", vsubtractNoAltivecAbs); singles("vmaxNoAltivec", vmaxNoAltivec);
        singles("vminNoAltivec", vminNoAltivec);
    }
    return 0;
}
'''.replace('@STRINGS@', '\n'.join(f'        STRING({name})' for name in STRINGS))


def values(folder, sources):
    """{name: value} as the program linked with `sources` prints them."""
    folder.mkdir(parents=True, exist_ok=True)
    main = folder / 'main.m'
    main.write_text(MAIN)
    objects = []
    for source in [main, *sources]:
        obj = folder / (Path(source).name + '.o')
        built = subprocess.run(['xcrun', 'clang', '-c', *FLAGS, '-Wno-deprecated-declarations', str(source), '-o', str(obj)],
                               capture_output=True, text=True)
        if built.returncode:
            raise SystemExit(f'FAIL: {Path(source).name} does not compile alone: ' + built.stderr[-2500:])
        objects.append(str(obj))
    linked = subprocess.run(['xcrun', 'clang', '-target', 'arm64-apple-macos15.0', *objects, '-framework', 'Cocoa',
                             '-framework', 'QuartzCore', '-framework', 'Accelerate', '-o', str(folder / 'values')],
                            capture_output=True, text=True)
    if linked.returncode:
        raise SystemExit('FAIL: the values do not link: ' + linked.stderr[-2500:])
    run = subprocess.run([str(folder / 'values')], capture_output=True, text=True, timeout=60)
    if run.returncode:
        raise SystemExit(f'FAIL: the values program exited {run.returncode}: ' + run.stderr[-1500:])
    return dict(line.split('=', 1) for line in run.stdout.splitlines() if '=' in line)


def differences(found):
    expected = {**STRINGS, **NUMBERS}
    return sorted(f'{name} is {found.get(name)!r}, not {value!r}' for name, value in expected.items()
                  if found.get(name) != value) + sorted(f'{name} is printed and not in the table' for name in set(found) - set(expected))


def main():
    if shutil.which('xcrun') is None:
        print('skipped: needs xcrun (Xcode command line tools)', file=sys.stderr)
        return 2
    sources = [ROOT / source for source in SOURCES]
    with tempfile.TemporaryDirectory(prefix='isix-former-sdk-') as folder:
        folder = Path(folder)
        failures = differences(values(folder / 'real', sources))
        # The control: one string, one number and one vector operation changed.
        changes = (('FormerPluginSDK+CAPI.m', '@"OSID"', '@"OSIDX"', 'SessionCookieName'),
                   ('Nitrogen+CAPI.m', 'N2Bottom = 1<<1', 'N2Bottom = 1<<5', 'N2Bottom'),
                   ('altivecFunctions.c', '{ bytes16(a, b, r, size, 1); }', '{ bytes16(a, b, r, size, 0); }', 'vmax8ARM'))
        altered = []
        for source in sources:
            text = source.read_text(errors='surrogateescape')
            for name, old, new, _ in changes:
                if source.name == name:
                    if old not in text:
                        failures.append(f'the control cannot change {old!r} in {name}: this test needs a new look')
                    text = text.replace(old, new)
            copy = folder / 'altered' / source.name
            copy.parent.mkdir(exist_ok=True)
            copy.write_text(text, errors='surrogateescape')
            altered.append(copy)
        reported = ' '.join(differences(values(folder / 'control', altered)))
        failures += [f'the control changed {name} and the comparison did not report it' for _, _, _, name in changes
                     if not re.search(r'\b%s is ' % name, reported)]
    for failure in failures:
        print('FAIL: ' + failure)
    if failures:
        return 1
    print(f'PASS: {len(STRINGS)} strings and {len(NUMBERS)} numbers, structs, callbacks and vector functions of the former '
          'plugin SDK have its values, and a changed string, number and vector operation are reported')
    return 0


if __name__ == '__main__':
    sys.exit(main())
