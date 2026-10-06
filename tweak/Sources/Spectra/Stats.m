// Listening stats, kept on the phone and nowhere else. Written for Spectra iOS.
//
// The player's state (Shared/Player/PlayerState.h) says when a track starts, pauses and changes; the time
// between a track starting to play and it stopping or changing is added to that track, its artist and
// the day. A play is counted once a track has been listened to for 30 seconds, Spotify's own rule.
//
// Spotify's data export can be imported (Settings > Privacy on spotify.com): the account data's
// StreamingHistory_music_*.json and the extended history's Streaming_History_Audio_*.json both work,
// several files at once. What is imported is added to what the phone counted.
//
// The stats live in Documents/Spectra/stats.json, written a few seconds after a change and when the app
// goes to the background. Main thread throughout.
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "Shared/Player/PlayerState.h"
#import "Spectra.h"

static const double kPlayAfter = 30;
static const NSUInteger kTopCount = 15;

#pragma mark - the store

// tracks: key -> {title, artist, seconds, plays}; artists: name -> {seconds, plays}; days: yyyy-MM-dd -> seconds.
static NSMutableDictionary *sg_stats;
static BOOL sg_saveQueued;

static NSURL *statsURL(void) {
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *folder = [documents URLByAppendingPathComponent:@"Spectra" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
    return [folder URLByAppendingPathComponent:@"stats.json"];
}

static NSMutableDictionary *mutableTree(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return [NSMutableDictionary dictionary];
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    id copy = data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil] : nil;
    return [copy isKindOfClass:NSMutableDictionary.class] ? copy : [NSMutableDictionary dictionary];
}

static NSMutableDictionary *stats(void) {
    if (sg_stats) return sg_stats;
    NSData *data = [NSData dataWithContentsOfURL:statsURL()];
    id saved = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    sg_stats = mutableTree(saved);
    for (NSString *part in @[@"tracks", @"artists", @"days"]) {
        if (![sg_stats[part] isKindOfClass:NSMutableDictionary.class]) sg_stats[part] = [NSMutableDictionary dictionary];
    }
    return sg_stats;
}

static void saveNow(void) {
    sg_saveQueued = NO;
    if (!sg_stats) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:sg_stats options:0 error:nil];
    if (data) [data writeToURL:statsURL() options:NSDataWritingAtomic error:nil];
}

static void saveSoon(void) {
    if (sg_saveQueued) return;
    sg_saveQueued = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ saveNow(); });
}

static NSString *dayKey(NSDate *date) {
    static NSDateFormatter *format;
    if (!format) {
        format = [NSDateFormatter new];
        format.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        format.dateFormat = @"yyyy-MM-dd";
    }
    return [format stringFromDate:date];
}

static void addListening(NSString *key, NSString *title, NSString *artist, double seconds, NSInteger plays, NSDate *when) {
    if (!key.length || seconds <= 0) return;
    NSMutableDictionary *all = stats();
    NSMutableDictionary *track = all[@"tracks"][key];
    if (!track) {
        track = [NSMutableDictionary dictionaryWithDictionary:@{@"title": title ?: @"", @"artist": artist ?: @"", @"seconds": @0, @"plays": @0}];
        all[@"tracks"][key] = track;
    }
    track[@"seconds"] = @([track[@"seconds"] doubleValue] + seconds);
    track[@"plays"] = @([track[@"plays"] integerValue] + plays);
    if (artist.length) {
        NSMutableDictionary *entry = all[@"artists"][artist];
        if (!entry) {
            entry = [NSMutableDictionary dictionaryWithDictionary:@{@"seconds": @0, @"plays": @0}];
            all[@"artists"][artist] = entry;
        }
        entry[@"seconds"] = @([entry[@"seconds"] doubleValue] + seconds);
        entry[@"plays"] = @([entry[@"plays"] integerValue] + plays);
    }
    NSString *day = dayKey(when ?: NSDate.date);
    all[@"days"][day] = @([all[@"days"][day] doubleValue] + seconds);
    saveSoon();
}

#pragma mark - following the player

@interface SPXStatsObserver : NSObject <SGPlayerStateObserver>
@end

@implementation SPXStatsObserver {
    NSString *_key, *_title, *_artist;
    NSDate *_since;            // when the current stretch of playing started, nil while not playing
    double _listened;          // this track's seconds so far, for the 30 second play
    BOOL _counted;
}

- (void)closeStretch {
    if (!_since || !_key) {
        _since = nil;
        return;
    }
    double seconds = -_since.timeIntervalSinceNow;
    _since = nil;
    // A stretch longer than any track is the phone having slept through a pause it never reported.
    if (seconds <= 0 || seconds > 3 * 60 * 60) return;
    _listened += seconds;
    NSInteger play = 0;
    if (!_counted && _listened >= kPlayAfter) {
        _counted = YES;
        play = 1;
    }
    addListening(_key, _title, _artist, seconds, play, nil);
}

- (void)playerStateDidChange:(SPTPlayerState *)state {
    if (!SGEnabled(SPXKeyStats)) return;
    SPTPlayerTrack *track = [state respondsToSelector:@selector(track)] ? state.track : nil;
    NSString *uri = track ? SGURIString(track.URI) : nil;
    BOOL playing = state.isPlaying && !state.isPaused && !state.isLoading;
    if (![uri isEqualToString:_key]) {
        [self closeStretch];
        _key = uri;
        _title = [track respondsToSelector:@selector(trackTitle)] ? track.trackTitle : nil;
        _artist = [track respondsToSelector:@selector(artistName)] ? track.artistName : nil;
        _listened = 0;
        _counted = NO;
    }
    if (playing && !_since && _key) _since = NSDate.date;
    if (!playing && _since) [self closeStretch];
}

- (void)background {
    if (_since) {
        [self closeStretch];
        _since = NSDate.date;   // still playing in the background; the next stretch starts now
    }
    saveNow();
}

@end

static SPXStatsObserver *sg_observer;

#pragma mark - reading the stats

static NSString *duration(double seconds) {
    if (seconds < 60) return @"< 1 min";
    long minutes = (long)(seconds / 60);
    if (minutes < 60) return [NSString stringWithFormat:@"%ld min", minutes];
    return [NSString stringWithFormat:@"%ld h %ld min", minutes / 60, minutes % 60];
}

static double secondsSince(NSInteger daysBack) {
    NSDictionary *days = stats()[@"days"];
    if (daysBack < 0) {
        double total = 0;
        for (NSNumber *value in days.allValues) total += value.doubleValue;
        return total;
    }
    double total = 0;
    for (NSInteger i = 0; i < daysBack; i++) {
        total += [days[dayKey([NSDate dateWithTimeIntervalSinceNow:-i * 86400.0])] doubleValue];
    }
    return total;
}

NSString *SPXStatsSummary(void) {
    if (!SGEnabled(SPXKeyStats)) return @"Off";
    return [duration(secondsSince(7)) stringByAppendingString:@" this week"];
}

static NSArray<NSString *> *topKeys(NSDictionary *table) {
    NSArray *sorted = [table keysSortedByValueUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [(NSNumber *)b[@"seconds"] compare:(NSNumber *)a[@"seconds"]];
    }];
    return [sorted subarrayWithRange:NSMakeRange(0, MIN(kTopCount, sorted.count))];
}

#pragma mark - importing Spotify's export

static NSUInteger importEntries(NSArray *entries) {
    NSUInteger added = 0;
    NSISO8601DateFormatter *iso = [NSISO8601DateFormatter new];
    NSDateFormatter *plain = [NSDateFormatter new];
    plain.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    plain.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    plain.dateFormat = @"yyyy-MM-dd HH:mm";
    for (NSDictionary *entry in entries) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        // Extended history: ts, ms_played, master_metadata_*, spotify_track_uri. Account data: endTime, msPlayed, artistName, trackName.
        NSString *title = entry[@"master_metadata_track_name"] ?: entry[@"trackName"];
        NSString *artist = entry[@"master_metadata_album_artist_name"] ?: entry[@"artistName"];
        id ms = entry[@"ms_played"] ?: entry[@"msPlayed"];
        if (![title isKindOfClass:NSString.class] || ![ms respondsToSelector:@selector(doubleValue)]) continue;
        if (![artist isKindOfClass:NSString.class]) artist = @"";
        NSString *uri = [entry[@"spotify_track_uri"] isKindOfClass:NSString.class] ? entry[@"spotify_track_uri"] : nil;
        NSString *key = uri.length ? uri : [NSString stringWithFormat:@"%@ — %@", artist, title];
        NSDate *when = nil;
        if ([entry[@"ts"] isKindOfClass:NSString.class]) when = [iso dateFromString:entry[@"ts"]];
        if (!when && [entry[@"endTime"] isKindOfClass:NSString.class]) when = [plain dateFromString:entry[@"endTime"]];
        double seconds = [ms doubleValue] / 1000.0;
        addListening(key, title, artist, seconds, seconds >= kPlayAfter ? 1 : 0, when);
        added++;
    }
    return added;
}

@interface SPXStatsImporter : NSObject <UIDocumentPickerDelegate>
@property (nonatomic, weak) UIViewController *page;
@end

@implementation SPXStatsImporter

- (void)documentPicker:(UIDocumentPickerViewController *)picker didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSUInteger added = 0, files = 0;
    for (NSURL *url in urls) {
        BOOL scoped = [url startAccessingSecurityScopedResource];
        NSData *data = [NSData dataWithContentsOfURL:url];
        if (scoped) [url stopAccessingSecurityScopedResource];
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![json isKindOfClass:NSArray.class]) continue;
        files++;
        added += importEntries(json);
    }
    saveNow();
    NSString *message = files
        ? [NSString stringWithFormat:@"Added %lu plays from %lu file%@.", (unsigned long)added, (unsigned long)files, files == 1 ? @"" : @"s"]
        : @"None of those files is a Spotify streaming history (StreamingHistory_music_*.json or Streaming_History_Audio_*.json).";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Import" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

@end

static SPXStatsImporter *sg_importer;

static void importExport(void) {
    sg_importer = sg_importer ?: [SPXStatsImporter new];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeJSON] asCopy:YES];
    picker.allowsMultipleSelection = YES;
    picker.delegate = sg_importer;
    [SGTopController() presentViewController:picker animated:YES completion:nil];
}

static void resetStats(void) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Reset listening stats?"
                                                                   message:@"Everything counted on this phone and everything imported is deleted."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        sg_stats = nil;
        [NSFileManager.defaultManager removeItemAtURL:statsURL() error:nil];
    }]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

#pragma mark - the page

UIViewController *SPXStatsPage(void) {
    [sg_observer background];   // the current stretch counts in what the page shows
    NSDictionary *all = stats();
    NSMutableArray<SGModRow *> *tracks = [NSMutableArray array];
    for (NSString *key in topKeys(all[@"tracks"])) {
        NSDictionary *track = all[@"tracks"][key];
        double seconds = [track[@"seconds"] doubleValue];
        [tracks addObject:SGStatRow([NSString stringWithFormat:@"%@ · %@", track[@"title"], track[@"artist"]],
                                    ^NSString *{ return duration(seconds); })];
    }
    NSMutableArray<SGModRow *> *artists = [NSMutableArray array];
    for (NSString *name in topKeys(all[@"artists"])) {
        double seconds = [all[@"artists"][name][@"seconds"] doubleValue];
        [artists addObject:SGStatRow(name, ^NSString *{ return duration(seconds); })];
    }
    NSInteger plays = 0;
    for (NSDictionary *track in [all[@"tracks"] allValues]) plays += [track[@"plays"] integerValue];

    NSMutableArray *sections = [NSMutableArray arrayWithObject:SGNotedSection(nil, @[
        SGWithSymbol(SGSwitchRow(@"Count my listening", nil, SPXKeyStats), @"chart.bar"),
    ], @"Kept only on this iPhone, in Spotify's Documents folder.")];
    [sections addObject:SGSection(@"Listening time", @[
        SGStatRow(@"Today", ^NSString *{ return duration(secondsSince(1)); }),
        SGStatRow(@"Last 7 days", ^NSString *{ return duration(secondsSince(7)); }),
        SGStatRow(@"Last 30 days", ^NSString *{ return duration(secondsSince(30)); }),
        SGStatRow(@"All time", ^NSString *{ return duration(secondsSince(-1)); }),
        SGStatRow(@"Plays", ^NSString *{ return @(plays).stringValue; }),
    ])];
    if (tracks.count) [sections addObject:SGSection(@"Top tracks", tracks)];
    if (artists.count) [sections addObject:SGSection(@"Top artists", artists)];
    [sections addObject:SGNotedSection(nil, @[
        SGWithSymbol(SGActionRow(@"Import Spotify's data export", nil, ^{ importExport(); }), @"square.and.arrow.down"),
        SGWithSymbol(SGActionRow(@"Reset listening stats", nil, ^{ resetStats(); }), @"trash"),
    ], @"Request your data on spotify.com under Account > Privacy, then pick the StreamingHistory or Streaming_History_Audio JSON files.")];
    return [[SGModPage alloc] initWithTitle:@"Listening stats" intro:nil sections:sections footer:nil];
}

__attribute__((constructor)) static void SPXStatsStart(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        sg_observer = [SPXStatsObserver new];
        SGAddPlayerStateObserver(sg_observer);
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *note) { [sg_observer background]; }];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillTerminateNotification object:nil queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *note) { [sg_observer background]; }];
    });
}
