#import "uYouPlusPatches.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

#define YT_BUNDLE_ID @"com.google.ios.youtube"
#define YT_NAME @"YouTube"
static NSInteger const kPlaybackIsolationStage = 1;
static BOOL const kEnableGoogleSignInBundlePatch = NO;

# pragma mark - YouTube patches

// Fix Google Sign in Patch
%group gGoogleSignInPatch
%hook NSBundle
+ (NSBundle *)bundleWithIdentifier:(NSString *)identifier {
    if (!kEnableGoogleSignInBundlePatch) {
        return %orig(identifier);
    }
    if ([identifier isEqualToString:YT_BUNDLE_ID])
        return NSBundle.mainBundle;
    return %orig(identifier);
}
- (NSString *)bundleIdentifier {
    if (!kEnableGoogleSignInBundlePatch) {
        return %orig;
    }
    return [self isEqual:NSBundle.mainBundle] ? YT_BUNDLE_ID : %orig;
}
- (NSDictionary *)infoDictionary {
    if (!kEnableGoogleSignInBundlePatch) {
        return %orig;
    }
    NSDictionary *dict = %orig;
    if (![self isEqual:NSBundle.mainBundle])
        return %orig;
    NSMutableDictionary *info = [dict mutableCopy];
    if (info[@"CFBundleIdentifier"]) info[@"CFBundleIdentifier"] = YT_BUNDLE_ID;
    if (info[@"CFBundleDisplayName"]) info[@"CFBundleDisplayName"] = YT_NAME;
    if (info[@"CFBundleName"]) info[@"CFBundleName"] = YT_NAME;
    return info;
}
- (id)objectForInfoDictionaryKey:(NSString *)key {
    if (!kEnableGoogleSignInBundlePatch) {
        return %orig;
    }
    if (![self isEqual:NSBundle.mainBundle])
        return %orig;
    if ([key isEqualToString:@"CFBundleIdentifier"])
        return YT_BUNDLE_ID;
    if ([key isEqualToString:@"CFBundleDisplayName"] || [key isEqualToString:@"CFBundleName"])
        return YT_NAME;
    return %orig;
}
%end
%end

// Workaround for MiRO92/uYou-for-YouTube#12, qnblackcat/uYouPlus#263
%hook YTDataUtils
+ (NSMutableDictionary *)spamSignalsDictionary {
    return %orig;
}
+ (NSMutableDictionary *)spamSignalsDictionaryWithoutIDFA {
    return %orig;
}
%end

%hook YTHotConfig
- (BOOL)disableAfmaIdfaCollection { return %orig; }
%end

static NSString *const kCachedVisitorDataKey = @"uYouEnhancedCachedVisitorData";
static NSString *cachedVisitorData = nil;
static NSString *const kPlaybackDiagLinesKey = @"uYouEnhancedPlaybackDiagLines";
static NSString *const kPlaybackDiagLastFailureKey = @"uYouEnhancedPlaybackDiagLastFailure";
static NSString *const kPlaybackDiagLastUpdatedKey = @"uYouEnhancedPlaybackDiagLastUpdated";
static NSString *const kPlaybackDiagFileName = @"uYouEnhancedPlaybackDiagnostics.txt";
static NSUInteger const kPlaybackDiagMaxLines = 120;
static NSUInteger const kPlaybackDiagMaxBodyCaptureBytes = 1024 * 1024;
static NSTimeInterval const kPlaybackDiagAutoCopyThrottleSeconds = 4.0;
static NSMutableArray<NSString *> *playbackDiagLines = nil;
static NSString *playbackDiagLastAutoCopiedFailure = nil;
static NSDate *playbackDiagLastAutoCopiedAt = nil;
static NSMutableArray *playbackDiagObserverTokens = nil;

static NSString *playbackEndpointCodeForURL(NSURL *url);
static void recordPlaybackRequestDiagnostic(NSURLRequest *originalRequest, NSURLRequest *patchedRequest, BOOL strippedAuthHeaders, BOOL injectedVisitorHeader);
static void recordPlaybackResponseDiagnostic(NSURLRequest *request, NSURLResponse *response, NSData *data, NSError *error);
static void autoCopyPlaybackDiagnosticsIfNeeded(NSString *reasonCode);
static void setupAVPlayerItemDiagnosticsObservers(void);
static NSString *shortenedDiagnosticString(NSString *value, NSUInteger maxLength);
static NSString *queryItemValueForURL(NSURL *url, NSString *targetKey);

static dispatch_queue_t visitorDataQueue() {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.uyouenhanced.visitor-data", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static dispatch_queue_t playbackDiagQueue() {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.uyouenhanced.playback-diag", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static NSString *playbackDiagTimestamp(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    });
    return [formatter stringFromDate:[NSDate date]];
}

static BOOL playbackDiagnosticsBannerEnabled(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id bannerValue = [defaults objectForKey:kPlaybackDiagnosticsBanner];
    if (!bannerValue) {
        return YES;
    }
    return [defaults boolForKey:kPlaybackDiagnosticsBanner];
}

static BOOL playbackDiagnosticsAutoCopyEnabled(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id autoCopyValue = [defaults objectForKey:kPlaybackDiagnosticsAutoCopy];
    if (!autoCopyValue) {
        return YES;
    }
    return [defaults boolForKey:kPlaybackDiagnosticsAutoCopy];
}

static void showPlaybackDiagnosticsBanner(NSString *text) {
    if (!text.length || !playbackDiagnosticsBannerEnabled()) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *keyWindow = UIApplication.sharedApplication.keyWindow;
        if (!keyWindow && UIApplication.sharedApplication.windows.count > 0) {
            keyWindow = UIApplication.sharedApplication.windows.firstObject;
        }
        if (!keyWindow) {
            return;
        }

        const NSInteger bannerTag = 908413;
        UILabel *label = [keyWindow viewWithTag:bannerTag];
        if (![label isKindOfClass:[UILabel class]]) {
            label = [[UILabel alloc] initWithFrame:CGRectZero];
            label.tag = bannerTag;
            label.numberOfLines = 2;
            label.textAlignment = NSTextAlignmentCenter;
            label.font = [UIFont monospacedSystemFontOfSize:11.0 weight:UIFontWeightSemibold];
            label.textColor = UIColor.whiteColor;
            label.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.75];
            label.layer.cornerRadius = 10.0;
            label.layer.masksToBounds = YES;
            [keyWindow addSubview:label];
        }

        CGFloat width = MIN(CGRectGetWidth(keyWindow.bounds) - 24.0, 420.0);
        label.frame = CGRectMake((CGRectGetWidth(keyWindow.bounds) - width) / 2.0, 64.0, width, 58.0);
        label.text = text;

        [NSObject cancelPreviousPerformRequestsWithTarget:label selector:@selector(removeFromSuperview) object:nil];
        [label performSelector:@selector(removeFromSuperview) withObject:nil afterDelay:4.0];
    });
}

static void ensurePlaybackDiagLinesLoaded(void) {
    if (playbackDiagLines) {
        return;
    }
    NSArray *storedLines = [[NSUserDefaults standardUserDefaults] arrayForKey:kPlaybackDiagLinesKey];
    if ([storedLines isKindOfClass:[NSArray class]]) {
        playbackDiagLines = [storedLines mutableCopy];
    }
    if (!playbackDiagLines) {
        playbackDiagLines = [NSMutableArray array];
    }
}

static void appendPlaybackDiagnosticLine(NSString *line, NSString *failureCode, BOOL shouldShowBanner) {
    if (!line.length) {
        return;
    }

    dispatch_async(playbackDiagQueue(), ^{
        ensurePlaybackDiagLinesLoaded();
        [playbackDiagLines addObject:line];
        if (playbackDiagLines.count > kPlaybackDiagMaxLines) {
            [playbackDiagLines removeObjectsInRange:NSMakeRange(0, playbackDiagLines.count - kPlaybackDiagMaxLines)];
        }

        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setObject:playbackDiagLines forKey:kPlaybackDiagLinesKey];
        [defaults setObject:[NSDate date] forKey:kPlaybackDiagLastUpdatedKey];

        NSString *autoCopyReason = failureCode;
        if (!autoCopyReason.length) {
            if ([line containsString:@" RES "]) {
                autoCopyReason = @"RES_EVENT";
            } else if ([line containsString:@" REQ "]) {
                autoCopyReason = @"REQ_EVENT";
            } else {
                autoCopyReason = @"EVENT";
            }
        }
        autoCopyPlaybackDiagnosticsIfNeeded(autoCopyReason);

        if (failureCode.length) {
            [defaults setObject:failureCode forKey:kPlaybackDiagLastFailureKey];
            if (shouldShowBanner) {
                showPlaybackDiagnosticsBanner([NSString stringWithFormat:@"Playback %@", failureCode]);
            }
        }
    });
}

NSString *uYouEnhancedPlaybackDiagnosticsLastFailureCode(void) {
    NSString *failureCode = [[NSUserDefaults standardUserDefaults] stringForKey:kPlaybackDiagLastFailureKey];
    return failureCode.length ? failureCode : @"none";
}

NSString *uYouEnhancedPlaybackDiagnosticsReport(void) {
    __block NSArray<NSString *> *lines = nil;
    dispatch_sync(playbackDiagQueue(), ^{
        ensurePlaybackDiagLinesLoaded();
        lines = [playbackDiagLines copy];
    });

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *lastFailure = [defaults stringForKey:kPlaybackDiagLastFailureKey] ?: @"none";
    NSDate *lastUpdated = [defaults objectForKey:kPlaybackDiagLastUpdatedKey];
    NSString *appVersion = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"] ?: @"unknown";

    NSMutableString *report = [NSMutableString string];
    [report appendFormat:@"uYouEnhanced Playback Diagnostics\n"]; 
    [report appendFormat:@"App Version: %@\n", appVersion];
    [report appendFormat:@"Isolation Stage: %ld\n", (long)kPlaybackIsolationStage];
    [report appendFormat:@"Last Failure: %@\n", lastFailure];
    if (lastUpdated) {
        [report appendFormat:@"Last Updated: %@\n", [NSDateFormatter localizedStringFromDate:lastUpdated dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterMediumStyle]];
    }
    [report appendString:@"\nRecent Events:\n"];

    if (lines.count == 0) {
        [report appendString:@"(no events captured yet)\n"];
    } else {
        for (NSString *line in lines) {
            [report appendFormat:@"%@\n", line];
        }
    }

    return report;
}

NSString *uYouEnhancedPlaybackDiagnosticsWriteReportToFile(void) {
    NSString *report = uYouEnhancedPlaybackDiagnosticsReport();
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:kPlaybackDiagFileName];
    NSError *writeError = nil;
    [report writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&writeError];
    return writeError ? nil : path;
}

static void autoCopyPlaybackDiagnosticsIfNeeded(NSString *reasonCode) {
    if (!playbackDiagnosticsAutoCopyEnabled()) {
        return;
    }

    NSString *normalizedReason = reasonCode.length ? reasonCode : @"EVENT";

    NSDate *now = [NSDate date];
    BOOL isSameReasonCode = [playbackDiagLastAutoCopiedFailure isEqualToString:normalizedReason];
    if (isSameReasonCode && playbackDiagLastAutoCopiedAt && [now timeIntervalSinceDate:playbackDiagLastAutoCopiedAt] < kPlaybackDiagAutoCopyThrottleSeconds) {
        return;
    }

    playbackDiagLastAutoCopiedFailure = [normalizedReason copy];
    playbackDiagLastAutoCopiedAt = now;

    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *report = uYouEnhancedPlaybackDiagnosticsReport();
        NSString *reportPath = uYouEnhancedPlaybackDiagnosticsWriteReportToFile();

        NSMutableString *clipboardPayload = [NSMutableString string];
        [clipboardPayload appendFormat:@"[uYouEnhanced diag %@ at %@]\n", normalizedReason, playbackDiagTimestamp()];
        if (report.length) {
            [clipboardPayload appendFormat:@"\n%@", report];
        }
        if (reportPath.length) {
            [clipboardPayload appendFormat:@"\n\nDiagnostics file: %@\n", reportPath];
        }
        if (!clipboardPayload.length) {
            [clipboardPayload appendString:@"Playback diagnostics unavailable."];
        }

        [UIPasteboard generalPasteboard].string = clipboardPayload;
    });
}

void uYouEnhancedPlaybackDiagnosticsClear(void) {
    dispatch_async(playbackDiagQueue(), ^{
        playbackDiagLines = [NSMutableArray array];
        playbackDiagLastAutoCopiedFailure = nil;
        playbackDiagLastAutoCopiedAt = nil;
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults removeObjectForKey:kPlaybackDiagLinesKey];
        [defaults removeObjectForKey:kPlaybackDiagLastFailureKey];
        [defaults removeObjectForKey:kPlaybackDiagLastUpdatedKey];
    });

    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:kPlaybackDiagFileName];
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
}

static NSString *trimmedString(NSString *value) {
    if (![value isKindOfClass:[NSString class]]) {
        return nil;
    }
    NSString *trimmed = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmed.length ? trimmed : nil;
}

static NSString *headerValueForKey(NSDictionary *headers, NSString *targetKey) {
    if (![headers isKindOfClass:[NSDictionary class]] || !targetKey.length) {
        return nil;
    }
    __block NSString *value = nil;
    [headers enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        if (![key isKindOfClass:[NSString class]]) {
            return;
        }
        if ([(NSString *)key caseInsensitiveCompare:targetKey] == NSOrderedSame) {
            value = trimmedString(obj);
            *stop = YES;
        }
    }];
    return value;
}

static NSString *extractVisitorDataFromCookies(NSString *cookieHeaderValue) {
    NSString *cookieString = trimmedString(cookieHeaderValue);
    if (!cookieString.length) {
        return nil;
    }

    NSArray<NSString *> *segments = [cookieString componentsSeparatedByString:@";"];
    for (NSString *segment in segments) {
        NSArray<NSString *> *pair = [segment componentsSeparatedByString:@"="];
        if (pair.count < 2) {
            continue;
        }
        NSString *key = [trimmedString(pair.firstObject).lowercaseString copy];
        if ([key isEqualToString:@"visitor_info1_live"] || [key isEqualToString:@"visitor_data"]) {
            NSString *value = trimmedString([[pair subarrayWithRange:NSMakeRange(1, pair.count - 1)] componentsJoinedByString:@"="]);
            if (value.length) {
                return value;
            }
        }
    }
    return nil;
}

static NSString *extractVisitorDataFromSetCookieHeader(NSDictionary *headers) {
    if (![headers isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    NSString *singleSetCookie = headerValueForKey(headers, @"Set-Cookie");
    NSString *visitorData = extractVisitorDataFromCookies(singleSetCookie);
    if (visitorData.length) {
        return visitorData;
    }

    __block NSString *arrayVisitorData = nil;
    [headers enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        if (![key isKindOfClass:[NSString class]]) {
            return;
        }
        if ([(NSString *)key caseInsensitiveCompare:@"Set-Cookie"] != NSOrderedSame) {
            return;
        }
        if ([obj isKindOfClass:[NSArray class]]) {
            for (id item in (NSArray *)obj) {
                arrayVisitorData = extractVisitorDataFromCookies(item);
                if (arrayVisitorData.length) {
                    *stop = YES;
                    break;
                }
            }
        }
    }];

    return arrayVisitorData;
}

static BOOL isInnerTubeRequest(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) {
        return NO;
    }
    NSString *absoluteString = url.absoluteString.lowercaseString;
    if (![absoluteString isKindOfClass:[NSString class]]) {
        return NO;
    }
    return ([absoluteString containsString:@"youtubei/v1/"] ||
            [absoluteString containsString:@"youtubei.googleapis.com"]);
}

static BOOL isGoogleVideoPlaybackRequest(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) {
        return NO;
    }
    NSString *host = url.host.lowercaseString;
    if (![host isKindOfClass:[NSString class]]) {
        return NO;
    }
    if (![host containsString:@"googlevideo.com"]) {
        return NO;
    }
    NSString *path = url.path.lowercaseString;
    return [path containsString:@"videoplayback"];
}

static NSString *queryItemValueForURL(NSURL *url, NSString *targetKey) {
    if (![url isKindOfClass:[NSURL class]] || !targetKey.length) {
        return nil;
    }

    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (![components.queryItems isKindOfClass:[NSArray class]]) {
        return nil;
    }

    for (NSURLQueryItem *item in components.queryItems) {
        if (![item.name isKindOfClass:[NSString class]]) {
            continue;
        }
        if ([item.name caseInsensitiveCompare:targetKey] == NSOrderedSame) {
            return trimmedString(item.value);
        }
    }

    return nil;
}

static BOOL headerLooksLoggedIn(NSDictionary *headers) {
    NSString *loggedInHeader = headerValueForKey(headers, @"X-Goog-Logged-In");
    if ([loggedInHeader isEqualToString:@"1"]) {
        return YES;
    }
    NSString *bootstrapLoggedInHeader = headerValueForKey(headers, @"X-Youtube-Bootstrap-Logged-In");
    if ([bootstrapLoggedInHeader isEqualToString:@"1"] ||
        [bootstrapLoggedInHeader caseInsensitiveCompare:@"true"] == NSOrderedSame) {
        return YES;
    }
    return NO;
}

static NSString *playbackEndpointCodeForURL(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) {
        return nil;
    }

    NSString *absoluteString = url.absoluteString.lowercaseString;
    if (![absoluteString isKindOfClass:[NSString class]]) {
        return nil;
    }

    if ([absoluteString containsString:@"googlevideo.com"] && [absoluteString containsString:@"videoplayback"]) {
        return @"GV_MEDIA";
    }

    NSRange innerTubeRange = [absoluteString rangeOfString:@"youtubei/v1/"];
    if (innerTubeRange.location != NSNotFound) {
        NSString *endpointSuffix = [absoluteString substringFromIndex:(innerTubeRange.location + innerTubeRange.length)];
        NSRange queryRange = [endpointSuffix rangeOfString:@"?"];
        if (queryRange.location != NSNotFound) {
            endpointSuffix = [endpointSuffix substringToIndex:queryRange.location];
        }
        if (!endpointSuffix.length) {
            return @"IT_UNKNOWN";
        }

        NSMutableString *sanitized = [NSMutableString stringWithString:@"IT_"];
        NSCharacterSet *validSet = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789"];
        for (NSUInteger idx = 0; idx < endpointSuffix.length; idx++) {
            unichar ch = [endpointSuffix characterAtIndex:idx];
            NSString *charString = [[NSString stringWithCharacters:&ch length:1] lowercaseString];
            if ([validSet characterIsMember:[charString characterAtIndex:0]]) {
                [sanitized appendString:[charString uppercaseString]];
            } else {
                [sanitized appendString:@"_"];
            }
            if (sanitized.length >= 36) {
                break;
            }
        }

        while ([sanitized containsString:@"__"]) {
            [sanitized replaceOccurrencesOfString:@"__" withString:@"_" options:0 range:NSMakeRange(0, sanitized.length)];
        }
        if ([sanitized hasSuffix:@"_"]) {
            [sanitized deleteCharactersInRange:NSMakeRange(sanitized.length - 1, 1)];
        }
        return sanitized.length ? sanitized : @"IT_UNKNOWN";
    }

    return nil;
}

static void recordPlaybackHTTPStatusDiagnostic(NSURL *url, NSInteger statusCode, NSDictionary *headers) {
    NSString *endpoint = playbackEndpointCodeForURL(url);
    if (!endpoint.length) {
        return;
    }

    NSString *visitorHeader = headerValueForKey(headers, @"X-Goog-Visitor-Id");
    NSString *wwwAuthenticate = headerValueForKey(headers, @"WWW-Authenticate");
    BOOL loggedIn = headerLooksLoggedIn(headers);

    NSString *line = nil;
    if ([endpoint isEqualToString:@"GV_MEDIA"]) {
        NSString *itag = shortenedDiagnosticString(queryItemValueForURL(url, @"itag"), 8);
        NSString *range = shortenedDiagnosticString(queryItemValueForURL(url, @"range"), 20);
        NSString *contentType = shortenedDiagnosticString(headerValueForKey(headers, @"Content-Type"), 28);
        NSString *contentLength = shortenedDiagnosticString(headerValueForKey(headers, @"Content-Length"), 14);
        NSString *contentRange = shortenedDiagnosticString(headerValueForKey(headers, @"Content-Range"), 42);

        line = [NSString stringWithFormat:@"%@ %@ RES_HDR status=%ld logged=%d visitor=%d wwwAuth=%d itag=%@ range=%@ ctype=%@ clen=%@ crange=%@",
                playbackDiagTimestamp(),
                endpoint,
                (long)statusCode,
                loggedIn ? 1 : 0,
                visitorHeader.length > 0 ? 1 : 0,
                wwwAuthenticate.length > 0 ? 1 : 0,
                itag,
                range,
                contentType,
                contentLength,
                contentRange];
    } else {
        line = [NSString stringWithFormat:@"%@ %@ RES_HDR status=%ld logged=%d visitor=%d wwwAuth=%d",
                playbackDiagTimestamp(),
                endpoint,
                (long)statusCode,
                loggedIn ? 1 : 0,
                visitorHeader.length > 0 ? 1 : 0,
                wwwAuthenticate.length > 0 ? 1 : 0];
    }

    NSString *failureCode = statusCode >= 400 ? [NSString stringWithFormat:@"%@_%ld", endpoint, (long)statusCode] : nil;
    appendPlaybackDiagnosticLine(line, failureCode, statusCode >= 400);
}

static NSString *playabilityStatusFromData(NSData *data) {
    if (![data isKindOfClass:[NSData class]] || data.length == 0 || data.length > kPlaybackDiagMaxBodyCaptureBytes) {
        return nil;
    }

    NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!body.length) {
        return nil;
    }

    static NSRegularExpression *statusRegex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        statusRegex = [NSRegularExpression regularExpressionWithPattern:@"\\\"playabilityStatus\\\"\\s*:\\s*\\{[^\\}]*\\\"status\\\"\\s*:\\s*\\\"([^\\\"]+)\\\"" options:NSRegularExpressionCaseInsensitive error:nil];
    });

    NSTextCheckingResult *match = [statusRegex firstMatchInString:body options:0 range:NSMakeRange(0, body.length)];
    if (match.numberOfRanges >= 2) {
        return [body substringWithRange:[match rangeAtIndex:1]];
    }

    return nil;
}

static NSString *playabilityReasonSnippetFromData(NSData *data) {
    if (![data isKindOfClass:[NSData class]] || data.length == 0 || data.length > kPlaybackDiagMaxBodyCaptureBytes) {
        return nil;
    }

    NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!body.length) {
        return nil;
    }

    static NSRegularExpression *reasonRegex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        reasonRegex = [NSRegularExpression regularExpressionWithPattern:@"\\\"reason\\\"\\s*:\\s*\\\"([^\\\"]+)\\\"" options:NSRegularExpressionCaseInsensitive error:nil];
    });

    NSTextCheckingResult *match = [reasonRegex firstMatchInString:body options:0 range:NSMakeRange(0, body.length)];
    if (match.numberOfRanges < 2) {
        return nil;
    }

    NSString *reason = [body substringWithRange:[match rangeAtIndex:1]];
    NSString *singleLineReason = [[reason componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] componentsJoinedByString:@" "];
    if (singleLineReason.length > 80) {
        singleLineReason = [singleLineReason substringToIndex:80];
    }
    return singleLineReason;
}

static BOOL headersContainSignedInCookie(NSString *cookieHeader) {
    if (!cookieHeader.length) {
        return NO;
    }

    return ([cookieHeader rangeOfString:@"SAPISID" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [cookieHeader rangeOfString:@"__Secure-3PAPISID" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [cookieHeader rangeOfString:@"SID=" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [cookieHeader rangeOfString:@"HSID=" options:NSCaseInsensitiveSearch].location != NSNotFound);
}

static void recordPlaybackRequestDiagnostic(NSURLRequest *originalRequest, NSURLRequest *patchedRequest, BOOL strippedAuthHeaders, BOOL injectedVisitorHeader) {
    NSURLRequest *effectiveRequest = patchedRequest ?: originalRequest;
    NSString *endpoint = playbackEndpointCodeForURL(effectiveRequest.URL);
    if (!endpoint.length) {
        return;
    }

    NSDictionary *headers = effectiveRequest.allHTTPHeaderFields;
    NSString *authorizationHeader = headerValueForKey(headers, @"Authorization");
    NSString *cookieHeader = headerValueForKey(headers, @"Cookie");
    NSString *visitorHeader = headerValueForKey(headers, @"X-Goog-Visitor-Id");
    BOOL loggedIn = headerLooksLoggedIn(headers);
    BOOL signedInCookie = headersContainSignedInCookie(cookieHeader);
    NSString *method = effectiveRequest.HTTPMethod ?: @"GET";

    NSString *line = nil;
    if ([endpoint isEqualToString:@"GV_MEDIA"]) {
        NSString *itag = shortenedDiagnosticString(queryItemValueForURL(effectiveRequest.URL, @"itag"), 8);
        NSString *range = queryItemValueForURL(effectiveRequest.URL, @"range");
        if (!range.length) {
            range = headerValueForKey(headers, @"Range");
        }
        NSString *rn = shortenedDiagnosticString(queryItemValueForURL(effectiveRequest.URL, @"rn"), 10);
        NSString *rbuf = shortenedDiagnosticString(queryItemValueForURL(effectiveRequest.URL, @"rbuf"), 10);
        NSString *clen = shortenedDiagnosticString(queryItemValueForURL(effectiveRequest.URL, @"clen"), 14);

        line = [NSString stringWithFormat:@"%@ %@ REQ m=%@ auth=%d cookie=%d logged=%d visitor=%d strip=%d inject=%d itag=%@ range=%@ rn=%@ rbuf=%@ clen=%@",
                playbackDiagTimestamp(),
                endpoint,
                method,
                authorizationHeader.length > 0 ? 1 : 0,
                signedInCookie ? 1 : 0,
                loggedIn ? 1 : 0,
                visitorHeader.length > 0 ? 1 : 0,
                strippedAuthHeaders ? 1 : 0,
                injectedVisitorHeader ? 1 : 0,
                itag,
                shortenedDiagnosticString(range, 20),
                rn,
                rbuf,
                clen];
    } else {
        line = [NSString stringWithFormat:@"%@ %@ REQ m=%@ auth=%d cookie=%d logged=%d visitor=%d strip=%d inject=%d",
                playbackDiagTimestamp(),
                endpoint,
                method,
                authorizationHeader.length > 0 ? 1 : 0,
                signedInCookie ? 1 : 0,
                loggedIn ? 1 : 0,
                visitorHeader.length > 0 ? 1 : 0,
                strippedAuthHeaders ? 1 : 0,
                injectedVisitorHeader ? 1 : 0];
    }
    appendPlaybackDiagnosticLine(line, nil, NO);
}

static void recordPlaybackResponseDiagnostic(NSURLRequest *request, NSURLResponse *response, NSData *data, NSError *error) {
    NSString *endpoint = playbackEndpointCodeForURL(request.URL);
    if (!endpoint.length) {
        return;
    }

    NSInteger statusCode = 0;
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        statusCode = ((NSHTTPURLResponse *)response).statusCode;
    }

    NSDictionary *responseHeaders = nil;
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        responseHeaders = ((NSHTTPURLResponse *)response).allHeaderFields;
    }

    NSString *playabilityStatus = playabilityStatusFromData(data);
    NSString *playabilityReason = playabilityReasonSnippetFromData(data);

    NSString *line = nil;
    if ([endpoint isEqualToString:@"GV_MEDIA"]) {
        NSString *itag = shortenedDiagnosticString(queryItemValueForURL(request.URL, @"itag"), 8);
        NSString *range = shortenedDiagnosticString(queryItemValueForURL(request.URL, @"range"), 20);
        NSString *contentType = shortenedDiagnosticString(headerValueForKey(responseHeaders, @"Content-Type"), 28);
        NSString *contentLength = shortenedDiagnosticString(headerValueForKey(responseHeaders, @"Content-Length"), 14);
        NSString *contentRange = shortenedDiagnosticString(headerValueForKey(responseHeaders, @"Content-Range"), 42);

        line = [NSString stringWithFormat:@"%@ %@ RES status=%ld err=%d bytes=%lu itag=%@ range=%@ ctype=%@ clen=%@ crange=%@",
                playbackDiagTimestamp(),
                endpoint,
                (long)statusCode,
                error ? 1 : 0,
                (unsigned long)data.length,
                itag,
                range,
                contentType,
                contentLength,
                contentRange];
    } else {
        line = [NSString stringWithFormat:@"%@ %@ RES status=%ld err=%d play=%@ reason=%@ bytes=%lu",
                playbackDiagTimestamp(),
                endpoint,
                (long)statusCode,
                error ? 1 : 0,
                playabilityStatus ?: @"-",
                playabilityReason ?: @"-",
                (unsigned long)data.length];
    }

    NSString *failureCode = nil;
    if (error) {
        failureCode = [NSString stringWithFormat:@"%@_ERR", endpoint];
    } else if (statusCode >= 400) {
        failureCode = [NSString stringWithFormat:@"%@_%ld", endpoint, (long)statusCode];
    } else if (playabilityStatus.length && ![playabilityStatus isEqualToString:@"OK"]) {
        failureCode = [NSString stringWithFormat:@"%@_PLAY_%@", endpoint, playabilityStatus];
    }

    appendPlaybackDiagnosticLine(line, failureCode, YES);
}

static NSString *shortenedDiagnosticString(NSString *value, NSUInteger maxLength) {
    if (![value isKindOfClass:[NSString class]] || value.length == 0) {
        return @"-";
    }
    NSString *singleLine = [[value componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] componentsJoinedByString:@" "];
    if (singleLine.length > maxLength) {
        return [singleLine substringToIndex:maxLength];
    }
    return singleLine;
}

static void recordAVPlayerAccessLogDiagnostic(AVPlayerItem *item) {
    if (!item || ![item respondsToSelector:@selector(accessLog)]) {
        appendPlaybackDiagnosticLine([NSString stringWithFormat:@"%@ AVP_ACCESS none=1", playbackDiagTimestamp()], nil, NO);
        return;
    }

    AVPlayerItemAccessLog *accessLog = [item accessLog];
    AVPlayerItemAccessLogEvent *event = [accessLog.events lastObject];
    if (!event) {
        appendPlaybackDiagnosticLine([NSString stringWithFormat:@"%@ AVP_ACCESS empty=1", playbackDiagTimestamp()], nil, NO);
        return;
    }

    NSString *uri = shortenedDiagnosticString(event.URI, 80);
    NSString *serverAddress = shortenedDiagnosticString(event.serverAddress, 40);
    NSString *line = [NSString stringWithFormat:@"%@ AVP_ACCESS seg=%ld bytes=%lld obs=%.0f ind=%.0f stalls=%ld xfer=%.2f server=%@ uri=%@",
                      playbackDiagTimestamp(),
                      (long)event.numberOfSegmentsDownloaded,
                      (long long)event.numberOfBytesTransferred,
                      event.observedBitrate,
                      event.indicatedBitrate,
                      (long)event.numberOfStalls,
                      event.transferDuration,
                      serverAddress,
                      uri];
    appendPlaybackDiagnosticLine(line, nil, NO);
}

static void recordAVPlayerItemDiagnostic(NSString *eventCode, AVPlayerItem *item, NSError *error, BOOL shouldShowBanner) {
    if (!eventCode.length) {
        return;
    }

    NSError *itemError = error;
    if (!itemError && [item respondsToSelector:@selector(error)]) {
        itemError = item.error;
    }

    NSInteger errorCode = itemError ? itemError.code : 0;
    NSString *errorDomain = itemError ? shortenedDiagnosticString(itemError.domain, 40) : @"-";

    NSInteger errorStatusCode = 0;
    NSString *errorLogDomain = @"-";
    NSString *errorLogComment = @"-";
    NSString *errorLogURI = @"-";

    if (item && [item respondsToSelector:@selector(errorLog)]) {
        AVPlayerItemErrorLog *errorLog = [item errorLog];
        AVPlayerItemErrorLogEvent *lastEvent = [errorLog.events lastObject];
        if (lastEvent) {
            errorStatusCode = lastEvent.errorStatusCode;
            errorLogDomain = shortenedDiagnosticString(lastEvent.errorDomain, 40);
            errorLogComment = shortenedDiagnosticString(lastEvent.errorComment, 80);
            errorLogURI = shortenedDiagnosticString(lastEvent.URI, 80);
        }
    }

    NSString *line = [NSString stringWithFormat:@"%@ AVP_%@ code=%ld domain=%@ http=%ld edomain=%@ comment=%@ uri=%@",
                      playbackDiagTimestamp(),
                      eventCode,
                      (long)errorCode,
                      errorDomain,
                      (long)errorStatusCode,
                      errorLogDomain,
                      errorLogComment,
                      errorLogURI];

    NSString *failureCode = nil;
    if (errorStatusCode >= 400) {
        failureCode = [NSString stringWithFormat:@"AVP_%@_%ld", eventCode, (long)errorStatusCode];
    } else if (itemError) {
        failureCode = [NSString stringWithFormat:@"AVP_%@_%ld", eventCode, (long)errorCode];
    }

    appendPlaybackDiagnosticLine(line, failureCode, shouldShowBanner);
}

static void setupAVPlayerItemDiagnosticsObservers(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        playbackDiagObserverTokens = [NSMutableArray array];

        id stalledToken = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemPlaybackStalledNotification
                                                                             object:nil
                                                                              queue:[NSOperationQueue mainQueue]
                                                                         usingBlock:^(NSNotification *note) {
            AVPlayerItem *item = [note.object isKindOfClass:[AVPlayerItem class]] ? (AVPlayerItem *)note.object : nil;
            recordAVPlayerItemDiagnostic(@"STALLED", item, nil, YES);
        }];
        if (stalledToken) {
            [playbackDiagObserverTokens addObject:stalledToken];
        }

        id failedToken = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemFailedToPlayToEndTimeNotification
                                                                            object:nil
                                                                             queue:[NSOperationQueue mainQueue]
                                                                        usingBlock:^(NSNotification *note) {
            AVPlayerItem *item = [note.object isKindOfClass:[AVPlayerItem class]] ? (AVPlayerItem *)note.object : nil;
            NSError *error = note.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey];
            recordAVPlayerItemDiagnostic(@"FAILED_END", item, error, YES);
        }];
        if (failedToken) {
            [playbackDiagObserverTokens addObject:failedToken];
        }

        id errorLogToken = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemNewErrorLogEntryNotification
                                                                              object:nil
                                                                               queue:[NSOperationQueue mainQueue]
                                                                          usingBlock:^(NSNotification *note) {
            AVPlayerItem *item = [note.object isKindOfClass:[AVPlayerItem class]] ? (AVPlayerItem *)note.object : nil;
            recordAVPlayerItemDiagnostic(@"ERRLOG", item, nil, NO);
        }];
        if (errorLogToken) {
            [playbackDiagObserverTokens addObject:errorLogToken];
        }

        id accessLogToken = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemNewAccessLogEntryNotification
                                                                               object:nil
                                                                                queue:[NSOperationQueue mainQueue]
                                                                           usingBlock:^(NSNotification *note) {
            AVPlayerItem *item = [note.object isKindOfClass:[AVPlayerItem class]] ? (AVPlayerItem *)note.object : nil;
            recordAVPlayerAccessLogDiagnostic(item);
        }];
        if (accessLogToken) {
            [playbackDiagObserverTokens addObject:accessLogToken];
        }

        id didEndToken = [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                                                                             object:nil
                                                                              queue:[NSOperationQueue mainQueue]
                                                                         usingBlock:^(NSNotification *note) {
            appendPlaybackDiagnosticLine([NSString stringWithFormat:@"%@ AVP_DID_END", playbackDiagTimestamp()], nil, NO);
        }];
        if (didEndToken) {
            [playbackDiagObserverTokens addObject:didEndToken];
        }
    });
}

static NSString *extractVisitorDataFromString(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) {
        return nil;
    }
    static NSArray<NSRegularExpression *> *regexes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        regexes = @[
            [NSRegularExpression regularExpressionWithPattern:@"\\\"visitorData\\\"\\s*:\\s*\\\"([^\\\"]+)\\\"" options:0 error:nil],
            [NSRegularExpression regularExpressionWithPattern:@"\\\"VISITOR_DATA\\\"\\s*:\\s*\\\"([^\\\"]+)\\\"" options:0 error:nil],
            [NSRegularExpression regularExpressionWithPattern:@"X-Goog-Visitor-Id\\\"?\\s*[:=]\\s*\\\"([^\\\"]+)\\\"" options:NSRegularExpressionCaseInsensitive error:nil]
        ];
    });

    NSRange range = NSMakeRange(0, text.length);
    for (NSRegularExpression *regex in regexes) {
        NSTextCheckingResult *match = [regex firstMatchInString:text options:0 range:range];
        if (match.numberOfRanges < 2) {
            continue;
        }
        NSString *matchValue = [text substringWithRange:[match rangeAtIndex:1]];
        NSString *trimmed = trimmedString(matchValue);
        if (trimmed.length) {
            return trimmed;
        }
    }
    return nil;
}

static NSString *extractVisitorDataFromBody(NSData *data) {
    if (![data isKindOfClass:[NSData class]] || data.length == 0 || data.length > kPlaybackDiagMaxBodyCaptureBytes) {
        return nil;
    }
    NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return extractVisitorDataFromString(body);
}

static void cacheVisitorData(NSString *value) {
    NSString *trimmed = trimmedString(value);
    if (!trimmed.length) {
        return;
    }
    dispatch_async(visitorDataQueue(), ^{
        cachedVisitorData = [trimmed copy];
        [[NSUserDefaults standardUserDefaults] setObject:cachedVisitorData forKey:kCachedVisitorDataKey];
    });
}

static NSURLRequest *requestByInjectingVisitorDataIfNeeded(NSURLRequest *request) {
    if (![request isKindOfClass:[NSURLRequest class]]) {
        return request;
    }

    NSURL *requestURL = request.URL;
    BOOL isInnerTube = isInnerTubeRequest(requestURL);
    BOOL isTrackedGoogleVideo = isGoogleVideoPlaybackRequest(requestURL);

    if (!isInnerTube && !isTrackedGoogleVideo) {
        return request;
    }

    NSDictionary *headers = request.allHTTPHeaderFields;
    NSString *cookieHeader = headerValueForKey(headers, @"Cookie");
    NSString *visitorDataFromHeaders = headerValueForKey(headers, @"X-Goog-Visitor-Id");
    if (visitorDataFromHeaders.length) {
        cacheVisitorData(visitorDataFromHeaders);
    }

    NSString *visitorDataFromCookie = extractVisitorDataFromCookies(cookieHeader);
    if (visitorDataFromCookie.length) {
        cacheVisitorData(visitorDataFromCookie);
    }

    recordPlaybackRequestDiagnostic(request, nil, NO, NO);
    return request;
}

static void cacheVisitorDataFromResponse(NSURLResponse *response, NSData *data) {
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSDictionary *headers = ((NSHTTPURLResponse *)response).allHeaderFields;
        NSString *visitorDataFromHeaders = headerValueForKey(headers, @"X-Goog-Visitor-Id");
        if (!visitorDataFromHeaders.length) {
            visitorDataFromHeaders = headerValueForKey(headers, @"X-Youtube-Client-Visitor-Id");
        }
        if (!visitorDataFromHeaders.length) {
            visitorDataFromHeaders = extractVisitorDataFromSetCookieHeader(headers);
        }
        if (visitorDataFromHeaders.length) {
            cacheVisitorData(visitorDataFromHeaders);
            return;
        }
    }

    NSString *visitorDataFromBody = extractVisitorDataFromBody(data);
    if (visitorDataFromBody.length) {
        cacheVisitorData(visitorDataFromBody);
    }
}

@interface UYEPlaybackSessionDelegateProxy : NSObject <NSURLSessionDelegate, NSURLSessionTaskDelegate, NSURLSessionDataDelegate>
- (instancetype)initWithDelegate:(id)delegate;
@end

@implementation UYEPlaybackSessionDelegateProxy {
    id _delegate;
    NSMutableSet<NSNumber *> *_trackedTaskIDs;
    NSMutableDictionary<NSNumber *, NSMutableData *> *_capturedTaskData;
    NSMutableDictionary<NSNumber *, NSURLRequest *> *_capturedTaskRequests;
}

- (instancetype)initWithDelegate:(id)delegate {
    self = [super init];
    if (self) {
        _delegate = delegate;
        _trackedTaskIDs = [NSMutableSet set];
        _capturedTaskData = [NSMutableDictionary dictionary];
        _capturedTaskRequests = [NSMutableDictionary dictionary];
    }
    return self;
}

- (BOOL)respondsToSelector:(SEL)selector {
    return [super respondsToSelector:selector] || [_delegate respondsToSelector:selector];
}

- (BOOL)conformsToProtocol:(Protocol *)aProtocol {
    return [super conformsToProtocol:aProtocol] || [_delegate conformsToProtocol:aProtocol];
}

- (id)forwardingTargetForSelector:(SEL)selector {
    if ([_delegate respondsToSelector:selector]) {
        return _delegate;
    }
    return [super forwardingTargetForSelector:selector];
}

- (NSNumber *)taskKeyForTask:(NSURLSessionTask *)task {
    if (![task isKindOfClass:[NSURLSessionTask class]]) {
        return nil;
    }
    return @(task.taskIdentifier);
}

- (void)beginTrackingTask:(NSURLSessionTask *)task response:(NSURLResponse *)response {
    NSNumber *taskKey = [self taskKeyForTask:task];
    if (!taskKey) {
        return;
    }

    NSURLRequest *request = task.currentRequest ?: task.originalRequest;
    NSURL *url = request.URL ?: response.URL;
    if (!playbackEndpointCodeForURL(url).length) {
        return;
    }

    @synchronized (self) {
        [_trackedTaskIDs addObject:taskKey];
        if (request) {
            _capturedTaskRequests[taskKey] = request;
        }
        if (!_capturedTaskData[taskKey]) {
            _capturedTaskData[taskKey] = [NSMutableData data];
        }
    }
}

- (void)appendData:(NSData *)data forTask:(NSURLSessionTask *)task {
    if (![data isKindOfClass:[NSData class]] || data.length == 0) {
        return;
    }

    NSNumber *taskKey = [self taskKeyForTask:task];
    if (!taskKey) {
        return;
    }

    @synchronized (self) {
        if (![_trackedTaskIDs containsObject:taskKey]) {
            return;
        }

        NSMutableData *buffer = _capturedTaskData[taskKey];
        if (!buffer) {
            buffer = [NSMutableData data];
            _capturedTaskData[taskKey] = buffer;
        }

        if (buffer.length >= kPlaybackDiagMaxBodyCaptureBytes) {
            return;
        }

        NSUInteger remainingBytes = kPlaybackDiagMaxBodyCaptureBytes - buffer.length;
        NSData *chunk = data;
        if (chunk.length > remainingBytes) {
            chunk = [chunk subdataWithRange:NSMakeRange(0, remainingBytes)];
        }
        [buffer appendData:chunk];
    }
}

- (void)finishTrackingTask:(NSURLSessionTask *)task error:(NSError *)error {
    NSNumber *taskKey = [self taskKeyForTask:task];
    NSURLRequest *fallbackRequest = task.currentRequest ?: task.originalRequest;
    NSURLResponse *response = task.response;

    BOOL tracked = NO;
    NSData *capturedData = nil;
    NSURLRequest *capturedRequest = nil;

    if (taskKey) {
        @synchronized (self) {
            tracked = [_trackedTaskIDs containsObject:taskKey];
            if (tracked) {
                capturedData = [_capturedTaskData[taskKey] copy];
                capturedRequest = _capturedTaskRequests[taskKey];
                [_trackedTaskIDs removeObject:taskKey];
                [_capturedTaskData removeObjectForKey:taskKey];
                [_capturedTaskRequests removeObjectForKey:taskKey];
            }
        }
    }

    if (!tracked) {
        NSURL *url = fallbackRequest.URL ?: response.URL;
        tracked = playbackEndpointCodeForURL(url).length > 0;
    }

    if (!tracked) {
        return;
    }

    NSURLRequest *request = capturedRequest ?: fallbackRequest;
    if (!request && [response.URL isKindOfClass:[NSURL class]]) {
        request = [NSURLRequest requestWithURL:response.URL];
    }
    cacheVisitorDataFromResponse(response, capturedData);
    recordPlaybackResponseDiagnostic(request, response, capturedData, error);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {
    [self beginTrackingTask:dataTask response:response];

    if ([_delegate respondsToSelector:_cmd]) {
        [(id<NSURLSessionDataDelegate>)_delegate URLSession:session dataTask:dataTask didReceiveResponse:response completionHandler:completionHandler];
        return;
    }

    if (completionHandler) {
        completionHandler(NSURLSessionResponseAllow);
    }
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    [self appendData:data forTask:dataTask];

    if ([_delegate respondsToSelector:_cmd]) {
        [(id<NSURLSessionDataDelegate>)_delegate URLSession:session dataTask:dataTask didReceiveData:data];
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    [self finishTrackingTask:task error:error];

    if ([_delegate respondsToSelector:_cmd]) {
        [(id<NSURLSessionTaskDelegate>)_delegate URLSession:session task:task didCompleteWithError:error];
    }
}
@end

static const void *kPlaybackDiagSessionDelegateProxyAssociationKey = &kPlaybackDiagSessionDelegateProxyAssociationKey;

static id wrappedSessionDelegateForPlaybackDiagnostics(id delegate) {
    if (!delegate || [delegate isKindOfClass:[UYEPlaybackSessionDelegateProxy class]]) {
        return delegate;
    }
    return [[UYEPlaybackSessionDelegateProxy alloc] initWithDelegate:delegate];
}

static void retainWrappedSessionDelegateProxy(NSURLSession *session, id originalDelegate, id wrappedDelegate) {
    if (session && wrappedDelegate && wrappedDelegate != originalDelegate) {
        objc_setAssociatedObject(session, kPlaybackDiagSessionDelegateProxyAssociationKey, wrappedDelegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

%group gVisitorDataFix
%hook NSMutableURLRequest
- (void)setValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if ([field isKindOfClass:[NSString class]] && [field caseInsensitiveCompare:@"X-Goog-Visitor-Id"] == NSOrderedSame) {
        cacheVisitorData(value);
    }
    %orig;
}

- (void)setAllHTTPHeaderFields:(NSDictionary<NSString *, NSString *> *)headerFields {
    cacheVisitorData(headerValueForKey(headerFields, @"X-Goog-Visitor-Id"));
    %orig(headerFields);
}
%end

%hook NSURLSession
+ (NSURLSession *)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration delegate:(id<NSURLSessionDelegate>)delegate delegateQueue:(NSOperationQueue *)queue {
    id wrappedDelegate = wrappedSessionDelegateForPlaybackDiagnostics(delegate);
    NSURLSession *session = %orig(configuration, wrappedDelegate, queue);
    retainWrappedSessionDelegateProxy(session, delegate, wrappedDelegate);
    return session;
}

- (instancetype)initWithConfiguration:(NSURLSessionConfiguration *)configuration delegate:(id<NSURLSessionDelegate>)delegate delegateQueue:(NSOperationQueue *)queue {
    id wrappedDelegate = wrappedSessionDelegateForPlaybackDiagnostics(delegate);
    NSURLSession *session = %orig(configuration, wrappedDelegate, queue);
    retainWrappedSessionDelegateProxy(session, delegate, wrappedDelegate);
    return session;
}

- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url {
    NSURLRequest *request = [NSURLRequest requestWithURL:url];
    return [self dataTaskWithRequest:request];
}

- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    NSURLRequest *request = [NSURLRequest requestWithURL:url];
    return [self dataTaskWithRequest:request completionHandler:completionHandler];
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    return %orig(requestByInjectingVisitorDataIfNeeded(request));
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    NSURLRequest *patchedRequest = requestByInjectingVisitorDataIfNeeded(request);
    void (^wrappedCompletion)(NSData *data, NSURLResponse *response, NSError *error) = ^(NSData *data, NSURLResponse *response, NSError *error) {
        cacheVisitorDataFromResponse(response, data);
        recordPlaybackResponseDiagnostic(patchedRequest, response, data, error);
        if (completionHandler) {
            completionHandler(data, response, error);
        }
    };
    return %orig(patchedRequest, wrappedCompletion);
}

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)bodyData {
    return %orig(requestByInjectingVisitorDataIfNeeded(request), bodyData);
}

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)bodyData completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    NSURLRequest *patchedRequest = requestByInjectingVisitorDataIfNeeded(request);
    void (^wrappedCompletion)(NSData *data, NSURLResponse *response, NSError *error) = ^(NSData *data, NSURLResponse *response, NSError *error) {
        cacheVisitorDataFromResponse(response, data);
        recordPlaybackResponseDiagnostic(patchedRequest, response, data, error);
        if (completionHandler) {
            completionHandler(data, response, error);
        }
    };
    return %orig(patchedRequest, bodyData, wrappedCompletion);
}

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromFile:(NSURL *)fileURL {
    return %orig(requestByInjectingVisitorDataIfNeeded(request), fileURL);
}

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromFile:(NSURL *)fileURL completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    NSURLRequest *patchedRequest = requestByInjectingVisitorDataIfNeeded(request);
    void (^wrappedCompletion)(NSData *data, NSURLResponse *response, NSError *error) = ^(NSData *data, NSURLResponse *response, NSError *error) {
        cacheVisitorDataFromResponse(response, data);
        recordPlaybackResponseDiagnostic(patchedRequest, response, data, error);
        if (completionHandler) {
            completionHandler(data, response, error);
        }
    };
    return %orig(patchedRequest, fileURL, wrappedCompletion);
}

- (NSURLSessionUploadTask *)uploadTaskWithStreamedRequest:(NSURLRequest *)request {
    return %orig(requestByInjectingVisitorDataIfNeeded(request));
}

- (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request {
    return %orig(requestByInjectingVisitorDataIfNeeded(request));
}

- (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURL *location, NSURLResponse *response, NSError *error))completionHandler {
    NSURLRequest *patchedRequest = requestByInjectingVisitorDataIfNeeded(request);
    void (^wrappedCompletion)(NSURL *location, NSURLResponse *response, NSError *error) = ^(NSURL *location, NSURLResponse *response, NSError *error) {
        recordPlaybackResponseDiagnostic(patchedRequest, response, nil, error);
        if (completionHandler) {
            completionHandler(location, response, error);
        }
    };
    return %orig(patchedRequest, wrappedCompletion);
}

- (NSURLSessionDownloadTask *)downloadTaskWithURL:(NSURL *)url {
    NSURLRequest *request = [NSURLRequest requestWithURL:url];
    return [self downloadTaskWithRequest:request];
}

- (NSURLSessionDownloadTask *)downloadTaskWithURL:(NSURL *)url completionHandler:(void (^)(NSURL *location, NSURLResponse *response, NSError *error))completionHandler {
    NSURLRequest *request = [NSURLRequest requestWithURL:url];
    return [self downloadTaskWithRequest:request completionHandler:completionHandler];
}
%end

%hook NSHTTPURLResponse
- (instancetype)initWithURL:(NSURL *)URL statusCode:(NSInteger)statusCode HTTPVersion:(NSString *)HTTPVersion headerFields:(NSDictionary *)headerFields {
    id response = %orig(URL, statusCode, HTTPVersion, headerFields);
    recordPlaybackHTTPStatusDiagnostic(URL, statusCode, headerFields);
    return response;
}
%end
%end

// Reposition "Create" Tab to the Center in the Pivot Bar - qnblackcat/uYouPlus#107
/*
static void repositionCreateTab(YTIGuideResponse *response) {
    NSMutableArray<YTIGuideResponseSupportedRenderers *> *renderers = [response itemsArray];
    for (YTIGuideResponseSupportedRenderers *guideRenderers in renderers) {
        YTIPivotBarRenderer *pivotBarRenderer = [guideRenderers pivotBarRenderer];
        NSMutableArray<YTIPivotBarSupportedRenderers *> *items = [pivotBarRenderer itemsArray];
        NSUInteger createIndex = [items indexOfObjectPassingTest:^BOOL(YTIPivotBarSupportedRenderers *renderers, NSUInteger idx, BOOL *stop) {
            return [[[renderers pivotBarItemRenderer] pivotIdentifier] isEqualToString:@"FEuploads"];
        }];
        if (createIndex != NSNotFound) {
            YTIPivotBarSupportedRenderers *createTab = [items objectAtIndex:createIndex];
            [items removeObjectAtIndex:createIndex];
            NSUInteger centerIndex = items.count / 2;
            [items insertObject:createTab atIndex:centerIndex]; // Reposition the "Create" tab at the center
        }
    }
}
%hook YTGuideServiceCoordinator
- (void)handleResponse:(YTIGuideResponse *)response withCompletion:(id)completion {
    repositionCreateTab(response);
    %orig(response, completion);
}
- (void)handleResponse:(YTIGuideResponse *)response error:(id)error completion:(id)completion {
    repositionCreateTab(response);
    %orig(response, error, completion);
}
%end
*/

// https://github.com/PoomSmart/YouTube-X/blob/1e62b68e9027fcb849a75f54a402a530385f2a51/Tweak.x#L27
// %hook YTAdsInnerTubeContextDecorator
// - (void)decorateContext:(id)context {}
// %end

# pragma mark - uYou patches

// Workaround for qnblackcat/uYouPlus#10
%hook UIViewController
- (UITraitCollection *)traitCollection {
    @try {
        return %orig;
    } @catch(NSException *e) {
        return [UITraitCollection currentTraitCollection];
    }
}
%end

// Prevent uYou player bar from showing when not playing downloaded media
%hook PlayerManager
- (void)pause {
    if (isnan([self progress]))
        return;
    %orig;
}
%end

// Workaround for issue #54
%hook YTMainAppVideoPlayerOverlayViewController
- (void)updateRelatedVideos {
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"relatedVideosAtTheEndOfYTVideos"] == NO) {}
    else { return %orig; }
}
%end

// YouTube Native Share - https://github.com/jkhsjdhjs/youtube-native-share - @jkhsjdhjs
typedef NS_ENUM(NSInteger, ShareEntityType) {
    ShareEntityFieldVideo = 1,
    ShareEntityFieldPlaylist = 2,
    ShareEntityFieldChannel = 3,
    ShareEntityFieldPost = 6,
    ShareEntityFieldClip = 8,
    ShareEntityFieldShortFlag = 10
};

static inline NSString* extractIdWithFormat(GPBUnknownFields *fields, NSInteger fieldNumber, NSString *format) {
    NSArray<GPBUnknownField*> *fieldArray = [fields fields:fieldNumber];
    if (!fieldArray)
        return nil;
    if ([fieldArray count] != 1)
        return nil;
    NSString *id = [[NSString alloc] initWithData:[fieldArray firstObject].lengthDelimited encoding:NSUTF8StringEncoding];
    return [NSString stringWithFormat:format, id];
}

static BOOL showNativeShareSheet(NSString *serializedShareEntity, UIView *sourceView) {
    GPBMessage *shareEntity = [%c(GPBMessage) deserializeFromString:serializedShareEntity];
    GPBUnknownFields *fields = [[%c(GPBUnknownFields) alloc] initFromMessage:shareEntity];
    NSString *shareUrl;

    NSArray<GPBUnknownField*> *shareEntityClip = [fields fields:ShareEntityFieldClip];
    if (shareEntityClip) {
        if ([shareEntityClip count] != 1)
            return NO;
        GPBMessage *clipMessage = [%c(GPBMessage) parseFromData:[shareEntityClip firstObject].lengthDelimited error:nil];
        shareUrl = extractIdWithFormat([[%c(GPBUnknownFields) alloc] initFromMessage:clipMessage], 1, @"https://youtube.com/clip/%@");
    }

    if (!shareUrl)
        shareUrl = extractIdWithFormat(fields, ShareEntityFieldChannel, @"https://youtube.com/channel/%@");

    if (!shareUrl) {
        shareUrl = extractIdWithFormat(fields, ShareEntityFieldPlaylist, @"%@");
        if (shareUrl) {
            if (![shareUrl hasPrefix:@"PL"] && ![shareUrl hasPrefix:@"FL"])
                shareUrl = [shareUrl stringByAppendingString:@"&playnext=1"];
            shareUrl = [@"https://youtube.com/playlist?list=" stringByAppendingString:shareUrl];
        }
    }

    if (!shareUrl) {
        NSString *format = @"https://youtube.com/watch?v=%@";
        if ([fields fields:ShareEntityFieldShortFlag])
            format = @"https://youtube.com/shorts/%@";
        shareUrl = extractIdWithFormat(fields, ShareEntityFieldVideo, format);
    }

    if (!shareUrl)
        shareUrl = extractIdWithFormat(fields, ShareEntityFieldPost, @"https://youtube.com/post/%@");

    if (!shareUrl)
        return NO;

    UIActivityViewController *activityViewController = [[UIActivityViewController alloc] initWithActivityItems:@[shareUrl] applicationActivities:nil];
    activityViewController.excludedActivityTypes = @[UIActivityTypeAssignToContact, UIActivityTypePrint];

    UIViewController *topViewController = [%c(YTUIUtils) topViewControllerForPresenting];

    if (activityViewController.popoverPresentationController) {
        activityViewController.popoverPresentationController.sourceView = topViewController.view;
        activityViewController.popoverPresentationController.sourceRect = [sourceView convertRect:sourceView.bounds toView:topViewController.view];
    }

    [topViewController presentViewController:activityViewController animated:YES completion:nil];

    return YES;
}

/* -------------------- iPad Layout -------------------- */

// %group gYouTubeNativeShare // YouTube Native Share Option - 0.2.3 - Supports YouTube v17.33.2-v19.34.2
%hook YTAccountScopedCommandResponderEvent
- (void)send {
    GPBExtensionDescriptor *shareEntityEndpointDescriptor = [%c(YTIShareEntityEndpoint) shareEntityEndpoint];
    if (![self.command hasExtension:shareEntityEndpointDescriptor])
        return %orig;
    YTIShareEntityEndpoint *shareEntityEndpoint = [self.command getExtension:shareEntityEndpointDescriptor];
    if (!shareEntityEndpoint.hasSerializedShareEntity)
        return %orig;
    if (!showNativeShareSheet(shareEntityEndpoint.serializedShareEntity, self.fromView))
        return %orig;
}
%end


/* ------------------- iPhone Layout ------------------- */

%hook ELMPBShowActionSheetCommand
- (void)executeWithCommandContext:(ELMCommandContext*)context handler:(id)_handler {
    if (!self.hasOnAppear)
        return %orig;
    GPBExtensionDescriptor *innertubeCommandDescriptor = [%c(YTIInnertubeCommandExtensionRoot) innertubeCommand];
    if (![self.onAppear hasExtension:innertubeCommandDescriptor])
        return %orig;
    YTICommand *innertubeCommand = [self.onAppear getExtension:innertubeCommandDescriptor];
    GPBExtensionDescriptor *updateShareSheetCommandDescriptor = [%c(YTIUpdateShareSheetCommand) updateShareSheetCommand];
    if(![innertubeCommand hasExtension:updateShareSheetCommandDescriptor])
        return %orig;
    YTIUpdateShareSheetCommand *updateShareSheetCommand = [innertubeCommand getExtension:updateShareSheetCommandDescriptor];
    if (!updateShareSheetCommand.hasSerializedShareEntity)
        return %orig;
    if (!showNativeShareSheet(updateShareSheetCommand.serializedShareEntity, context.context.fromView))
        return %orig;
}
%end
// %end

//

// iOS 16 uYou crash fix - @level3tjg: https://github.com/qnblackcat/uYouPlus/pull/224
// %group iOS16
// %hook OBPrivacyLinkButton
// %new
// - (instancetype)initWithCaption:(NSString *)caption
//                      buttonText:(NSString *)buttonText
//                           image:(UIImage *)image
//                       imageSize:(CGSize)imageSize
//                    useLargeIcon:(BOOL)useLargeIcon {
//   return [self initWithCaption:caption
//                     buttonText:buttonText
//                          image:image
//                      imageSize:imageSize
//                   useLargeIcon:useLargeIcon
//                displayLanguage:[NSLocale currentLocale].languageCode];
// }
// %end
// %end

// Fix uYou playback speed crashes YT v18.49.3+, see https://github.com/iCrazeiOS/uYouCrashFix
// %hook YTPlayerViewController
// %new
// -(float)currentPlaybackRateForVarispeedSwitchController:(id)arg1 {
// 	return [[self activeVideo] playbackRate];
// }

// %new
// -(void)varispeedSwitchController:(id)arg1 didSelectRate:(float)arg2 {
// 	[[self activeVideo] setPlaybackRate:arg2];
// }
// %end

// Fix streched artwork in uYou's player view - https://github.com/MiRO92/uYou-for-YouTube/issues/287
%hook ArtworkImageView
- (id)imageView {
    UIImageView * imageView = %orig;
    imageView.contentMode = UIViewContentModeScaleAspectFit;
    // Make artwork a bit bigger
    UIView *artworkImageView = imageView.superview;
    if (artworkImageView != nil && !artworkImageView.translatesAutoresizingMaskIntoConstraints) {
        [artworkImageView.leftAnchor constraintEqualToAnchor:artworkImageView.superview.leftAnchor constant:16].active = YES;
        [artworkImageView.rightAnchor constraintEqualToAnchor:artworkImageView.superview.rightAnchor constant:-16].active = YES;
    }
    return imageView;
}
%end

// Fix navigation bar showing a lighter grey with default dark mode - https://github.com/therealFoxster/uYouPlus/commit/8db8197
%hook YTCommonColorPalette
- (UIColor *)brandBackgroundSolid {
    return self.pageStyle == 1 ? [UIColor colorWithRed:0.05882352941176471 green:0.05882352941176471 blue:0.05882352941176471 alpha:1.0] : %orig;
}
%end

// Fix uYou's appearance not updating if the app is backgrounded
static DownloadsPagerVC *downloadsPagerVC;
static NSUInteger selectedTabIndex;
%hook DownloadsPagerVC
- (id)init {
    downloadsPagerVC = %orig;
    return downloadsPagerVC;
}
- (void)viewPager:(id)viewPager didChangeTabToIndex:(NSUInteger)arg1 fromTabIndex:(NSUInteger)arg2 {
    %orig; selectedTabIndex = arg1;
}
%end
static void refreshUYouAppearance() {
    if (!downloadsPagerVC) return;
    // View pager
    [downloadsPagerVC updatePageStyles];
    // Views
    for (UIViewController *vc in [downloadsPagerVC viewControllers]) {
        if ([vc isKindOfClass:%c(DownloadingVC)]) {
            // `Downloading` view
            [(DownloadingVC *)vc updatePageStyles];
            for (UITableViewCell *cell in [(DownloadingVC *)vc tableView].visibleCells)
                if ([cell isKindOfClass:%c(DownloadingCell)])
                    [(DownloadingCell *)cell updatePageStyles];
        }
        else if ([vc isKindOfClass:%c(DownloadedVC)]) {
            // `All`, `Audios`, `Videos`, `Shorts` views
            [(DownloadedVC *)vc updatePageStyles];
            for (UITableViewCell *cell in [(DownloadedVC *)vc tableView].visibleCells)
                if ([cell isKindOfClass:%c(DownloadedCell)])
                    [(DownloadedCell *)cell updatePageStyles];
        }
    }
    // View pager tabs
    for (UIView *subview in [downloadsPagerVC view].subviews) {
        if ([subview isKindOfClass:[UIScrollView class]]) {
            UIScrollView *tabs = (UIScrollView *)subview;
            NSUInteger i = 0;
            for (UIView *item in tabs.subviews) {
                if ([item isKindOfClass:[UILabel class]]) {
                    // Tab label
                    UILabel *tabLabel = (UILabel *)item;
                    if (i == selectedTabIndex) {} // Selected tab should be excluded
                    else [tabLabel setTextColor:[UILabel _defaultColor]];
                    i++;
                }
            }
        }
    }
}
%hook UIViewController
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        refreshUYouAppearance();
    });
}
%end

// Prevent uYou's playback from colliding with YouTube's
%hook PlayerVC
- (void)close {
    %orig;
    [[%c(PlayerManager) sharedInstance] setSource:nil];
}
%end
%hook HAMPlayerInternal
- (void)play {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[%c(PlayerManager) sharedInstance] pause];
    });
    %orig;
}
%end

// Temporarily disable uYou's bouncy animation cause it's buggy
%hook SSBouncyButton
- (void)beginShrinkAnimation {}
- (void)beginEnlargeAnimation {}
%end

%hook GOODialogView
- (id)imageView {
    UIImageView *imageView = %orig;

    if ([[self titleLabel].text containsString:@"uYou\n"]) {
        // // Invert uYou logo in download dialog if dark mode is enabled
        // if ([[NSUserDefaults standardUserDefaults] integerForKey:@"page_style"] == 0)
        //     return imageView;
        // // https://gist.github.com/coryalder/3113a43734f5e0e4b497
        // UIImage *image = [imageView image];
        // CIImage *ciImage = [[CIImage alloc] initWithImage:image];
        // CIFilter *filter = [CIFilter filterWithName:@"CIColorInvert"];
        // [filter setDefaults];
        // [filter setValue:ciImage forKey:kCIInputImageKey];
        // CIContext *context = [CIContext contextWithOptions:nil];
        // CIImage *output = [filter outputImage];
        // CGImageRef cgImage = [context createCGImage:output fromRect:[output extent]];
        // UIImage *icon = [UIImage imageWithCGImage:cgImage];
        // CGImageRelease(cgImage);

        // Load icon_clipped.png from uYouBundle.bundle
        NSString *bundlePath = [[NSBundle mainBundle] pathForResource:@"uYouBundle" ofType:@"bundle"];
        NSBundle *bundle = [NSBundle bundleWithPath:bundlePath];
        NSString *iconPath = [bundle pathForResource:@"icon_clipped" ofType:@"png"];
        UIImage *icon = [UIImage imageWithContentsOfFile:iconPath];
        [imageView setImage:icon];

        // Resize image to 30x30
        // https://stackoverflow.com/a/2658801/19227228
        CGSize size = CGSizeMake(30, 30);
        UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
        [icon drawInRect:CGRectMake(0, 0, size.width, size.height)];
        UIImage *resizedImage = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();

        [imageView setImage:resizedImage];
    }

    return imageView;
}
// Increase space between uYou label and video title
- (id)titleLabel {
    UILabel *titleLabel = %orig;
    if ([titleLabel.text containsString:@"uYou\n"] &&
        ![titleLabel.text containsString:@"uYou\n\n"]
    ) {
        NSString *text = [titleLabel.text stringByReplacingOccurrencesOfString:@"uYou\n" withString:@"uYou\n\n"];
        [titleLabel setText:text];
    }
    return titleLabel;
}
%end

%hook YTPlayerViewController
 
 - (id)varispeedController {
     id controller = %orig;
     if (controller == nil && [self respondsToSelector:@selector(overlayManager)])
         controller = [self.overlayManager varispeedController];
     return controller;
 }
 
 %end

%ctor {
    if (kPlaybackIsolationStage == 0) {
        return;
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (![defaults objectForKey:kPlaybackDiagnosticsBanner]) {
        [defaults setBool:YES forKey:kPlaybackDiagnosticsBanner];
    }
    if (![defaults objectForKey:kPlaybackDiagnosticsAutoCopy]) {
        [defaults setBool:YES forKey:kPlaybackDiagnosticsAutoCopy];
    }

    uYouEnhancedPlaybackDiagnosticsClear();
    appendPlaybackDiagnosticLine([NSString stringWithFormat:@"%@ APP_INIT stage=%ld mode=observer_only", playbackDiagTimestamp(), (long)kPlaybackIsolationStage], nil, NO);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1800 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        showPlaybackDiagnosticsBanner(@"Playback diagnostics active");
    });
    setupAVPlayerItemDiagnosticsObservers();

    %init(gGoogleSignInPatch);
    %init(gVisitorDataFix);

    if (kPlaybackIsolationStage == 1) {
        return;
    }

    %init;
/*
    if (IS_ENABLED(kYouTubeNativeShare)) {
        %init(gYouTubeNativeShare);
    }
*/
    // if (@available(iOS 16, *)) {
    //     %init(iOS16);
    // }

    // Disable broken options
    
    // Disable uYou's auto updates
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"automaticallyCheckForUpdates"];

    // Disable uYou's welcome screen (fix #1147)
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"showedWelcomeVC"];
 
    // Disable uYou's disable age restriction
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"disableAgeRestriction"];

    // Disable uYou's playback speed controls (prevent crash on video playback https://github.com/therealFoxster/uYouPlus/issues/2#issuecomment-1894912963)
    // [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"showPlaybackRate"];
}
