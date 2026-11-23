//! Minimal IPA inspection: find `Payload/<App>.app/Info.plist` and read it.

use std::fs::File;
use std::io::Read;
use std::path::Path;

use crate::BridgeResult;

pub struct IpaInfo {
    pub bundle_id: String,
    pub name: Option<String>,
    pub version: Option<String>,
    pub platforms: Vec<String>,
    pub minimum_os: Option<String>,
}

impl IpaInfo {
    pub fn is_tvos(&self) -> bool {
        // Apps built for tvOS list AppleTVOS (device) in CFBundleSupportedPlatforms.
        // If the key is missing we can't tell, so let the TV decide.
        self.platforms.is_empty() || self.platforms.iter().any(|p| p == "AppleTVOS")
    }

    pub fn to_json(&self) -> String {
        serde_json::json!({
            "bundleId": self.bundle_id,
            "name": self.name,
            "version": self.version,
            "platforms": self.platforms,
            "minimumOS": self.minimum_os,
            "isTvOS": self.is_tvos(),
        })
        .to_string()
    }
}

fn is_app_info_plist(name: &str) -> bool {
    // Exactly Payload/<X>.app/Info.plist (not nested frameworks/extensions).
    let mut parts = name.split('/');
    matches!(
        (parts.next(), parts.next(), parts.next(), parts.next()),
        (Some("Payload"), Some(app), Some("Info.plist"), None) if app.ends_with(".app")
    )
}

pub fn inspect(path: &Path) -> BridgeResult<IpaInfo> {
    let file = File::open(path).map_err(|e| format!("could not open IPA: {e}"))?;
    let mut zip = zip::ZipArchive::new(file).map_err(|e| format!("not a valid IPA (zip): {e}"))?;

    let name = (0..zip.len())
        .filter_map(|i| zip.name_for_index(i).map(str::to_string))
        .find(|n| is_app_info_plist(n))
        .ok_or("not a valid IPA: no Payload/*.app/Info.plist")?;

    let mut data = Vec::new();
    zip.by_name(&name)
        .map_err(|e| format!("could not read Info.plist: {e}"))?
        .read_to_end(&mut data)
        .map_err(|e| format!("could not read Info.plist: {e}"))?;

    let plist: plist::Dictionary =
        plist::from_bytes(&data).map_err(|e| format!("could not parse Info.plist: {e}"))?;
    let s = |k: &str| plist.get(k).and_then(|v| v.as_string()).map(str::to_string);

    Ok(IpaInfo {
        bundle_id: s("CFBundleIdentifier").ok_or("Info.plist has no CFBundleIdentifier")?,
        name: s("CFBundleDisplayName").or_else(|| s("CFBundleName")),
        version: s("CFBundleShortVersionString").or_else(|| s("CFBundleVersion")),
        platforms: plist
            .get("CFBundleSupportedPlatforms")
            .and_then(|v| v.as_array())
            .map(|a| {
                a.iter()
                    .filter_map(|v| v.as_string().map(str::to_string))
                    .collect()
            })
            .unwrap_or_default(),
        minimum_os: s("MinimumOSVersion"),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_only_top_level_info_plist() {
        assert!(is_app_info_plist("Payload/Foo.app/Info.plist"));
        assert!(!is_app_info_plist(
            "Payload/Foo.app/Frameworks/X.framework/Info.plist"
        ));
        assert!(!is_app_info_plist(
            "Payload/Foo.app/PlugIns/Ext.appex/Info.plist"
        ));
        assert!(!is_app_info_plist("Info.plist"));
    }
}
