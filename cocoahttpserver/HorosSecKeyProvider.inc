// Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
// This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
// Distributed under the GNU Lesser General Public License, version 3.
// No warranty; see the GNU Lesser General Public License for details.
// Private C ABI callbacks: Security owns private keys; OpenSSL sees only public
// material.
#include <openssl/core_dispatch.h>
#include <openssl/core_names.h>
#include <openssl/err.h>
#include <openssl/params.h>
#include <openssl/provider.h>
#include <openssl/rsa.h>
#include <openssl/ssl.h>

typedef struct {
  SecKeyRef secret;
  EVP_PKEY *publicKey;
  int rsa;
} HorosTLSKey;
static void *HorosKeyNewRSA(void *ctx) {
  (void)ctx;
  HorosTLSKey *k = calloc(1, sizeof(*k));
  if (k)
    k->rsa = 1;
  return k;
}
static void *HorosKeyNewEC(void *ctx) {
  (void)ctx;
  return calloc(1, sizeof(HorosTLSKey));
}
static void HorosKeyFree(void *data) {
  HorosTLSKey *k = data;
  if (!k)
    return;
  if (k->secret)
    CFRelease(k->secret);
  EVP_PKEY_free(k->publicKey);
  free(k);
}
static void *HorosKeyDup(const void *data, int selection) {
  const HorosTLSKey *src = data;
  if (!src)
    return NULL;
  HorosTLSKey *k = calloc(1, sizeof(*k));
  if (!k)
    return NULL;
  k->rsa = src->rsa;
  if ((selection & OSSL_KEYMGMT_SELECT_PRIVATE_KEY) && src->secret)
    k->secret = (SecKeyRef)CFRetain(src->secret);
  if (src->publicKey) {
    k->publicKey = src->publicKey;
    EVP_PKEY_up_ref(k->publicKey);
  }
  return k;
}
static int HorosKeyHas(const void *data, int selection) {
  const HorosTLSKey *k = data;
  return (!(selection & OSSL_KEYMGMT_SELECT_PRIVATE_KEY) || k->secret) &&
         (!(selection & (OSSL_KEYMGMT_SELECT_PUBLIC_KEY |
                         OSSL_KEYMGMT_SELECT_DOMAIN_PARAMETERS)) ||
          k->publicKey);
}
static int HorosKeyMatch(const void *a, const void *b, int selection) {
  const HorosTLSKey *ka = a, *kb = b;
  (void)selection;
  return ka->publicKey && kb->publicKey &&
         EVP_PKEY_eq(ka->publicKey, kb->publicKey) == 1;
}
static int HorosKeyParams(void *data, OSSL_PARAM p[]) {
  HorosTLSKey *k = data;
  return k->publicKey && EVP_PKEY_get_params(k->publicKey, p);
}
static const OSSL_PARAM HorosKeyParamTypes[] = {
    OSSL_PARAM_int(OSSL_PKEY_PARAM_BITS, NULL),
    OSSL_PARAM_int(OSSL_PKEY_PARAM_SECURITY_BITS, NULL),
    OSSL_PARAM_int(OSSL_PKEY_PARAM_MAX_SIZE, NULL),
    OSSL_PARAM_utf8_string(OSSL_PKEY_PARAM_DEFAULT_DIGEST, NULL, 0),
    OSSL_PARAM_utf8_string(OSSL_PKEY_PARAM_GROUP_NAME, NULL, 0),
    OSSL_PARAM_octet_string(OSSL_PKEY_PARAM_ENCODED_PUBLIC_KEY, NULL, 0),
    OSSL_PARAM_END};
static const OSSL_PARAM *HorosKeyGettable(void *ctx) {
  (void)ctx;
  return HorosKeyParamTypes;
}
static const char *HorosRSAOperation(int op) {
  return op == OSSL_OP_SIGNATURE ? "RSA" : NULL;
}
static const char *HorosECOperation(int op) {
  return op == OSSL_OP_SIGNATURE ? "ECDSA" : NULL;
}
static const OSSL_PARAM HorosKeyImportTypes[] = {
    OSSL_PARAM_octet_string("horos-seckey", NULL, 0),
    OSSL_PARAM_octet_string("horos-public", NULL, 0),
    OSSL_PARAM_BN(OSSL_PKEY_PARAM_RSA_N, NULL, 0),
    OSSL_PARAM_BN(OSSL_PKEY_PARAM_RSA_E, NULL, 0),
    OSSL_PARAM_utf8_string(OSSL_PKEY_PARAM_GROUP_NAME, NULL, 0),
    OSSL_PARAM_octet_string(OSSL_PKEY_PARAM_PUB_KEY, NULL, 0),
    OSSL_PARAM_END};
static const OSSL_PARAM *HorosKeyTypes(int selection) {
  (void)selection;
  return HorosKeyImportTypes;
}
static int HorosKeyImport(void *data, int selection, const OSSL_PARAM p[]) {
  HorosTLSKey *k = data;
  const OSSL_PARAM *s = OSSL_PARAM_locate_const(p, "horos-seckey"),
                   *pub = OSSL_PARAM_locate_const(p, "horos-public");
  if (s && pub && s->data_type == OSSL_PARAM_OCTET_STRING &&
      pub->data_type == OSSL_PARAM_OCTET_STRING &&
      s->data_size == sizeof(SecKeyRef) &&
      pub->data_size == sizeof(EVP_PKEY *)) {
    SecKeyRef secret = NULL;
    EVP_PKEY *publicKey = NULL;
    memcpy(&secret, s->data, sizeof(secret));
    memcpy(&publicKey, pub->data, sizeof(publicKey));
    if (!secret || !publicKey || !(selection & OSSL_KEYMGMT_SELECT_PRIVATE_KEY))
      return 0;
    if (EVP_PKEY_is_a(publicKey, k->rsa ? "RSA" : "EC") != 1)
      return 0;
    CFRetain(secret);
    EVP_PKEY_up_ref(publicKey);
    if (k->secret)
      CFRelease(k->secret);
    EVP_PKEY_free(k->publicKey);
    k->secret = secret;
    k->publicKey = publicKey;
    return 1;
  }
  if (selection & OSSL_KEYMGMT_SELECT_PRIVATE_KEY)
    return 0;
  EVP_PKEY_CTX *ctx = EVP_PKEY_CTX_new_from_name(NULL, k->rsa ? "RSA" : "EC",
                                                 "provider=default");
  EVP_PKEY *publicKey = NULL;
  int ok = ctx && EVP_PKEY_fromdata_init(ctx) > 0 &&
           EVP_PKEY_fromdata(ctx, &publicKey, selection, (OSSL_PARAM *)p) > 0;
  EVP_PKEY_CTX_free(ctx);
  if (ok) {
    EVP_PKEY_free(k->publicKey);
    k->publicKey = publicKey;
  } else
    EVP_PKEY_free(publicKey);
  return ok;
}
static const OSSL_PARAM HorosRSAExportTypes[] = {
    OSSL_PARAM_BN(OSSL_PKEY_PARAM_RSA_N, NULL, 0),
    OSSL_PARAM_BN(OSSL_PKEY_PARAM_RSA_E, NULL, 0), OSSL_PARAM_END};
static const OSSL_PARAM HorosECExportTypes[] = {
    OSSL_PARAM_utf8_string(OSSL_PKEY_PARAM_GROUP_NAME, NULL, 0),
    OSSL_PARAM_octet_string(OSSL_PKEY_PARAM_PUB_KEY, NULL, 0), OSSL_PARAM_END};
static const OSSL_PARAM *HorosRSAExport(int selection) {
  return selection & OSSL_KEYMGMT_SELECT_PRIVATE_KEY ? NULL
                                                     : HorosRSAExportTypes;
}
static const OSSL_PARAM *HorosECExport(int selection) {
  return selection & OSSL_KEYMGMT_SELECT_PRIVATE_KEY ? NULL
                                                     : HorosECExportTypes;
}
static int HorosKeyExport(void *data, int selection, OSSL_CALLBACK *cb,
                          void *arg) {
  HorosTLSKey *k = data;
  if (!k->publicKey || (selection & OSSL_KEYMGMT_SELECT_PRIVATE_KEY))
    return 0;
  OSSL_PARAM *p = NULL;
  int ok = EVP_PKEY_todata(k->publicKey, selection, &p) > 0;
  if (ok)
    ok = cb(p, arg);
  OSSL_PARAM_free(p);
  return ok;
}
typedef struct {
  HorosTLSKey *key;
  NSMutableData *message;
  char digest[64], mgf[64];
  int padding, salt;
} HorosTLSSign;
static void *HorosSignNew(void *ctx, const char *propq) {
  (void)ctx;
  (void)propq;
  HorosTLSSign *s = calloc(1, sizeof(*s));
  if (s) {
    s->padding = RSA_PKCS1_PADDING;
    s->salt = RSA_PSS_SALTLEN_DIGEST;
    s->message = [[NSMutableData alloc] init];
  }
  return s;
}
static void HorosSignFree(void *data) {
  HorosTLSSign *s = data;
  if (!s)
    return;
  HorosKeyFree(s->key);
  [s->message release];
  free(s);
}
static void *HorosSignDup(void *data) {
  HorosTLSSign *s = data, *d = malloc(sizeof(*d));
  if (!d)
    return NULL;
  *d = *s;
  d->key = HorosKeyDup(s->key, OSSL_KEYMGMT_SELECT_ALL);
  if (s->key && !d->key) {
    free(d);
    return NULL;
  }
  d->message = [s->message mutableCopy];
  return d;
}
static int HorosParamText(const OSSL_PARAM *p, char *out, size_t n) {
  if (!p)
    return 1;
  char *t = out;
  return OSSL_PARAM_get_utf8_string(p, &t, n);
}
static int HorosSignSet(void *data, const OSSL_PARAM p[]) {
  HorosTLSSign *s = data;
  if (!p)
    return 1;
  const OSSL_PARAM *v;
  if (!HorosParamText(OSSL_PARAM_locate_const(p, OSSL_SIGNATURE_PARAM_DIGEST),
                      s->digest, sizeof(s->digest)) ||
      !HorosParamText(
          OSSL_PARAM_locate_const(p, OSSL_SIGNATURE_PARAM_MGF1_DIGEST), s->mgf,
          sizeof(s->mgf)))
    return 0;
  if ((v = OSSL_PARAM_locate_const(p, OSSL_SIGNATURE_PARAM_PAD_MODE))) {
    if (v->data_type == OSSL_PARAM_UTF8_STRING) {
      char text[32] = {0};
      if (!HorosParamText(v, text, sizeof(text)))
        return 0;
      if (!strcmp(text, OSSL_PKEY_RSA_PAD_MODE_PKCSV15))
        s->padding = RSA_PKCS1_PADDING;
      else if (!strcmp(text, OSSL_PKEY_RSA_PAD_MODE_PSS))
        s->padding = RSA_PKCS1_PSS_PADDING;
      else
        return 0;
    } else if (!OSSL_PARAM_get_int(v, &s->padding))
      return 0;
  }
  if ((v = OSSL_PARAM_locate_const(p, OSSL_SIGNATURE_PARAM_PSS_SALTLEN))) {
    if (v->data_type == OSSL_PARAM_UTF8_STRING) {
      char text[32] = {0};
      if (!HorosParamText(v, text, sizeof(text)))
        return 0;
      if (!strcmp(text, "digest"))
        s->salt = RSA_PSS_SALTLEN_DIGEST;
      else {
        char *end;
        long n = strtol(text, &end, 10);
        if (*end || n < 0 || n > INT_MAX)
          return 0;
        s->salt = (int)n;
      }
    } else if (!OSSL_PARAM_get_int(v, &s->salt))
      return 0;
  }
  return 1;
}
static int HorosSignInit(void *data, void *key, const OSSL_PARAM p[]) {
  HorosTLSSign *s = data;
  HorosKeyFree(s->key);
  s->key = HorosKeyDup(key, OSSL_KEYMGMT_SELECT_ALL);
  [s->message setLength:0];
  return s->key && s->key->secret && HorosSignSet(s, p);
}
static int HorosDigestInit(void *data, const char *md, void *key,
                           const OSSL_PARAM p[]) {
  HorosTLSSign *s = data;
  if (md) {
    if (strlen(md) >= sizeof(s->digest))
      return 0;
    memcpy(s->digest, md, strlen(md) + 1);
  }
  return HorosSignInit(data, key, p);
}
static int HorosDigestBits(const char *d) {
  if (!strcasecmp(d, "SHA256") || !strcasecmp(d, "SHA2-256"))
    return 256;
  if (!strcasecmp(d, "SHA384") || !strcasecmp(d, "SHA2-384"))
    return 384;
  if (!strcasecmp(d, "SHA512") || !strcasecmp(d, "SHA2-512"))
    return 512;
  return 0;
}
static SecKeyAlgorithm HorosSignAlgorithm(HorosTLSSign *s, int message) {
  int bits = HorosDigestBits(s->digest);
  if (!bits)
    return NULL;
  if (!s->key->rsa) {
    if (bits == 256)
      return message ? kSecKeyAlgorithmECDSASignatureMessageX962SHA256
                     : kSecKeyAlgorithmECDSASignatureDigestX962SHA256;
    if (bits == 384)
      return message ? kSecKeyAlgorithmECDSASignatureMessageX962SHA384
                     : kSecKeyAlgorithmECDSASignatureDigestX962SHA384;
    return message ? kSecKeyAlgorithmECDSASignatureMessageX962SHA512
                   : kSecKeyAlgorithmECDSASignatureDigestX962SHA512;
  }
  if (s->padding == RSA_PKCS1_PSS_PADDING) {
    if (s->salt != RSA_PSS_SALTLEN_DIGEST && s->salt != bits / 8)
      return NULL;
    if (s->mgf[0] && HorosDigestBits(s->mgf) != bits)
      return NULL;
    if (bits == 256)
      return message ? kSecKeyAlgorithmRSASignatureMessagePSSSHA256
                     : kSecKeyAlgorithmRSASignatureDigestPSSSHA256;
    if (bits == 384)
      return message ? kSecKeyAlgorithmRSASignatureMessagePSSSHA384
                     : kSecKeyAlgorithmRSASignatureDigestPSSSHA384;
    return message ? kSecKeyAlgorithmRSASignatureMessagePSSSHA512
                   : kSecKeyAlgorithmRSASignatureDigestPSSSHA512;
  }
  if (s->padding != RSA_PKCS1_PADDING)
    return NULL;
  if (bits == 256)
    return message ? kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256
                   : kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA256;
  if (bits == 384)
    return message ? kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA384
                   : kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA384;
  return message ? kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA512
                 : kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA512;
}
static int HorosDoSign(HorosTLSSign *s, unsigned char *sig, size_t *len,
                       size_t size, const unsigned char *data, size_t n,
                       int message) {
  if (!s->key || !s->key->secret || !s->key->publicKey)
    return 0;
  size_t maximum = (size_t)EVP_PKEY_get_size(s->key->publicKey);
  if (!sig) {
    *len = maximum;
    return 1;
  }
  SecKeyAlgorithm alg = HorosSignAlgorithm(s, message);
  if (!alg || !SecKeyIsAlgorithmSupported(s->key->secret,
                                          kSecKeyOperationTypeSign, alg))
    return 0;
  CFDataRef input = CFDataCreate(NULL, data, (CFIndex)n);
  CFErrorRef error = NULL;
  CFDataRef result =
      input ? SecKeyCreateSignature(s->key->secret, alg, input, &error) : NULL;
  int ok = result && (size_t)CFDataGetLength(result) <= size;
  if (ok) {
    *len = (size_t)CFDataGetLength(result);
    memcpy(sig, CFDataGetBytePtr(result), *len);
  }
  if (result)
    CFRelease(result);
  if (input)
    CFRelease(input);
  if (error)
    CFRelease(error);
  return ok;
}
static int HorosRawSign(void *s, unsigned char *sig, size_t *len, size_t size,
                        const unsigned char *d, size_t n) {
  return HorosDoSign(s, sig, len, size, d, n, 0);
}
static int HorosDigestUpdate(void *data, const unsigned char *d, size_t n) {
  HorosTLSSign *s = data;
  [s->message appendBytes:d length:n];
  return 1;
}
static int HorosDigestFinal(void *data, unsigned char *sig, size_t *len,
                            size_t size) {
  HorosTLSSign *s = data;
  return HorosDoSign(s, sig, len, size, [s->message bytes], [s->message length],
                     1);
}
static int HorosDigestSign(void *data, unsigned char *sig, size_t *len,
                           size_t size, const unsigned char *d, size_t n) {
  return HorosDoSign(data, sig, len, size, d, n, 1);
}
static const OSSL_PARAM HorosSignParamTypes[] = {
    OSSL_PARAM_utf8_string(OSSL_SIGNATURE_PARAM_DIGEST, NULL, 0),
    OSSL_PARAM_utf8_string(OSSL_SIGNATURE_PARAM_MGF1_DIGEST, NULL, 0),
    OSSL_PARAM_utf8_string(OSSL_SIGNATURE_PARAM_PAD_MODE, NULL, 0),
    OSSL_PARAM_utf8_string(OSSL_SIGNATURE_PARAM_PSS_SALTLEN, NULL, 0),
    OSSL_PARAM_END};
static const OSSL_PARAM *HorosSignSettable(void *s, void *p) {
  (void)s;
  (void)p;
  return HorosSignParamTypes;
}
#define HD(id, fn) {id, (void (*)(void))fn}
#define HOROS_KEY_DISPATCH(newfn, queryfn, exportfn)                           \
  HD(OSSL_FUNC_KEYMGMT_NEW, newfn), HD(OSSL_FUNC_KEYMGMT_FREE, HorosKeyFree),  \
      HD(OSSL_FUNC_KEYMGMT_DUP, HorosKeyDup),                                  \
      HD(OSSL_FUNC_KEYMGMT_HAS, HorosKeyHas),                                  \
      HD(OSSL_FUNC_KEYMGMT_MATCH, HorosKeyMatch),                              \
      HD(OSSL_FUNC_KEYMGMT_GET_PARAMS, HorosKeyParams),                        \
      HD(OSSL_FUNC_KEYMGMT_GETTABLE_PARAMS, HorosKeyGettable),                 \
      HD(OSSL_FUNC_KEYMGMT_QUERY_OPERATION_NAME, queryfn),                     \
      HD(OSSL_FUNC_KEYMGMT_IMPORT, HorosKeyImport),                            \
      HD(OSSL_FUNC_KEYMGMT_IMPORT_TYPES, HorosKeyTypes),                       \
      HD(OSSL_FUNC_KEYMGMT_EXPORT, HorosKeyExport),                            \
      HD(OSSL_FUNC_KEYMGMT_EXPORT_TYPES, exportfn), {                          \
    0, NULL                                                                    \
  }
static const OSSL_DISPATCH HorosRSAKeyDispatch[] = {
    HOROS_KEY_DISPATCH(HorosKeyNewRSA, HorosRSAOperation, HorosRSAExport)};
static const OSSL_DISPATCH HorosECKeyDispatch[] = {
    HOROS_KEY_DISPATCH(HorosKeyNewEC, HorosECOperation, HorosECExport)};
static const OSSL_DISPATCH HorosSignatureDispatch[] = {
    HD(OSSL_FUNC_SIGNATURE_NEWCTX, HorosSignNew),
    HD(OSSL_FUNC_SIGNATURE_FREECTX, HorosSignFree),
    HD(OSSL_FUNC_SIGNATURE_DUPCTX, HorosSignDup),
    HD(OSSL_FUNC_SIGNATURE_SIGN_INIT, HorosSignInit),
    HD(OSSL_FUNC_SIGNATURE_SIGN, HorosRawSign),
    HD(OSSL_FUNC_SIGNATURE_DIGEST_SIGN_INIT, HorosDigestInit),
    HD(OSSL_FUNC_SIGNATURE_DIGEST_SIGN_UPDATE, HorosDigestUpdate),
    HD(OSSL_FUNC_SIGNATURE_DIGEST_SIGN_FINAL, HorosDigestFinal),
    HD(OSSL_FUNC_SIGNATURE_DIGEST_SIGN, HorosDigestSign),
    HD(OSSL_FUNC_SIGNATURE_SET_CTX_PARAMS, HorosSignSet),
    HD(OSSL_FUNC_SIGNATURE_SETTABLE_CTX_PARAMS, HorosSignSettable),
    {0, NULL}};
static const OSSL_ALGORITHM HorosKeyAlgorithms[] = {
    {"RSA:rsaEncryption", "provider=horos-seckey", HorosRSAKeyDispatch,
     "Security RSA handle"},
    {"EC:id-ecPublicKey", "provider=horos-seckey", HorosECKeyDispatch,
     "Security EC handle"},
    {NULL, NULL, NULL, NULL}};
static const OSSL_ALGORITHM HorosSignatureAlgorithms[] = {
    {"RSA:rsaEncryption", "provider=horos-seckey", HorosSignatureDispatch,
     "Security RSA signature"},
    {"ECDSA", "provider=horos-seckey", HorosSignatureDispatch,
     "Security ECDSA signature"},
    {NULL, NULL, NULL, NULL}};
static const OSSL_ALGORITHM *HorosProviderQuery(void *ctx, int op, int *cache) {
  (void)ctx;
  *cache = 0;
  return op == OSSL_OP_KEYMGMT     ? HorosKeyAlgorithms
         : op == OSSL_OP_SIGNATURE ? HorosSignatureAlgorithms
                                   : NULL;
}
static const OSSL_DISPATCH HorosProviderDispatch[] = {
    HD(OSSL_FUNC_PROVIDER_QUERY_OPERATION, HorosProviderQuery), {0, NULL}};
static int HorosProviderInit(const OSSL_CORE_HANDLE *handle,
                             const OSSL_DISPATCH *in, const OSSL_DISPATCH **out,
                             void **ctx) {
  (void)handle;
  (void)in;
  *ctx = NULL;
  *out = HorosProviderDispatch;
  return 1;
}
#undef HD
#undef HOROS_KEY_DISPATCH

typedef struct {
  OSSL_LIB_CTX *library;
  OSSL_PROVIDER *standard, *security;
  SSL_CTX *context;
  SSL *ssl;
  NSString *peer;
  BOOL validate;
  int readWant, writeWant;
} HorosNativeTLS;
static X509 *HorosTLSCertificate(SecCertificateRef cert) {
  CFDataRef data = SecCertificateCopyData(cert);
  if (!data)
    return NULL;
  const unsigned char *p = CFDataGetBytePtr(data);
  X509 *x = d2i_X509(NULL, &p, CFDataGetLength(data));
  CFRelease(data);
  return x;
}
static int HorosTLSTrust(X509_STORE_CTX *store, void *arg) {
  HorosNativeTLS *t = arg;
  if (!t->validate) {
    X509_STORE_CTX_set_error(store, X509_V_OK);
    return 1;
  }
  NSMutableArray *certs = [NSMutableArray array];
  X509 *leaf = X509_STORE_CTX_get0_cert(store);
  STACK_OF(X509) *chain = X509_STORE_CTX_get0_untrusted(store);
  if (!leaf) {
    X509_STORE_CTX_set_error(store, X509_V_ERR_UNABLE_TO_GET_ISSUER_CERT);
    return 0;
  }
  int total = chain ? sk_X509_num(chain) : 0;
  for (int i = -1; i < total; i++) {
    X509 *x = i < 0 ? leaf : sk_X509_value(chain, i);
    if (!x || (i >= 0 && X509_cmp(x, leaf) == 0))
      continue;
    unsigned char *der = NULL;
    int n = i2d_X509(x, &der);
    if (n <= 0) {
      OPENSSL_free(der);
      return 0;
    }
    CFDataRef data = CFDataCreate(NULL, der, n);
    OPENSSL_free(der);
    SecCertificateRef cert =
        data ? SecCertificateCreateWithData(NULL, data) : NULL;
    if (data)
      CFRelease(data);
    if (!cert)
      return 0;
    [certs addObject:(id)cert];
    CFRelease(cert);
  }
  SecPolicyRef policy = SecPolicyCreateSSL(true, (CFStringRef)t->peer);
  SecTrustRef trust = NULL;
  OSStatus status =
      SecTrustCreateWithCertificates((CFArrayRef)certs, policy, &trust);
  if (policy)
    CFRelease(policy);
  CFErrorRef error = NULL;
  BOOL ok = status == errSecSuccess && SecTrustEvaluateWithError(trust, &error);
  if (error)
    CFRelease(error);
  if (trust)
    CFRelease(trust);
  X509_STORE_CTX_set_error(store, ok ? X509_V_OK : X509_V_ERR_CERT_UNTRUSTED);
  return ok;
}
static void HorosTLSFree(HorosNativeTLS *t) {
  if (!t)
    return;
  SSL_free(t->ssl);
  SSL_CTX_free(t->context);
  OSSL_PROVIDER_unload(t->security);
  OSSL_PROVIDER_unload(t->standard);
  OSSL_LIB_CTX_free(t->library);
  [t->peer release];
  free(t);
}
static HorosNativeTLS *HorosTLSCreate(int fd, NSDictionary *settings) {
  HorosNativeTLS *t = calloc(1, sizeof(*t));
  if (!t)
    return NULL;
  t->library = OSSL_LIB_CTX_new();
  if (!t->library ||
      !OSSL_PROVIDER_add_builtin(t->library, "horos-seckey", HorosProviderInit))
    goto failure;
  t->standard = OSSL_PROVIDER_load(t->library, "default");
  t->security = OSSL_PROVIDER_load(t->library, "horos-seckey");
  if (!t->standard || !t->security)
    goto failure;
  t->context = SSL_CTX_new_ex(t->library, NULL, TLS_method());
  if (!t->context)
    goto failure;
  if (!SSL_CTX_set_min_proto_version(t->context, TLS1_2_VERSION) ||
      !SSL_CTX_set_cipher_list(t->context, "DEFAULT:!kRSA"))
    goto failure;
  BOOL server = [[settings objectForKey:(id)kCFStreamSSLIsServer] boolValue];
  id peer = [settings objectForKey:(id)kCFStreamSSLPeerName];
  if (peer && peer != [NSNull null]) {
    if (![peer isKindOfClass:[NSString class]])
      goto failure;
    t->peer = [peer copy];
  }
  id validates =
      [settings objectForKey:(id)kCFStreamSSLValidatesCertificateChain];
  t->validate = !validates || [validates boolValue];
  if (!server) {
    SSL_CTX_set_verify(t->context, SSL_VERIFY_PEER, NULL);
    SSL_CTX_set_cert_verify_callback(t->context, HorosTLSTrust, t);
  }
  NSArray *certs = [settings objectForKey:(id)kCFStreamSSLCertificates];
  if ([certs count]) {
    SecIdentityRef identity = (SecIdentityRef)[certs objectAtIndex:0];
    if (CFGetTypeID(identity) != SecIdentityGetTypeID())
      goto failure;
    SecCertificateRef cert = NULL;
    SecKeyRef private = NULL;
    X509 *x = NULL;
    EVP_PKEY *publicKey = NULL, *key = NULL;
    EVP_PKEY_CTX *import = NULL;
    BOOL ok = SecIdentityCopyCertificate(identity, &cert) == errSecSuccess &&
              SecIdentityCopyPrivateKey(identity, &private) == errSecSuccess;
    if (ok) {
      x = HorosTLSCertificate(cert);
      publicKey = x ? X509_get_pubkey(x) : NULL;
      ok = publicKey != NULL;
    }
    if (ok) {
      const char *type = EVP_PKEY_is_a(publicKey, "RSA")  ? "RSA"
                         : EVP_PKEY_is_a(publicKey, "EC") ? "EC"
                                                          : NULL;
      import = type ? EVP_PKEY_CTX_new_from_name(t->library, type,
                                                 "provider=horos-seckey")
                    : NULL;
      OSSL_PARAM p[] = {
          OSSL_PARAM_octet_string("horos-seckey", &private, sizeof(private)),
          OSSL_PARAM_octet_string("horos-public", &publicKey,
                                  sizeof(publicKey)),
          OSSL_PARAM_END};
      ok = import && EVP_PKEY_fromdata_init(import) > 0 &&
           EVP_PKEY_fromdata(import, &key, EVP_PKEY_KEYPAIR, p) > 0 &&
           SSL_CTX_use_certificate(t->context, x) == 1 &&
           SSL_CTX_use_PrivateKey(t->context, key) == 1 &&
           SSL_CTX_check_private_key(t->context) == 1;
    }
    EVP_PKEY_CTX_free(import);
    EVP_PKEY_free(key);
    EVP_PKEY_free(publicKey);
    X509_free(x);
    if (private)
      CFRelease(private);
    if (cert)
      CFRelease(cert);
    if (!ok)
      goto failure;
    for (NSUInteger i = 1; i < [certs count]; i++) {
      SecCertificateRef ca = (SecCertificateRef)[certs objectAtIndex:i];
      if (CFGetTypeID(ca) != SecCertificateGetTypeID())
        goto failure;
      X509 *chain = HorosTLSCertificate(ca);
      BOOL added = chain && SSL_CTX_add1_chain_cert(t->context, chain);
      X509_free(chain);
      if (!added)
        goto failure;
    }
  }
  t->ssl = SSL_new(t->context);
  if (!t->ssl)
    goto failure;
  BIO *bio = BIO_new_socket(fd, BIO_NOCLOSE);
  if (!bio)
    goto failure;
  SSL_set_bio(t->ssl, bio, bio);
  SSL_set_mode(t->ssl, SSL_MODE_ENABLE_PARTIAL_WRITE |
                           SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER);
  if (server)
    SSL_set_accept_state(t->ssl);
  else {
    SSL_set_connect_state(t->ssl);
    if (t->peer && !SSL_set_tlsext_host_name(t->ssl, [t->peer UTF8String]))
      goto failure;
  }
  return t;
failure:
  HorosTLSFree(t);
  return NULL;
}
