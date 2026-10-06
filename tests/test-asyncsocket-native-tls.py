#!/usr/bin/env python3
"""Native socket queues, TLS, timeout and resets on a delegate run loop.

Certificates are generated locally. TLS signing uses memory-only nonexportable
keys; DDKeychain export/password compatibility uses disposable UUID private
Keychains with an explicit private search list. Real preference comparison uses
only an ephemeral UUID name, cleared afterward; app preference names are captured
in memory. No patients or network peers outside loopback are used.
"""
import ast
import concurrent.futures
import hashlib
import os
from pathlib import Path
import select
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
KEY_ALGORITHM = 'EC' if '--identity=ec' in sys.argv else 'RSA'
PASSWORD_UPDATE_CONTROL = '--duplicate-update-control' in sys.argv
CONFIGURATION = next((arg.split('=', 1)[1] for arg in sys.argv if arg.startswith('--configuration=')), 'Debug')
OPENSSL = next((ROOT / base / CONFIGURATION / 'OpenSSL.build/Install'
                for base in ('build/Intermediates.noindex/Horos.build', 'build/Build/Intermediates.noindex/Horos.build')
                if (ROOT / base / CONFIGURATION / 'OpenSSL.build/Install/lib/libssl.a').is_file()),
               ROOT / 'build/Intermediates.noindex/Horos.build' / CONFIGURATION / 'OpenSSL.build/Install')
if not (OPENSSL / 'lib/libssl.a').is_file():
    print('SKIP: compile OpenSSL dependency first'); raise SystemExit(2)
snapshot_source = ROOT / 'tests/test-asyncsocket-reset-close.py'
tree = ast.parse(snapshot_source.read_text())
snapshot = next(node for node in tree.body if isinstance(node, ast.FunctionDef)
                and node.name == 'descriptor_snapshot')
namespace = {'subprocess': subprocess}
exec(compile(ast.Module(body=[snapshot], type_ignores=[]), str(snapshot_source), 'exec'), namespace)
descriptor_snapshot = namespace['descriptor_snapshot']

DRIVER = r'''
#import "AsyncSocket.h"
#import <Security/Security.h>
#import <fcntl.h>
#import <unistd.h>
#import <netinet/in.h>
#import <sys/resource.h>

static SecCertificateRef fixtureAnchor;
static BOOL fixtureUpgrade;
static BOOL fixtureFuture;
static Boolean FixtureTrustEvaluate(SecTrustRef trust,CFErrorRef *error) {
 if(fixtureAnchor){
  if(SecTrustSetAnchorCertificates(trust,(CFArrayRef)@[(id)fixtureAnchor])!=errSecSuccess)return false;
  if(SecTrustSetAnchorCertificatesOnly(trust,true)!=errSecSuccess)return false;
 }
 if(fixtureFuture)SecTrustSetVerifyDate(trust,(CFDateRef)[NSDate dateWithTimeIntervalSinceNow:2*24*60*60]);
 Boolean valid=SecTrustEvaluateWithError(trust,error);if(!valid)NSLog(@"real SecTrust rejection: %@",error?(id)*error:nil);return valid;
}
#define SecTrustEvaluateWithError FixtureTrustEvaluate
#include "AsyncSocket.m"
#undef SecTrustEvaluateWithError
#import "DDKeychain.h"
#import <objc/runtime.h>
#import <dlfcn.h>
#include <openssl/x509v3.h>
static NSMutableDictionary *fixturePreferences;
static NSString *fixtureDirectory;
static NSArray *fixtureLastUses;
static SecKeychainRef fixtureKeychain;
static NSString *fixtureActualPreferenceName;
static OSStatus fixtureRealPreferenceStatus;
static NSArray *fixturePasswordSearchList;
static int fixturePasswordAdds,fixturePasswordUpdates;
static OSStatus fixturePasswordLookupError,fixturePasswordUpdateError;
static NSDictionary *FixturePasswordQuery(CFDictionaryRef query){
 if(![(id)CFDictionaryGetValue(query,kSecClass)isEqual:(id)kSecClassGenericPassword])abort();
 if(!fixturePasswordSearchList.count)abort();
 NSMutableDictionary *scoped=[(NSDictionary*)query mutableCopy];scoped[(id)kSecMatchSearchList]=fixturePasswordSearchList;return [scoped autorelease];
}
static OSStatus FixtureItemCopyMatching(CFDictionaryRef query,CFTypeRef *result){
 if([(id)CFDictionaryGetValue(query,kSecClass)isEqual:(id)kSecClassIdentity]||[(id)CFDictionaryGetValue(query,kSecClass)isEqual:(id)kSecClassKey]){
  NSArray *keys=(id)CFDictionaryGetValue(query,kSecMatchSearchList);if(keys.count!=1||keys[0]!=(id)fixtureKeychain)abort();
  return SecItemCopyMatching(query,result);
 }
 if(fixturePasswordLookupError)return fixturePasswordLookupError;
 return SecItemCopyMatching((CFDictionaryRef)FixturePasswordQuery(query),result);
}
static OSStatus FixtureItemUpdate(CFDictionaryRef query,CFDictionaryRef changes){
 ++fixturePasswordUpdates;if(fixturePasswordUpdateError)return fixturePasswordUpdateError;
 return SecItemUpdate((CFDictionaryRef)FixturePasswordQuery(query),changes);
}
static OSStatus FixtureItemAdd(CFDictionaryRef attributes,CFTypeRef *result){
 if(!fixturePasswordSearchList.count)abort();++fixturePasswordAdds;
 NSMutableDictionary *scoped=[(NSDictionary*)attributes mutableCopy];scoped[(id)kSecUseKeychain]=fixturePasswordSearchList[0];
 OSStatus status=SecItemAdd((CFDictionaryRef)scoped,result);[scoped release];return status;
}
static SecIdentityRef FixtureCopyPreferred(CFStringRef name,CFArrayRef uses,CFArrayRef issuers){
 if(issuers)abort();if(fixtureActualPreferenceName&&CFEqual(name,(CFStringRef)fixtureActualPreferenceName))return SecIdentityCopyPreferred(name,uses,issuers);fixtureLastUses=(NSArray*)uses;
 id value=[fixturePreferences objectForKey:(id)name];return value?(SecIdentityRef)CFRetain(value):NULL;
}
static OSStatus FixtureSetPreferred(SecIdentityRef identity,CFStringRef name,CFArrayRef uses){
 if(fixtureActualPreferenceName&&CFEqual(name,(CFStringRef)fixtureActualPreferenceName)){fixtureRealPreferenceStatus=SecIdentitySetPreferred(identity,name,uses);return fixtureRealPreferenceStatus;}fixtureLastUses=(NSArray*)uses;if(!identity)abort();[fixturePreferences setObject:(id)identity forKey:(id)name];return errSecSuccess;
}
static OSStatus FixturePKCS12Import(CFDataRef data,CFDictionaryRef options,CFArrayRef *items){
 NSMutableDictionary *memory=[(NSDictionary*)options mutableCopy];memory[(id)kSecImportExportKeychain]=(id)fixtureKeychain;
 OSStatus result=SecPKCS12Import(data,(CFDictionaryRef)memory,items);[memory release];return result;
}
static OSStatus FixtureCopyDefault(SecKeychainRef *keychain){if(!fixtureKeychain)abort();*keychain=(SecKeychainRef)CFRetain(fixtureKeychain);return errSecSuccess;}
static void *FixtureDLSym(void *handle,const char *name){return !strcmp(name,"SecKeychainCopyDefault")?(void*)FixtureCopyDefault:dlsym(handle,name);}
#define dlsym FixtureDLSym
#define SecIdentityCopyPreferred FixtureCopyPreferred
#define SecIdentitySetPreferred FixtureSetPreferred
#define SecPKCS12Import FixturePKCS12Import
#define SecItemCopyMatching FixtureItemCopyMatching
#define SecItemUpdate FixtureItemUpdate
#define SecItemAdd FixtureItemAdd
#include "DDKeychain.m"
#undef SecIdentityCopyPreferred
#undef SecIdentitySetPreferred
#undef SecPKCS12Import
#undef SecItemCopyMatching
#undef SecItemUpdate
#undef SecItemAdd
#undef dlsym
static NSString *FixtureTempDirectory(id cls,SEL command){(void)cls;(void)command;return fixtureDirectory;}
// Legacy file-keychain setup is confined to the synthetic test boundary.
// Production DDKeychain is compiled independently with deprecated APIs as errors.
static NSData *FixtureSecurity(NSArray *arguments,NSString *home){
 NSTask *task=[[[NSTask alloc]init]autorelease];task.launchPath=@"/usr/bin/security";task.arguments=arguments;
 NSMutableDictionary *env=[[[NSProcessInfo processInfo]environment]mutableCopy];env[@"CFFIXED_USER_HOME"]=home;task.environment=env;[env release];
 NSPipe *pipe=[NSPipe pipe];task.standardOutput=pipe;task.standardError=[NSFileHandle fileHandleWithNullDevice];[task launch];
 NSData *output=[[pipe fileHandleForReading]readDataToEndOfFile];[task waitUntilExit];if(task.terminationStatus)abort();return output;
}
static NSString *FixturePasswordInKeychain(SecKeychainRef keychain){
 CFTypeRef value=NULL;NSDictionary *query=@{(id)kSecClass:(id)kSecClassGenericPassword,(id)kSecAttrService:@"OsiriX HTTP Server",(id)kSecAttrAccount:@"OsiriX",(id)kSecReturnData:@YES,(id)kSecMatchLimit:(id)kSecMatchLimitOne,(id)kSecMatchSearchList:@[(id)keychain]};
 OSStatus status=SecItemCopyMatching((CFDictionaryRef)query,&value);
 NSString *result=status==errSecSuccess?[[[NSString alloc]initWithData:(NSData*)value encoding:NSUTF8StringEncoding]autorelease]:nil;if(value)CFRelease(value);return result;
}
static BOOL checkHTTPPasswords(SecKeychainRef second){
 fixturePasswordSearchList=@[(id)fixtureKeychain,(id)second];fixturePasswordAdds=fixturePasswordUpdates=0;
 if([DDKeychain passwordForHTTPServer]||![DDKeychain setPasswordForHTTPServer:@"synthetic-ação"]||![[DDKeychain passwordForHTTPServer]isEqual:@"synthetic-ação"]||fixturePasswordAdds!=1)return NO;
 NSDictionary *duplicate=@{(id)kSecClass:(id)kSecClassGenericPassword,(id)kSecAttrService:@"OsiriX HTTP Server",(id)kSecAttrAccount:@"OsiriX",(id)kSecValueData:[@"untouched-duplicate"dataUsingEncoding:NSUTF8StringEncoding],(id)kSecUseKeychain:(id)second};
 if(SecItemAdd((CFDictionaryRef)duplicate,NULL))return NO;
 if(![DDKeychain setPasswordForHTTPServer:@"replacement"]||fixturePasswordAdds!=1||fixturePasswordUpdates!=1)return NO;
 if(![FixturePasswordInKeychain(fixtureKeychain)isEqual:@"replacement"]||![FixturePasswordInKeychain(second)isEqual:@"untouched-duplicate"])return NO;
 if([DDKeychain setPasswordForHTTPServer:nil])return NO;
 fixturePasswordLookupError=errSecAuthFailed;BOOL refused=![DDKeychain setPasswordForHTTPServer:@"forbidden"];fixturePasswordLookupError=0;
 if(!refused||fixturePasswordAdds!=1||fixturePasswordUpdates!=1)return NO;
 fixturePasswordUpdateError=errSecItemNotFound;refused=![DDKeychain setPasswordForHTTPServer:@"raced-deletion"];fixturePasswordUpdateError=0;
 return refused&&fixturePasswordAdds==1&&[FixturePasswordInKeychain(fixtureKeychain)isEqual:@"replacement"]&&[FixturePasswordInKeychain(second)isEqual:@"untouched-duplicate"];
}
static void checkDDKeychain(NSArray *identity,NSString *folder){
 folder=[folder stringByAppendingPathComponent:[@"keychain-"stringByAppendingString:[[NSUUID UUID]UUIDString]]];
 if(![[NSFileManager defaultManager]createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700}error:NULL])abort();
 NSData *searchBefore=[FixtureSecurity(@[@"list-keychains",@"-d",@"user"],folder)copy];
 NSString *keychainPath=[folder stringByAppendingPathComponent:@"fixture.keychain-db"];
 FixtureSecurity(@[@"create-keychain",@"-p",@"synthetic",keychainPath],folder);
 if(![searchBefore isEqual:FixtureSecurity(@[@"list-keychains",@"-d",@"user"],folder)])abort();
 OSStatus (*openFixture)(const char*,SecKeychainRef*)=dlsym(RTLD_DEFAULT,"SecKeychainOpen");
 if(!openFixture||openFixture(keychainPath.fileSystemRepresentation,&fixtureKeychain))abort();
 NSString *secondPath=[folder stringByAppendingPathComponent:@"duplicate.keychain-db"];
 FixtureSecurity(@[@"create-keychain",@"-p",@"synthetic",secondPath],folder);SecKeychainRef second=NULL;
 if(openFixture(secondPath.fileSystemRepresentation,&second))abort();
 BOOL passwordsOK=checkHTTPPasswords(second);fixturePasswordSearchList=nil;fixturePasswordLookupError=fixturePasswordUpdateError=0;
 CFRelease(second);FixtureSecurity(@[@"delete-keychain",secondPath],folder);
 if(!passwordsOK){CFRelease(fixtureKeychain);fixtureKeychain=NULL;FixtureSecurity(@[@"delete-keychain",keychainPath],folder);fprintf(stderr,"HTTP password single-item acceptance failed\n");abort();}
 fixturePreferences=[NSMutableDictionary new];
 NSString *name=@"org.horosproject.synthetic-tls-fixture";SecIdentityRef original=(SecIdentityRef)identity[0];
 [DDKeychain KeychainAccessSetPreferredIdentity:original forName:name keyUse:(int)CSSM_KEYUSE_ANY];if(fixtureLastUses)abort();
 SecIdentityRef copied=[DDKeychain KeychainAccessPreferredIdentityForName:name keyUse:(int)CSSM_KEYUSE_ANY];if(copied!=original||fixtureLastUses)abort();CFRelease(copied);
 [DDKeychain KeychainAccessSetPreferredIdentity:original forName:name keyUse:CSSM_KEYUSE_SIGN|CSSM_KEYUSE_VERIFY|CSSM_KEYUSE_SIGN_RECOVER];
 if(![(NSArray*)fixtureLastUses isEqual:@[(id)kSecAttrCanSign,(id)kSecAttrCanVerify]])abort();
 if([DDKeychain KeychainAccessPreferredIdentityForName:@"absent" keyUse:0])abort();
 if([DDKeychain KeychainAccessPreferredIdentityForName:name keyUse:0x40000000])abort();
 NSArray *chain=[DDKeychain KeychainAccessCertificateChainForIdentity:original];if(!chain.count)abort();
 SecCertificateRef cert=NULL;SecIdentityCopyCertificate(original,&cert);if(!CFEqual(cert,(CFTypeRef)chain[0]))abort();CFRelease(cert);
 NSString *certificatePath=[folder stringByAppendingPathComponent:@"exported-certificate.pem"];
 [DDKeychain KeychainAccessExportCertificateForIdentity:original toPath:certificatePath];
 if(![[NSString stringWithContentsOfFile:certificatePath encoding:NSUTF8StringEncoding error:NULL]containsString:@"BEGIN CERTIFICATE"])abort();
 fixtureDirectory=[[folder stringByAppendingPathComponent:@"fallback"]copy];
 if(![[NSFileManager defaultManager]createDirectoryAtPath:fixtureDirectory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700}error:NULL])abort();
 Method method=class_getClassMethod([DDKeychain class],@selector(applicationTemporaryDirectory));IMP before=method_setImplementation(method,(IMP)FixtureTempDirectory);
 [DDKeychain createNewIdentity];method_setImplementation(method,before);
 SecIdentityRef fallback=(SecIdentityRef)fixturePreferences[@"org.horosproject.horoswebserver"];if(!fallback)abort();
 fixtureActualPreferenceName=[[@"org.horosproject.synthetic-preference."stringByAppendingString:[[NSUUID UUID]UUIDString]]copy];
 if(SecIdentityCopyPreferred((CFStringRef)fixtureActualPreferenceName,NULL,NULL))abort();
 [DDKeychain KeychainAccessSetPreferredIdentity:fallback forName:fixtureActualPreferenceName keyUse:(int)CSSM_KEYUSE_ANY];
 SecIdentityRef persisted=[DDKeychain KeychainAccessPreferredIdentityForName:fixtureActualPreferenceName keyUse:(int)CSSM_KEYUSE_ANY];
 BOOL preferenceOK=persisted&&CFEqual(persisted,fallback);if(persisted)CFRelease(persisted);
 if(fixtureRealPreferenceStatus){
  OSStatus (*legacySet)(SecIdentityRef,CFStringRef,uint32_t)=dlsym(RTLD_DEFAULT,"SecIdentitySetPreference");
  OSStatus legacyStatus=legacySet?legacySet(fallback,(CFStringRef)fixtureActualPreferenceName,0):errSecUnimplemented;
  fprintf(stderr,"LIMIT: real preferred identity outside global search list: current=%d historical=%d\n",(int)fixtureRealPreferenceStatus,(int)legacyStatus);
  preferenceOK=fixtureRealPreferenceStatus==legacyStatus;
 }
 OSStatus removed=SecIdentitySetPreferred(NULL,(CFStringRef)fixtureActualPreferenceName,NULL);
 persisted=SecIdentityCopyPreferred((CFStringRef)fixtureActualPreferenceName,NULL,NULL);fprintf(stderr,"Preferred UUID cleanup status=%d remaining=%d\n",(int)removed,persisted!=NULL);
 preferenceOK=preferenceOK&&(removed==0||removed==fixtureRealPreferenceStatus||removed==errSecItemNotFound)&&!persisted;if(persisted)CFRelease(persisted);
 [fixtureActualPreferenceName release];fixtureActualPreferenceName=nil;if(!preferenceOK)abort();
 if([DDKeychain SSLIdentityAndCertificates].count){fprintf(stderr,"unexpected unlabeled SDK identity\n");abort();}
 SecKeyRef labeledKey=NULL;if(SecIdentityCopyPrivateKey(fallback,&labeledKey))abort();
 NSDictionary *labelQuery=@{(id)kSecClass:(id)kSecClassKey,(id)kSecMatchItemList:@[(id)labeledKey],(id)kSecMatchSearchList:@[(id)fixtureKeychain]};
 OSStatus labelStatus=SecItemUpdate((CFDictionaryRef)labelQuery,(CFDictionaryRef)@{(id)kSecAttrLabel:@"org.horosproject.horoswebserver.synthetic"});if(labelStatus){fprintf(stderr,"label update status=%d\n",(int)labelStatus);abort();}CFRelease(labeledKey);
 NSArray *sdkIdentity=[DDKeychain SSLIdentityAndCertificates];if(sdkIdentity.count!=1||!CFEqual((CFTypeRef)sdkIdentity[0],fallback)){fprintf(stderr,"SDK labeled identity count=%lu\n",(unsigned long)sdkIdentity.count);abort();}
 SecIdentityCopyCertificate(fallback,&cert);X509 *x=HorosTLSCertificate(cert);EVP_PKEY *publicKey=X509_get_pubkey(x);
 if(EVP_PKEY_get_bits(publicKey)<2048||X509_get_signature_nid(x)!=NID_sha256WithRSAEncryption)abort();
 EXTENDED_KEY_USAGE *usage=X509_get_ext_d2i(x,NID_ext_key_usage,NULL,NULL);BOOL serverAuth=NO;
 for(int i=0;usage&&i<sk_ASN1_OBJECT_num(usage);++i)if(OBJ_obj2nid(sk_ASN1_OBJECT_value(usage,i))==NID_server_auth)serverAuth=YES;
 EXTENDED_KEY_USAGE_free(usage);if(!serverAuth)abort();
 int pair[2];if(socketpair(AF_UNIX,SOCK_STREAM,0,pair))abort();HorosNativeTLS *tls=HorosTLSCreate(pair[0],@{(id)kCFStreamSSLIsServer:@YES,(id)kCFStreamSSLCertificates:@[(id)fallback]});
 if(!tls)abort();HorosTLSFree(tls);close(pair[0]);close(pair[1]);X509_free(x);CFRelease(cert);
 NSString *keyPath=[folder stringByAppendingPathComponent:@"exported-private.pem"];
 [DDKeychain KeychainAccessExportPrivateKeyForIdentity:fallback toPath:keyPath cryptWithPassword:@"synthetic"];
 BOOL exportOK=[[NSFileManager defaultManager]fileExistsAtPath:keyPath]&&![[NSFileManager defaultManager]fileExistsAtPath:[keyPath stringByAppendingPathExtension:@"p12"]];
 BIO *pem=BIO_new_file(keyPath.fileSystemRepresentation,"r");EVP_PKEY *roundtrip=pem?PEM_read_bio_PrivateKey(pem,NULL,NULL,"synthetic"):NULL;
 exportOK=exportOK&&roundtrip&&EVP_PKEY_eq(publicKey,roundtrip)==1;
 BIO_free(pem);EVP_PKEY_free(roundtrip);EVP_PKEY_free(publicKey);
 if([[NSFileManager defaultManager]contentsOfDirectoryAtPath:fixtureDirectory error:NULL].count)abort();
 [fixtureDirectory release];fixtureDirectory=nil;[fixturePreferences release];fixturePreferences=nil;
 CFRelease(fixtureKeychain);fixtureKeychain=NULL;FixtureSecurity(@[@"delete-keychain",keychainPath],folder);
 if(![searchBefore isEqual:FixtureSecurity(@[@"list-keychains",@"-d",@"user"],folder)])abort();[searchBefore release];
 if(!exportOK)abort();
 fprintf(stderr,"PASS: DDKeychain HTTP password read/add/single-item update/duplicate isolation, current preference selectors/key-use/chain, synthetic fallback RSA2048/SHA256, level2 context, encrypted PEM and private keychain cleanup\n");
}


@interface Client:NSObject { @public BOOL done; BOOL valid; BOOL secure; BOOL upgrading; BOOL ready; BOOL secured; NSString *peer; NSArray *identity; }
@end
@implementation Client
- (void)onSocket:(AsyncSocket *)sock didConnectToHost:(NSString *)host port:(UInt16)port {
 if(upgrading){
  [sock writeData:[@"STARTTLS\r\n\r\n"dataUsingEncoding:NSUTF8StringEncoding]withTimeout:2 tag:10];
  [sock readDataToData:[@"\r\n"dataUsingEncoding:NSUTF8StringEncoding]withTimeout:2 maxLength:256 tag:10];
 }
 if(secure){NSMutableDictionary *settings=[NSMutableDictionary dictionaryWithObject:peer?:[NSNull null]forKey:(id)kCFStreamSSLPeerName];
  if(identity)settings[(id)kCFStreamSSLCertificates]=identity;[sock startTLS:settings];}
 [sock writeData:[@"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding] withTimeout:2 tag:0];
 [sock readDataToData:[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding] withTimeout:2 maxLength:4096 tag:1];
 [sock readDataToLength:2 withTimeout:2 tag:2];
}
- (void)onSocket:(AsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag {
 if(tag==10){ready=[data isEqual:[@"ready\r\n"dataUsingEncoding:NSUTF8StringEncoding]];if(!ready)abort();}
 if(tag==2){valid=[data isEqual:[@"xx" dataUsingEncoding:NSUTF8StringEncoding]];[sock disconnect];}
}
- (void)onSocketDidSecure:(AsyncSocket *)sock { secured=YES;if(upgrading&&!ready)abort(); }
- (void)onSocket:(AsyncSocket *)sock willDisconnectWithError:(NSError *)error { NSLog(@"client TLS error: %@",error); }
- (void)onSocketDidDisconnect:(AsyncSocket *)sock { done=YES; }
@end

@interface Listener:NSObject {
 NSMutableArray *clients;
 NSArray *identity;
 NSThread *worker;
 NSRunLoop *loop;
}
- (id)initWithIdentity:(NSArray *)value;
@end
@implementation Listener
- (id)initWithIdentity:(NSArray *)value {
 if((self=[super init])) {
  clients=[NSMutableArray new];identity=[value retain];
  worker=[[NSThread alloc]initWithTarget:self selector:@selector(work) object:nil];[worker start];
  for(;;){@synchronized(self){if(loop)break;}[NSThread sleepForTimeInterval:0.001];}
 }return self;
}
- (void)work { @autoreleasepool {
 NSRunLoop *current=[NSRunLoop currentRunLoop];
 [current addPort:[NSMachPort port] forMode:NSDefaultRunLoopMode];
 @synchronized(self){loop=[current retain];}
 [current run];
}}
- (void)onSocket:(AsyncSocket *)server didAcceptNewSocket:(AsyncSocket *)sock {
 @synchronized(clients){[clients addObject:sock];}
}
- (NSRunLoop *)onSocket:(AsyncSocket *)server wantsRunLoopForNewSocket:(AsyncSocket *)sock { return loop; }
- (void)secure:(AsyncSocket *)sock {
 [sock startTLS:@{(id)kCFStreamSSLIsServer:@YES,(id)kCFStreamSSLCertificates:identity,
  (id)kCFStreamSSLValidatesCertificateChain:@YES,
  (id)kCFStreamSSLLevel:(id)kCFStreamSocketSecurityLevelNegotiatedSSL}];
}
- (BOOL)onSocketWillConnect:(AsyncSocket *)sock {
 if(identity&&!fixtureUpgrade)[self performSelector:@selector(secure:) onThread:worker withObject:sock waitUntilDone:YES];
 return YES;
}
- (void)onSocket:(AsyncSocket *)sock didConnectToHost:(NSString *)host port:(UInt16)port {
 if([NSRunLoop currentRunLoop]!=loop)abort();
 [sock readDataToData:[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding] withTimeout:0.4 maxLength:4096 tag:0];
}
- (void)onSocketDidSecure:(AsyncSocket *)sock {
 if([NSRunLoop currentRunLoop]!=loop)abort();
}
- (void)onSocket:(AsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag {
 NSString *request=[[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding]autorelease];
 if([request hasPrefix:@"STARTTLS"]){
  [sock writeData:[@"ready\r\n"dataUsingEncoding:NSUTF8StringEncoding]withTimeout:2 tag:10];
  [self secure:sock];
  [sock readDataToData:[@"\r\n\r\n"dataUsingEncoding:NSUTF8StringEncoding]withTimeout:2 maxLength:4096 tag:0];return;
 }
 NSUInteger size=[request containsString:@"/large"]?6*1024*1024:2;
 NSMutableData *body=[NSMutableData dataWithLength:size];memset(body.mutableBytes,'x',size);
 NSString *head=[NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n",size];
 [sock writeData:[head dataUsingEncoding:NSUTF8StringEncoding] withTimeout:2 tag:1];
 [sock writeData:body withTimeout:0.5 tag:2];
 [sock disconnectAfterWriting];
}
- (void)onSocketDidDisconnect:(AsyncSocket *)sock {
 @synchronized(clients){[clients removeObject:sock];}
}
- (void)onSocket:(AsyncSocket *)sock willDisconnectWithError:(NSError *)error { NSLog(@"probe disconnect: %@",error); }
@end
static void checkProviderIdentity(NSArray *identity) {
 int fds[2];if(socketpair(AF_UNIX,SOCK_STREAM,0,fds))abort();
 HorosNativeTLS *tls=HorosTLSCreate(fds[0],@{(id)kCFStreamSSLIsServer:@YES,(id)kCFStreamSSLCertificates:identity});
 if(!tls)abort();EVP_PKEY *key=SSL_CTX_get0_privatekey(tls->context);
 EVP_MD_CTX *digest=EVP_MD_CTX_new(),*copy=EVP_MD_CTX_new();EVP_PKEY_CTX *sign=NULL;
 if(!EVP_DigestSignInit_ex(digest,&sign,"SHA256",tls->library,NULL,key,NULL))abort();
 NSData *message=[@"real protected TLS signature transcript"dataUsingEncoding:NSUTF8StringEncoding];
 if(!EVP_DigestSignUpdate(digest,message.bytes,message.length)||!EVP_MD_CTX_copy_ex(copy,digest))abort();
 size_t size=0,again=0;if(!EVP_DigestSignFinal(digest,NULL,&size)||!EVP_DigestSignFinal(digest,NULL,&again)||size!=again||size!=(size_t)EVP_PKEY_get_size(key))abort();
 NSMutableData *signature=[NSMutableData dataWithLength:size];if(!EVP_DigestSignFinal(copy,signature.mutableBytes,&size))abort();[signature setLength:size];
 SecKeyRef private=NULL;SecIdentityCopyPrivateKey((SecIdentityRef)identity[0],&private);SecKeyRef public=SecKeyCopyPublicKey(private);
 SecKeyAlgorithm algorithm=EVP_PKEY_is_a(key,"RSA")?kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256:kSecKeyAlgorithmECDSASignatureMessageX962SHA256;
 if(!SecKeyVerifySignature(public,algorithm,(CFDataRef)message,(CFDataRef)signature,NULL))abort();
 if(EVP_PKEY_is_a(key,"RSA")){
  EVP_MD_CTX_free(digest);digest=EVP_MD_CTX_new();
  if(!EVP_DigestSignInit_ex(digest,&sign,"SHA256",tls->library,NULL,key,NULL)||EVP_PKEY_CTX_set_rsa_padding(sign,RSA_PKCS1_PSS_PADDING)<=0||EVP_PKEY_CTX_set_rsa_pss_saltlen(sign,RSA_PSS_SALTLEN_DIGEST)<=0||EVP_PKEY_CTX_set_rsa_mgf1_md_name(sign,"SHA2-256",NULL)<=0)abort();
  if(!EVP_DigestSignUpdate(digest,message.bytes,message.length))abort();size=EVP_PKEY_get_size(key);[signature setLength:size];
  if(!EVP_DigestSignFinal(digest,signature.mutableBytes,&size))abort();[signature setLength:size];
  if(!SecKeyVerifySignature(public,kSecKeyAlgorithmRSASignatureMessagePSSSHA256,(CFDataRef)message,(CFDataRef)signature,NULL))abort();
  if(EVP_PKEY_CTX_set_rsa_pss_saltlen(sign,20)<=0)abort();size=EVP_PKEY_get_size(key);[signature setLength:size];
  if(EVP_DigestSignFinal(digest,signature.mutableBytes,&size)>0)abort();
 }
 CFRelease(public);CFRelease(private);EVP_MD_CTX_free(copy);EVP_MD_CTX_free(digest);HorosTLSFree(tls);close(fds[0]);close(fds[1]);
}
static NSArray *protectedIdentity(NSString *folder) {
 CFArrayRef imported=NULL;
  NSData *der=[NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:@"key.der"]];
  SecItemImportExportKeyParameters params={0};params.version=SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION;
  params.keyUsage=(CFArrayRef)@[(id)kSecAttrCanSign];params.keyAttributes=(CFArrayRef)@[(id)kSecAttrIsSensitive];
  SecExternalFormat format=kSecFormatOpenSSL;SecExternalItemType type=kSecItemTypePrivateKey;
  OSStatus status=SecItemImport((CFDataRef)der,CFSTR("der"),&format,&type,0,&params,NULL,&imported);
  if(status||!imported||CFArrayGetCount(imported)!=1){fprintf(stderr,"protected import: %d\n",(int)status);abort();}
  SecKeyRef key=(SecKeyRef)CFArrayGetValueAtIndex(imported,0);CFErrorRef exportError=NULL;
  CFDataRef exported=SecKeyCopyExternalRepresentation(key,&exportError);
  if(exported){CFRelease(exported);fprintf(stderr,"fixture private key unexpectedly exportable\n");abort();}
  if(exportError)CFRelease(exportError);
  NSData *certificate=[NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:@"cert.der"]];
  SecCertificateRef cert=SecCertificateCreateWithData(NULL,(CFDataRef)certificate);
  SecIdentityRef protectedIdentity=cert?SecIdentityCreate(NULL,cert,key):NULL;
  if(!protectedIdentity){fprintf(stderr,"protected identity mismatch\n");abort();}
  NSArray *identity=@[(id)protectedIdentity];CFRelease(protectedIdentity);CFRelease(cert);CFRelease(imported);checkProviderIdentity(identity);checkDDKeychain(identity,folder);return identity;
}
int main(int argc,char **argv) { @autoreleasepool {
 if(argc>3 && !strcmp(argv[1],"client")) {
  Client *delegate=[Client new];
  if(argc>6)delegate->upgrading=!strcmp(argv[6],"upgrade");
  if(argc>4){delegate->secure=YES;delegate->peer=!strcmp(argv[4],"none")?nil:[NSString stringWithUTF8String:argv[4]];
   if(!strcmp(argv[4],"expired")){fixtureFuture=YES;delegate->peer=@"localhost";}
   if(argc>5&&strcmp(argv[5],"untrusted")){NSData *ca=[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[5]]];fixtureAnchor=SecCertificateCreateWithData(NULL,(CFDataRef)ca);if(!fixtureAnchor)abort();}}
  if(argc>6&&!strcmp(argv[6],"mutual"))delegate->identity=protectedIdentity([[NSString stringWithUTF8String:argv[5]]stringByDeletingLastPathComponent]);
  AsyncSocket *client=[[AsyncSocket alloc]initWithDelegate:delegate];
  NSError *error=nil;BOOL started;
  if(!strcmp(argv[3],"address")) {
   struct sockaddr_in address={.sin_len=sizeof(address),.sin_family=AF_INET,.sin_port=htons(atoi(argv[2])),.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
   started=[client connectToAddress:[NSData dataWithBytes:&address length:sizeof(address)] withTimeout:2 error:&error];
  }else started=[client connectToHost:@"127.0.0.1" onPort:atoi(argv[2]) withTimeout:2 error:&error];
  if(argc>6&&!strcmp(argv[6],"cancel"))[client performSelector:@selector(disconnect)withObject:nil afterDelay:0.05];
  NSDate *limit=[NSDate dateWithTimeIntervalSinceNow:5];
  while(started && !delegate->done && limit.timeIntervalSinceNow>0)
   [[NSRunLoop currentRunLoop]runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  if(argc>6&&!strcmp(argv[6],"cancel")&&!delegate->done){fprintf(stderr,"cancellation did not notify delegate\n");return 2;}
  BOOL valid=delegate->valid&&(!delegate->secure||delegate->secured);[client disconnect];[client release];[delegate release];
  if(!valid)fprintf(stderr,"client failed: %s\n",error.description.UTF8String);return valid?0:1;
 }
 fixtureUpgrade=argc>2&&!strcmp(argv[2],"upgrade");
 NSArray *identity=nil;
 if(argc>1 && strcmp(argv[1],"plain")) {
  identity=protectedIdentity([[NSString stringWithUTF8String:argv[1]]stringByDeletingLastPathComponent]);

 }
 if(argc>2){struct rlimit limit;if(getrlimit(RLIMIT_NOFILE,&limit))abort();
  if(limit.rlim_cur<2048){limit.rlim_cur=2048;if(setrlimit(RLIMIT_NOFILE,&limit))abort();}
  int fd;do{fd=open("/dev/null",O_RDONLY);if(fd<0)abort();}while(fd<1100);}
 Listener *listener=[[Listener alloc]initWithIdentity:identity];
 AsyncSocket *server=[[AsyncSocket alloc]initWithDelegate:listener];NSError *error=nil;
 if(![server acceptOnInterface:@"localhost" port:0 error:&error])abort();
 printf("PORT %u\n",[server localPort]);fflush(stdout);
 [[NSRunLoop currentRunLoop]run];
 }return 0;
}
'''


def run(command, **kwargs):
    result = subprocess.run(command, capture_output=True, text=True, timeout=60, **kwargs)
    assert result.returncode == 0, repr(command) + '\n' + result.stderr[-4000:]
    return result


with tempfile.TemporaryDirectory(prefix='horos-native-tls-') as folder:
    work = Path(folder)
    (work / 'main.m').write_text(DRIVER)
    dd_source = (ROOT / 'cocoahttpserver/DDKeychain.m').read_text()
    if PASSWORD_UPDATE_CONTROL:
        needle = 'SecItemUpdate((CFDictionaryRef)selected,'
        assert dd_source.count(needle) == 1
        dd_source = dd_source.replace(needle, 'SecItemUpdate((CFDictionaryRef)@{(id)kSecClass:(id)kSecClassGenericPassword,(id)kSecAttrService:@"OsiriX HTTP Server",(id)kSecAttrAccount:@"OsiriX",(id)kSecMatchLimit:(id)kSecMatchLimitAll},')
    (work / 'DDKeychain.m').write_text(dd_source)
    key_args = ['-newkey','ec','-pkeyopt','ec_paramgen_curve:P-256'] if KEY_ALGORITHM == 'EC' else ['-newkey','rsa:2048']
    run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','3','-subj','/CN=Horos synthetic fixture CA',
         '-addext','basicConstraints=critical,CA:TRUE','-addext','keyUsage=critical,keyCertSign,cRLSign',
         '-keyout',str(work/'root-key.pem'),'-out',str(work/'root-cert.pem')])
    run(['openssl', 'req', '-new'] + key_args + ['-nodes',
         '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost',
         '-addext', 'extendedKeyUsage=serverAuth,clientAuth',
         '-addext','basicConstraints=critical,CA:FALSE',
         '-keyout', str(work / 'key.pem'), '-out', str(work / 'cert.csr')])
    run(['openssl','x509','-req','-in',str(work/'cert.csr'),'-CA',str(work/'root-cert.pem'),'-CAkey',str(work/'root-key.pem'),
         '-CAcreateserial','-copy_extensions','copyall','-days','1','-out',str(work/'cert.pem')])
    run(['openssl','x509','-in',str(work/'root-cert.pem'),'-outform','DER','-out',str(work/'root-cert.der')])
    converter = ['ec'] if KEY_ALGORITHM == 'EC' else ['rsa','-traditional']
    run(['openssl'] + converter + ['-in', str(work / 'key.pem'), '-outform', 'DER', '-out', str(work / 'key.der')])
    run(['openssl', 'x509', '-in', str(work / 'cert.pem'), '-outform', 'DER', '-out', str(work / 'cert.der')])
    run(['xcrun', 'clang', '-fno-objc-arc', '-fobjc-exceptions', '-g',
         '-Os' if CONFIGURATION == 'Release' else '-O0', '-fno-fast-math', '-target', 'arm64-apple-macos26.0',
         '-fsanitize=address,undefined', '-Werror=deprecated-declarations', '-Wno-objc-method-access',
         '-I', str(ROOT / 'cocoahttpserver'), '-I', str(ROOT / 'Horos/Sources'), '-I', str(OPENSSL / 'include'), str(work / 'main.m'),
         '-framework', 'Foundation', '-framework', 'AppKit', '-framework', 'SecurityInterface',
         '-framework', 'CoreServices', '-framework', 'Security', str(OPENSSL / 'lib/libssl.a'), str(OPENSSL / 'lib/libcrypto.a'), '-o', str(work / 'helper')])
    trusted = ssl.create_default_context(cafile=str(work / 'root-cert.pem'))
    environment = dict(os.environ, ASAN_OPTIONS='abort_on_error=1:detect_leaks=0:halt_on_error=1',
                       UBSAN_OPTIONS='halt_on_error=1:print_stacktrace=1')
    for tls in ((True,) if KEY_ALGORITHM == "EC" or PASSWORD_UPDATE_CONTROL else (False, True)):
        for high in (False, True):
            with (work / 'stderr.log').open('w+') as errors:
                server = subprocess.Popen([str(work / 'helper'), str(work / 'cert.pem') if tls else 'plain']
                                          + (['high'] if high else []), stdout=subprocess.PIPE,
                                          stderr=errors, text=True, env=environment)
                try:
                    assert select.select([server.stdout], [], [], 5)[0], 'listener did not start'
                    line = server.stdout.readline()
                    assert line.startswith('PORT '), line
                    port = int(line.split()[1])

                    def connect():
                        peer = socket.create_connection(('127.0.0.1', port), timeout=5)
                        return trusted.wrap_socket(peer, server_hostname='localhost') if tls else peer

                    def complete(large=False):
                        with connect() as peer:
                            request = b'GET /large HTTP/1.1\r\nHost: localhost\r\n\r\n' if large else b'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'
                            # Split the delimiter between writes to exercise the existing queue/prebuffer.
                            peer.sendall(request[:-1]); peer.sendall(request[-1:])
                            if large:
                                time.sleep(0.15)
                            received = bytearray()
                            while packet := peer.recv(65536):
                                received.extend(packet)
                            head, body = received.split(b'\r\n\r\n', 1)
                            expected = b'x' * (6 * 1024 * 1024 if large else 2)
                            assert hashlib.sha256(body).digest() == hashlib.sha256(expected).digest()
                            assert b'Content-Length: ' + str(len(expected)).encode() in head

                    for _ in range(8):
                        complete()
                    if not tls:
                        for mode in ('host', 'address'):
                            run([str(work / 'helper'), 'client', str(port), mode], env=environment)
                    if tls:
                        for peer, anchor, accepted in (
                            ('localhost', str(work / 'root-cert.der'), True),
                            ('wrong.invalid', str(work / 'root-cert.der'), False),
                            ('localhost', 'untrusted', False),
                            ('expired', str(work / 'root-cert.der'), False),
                            ('none', str(work / 'root-cert.der'), True)):
                            result=subprocess.run([str(work / 'helper'), 'client', str(port), 'address', peer, anchor],
                                                  capture_output=True,text=True,timeout=8,env=environment)
                            assert (result.returncode==0)==accepted, (peer, anchor, result.stderr)
                        for version in (ssl.TLSVersion.TLSv1_2, ssl.TLSVersion.TLSv1_3):
                            context=ssl.create_default_context(cafile=str(work / 'root-cert.pem'))
                            context.minimum_version=context.maximum_version=version
                            with context.wrap_socket(socket.create_connection(('127.0.0.1',port),timeout=5),server_hostname='localhost') as peer:
                                peer.sendall(b'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n')
                                response=bytearray()
                                while chunk:=peer.recv(65536):response.extend(chunk)
                                assert response.endswith(b'xx'), (version,response)
                        if KEY_ALGORITHM == 'RSA':
                            result=run(['openssl','s_client','-connect',f'127.0.0.1:{port}', '-CAfile',str(work/'root-cert.pem'),
                                        '-verify_return_error','-tls1_2','-sigalgs','rsa_pkcs1_sha256','-quiet'],
                                       input='GET / HTTP/1.1\r\nHost: localhost\r\n\r\n')
                            assert result.stdout.endswith('xx'),result.stdout
                    if tls:print('PASS: AsyncSocket native client verifies CA/expiration/explicit hostname, rejects negatives and preserves NSNull PeerName',flush=True)
                    baseline = descriptor_snapshot(server.pid)
                    complete(large=True)
                    with connect() as peer:
                        peer.sendall(b'GET / HTTP/1.1\r\n')
                        assert peer.recv(1) == b'', 'read timeout did not close'
                    # Stop consuming a large response until its write timer fires.
                    raw = socket.socket()
                    raw.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
                    raw.settimeout(3)
                    raw.connect(('127.0.0.1', port))
                    slow = trusted.wrap_socket(raw, server_hostname='localhost') if tls else raw
                    with slow:
                        slow.sendall(b'GET /large HTTP/1.1\r\nHost: localhost\r\n\r\n')
                        time.sleep(0.8)
                        truncated = bytearray()
                        limit = time.monotonic() + 5
                        while packet := slow.recv(65536):
                            truncated.extend(packet)
                            assert time.monotonic() < limit, 'write timeout failed to close'
                        assert len(truncated) < 6 * 1024 * 1024, 'write timeout was not exercised'
                    if tls:
                        with socket.create_connection(('127.0.0.1', port), timeout=3) as raw:
                            try:
                                with ssl.create_default_context().wrap_socket(raw, server_hostname='localhost'):
                                    raise AssertionError('untrusted certificate accepted')
                            except ssl.SSLCertVerificationError:
                                pass

                    def reset(_):
                        with socket.create_connection(('127.0.0.1', port), timeout=5) as peer:
                            peer.sendall(b'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n')
                            peer.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', 1, 0))

                    with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
                        list(pool.map(reset, range(400)))
                        if tls:
                            def secure_reset(_):
                                with connect() as peer:
                                    peer.sendall(b'GET / HTTP/1.1\r\n')
                                    peer.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', 1, 0))
                            list(pool.map(secure_reset, range(60)))
                    complete()
                    deadline = time.monotonic() + 30
                    while True:
                        after = descriptor_snapshot(server.pid)
                        if after[0] <= baseline[0] and after[1] <= baseline[1] or time.monotonic() >= deadline:
                            break
                        time.sleep(0.1)
                    assert after[0] <= baseline[0] and after[1] <= baseline[1], (baseline, after)
                    assert server.poll() is None, 'server died'
                    print(f'PASS: key={KEY_ALGORITHM} tls={tls} high={high}, delegate thread, fragmented read, 6 MiB write, '
                          f'read/write timeouts, 400 resets' + (' + 60 TLS resets' if tls else '')
                          + f', descriptors {baseline} -> {after}', flush=True)
                finally:
                    server.terminate()
                    try:
                        server.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        server.kill(); server.wait()
                    errors.seek(0)
                    stderr = errors.read()
                    if sys.exc_info()[0]:
                        print(stderr[-4000:], file=sys.stderr)
                    assert not any(mark in stderr for mark in ('AddressSanitizer', 'UndefinedBehaviorSanitizer',
                                                              'runtime error:', 'Assertion failure')), stderr[-4000:]

    with (work / 'upgrade-stderr.log').open('w+') as errors:
        server=subprocess.Popen([str(work/'helper'),str(work/'cert.pem'),'upgrade'],
                                stdout=subprocess.PIPE,stderr=errors,text=True,env=environment)
        try:
            assert select.select([server.stdout],[],[],5)[0],'upgrade listener did not start'
            port=int(server.stdout.readline().split()[1])
            run([str(work/'helper'),'client',str(port),'address','localhost',str(work/'root-cert.der'),'upgrade'],env=environment)
            for version in (ssl.TLSVersion.TLSv1_2,ssl.TLSVersion.TLSv1_3):
                with socket.create_connection(('127.0.0.1',port),timeout=5) as raw:
                    raw.sendall(b'STARTTLS\r\n\r\n');assert raw.recv(64)==b'ready\r\n'
                    context=ssl.create_default_context(cafile=str(work/'root-cert.pem'))
                    context.minimum_version=context.maximum_version=version
                    with context.wrap_socket(raw,server_hostname='localhost') as peer:
                        peer.sendall(b'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n');response=bytearray()
                        while chunk:=peer.recv(65536):response.extend(chunk)
                        assert response.endswith(b'xx')
            print(f'PASS: {KEY_ALGORITHM} STARTTLS preserves pending plaintext read/write ordering, AsyncSocket native client/server and TLS1.2/1.3',flush=True)
        finally:
            server.terminate();server.wait(timeout=5);errors.seek(0)
            diagnostic=errors.read()
            assert 'AddressSanitizer' not in diagnostic and 'runtime error:' not in diagnostic,diagnostic[-4000:]

    def mutual_peer(listener):
        context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(str(work/'cert.pem'),str(work/'key.pem'))
        context.load_verify_locations(str(work/'root-cert.pem'));context.verify_mode=ssl.CERT_REQUIRED
        with listener.accept()[0] as raw:
            with context.wrap_socket(raw,server_side=True) as peer:
                request=bytearray()
                while b'\r\n\r\n' not in request:request.extend(peer.recv(4096))
                peer.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nxx')
                assert peer.getpeercert(),'client did not present certificate'
    with socket.socket() as listener, concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
        listener.bind(('127.0.0.1',0));listener.listen(1);listener.settimeout(5)
        pending=executor.submit(mutual_peer,listener)
        run([str(work/'helper'),'client',str(listener.getsockname()[1]),'address','localhost',str(work/'root-cert.der'),'mutual'],env=environment)
        pending.result(timeout=5)
    print(f'PASS: {KEY_ALGORITHM} nonexportable client identity signs real mutual TLS',flush=True)

    def cancelled_peer(listener):
        with listener.accept()[0] as peer:
            peer.settimeout(3);hello=peer.recv(65536);assert hello,'client handshake never started'
            while peer.recv(65536):pass
    with socket.socket() as listener, concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
        listener.bind(('127.0.0.1',0));listener.listen(1);listener.settimeout(5)
        pending=executor.submit(cancelled_peer,listener)
        result=subprocess.run([str(work/'helper'),'client',str(listener.getsockname()[1]),'address','localhost',str(work/'root-cert.der'),'cancel'],env=environment,capture_output=True,text=True,timeout=3)
        assert result.returncode==1,result.stderr
        assert 'AddressSanitizer' not in result.stderr and 'runtime error:' not in result.stderr,result.stderr
        pending.result(timeout=5)
    print('PASS: cancellation during pending native TLS handshake releases connection without callback-after-free',flush=True)
