#!/usr/bin/env python3
"""Every way the TLS listener's set-up fails closes its port and frees its TLS layer.

-[DCMTKQueryRetrieveSCP run] opens the network - the listening socket - before
it builds the DcmTLSTransportLayer. Most of the TLS set-up's error exits
returned without ASC_dropNetwork() or deleting the layer: with "Activate DICOM
TLS Listener" on and no private key, the Listener preferences said the TLS
settings could not be applied, and the TLS port stayed in LISTEN, accepting
connections nothing answered, until the app quit. Turning TLS on again after
fixing the settings could then run into the app's own port.

The listener's own TLS set-up, cut from DCMTKQueryRetrieveSCP.mm, runs here
against the real DCMTK and OpenSSL archives, after the network has been opened
on a port, once for each way it can fail and once for success:

- a trusted certificate that does not load, a missing private key, a missing
  certificate, a key and a certificate that do not match, a cipher suite that
  is refused, and a transport layer DCMTK does not take: each leaves the port
  closed, no TLS layer alive, an error shown and the listener reported as not
  listening because of its TLS settings;
- with a matching key and certificate, the set-up goes on with the port still
  listening and the layer in place.

The layer's creation returning NULL cannot happen with new; its exit is
checked in the source with the others.
"""
import re
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dcmtk_build import ROOT, BUILD, dcmtk_flags

failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


source = (ROOT / 'Horos/Sources/DCMTKQueryRetrieveSCP.mm').read_bytes().decode('latin1')
start = source.index('\tDcmTLSTransportLayer *tLayer = NULL;')
block = source[start:source.index('\n#endif', start)]
opened = source.rfind('ASC_initializeNetwork(', 0, start)
check(opened > -1, 'the network is no longer opened before the TLS set-up')

# Every exit of the TLS set-up goes through the one clean-up.
body = block[block.index("if([[_params objectForKey:@\"TLSEnabled\"] boolValue])"):]
returns = len(re.findall(r'\breturn\s*;', body))
abandoned = len(re.findall(r'abandonTLS\( [^;]+\);\s*return;', body))
check(returns == abandoned == 7, f'{returns} exits from the TLS set-up, {abandoned} of them after abandonTLS(); expected 7 of 7')
at = block.find('auto abandonTLS')
cleanup = block[at:block.index('};', at)] if at > -1 else ''
check(cleanup, 'the TLS set-up has no single clean-up')
for step in ('ASC_dropNetwork(&options.net_);', 'delete tLayer;', 'tLayer = NULL;',
             'setNotListening: [HorosListenerStatus tlsSettingsReason] TLS: YES', '@selector(displayListenerError:)'):
    check(step in cleanup, f'abandonTLS() no longer does {step}')
check(cleanup.find('ASC_dropNetwork') < cleanup.find('delete tLayer'),
      'the layer is freed before the network that may still point at it')

openssl = BUILD / 'OpenSSL.build/Install'
if not (openssl / 'lib/libssl.a').is_file():
    print('skipped: needs the OpenSSL built by script/build_and_run.sh --verify: ' + str(openssl / 'lib/libssl.a'))
    sys.exit(2)

driver = r'''
#include "dcmtk/config/osconfig.h"
#include "dcmtk/dcmnet/assoc.h"
#include "dcmtk/dcmtls/tlslayer.h"
#include "HorosTLSConfiguration.h"
#import <Foundation/Foundation.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

typedef enum { RequirePeerCertificate = 0, VerifyPeerCertificate, IgnorePeerCertificate } TLSCertificateVerificationType;

static NSString *folder, *keyPath, *certificatePath;
static BOOL badTrustedCertificate, refuseTransportLayer;
static int liveLayers, errorsShown, notListening;
static NSString *notListeningReason;

class CountingLayer : public DcmTLSTransportLayer
{
public:
    CountingLayer(T_ASC_NetworkRole role, const char *seed, OFBool initialise) : DcmTLSTransportLayer(role, seed, initialise) { liveLayers++; }
    ~CountingLayer() { liveLayers--; }
};
#define DcmTLSTransportLayer CountingLayer

static OFCondition RefusingSetTransportLayer(T_ASC_Network *network, DcmTransportLayer *layer, int takeOver)
{
    if (refuseTransportLayer)
        return makeOFCondition(OFM_dcmnet, 999, OF_error, "transport layer refused by the test");
    return ASC_setTransportLayer(network, layer, takeOver);
}
#define ASC_setTransportLayer RefusingSetTransportLayer
static void HorosDumpDIMSECondition(OFCondition) {}

@interface AppController : NSObject
+ (AppController *)sharedAppController;
- (void)displayListenerError:(NSString *)message;
@end
@implementation AppController
+ (AppController *)sharedAppController { static AppController *app; if (!app) app = [AppController new]; return app; }
- (void)displayListenerError:(NSString *)message { errorsShown++; }
@end
@interface HorosListenerStatus : NSObject
+ (NSString *)tlsSettingsReason;
+ (void)setNotListening:(NSString *)reason TLS:(BOOL)tls;
@end
@implementation HorosListenerStatus
+ (NSString *)tlsSettingsReason { return @"its TLS settings could not be applied"; }
+ (void)setNotListening:(NSString *)reason TLS:(BOOL)tls { if (tls) { notListening++; notListeningReason = reason; } }
@end
@interface DICOMTLS : NSObject
@end
@implementation DICOMTLS
+ (const char *)seedFilePath { return NULL; }
+ (NSString *)temporaryFolder { return folder; }
+ (NSString *)TLS_PRIVATE_KEY_PASSWORD { return @""; }
+ (void)generateCertificateAndKeyForLabel:(NSString *)label withStringID:(NSString *)stringID {}
+ (NSString *)keyPathForLabel:(NSString *)label withStringID:(NSString *)stringID { return keyPath; }
+ (NSString *)certificatePathForLabel:(NSString *)label withStringID:(NSString *)stringID { return certificatePath; }
@end
#define TLS_TRUSTED_CERTIFICATES_DIR [[DICOMTLS temporaryFolder] stringByAppendingPathComponent: @"TLSTrustedCert"]
#define TLS_KEYCHAIN_IDENTITY_NAME_SERVER @"com.osirixviewer.dicomtlsserver"
@interface DDKeychain : NSObject
@end
@implementation DDKeychain
+ (void)KeychainAccessExportTrustedCertificatesToDirectory:(NSString *)directory
{
    [NSFileManager.defaultManager createDirectoryAtPath: directory withIntermediateDirectories: YES attributes: nil error: NULL];
    if (badTrustedCertificate)
        [@"not a certificate" writeToFile: [directory stringByAppendingPathComponent: @"bad.pem"] atomically: NO encoding: NSUTF8StringEncoding error: NULL];
}
@end
@interface HorosTLSVerificationPolicy : NSObject
@end
@implementation HorosTLSVerificationPolicy
+ (int)normalise:(int)stored { return stored; }
@end

struct Options { T_ASC_Network *net_; };

static bool reachedEnd;

static void setUp(Options &options, NSDictionary *_params)
{
    OFCondition cond;
''' + block + r'''
    reachedEnd = true;
    if (tLayer) { ASC_dropNetwork(&options.net_); delete tLayer; }
}

static bool listening(int port)
{
    int s = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in address = {};
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    bool connected = connect(s, (struct sockaddr *)&address, sizeof address) == 0;
    close(s);
    return connected;
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        NSString *kase = @(argv[1]);
        int port = atoi(argv[2]);
        folder = @(argv[3]);
        NSString *pair = [kase isEqualToString: @"mismatch"] ? @"other" : @"server";
        keyPath = [folder stringByAppendingPathComponent: [kase isEqualToString: @"no-key"] ? @"missing.key" : @"server.key"];
        certificatePath = [folder stringByAppendingPathComponent: [kase isEqualToString: @"no-certificate"] ? @"missing.pem" : [pair stringByAppendingString: @".pem"]];
        badTrustedCertificate = [kase isEqualToString: @"trusted-certificate"];
        refuseTransportLayer = [kase isEqualToString: @"transport-layer"];
        NSArray *suites = [kase isEqualToString: @"cipher-suites"] ? @[@{@"Supported": @YES, @"Cipher": @"NOT-A-CIPHER-SUITE"}] : @[];
        [NSUserDefaults.standardUserDefaults registerDefaults: @{
            @"TLSStoreSCPCertificateVerification": @(badTrustedCertificate ? VerifyPeerCertificate : IgnorePeerCertificate),
            @"TLSStoreSCPCipherSuites": suites}];

        Options options = {};
        OFCondition opened = ASC_initializeNetwork(NET_ACCEPTORREQUESTOR, port, 30, &options.net_);
        if (opened.bad()) { printf("BIND %s\n", opened.text()); return 3; }
        bool before = listening(port);
        setUp(options, @{@"TLSEnabled": @YES});
        bool reached = reachedEnd;
        bool after = reached ? true : listening(port);
        // The error is shown on the main thread, which is this one: let it arrive.
        [NSRunLoop.currentRunLoop runUntilDate: [NSDate dateWithTimeIntervalSinceNow: 0.1]];
        printf("%s\treached=%d listeningBefore=%d listeningAfter=%d layers=%d errors=%d notListening=%d tlsReason=%d network=%d\n",
               kase.UTF8String, reached, before, after, liveLayers, errorsShown, notListening,
               [notListeningReason isEqualToString: [HorosListenerStatus tlsSettingsReason]], options.net_ != NULL);
    }
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix='horos-tls-port-') as directory:
    p = Path(directory)
    (p / 'main.mm').write_text(driver)
    built = subprocess.run(['xcrun', 'clang++', '-std=c++17', '-fobjc-arc', '-w', '-I' + str(openssl / 'include'), str(p / 'main.mm'),
                            *dcmtk_flags('dcmtls', 'dcmnet'), str(openssl / 'lib/libssl.a'), str(openssl / 'lib/libcrypto.a'),
                            '-framework', 'Foundation', '-framework', 'Security', '-o', str(p / 'driver')],
                           capture_output=True, text=True)
    check(built.returncode == 0, 'the TLS set-up does not compile on its own\n' + built.stderr[-4000:])
    if built.returncode == 0:
        executable = str(openssl / 'bin/openssl') if (openssl / 'bin/openssl').exists() else 'openssl'
        (p / 'openssl.cnf').write_text('[req]\ndistinguished_name=dn\nx509_extensions=ext\n[dn]\n[ext]\nbasicConstraints=critical,CA:TRUE\n')
        for name in ('server', 'other'):
            subprocess.run([executable, 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-sha256', '-days', '1',
                            '-subj', '/CN=Horos synthetic TLS ' + name, '-config', str(p / 'openssl.cnf'),
                            '-keyout', str(p / (name + '.key')), '-out', str(p / (name + '.pem'))], check=True, capture_output=True)
        for kase in ('trusted-certificate', 'no-key', 'no-certificate', 'mismatch', 'cipher-suites', 'transport-layer', 'success'):
            for attempt in range(5):
                with socket.socket() as probe:
                    probe.bind(('127.0.0.1', 0))
                    port = probe.getsockname()[1]
                run = subprocess.run([str(p / 'driver'), kase, str(port), str(p)], capture_output=True, text=True, timeout=60)
                if run.returncode != 3:
                    break
            line = next((l for l in run.stdout.splitlines() if l.startswith(kase + '\t')), None)
            if run.returncode != 0 or line is None:
                failures.append(f'{kase}: the driver stopped (exit {run.returncode}): {run.stdout[-500:]} {run.stderr[-1500:]}')
                continue
            result = dict(item.split('=', 1) for item in line.split('\t', 1)[1].split(' '))
            check(result['listeningBefore'] == '1', f'{kase}: the port was not listening before the TLS set-up')
            if kase == 'success':
                check(result['reached'] == '1' and result['errors'] == '0' and result['notListening'] == '0',
                      f'success: the TLS set-up did not go through: {line}')
            else:
                check(result['reached'] == '0', f'{kase}: the TLS set-up went through')
                check(result['listeningAfter'] == '0', f'{kase}: the TLS port is still listening after the set-up failed')
                check(result['network'] == '0', f'{kase}: the network was not dropped')
                check(result['layers'] == '0', f'{kase}: the TLS layer was not freed ({result["layers"]} alive)')
                check(result['errors'] == '1', f'{kase}: {result["errors"]} errors shown, not 1')
                check(result['notListening'] == '1' and result['tlsReason'] == '1',
                      f'{kase}: the listener was not reported as not listening because of its TLS settings: {line}')

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('PASS: each failure of the TLS set-up closes the port and frees the layer; success keeps both')
