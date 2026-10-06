# Spectra iOS

Spectra for the Spotify iOS app: Liquid Glass, karaoke lyrics, more lyric sources, lock-screen
lyrics, a Live Activity, the JamesDSP equaliser, music haptics, speed and pitch, artist block,
gestures, ad and upsell hiding, Spotify's experiment flags and privacy switches.

Spectra's own additions, under **Mod Settings > Spectra**:

- **Spectra dashboard**: the dashboard's Extensions, Snippets and Admin panel, in the app
- **Sing**: turns the song's vocals down so you can sing over it, live
- **Reverb**, with a room size
- **Pitch follows speed**: a faster song plays higher, like a record, without time-stretch smearing
- **Hold the cover's sides for 2x**
- **Listening stats** kept on the phone, with Spotify's own data export imported
- **AirPods head gestures**: a double nod and a shake of the head, each set to an action
- **Apple Music red** accent, **What's new** after an update, and warnings for an unsupported
  Spotify version or EeveeSpotify injected alongside

A no-jailbreak Theos tweak, injected into **your own** decrypted Spotify IPA and signed with your own
certificate or signer. No IPA is distributed here.

Part of [Spectra](https://usespectra.xyz), which also covers Spotify on the web, desktop and Quest.

## Credits

Spectra iOS is a fork of **[spoti.pw](https://github.com/skopevoj/spoti.pw/tree/v0.21.1) by
skopevoj**, from its **v0.21.1** release, the last one published under GPL-3.0. The first paragraph
above is spoti.pw's work; support its author at [ko-fi.com/darkksh](https://ko-fi.com/darkksh).
Later spoti.pw releases are under another licence and none of their code is used here: Spectra's
additions are written for Spectra.

## Requirements

| | |
|---|---|
| Spotify IPA | **9.1.78**, decrypted (the version spoti.pw v0.21.1 was built for) |
| Redesign (Liquid Glass) | iOS 26+ |
| Legacy look | iOS 16.1+ |
| Live Activity | iOS 17+ |

The tweak hooks Spotify's own classes, which change between releases. Another Spotify version may
build and then crash or lose features.

## Build it

On a Mac with Theos in `~/theos`, Xcode with an iPhoneOS 26+ SDK, and:

    brew install make ldid dpkg
    pipx install "git+https://github.com/asdfzxcvbn/pyzule-rw"

Put the decrypted `.ipa` in `ipa/`, then:

    make release    # out/Spectra-iOS-<version>.ipa, unsigned

With the Spectra repo's `extension/` folder beside this one (or `SPECTRA_EXTENSION` pointing at
it), the build also puts the dashboard in the app.

## Signing

Sign with SideStore, AltStore, Sideloadly, Feather or any certificate signer. Use a bundle id that
matches your certificate's App ID, otherwise tapping the player on the lock screen won't open the app.
Free Apple IDs can only sign a few app ids, so keep the app's extensions to a minimum there.

## Changes from spoti.pw v0.21.1

- **Spoof Premium removed.** `tweak/Sources/Shared/AdBlock/Premium.m` is replaced by stubs that pass
  everything through; `Crossfade.x` (only active under Spoof Premium) is removed; the switch and its
  section are gone from the settings page, now named "Ads & privacy" (`AdBlockSettings.m`,
  `AdBlock.h`, `AdNetwork.x`, `ModSettings.x`).
- **No install counts.** `App/About/Usage.m` never sends usage data; the update check
  (`App/About/Update.m`) asks this repo's GitHub releases directly instead of spoti.pw's server.
- **Links and names** point to Spectra (`Settings/SGPageStyle.m`, `App/About/Signing.m`,
  `Shared/LyricsSources/LrcLib.m`, `App/ModSettings.x`, `tweak/control`, `scripts/pipeline.sh`).
- **Spicy Lyrics is not offered** as a lyrics source (`LyricsSources.m`): its author's permission
  to reach his API that way was given to spoti.pw.
- **No donation prompts** (`App/Donate/Donate.m`); spoti.pw is credited in the app under
  Spectra > Credits & licences.
- **Pitch follows speed** added to `Shared/Player/SpeedPitch.x`, **hold for 2x** to
  `Shared/Gestures/Gestures.x`; everything else Spectra adds is in `tweak/Sources/Spectra/` and
  `dashboard/`.
- Spectra's own version numbers (`version.txt`), changelog and README. spoti.pw's release
  automation, GitHub Actions, AI agent notes, screenshots and icon are not included.

## Licence

GPL-3.0, the same as spoti.pw v0.21.1 (see [LICENSE](LICENSE)). JamesDSP in `vendor/libjamesdsp` keeps
its own licence. The ad blocking is ported by spoti.pw from
[EeveeSpotify Reincarnated](https://github.com/SideloadLabs/EeveeSpotifyReincarnated). Built with
[Theos](https://theos.dev) and injected with [cyan](https://github.com/asdfzxcvbn/pyzule-rw).
[FLEX](https://github.com/FLEXTool/FLEX) (hopeless's AutoFLEX build in `vendor/`) is only used for
development builds.

Not affiliated with Spotify or with spoti.pw.
