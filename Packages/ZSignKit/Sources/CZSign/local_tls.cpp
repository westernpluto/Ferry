// Generates the loopback-only root CA and HTTPS server certificate used by the
// app's local install server, so no Mac or script is needed.

#include "CZSign.h"

#include <openssl/bn.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/pkcs12.h>
#include <openssl/rand.h>
#include <openssl/rsa.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>

#include <cstdlib>
#include <cstring>
#include <string>

namespace {

const char *kRootName = "Ferry Local Root";
const char *kServerName = "Ferry Local Server";

void setError(char *buffer, int length, const std::string &message) {
    if (!buffer || length <= 0) return;
    std::string text = message;
    unsigned long code = ERR_get_error();
    if (code != 0) {
        char detail[256];
        ERR_error_string_n(code, detail, sizeof(detail));
        text += " (";
        text += detail;
        text += ")";
    }
    std::strncpy(buffer, text.c_str(), (size_t)length - 1);
    buffer[length - 1] = '\0';
}

EVP_PKEY *makeKey() {
    EVP_PKEY *key = NULL;
    EVP_PKEY_CTX *ctx = EVP_PKEY_CTX_new_id(EVP_PKEY_RSA, NULL);
    if (ctx && EVP_PKEY_keygen_init(ctx) > 0 && EVP_PKEY_CTX_set_rsa_keygen_bits(ctx, 2048) > 0) {
        EVP_PKEY_keygen(ctx, &key);
    }
    EVP_PKEY_CTX_free(ctx);
    return key;
}

bool setRandomSerial(X509 *cert) {
    BIGNUM *bn = BN_new();
    bool ok = bn && BN_rand(bn, 120, BN_RAND_TOP_ANY, BN_RAND_BOTTOM_ANY) == 1;
    ASN1_INTEGER *serial = ok ? BN_to_ASN1_INTEGER(bn, NULL) : NULL;
    ok = serial && X509_set_serialNumber(cert, serial) == 1;
    ASN1_INTEGER_free(serial);
    BN_free(bn);
    return ok;
}

bool setName(X509_NAME *name, const char *commonName) {
    return X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_UTF8, (const unsigned char *)commonName, -1, -1, 0) == 1 &&
           X509_NAME_add_entry_by_txt(name, "O", MBSTRING_UTF8, (const unsigned char *)"Ferry", -1, -1, 0) == 1;
}

bool addExtension(X509 *cert, X509 *issuer, int nid, const char *value) {
    X509V3_CTX ctx;
    X509V3_set_ctx_nodb(&ctx);
    X509V3_set_ctx(&ctx, issuer, cert, NULL, NULL, 0);
    X509_EXTENSION *ext = X509V3_EXT_conf_nid(NULL, &ctx, nid, value);
    if (!ext) return false;
    bool ok = X509_add_ext(cert, ext, -1) == 1;
    X509_EXTENSION_free(ext);
    return ok;
}

X509 *makeCertificate(EVP_PKEY *key, const char *commonName, X509 *issuer, EVP_PKEY *issuerKey, int days, bool isCA) {
    X509 *cert = X509_new();
    if (!cert) return NULL;
    bool ok = X509_set_version(cert, 2) == 1 && setRandomSerial(cert) &&
              X509_gmtime_adj(X509_getm_notBefore(cert), -3600) &&
              X509_gmtime_adj(X509_getm_notAfter(cert), (long)days * 24 * 3600) &&
              X509_set_pubkey(cert, key) == 1 && setName(X509_get_subject_name(cert), commonName);
    X509 *signer = issuer ? issuer : cert;
    ok = ok && X509_set_issuer_name(cert, X509_get_subject_name(signer)) == 1;

    if (ok && isCA) {
        // Only names that always resolve to this device: localhost, the loopback IPs, and
        // public DNS names that answer 127.0.0.1 for every subdomain (localtest.me and
        // 127-0-0-1.sslip.io). iOS's installer won't fetch from a bare IP address.
        ok = addExtension(cert, signer, NID_basic_constraints, "critical,CA:TRUE,pathlen:0") &&
             addExtension(cert, signer, NID_key_usage, "critical,keyCertSign,cRLSign") &&
             addExtension(cert, signer, NID_subject_key_identifier, "hash") &&
             addExtension(cert, signer, NID_name_constraints,
                          "critical,permitted;DNS:localhost,permitted;DNS:localtest.me,"
                          "permitted;DNS:127-0-0-1.sslip.io,permitted;IP:127.0.0.1/255.255.255.255,"
                          "permitted;IP:0:0:0:0:0:0:0:1/FFFF:FFFF:FFFF:FFFF:FFFF:FFFF:FFFF:FFFF");
    } else if (ok) {
        ok = addExtension(cert, signer, NID_basic_constraints, "critical,CA:FALSE") &&
             addExtension(cert, signer, NID_key_usage, "critical,digitalSignature,keyEncipherment") &&
             addExtension(cert, signer, NID_ext_key_usage, "serverAuth") &&
             addExtension(cert, signer, NID_subject_alt_name,
                          "DNS:localhost,DNS:localtest.me,DNS:*.localtest.me,DNS:127-0-0-1.sslip.io,"
                          "DNS:*.127-0-0-1.sslip.io,IP:127.0.0.1,IP:0:0:0:0:0:0:0:1") &&
             addExtension(cert, signer, NID_subject_key_identifier, "hash") &&
             addExtension(cert, signer, NID_authority_key_identifier, "keyid");
    }

    ok = ok && X509_sign(cert, issuerKey ? issuerKey : key, EVP_sha256()) > 0;
    if (!ok) {
        X509_free(cert);
        return NULL;
    }
    return cert;
}

/// PKCS#12 with SHA1/3DES and a SHA-1 MAC, which SecPKCS12Import reads on every iOS version.
bool writePKCS12(const char *password, const char *name, EVP_PKEY *key, X509 *cert, X509 *chain,
                 unsigned char **out, int *outLength) {
    STACK_OF(X509) *ca = NULL;
    if (chain) {
        ca = sk_X509_new_null();
        if (!ca || !sk_X509_push(ca, chain)) {
            sk_X509_free(ca);
            return false;
        }
    }
    PKCS12 *p12 = PKCS12_create(password, name, key, cert, ca,
                                NID_pbe_WithSHA1And3_Key_TripleDES_CBC,
                                NID_pbe_WithSHA1And3_Key_TripleDES_CBC, 2048, -1, 0);
    sk_X509_free(ca);
    bool ok = p12 && PKCS12_set_mac(p12, password, -1, NULL, 0, 2048, EVP_sha1()) == 1;
    if (ok) {
        *outLength = i2d_PKCS12(p12, out);
        ok = *outLength > 0;
    }
    PKCS12_free(p12);
    return ok;
}

bool readPKCS12(const unsigned char *data, int length, const char *password, EVP_PKEY **key, X509 **cert) {
    const unsigned char *cursor = data;
    PKCS12 *p12 = d2i_PKCS12(NULL, &cursor, length);
    if (!p12) return false;
    bool ok = PKCS12_parse(p12, password, key, cert, NULL) == 1 && *key && *cert;
    PKCS12_free(p12);
    return ok;
}

unsigned char *copyOut(unsigned char *data, int length) {
    unsigned char *copy = (unsigned char *)std::malloc((size_t)length);
    if (copy) std::memcpy(copy, data, (size_t)length);
    return copy;
}

}  // namespace

extern "C" int czsign_make_local_tls(const unsigned char *existing_ca_p12, int existing_ca_p12_length,
                                     const char *password, int server_days, czsign_local_tls *result,
                                     char *error, int error_length) {
    if (!password || !result) {
        setError(error, error_length, "Missing arguments.");
        return -1;
    }
    std::memset(result, 0, sizeof(*result));
    ERR_clear_error();

    EVP_PKEY *caKey = NULL;
    X509 *caCert = NULL;
    if (existing_ca_p12 && existing_ca_p12_length > 0) {
        if (!readPKCS12(existing_ca_p12, existing_ca_p12_length, password, &caKey, &caCert)) {
            EVP_PKEY_free(caKey);
            X509_free(caCert);
            caKey = NULL;
            caCert = NULL;
        }
    }
    if (!caCert) {
        caKey = makeKey();
        caCert = caKey ? makeCertificate(caKey, kRootName, NULL, NULL, 3650, true) : NULL;
    }

    EVP_PKEY *serverKey = caCert ? makeKey() : NULL;
    X509 *serverCert = serverKey ? makeCertificate(serverKey, "localhost", caCert, caKey, server_days, false) : NULL;

    unsigned char *serverP12 = NULL, *caP12 = NULL, *caDER = NULL;
    int serverP12Length = 0, caP12Length = 0, caDERLength = 0;
    bool ok = serverCert &&
              writePKCS12(password, kServerName, serverKey, serverCert, caCert, &serverP12, &serverP12Length) &&
              writePKCS12(password, kRootName, caKey, caCert, NULL, &caP12, &caP12Length);
    if (ok) {
        caDERLength = i2d_X509(caCert, &caDER);
        ok = caDERLength > 0;
    }

    if (ok) {
        result->server_p12 = copyOut(serverP12, serverP12Length);
        result->server_p12_length = serverP12Length;
        result->ca_p12 = copyOut(caP12, caP12Length);
        result->ca_p12_length = caP12Length;
        result->ca_der = copyOut(caDER, caDERLength);
        result->ca_der_length = caDERLength;
        ok = result->server_p12 && result->ca_p12 && result->ca_der;
    }
    if (!ok) {
        setError(error, error_length, "Couldn't create the certificate.");
        czsign_free_local_tls(result);
    }

    OPENSSL_free(serverP12);
    OPENSSL_free(caP12);
    OPENSSL_free(caDER);
    X509_free(serverCert);
    EVP_PKEY_free(serverKey);
    X509_free(caCert);
    EVP_PKEY_free(caKey);
    return ok ? 0 : -1;
}

extern "C" void czsign_free_local_tls(czsign_local_tls *result) {
    if (!result) return;
    std::free(result->server_p12);
    std::free(result->ca_p12);
    std::free(result->ca_der);
    std::memset(result, 0, sizeof(*result));
}
