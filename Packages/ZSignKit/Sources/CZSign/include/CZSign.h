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
/// Returns 0 on success.
int czsign_sign_ipa(const char *input_ipa,
                    const char *output_ipa,
                    const char *key_path,
                    const char *cert_path,
                    const char *password,
                    const czsign_profile *profiles,
                    int profile_count,
                    const char *temp_folder,
                    czsign_log_callback log_callback,
                    void *log_context);

#ifdef __cplusplus
}
#endif

#endif
