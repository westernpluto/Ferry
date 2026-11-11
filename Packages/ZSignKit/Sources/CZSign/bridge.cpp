// C entry point around zsign's bundle signer, mirroring the IPA path of zsign's
// command-line tool (extract → sign every bundle → archive).

#include "CZSign.h"
#include "common.h"
#include "bundle.h"
#include "openssl.h"
#include "archive.h"
#include <list>
#include <mutex>
#include <dirent.h>
#include <sys/stat.h>

extern void (*g_zsign_log_hook)(int nColor, const char *szLog);

namespace {
std::mutex g_signLock;
czsign_log_callback g_callback = NULL;
void *g_context = NULL;

void forwardLog(int nColor, const char *szLog) {
    if (g_callback) {
        g_callback(g_context, nColor == 12 ? 1 : 0, szLog);
    }
}

std::string safe(const char *value) { return value ? std::string(value) : std::string(); }

bool endsWith(const std::string &value, const std::string &suffix) {
    return value.size() >= suffix.size() && value.compare(value.size() - suffix.size(), suffix.size(), suffix) == 0;
}

/// Sets CFBundleVersion in the Info.plist of every .app / .appex below `folder`,
/// keeping each file's format (binary or XML). Returns the number of bundles changed.
int setBundleVersions(const std::string &folder, const std::string &version) {
    int changed = 0;
    DIR *dir = opendir(folder.c_str());
    if (!dir) return 0;
    while (struct dirent *entry = readdir(dir)) {
        std::string name = entry->d_name;
        if (name == "." || name == "..") continue;
        std::string path = folder + "/" + name;
        struct stat info;
        if (lstat(path.c_str(), &info) != 0 || !S_ISDIR(info.st_mode)) continue;
        if (endsWith(name, ".app") || endsWith(name, ".appex")) {
            std::string plistPath = path + "/Info.plist";
            std::string data;
            jvalue plist;
            bool binary = false;
            if (ZFile::ReadFile(plistPath.c_str(), data) && plist.read_plist(data, NULL, &binary) &&
                plist.has("CFBundleVersion")) {
                plist["CFBundleVersion"] = version;
                bool written = binary ? plist.write_bplist_to_file("%s", plistPath.c_str())
                                      : plist.style_write_plist_to_file("%s", plistPath.c_str());
                if (written) {
                    changed++;
                    ZLog::PrintV(">>> Build number:\t%s -> %s\n", name.c_str(), version.c_str());
                }
            }
        }
        changed += setBundleVersions(path, version);
    }
    closedir(dir);
    return changed;
}

struct LogScope {
    LogScope(czsign_log_callback callback, void *context) {
        g_callback = callback;
        g_context = context;
        g_zsign_log_hook = forwardLog;
    }
    ~LogScope() {
        g_zsign_log_hook = NULL;
        g_callback = NULL;
        g_context = NULL;
    }
};
}

extern "C" int czsign_sign_ipa(const char *input_ipa,
                               const char *output_ipa,
                               const char *key_path,
                               const char *cert_path,
                               const char *password,
                               const czsign_profile *profiles,
                               int profile_count,
                               const char *temp_folder,
                               const char *bundle_version,
                               czsign_log_callback log_callback,
                               void *log_context) {
    std::lock_guard<std::mutex> guard(g_signLock);
    LogScope logScope(log_callback, log_context);

    if (!input_ipa || !output_ipa || !key_path || !profiles || profile_count < 1 || !temp_folder) {
        ZLog::Error(">>> Missing signing input.\n");
        return -1;
    }

    std::list<ZSignAsset> assets;
    for (int i = 0; i < profile_count; i++) {
        assets.push_back(ZSignAsset());
        if (!assets.back().Init(safe(cert_path), safe(key_path), safe(profiles[i].profile_path),
                                safe(profiles[i].entitlements_path), safe(password), false, false, false)) {
            ZLog::ErrorV(">>> Could not use provisioning profile %s\n", safe(profiles[i].profile_path).c_str());
            return -2;
        }
    }

    std::string folder = ZFile::GetRealPathV("%s/zsign_%llu", temp_folder, ZUtil::GetMicroSecond());
    if (!Zip::Extract(input_ipa, folder.c_str())) {
        ZLog::Error(">>> Could not extract the IPA.\n");
        ZFile::RemoveFolder(folder.c_str());
        return -3;
    }

    if (bundle_version && *bundle_version) {
        if (setBundleVersions(folder + "/Payload", bundle_version) == 0) {
            ZLog::Warn(">>> Couldn't set the build number; signing with the original.\n");
        }
    }

    ZBundle bundle;
    std::vector<std::string> noDylibs;
    bool ok = bundle.SignFolder(&assets, folder, "", "", "", noDylibs, noDylibs,
                                true /* force */, false /* weak inject */, false /* cache */);

    if (ok) {
        size_t pos = bundle.m_strAppFolder.rfind("Payload");
        if (std::string::npos == pos || pos == 0) {
            ZLog::Error(">>> Could not find the Payload folder.\n");
            ok = false;
        } else {
            std::string base = bundle.m_strAppFolder.substr(0, pos - 1);
            ZFile::RemoveFile(output_ipa);
            if (!Zip::Archive(base, output_ipa, 6)) {
                ZLog::Error(">>> Could not write the signed IPA.\n");
                ok = false;
            }
        }
    }

    ZFile::RemoveFolder(folder.c_str());
    return ok ? 0 : -4;
}
