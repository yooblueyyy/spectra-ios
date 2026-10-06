// AirPods head gestures: a double nod and a shake of the head, each doing what its row says, while
// headphones that report head motion (AirPods Pro, Max, 3rd generation and later, Beats Fit Pro) are in.
// Written for Spectra iOS.
//
// CMHeadphoneMotionManager reports the head's rotation rate. A nod turns the head about its x axis
// (pitch), a shake about its z axis (yaw). A gesture is a quick back and forth: the rate crosses a
// threshold one way, then the other, then the first way again, all within a second, while the other axis
// stays calmer, so turning to look at something counts as neither. After a gesture the next one waits a
// moment, so one nod is not read twice.
//
// Asking for motion shows iOS's prompt once; Info.plist carries the reason (plist/liquid-glass.plist).
// Main thread, except the motion handler, which is handed the main queue.
#import <CoreMotion/CoreMotion.h>
#import "Core/SGCore.h"
#import "Headers/SPTPlayer.h"
#import "Settings/SGModPage.h"
#import "Spectra.h"

typedef NS_ENUM(NSInteger, SPXHeadAction) {
    SPXHeadNothing = 0,
    SPXHeadPlayPause,
    SPXHeadNext,
    SPXHeadPrevious,
    SPXHeadRestart,
};

static const double kThreshold = 1.6;      // rad/s
static const double kWindow = 1.0;         // s, from the first swing to the last
static const double kCooldown = 1.2;       // s

NSArray<NSString *> *SPXHeadActionNames(void) {
    return @[@"Nothing", @"Play or pause", @"Next track", @"Previous track", @"Restart the track"];
}

#pragma mark - the player

static __weak id sg_player;

%hook SPTEsperantoPlayer
- (void)addPlayerObserver:(id)observer {
    %orig;
    if (!sg_player) sg_player = self;
}
%end

static void perform(SPXHeadAction action) {
    id<SPTPlayer> player = sg_player;
    if (!player || action == SPXHeadNothing) return;
    SGLog(@"head gestures: %@", SPXHeadActionNames()[action]);
    SPTPlayerState *state = [player respondsToSelector:@selector(state)] ? player.state : nil;
    switch (action) {
        case SPXHeadPlayPause:
            if (state.isPaused || !state.isPlaying) {
                if ([player respondsToSelector:@selector(resume:)]) [player resume:nil];
            } else if ([player respondsToSelector:@selector(pause:)]) {
                [player pause:nil];
            }
            break;
        case SPXHeadNext:
            if ([player respondsToSelector:@selector(skipToNextTrack)]) [player skipToNextTrack];
            break;
        case SPXHeadPrevious:
            if ([player respondsToSelector:@selector(skipToPreviousTrackWithOptions:)]) [player skipToPreviousTrackWithOptions:nil];
            break;
        case SPXHeadRestart:
            if ([player respondsToSelector:@selector(seekTo:)]) [player seekTo:0];
            break;
        case SPXHeadNothing:
            break;
    }
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
}

#pragma mark - reading the head

// One axis's swings: the sign of the last one past the threshold, how many alternated, and when the first was.
typedef struct {
    int sign, swings;
    double firstAt;
} Swings;

static BOOL swung(Swings *axis, double rate, double calmer, double now) {
    if (axis->swings && now - axis->firstAt > kWindow) *axis = (Swings){0};
    if (fabs(rate) < kThreshold || fabs(calmer) > fabs(rate) * 0.8) return NO;
    int sign = rate > 0 ? 1 : -1;
    if (sign == axis->sign) return NO;
    if (!axis->swings) axis->firstAt = now;
    axis->sign = sign;
    axis->swings++;
    if (axis->swings < 3) return NO;
    *axis = (Swings){0};
    return YES;
}

static CMHeadphoneMotionManager *sg_manager;
static Swings sg_nod, sg_shake;
static double sg_quietUntil;

static void stopListening(void) {
    if (sg_manager.deviceMotionActive) [sg_manager stopDeviceMotionUpdates];
}

static void startListening(void) {
    if (!SGHidden(SPXKeyHeadGestures)) {
        stopListening();
        return;
    }
    sg_manager = sg_manager ?: [CMHeadphoneMotionManager new];
    if (!sg_manager.deviceMotionAvailable || sg_manager.deviceMotionActive) return;
    [sg_manager startDeviceMotionUpdatesToQueue:NSOperationQueue.mainQueue withHandler:^(CMDeviceMotion *motion, NSError *error) {
        if (!motion) return;
        double now = motion.timestamp;
        if (now < sg_quietUntil) return;
        CMRotationRate rate = motion.rotationRate;
        if (swung(&sg_nod, rate.x, rate.z, now)) {
            sg_shake = (Swings){0};
            sg_quietUntil = now + kCooldown;
            perform((SPXHeadAction)SGInt(SPXKeyNodAction, SPXHeadPlayPause));
        } else if (swung(&sg_shake, rate.z, rate.x, now)) {
            sg_nod = (Swings){0};
            sg_quietUntil = now + kCooldown;
            perform((SPXHeadAction)SGInt(SPXKeyShakeAction, SPXHeadNext));
        }
    }];
}

#pragma mark - the page

NSString *SPXHeadGesturesSummary(void) {
    return SGHidden(SPXKeyHeadGestures) ? @"On" : @"Off";
}

UIViewController *SPXHeadGesturesPage(void) {
    SGModRow *toggle = SGWithSymbol(SGOptionRow(@"AirPods head gestures", nil, SPXKeyHeadGestures), @"airpodspro");
    toggle.changed = ^(BOOL on) { on ? startListening() : stopListening(); };
    SGModRow *nod = SGChoiceRow(@"Double nod", nil, SPXKeyNodAction, SPXHeadActionNames(), SPXHeadPlayPause);
    SGModRow *shake = SGChoiceRow(@"Shake your head", nil, SPXKeyShakeAction, SPXHeadActionNames(), SPXHeadNext);
    nod.visible = shake.visible = ^BOOL { return SGHidden(SPXKeyHeadGestures); };
    return [[SGModPage alloc] initWithTitle:@"Head gestures" intro:nil sections:@[
        SGNotedSection(nil, @[toggle], @"Needs AirPods (3rd generation or later, Pro or Max) or Beats that track head movement. iOS asks once for Motion & Fitness."),
        SGSection(@"Gestures", @[nod, shake]),
    ] footer:nil];
}

%ctor {
    %init;
    dispatch_async(dispatch_get_main_queue(), ^{
        startListening();
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *note) { startListening(); }];
    });
}
