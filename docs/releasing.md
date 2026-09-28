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
xcrun notarytool store-credentials peek \
  --apple-id "<your-apple-id>" \
  --team-id "<your-team-id>" \
  --password "<app-specific-password>"
```

Your team ID is the parenthesised code in the certificate name printed by the
`security find-identity` command above.

### 3. Sparkle signing key

Sparkle signs every update with an EdDSA key. The **private** key goes into your
login keychain and never leaves your machine; the **public** half is compiled
into the app. This is what makes GitHub Releases a safe place to host updates:
a compromised download cannot produce a build Peek will accept.

Find Sparkle's tools (present after one build, since SPM fetches them):

```bash
GENERATE_KEYS=$(find ~/Library/Developer/Xcode/DerivedData -type f -name generate_keys -path "*Sparkle*" | head -1)
"$GENERATE_KEYS"
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

1. Bump **both** `MARKETING_VERSION` **and** `CURRENT_PROJECT_VERSION` in
   `project.yml`.

   `CURRENT_PROJECT_VERSION` is the one that matters mechanically: it becomes
   `<sparkle:version>` in the appcast, and Sparkle decides whether an update is
   newer by comparing it — not the marketing string. Two releases sharing a
   build number means no installed copy is ever offered the second one. The
   release script refuses to run if the build number has not increased since
   the last tag, and if a tag for this marketing version already exists.
2. Run, with your Apple ID and team ID in the environment:

```bash
APPLE_ID="<your-apple-id>" TEAM_ID="<your-team-id>" ./scripts/release.sh
```

Both can be exported from your shell profile instead, so the everyday command
is just `./scripts/release.sh`.

That runs the tests, archives Release, exports with Developer ID, verifies the
signature and hardened runtime *before* spending a notarization round trip,
builds a signed DMG, notarizes, staples, checks Gatekeeper, and generates a
signed `appcast.xml`.

3. Tag, then create the GitHub release with **both** the DMG and `appcast.xml`.
   The release notes come from that version's `CHANGELOG.md` section, so the
   two cannot drift:

```bash
VERSION=0.2.0
git tag "v$VERSION" && git push origin main --tags
./scripts/changelog-section.sh "$VERSION" > /tmp/notes.md
gh release create "v$VERSION" \
  "build/release/Peek-$VERSION.dmg" \
  build/release/appcast.xml \
  --title "Peek $VERSION" --notes-file /tmp/notes.md
```

Both files must be attached to the **same** release, because `SUFeedURL` points
at `releases/latest/download/appcast.xml` and the appcast's enclosure URL points
at `releases/latest/download/Peek-<version>.dmg`.

> **The repository must be public** for updates to work. GitHub returns 404 for
> release assets on private repositories to unauthenticated clients, and Sparkle
> sends no credentials.

Existing installs pick the update up from the feed. `SUPublicEDKey` must not
change between releases, or they will reject it.

## Notes

- An unconfigured build (no feed, or the placeholder public key) reports updates
  as unavailable and never schedules a background check, rather than erroring.
- Sparkle's installer launcher service is disabled
  (`SUEnableInstallerLauncherService`), since Peek installs into `/Applications`
  without needing privileged help.
