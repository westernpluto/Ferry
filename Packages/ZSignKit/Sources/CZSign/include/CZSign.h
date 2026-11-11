#ifndef CZSIGN_H
#define CZSIGN_H

#ifdef __cplusplus
extern "C" {
#endif

/// One provisioning profile to sign with, plus the entitlements to sign that bundle with.
/// zsign matches a profile to a bundle by the `application-identifier` in `entitlements_path`
/// (which must be `TEAMID.<bundle id>`). The first entry is also the fallback for unmatched bundles.
typedef struct {
    const char *profile_path;
    const char *entitlements_path;
} czsign_profile;

/// Receives zsign's log output, one message at a time. `is_error` is non-zero for errors.
typedef void (*czsign_log_callback)(void *context, int is_error, const char *message);

/// Re-signs every bundle in an IPA and writes a new IPA.
///
/// - key_path: PEM/DER private key or a .p12 file.
/// - cert_path: PEM/DER certificate (may be NULL when key_path is a .p12).
/// - password: password for key_path (may be NULL).
/// - temp_folder: an existing, writable folder for the extracted app.
/// - bundle_version: if not NULL, CFBundleVersion of every app and extension is set to it
///   before signing (so an iPhone app and its watch app keep matching build numbers).
/// Returns 0 on success.
int czsign_sign_ipa(const char *input_ipa,
                    const char *output_ipa,
                    const char *key_path,
                    const char *cert_path,
                    const char *password,
                    const czsign_profile *profiles,
                    int profile_count,
                    const char *temp_folder,
                    const char *bundle_version,
                    czsign_log_callback log_callback,
                    void *log_context);

/// Output of czsign_make_local_tls. Free with czsign_free_local_tls.
typedef struct {
    unsigned char *server_p12;   ///< HTTPS server identity (key + cert + root), PKCS#12
    int server_p12_length;
    unsigned char *ca_p12;       ///< Root CA key + cert, kept to re-issue server certificates
    int ca_p12_length;
    unsigned char *ca_der;       ///< Root CA certificate (DER), for the configuration profile
    int ca_der_length;
} czsign_local_tls;

/// Creates a root CA limited (name constraints) to localhost/127.0.0.1/::1 and an HTTPS
/// server certificate for those names. Pass an existing CA PKCS#12 to re-use that root
/// (so the installed profile stays valid); pass NULL to create a new root.
/// Both PKCS#12 outputs use `password`. Returns 0 on success.
int czsign_make_local_tls(const unsigned char *existing_ca_p12,
                          int existing_ca_p12_length,
                          const char *password,
                          int server_days,
                          czsign_local_tls *result,
                          char *error,
                          int error_length);

void czsign_free_local_tls(czsign_local_tls *result);

#ifdef __cplusplus
}
#endif

#endif
