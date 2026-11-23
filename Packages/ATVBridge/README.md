# ATVBridge

Ferry's Apple TV support: a Rust static library with a C API (`include/atvbridge.h`, imported in
Swift as `ATVBridge`) over [`idevice`](https://github.com/jkcoxson/idevice) (MIT). It pairs with an
Apple TV (tvOS 17+, RemotePairing with the on-screen PIN), opens a CoreDevice tunnel, uploads an IPA
over AFC and installs, lists and removes apps with InstallationProxy.

It comes from iOStoATV (MIT, see `LICENSE-iOStoATV`); only names were changed. `idevice` is pre-1.0,
so it's pinned exactly in `Cargo.toml`.

```sh
cargo test && cargo clippy --all-targets   # any OS
../../scripts/build-atv-bridge.sh          # macOS: builds ../../Frameworks/ATVBridge.xcframework
```
