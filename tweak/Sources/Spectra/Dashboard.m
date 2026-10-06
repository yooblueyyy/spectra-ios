// The Spectra dashboard on the iPhone: the same dashboard the browser extension, desktop and Android apps
// use, showing its Extensions, Snippets and Admin (and Settings, where Discord is linked for Admin).
// Written for Spectra iOS.
//
// The dashboard's files ship inside the app as SpectraDashboard.bundle (scripts/build-dashboard.sh puts
// extension/dashboard, extension/shared and extension/icons in it, with dashboard/ios-shim.js) and are
// served to a WKWebView under the spectra-ui: scheme, so nothing is fetched from the network but the
// Spectra API the dashboard itself calls. ios-shim.js turns the dashboard's storage and messages into
// calls to the "spectra" handler here, which keeps them in Documents/Spectra/dashboard.json.
//
// Links and window.open (Discord linking, GitHub pages) leave for Safari. Main thread.
#import <WebKit/WebKit.h>
#import "Core/SGCore.h"
#import "Settings/SGPageStyle.h"
#import "Spectra.h"

static NSString *const kScheme = @"spectra-ui";
static NSString *const kManifestURL = @"https://usespectra.xyz/api/manifest";

static NSURL *bundleURL(void) {
    return [NSBundle.mainBundle URLForResource:@"SpectraDashboard" withExtension:@"bundle"];
}

#pragma mark - storage

static NSURL *storageURL(void) {
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *folder = [documents URLByAppendingPathComponent:@"Spectra" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
    return [folder URLByAppendingPathComponent:@"dashboard.json"];
}

static NSMutableDictionary *sg_storage;

static NSMutableDictionary *storage(void) {
    if (sg_storage) return sg_storage;
    NSData *data = [NSData dataWithContentsOfURL:storageURL()];
    id saved = data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil] : nil;
    sg_storage = [saved isKindOfClass:NSMutableDictionary.class] ? saved : [NSMutableDictionary dictionary];
    return sg_storage;
}

static void saveStorage(void) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:storage() options:0 error:nil];
    if (data) [data writeToURL:storageURL() options:NSDataWritingAtomic error:nil];
}

// chrome.storage.local.get: null for everything, a key, a list of keys, or an object of keys and defaults.
static NSDictionary *storageGet(id keys) {
    NSDictionary *all = storage();
    if (!keys || keys == NSNull.null) return all;
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    if ([keys isKindOfClass:NSString.class]) keys = @[keys];
    if ([keys isKindOfClass:NSArray.class]) {
        for (id key in keys) if ([key isKindOfClass:NSString.class] && all[key]) out[key] = all[key];
    } else if ([keys isKindOfClass:NSDictionary.class]) {
        [keys enumerateKeysAndObjectsUsingBlock:^(id key, id fallback, BOOL *stop) { out[key] = all[key] ?: fallback; }];
    }
    return out;
}

// chrome.storage.local.set: merges, and returns the changes the way chrome.storage.onChanged has them.
static NSDictionary *storageSet(NSDictionary *values) {
    NSMutableDictionary *changes = [NSMutableDictionary dictionary];
    [values enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        if (![key isKindOfClass:NSString.class]) return;
        id old = storage()[key];
        storage()[key] = value;
        changes[key] = old ? @{@"newValue": value, @"oldValue": old} : @{@"newValue": value};
    }];
    if (changes.count) saveStorage();
    return changes;
}

static NSString *json(id object) {
    NSData *data = object ? [NSJSONSerialization dataWithJSONObject:object options:0 error:nil] : nil;
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{}";
}

#pragma mark - serving the bundle

@interface SPXDashboardFiles : NSObject <WKURLSchemeHandler>
@end

@implementation SPXDashboardFiles

static NSString *mimeType(NSString *extension) {
    NSDictionary *types = @{@"html": @"text/html", @"js": @"text/javascript", @"css": @"text/css", @"json": @"application/json",
                            @"png": @"image/png", @"svg": @"image/svg+xml", @"woff2": @"font/woff2", @"ico": @"image/x-icon"};
    return types[extension.lowercaseString] ?: @"application/octet-stream";
}

- (void)webView:(WKWebView *)webView startURLSchemeTask:(id<WKURLSchemeTask>)task {
    NSString *path = [task.request.URL.path stringByStandardizingPath];
    NSURL *root = bundleURL();
    NSURL *file = root && path.length && ![path containsString:@".."] ? [root URLByAppendingPathComponent:path] : nil;
    NSData *data = file ? [NSData dataWithContentsOfURL:file] : nil;
    NSInteger status = data ? 200 : 404;
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:task.request.URL statusCode:status HTTPVersion:@"HTTP/1.1"
                                                            headerFields:@{@"Content-Type": data ? mimeType(path.pathExtension) : @"text/plain",
                                                                           @"Content-Length": @(data.length).stringValue}];
    [task didReceiveResponse:response];
    if (data) [task didReceiveData:data];
    [task didFinish];
}

- (void)webView:(WKWebView *)webView stopURLSchemeTask:(id<WKURLSchemeTask>)task {
}

@end

#pragma mark - the page

// The content controller holds its handlers strongly; this stands between it and the page so closing the
// dashboard frees it.
@interface SPXWeakHandler : NSObject <WKScriptMessageHandlerWithReply>
@property (nonatomic, weak) id<WKScriptMessageHandlerWithReply> target;
@end

@implementation SPXWeakHandler
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message
                 replyHandler:(void (^)(id reply, NSString *error))replyHandler {
    id<WKScriptMessageHandlerWithReply> target = self.target;
    if (target) [target userContentController:controller didReceiveScriptMessage:message replyHandler:replyHandler];
    else replyHandler(@"{}", nil);
}
@end

@interface SPXDashboardController : UIViewController <WKScriptMessageHandlerWithReply, WKNavigationDelegate, WKUIDelegate>
@end

@implementation SPXDashboardController {
    WKWebView *_web;
}

- (void)loadView {
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    [configuration setURLSchemeHandler:[SPXDashboardFiles new] forURLScheme:kScheme];
    WKUserContentController *content = configuration.userContentController;
    SPXWeakHandler *handler = [SPXWeakHandler new];
    handler.target = self;
    [content addScriptMessageHandlerWithReply:handler contentWorld:WKContentWorld.pageWorld name:@"spectra"];
    NSString *shim = [NSString stringWithContentsOfURL:[bundleURL() URLByAppendingPathComponent:@"ios-shim.js"] encoding:NSUTF8StringEncoding error:nil];
    if (shim.length) {
        [content addUserScript:[[WKUserScript alloc] initWithSource:shim injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                   forMainFrameOnly:YES]];
    }
    _web = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
    _web.navigationDelegate = self;
    _web.UIDelegate = self;
    _web.opaque = NO;
    _web.backgroundColor = [UIColor colorWithRed:0x0b / 255.0 green:0x0b / 255.0 blue:0x0f / 255.0 alpha:1];
    _web.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    self.view = _web;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Spectra dashboard";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    [_web loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:[kScheme stringByAppendingString:@"://app/dashboard/index.html#extensions"]]]];
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)dealloc {
    [_web.configuration.userContentController removeAllScriptMessageHandlers];
}

- (void)notify:(NSDictionary *)changes {
    if (!changes.count) return;
    [_web evaluateJavaScript:[NSString stringWithFormat:@"window.__spectraStorageChanged&&window.__spectraStorageChanged(%@)", json(changes)] completionHandler:nil];
}

// The live config every Spectra install reads, stored the way the other apps store it.
- (void)ensureRemote {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kManifestURL]];
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    request.timeoutInterval = 20;
    __weak SPXDashboardController *weakSelf = self;
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        id manifest = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![manifest isKindOfClass:NSDictionary.class]) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSDictionary *wrapped = @{@"data": manifest, @"fetchedAt": @((long long)(NSDate.date.timeIntervalSince1970 * 1000)), @"from": kManifestURL};
            [weakSelf notify:storageSet(@{@"remote": wrapped})];
        });
    }] resume];
}

- (void)saveFile:(NSString *)name content:(NSString *)content {
    NSString *safe = [[name componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/\\:"]] componentsJoinedByString:@"_"];
    NSURL *file = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:safe.length ? safe : @"spectra.json"]];
    if (![content writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:nil]) return;
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[file] applicationActivities:nil];
    share.popoverPresentationController.sourceView = self.view;
    share.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), 80, 1, 1);
    [self presentViewController:share animated:YES completion:nil];
}

- (NSDictionary *)answer:(NSDictionary *)message {
    NSDictionary *msg = [message[@"msg"] isKindOfClass:NSDictionary.class] ? message[@"msg"] : @{};
    NSString *type = [msg[@"type"] isKindOfClass:NSString.class] ? msg[@"type"] : @"";
    if ([type isEqualToString:@"appInfo"]) {
        return @{@"platform": @"ios", @"version": @(SG_VERSION), @"spotify": [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @""};
    }
    if ([type isEqualToString:@"ensureRemote"]) {
        id remote = storage()[@"remote"];
        double fetched = [remote isKindOfClass:NSDictionary.class] ? [remote[@"fetchedAt"] doubleValue] : 0;
        if ([msg[@"force"] boolValue] || NSDate.date.timeIntervalSince1970 * 1000 - fetched > 5 * 60 * 1000) [self ensureRemote];
        return @{@"ok": @YES};
    }
    if ([type isEqualToString:@"saveFile"]) {
        NSString *name = [msg[@"name"] isKindOfClass:NSString.class] ? msg[@"name"] : @"spectra.json";
        NSString *content = [msg[@"content"] isKindOfClass:NSString.class] ? msg[@"content"] : @"";
        [self saveFile:name content:content];
        return @{@"ok": @YES};
    }
    // Nothing to reload or map on the iPhone: Spotify here is the native app.
    if ([type isEqualToString:@"ensureCssMap"] || [type isEqualToString:@"reloadSpotifyTabs"] || [type isEqualToString:@"openDashboard"]) return @{@"ok": @YES};
    if ([type isEqualToString:@"spotifyStatus"]) return @{@"state": @"native", @"message": @"Spotify on iPhone is the native app."};
    return @{@"ok": @NO};
}

- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message
                 replyHandler:(void (^)(id reply, NSString *error))replyHandler {
    NSDictionary *body = [message.body isKindOfClass:NSDictionary.class] ? message.body : @{};
    NSString *op = body[@"op"];
    if ([op isEqualToString:@"get"]) {
        replyHandler(json(storageGet(body[@"keys"])), nil);
    } else if ([op isEqualToString:@"set"]) {
        NSDictionary *values = [body[@"obj"] isKindOfClass:NSDictionary.class] ? body[@"obj"] : @{};
        NSDictionary *changes = storageSet(values);
        replyHandler(@"{}", nil);
        dispatch_async(dispatch_get_main_queue(), ^{ [self notify:changes]; });
    } else if ([op isEqualToString:@"send"]) {
        replyHandler(json([self answer:body]), nil);
    } else {
        replyHandler(@"{}", nil);
    }
}

// Pages of the dashboard stay; everything else (README links, Discord sign-in) opens in Safari.
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action
    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = action.request.URL;
    if ([url.scheme isEqualToString:kScheme] || [url.scheme isEqualToString:@"about"] || [url.scheme isEqualToString:@"blob"]
        || [url.scheme isEqualToString:@"data"] || !action.targetFrame.isMainFrame) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }
    decisionHandler(WKNavigationActionPolicyCancel);
    SGOpenURL(url.absoluteString);
}

- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
   forNavigationAction:(WKNavigationAction *)action windowFeatures:(WKWindowFeatures *)features {
    if (action.request.URL) SGOpenURL(action.request.URL.absoluteString);
    return nil;
}

- (void)webView:(WKWebView *)webView runJavaScriptAlertPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame
    completionHandler:(void (^)(void))completionHandler {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { completionHandler(); }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)webView:(WKWebView *)webView runJavaScriptConfirmPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame
    completionHandler:(void (^)(BOOL))completionHandler {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) { completionHandler(NO); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { completionHandler(YES); }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)webView:(WKWebView *)webView runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt defaultText:(NSString *)defaultText
    initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(NSString *))completionHandler {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil message:prompt preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.text = defaultText; }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) { completionHandler(nil); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        completionHandler(alert.textFields.firstObject.text);
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

void SPXOpenDashboard(void) {
    UIViewController *top = SGTopController();
    if (!top) return;
    if (!bundleURL()) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Dashboard not in this build"
                                                                       message:@"This IPA was built without SpectraDashboard.bundle. Build it again with the Spectra iOS workflow."
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [top presentViewController:alert animated:YES completion:nil];
        return;
    }
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:[SPXDashboardController new]];
    navigation.modalPresentationStyle = UIModalPresentationFullScreen;
    navigation.navigationBar.barStyle = UIBarStyleBlack;
    navigation.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [top presentViewController:navigation animated:YES completion:nil];
}
