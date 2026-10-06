// A double tap on the player, read against the grid Settings draws: the recognizer, what each cell does
// and the playback controller it does it with. Which view of the player it goes on is each look's own
// hookup (Native/Player/PlayerGestures.x, Redesigned/Player/PlayerGestures.x), which call SGGestureAttach.
//
// The player already answers a sideways swipe with the next track and a vertical drag with the
// cards below, which leaves the double tap as the one gesture free to take.
#import "Core/SGCore.h"
#import "Gestures.h"
#import "Headers/SPTNowPlayingPlaybackController.h"
#import "Shared/Player/SpeedPitch.h"

static __weak SPTNowPlayingPlaybackControllerImplementation *sg_player;
static void (^sg_observer)(SGGestureAction action);

void SGGestureSetObserver(void (^observer)(SGGestureAction action)) {
    sg_observer = [observer copy];
}

#pragma mark - what a cell does

static void perform(SGGestureAction action) {
    SPTNowPlayingPlaybackControllerImplementation *player = sg_player;
    if (!player) return;
    if (action != SGGestureNothing && sg_observer) sg_observer(action);
    switch (action) {
        case SGGestureNothing:
            break;
        case SGGestureSeekBack:
            if (player.seekingAllowed) [player seekBackwardBySeconds:SGGestureStep()];
            break;
        case SGGestureSeekForward:
            if (player.seekingAllowed) [player seekForwardBySeconds:SGGestureStep()];
            break;
        case SGGesturePlayPause:
            if (player.isPaused ? !player.disallowResuming : !player.disallowPausing) {
                [player setPaused:!player.isPaused];
            }
            break;
        case SGGestureNextTrack:
            if (player.canSkipNext) [player skipToNextWhileDragging:NO];
            break;
        case SGGesturePreviousTrack:
            [player skipToPreviousWhileDragging:NO];
            break;
        case SGGestureShuffle:
            [player setGlobalShuffleMode:!player.isShuffling];
            break;
        case SGGestureRepeat:
            [player toggleRepeatMode];
            break;
    }
}

#pragma mark - the recognizer

@interface SGGestureTarget : NSObject
@end

@implementation SGGestureTarget

- (void)doubleTapped:(UITapGestureRecognizer *)tap {
    // The recognizer outlives the switch: it stays on the player once attached, so the switch is
    // read here as well and the gesture stops the moment it goes off.
    if (!SGFlag(SGKeyGestures, NO)) return;
    // The host is the queue scrolled sideways, so a tap lands in content coordinates a few million
    // points out; its bounds origin is that scroll, and taking it off gives the point on screen.
    UIView *host = tap.view;
    CGRect visible = host.bounds;
    CGPoint point = [tap locationInView:host];
    point.x -= visible.origin.x;
    point.y -= visible.origin.y;
    NSInteger cell = SGGestureCellAt(point, visible.size);
    NSArray<NSNumber *> *zones = SGGestureZones();
    if (cell < 0 || cell >= (NSInteger)zones.count) return;
    perform((SGGestureAction)zones[(NSUInteger)cell].integerValue);
}

// Spectra: a finger held on either side of the cover plays at 2x until it lifts, the speed before
// coming back then. The middle third is left to Spotify's own touches.
- (void)held:(UILongPressGestureRecognizer *)press {
    static double before = 1;
    static BOOL holding;
    if (press.state == UIGestureRecognizerStateBegan) {
        if (!SGHidden(SGKeyHoldFaster) || !SGPlayerSpeedAllowed()) return;
        UIView *host = press.view;
        CGFloat x = [press locationInView:host].x - host.bounds.origin.x, width = host.bounds.size.width;
        if (width <= 0 || (x > width * 0.3 && x < width * 0.7)) return;
        before = SGPlayerSpeed();
        holding = YES;
        SGSetPlayerSpeed(2);
        [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
    } else if (holding && press.state != UIGestureRecognizerStateChanged) {
        holding = NO;
        SGSetPlayerSpeed(before);
    }
}

@end

static SGGestureTarget *target(void) {
    static SGGestureTarget *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [SGGestureTarget new]; });
    return shared;
}

// Spotify's own single tap on the player scrolls it to the cards below, and would fire on the first
// of a pair as well; every one above the artwork is asked to wait for the double tap to miss.
static void yieldSingleTaps(UIView *host, UITapGestureRecognizer *tap) {
    for (UIView *view = host; view; view = view.superview) {
        for (UIGestureRecognizer *other in view.gestureRecognizers) {
            if (other == tap || ![other isKindOfClass:UITapGestureRecognizer.class]) continue;
            if (((UITapGestureRecognizer *)other).numberOfTapsRequired != 1) continue;
            [other requireGestureRecognizerToFail:tap];
        }
    }
}

static char kTapKey, kSeenKey, kHoldKey;

// Spotify adds its own recognizers as the player's controllers load, which is not ordered against
// this hook: the count of what stands above the artwork is watched so a later one still yields.
static NSUInteger tapsAbove(UIView *host) {
    NSUInteger count = 0;
    for (UIView *view = host; view; view = view.superview) count += view.gestureRecognizers.count;
    return count;
}

static void attachHold(UIView *host) {
    if (!SGHidden(SGKeyHoldFaster) || objc_getAssociatedObject(host, &kHoldKey)) return;
    UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:target() action:@selector(held:)];
    press.minimumPressDuration = 0.35;
    press.cancelsTouchesInView = NO;
    [host addGestureRecognizer:press];
    objc_setAssociatedObject(host, &kHoldKey, press, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void SGGestureAttach(UIView *host) {
    if (host) attachHold(host);
    if (!host || !SGFlag(SGKeyGestures, NO)) return;
    UITapGestureRecognizer *tap = objc_getAssociatedObject(host, &kTapKey);
    if (!tap) {
        tap = [[UITapGestureRecognizer alloc] initWithTarget:target() action:@selector(doubleTapped:)];
        tap.numberOfTapsRequired = 2;
        [host addGestureRecognizer:tap];
        objc_setAssociatedObject(host, &kTapKey, tap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSNumber *seen = objc_getAssociatedObject(host, &kSeenKey);
    NSUInteger now = tapsAbove(host);
    if (seen.unsignedIntegerValue == now) return;
    objc_setAssociatedObject(host, &kSeenKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    yieldSingleTaps(host, tap);
}

#pragma mark - hooks

%hook SPTNowPlayingPlaybackControllerImplementation
- (id)initWithPlayer:(id)player testManager:(id)manager inStreamClient:(id)client {
    id controller = %orig;
    sg_player = controller;
    return controller;
}
%end

// A single tap on the cover is Spotify's way into the tilt mode, the artwork alone in 3D. That is
// the half of a double tap that misses, so while the zones are on it would open on the way to every
// gesture; the tap goes back to Spotify with the switch.
%ctor {
    %init;
    SGRequireClasses(@[@"SPTNowPlayingPlaybackControllerImplementation"]);
}
