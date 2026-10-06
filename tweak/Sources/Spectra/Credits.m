// Credits and licences: who Spectra iOS is built on, and the licences their work comes under.
// Written for Spectra iOS.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Spectra.h"

UIViewController *SPXCreditsPage(void) {
    return [[SGModPage alloc] initWithTitle:@"Credits & licences" intro:nil sections:@[
        SGNotedSection(@"Built on", @[
            SGWithSymbol(SGLinkRow(@"spoti.pw by skopevoj", @"Spectra iOS is a fork of spoti.pw v0.21.1, the Liquid Glass redesign, karaoke lyrics and much more",
                                   @"https://github.com/skopevoj/spoti.pw/tree/v0.21.1"), @"heart"),
            SGWithSymbol(SGLinkRow(@"Support spoti.pw's author", @"ko-fi.com/darkksh", @"https://ko-fi.com/darkksh"), @"cup.and.saucer"),
        ], @"spoti.pw v0.21.1 was published under GPL-3.0. Later spoti.pw releases are under another licence, and none of their code is in Spectra; Spectra's newer features are its own."),
        SGSection(@"Also thanks to", @[
            SGLinkRow(@"EeveeSpotify Reincarnated", @"The ad blocking, ported by spoti.pw", @"https://github.com/SideloadLabs/EeveeSpotifyReincarnated"),
            SGLinkRow(@"JamesDSP", @"The audio effects engine (libjamesdsp)", @"https://github.com/Audio4Linux/JDSP4Linux"),
            SGLinkRow(@"LRCLIB", @"Synced lyrics", @"https://lrclib.net"),
            SGLinkRow(@"Theos", @"Builds the tweak", @"https://theos.dev"),
            SGLinkRow(@"cyan", @"Injects it into your IPA", @"https://github.com/asdfzxcvbn/pyzule-rw"),
        ]),
        SGNotedSection(@"Licences", @[
            SGLinkRow(@"Spectra iOS", @"GNU General Public License v3.0", @"https://github.com/yooblueyyy/spectra-ios/blob/main/LICENSE"),
            SGLinkRow(@"libjamesdsp", @"Its own licence, in vendor/libjamesdsp", @"https://github.com/yooblueyyy/spectra-ios/tree/main/vendor/libjamesdsp"),
            SGLinkRow(@"Source code", @"github.com/yooblueyyy/spectra-ios", @"https://github.com/yooblueyyy/spectra-ios"),
        ], @"Spectra is not affiliated with Spotify or with spoti.pw."),
    ] footer:nil];
}
