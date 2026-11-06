#!/usr/bin/env python3
"""Every way the TLS listener's set-up fails closes its port and frees its TLS layer.

The listener opens the network - the listening socket - before it builds the
TLS layer. Most of the TLS set-up's error exits once returned without dropping
the network or deleting the layer: with "Activate DICOM TLS Listener" on and
no private key, the Listener preferences said the TLS settings could not be
applied, and the TLS port stayed in LISTEN, accepting connections nothing
answered, until the app quit. Turning TLS on again after fixing the settings
could then run into the app's own port.

The listener is Swift (DCMTKQueryRetrieveSCP.swift) and reaches DCMTK through
its adapter's IsiXDCMTKListener, in steps that each fail with an NSError. In
the sources: every way out of the Swift TLS set-up is a failure the listener
answers by showing the error, closing the adapter's listener and reporting it
not listening because of its TLS settings; the adapter's close drops the
network before it deletes the layer.

The adapter itself runs here against the real DCMTK and OpenSSL archives,
after the network has been opened on a port, once for each way the set-up can
fail and once for success:

- a trusted certificate that does not load (named in the error), a missing
  private key, a missing certificate, a key and a certificate that do not
  match, a cipher suite that is refused, and a layer attached before it was
  made: each step fails with an NSError naming it, and closing the listener
  closes the port, which another listener then opens;
- with a matching key and certificate, the set-up goes through with the port
  still listening, until the listener is closed.
"""
import re
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dcmtk_build import ROOT  # noqa: E402
import dcmtk_scp_adapter  # noqa: E402

failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


# --- the sources ----------------------------------------------------------------
listener = (ROOT / 'Horos/Sources/DCMTKQueryRetrieveSCP.swift').read_text()
run = listener[listener.index('    @objc func run() {'):listener.index('    private func setUpTLS(')]
opened, tls = run.find('try listener.openNetwork()'), run.find('if secure, let message = setUpTLS(listener) {')
check(-1 < opened < tls, 'the network is no longer opened before the TLS set-up')
branch = run[tls:run.index('\n        }\n', tls)]
for step in ('Self.displayListenerError(message)', '_ = listener.close()',
             'ListenerStatus.setNotListening(reason: ListenerStatus.tlsSettingsReason, tls: true)', 'return'):
    check(step in branch, f'a TLS set-up that fails no longer does {step}')
setup = listener[listener.index('    private func setUpTLS('):]
setup = setup[:setup.index('\n    }\n')]
# The closure that picks the cipher suites returns its own values.
suites = setup.find('.compactMap { suite -> String? in')
if suites > -1:
    setup = setup[:suites] + setup[setup.index('\n        }\n', suites):]
exits = re.findall(r'\breturn (\S+)', setup)
check(len(exits) == 8 and exits[-1] == 'nil' and all(value.startswith('"') for value in exits[:-1]),
      f'the TLS set-up has {len(exits)} exits; expected 7 failures, each a message, and nil at its end: {exits}')
adapter = (ROOT / 'Horos/Sources/Adapters/DCMTK/IsiXDCMTKQueryRetrieveSCP.mm').read_text()
close = adapter[adapter.index('- (NSError *)close'):]
close = close[:close.index('\n}\n')]
check(-1 < close.find('ASC_dropNetwork(&_network)') < close.find('delete _layer;') < close.find('_layer = NULL;'),
      'the adapter\'s close no longer drops the network, then frees the layer that it may still point at')

DRIVER = r'''
#import <Foundation/Foundation.h>
#import "IsiXDCMTKQueryRetrieveSCP.h"
#import "IsiXDCMTKError.h"
#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>

@interface Host : NSObject <IsiXDCMTKListenerHost>
@end
@implementation Host
- (id<IsiXDCMTKSCPDatabase>)databaseForCallingAETitle:(NSString *)callingAETitle { return nil; }
- (IsiXDCMTKMoveDestination *)moveDestinationForAETitle:(NSString *)aeTitle { return nil; }
- (BOOL)answersCommand:(IsiXDCMTKListenerCommand)command { return YES; }
- (NSUInteger)maximumConcurrentAssociations { return 1; }
- (BOOL)isListenerAETitle:(NSData *)calledAETitle { return YES; }
- (uint16_t)finalStatusOfGet:(uint16_t)proposed completed:(NSUInteger)completed failed:(NSUInteger)failed
                    warnings:(NSUInteger)warnings { return proposed; }
- (void)associationEndedWithError:(NSError *)error message:(NSString *)message {}
- (void)startAssociationThread:(NSThread *)thread peer:(NSString *)peer { [thread start]; }
- (void)association:(NSString *)peer willServe:(IsiXDCMTKListenerCommand)command secure:(BOOL)secure {}
- (void)associationDidEnd {}
@end

static IsiXDCMTKListener *makeListener(int port)
{
    IsiXDCMTKListenerSettings *settings = [IsiXDCMTKListenerSettings new];
    settings.port = port;
    settings.aeTitle = @"TLSSCP";
    settings.timeout = 10;
    settings.connectionTimeout = 5;
    settings.maxAssociations = 1;
    settings.secureConnection = YES;
    return [[IsiXDCMTKListener alloc] initWithSettings:settings host:[Host new]];
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
        NSString *folder = @(argv[3]);
        NSString *pair = [kase isEqualToString:@"mismatch"] ? @"other" : @"server";
        NSString *key = [folder stringByAppendingPathComponent:[kase isEqualToString:@"no-key"] ? @"missing.key" : @"server.key"];
        NSString *certificate = [folder stringByAppendingPathComponent:
            [kase isEqualToString:@"no-certificate"] ? @"missing.pem" : [pair stringByAppendingString:@".pem"]];
        NSString *bad = [folder stringByAppendingPathComponent:@"bad.pem"];
        [@"not a certificate" writeToFile:bad atomically:NO encoding:NSUTF8StringEncoding error:NULL];

        IsiXDCMTKListener *listener = makeListener(port);
        NSError *error = nil;
        if (![listener openNetwork:&error]) { printf("BIND %s\n", error.localizedDescription.UTF8String); return 3; }
        const bool before = listening(port);
        NSString *failed = nil, *file = nil;
        BOOL ok = YES;
        if (![kase isEqualToString:@"transport-layer"]) ok = [listener createTLSLayer:&error];
        if (ok && [kase isEqualToString:@"trusted-certificate"]) ok = [listener addTrustedCertificateFiles:@[bad] error:&error];
        if (ok && ![kase isEqualToString:@"transport-layer"])
            ok = [listener setPrivateKeyFile:key certificateFile:certificate password:@"" error:&error];
        if (ok && ![kase isEqualToString:@"transport-layer"])
            ok = [listener setCipherSuites:[kase isEqualToString:@"cipher-suites"] ? @[@"NOT-A-CIPHER-SUITE"] : @[]
                              verification:2 error:&error];
        if (ok) ok = [listener attachTLSLayer:&error];
        if (!ok) {
            failed = error.userInfo[IsiXDCMTKOperationKey];
            file = error.userInfo[IsiXDCMTKListenerFileKey];
        }
        const bool during = listening(port);
        NSError *closed = [listener close];
        const bool after = listening(port);
        IsiXDCMTKListener *again = makeListener(port);
        const bool reopened = [again openNetwork:NULL] && listening(port);
        [again close];
        printf("%s\tok=%d step=%s file=%s domain=%d listeningBefore=%d listeningDuring=%d closed=%d listeningAfter=%d reopened=%d\n",
               kase.UTF8String, ok, failed.UTF8String ?: "-", file.lastPathComponent.UTF8String ?: "-",
               [error.domain isEqualToString:IsiXDCMTKErrorDomain], before, during, closed == nil, after, reopened);
    }
    return 0;
}
'''

EXPECTED = {
    'trusted-certificate': ('addTrustedCertificateFile', 'bad.pem'),
    'no-key': ('setPrivateKeyFile', 'missing.key'),
    'no-certificate': ('setCertificateFile', 'missing.pem'),
    'mismatch': ('checkPrivateKeyMatchesCertificate', 'other.pem'),
    'cipher-suites': ('HorosConfigureTLSCipherSuites', '-'),
    'transport-layer': ('ASC_setTransportLayer', '-'),
}

if not failures:
    with tempfile.TemporaryDirectory(prefix='horos-tls-port-') as directory:
        p = Path(directory)
        executable = dcmtk_scp_adapter.build(p, DRIVER)
        (p / 'openssl.cnf').write_text('[req]\ndistinguished_name=dn\nx509_extensions=ext\n[dn]\n[ext]\nbasicConstraints=critical,CA:TRUE\n')
        for name in ('server', 'other'):
            subprocess.run([dcmtk_scp_adapter.openssl(), 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-sha256', '-days', '1',
                            '-subj', '/CN=Horos synthetic TLS ' + name, '-config', str(p / 'openssl.cnf'),
                            '-keyout', str(p / (name + '.key')), '-out', str(p / (name + '.pem'))], check=True, capture_output=True)
        for kase in (*EXPECTED, 'success'):
            for attempt in range(5):
                with socket.socket() as probe:
                    probe.bind(('127.0.0.1', 0))
                    port = probe.getsockname()[1]
                run = subprocess.run([str(executable), kase, str(port), str(p)], capture_output=True, text=True, timeout=60)
                if run.returncode != 3:
                    break
            line = next((l for l in run.stdout.splitlines() if l.startswith(kase + '\t')), None)
            if run.returncode != 0 or line is None:
                failures.append(f'{kase}: the driver stopped (exit {run.returncode}): {run.stdout[-500:]} {run.stderr[-1500:]}')
                continue
            result = dict(item.split('=', 1) for item in line.split('\t', 1)[1].split(' '))
            check(result['listeningBefore'] == '1', f'{kase}: the port was not listening before the TLS set-up')
            check(result['closed'] == '1' and result['listeningAfter'] == '0', f'{kase}: closing the listener did not close its port: {line}')
            check(result['reopened'] == '1', f'{kase}: another listener could not open the port again: {line}')
            if kase == 'success':
                check(result['ok'] == '1' and result['listeningDuring'] == '1', f'success: the TLS set-up did not go through: {line}')
            else:
                step, file = EXPECTED[kase]
                check(result['ok'] == '0' and result['domain'] == '1', f'{kase}: the TLS set-up went through: {line}')
                check(result['step'] == step and result['file'] == file, f'{kase}: the error names {result["step"]}, {result["file"]}; '
                      f'expected {step}, {file}')
            print(line)

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('PASS: each failure of the TLS set-up is an NSError naming its step, and closing the listener frees the port; success keeps it')
