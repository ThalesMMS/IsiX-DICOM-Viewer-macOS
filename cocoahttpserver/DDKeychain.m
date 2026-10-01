/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/

#import "DDKeychain.h"
#import "DICOMTLS.h"
#include <stdio.h>
#include <dlfcn.h>

static NSMutableDictionary *lockedFiles = nil;
static NSRecursiveLock *lockFile = nil;

/*
 * Map legacy key-use bits to current Security attributes without changing the
 * SDK ABI.
 */
// Retain the public integer key-use ABI while mapping to current Security
// attributes.
static BOOL DDValidKeyUses(int bits) {
 uint32_t known=CSSM_KEYUSE_ANY|CSSM_KEYUSE_ENCRYPT|CSSM_KEYUSE_DECRYPT|CSSM_KEYUSE_SIGN|CSSM_KEYUSE_VERIFY|CSSM_KEYUSE_SIGN_RECOVER|CSSM_KEYUSE_VERIFY_RECOVER|CSSM_KEYUSE_WRAP|CSSM_KEYUSE_UNWRAP|CSSM_KEYUSE_DERIVE;
 return !((uint32_t)bits&~known);
}
static CFArrayRef DDKeyUses(int bits) {
  if (!bits || ((uint32_t)bits & CSSM_KEYUSE_ANY))
    return NULL;
  NSMutableArray *uses = [NSMutableArray array];
  const uint32_t flags[] = {CSSM_KEYUSE_ENCRYPT,       CSSM_KEYUSE_DECRYPT,
                            CSSM_KEYUSE_SIGN,          CSSM_KEYUSE_VERIFY,
                            CSSM_KEYUSE_WRAP,          CSSM_KEYUSE_UNWRAP,
                            CSSM_KEYUSE_DERIVE,        CSSM_KEYUSE_SIGN_RECOVER,
                            CSSM_KEYUSE_VERIFY_RECOVER};
  const CFStringRef names[] = {
      kSecAttrCanEncrypt, kSecAttrCanDecrypt, kSecAttrCanSign,
      kSecAttrCanVerify,  kSecAttrCanWrap,    kSecAttrCanUnwrap,
      kSecAttrCanDerive,  kSecAttrCanSign,    kSecAttrCanVerify};
  for (size_t i = 0; i < sizeof(flags) / sizeof(flags[0]); i++)
    if ((uint32_t)bits & flags[i]) {
      if (![uses containsObject:(id)names[i]])
        [uses addObject:(id)names[i]];
    }
  return (CFArrayRef)uses;
}

// SDK compatibility boundary: this public selector has no internal callers and retains its
// historical default-Keychain-only search. Security has no current API to
// obtain that handle. Resolve the exact public C ABI here; do not widen the
// search or silence diagnostics for the active current-API implementation.
static OSStatus DDCopyDefaultKeychainForLegacySDK(SecKeychainRef *keychain) {
  typedef OSStatus (*CopyDefault)(SecKeychainRef *);
  CopyDefault copyDefault = (CopyDefault)dlsym(RTLD_DEFAULT, "SecKeychainCopyDefault");
  *keychain = NULL;
  return copyDefault ? copyDefault(keychain) : errSecUnimplemented;
}

@implementation DDKeychain

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Server:
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * Retrieves the password stored in the keychain for the HTTP server.
 **/
+ (NSString *)passwordForHTTPServer {
  NSDictionary *query = @{
    (id)kSecClass : (id)kSecClassGenericPassword,
    (id)kSecAttrService : @"OsiriX HTTP Server",
    (id)kSecAttrAccount : @"OsiriX",
    (id)kSecReturnData : @YES,
    (id)kSecMatchLimit : (id)kSecMatchLimitOne
  };
  CFTypeRef data = NULL;
  OSStatus status = SecItemCopyMatching((CFDictionaryRef)query, &data);
  NSString *password = nil;
  if (status == errSecSuccess && data && CFGetTypeID(data) == CFDataGetTypeID())
    password =
        [[[NSString alloc] initWithData:(NSData *)data
                               encoding:NSUTF8StringEncoding] autorelease];
  if (data)
    CFRelease(data);
  return password;
}

+ (BOOL)setPasswordForHTTPServer:(NSString *)password {
  if (!password)
    return NO;
  NSData *data = [password dataUsingEncoding:NSUTF8StringEncoding];
  if (!data)
    return NO;
  NSDictionary *query = @{
    (id)kSecClass : (id)kSecClassGenericPassword,
    (id)kSecAttrService : @"OsiriX HTTP Server",
    (id)kSecAttrAccount : @"OsiriX"
  };
  NSMutableDictionary *lookup = [query mutableCopy];
  lookup[(id)kSecReturnRef] = @YES;
  lookup[(id)kSecMatchLimit] = (id)kSecMatchLimitOne;
  CFTypeRef existingItem = NULL;
  OSStatus status = SecItemCopyMatching((CFDictionaryRef)lookup, &existingItem);
  [lookup release];
  if (status == errSecSuccess && existingItem) {
    // Match the one item returned by the lookup, as the historical
    // FindGenericPassword + ModifyAttributesAndData pair did.
    NSDictionary *selected = @{
      (id)kSecClass : (id)kSecClassGenericPassword,
      (id)kSecMatchItemList : @[(id)existingItem]
    };
    status = SecItemUpdate((CFDictionaryRef)selected,
                          (CFDictionaryRef)@{(id)kSecValueData : data});
  } else if (status == errSecItemNotFound) {
    NSMutableDictionary *item = [query mutableCopy];
    item[(id)kSecValueData] = data;
    item[(id)kSecAttrDescription] = @"OsiriX password";
    status = SecItemAdd((CFDictionaryRef)item, NULL);
    [item release];
  } else if (status == errSecSuccess) {
    status = errSecInternalComponent;
  }
  if (existingItem)
    CFRelease(existingItem);
  return status == errSecSuccess;
}

+ (void)createNewIdentity {
  // Declare any Carbon variables we may create
  // We do this here so it's easier to compare to the bottom of this method
  // where we release them all
  CFArrayRef outItems = NULL;

  // Configure the paths where we'll create all of our identity files
  NSString *basePath = [DDKeychain applicationTemporaryDirectory];

  NSString *privateKeyPath =
      [basePath stringByAppendingPathComponent:@"private.pem"];
  NSString *reqConfPath = [basePath stringByAppendingPathComponent:@"req.conf"];
  NSString *certificatePath =
      [basePath stringByAppendingPathComponent:@"certificate.crt"];
  NSString *certWrapperPath =
      [basePath stringByAppendingPathComponent:@"certificate.p12"];

  // RSA 2048 and SHA-256 meet the transport default security level.

  NSArray *privateKeyArgs = [NSArray
      arrayWithObjects:@"genrsa", @"-out", privateKeyPath, @"2048", nil];

  NSTask *genPrivateKeyTask = [[[NSTask alloc] init] autorelease];

  [genPrivateKeyTask setLaunchPath:@"/usr/bin/openssl"];
  [genPrivateKeyTask setArguments:privateKeyArgs];
  [genPrivateKeyTask launch];

  // Don't use waitUntilExit - I've had too many problems with it in the past
  do {
    [NSThread sleepUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  } while ([genPrivateKeyTask isRunning]);

  // Now we want to create a configuration file for our certificate
  // This is an optional step, but we do it so people who are browsing their
  // keychain know exactly where the certificate came from, and don't delete it.

  NSMutableString *mStr = [NSMutableString stringWithCapacity:500];
  [mStr appendFormat:@"%@\n", @"[ req ]"];
  [mStr appendFormat:@"%@\n", @"distinguished_name  = req_distinguished_name"];
  [mStr appendFormat:@"%@\n", @"prompt              = no"];
  [mStr appendFormat:@"%@\n", @"x509_extensions     = server_extensions"];
  [mStr appendFormat:@"%@\n", @""];
  [mStr appendFormat:@"%@\n", @"[ req_distinguished_name ]"];
  [mStr appendFormat:@"%@\n", @"C                   = BR"];
  [mStr appendFormat:@"%@\n", @"ST                  = SC"];
  [mStr appendFormat:@"%@\n", @"L                   = Florianopolis"];
  [mStr appendFormat:@"%@\n", @"O                   = Horos Team"];
  [mStr appendFormat:@"%@\n", @"OU                  = Open Source"];
  [mStr appendFormat:@"%@\n", @"CN                  = Horos HTTP Server"];
  [mStr appendFormat:@"%@\n", @"emailAddress        = horos@horosproject.org"];
  [mStr appendString:@"\n[ server_extensions ]\nbasicConstraints = "
                     @"critical,CA:FALSE\nkeyUsage = "
                     @"critical,digitalSignature,"
                     @"keyEncipherment\nextendedKeyUsage = serverAuth\n"];

  [mStr writeToFile:reqConfPath
         atomically:NO
           encoding:NSUTF8StringEncoding
              error:nil];

  // You can generate your own certificate by running the following command in
  // the terminal: openssl req -new -x509 -key private.pem -out certificate.crt
  // -text -days 365 -batch
  //
  // You can optionally create a configuration file, and pass an extra command
  // to use it: -config req.conf

  NSArray *certificateArgs =
      [NSArray arrayWithObjects:@"req", @"-new", @"-x509", @"-sha256", @"-key",
                                privateKeyPath, @"-config", reqConfPath,
                                @"-out", certificatePath, @"-text", @"-days",
                                @"365", @"-batch", nil];

  NSTask *genCertificateTask = [[[NSTask alloc] init] autorelease];

  [genCertificateTask setLaunchPath:@"/usr/bin/openssl"];
  [genCertificateTask setArguments:certificateArgs];
  [genCertificateTask launch];

  // Don't use waitUntilExit - I've had too many problems with it in the past
  do {
    [NSThread sleepUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  } while ([genCertificateTask isRunning]);

  // Mac OS X has problems importing private keys, so we wrap everything in
  // PKCS#12 format You can create a p12 wrapper by running the following
  // command in the terminal: openssl pkcs12 -export -in certificate.crt -inkey
  // private.pem -passout pass:password -out certificate.p12 -name "Open Source"

  NSArray *certWrapperArgs = [NSArray
      arrayWithObjects:@"pkcs12", @"-export", @"-export", @"-in",
                       certificatePath, @"-inkey", privateKeyPath, @"-passout",
                       @"pass:password", @"-out", certWrapperPath, @"-name",
                       @"OsiriX HTTP Server", nil];

  NSTask *genCertWrapperTask = [[[NSTask alloc] init] autorelease];

  [genCertWrapperTask setLaunchPath:@"/usr/bin/openssl"];
  [genCertWrapperTask setArguments:certWrapperArgs];
  [genCertWrapperTask launch];

  // Don't use waitUntilExit - I've had too many problems with it in the past
  do {
    [NSThread sleepUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  } while ([genCertWrapperTask isRunning]);

  // At this point we've created all the identity files that we need
  // Our next step is to import the identity into the keychain
  // We can do this by using the SecKeychainItemImport() method.
  // But of course this method is "Frozen in Carbonite"...
  // So it's going to take us 100 lines of code to build up the parameters
  // needed to make the method call
  NSData *certData = [NSData dataWithContentsOfFile:certWrapperPath];

  NSDictionary *options = @{(id)kSecImportExportPassphrase : @"password"};
  OSStatus err = certData ? SecPKCS12Import((CFDataRef)certData,
                                            (CFDictionaryRef)options, &outItems)
                          : errSecDecode;
  if (err == errSecSuccess) {
    SecIdentityRef identity = NULL;
    for (NSDictionary *item in (NSArray *)outItems) {
      id candidate = item[(id)kSecImportItemIdentity];
      if (candidate &&
          CFGetTypeID((CFTypeRef)candidate) == SecIdentityGetTypeID()) {
        identity = (SecIdentityRef)candidate;
        break;
      }
    }
    if (identity)
      [DDKeychain
          KeychainAccessSetPreferredIdentity:identity
                                     forName:@"org.horosproject.horoswebserver"
                                      keyUse:CSSM_KEYUSE_ANY];
  } else
    NSLog(@"Web server identity import failed: %@",
          [DDKeychain stringForError:err]);

  // Don't forget to delete the temporary files
  [[NSFileManager defaultManager] removeItemAtPath:privateKeyPath error:NULL];
  [[NSFileManager defaultManager] removeItemAtPath:reqConfPath error:NULL];
  [[NSFileManager defaultManager] removeItemAtPath:certificatePath error:NULL];
  [[NSFileManager defaultManager] removeItemAtPath:certWrapperPath error:NULL];

  // Don't forget to release anything we may have created
  if (outItems)
    CFRelease(outItems);
}

/**
 * Returns an array of SecCertificateRefs except for the first element in the array, which is a SecIdentityRef.
 * Currently this method is designed to return the identity created in the method above.
 * You will most likely alter this method to return a proper identity based on what it is you're trying to do.
**/
+ (NSArray *)SSLIdentityAndCertificates
{
 // Retain the legacy default-Keychain-only and first matching prefix contract.
 SecKeychainRef keychain = NULL;
 NSMutableArray *result=[NSMutableArray array];
 if(DDCopyDefaultKeychainForLegacySDK(&keychain)!=errSecSuccess||!keychain)return result;
 CFTypeRef found=NULL;
 NSDictionary *query=@{(id)kSecClass:(id)kSecClassIdentity,(id)kSecMatchLimit:(id)kSecMatchLimitAll,(id)kSecReturnRef:@YES,(id)kSecMatchSearchList:@[(id)keychain]};
 OSStatus status=SecItemCopyMatching((CFDictionaryRef)query,&found);
 if(status==errSecSuccess&&found&&CFGetTypeID(found)==CFArrayGetTypeID()){
  for(id item in (NSArray*)found){SecKeyRef key=NULL;
   if(SecIdentityCopyPrivateKey((SecIdentityRef)item,&key)!=errSecSuccess)continue;
   CFTypeRef attrs = NULL;
   NSDictionary *keyQuery=@{(id)kSecClass:(id)kSecClassKey,(id)kSecMatchSearchList:@[(id)keychain],(id)kSecMatchItemList:@[(id)key],(id)kSecReturnAttributes:@YES,(id)kSecMatchLimit:(id)kSecMatchLimitOne};
   OSStatus keyStatus=SecItemCopyMatching((CFDictionaryRef)keyQuery,&attrs);
   id name=keyStatus==errSecSuccess&&attrs&&CFGetTypeID(attrs)==CFDictionaryGetTypeID()?[(NSDictionary*)attrs objectForKey:(id)kSecAttrLabel]:nil;
   if([name isKindOfClass:[NSString class]]&&[name hasPrefix:@"org.horosproject.horoswebserver"])[result addObject:item];
   if(attrs)CFRelease(attrs);CFRelease(key);if([result count])break;
  }
 }
 if(found)CFRelease(found);CFRelease(keychain);return result;
}

+ (NSString *)applicationTemporaryDirectory
{
	NSString *userTempDir = NSTemporaryDirectory();
	NSString *appTempDir = [userTempDir stringByAppendingPathComponent:@"OsiriX HTTP Server"];
	
	NSFileManager *fileManager = [NSFileManager defaultManager];
	if([fileManager fileExistsAtPath:appTempDir] == NO)
	{
		[fileManager createDirectoryAtPath:appTempDir withIntermediateDirectories:YES attributes:nil error:NULL];
	}
	
	return appTempDir;
}

/**
 * Simple utility class to convert a SecExternalFormat into a string suitable for printing/logging.
**/
+ (NSString *)stringForSecExternalFormat:(SecExternalFormat)extFormat
{
	switch(extFormat)
	{
		case kSecFormatUnknown              : return @"kSecFormatUnknown";
			
		/* Asymmetric Key Formats */
		case kSecFormatOpenSSL              : return @"kSecFormatOpenSSL";
		case kSecFormatSSH                  : return @"kSecFormatSSH - Not Supported";
		case kSecFormatBSAFE                : return @"kSecFormatBSAFE";
			
		/* Symmetric Key Formats */
		case kSecFormatRawKey               : return @"kSecFormatRawKey";
			
		/* Formats for wrapped symmetric and private keys */
		case kSecFormatWrappedPKCS8         : return @"kSecFormatWrappedPKCS8";
		case kSecFormatWrappedOpenSSL       : return @"kSecFormatWrappedOpenSSL";
		case kSecFormatWrappedSSH           : return @"kSecFormatWrappedSSH - Not Supported";
		case kSecFormatWrappedLSH           : return @"kSecFormatWrappedLSH - Not Supported";
			
		/* Formats for certificates */
		case kSecFormatX509Cert             : return @"kSecFormatX509Cert";
			
		/* Aggregate Types */
		case kSecFormatPEMSequence          : return @"kSecFormatPEMSequence";
		case kSecFormatPKCS7                : return @"kSecFormatPKCS7";
		case kSecFormatPKCS12               : return @"kSecFormatPKCS12";
		case kSecFormatNetscapeCertSequence : return @"kSecFormatNetscapeCertSequence";
			
		default                             : return @"Unknown";
	}
}

/**
 * Simple utility class to convert a SecExternalItemType into a string suitable for printing/logging.
**/
+ (NSString *)stringForSecExternalItemType:(SecExternalItemType)itemType
{
	switch(itemType)
	{
		case kSecItemTypeUnknown     : return @"kSecItemTypeUnknown";
			
		case kSecItemTypePrivateKey  : return @"kSecItemTypePrivateKey";
		case kSecItemTypePublicKey   : return @"kSecItemTypePublicKey";
		case kSecItemTypeSessionKey  : return @"kSecItemTypeSessionKey";
		case kSecItemTypeCertificate : return @"kSecItemTypeCertificate";
		case kSecItemTypeAggregate   : return @"kSecItemTypeAggregate";
		
		default                      : return @"Unknown";
	}
}

/**
 * Simple utility class to convert a SecKeychainAttrType into a string suitable for printing/logging.
**/
+ (NSString *)stringForSecKeychainAttrType:(SecKeychainAttrType)attrType
{
	switch(attrType)
	{
		case kSecCreationDateItemAttr       : return @"kSecCreationDateItemAttr";
		case kSecModDateItemAttr            : return @"kSecModDateItemAttr";
		case kSecDescriptionItemAttr        : return @"kSecDescriptionItemAttr";
		case kSecCommentItemAttr            : return @"kSecCommentItemAttr";
		case kSecCreatorItemAttr            : return @"kSecCreatorItemAttr";
		case kSecTypeItemAttr               : return @"kSecTypeItemAttr";
		case kSecScriptCodeItemAttr         : return @"kSecScriptCodeItemAttr";
		case kSecLabelItemAttr              : return @"kSecLabelItemAttr";
		case kSecInvisibleItemAttr          : return @"kSecInvisibleItemAttr";
		case kSecNegativeItemAttr           : return @"kSecNegativeItemAttr";
		case kSecCustomIconItemAttr         : return @"kSecCustomIconItemAttr";
		case kSecAccountItemAttr            : return @"kSecAccountItemAttr";
		case kSecServiceItemAttr            : return @"kSecServiceItemAttr";
		case kSecGenericItemAttr            : return @"kSecGenericItemAttr";
		case kSecSecurityDomainItemAttr     : return @"kSecSecurityDomainItemAttr";
		case kSecServerItemAttr             : return @"kSecServerItemAttr";
		case kSecAuthenticationTypeItemAttr : return @"kSecAuthenticationTypeItemAttr";
		case kSecPortItemAttr               : return @"kSecPortItemAttr";
		case kSecPathItemAttr               : return @"kSecPathItemAttr";
		case kSecVolumeItemAttr             : return @"kSecVolumeItemAttr";
		case kSecAddressItemAttr            : return @"kSecAddressItemAttr";
		case kSecSignatureItemAttr          : return @"kSecSignatureItemAttr";
		case kSecProtocolItemAttr           : return @"kSecProtocolItemAttr";
		case kSecCertificateType            : return @"kSecCertificateType";
		case kSecCertificateEncoding        : return @"kSecCertificateEncoding";
		case kSecCrlType                    : return @"kSecCrlType";
		case kSecCrlEncoding                : return @"kSecCrlEncoding";
		case kSecAlias                      : return @"kSecAlias";
		default                             : return @"Unknown";
	}
}

+ (NSString *)stringForError:(OSStatus)status;
{
	CFStringRef msg = SecCopyErrorMessageString(status, NULL);
	NSString *errorMsg = msg?[NSString stringWithString:(NSString*)msg]:[NSString stringWithFormat:@"Security status %d",(int)status];
	if(msg)CFRelease(msg);
	
	return errorMsg;
}

# pragma mark Keychain Access


+ (NSArray *)KeychainAccessCertificatesList {
    
    CFTypeRef   arrayRef     = NULL;
    NSDictionary * dict = @{
                            (id) kSecClass: (id) kSecClassIdentity,
                            (id) kSecMatchLimit: (id) kSecMatchLimitAll,
                            (id) kSecReturnAttributes: (id) kCFBooleanTrue,
                            (id) kSecReturnRef: (id) kCFBooleanTrue,
                            };
    
    OSStatus err = SecItemCopyMatching((CFDictionaryRef) dict, &arrayRef);

    if (err != errSecSuccess) {
        if (err == errSecItemNotFound)
            return [NSArray array];
        NSLog(@"%@:%s: SecItemCopyMatching failed: %@", [[self class] description],
              __PRETTY_FUNCTION__, [DDKeychain stringForError:err]);
        return nil;
    }
    
    NSMutableArray * found = [NSMutableArray array];
    
    for(int i = 0; i < CFArrayGetCount(arrayRef); i++) {
        NSDictionary * attr = (__bridge NSDictionary *)(CFArrayGetValueAtIndex(arrayRef, i));
        /*NSString * label = (NSString *)[attr objectForKey:(id)kSecAttrLabel];*/
        
        if (YES)  {
            SecIdentityRef identityRef = (__bridge SecIdentityRef)([attr objectForKey:(id)kSecValueRef]);
            SecCertificateRef certRef = NULL;
            err = SecIdentityCopyCertificate(identityRef, &certRef);
            if (err != errSecSuccess) {
                NSLog(@"%@:%s: SecIdentityCopyCertificate failed: %@ (skipping %@)", [[self class] description],
                      __PRETTY_FUNCTION__, [DDKeychain stringForError:err], identityRef);
                goto skip;
            }

            NSDictionary * valRef = CFBridgingRelease(SecCertificateCopyValues(certRef, nil, nil));

#if 0
            SecKeychainRef keychainRef;
            err = SecKeychainItemCopyKeychain((SecKeychainItemRef)identityRef, &keychainRef);
            if (err != errSecSuccess) {
                NSLog(@"%@:%s: SecKeychainItemCopyKeychain failed: %@ (skipping %@)", [[self class] description],
                      __PRETTY_FUNCTION__, [DDKeychain stringForError:err], identityRef);
                goto skip;
            };
            
            char path[PATH_MAX];
            UInt32 len = sizeof(path);
            err = SecKeychainGetPath(keychainRef, &len, path);
            if (err != errSecSuccess) {
                NSLog(@"%@:%s: SecKeychainGetPath failed: %@ (skipping %@)", [[self class] description],
                      __PRETTY_FUNCTION__, [DDKeychain stringForError:err], identityRef);
                goto skip;
            };
            NSLog(@"%@: %s",[valRef objectForKey:(__bridge id)(kSecOIDCommonName)], path);
#endif
            
            // Skip certs which cannot be used. Page 29 of ITU-T Rec. X.509 (11/2008):
            //
            // KeyUsage  ::=  BIT STRING {
            //    digitalSignature  (0),
            //    contentCommitment (1),
            //    keyEncipherment   (2),
            //    dataEncipherment  (3),
            //    keyAgreement      (4),
            //    keyCertSign       (5),
            //    cRLSign           (6),
            //    encipherOnly      (7),
            //    decipherOnly      (8),
            //
            NSDictionary * keyUsage = [valRef objectForKey:(__bridge id)(kSecOIDKeyUsage)];
            NSInteger flag = keyUsage ? [[keyUsage objectForKey:@"value"] integerValue] : 0;
            
            CFBooleanRef invisible = (CFBooleanRef) [valRef objectForKey:(__bridge id)(kSecAttrIsInvisible)];
            
            // Value of 0 is implies any use - seems to be passed by apple if none is set.
            //
            if (invisible == kCFBooleanTrue)
                goto skip;
            
            if ((flag != 0)&& ((flag & 1) == 0))
                goto skip;
                
                [found addObject:(__bridge id)(identityRef)];
        skip:
            if(certRef)CFRelease(certRef);
        }
    };
    if (arrayRef)
        CFRelease(arrayRef);

    return found;
}

+ (void)KeychainAccessExportTrustedCertificatesToDirectory:(NSString*)directory;
{
	BOOL isDirectory, directoryExists;
	
	directoryExists = [[NSFileManager defaultManager] fileExistsAtPath:directory isDirectory:&isDirectory];
	if(directoryExists) return;
	if(!directoryExists)[[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:NO attributes:nil error:nil];
		
	int domains[3] = {kSecTrustSettingsDomainUser, kSecTrustSettingsDomainAdmin, kSecTrustSettingsDomainSystem};
	
	CFArrayRef certArray = NULL;
	OSStatus status;
	CFIndex numCerts, dex;
	int i;
	for (i=0; i<3; i++)
	{
		status = SecTrustSettingsCopyCertificates(domains[i], &certArray);
		if(status) NSLog(@"SecTrustSettingsCopyCertificates: %@",[DDKeychain stringForError:status]);
		
		if( certArray)
		{
			numCerts = CFArrayGetCount(certArray);

			for(dex=0; dex<numCerts; dex++)
			{
				SecCertificateRef certRef = (SecCertificateRef)CFArrayGetValueAtIndex(certArray, dex);			
				CFDataRef certificateDataRef = NULL;
				status = SecItemExport(certRef, kSecFormatX509Cert, kSecItemPemArmour, NULL, &certificateDataRef);
				
				if(status==0)
				{
					NSString *path = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"%d_%d.pem", i, (int) dex]];
					if(![[NSFileManager defaultManager] fileExistsAtPath:path])
						[(NSData*)certificateDataRef writeToFile:path atomically:YES];
				}
				else NSLog(@"SecItemExport : error : %@", [DDKeychain stringForError:status]);
				
			}
			
			CFRelease(certArray);
			certArray = NULL;
		}
	}
}

// Returns a reference to the preferred identity, or NULL if none was found.
// Call the CFRelease function to release this object when you are finished with it.
+ (SecIdentityRef)KeychainAccessPreferredIdentityForName:(NSString*)name keyUse:(int)keyUse;
{
 if(!name||!DDValidKeyUses(keyUse))return NULL;
 return SecIdentityCopyPreferred((CFStringRef)name,DDKeyUses(keyUse),NULL);
}

+ (void)KeychainAccessSetPreferredIdentity:(SecIdentityRef)identity forName:(NSString*)name keyUse:(int)keyUse;
{
 if(identity&&name&&DDValidKeyUses(keyUse)){OSStatus status=SecIdentitySetPreferred(identity,(CFStringRef)name,DDKeyUses(keyUse));if(status!=errSecSuccess)NSLog(@"Identity preference failed: %@",[DDKeychain stringForError:status]);}
}

+ (NSString*)KeychainAccessCertificateCommonNameForIdentity:(SecIdentityRef)identity;
{
	NSString *name = nil;
	if(identity)
	{		
		SecCertificateRef certificateRef = NULL;
		SecIdentityCopyCertificate(identity, &certificateRef);
		if(certificateRef)
		{
			CFStringRef commonName = NULL;
			OSStatus status = SecCertificateCopyCommonName(certificateRef, &commonName);
			if(status==0)
			{
				name = [NSString stringWithString:(NSString*)commonName];
				CFRelease(commonName);
			}
			else NSLog(@"KeychainAccessCertificateCommonNameForIdentity: error: %@", [DDKeychain stringForError:status]);
			
			CFRelease(certificateRef);
		}		
	}	
	return name;
}

/*
 * The following method returns the correct icon for a certificate:
 *	- the blue icon for "Standard certificates"
 *	- the gold icon for "Self signed certificates"
 *
 *	The hypothese is : if the subject == the issuer then it is a Self signed certificate
 *	It _seems_ to work (Joris)
 */
+ (NSImage*)KeychainAccessCertificateIconForIdentity:(SecIdentityRef)identity;
{
 if(!identity)return nil;SecCertificateRef certificate=NULL;if(SecIdentityCopyCertificate(identity,&certificate)!=errSecSuccess)return nil;
 CFDataRef subject=SecCertificateCopyNormalizedSubjectSequence(certificate),issuer=SecCertificateCopyNormalizedIssuerSequence(certificate);
 BOOL selfIssued=subject&&issuer&&CFEqual(subject,issuer);
 if(subject)CFRelease(subject);if(issuer)CFRelease(issuer);CFRelease(certificate);
 return [NSImage imageNamed:selfIssued?@"CertSmallRoot.tif":@"CertSmallStd.tif"];
}

+ (NSArray*)KeychainAccessCertificateChainForIdentity:(SecIdentityRef)identity;
{
 if(!identity)return nil;SecCertificateRef certificate=NULL;
 if(SecIdentityCopyCertificate(identity,&certificate)!=errSecSuccess)return nil;
 SecPolicyRef policy=SecPolicyCreateSSL(true,NULL);SecTrustRef trust=NULL;
 OSStatus status=SecTrustCreateWithCertificates((CFArrayRef)@[ (id)certificate ],policy,&trust);
 NSArray *chain=nil;
 if(status==errSecSuccess){
  // A self-signed/untrusted identity still needs its built chain returned,
  // as with SecTrustEvaluate+GetResult; trust approval is not this getter's contract.
  CFErrorRef error=NULL;(void)SecTrustEvaluateWithError(trust,&error);if(error)CFRelease(error);
  CFArrayRef certificates=SecTrustCopyCertificateChain(trust);if(certificates){chain=[NSArray arrayWithArray:(NSArray*)certificates];CFRelease(certificates);}
 }
 if(trust)CFRelease(trust);if(policy)CFRelease(policy);CFRelease(certificate);return chain;
}

+ (void)KeychainAccessExportCertificateForIdentity:(SecIdentityRef)identity toPath:(NSString*)path;
{
	if([[NSFileManager defaultManager] fileExistsAtPath:path]) return;
	
	SecCertificateRef certificate = NULL;
	OSStatus status = SecIdentityCopyCertificate(identity, &certificate);
	if(status==0)
	{
		CFDataRef certificateDataRef = NULL;
		status = SecItemExport(certificate, kSecFormatX509Cert, kSecItemPemArmour, NULL, &certificateDataRef);
		
		if(status==0)
		{
			[(NSData*)certificateDataRef writeToFile:path atomically:YES];
		}
		else NSLog(@"SecItemExport : error : %@", [DDKeychain stringForError:status]);
		
		if(certificateDataRef)CFRelease(certificateDataRef);
		CFRelease(certificate);	
	}
	else NSLog(@"SecIdentityCopyCertificate : error : %@", [DDKeychain stringForError:status]);	
}

+ (void)KeychainAccessExportPrivateKeyForIdentity:(SecIdentityRef)identity toPath:(NSString*)path cryptWithPassword:(NSString*)password;
{
	if([[NSFileManager defaultManager] fileExistsAtPath:path]) return;
		
	SecKeyRef privateKey = NULL;
	OSStatus status = SecIdentityCopyPrivateKey(identity, &privateKey);
	if(status==0)
	{
		CFDataRef privateKeyDataRef = NULL;
		SecItemImportExportKeyParameters exportParameters = {.version=SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION,.passphrase=(CFStringRef)password};
		
		status = SecItemExport(identity, kSecFormatPKCS12, 0, &exportParameters, &privateKeyDataRef);
		
		if(status==0)
		{
			[(NSData*)privateKeyDataRef writeToFile:[path stringByAppendingPathExtension:@"p12"] atomically:YES];
			
			// convert the private key file from PKCS#12 format to PEM format:
			// $ openssl pkcs12 -in key.p12 -out key.pem -passin pass:passwordIN -passout pass:passwordOUT
			
			// The password goes through the environment: on the command line, every
			// user of the machine saw it in ps while the .p12 was on disk (#801).
			NSArray *args = [NSArray arrayWithObjects:	@"pkcs12", @"-nocerts",
							 @"-in", [path stringByAppendingPathExtension:@"p12"],
							 @"-out", path,
							 @"-passin", @"env:HOROS_TLS_KEY_PASSWORD",
							 @"-passout", @"env:HOROS_TLS_KEY_PASSWORD", nil];
			
			NSMutableDictionary *environment = [NSMutableDictionary dictionaryWithDictionary:[[NSProcessInfo processInfo] environment]];
			[environment setObject:password forKey:@"HOROS_TLS_KEY_PASSWORD"];
			
			NSTask *convertTask = [[[NSTask alloc] init] autorelease];
			[convertTask setLaunchPath:@"/usr/bin/openssl"];
			[convertTask setArguments:args];
			[convertTask setEnvironment:environment];
			[convertTask launch];
			
            while( [convertTask isRunning])
                [NSThread sleepForTimeInterval: 0.1];
            
			[[NSFileManager defaultManager] removeItemAtPath:[path stringByAppendingPathExtension:@"p12"] error:NULL]; // remove the .p12 file
		}
		else NSLog(@"SecItemExport : error : %@", [DDKeychain stringForError:status]);
		
		if(privateKeyDataRef)CFRelease(privateKeyDataRef);
		CFRelease(privateKey);
	}
	else NSLog(@"SecIdentityCopyPrivateKey : error : %@", [DDKeychain stringForError:status]);			
}

+ (void)KeychainAccessOpenCertificatePanelForIdentity:(SecIdentityRef)identity;
{
	if(identity)
	{		
		SecCertificateRef certificateRef = NULL;
		SecIdentityCopyCertificate(identity, &certificateRef);
		if(certificateRef)
		{
			NSMutableArray *certificates = [NSMutableArray arrayWithObject:(id)certificateRef];
			NSArray *certificateChain = [DDKeychain KeychainAccessCertificateChainForIdentity:identity];
			[certificates addObjectsFromArray:certificateChain];
			
			[[SFCertificatePanel sharedCertificatePanel] runModalForCertificates:certificates showGroup:YES];		
			CFRelease(certificateRef);
		}
	}
}

#pragma mark-

// Returns a reference to the preferred identity for DICOM TLS, or NULL if none was found.
// Call the CFRelease function to release this object when you are finished with it.
+ (SecIdentityRef)identityForLabel:(NSString*)label;
{
	return [DDKeychain KeychainAccessPreferredIdentityForName:label keyUse:CSSM_KEYUSE_ANY];
}

+ (NSString*)certificateNameForLabel:(NSString*)label;
{
	SecIdentityRef identity = [DDKeychain identityForLabel:label];
	
	NSString *name = nil;
	if(identity)
	{
		name = [DDKeychain KeychainAccessCertificateCommonNameForIdentity:identity];
		CFRelease(identity);
	}
	
	return name;
}

+ (NSImage*)certificateIconForLabel:(NSString*)label;
{
	SecIdentityRef identity = [DDKeychain identityForLabel:label];
	
	NSImage *icon = nil;
	if(identity)
	{
		icon = [DDKeychain KeychainAccessCertificateIconForIdentity:identity];
		CFRelease(identity);
	}
	
	return icon;
}

+ (void)openCertificatePanelForLabel:(NSString*)label;
{
	SecIdentityRef identity = [DDKeychain identityForLabel:label];
	if(identity)
	{
		[DDKeychain KeychainAccessOpenCertificatePanelForIdentity:identity];
		CFRelease(identity);
	}
}

#pragma mark Other Utilities

+ (void)generatePseudoRandomFileToPath:(NSString*)path;
{
	NSPoint mouseLocation = [NSEvent mouseLocation];
	NSTimeInterval time = [[NSDate date] timeIntervalSince1970];

	NSString *string = [NSString stringWithFormat:@"%f%f%lf", mouseLocation.x, mouseLocation.y, time];
	[string writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

+ (void)lockFile:(NSString*)path;
{
	if(!lockedFiles) lockedFiles = [[NSMutableDictionary dictionary] retain];
	
	@synchronized( lockedFiles)
	{
		int n=0;
		
		if([[lockedFiles allKeys] containsObject:path])
		{
			n = [(NSNumber*)[lockedFiles objectForKey:path] intValue];
		}
		
		[lockedFiles setObject:[NSNumber numberWithInt:n+1] forKey:path];
		NSLog(@"lockFile: %d %@", n+1, path);
	}
}

+ (void)unlockFile:(NSString*)path;
{	
	@synchronized( lockedFiles)
	{
		int n=0;
		
		if(lockedFiles)
		{
			if([[lockedFiles allKeys] containsObject:path])
			{
				n = [(NSNumber*)[lockedFiles objectForKey:path] intValue];
				n--;
				[lockedFiles setObject:[NSNumber numberWithInt:n] forKey:path];
				NSLog(@"unlockFile: %d %@", n, path);
			}
		}
		
		if(n==0)
		{
			[lockedFiles removeObjectForKey:path];
			//[[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
			//NSLog(@"removeItemAtPath: %@", path);
		}
	}
}

+ (void)lockTmpFiles;
{
	if(!lockFile) lockFile = [[NSRecursiveLock alloc] init];
	
	[lockFile lock];
}

+ (void)unlockTmpFiles;
{
	[lockFile unlock];
	//NSString *cmd = [NSString stringWithFormat:@"rm %@* %@*", TLS_PRIVATE_KEY_FILE, TLS_CERTIFICATE_FILE];
	//system([cmd cStringUsingEncoding:NSUTF8StringEncoding]);
}


@end
