// C interface to the Rust bridge (bridge/src/lib.rs).
// Every function blocks; call from a background thread.
// Functions returning char* return NULL on success or an error message that
// must be released with atv_free_string.

#ifndef ATVBRIDGE_H
#define ATVBRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Write a NUL-terminated PIN into out_pin. Leave it empty to cancel.
typedef void (*AtvPinCallback)(void *ctx, char *out_pin, size_t out_cap);

/// phase: 0 = uploading, 1 = installing/removing. percent: 0-100.
typedef void (*AtvProgressCallback)(void *ctx, uint32_t phase, uint32_t percent, const char *status);

char *atv_pair(const char *host, uint16_t port, const char *host_name,
               AtvPinCallback pin_cb, void *ctx,
               uint8_t **out_file, size_t *out_len,
               char **out_peer_json);

char *atv_device_info(const char *host, uint16_t port, const char *host_name,
                      const uint8_t *pairing, size_t pairing_len,
                      char **out_json);

char *atv_install(const char *host, uint16_t port, const char *host_name,
                  const uint8_t *pairing, size_t pairing_len,
                  const char *ipa_path,
                  AtvProgressCallback progress_cb, void *ctx);

char *atv_list_apps(const char *host, uint16_t port, const char *host_name,
                    const uint8_t *pairing, size_t pairing_len,
                    char **out_json);

char *atv_uninstall(const char *host, uint16_t port, const char *host_name,
                    const uint8_t *pairing, size_t pairing_len,
                    const char *bundle_id,
                    AtvProgressCallback progress_cb, void *ctx);

/// 1 if the _remotepairing._tcp TXT record (identifier, authTag) belongs to
/// the Apple TV this pairing record was made with, else 0.
int32_t atv_service_matches(const uint8_t *pairing, size_t pairing_len,
                            const char *identifier, const char *auth_tag);

/// Ask host directly (unicast DNS-SD to port 5353) for its RemotePairing
/// services. JSON array of {"serviceType", "instance", "port"}.
char *atv_probe_host(const char *host, char **out_json);

char *atv_inspect_ipa(const char *ipa_path, char **out_json);

void atv_free_string(char *s);
void atv_free_bytes(uint8_t *p, size_t len);

#ifdef __cplusplus
}
#endif

#endif
