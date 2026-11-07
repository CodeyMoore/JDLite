### ⚠️**Disclaimer**⚠️

**JDLite was developed entirely with Claude.**

As a result, bugs, unexpected behaviour and other issues may occur. Features may not always work as intended.

Use at your own discretion.
-- --

JDLite is a lightweight download manager inspired by jDownloader2, which aims to provide a clean, streamlined experience for managing downloads on iOS.

### Features
* TorBox Integration — Connect your TorBox account to accelerate your downloads.
* OffCloud Intergration - Connect your OffCloud account to accelerate your downloads.
* iOS Focused — Designed specifically for the iOS experience.
* Simple & Streamlined — Inspired by jDownloader2, with an emphasis on ease of use.

### Compatibility
Built and tested for iOS 27 (older iOS version has not been tested) 

Currently only TorBox has been tested, OffCloud support has been implemented but remains untested (Support for other debrid services has not been implemented).

## Getting the IPA

Every push to `main` builds the app with GitHub Actions. Open **Actions → Build IPA**, pick the latest run, and download **JDLite-<version>-ipa** from *Artifacts*.

The IPA has no Apple signature, only an ad-hoc one. Install it with one of:

- **Jailbroken**: install AppSync Unified, then install the IPA with Filza. The IPA carries the entitlements AppSync installs need.
- **Sideload**: Sign the IPA via your preferred sideloading method. whether that be with your own Apple ID (re-sign every 7 days) or with your preferred signing service.
