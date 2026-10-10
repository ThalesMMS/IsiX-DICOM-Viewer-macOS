#!/usr/bin/env python3
"""The listener reads its DCMTK configuration whatever its AE title and folders hold.

DCMTK's Q/R configuration parser ends a value at a space, '=' or ',', and a
quoted one at any quote or parenthesis. When the listener wrote the user's AE
title and the database's INCOMING folder into that file, an AE title with a
space, or a database in a folder such as "Data (2)" or "Joe's Files", made it
fail with "Unable to read DICOM listener configuration." at every launch.

The listener's own configuration code, from DCMTKQueryRetrieveSCP.mm and
HorosQueryRetrieveServer.mm, runs here against the real DCMTK archives, with
the database's INCOMING folder set to such paths:

- each valid AE title (with a space, quote, apostrophe, parenthesis, '=',
  ',', '#' or '/', of 16 characters, padded with spaces) gives a configuration
  DCMTK reads, with no error and no file left in the temporary folder;
- the association check accepts that AE title as the peer sends it (without
  the padding, or padded) and refuses another title, a prefix, a different
  case or an empty one; storage is writable;
- an empty or blank AE title, or one of 17 characters, is refused with a
  message that says where to set it and how to turn the listener off.
"""
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dcmtk_build import ROOT, dcmtk_flags


def between(text, start, end, include_end=False):
    a = text.index(start)
    b = text.index(end, a + len(start))
    return text[a:b + (len(end) if include_end else 0)]


server = (ROOT / 'Horos/Sources/HorosQueryRetrieveServer.mm').read_bytes().decode('latin1')
scp = (ROOT / 'Horos/Sources/DCMTKQueryRetrieveSCP.mm').read_bytes().decode('latin1')

functions = between(server, 'const char* const HorosListenerConfigurationAETitle',
                    '\n}\n', include_end=True)
functions += between(server, 'bool HorosListenerAETitleMatches(', '\n}\n', include_end=True)
check = between(server, '    OFBool checkCalledAETitleAccepted(const OFString& calledAE) override',
                '\n    }\n', include_end=True).replace(' override', '')
configure = between(scp, '\tNSString *aeTitle = [_aeTitle', 'DcmAssociationConfiguration asccfg;')
assert configure.count('\tDcmQueryRetrieveConfig config;\n') == 1 and 'return;' in configure
configure = configure.replace('\tDcmQueryRetrieveConfig config;\n', '').replace('return;', 'return false;')

# The old listener read the database's INCOMING folder here; the stub hands it
# the hostile path, so that reading it again would show up below.
code = r'''
#include <dcmtk/config/osconfig.h>
#include <dcmtk/dcmqrdb/dcmqrcnf.h>
#include <dcmtk/dcmqrdb/dcmqropt.h>
#include <dcmtk/dcmnet/assoc.h>
#import <Foundation/Foundation.h>
#include <cstdio>
#include <cstdlib>

static NSString *reported = nil;
static NSString *incoming = nil;
static NSString *testTemporaryDirectory = nil;
#define NSTemporaryDirectory() testTemporaryDirectory
@interface AppController : NSObject
+ (id)sharedAppController;
- (void)displayListenerError:(NSString *)message;
@end
@implementation AppController
+ (id)sharedAppController { static id app = [self new]; return app; }
- (void)displayListenerError:(NSString *)message { reported = [message copy]; }
- (void)performSelectorOnMainThread:(SEL)selector withObject:(id)value waitUntilDone:(BOOL)wait { reported = [value copy]; }
@end
@interface DicomDatabase : NSObject
+ (id)activeLocalDatabase;
- (NSString *)incomingDirPath;
@end
@implementation DicomDatabase
+ (id)activeLocalDatabase { static id database = [self new]; return database; }
- (NSString *)incomingDirPath { return incoming; }
@end

FUNCTIONS

struct Parameters { struct { char callingAPTitle[65]; char callingPresentationAddress[65]; } DULparams; };
struct T_ASC_Association_ { Parameters *params; };
struct Association {
    T_ASC_Association_ *association_;
    const DcmQueryRetrieveConfig &config_;
    const OFString aeTitle_;
CHECK
};

#ifdef WITH_OPENSSL
struct FakeTransportLayer {};
#endif

// What -[DCMTKQueryRetrieveSCP run] does between initializing the network and
// configuring the association profile. Returns whether it went on.
static bool configure(NSString *_aeTitle, int _port, DcmQueryRetrieveOptions &options,
                      DcmQueryRetrieveConfig &config, NSString **trimmed)
{
#ifdef WITH_OPENSSL
    FakeTransportLayer *tLayer = NULL;
#endif
    reported = nil;
    CONFIGURE
    *trimmed = aeTitle;
    return true;
}

static int failures = 0;
#define EXPECT(condition, ...) do { if (!(condition)) { failures++; fprintf(stderr, "FAIL: " __VA_ARGS__); fputc('\n', stderr); } } while (0)

static NSUInteger leftovers(void)
{
    NSUInteger count = 0;
    for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:NSTemporaryDirectory() error:NULL])
        if ([name hasPrefix:@"Horos-dcmqrscp-"]) count++;
    return count;
}

static bool accepts(const DcmQueryRetrieveConfig &config, NSString *configured, const char *called)
{
    Parameters parameters = {};
    strcpy(parameters.DULparams.callingAPTitle, "PEER");
    strcpy(parameters.DULparams.callingPresentationAddress, "127.0.0.1");
    T_ASC_Association_ association = {&parameters};
    Association worker = {&association, config, OFString(configured.UTF8String)};
    return worker.checkCalledAETitleAccepted(OFString(called));
}

int main(int argc, char **argv) { @autoreleasepool {
    testTemporaryDirectory = [NSString stringWithUTF8String:argv[2]];
    NSArray *folders = [[NSString stringWithUTF8String:argv[1]] componentsSeparatedByString:@"\n"];
    NSString *temporary = NSTemporaryDirectory();
    for (NSString *folder in folders) {
        incoming = folder;
        struct Case { NSString *title; const char *peer; } valid[] = {
            {@"ISIX", "ISIX"}, {@"ISIX VIEWER", "ISIX VIEWER"}, {@"O'BRIEN", "O'BRIEN"},
            {@"ISIX (2)", "ISIX (2)"}, {@"A\"B", "A\"B"}, {@"A=B,C", "A=B,C"}, {@"#COMMENT", "#COMMENT"},
            {@"AETable END", "AETable END"}, {@"ABCDEFGHIJKLMNOP", "ABCDEFGHIJKLMNOP"},
            {@"  PADDED  ", "PADDED"}, {@"WITH/SLASH", "WITH/SLASH"},
        };
        for (const Case &c : valid) {
            DcmQueryRetrieveOptions options;
            DcmQueryRetrieveConfig config;
            NSString *aeTitle = nil;
            const bool ran = configure(c.title, 11112, options, config, &aeTitle);
            EXPECT(ran && reported == nil, "AE [%s], folder [%s]: %s", c.title.UTF8String, folder.UTF8String,
                   reported.UTF8String ?: "stopped");
            if (!ran) continue;
            EXPECT(config.getNetworkTCPPort() == 11112, "AE [%s]: port %d", c.title.UTF8String, config.getNetworkTCPPort());
            EXPECT(config.writableStorageArea(HorosListenerConfigurationAETitle), "AE [%s]: storage is not writable", c.title.UTF8String);
            EXPECT(accepts(config, aeTitle, c.peer), "AE [%s] refuses its own title [%s]", c.title.UTF8String, c.peer);
            NSString *padded = [NSString stringWithFormat:@"  %s  ", c.peer];
            EXPECT(accepts(config, aeTitle, padded.UTF8String), "AE [%s] refuses its padded title", c.title.UTF8String);
            EXPECT(!accepts(config, aeTitle, "OTHER"), "AE [%s] accepts OTHER", c.title.UTF8String);
            EXPECT(!accepts(config, aeTitle, ""), "AE [%s] accepts an empty called title", c.title.UTF8String);
            EXPECT(!accepts(config, aeTitle, HorosListenerConfigurationAETitle) || [aeTitle isEqualToString:@(HorosListenerConfigurationAETitle)],
                   "AE [%s] accepts the configuration's own name", c.title.UTF8String);
            NSString *prefix = [aeTitle substringToIndex:aeTitle.length - 1];
            EXPECT(prefix.length == 0 || !accepts(config, aeTitle, prefix.UTF8String), "AE [%s] accepts its prefix", c.title.UTF8String);
            NSString *lower = aeTitle.lowercaseString;
            EXPECT([lower isEqualToString:aeTitle] || !accepts(config, aeTitle, lower.UTF8String), "AE [%s] ignores case", c.title.UTF8String);
        }
        for (NSString *title in @[@"", @"   ", @"ABCDEFGHIJKLMNOPQ"]) {
            DcmQueryRetrieveOptions options;
            DcmQueryRetrieveConfig config;
            NSString *aeTitle = nil;
            const bool ran = configure(title, 11112, options, config, &aeTitle);
            EXPECT(!ran, "AE [%s] was accepted", title.UTF8String);
            EXPECT([reported containsString:@"Preferences > Listener"] && [reported containsString:@"turn it off"],
                   "AE [%s]: the message does not say where to set it or turn the listener off: %s",
                   title.UTF8String, reported.UTF8String);
            EXPECT(![reported containsString:@"Unable to read"], "AE [%s]: the generic message", title.UTF8String);
        }
    }
    EXPECT(leftovers() == 0, "%lu configuration files left in %s", (unsigned long)leftovers(), temporary.UTF8String);
    if (failures) return 1;
    printf("PASS: %lu folders x 11 AE titles read by DCMTK in %s; own title accepted, others refused; "
           "empty and long titles refused with directions\n", (unsigned long)folders.count, temporary.UTF8String);
    return 0;
}}
'''.replace('FUNCTIONS', functions).replace('CHECK', check).replace('CONFIGURE', configure)

flags = dcmtk_flags('dcmqrdb', 'dcmnet', 'dcmtls')
with tempfile.TemporaryDirectory(prefix='horos-listener-configuration-') as folder:
    folder = Path(folder)
    source = folder / 'test.mm'
    source.write_text(code)
    binary = folder / 'test'
    subprocess.run(['xcrun', 'clang++', '-std=c++17', '-fobjc-arc', '-w', '-framework', 'Foundation',
                    '-framework', 'Security', str(source), '-o', str(binary), *flags], check=True)
    hostile = ["Data (2)", "Joe's Files", 'Quote " here', 'A=B, C', 'Café Ünïcode',
               'Café decomposed', 'x' * 200]
    incoming = [str(folder / 'db' / name / 'IsiX Data' / 'INCOMING.noindex') for name in hostile]
    incoming.append(str(folder / 'db' / ('long-' + 'y' * 200) / ('z' * 200) / 'INCOMING.noindex'))
    incoming.append('(null)')
    configuration_directory = folder / 'configurations'
    configuration_directory.mkdir()
    result = subprocess.run([str(binary), '\n'.join(incoming), str(configuration_directory)], text=True, capture_output=True)
    sys.stdout.write(result.stdout)
    sys.stderr.write(result.stderr)
    if result.returncode:
        raise SystemExit(1)
