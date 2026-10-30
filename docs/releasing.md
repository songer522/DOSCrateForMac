# Release Process (`DOSCrate`)

This document covers the end-to-end process for building, signing, notarizing, and publishing a new DOSCrate release on GitHub.

---

## 1. One-Time Machine Setup

If you are cutting a release from a Mac that has already published a previous release, skip to **[Section 2: Cutting a New Release](#2-cutting-a-new-release)**.

### 1.1 Developer ID Application Certificate
1. Open **Xcode → Settings… (`⌘,`) → Accounts**.
2. Select your Apple ID and Team, then click **Manage Certificates…**.
3. Click **`+` → Developer ID Application**.
4. Verify the identity is installed in Keychain:
   ```bash
   security find-identity -v -p codesigning
   ```
   Confirm you see `"Developer ID Application: Yang Song (4UXP3NANFN)"` (or your Developer ID string).

### 1.2 Apple Notary Credentials (`notarytool`)
1. Sign in to [account.apple.com](https://account.apple.com/) and go to **Sign-In and Security → App-Specific Passwords**.
2. Generate an app-specific password (e.g., `DOSCrate Notary`).
3. Store it in the macOS Keychain under the profile name `doscrate-notary`:
   ```bash
   xcrun notarytool store-credentials "doscrate-notary" \
     --apple-id "YOUR_APPLE_ID_EMAIL" \
     --team-id "4UXP3NANFN" \
     --password "xxxx-xxxx-xxxx-xxxx"
   ```

### 1.3 Sparkle Ed25519 Keypair
The private signing key lives in the macOS Keychain under the account `ed25519` (service `https://sparkle-project.org`).
- To print the existing public key (`SUPublicEDKey`) from Keychain:
  ```bash
  "$(find ~/Library/Developer/Xcode/DerivedData -path '*/Sparkle/bin/generate_keys' -print -quit)" -p
  ```
  Current public key for `songer522/DOSCrateForMac`:
  ```text
  73p5jbUUCeoXwge5OikYhxY0vSdy7bF/T96AxXZpZxA=
  ```
- **Important:** If moving to a new Mac, export the existing Sparkle private key from Keychain Access (or run `generate_keys -x private-key-file` on the old Mac and `generate_keys -f private-key-file` on the new Mac) so existing installs continue to trust updates.

---

## 2. Cutting a New Release

### Step 1: Run the Test Suite on `main`
Ensure `main` is up to date, clean, and passes all package + app tests with zero compiler warnings:

```bash
git checkout main
git pull --ff-only
make test
```

### Step 2: Build, Sign, Notarize & Package (`make release`)
Set `VERSION` to the new numeric dotted version (for example, `1.1.0`) and run `make release`:

```bash
DEVELOPER_ID="Developer ID Application: Yang Song (4UXP3NANFN)" \
NOTARY_PROFILE="doscrate-notary" \
DOSCRATE_APPCAST_URL="https://github.com/songer522/DOSCrateForMac/releases/latest/download/appcast.xml" \
DOSCRATE_SPARKLE_KEY="73p5jbUUCeoXwge5OikYhxY0vSdy7bF/T96AxXZpZxA=" \
VERSION="1.1.0" \
make release
```

What [`scripts/release.sh`](../scripts/release.sh) does and verifies:
1. Downloads and verifies the pinned DOSBox Staging (`0.83.0`), `GLib` (`2.86.3`), and `gettext` (`0.22.5`) source tarballs against SHA-256 checksums in [`scripts/staging.lock`](../scripts/staging.lock).
2. Runs `xcodegen generate` and archives `DOSCrate` in the `Release` configuration with `MARKETING_VERSION=$VERSION`, `CURRENT_PROJECT_VERSION=$VERSION`, `SUFeedURL`, and `SUPublicEDKey`.
3. Exports with `method = developer-id` and re-signs inside-out with Hardened Runtime (`--options runtime --timestamp`):
   - `DOSBox Staging.app/Contents/MacOS/lib/*.dylib`
   - `DOSBox Staging.app/Contents/MacOS/dosbox` and `DOSBox Staging.app` (preserving `com.apple.security.cs.allow-jit` and verifying both the JIT entitlement and hardened runtime flag)
   - `Sparkle.framework` XPC services, `Autoupdate`, `Updater.app`, and `Sparkle.framework`
   - `DOSCrate.app` with [`App/DOSCrate.entitlements`](../App/DOSCrate.entitlements)
4. Verifies deep code signing (`codesign --verify --deep --strict`).
5. Creates `build/release/DOSCrate-<VERSION>.dmg` (with a `/Applications` symlink), signs the DMG, submits it to Apple's notary service (`xcrun notarytool submit --wait`), staples the ticket (`xcrun stapler staple`), and verifies Gatekeeper approval (`spctl -a -t open --context context:primary-signature -vv`).
6. Runs Sparkle's `generate_appcast` to sign the DMG with the Keychain Ed25519 private key and emit `build/release/appcast.xml` pointing to `https://github.com/songer522/DOSCrateForMac/releases/download/v<VERSION>/DOSCrate-<VERSION>.dmg`.

### Step 3: Publish the GitHub Release
Attach **all 5 artifacts** produced in `build/release/` (the DMG, `appcast.xml`, and the 3 GPL/LGPL source archives):

```bash
VERSION="1.1.0"
source scripts/staging.lock

gh release create "v$VERSION" \
  "build/release/DOSCrate-$VERSION.dmg" \
  "build/release/appcast.xml" \
  "build/release/dosbox-staging-$STAGING_VERSION-source.tar.gz" \
  "build/release/glib-$GLIB_VERSION.tar.xz" \
  "build/release/gettext-$GETTEXT_VERSION.tar.gz" \
  --target main \
  --title "DOSCrate $VERSION" \
  --generate-notes
```

*(Because `SUFeedURL` is `https://github.com/songer522/DOSCrateForMac/releases/latest/download/appcast.xml`, uploading `appcast.xml` to the latest GitHub Release automatically serves updates to existing users via Sparkle.)*

### Step 4: Update `README.md` Download Link
Update the direct `.dmg` download link in [`README.md`](../README.md) to point to `v<VERSION>/DOSCrate-<VERSION>.dmg`.

---

## 3. Upgrading Bundled DOSBox Staging

When upgrading to a newer upstream DOSBox Staging version in the future:
1. Update `STAGING_VERSION`, `STAGING_URL`, `STAGING_SHA256`, `STAGING_SOURCE_SHA256`, `GLIB_VERSION`, `GLIB_SOURCE_SHA256`, `GETTEXT_VERSION`, and `GETTEXT_SOURCE_SHA256` in [`scripts/staging.lock`](../scripts/staging.lock).
2. Update `StagingRelease.version` in [`App/Views/LicensesView.swift`](../App/Views/LicensesView.swift) to match `STAGING_VERSION` (`LicensesTests` enforces that both match).
3. Run `rm -rf Vendor && make test` to fetch the new DOSBox Staging universal DMG and verify all tests pass.
