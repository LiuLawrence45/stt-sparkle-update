# stt-sparkle-update

Mac releases remain on GitHub. `Publish Mac downloads to R2` runs after the release
script pushes `appcast.xml`, verifies the installer against the public Sparkle key,
uploads it to R2, and checks the public download byte for byte before changing the
feed's download URL. Existing apps continue using the same feed and signing key.
It explicitly requests a GitHub Pages build because bot commits do not trigger
the repository's current branch-based Pages build.

## Production downloads

- Bucket: `willow-downloads` (R2 Standard).
- Custom domain: `downloads.willowvoice.com`; use the R2 custom-domain connection.
- Website: `https://downloads.willowvoice.com/mac/latest/Willow.Installer.dmg`.
- Updates: versioned paths such as `/mac/v2.6.0/Willow.Installer.dmg`.
- Versioned files cache for one year. The website's mutable latest file caches for
  60 seconds. Never replace the bytes of an existing versioned release.
- Leave the existing S3 mirror enabled during rollout so old website links work.

Configure repository variable `R2_ACCOUNT_ID`, and encrypted repository secrets
`R2_ACCESS_KEY_ID` and `R2_SECRET_ACCESS_KEY`. The R2 token needs only Object Read
and Write on `willow-downloads`. The workflow also needs permission to push
`appcast.xml` to `main`; a rejected push stops promotion of the latest installer.

Run the workflow manually to seed the current release. Before updating Framer,
verify HTTP 200, the expected size and SHA-256, a warmed `CF-Cache-Status: HIT`,
and HTTP 206 for a byte-range request. Compare repeated full downloads with the
S3 URL on the affected network. Confirm the latest URL returns the intended release.

The release workflow changes only the enclosure URL, preserving the existing
Sparkle signature and size. Changes to a signed appcast would also require signing
the feed itself; the current feed does not have a feed signature. Do not use this
URL-replacement workflow unchanged if signed-feed requirements are enabled later.

For rollback, restore the GitHub enclosure URL in the feed and return Framer to the
existing S3 link. Disable the R2 workflow before restoring the feed, or it will
publish the R2 URL again. Existing GitHub and S3 artifacts remain available.

Delta updates are a separate improvement: keep previous release archives together
when running Sparkle's `generate_appcast`, publish its signed `.delta` files, and
retain the full installer as fallback. The current feed contains only a full DMG.
