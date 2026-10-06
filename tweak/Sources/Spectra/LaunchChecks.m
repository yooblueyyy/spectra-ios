// What runs a few seconds after Spotify comes up, once the welcome tour and the update notice have had
// their turn. Written for Spectra iOS.
//
// - What's new: the first launch of a new build shows that release's notes, read from the Spectra iOS
//   repo's GitHub release for the version (tag "v1.2.3" or "1.2.3"). The very first install only
//   remembers the version; the tour is its welcome.
// - Spotify's version: the hooks are made against one Spotify release (SPXSupportedSpotify); on any other
//   the app says so once per Spotify version, since a crash or a missing feature is then expected.
// - EeveeSpotify: two mods hooking the same classes fight, so its dylib among the loaded images is
//   pointed out, once per launch of a new combination.
//
// Main thread.
#import <mach-o/dyld.h>
#import "Core/SGCore.h"
#import "Settings/SGPageStyle.h"
#import "Spectra.h"

static NSString *const kReleaseURL = @"https://api.github.com/repos/yooblueyyy/spectra-ios/releases/tags/";
static NSString *const kWarnedSpotify = @"spotifyglass.spectra.warnedSpotify";
static NSString *const kWarnedEevee = @"spotifyglass.spectra.warnedEevee";

static NSString *spotifyVersion(void) {
    return [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown";
}

// The alert over whatever is on top, unless something else is already showing there.
static BOOL present(UIViewController *controller) {
    UIViewController *top = SGTopController();
    if (!top || [top isKindOfClass:UIAlertController.class] || top.isBeingPresented || top.isBeingDismissed) return NO;
    [top presentViewController:controller animated:YES completion:nil];
    return YES;
}

#pragma mark - What's new

@interface SPXNotesPage : UIViewController
@property (nonatomic, copy) NSString *version;
@property (nonatomic, copy) NSString *notes;
@end

@implementation SPXNotesPage

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.07 alpha:1];
    UILabel *title = [UILabel new];
    title.text = [NSString stringWithFormat:@"What's new in Spectra %@", self.version];
    title.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBold];
    title.textColor = UIColor.whiteColor;
    title.numberOfLines = 0;
    UITextView *text = [UITextView new];
    text.editable = NO;
    text.backgroundColor = UIColor.clearColor;
    text.textColor = [UIColor colorWithWhite:0.85 alpha:1];
    text.font = [UIFont systemFontOfSize:16];
    text.text = self.notes;
    UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
    [done setTitle:@"Continue" forState:UIControlStateNormal];
    done.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    done.backgroundColor = UIColor.whiteColor;
    [done setTitleColor:UIColor.blackColor forState:UIControlStateNormal];
    done.layer.cornerRadius = 25;
    [done addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    for (UIView *view in @[title, text, done]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:view];
    }
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:safe.topAnchor constant:28],
        [title.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:24],
        [title.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24],
        [text.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:12],
        [text.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [text.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
        [text.bottomAnchor constraintEqualToAnchor:done.topAnchor constant:-12],
        [done.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:24],
        [done.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24],
        [done.heightAnchor constraintEqualToConstant:50],
        [done.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-16],
    ]];
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

// Release notes are Markdown; the sheet is plain text, so headings and list marks become plain lines.
static NSString *plainNotes(NSString *markdown) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSRegularExpression *links = [NSRegularExpression regularExpressionWithPattern:@"\\s*\\(\\[[0-9a-f]{7}\\]\\([^)]*\\)\\)|\\[([^\\]]+)\\]\\([^)]*\\)" options:0 error:nil];
    for (NSString *raw in [markdown componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        line = [links stringByReplacingMatchesInString:line options:0 range:NSMakeRange(0, line.length) withTemplate:@"$1"];
        if ([line hasPrefix:@"#"]) {
            line = [[line stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"# "]] uppercaseString];
            if (lines.count) [lines addObject:@""];
        } else if ([line hasPrefix:@"* "] || [line hasPrefix:@"- "]) {
            line = [@"• " stringByAppendingString:[line substringFromIndex:2]];
        }
        if (line.length || (lines.count && [lines.lastObject length])) [lines addObject:line];
    }
    return [[lines componentsJoinedByString:@"\n"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

// Tries each tag in turn: "v1.2.3", then "1.2.3". `done` gets nil when neither has notes.
static void fetchTag(NSArray<NSString *> *tags, NSUInteger index, void (^done)(NSString *notes)) {
    if (index >= tags.count) {
        dispatch_async(dispatch_get_main_queue(), ^{ done(nil); });
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[kReleaseURL stringByAppendingString:tags[index]]]];
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    request.timeoutInterval = 15;
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        id release = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        id body = [release isKindOfClass:NSDictionary.class] ? release[@"body"] : nil;
        if ([body isKindOfClass:NSString.class] && [body length]) {
            NSString *notes = plainNotes(body);
            dispatch_async(dispatch_get_main_queue(), ^{ done(notes); });
            return;
        }
        fetchTag(tags, index + 1, done);
    }] resume];
}

static void fetchNotes(NSString *version, void (^done)(NSString *notes)) {
    fetchTag(@[[@"v" stringByAppendingString:version], version], 0, done);
}

void SPXShowWhatsNew(BOOL always) {
    NSString *version = @(SG_VERSION);
    NSUserDefaults *store = NSUserDefaults.standardUserDefaults;
    NSString *seen = [store stringForKey:SPXKeySeenVersion];
    if (!always) {
        if ([seen isEqualToString:version]) return;
        [store setObject:version forKey:SPXKeySeenVersion];
        if (!seen) return;   // a first install: the tour is its welcome
    }
    fetchNotes(version, ^(NSString *notes) {
        if (!notes.length) {
            if (!always) return;
            notes = @"There are no release notes for this version yet.";
        }
        SPXNotesPage *page = [SPXNotesPage new];
        page.version = version;
        page.notes = notes;
        page.modalPresentationStyle = UIModalPresentationPageSheet;
        present(page);
    });
}

#pragma mark - warnings

static void warn(NSString *title, NSString *message, NSString *rememberKey, NSString *rememberValue) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [NSUserDefaults.standardUserDefaults setObject:rememberValue forKey:rememberKey];
    }]];
    present(alert);
}

static NSString *eeveeImage(void) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *path = _dyld_get_image_name(i);
        if (!path) continue;
        NSString *name = [@(path) lastPathComponent];
        if ([name.lowercaseString containsString:@"eevee"]) return name;
    }
    return nil;
}

static void checkSpotifyVersion(void) {
    if (!SGEnabled(SPXKeyVersionWarning)) return;
    NSString *version = spotifyVersion();
    if ([version isEqualToString:SPXSupportedSpotify]) return;
    if ([[NSUserDefaults.standardUserDefaults stringForKey:kWarnedSpotify] isEqualToString:version]) return;
    warn(@"Different Spotify version",
         [NSString stringWithFormat:@"Spectra %s is made for Spotify %@ and this is Spotify %@. Some features may not work and the app may crash. "
                                    @"Build Spectra with a Spotify %@ IPA for the best results.", SG_VERSION, SPXSupportedSpotify, version, SPXSupportedSpotify],
         kWarnedSpotify, version);
}

static BOOL checkEevee(void) {
    NSString *image = eeveeImage();
    if (!image) return NO;
    NSString *combination = [NSString stringWithFormat:@"%s/%@", SG_VERSION, spotifyVersion()];
    if ([[NSUserDefaults.standardUserDefaults stringForKey:kWarnedEevee] isEqualToString:combination]) return NO;
    warn(@"EeveeSpotify is injected too",
         [NSString stringWithFormat:@"%@ is loaded alongside Spectra. Both change the same parts of Spotify, which can freeze or crash the app. "
                                    @"Build Spectra from a Spotify IPA without EeveeSpotify.", image],
         kWarnedEevee, combination);
    return YES;
}

__attribute__((constructor)) static void SPXLaunchChecks(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (checkEevee()) return;
        checkSpotifyVersion();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ SPXShowWhatsNew(NO); });
    });
}
