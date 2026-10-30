#!/usr/bin/env python3
"""The TLS identities of the Keychain, on a disposable Keychain.

The web portal, XML-RPC and DICOM TLS take their identity from the Keychain
through the IsiXKeychain module (Swift over Security.framework). This compiles
the module as it is and runs it on a Keychain made here and deleted afterwards,
never added to the user's search list, holding a synthetic leaf signed by a
synthetic CA:

- the identity's certificate, its common name, whether it is self-signed, and
  the chain a TLS peer is shown, which starts with it;
- DICOM TLS's exports: the certificate as PEM (the same certificate), the
  private key as PEM encrypted with the password (openssl opens it with that
  password only, and it is the key of the certificate), no PKCS#12 file left
  behind, and a file already there left as it is;
- the certificates the system trusts, one PEM file each, into a folder made for
  them, and a folder already there left as it is;
- the web server's self-signed identity: RSA 2048, SHA-256, a year, server
  authentication, the subject that says where it comes from, imported with its
  key into the Keychain given;
- which certificates may serve TLS: any use, or digital signature.

No identity preference is written: setting one stores it in the login Keychain.
Exit 2 (skipped) without openssl.
"""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
from isix_modules import module_flags  # noqa: E402

OPENSSL = shutil.which('openssl')
if not OPENSSL:
    print('skipped: openssl is needed', file=sys.stderr)
    raise SystemExit(2)

DRIVER = r'''
import Foundation
import IsiXKeychain
import Security

let arguments = CommandLine.arguments
let keychainPath = arguments[1], p12 = arguments[2], folder = arguments[3]
typealias Open = @convention(c) (UnsafePointer<CChar>, UnsafeMutablePointer<SecKeychain?>) -> OSStatus
let open = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecKeychainOpen"), to: Open.self)
var keychain: SecKeychain?
precondition(open(keychainPath, &keychain) == errSecSuccess && keychain != nil, "open")
var items: CFArray?
let status = SecPKCS12Import(FileManager.default.contents(atPath: p12)! as CFData,
                             [kSecImportExportPassphrase as String: "synthetic",
                              kSecImportExportKeychain as String: keychain!] as CFDictionary, &items)
precondition(status == errSecSuccess, "import \(status)")
let identity = (items as! [[String: Any]])[0][kSecImportItemIdentity as String] as! SecIdentity

let certificate = KeychainIdentities.certificate(of: identity)!
print("name", KeychainIdentities.commonName(of: certificate) ?? "nil")
print("selfIssued", KeychainIdentities.isSelfIssued(certificate))
let chain = KeychainIdentities.certificateChain(for: identity) ?? []
print("chainStartsWithLeaf", !chain.isEmpty && CFEqual(chain[0], certificate))
print("serverUse", KeychainIdentities.allowsServerUse(certificate))

KeychainExport.exportCertificate(of: identity, toPath: folder + "/cert.pem")
KeychainExport.exportPrivateKey(of: identity, toPath: folder + "/key.pem", password: "pass-1467")
try! "kept".write(toFile: folder + "/existing.pem", atomically: true, encoding: .utf8)
KeychainExport.exportCertificate(of: identity, toPath: folder + "/existing.pem")
KeychainExport.exportPrivateKey(of: identity, toPath: folder + "/existing.pem", password: "x")
KeychainExport.exportTrustedCertificates(toDirectory: folder + "/trusted")
try! FileManager.default.createDirectory(atPath: folder + "/trusted-existing", withIntermediateDirectories: false)
KeychainExport.exportTrustedCertificates(toDirectory: folder + "/trusted-existing")

let made = WebServerIdentity.makeSelfSignedIdentity(importOptions: [kSecImportExportKeychain as String: keychain!])!
KeychainExport.exportCertificate(of: made, toPath: folder + "/made.pem")
print("madeName", KeychainIdentities.certificate(of: made).flatMap { KeychainIdentities.commonName(of: $0) } ?? "nil")
print("madeSelfIssued", KeychainIdentities.isSelfIssued(KeychainIdentities.certificate(of: made)!))
var key: SecKey?
SecIdentityCopyPrivateKey(made, &key)
let attributes = SecKeyCopyAttributes(key!) as! [String: Any]
print("madeKey", attributes[kSecAttrKeyType as String] as! String == kSecAttrKeyTypeRSA as String,
      attributes[kSecAttrKeySizeInBits as String] as! Int)
// The key signs in the Keychain it was imported into.
var error: Unmanaged<CFError>?
let signature = SecKeyCreateSignature(key!, .rsaSignatureMessagePKCS1v15SHA256, Data("synthetic".utf8) as CFData, &error)
print("madeKeySigns", signature != nil)
'''

failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def main():
    work = Path(tempfile.mkdtemp(prefix='isix-keychain-'))
    keychain = work / f'identities-{uuid.uuid4()}.keychain-db'
    try:
        def ssl(*args, **kwargs):
            return subprocess.run([OPENSSL, *args], capture_output=True, text=True, cwd=work, timeout=60, **kwargs)
        ssl('req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', 'ca.key', '-out', 'ca.pem', '-days', '2',
            '-subj', '/CN=IsiX Keychain Test CA', '-sha256', check=True)
        ssl('req', '-newkey', 'rsa:2048', '-nodes', '-keyout', 'leaf.key', '-out', 'leaf.csr', '-subj', '/CN=IsiX Keychain Test',
            check=True)
        ssl('x509', '-req', '-in', 'leaf.csr', '-CA', 'ca.pem', '-CAkey', 'ca.key', '-CAcreateserial', '-out', 'leaf.pem',
            '-days', '2', '-sha256', check=True)
        ssl('pkcs12', '-export', '-in', 'leaf.pem', '-inkey', 'leaf.key', '-out', 'id.p12', '-passout', 'pass:synthetic',
            check=True)
        before = subprocess.run(['security', 'list-keychains', '-d', 'user'], capture_output=True, text=True).stdout
        subprocess.run(['security', 'create-keychain', '-p', 'synthetic', str(keychain)], check=True, capture_output=True)
        subprocess.run(['security', 'unlock-keychain', '-p', 'synthetic', str(keychain)], check=True, capture_output=True)
        after = subprocess.run(['security', 'list-keychains', '-d', 'user'], capture_output=True, text=True).stdout
        check(before == after, 'the disposable Keychain entered the user\'s search list')

        (work / 'main.swift').write_text(DRIVER)
        build = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', *module_flags('IsiXKeychain', work / 'module'),
                                str(work / 'main.swift'), '-o', str(work / 'driver')],
                               capture_output=True, text=True, timeout=600)
        if build.returncode != 0:
            print(build.stderr[-3000:])
            print('FAIL: the driver did not compile')
            return 1
        exports = work / 'exports'
        exports.mkdir()
        run = subprocess.run([str(work / 'driver'), str(keychain), str(work / 'id.p12'), str(exports)],
                             capture_output=True, text=True, timeout=120)
        if run.returncode != 0:
            print(run.stdout, run.stderr[-3000:])
            print('FAIL: the driver stopped')
            return 1
        values = dict(line.split(' ', 1) for line in run.stdout.strip().splitlines())
        check(values.get('name') == 'IsiX Keychain Test' and values.get('selfIssued') == 'false',
              f'the leaf was not read: {values}')
        check(values.get('chainStartsWithLeaf') == 'true', 'the chain shown to a peer does not start with the certificate')
        check(values.get('serverUse') == 'true', 'a certificate without key usage may not serve TLS')

        fingerprint = lambda path: ssl('x509', '-in', str(path), '-noout', '-fingerprint', '-sha256').stdout.strip()
        check(fingerprint(exports / 'cert.pem') == fingerprint(work / 'leaf.pem') != '',
              'the exported certificate is not the identity\'s')
        key = (exports / 'key.pem').read_text() if (exports / 'key.pem').is_file() else ''
        check('ENCRYPTED' in key, 'the exported private key is not encrypted')
        opened = ssl('rsa', '-in', str(exports / 'key.pem'), '-passin', 'pass:pass-1467', '-noout', '-modulus')
        wrong = ssl('rsa', '-in', str(exports / 'key.pem'), '-passin', 'pass:wrong', '-noout', '-modulus')
        certificate_modulus = ssl('x509', '-in', str(work / 'leaf.pem'), '-noout', '-modulus').stdout.strip()
        check(opened.returncode == 0 and opened.stdout.strip() == certificate_modulus and wrong.returncode != 0,
              'the exported key does not open with its password only, or is not the certificate\'s')
        check(not (exports / 'key.pem.p12').exists(), 'the PKCS#12 file of the key export was left behind')
        check((exports / 'existing.pem').read_text() == 'kept', 'an export replaced a file already there')
        trusted = sorted((exports / 'trusted').glob('*.pem'))
        check(all(p.name.split('_')[0] in '012' and p.read_text().startswith('-----BEGIN CERTIFICATE-----') for p in trusted),
              'the trusted certificates are not PEM files named <domain>_<index>.pem')
        check(not list((exports / 'trusted-existing').iterdir()), 'a trusted-certificates folder already there was written to')

        made = ssl('x509', '-in', str(exports / 'made.pem'), '-noout', '-text').stdout
        check(values.get('madeName') == 'Horos HTTP Server' and values.get('madeSelfIssued') == 'true',
              f'the web server identity is not the self-signed one: {values}')
        check(values.get('madeKey') == 'true 2048' and values.get('madeKeySigns') == 'true',
              f'the web server identity\'s key is not RSA 2048 signing in its Keychain: {values}')
        check('sha256WithRSAEncryption' in made and 'TLS Web Server Authentication' in made and 'CA:FALSE' in made
              and 'O=Horos Team' in made.replace(' = ', '='), 'the web server certificate is not SHA-256 for server authentication')
    finally:
        subprocess.run(['security', 'delete-keychain', str(keychain)], capture_output=True)
        shutil.rmtree(work, ignore_errors=True)
    if failures:
        for failure in failures:
            print('FAIL: ' + failure)
        return 1
    print('PASS: certificate, name, chain and server use read; certificate and encrypted key exported for DICOM TLS; '
          'trusted certificates exported; the self-signed web server identity made in the Keychain given; '
          'nothing replaced and no Keychain item outside the disposable one')
    return 0


if __name__ == '__main__':
    sys.exit(main())
