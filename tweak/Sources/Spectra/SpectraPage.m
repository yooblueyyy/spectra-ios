// The Spectra page at the top of Mod Settings: the dashboard, Sing, Reverb and the rest of what Spectra
// adds, each applying as it changes unless its note says otherwise. Written for Spectra iOS.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "Native/Appearance/Appearance.h"
#import "Redesigned/Kit/SGRAccent.h"
#import "Shared/Gestures/Gestures.h"
#import "Shared/Player/SpeedPitch.h"
#import "Spectra.h"

static const NSInteger kAppleMusicRed = 0xFA2D48;

static NSString *percent(double value) {
    return value <= 0 ? @"Off" : [NSString stringWithFormat:@"%.0f%%", value];
}

static void useAppleMusicRed(void) {
    SGSetInt(SGKeyAccent, kAppleMusicRed);
    SGSetInt(SGRKeyAccent, kAppleMusicRed);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Apple Music red"
                                                                   message:@"The accent colour is Apple Music's red in both looks. Restart Spotify to see it everywhere."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Later" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Restart" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { SGRestartSpotify(); }]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

UIViewController *SPXSpectraPage(void) {
    SGModRow *dashboard = SGWithSymbol(SGActionRow(@"Spectra dashboard", @"Extensions, snippets and the admin panel", ^{ SPXOpenDashboard(); }),
                                       @"square.grid.2x2");

    SGModRow *sing = SGSliderRow(@"Sing", @"Turns the song's vocals down so you can sing over it", 0, 100, 5,
                                 ^double { return SPXSing() * 100; },
                                 ^(double value) { SPXSetSing((float)(value / 100)); },
                                 ^NSString *(double value) { return percent(value); });
    SGModRow *reverb = SGSliderRow(@"Reverb", nil, 0, 100, 5,
                                   ^double { return SPXReverb() * 100; },
                                   ^(double value) { SPXSetReverb((float)(value / 100)); },
                                   ^NSString *(double value) { return percent(value); });
    SGModRow *room = SGSliderRow(@"Room size", nil, 0, 100, 5,
                                 ^double { return SPXReverbRoom() * 100; },
                                 ^(double value) { SPXSetReverbRoom((float)(value / 100)); },
                                 ^NSString *(double value) { return [NSString stringWithFormat:@"%.0f%%", value]; });
    room.visible = ^BOOL { return SPXReverb() > 0; };

    SGModRow *stats = SGWithSymbol(SGPageRow(@"Listening stats", ^UIViewController *{ return SPXStatsPage(); }), @"chart.bar.xaxis");
    stats.value = ^NSString *{ return SPXStatsSummary(); };
    SGModRow *head = SGWithSymbol(SGPageRow(@"AirPods head gestures", ^UIViewController *{ return SPXHeadGesturesPage(); }), @"airpodspro");
    head.value = ^NSString *{ return SPXHeadGesturesSummary(); };

    return [[SGModPage alloc] initWithTitle:@"Spectra" intro:nil sections:@[
        SGNotedSection(nil, @[dashboard], @"The same dashboard as Spectra on the web, desktop and Quest. Spotify on iPhone is a native app, so web extensions and snippets saved there apply in Spectra's other apps."),
        SGNotedSection(@"Sing & sound", @[sing, reverb, room],
                       @"Both apply straight away. Sing works best on songs mixed with the voice in the middle, which is most of them."),
        SGNotedSection(@"Playback", @[
            SGWithSymbol(SGSwitchRow(@"Pitch follows speed", @"A faster song plays higher too, like a record", SGKeyPitchFollowsSpeed), @"tortoise"),
            SGWithSymbol(SGOptionRow(@"Hold the cover's sides for 2x", @"Plays twice as fast until you lift your finger", SGKeyHoldFaster), @"hare"),
        ], @"Speed itself is in the player's ⋯ menu. Hold for 2x needs a Spotify restart the first time."),
        SGSection(nil, @[stats, head]),
        SGNotedSection(@"Look", @[
            SGWithSymbol(SGActionRow(@"Use Apple Music red", @"As the accent colour, in either look", ^{ useAppleMusicRed(); }), @"paintpalette"),
        ], nil),
        SGSection(@"Spectra", @[
            SGWithSymbol(SGSwitchRow(@"Warn about other Spotify versions", [NSString stringWithFormat:@"Spectra is made for Spotify %@", SPXSupportedSpotify],
                                     SPXKeyVersionWarning), @"exclamationmark.triangle"),
            SGWithSymbol(SGActionRow(@"What's new", nil, ^{ SPXShowWhatsNew(YES); }), @"sparkles"),
            SGWithSymbol(SGPageRow(@"Credits & licences", ^UIViewController *{ return SPXCreditsPage(); }), @"heart"),
            SGWithSymbol(SGLinkRow(@"usespectra.xyz", nil, @"https://usespectra.xyz"), @"globe"),
        ]),
    ] footer:nil];
}
