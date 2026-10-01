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
/*
 Copyright (c) 2003-2006, Septicus Software All rights reserved.
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are
 met:
 
 * Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer. 
 * Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in the
 documentation and/or other materials provided with the distribution. 
 * Neither the name of Septicus Software nor the names of its contributors
 may be used to endorse or promote products derived from this software
 without specific prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
 IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
 TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
 PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER
 OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
 NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */
//
//  SSCrypto.m
//  SimpleWebCam
//
//  Created by Ed Silva on Sat May 31 2003.
//  Copyright (c) 2003-2006 Septicus Software. All rights reserved.
//

#import "SSCrypto.h"
#import <openssl/provider.h>
#import <openssl/core_names.h>
#include <limits.h>

// OpenSSL 3 keeps older SSCrypto algorithms (notably its default Blowfish)
// in a provider. Load that provider only into a private per-operation context:
// legacy report/plugin compatibility must not enable it for DICOM TLS.
@interface SSCryptoAlgorithm : NSObject {
    OSSL_LIB_CTX *library;
    OSSL_PROVIDER *legacy;
    EVP_CIPHER *cipher;
    EVP_MD *digest;
}
+ (instancetype)cipherNamed:(NSString *)name;
+ (instancetype)digestNamed:(NSString *)name;
- (const EVP_CIPHER *)cipher;
- (const EVP_MD *)digest;
- (BOOL)loadLegacy;
@end

@implementation SSCryptoAlgorithm
- (BOOL)loadLegacy {
    library = OSSL_LIB_CTX_new();
    if (library) legacy = OSSL_PROVIDER_load(library, "legacy");
    return legacy != NULL;
}
+ (instancetype)cipherNamed:(NSString *)name {
    SSCryptoAlgorithm *result = [[[self alloc] init] autorelease];
    int marked = ERR_set_mark();
    result->cipher = EVP_CIPHER_fetch(NULL, name.UTF8String, NULL);
    if (!result->cipher) {
        if (marked) ERR_pop_to_mark(); else ERR_clear_error();
        if ([result loadLegacy]) result->cipher = EVP_CIPHER_fetch(result->library, name.UTF8String, NULL);
    } else if (marked) ERR_clear_last_mark();
    return result;
}
+ (instancetype)digestNamed:(NSString *)name {
    SSCryptoAlgorithm *result = [[[self alloc] init] autorelease];
    int marked = ERR_set_mark();
    result->digest = EVP_MD_fetch(NULL, name.UTF8String, NULL);
    if (!result->digest) {
        if (marked) ERR_pop_to_mark(); else ERR_clear_error();
        if ([result loadLegacy]) result->digest = EVP_MD_fetch(result->library, name.UTF8String, NULL);
    } else if (marked) ERR_clear_last_mark();
    return result;
}
- (const EVP_CIPHER *)cipher { return cipher; }
- (const EVP_MD *)digest { return digest; }
- (void)dealloc {
    EVP_CIPHER_free(cipher);
    EVP_MD_free(digest);
    if (legacy) OSSL_PROVIDER_unload(legacy);
    OSSL_LIB_CTX_free(library);
    [super dealloc];
}
@end

// These operations intentionally retain the historical RSA PKCS#1 v1.5 wire
// format. In particular, sign/verify recover raw payloads rather than adding a
// digest or DigestInfo that older callers never supplied.
typedef NS_ENUM(NSUInteger, SSCryptoRSAOperation) {
    SSCryptoRSAEncrypt, SSCryptoRSADecrypt, SSCryptoRSASign, SSCryptoRSARecover
};

static EVP_PKEY *SSCryptoReadRSAKey(NSData *data, BOOL privateKey)
{
    if (!data.length || data.length > INT_MAX) return NULL;
    BIO *bio = BIO_new_mem_buf(data.bytes, (int)data.length);
    if (!bio) return NULL;
    EVP_PKEY *key = privateKey ? PEM_read_bio_PrivateKey(bio, NULL, NULL, NULL)
                               : PEM_read_bio_PUBKEY(bio, NULL, NULL, NULL);
    BIO_free(bio);
    if (!key) return NULL;
    BOOL valid = EVP_PKEY_is_a(key, "RSA") == 1;
    if (valid && privateKey) {
        EVP_PKEY_CTX *check = EVP_PKEY_CTX_new_from_pkey(NULL, key, NULL);
        valid = check && EVP_PKEY_private_check(check) == 1;
        EVP_PKEY_CTX_free(check);
    }
    if (!valid) { EVP_PKEY_free(key); return NULL; }
    return key;
}

static NSData *SSCryptoRSAData(NSData *input, NSData *keyData, SSCryptoRSAOperation operation)
{
    if (!input.length) return nil;
    BOOL privateKey = operation == SSCryptoRSADecrypt || operation == SSCryptoRSASign;
    EVP_PKEY *key = SSCryptoReadRSAKey(keyData, privateKey);
    if (!key) return nil;
    EVP_PKEY_CTX *context = EVP_PKEY_CTX_new_from_pkey(NULL, key, NULL);
    NSData *result = nil;
    if (context) {
        int (*initialize)(EVP_PKEY_CTX *) = NULL;
        int (*transform)(EVP_PKEY_CTX *, unsigned char *, size_t *, const unsigned char *, size_t) = NULL;
        switch (operation) {
            case SSCryptoRSAEncrypt: initialize = EVP_PKEY_encrypt_init; transform = EVP_PKEY_encrypt; break;
            case SSCryptoRSADecrypt: initialize = EVP_PKEY_decrypt_init; transform = EVP_PKEY_decrypt; break;
            case SSCryptoRSASign: initialize = EVP_PKEY_sign_init; transform = EVP_PKEY_sign; break;
            case SSCryptoRSARecover: initialize = EVP_PKEY_verify_recover_init; transform = EVP_PKEY_verify_recover; break;
        }
        size_t length = 0;
        BOOL ready = initialize(context) > 0 && EVP_PKEY_CTX_set_rsa_padding(context, RSA_PKCS1_PADDING) > 0;
        if (ready && operation == SSCryptoRSADecrypt) {
            // Existing callers receive nil on malformed PKCS#1 padding and must
            // never publish OpenSSL's implicit-rejection synthetic plaintext.
            unsigned int implicitRejection = 0;
            OSSL_PARAM parameters[] = {
                OSSL_PARAM_construct_uint(OSSL_ASYM_CIPHER_PARAM_IMPLICIT_REJECTION, &implicitRejection),
                OSSL_PARAM_construct_end()
            };
            ready = EVP_PKEY_CTX_set_params(context, parameters) > 0;
        }
        if (ready && transform(context, NULL, &length, input.bytes, input.length) > 0) {
            NSMutableData *output = [NSMutableData dataWithLength:length];
            if (transform(context, output.mutableBytes, &length, input.bytes, input.length) > 0 && length > 0) {
                output.length = length;
                result = output;
            }
        }
    }
    EVP_PKEY_CTX_free(context);
    EVP_PKEY_free(key);
    return result;
}

static NSData *SSCryptoRSAKeyPEM(EVP_PKEY *key, BOOL privateKey)
{
    BIO *bio = BIO_new(BIO_s_mem());
    if (!bio) return nil;
    // Keep RSA PRIVATE KEY (PKCS#1), not PKCS#8, and PUBLIC KEY (SPKI).
    int written = privateKey ? PEM_write_bio_PrivateKey_traditional(bio, key, NULL, NULL, 0, NULL, NULL)
                             : PEM_write_bio_PUBKEY(bio, key);
    char *bytes = NULL;
    long length = written ? BIO_get_mem_data(bio, &bytes) : 0;
    NSData *result = length > 0 ? [NSData dataWithBytes:bytes length:(NSUInteger)length] : nil;
    BIO_free(bio);
    return result;
}

static NSData *SSCryptoSymmetricData(NSData *input, NSData *password, NSData *salt,
                                     NSString *name, BOOL encrypt)
{
    if (input.length > INT_MAX || password.length > INT_MAX) return nil;
    const EVP_CIPHER *cipher = [[SSCryptoAlgorithm cipherNamed:name ?: @"BF-CBC"] cipher];
    if (!cipher) return nil;
    unsigned char key[EVP_MAX_KEY_LENGTH] = {0}, iv[EVP_MAX_IV_LENGTH] = {0};
    // Keep the legacy file/key derivation, so existing encrypted values reopen.
    if (!EVP_BytesToKey(cipher, EVP_md5(), salt.bytes, password.bytes,
                       (int)password.length, 1, key, iv)) return nil;
    EVP_CIPHER_CTX *context = EVP_CIPHER_CTX_new();
    if (!context) return nil;
    @try {
        if (!EVP_CipherInit_ex(context, cipher, NULL, key, iv, encrypt)) return nil;
        int blockSize = EVP_CIPHER_CTX_get_block_size(context);
        if (blockSize < 1) return nil;
        // Finalization can append a whole padding block even when the input
        // is block-aligned. The old encrypt allocation was one byte short.
        NSMutableData *output = [NSMutableData dataWithLength:input.length + (NSUInteger)blockSize];
        int written = 0, final = 0;
        if (!EVP_CipherUpdate(context, output.mutableBytes, &written, input.bytes, (int)input.length) ||
            !EVP_CipherFinal_ex(context, (unsigned char *)output.mutableBytes + written, &final)) return nil;
        output.length = (NSUInteger)written + (NSUInteger)final;
        return output;
    } @finally {
        EVP_CIPHER_CTX_free(context);
    }
}

@implementation NSData (HexDump)

/**
 * Encodes the current data in base64, and creates and returns an NSString from the result.
 * This is the same as piping data through "... | openssl enc -base64" on the command line.
 *
 * Code courtesy of DaveDribin (http://www.dribin.org/dave/)
 * Taken from http://www.cocoadev.com/index.pl?BaseSixtyFour
**/
- (NSString *)encodeBase64
{
    return [self encodeBase64WithNewlines: YES];
}

/**
 * Encodes the current data in base64, and creates and returns an NSString from the result.
 * This is the same as piping data through "... | openssl enc -base64" on the command line.
 *
 * Code courtesy of DaveDribin (http://www.dribin.org/dave/)
 * Taken from http://www.cocoadev.com/index.pl?BaseSixtyFour
**/
- (NSString *)encodeBase64WithNewlines:(BOOL)encodeWithNewlines
{
    // Create a memory buffer which will contain the Base64 encoded string
    BIO * mem = BIO_new(BIO_s_mem());
    
    // Push on a Base64 filter so that writing to the buffer encodes the data
    BIO * b64 = BIO_new(BIO_f_base64());
    if (!encodeWithNewlines)
        BIO_set_flags(b64, BIO_FLAGS_BASE64_NO_NL);
    mem = BIO_push(b64, mem);
    
    // Encode all the data
    BIO_write(mem, [self bytes], [self length]);
    BIO_flush(mem);
    
    // Create a new string from the data in the memory buffer
    char * base64Pointer;
    long base64Length = BIO_get_mem_data(mem, &base64Pointer);
	
	// The base64pointer is NOT null terminated.
	
	NSData * base64data = [NSData dataWithBytesNoCopy:base64Pointer length:base64Length freeWhenDone:NO];
	NSString * base64String = [[NSString alloc] initWithData:base64data encoding:NSUTF8StringEncoding];

    // Clean up and go home
	BIO_free_all(mem);
	return [base64String autorelease];
}

- (NSData *)decodeBase64
{
    return [self decodeBase64WithNewLines:YES];
}

- (NSData *)decodeBase64WithNewLines:(BOOL)encodedWithNewlines
{
    // Create a memory buffer containing Base64 encoded string data
    BIO * mem = BIO_new_mem_buf((void *) [self bytes], [self length]);

    // Push a Base64 filter so that reading from the buffer decodes it
    BIO * b64 = BIO_new(BIO_f_base64());
    if (!encodedWithNewlines)
        BIO_set_flags(b64, BIO_FLAGS_BASE64_NO_NL);
    mem = BIO_push(b64, mem);

    // Decode into an NSMutableData
    NSMutableData * data = [NSMutableData data];
    char inbuf[512];
    int inlen;
    while ((inlen = BIO_read(mem, inbuf, sizeof(inbuf))) > 0)
        [data appendBytes: inbuf length: inlen];

    // Clean up and go home
    BIO_free_all(mem);
    return data;
}

- (NSString *)hexval
{
    NSMutableString *hex = [NSMutableString string];
    unsigned char *bytes = (unsigned char *)[self bytes];
    char temp[3];
    int i = 0;

    for (i = 0; i < [self length]; i++) {
        temp[0] = temp[1] = temp[2] = 0;
        (void)snprintf(temp, sizeof(temp), "%02x", bytes[i]);
        [hex appendString:[NSString stringWithUTF8String:temp]];
    }

    return hex;
}

- (NSString *)hexdump
{
    NSMutableString *ret=[NSMutableString stringWithCapacity:[self length]*2];
    /* dumps size bytes of *data to string. Looks like:
    * [0000] 75 6E 6B 6E 6F 77 6E 20
    *                  30 FF 00 00 00 00 39 00 unknown 0.....9.
    * (in a single line of course)
    */
    unsigned int size= [self length];
    const unsigned char *p = [self bytes];
    unsigned char c;
    int n;
    char bytestr[4] = {0};
    char addrstr[10] = {0};
    char hexstr[ 16*3 + 5] = {0};
    char charstr[16*1 + 5] = {0};
    for(n=1;n<=size;n++) {
        if (n%16 == 1) {
            /* store address for this line */
            snprintf(addrstr, sizeof(addrstr), "%.4x",
                     (unsigned int)((long)p-(long)self) );
        }
        
        c = *p;
        if (isalnum(c) == 0) {
            c = '.';
        }
        
        /* store hex str (for left side) */
        snprintf(bytestr, sizeof(bytestr), "%02X ", *p);
        strncat(hexstr, bytestr, sizeof(hexstr)-strlen(hexstr)-1);
        
        /* store char str (for right side) */
        snprintf(bytestr, sizeof(bytestr), "%c", c);
        strncat(charstr, bytestr, sizeof(charstr)-strlen(charstr)-1);
        
        if(n%16 == 0) {
            /* line completed */
            //printf("[%4.4s]   %-50.50s  %s\n", addrstr, hexstr, charstr);
            [ret appendString:[NSString stringWithFormat:@"[%4.4s]   %-50.50s  %s\n",
                addrstr, hexstr, charstr]];
            hexstr[0] = 0;
            charstr[0] = 0;
        } else if(n%8 == 0) {
            /* half line: add whitespaces */
            strncat(hexstr, "  ", sizeof(hexstr)-strlen(hexstr)-1);
            strncat(charstr, " ", sizeof(charstr)-strlen(charstr)-1);
        }
        p++; /* next byte */
    }
    
    if (strlen(hexstr) > 0) {
        /* print rest of buffer if not empty */
        //printf("[%4.4s]   %-50.50s  %s\n", addrstr, hexstr, charstr);
        [ret appendString:[NSString stringWithFormat:@"[%4.4s]   %-50.50s  %s\n",
            addrstr, hexstr, charstr]];
    }
    return ret;
}

@end

@interface SSCrypto (PrivateAPI)
- (void)setupOpenSSL;
- (void)cleanupOpenSSL;
@end

// SSCrypto object
@implementation SSCrypto

/**
 * Generic constructor.
 * Simply configures internal OpenSSL setup.
**/
- (id)init
{
    if((self = [super init]))
	{
        // Call private method to handle the setup for internal OpenSSL stuff
		[self setupOpenSSL];
    }
    return self;
}

/**
 * Symmetric key constructor.
 * Configures the instance to use symmetric encryption/decryption using the given symmetric key.
**/
- (id)initWithSymmetricKey:(NSData *)k
{
    if((self = [super init]))
	{
        // Call private method to handle the setup for internal OpenSSL stuff
		[self setupOpenSSL];
		
        [self setSymmetricKey:k];
        [self setIsSymmetric:YES];
    }
    return self;
}

/**
 * Public key only constructor.
 * Configures the instance to use non-symmetric encryption/decryption, and to use the given public key.
**/
- (id)initWithPublicKey:(NSData *)pub
{
    return [self initWithPublicKey:pub privateKey:nil];
}

/**
 * Private key only constructor.
 * Configures the instance to use non-symmetric encryption/decryption, and to use the given private key.
**/
- (id)initWithPrivateKey:(NSData *)priv
{
    return [self initWithPublicKey:nil privateKey:priv];
}

/**
 * Public and Private key constructor.
 * Configures the instance to use non-symmetric encryption/decryption, and to use the given public and private keys.
**/
- (id)initWithPublicKey:(NSData *)pub privateKey:(NSData *)priv;
{
    if((self = [super init]))
	{
		// Call private method to handle the setup for internal OpenSSL stuff
		[self setupOpenSSL];
		
		// Store the publicKey variable (if not nil)
		if(pub != nil)
			[self setPublicKey:pub];
		
		// Store the privateKey variable (if not nil)
		if(priv != nil)
			[self setPrivateKey:priv];
		
		// Since we're using public and private keys, we can assume we're not using symmetric encryption
		[self setIsSymmetric:NO];
    }
    return self;
}

/**
 * This method sets up everything needed to use the OpenSSL libraries later within the code.
 * This method should be called by every constructor.
**/
- (void)setupOpenSSL
{
	// OpenSSL keeps an internal table of digest algorithms and ciphers.
	// It uses this table to lookup ciphers via functions such as EVP_get_cipher_byname().
	// OpenSSL_add_all_digests() adds all digest algorithms to the table.
	// OpenSSL_add_all_ciphers() adds all cipher algorithms to the table.
	// OpenSSL_add_all_algorithms() adds all algorithms to the table (digests and ciphers).
	// EVP_cleanup() removes all ciphers and digests from the table.
	// 
	// A typical application will call OpenSSL_add_all_algorithms() initially and EVP_cleanup() before exiting.
	
	OpenSSL_add_all_algorithms();
	
	// ERR_load_crypto_strings() registers the error strings for all libcrypto functions.
	// SSL_load_error_strings() does the same, but also registers the libssl error strings.
	// ERR_free_strings() frees all previously loaded error strings.
	//
	// One of these functions should be called before generating textual error messages.
	// However, this is not required when memory usage is an issue.
	
	ERR_load_crypto_strings();
}

/**
 * Standard deallocation method.
**/
- (void)dealloc
{
    // Cleanup all OpenSSL stuff
	[self cleanupOpenSSL];
	
	// Release all instance variables
	[symmetricKey release];
	[cipherText release];
	[clearText release];
	[publicKey release];
	[privateKey release];
	
	// Move up the inheritance chain
    [super dealloc];
}

- (void)cleanupOpenSSL
{
	// EVP_cleanup() removes all ciphers and digests from the table.
	EVP_cleanup();
	
	// ERR_free_strings() frees all previously loaded error strings.
    ERR_free_strings();
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Getter, Setter Methods:
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * Returns whether or not symmetric encryption is to be used.
 * If symmetric encryption is in use, then calls to encrypt or decrypt operate using symmetric encryption/decryption.
 * Otherwise, it is assumed that asymmetric encryption/decryption is to be used.
**/
- (BOOL)isSymmetric
{
    return isSymmetric;
}

- (void)setIsSymmetric:(BOOL)flag
{
    isSymmetric = flag;
}

- (NSData *)symmetricKey
{
    return symmetricKey;
}

- (void)setSymmetricKey:(NSData *)k
{
    [k retain];
    [symmetricKey release];
    symmetricKey = k;
}

/**
 * Returns the public key currently in use.
**/
- (NSData *)publicKey
{
    return publicKey;
}

/**
 * Sets the public key to use.
 * Public keys are used to verify signed data, or to encrypt data. (ToDo)
**/
- (void)setPublicKey:(NSData *)k
{
    [k retain];
    [publicKey release];
    publicKey = k;
}

/**
 * Returns the private key currently in use.
**/
- (NSData *)privateKey
{
    return privateKey;
}

/**
 * Sets the private key to use.
 * Private keys are used to sign data, or to decrypt data. (ToDo)
 * 
 * The data that is provided should from a file (such as private.pem) that was generated by openssl.
**/
- (void)setPrivateKey:(NSData *)k
{
    [k retain];
    [privateKey release];
    privateKey = k;
}

/**
 * Returns the clear text as plain NSData.
 * The plain text contains the text that was previously set.
 * It's the known text, which is to be encrypted, decrypted, etc.
**/
- (NSData *)clearTextAsData
{
    return clearText;
}

/**
 * Returns the clear text formatted as an NSString.
 * The plain text contains the text that was previously set.
 * It's the known text, which is to be encrypted, decrypted, etc.
**/
- (NSString *)clearTextAsString
{
    return [[[NSString alloc] initWithData:[self clearTextAsData] encoding:NSUTF8StringEncoding] autorelease];
}

/**
 * Sets the clear text using the given data.
 * The clear text will be used for encryption, decryption, etc.
 *
 * Note that the given data reference is retained and later used, so it shouldn't be externally modified.
**/
- (void)setClearTextWithData:(NSData *)c
{
    [c retain];
    [clearText release];
    clearText = c;
}

/**
 * Sets the clear text using the given string.
 * The clear text will be used for encryption, signing, and digests.
**/
- (void)setClearTextWithString:(NSString *)c
{
	[clearText release];
    
	// BUG FIX : PLL (2009/02/21)
	//
	// [c length] : Returns the number of Unicode characters in the receiver.
	// For example "‚àö¬©‚àö‚Ä†‚àö√ü test" in UTF8 is 11 bytes (c3 a9 c3 a0 c3 a7 20 74 65 73 74)
	// but only 8 Unicode characters.
	// So this will truncate the text and result in one error.
	//
	// clearText = [[NSData alloc] initWithBytes:[c UTF8String] length:[c length]];
	
	// The number of bytes required to store the receiver in the encoding enc in a non-external representation. The length does not include space for a terminating NULL character.
	unsigned int length = [c lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
	clearText = [[NSData alloc] initWithBytes:[c UTF8String] length:length];
}

/**
 * Returns the cipher text as plain NSData.
 * The cipher text contains the most recent encrypted data.  (Result of call to encrypt)
**/
- (NSData *)cipherTextAsData
{
    return cipherText;
}

/**
 * Returns the ciper text formatted as an NSString.
 * The ciper text contains the most recent encrypted data.  (Result of call to encrypt)
**/
- (NSString *)cipherTextAsString
{
    return [[[NSString alloc] initWithData:[self cipherTextAsData] encoding:NSUTF8StringEncoding] autorelease];
}

/**
 * Sets the cipher text using the given data.
 * The cipher text will be used for decryption and verifying.
**/
- (void)setCipherText:(NSData *)c
{
    [c retain];
    [cipherText release];
    cipherText = c;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Decryption methods:
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * Peforms decryption, and returns resulting clear text data.
 * If symmetric decryption is being used, performs symmetric decryption using aes128.
 * Otherwise, performs decryption using the private key.
**/
- (NSData *)decrypt
{
    if([self isSymmetric] && [self symmetricKey])
	{
        return [self decrypt:@"aes128"];
    }
	else if([self privateKey])
	{
        return [self decrypt:nil];
    }
	else
	{
        NSLog(@"No symmetric key or private key is set!");
        return nil;
    }
}

/**
 * Decrypts the cipher text data.
 * If symmetric decryption is being used, then the decryption is done using the given cipher.
 * Otherwise, asymmetric decryptions is used, and the data is encrypted using the private key.
 *
 * Returns the clear text data that is the result of the decryption.
 * The resulting clear text data may also be later retrieved with the clearTextAsData or clearTextAsString methods.
**/
- (NSData *)decrypt:(NSString *)cipherName
{
    if (!cipherText.length) return nil;
    NSData *result;
    if ([self isSymmetric]) {
        NSData *salt = nil, *inputData = cipherText;
        if (cipherText.length > 16 && memcmp(cipherText.bytes, "Salted__", 8) == 0) {
            salt = [cipherText subdataWithRange:NSMakeRange(8, 8)];
            inputData = [cipherText subdataWithRange:NSMakeRange(16, cipherText.length - 16)];
        }
        result = SSCryptoSymmetricData(inputData, symmetricKey, salt, cipherName, NO);
    } else result = SSCryptoRSAData(cipherText, privateKey, SSCryptoRSADecrypt);
    if (result) [self setClearTextWithData:result];
    return result;
}

/**
 * Verifies (decrypts) the cipher text data using the public key.
 * The resulting clear text data is returned.
 *
 * The resulting clear text data may also be later retrieved with the clearTextAsData or clearTextAsString methods.
 **/
- (NSData *)verify
{
    NSData *result = SSCryptoRSAData(cipherText, publicKey, SSCryptoRSARecover);
    if (result) [self setClearTextWithData:result];
    return result;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Encryption methods:
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * Peforms encryption, and returns resulting ciper text data.
 * If symmetric encryption is being used, performs symmetric encryption using aes128.
 * Otherwise, performs encryption using the public key.
**/
- (NSData *)encrypt
{
    if([self isSymmetric] && [self symmetricKey])
	{
        return [self encrypt:@"aes128"];
    }
	else if([self publicKey])
	{
        return [self encrypt:nil];
    }
	else
	{
        NSLog(@"No symmetric key or public key is set!");
        return nil;
    }
}

/**
 * Encrypts the clear text data.
 * If symmetric encryption is being used, then the encryption is done using the given cipher.
 * Otherwise, asymmetric encryption is used, and the data is encrypted using the public key.
 *
 * Returns the cipher text data that is the result of the encryption.
 * The resulting cipher text data may also be later retrieved with the cipherTextAsData or cipherTextAsString methods.
**/
- (NSData *)encrypt:(NSString *)cipherName
{
    if (!clearText.length) return nil;
    NSData *result = [self isSymmetric]
        ? SSCryptoSymmetricData(clearText, symmetricKey, nil, cipherName, YES)
        : SSCryptoRSAData(clearText, publicKey, SSCryptoRSAEncrypt);
    if (result) [self setCipherText:result];
    return result;
}

/**
 * Signs (encrypts) the clear text data using the private key.
 * The resulting cipher text data is returned, and may later be verified (decrypted) using the public key.
 *
 * The resulting cipher text data may also be later retrieved with the cipherTextAsData or cipherTextAsString methods.
**/
- (NSData *)sign
{
    NSData *result = SSCryptoRSAData(clearText, privateKey, SSCryptoRSASign);
    if (result) [self setCipherText:result];
    return result;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Other methods:
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * Description forthcoming...
**/
- (NSData *)digest:(NSString *)digestName
{
    if(clearText == nil) {
        return nil;
    }

    unsigned char outbuf[EVP_MAX_MD_SIZE];
    unsigned int templen, inlen;
    unsigned char *input=(unsigned char*)[clearText bytes];
    EVP_MD_CTX *ctx;
    const EVP_MD *digest = NULL;
    
    inlen = [clearText length];
    
    if(inlen==0)
        return nil;
    digest = [[SSCryptoAlgorithm digestNamed:digestName ?: @"MD5"] digest];
    if (!digest) return nil;

    ctx = EVP_MD_CTX_new();
    if (!ctx) return nil;
    if (!EVP_DigestInit(ctx,digest)) { EVP_MD_CTX_free(ctx); return nil; }
    if(!EVP_DigestUpdate(ctx,input,inlen)) {
        NSLog(@"EVP_DigestUpdate() failed!");
        EVP_MD_CTX_free(ctx);
        return nil;			
    }
    if (!EVP_DigestFinal(ctx, outbuf, &templen)) {
        NSLog(@"EVP_DigesttFinal() failed!");
        EVP_MD_CTX_free(ctx);
        return nil;
    }
    EVP_MD_CTX_free(ctx);
    
    return [NSData dataWithBytes:outbuf length:templen];
}

- (NSString *)description
{
    NSString *format = @"clearText: %@, cipherText: %@, symmetricKey: %@, publicKey: %@, privateKey: %@";
    NSString *desc = [NSString stringWithFormat:format, [clearText hexdump], [cipherText hexdump],
        [symmetricKey hexdump], [publicKey hexdump], [privateKey hexdump]];
    return desc;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Class methods:
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

+ (NSData *)generateRSAPrivateKeyWithLength:(int)length
{
    EVP_PKEY_CTX *context = EVP_PKEY_CTX_new_from_name(NULL, "RSA", NULL);
    if (!context) return nil;
    EVP_PKEY *key = NULL;
    NSData *result = nil;
    // The RSA provider defaults to exponent 65537, the historical RSA_F4.
    if (EVP_PKEY_keygen_init(context) > 0 && EVP_PKEY_CTX_set_rsa_keygen_bits(context, length) > 0 &&
        EVP_PKEY_generate(context, &key) > 0) result = SSCryptoRSAKeyPEM(key, YES);
    EVP_PKEY_free(key);
    EVP_PKEY_CTX_free(context);
    return result;
}

+ (NSData *)generateRSAPublicKeyFromPrivateKey:(NSData *)privateKey
{
    EVP_PKEY *key = SSCryptoReadRSAKey(privateKey, YES);
    if (!key) return nil;
    NSData *result = SSCryptoRSAKeyPEM(key, NO);
    EVP_PKEY_free(key);
    return result;
}

+ (NSData *)getKeyDataWithLength:(int)length
{
    NSData *randData = nil;
    unsigned char *buffer;
    
    buffer = (unsigned char *)calloc(length*4, sizeof(unsigned char));
    NSAssert((buffer != NULL), @"Cannot calloc memory for buffer.");
    
    if (!RAND_bytes(buffer, length)){
        free(buffer);
    }

    randData = [NSData dataWithBytes:buffer length:length];
    free(buffer);
    
    return randData;
}

// PBKDF2 support functions
// Thanks to Chris Benedict (chrisbdaemon@gmail.com) for the code
+ (NSData *)getKeyDataWithLength:(int)length fromPassword:(NSString *)pass withSalt:(NSString *)salt
{
	return [SSCrypto getKeyDataWithLength:length fromPassword:pass withSalt:salt withIterations:1000];
}

+ (NSData *)getKeyDataWithLength:(int)length fromPassword:(NSString *)pass withSalt:(NSString *)salt withIterations:(int)count
{
	NSData *key = nil;
	unsigned char *buffer = (unsigned char *)calloc(length, sizeof(unsigned char));
    NSAssert((buffer != NULL), @"Cannot calloc memory for buffer.");
	const char *password = [pass UTF8String];
    const char *saltVal = [salt UTF8String];

	if(!PKCS5_PBKDF2_HMAC_SHA1(password, [pass length], (unsigned char *)saltVal, [salt length], count, length, buffer)) {
		return nil;
	}

	key = [NSData dataWithBytes:buffer length:length];
	free(buffer);
	
	return key;
}

+ (NSData *)getSHA1ForData:(NSData *)d
{
    unsigned length = [d length];
    const void *buffer = [d bytes];
    unsigned char *md = (unsigned char *)calloc(SHA_DIGEST_LENGTH, sizeof(unsigned char));
    NSAssert((md != NULL), @"Cannot calloc memory for buffer.");

    (void)SHA1(buffer, length, md);

    return [NSData dataWithBytesNoCopy:md length:SHA_DIGEST_LENGTH freeWhenDone:YES];
}

+ (NSData *)getMD5ForData:(NSData *)d
{
    unsigned char bytes[EVP_MAX_MD_SIZE];
    unsigned int length = 0;
    if (!EVP_Digest(d.bytes, d.length, bytes, &length, EVP_md5(), NULL)) return nil;
    return [NSData dataWithBytes:bytes length:length];
}

@end
