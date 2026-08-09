<!-- Keep the description short. The checklist below is what CI will verify anyway,
     so ticking a box you have not actually checked only delays the red build. -->

## What changed

<!-- One or two sentences. Why, not just what. -->

## Checklist

- [ ] `swift test -c release` passes locally
- [ ] `./Scripts/bundle.sh release` produces a launchable `build/Impuls.app`
- [ ] Network is confined to `UpdateService.swift` and the user-opened
      `WebMusicPlayer.swift`; launch still opens no socket
- [ ] No `Color.white`, `foregroundStyle(.white)` or `darkAqua` in `UI/` or `Notch/`
- [ ] Panel checked in **both** light and dark system appearance
- [ ] New `localized("…")` keys added to `en.lproj` **and** `ru.lproj`
- [ ] No new dependency; Sparkle still pinned to `exact: "2.9.5"`

### If this is a release

- [ ] `Scripts/version` bumped
- [ ] `docs/releases/<version>.md` written (Russian section, `---`, English summary)
- [ ] Security note added to `docs/audits/` if the change touches updates, network
      access, permissions or stored data

### If this touches `docs/`

- [ ] Version, download link and SHA-256 still come from the Releases API, not hardcoded
- [ ] Theme overrides use `background-image`, never the `background` shorthand, on
      anything that clips its background to text
- [ ] The three strings CI greps for are intact: `const RELEASE_API = …`,
      `function releaseHash(asset,body)`, `data-conversion="feedback"`

## Privacy impact

<!-- Answer explicitly, even if the answer is "none". Does this change what leaves
     the Mac, what is stored on disk, or which system permission is requested? -->
