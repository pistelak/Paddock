# Releasing Paddock

How a release happens, how to cut one by hand, what to do when one goes wrong, and what would change with
a paid Apple developer account.

## The loop

1. [Renovate](https://docs.renovatebot.com) watches the two `exactVersion` pins in `project.yml`
   (`renovate.json`). When libghostty-spm publishes a release, it opens a pull request bumping the pin.
2. The `test` workflow (`.github/workflows/ci.yml`) runs the unit tests on the pull request.
3. Renovate merges the pull request itself once that check is green (`automerge` in `renovate.json`;
   Sparkle and GitHub Actions bumps are left for a human to merge).
4. The merge is a push to `main` that touches `project.yml`, so the `release` workflow
   (`.github/workflows/release.yml`) runs. Its `detect` job compares the libghostty version at `HEAD` with
   the one at the last `v*` tag and only carries on if they differ.
5. The `release` job runs the tests again, computes the next patch version from the last tag
   (`scripts/next-version.sh`), builds a signed universal zip (`scripts/build-release.sh`), creates the
   GitHub Release with the tag (`gh release create --target`), adds the item to the Sparkle appcast
   (`scripts/appcast.sh`), pushes the feed to the `gh-pages` branch for history, and deploys it to GitHub
   Pages. Sparkle in every installed Paddock reads `https://pistelak.github.io/Paddock/appcast.xml`.

Versions live in tags only. `project.yml` says `0.0.0`, and the build script stamps the real version
into the bundle on the `xcodebuild` command line. Nothing is ever committed to `main` by the workflow, so
there is no bot push to race with and no branch protection to fight.

## A release by hand

For anything other than a libghostty bump, dispatch the workflow with the bump you want:

```sh
gh workflow run release.yml -f bump=minor      # or patch, major
gh run watch
```

To see what it would build without publishing anything:

```sh
make release BUMP=minor    # build/Paddock-X.Y.Z.zip, signed, with every release check applied
```

## When a release goes wrong

The steps that publish come last, in this order: GitHub Release (with its tag), `gh-pages` push, Pages
deployment. A failure before the release leaves nothing behind; run it again.

If the release was created but the appcast was not updated or deployed, rebuild the feed entry from the
release asset without building again:

```sh
gh workflow run release.yml -f republish_tag=v0.2.1
```

The workflow runs one release at a time (`concurrency: release`). GitHub keeps only one run waiting, so two
dispatches in quick succession collapse into one; dispatch the second after the first has finished.

## The signing key

Updates are ad-hoc signed, so the only thing that proves an update came from this project is its EdDSA
signature. The private key exists in three places: the macOS Keychain of the machine that ran
`generate_keys`, the `SPARKLE_PRIVATE_KEY` repository secret, and an encrypted offline backup. GitHub
secrets cannot be read back, and a lost key cannot be replaced without every installed copy losing the
ability to update, so keep the backup. Never rotate the key without a transition release that carries both.

To export it again from the Keychain, or import it on another machine:

```sh
sparkle-tools/bin/generate_keys -x sparkle-private.key   # export (the file is gitignored)
sparkle-tools/bin/generate_keys -f sparkle-private.key   # import
```

## Signing with a Developer ID (not done yet)

Everything above works without an Apple developer account. With one, releases could be notarized, which
removes the Open Anyway step for new users. The changes would be:

- Add repository secrets for the Developer ID Application certificate (`.p12`, base64) and its
  password, plus an App Store Connect API key for `notarytool`.
- In the release workflow, import the certificate into a temporary keychain before the build and run
  `scripts/build-release.sh` with `CODE_SIGN_IDENTITY="Developer ID Application"` and
  `DEVELOPMENT_TEAM` set; the script's ad-hoc assertion is skipped when the identity is not `-`.
- After the build, `xcrun notarytool submit build/Paddock-X.Y.Z.zip --wait`, then
  `xcrun stapler staple build/Paddock.app` and zip again.
- The `disable-library-validation` entitlement can stay (notarization accepts it) or go, since a
  Developer ID signed Sparkle no longer needs it.

Sparkle accepts a change of code-signing identity as long as the EdDSA key stays the same, so existing
installs update across the switch.

## Known follow-ups

Findings from the pre-publication review that were real but not worth holding the first release for:

- Bound what is read from a subprocess and from the socket (`DescriptorReader`, `UnixSocketConnection`);
  today a misbehaving herdr can grow memory without limit.
- Read `tabs.json` through one descriptor with an `fstat` and a size cap (`TabStoreFile`), instead of
  checking the path and then opening it.
- Have `ProcessRunnerTests` clean up by process id rather than `pkill` on a command line.
- A Homebrew cask (`auto_updates true`, so Homebrew and Sparkle do not fight) and a `FUNDING.yml`, if
  wanted.
