// Spectra's own features, written for Spectra iOS on top of the GPL-3.0 base (see README.md):
//
//     SpectraFX.x        Sing (the song's vocals turned down) and Reverb, done to Spotify's finished sound
//     Stats.m            listening stats kept on the phone, with Spotify's own data export imported
//     HeadGestures.m     AirPods head gestures: a double nod and a shake of the head
//     LaunchChecks.m     what's new after an update, the Spotify version and EeveeSpotify warnings
//     Dashboard.m        the Spectra dashboard (extensions, snippets, admin) in a web view
//     Credits.m          credits and licences
//     SpectraPage.m      the Spectra page in Mod Settings that holds all of the above
//
// Keys start with "spotifyglass." like every other setting, so Reset all settings sweeps them too.
#import <UIKit/UIKit.h>

#pragma mark - keys

#define SPXKeySing            @"spotifyglass.spectra.sing"            // 0...1, how far the vocals go down
#define SPXKeyReverb          @"spotifyglass.spectra.reverb"          // 0...1, wet mix
#define SPXKeyReverbRoom      @"spotifyglass.spectra.reverb.room"     // 0...1, room size
#define SPXKeyStats           @"spotifyglass.spectra.stats"           // listening stats, on until switched off
#define SPXKeyHeadGestures    @"spotifyglass.spectra.headGestures"    // off until asked for
#define SPXKeyNodAction       @"spotifyglass.spectra.headGestures.nod"
#define SPXKeyShakeAction     @"spotifyglass.spectra.headGestures.shake"
#define SPXKeyVersionWarning  @"spotifyglass.spectra.versionWarning"  // on until switched off
#define SPXKeySeenVersion     @"spotifyglass.spectra.seenVersion"     // the build last opened, for What's new

// The Spotify version this build's hooks were made against.
#define SPXSupportedSpotify   @"9.1.78"

#pragma mark - SpectraFX.x

// Both apply as they change, from any slider; the sound is untouched while both are 0.
float SPXSing(void);
void SPXSetSing(float amount);
float SPXReverb(void);
void SPXSetReverb(float mix);
float SPXReverbRoom(void);
void SPXSetReverbRoom(float room);
// Whether Spotify's output has been reached, so the sliders can say when they cannot work yet.
BOOL SPXEffectsReady(void);

#pragma mark - Stats.m

UIViewController *SPXStatsPage(void);
NSString *SPXStatsSummary(void);   // "12 h this week", for the row's value

#pragma mark - HeadGestures.m

NSArray<NSString *> *SPXHeadActionNames(void);
UIViewController *SPXHeadGesturesPage(void);
NSString *SPXHeadGesturesSummary(void);

#pragma mark - LaunchChecks.m

void SPXShowWhatsNew(BOOL always);   // the notes of the running build's release, once per version unless `always`

#pragma mark - Dashboard.m

// The dashboard's Extensions, Snippets and Admin, in a sheet over the app.
void SPXOpenDashboard(void);

#pragma mark - Credits.m

UIViewController *SPXCreditsPage(void);

#pragma mark - SpectraPage.m

UIViewController *SPXSpectraPage(void);
