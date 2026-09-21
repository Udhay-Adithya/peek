# Releasing Peek

Peek ships **outside the Mac App Store** — see
[ADR 0002](adr/0002-developer-id-not-app-store.md) — so it is distributed as a
notarized DMG on GitHub Releases and updates itself with Sparkle.

## One-time setup

### 1. Developer ID Application certificate

Not the same as the *Apple Development* certificate used for local builds; that
one cannot be notarized. Only the Account Holder can create this.

> Xcode → Settings → Accounts → your team → Manage Certificates → **+** →
> **Developer ID Application**

Verify:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

### 2. Notarization credentials

Create an app-specific password at [appleid.apple.com](https://appleid.apple.com)
→ Sign-In and Security → App-Specific Passwords, then:

```bash
xcrun notarytool store-credentials peek --apple-id "udhayxd@gmail.com" --team-id 5ZN86R9K96 --password "<app-specific-password>"
```

### 3. Sparkle signing key

Sparkle signs every update with an EdDSA key. The **private** key goes into your
login keychain and never leaves your machine; the **public** half is compiled
into the app. This is what makes GitHub Releases a safe place to host updates:
a compromised download cannot produce a build Peek will accept.

Find Sparkle's tools (present after one build, since SPM fetches them):

```bash
find ~/Library/Developer/Xcode/DerivedData -type f -name generate_keys -path "*Sparkle*" | head -1
```

Run `generate_keys` once. It prints a public key — put it in
`App/Peek/Resources/Info.plist` under `SUPublicEDKey`, replacing
`REPLACE_WITH_SPARKLE_PUBLIC_KEY`.

**Back the private key up.** Losing it means existing installs can never be
updated again; they would all have to reinstall manually.

### 4. Feed URL

`SUFeedURL` in `Info.plist` points at `appcast.xml` on your GitHub releases.
Confirm the repository path matches yours before the first release.

## Each release

1. Bump `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION`) in `project.yml`.
2. Run:

```bash
./scripts/release.sh
```

That runs the tests, archives Release, exports with Developer ID, verifies the
signature and hardened runtime *before* spending a notarization round trip,
builds a signed DMG, notarizes, staples, checks Gatekeeper, and generates a
signed `appcast.xml`.

3. Create the GitHub release and upload **both** the DMG and `appcast.xml`.

Existing installs pick the update up from the feed. `SUPublicEDKey` must not
change between releases, or they will reject it.

## Notes

- An unconfigured build (no feed, or the placeholder public key) reports updates
  as unavailable and never schedules a background check, rather than erroring.
- Sparkle's installer launcher service is disabled
  (`SUEnableInstallerLauncherService`), since Peek installs into `/Applications`
  without needing privileged help.
