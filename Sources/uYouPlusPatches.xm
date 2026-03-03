#import "uYouPlusPatches.h"

#define YT_BUNDLE_ID @"com.google.ios.youtube"
#define YT_NAME @"YouTube"
static NSInteger const kPlaybackIsolationStage = 1;

# pragma mark - YouTube patches

// Fix Google Sign in Patch
%group gGoogleSignInPatch
%hook NSBundle
+ (NSBundle *)bundleWithIdentifier:(NSString *)identifier {
    if ([identifier isEqualToString:YT_BUNDLE_ID])
        return NSBundle.mainBundle;
    return %orig(identifier);
}
- (NSString *)bundleIdentifier {
    return [self isEqual:NSBundle.mainBundle] ? YT_BUNDLE_ID : %orig;
}
- (NSDictionary *)infoDictionary {
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
static BOOL visitorBootstrapRequested = NO;

static dispatch_queue_t visitorDataQueue() {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.uyouenhanced.visitor-data", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
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

static BOOL shouldStripSignedInHeadersForURL(NSURL *url) {
    return isGoogleVideoPlaybackRequest(url);
}

static BOOL isBlockedSignedInHeaderField(NSString *field) {
    if (![field isKindOfClass:[NSString class]]) {
        return NO;
    }
    NSString *lowerField = field.lowercaseString;
    return [lowerField isEqualToString:@"authorization"] ||
           [lowerField isEqualToString:@"cookie"] ||
           [lowerField isEqualToString:@"x-goog-authuser"] ||
           [lowerField isEqualToString:@"x-goog-pageid"] ||
           [lowerField isEqualToString:@"x-goog-device-auth"];
}

static NSString *extractVisitorDataFromURL(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) {
        return nil;
    }
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *queryItem in components.queryItems) {
        if (![queryItem.name isKindOfClass:[NSString class]]) {
            continue;
        }
        NSString *key = queryItem.name.lowercaseString;
        if ([key isEqualToString:@"visitordata"] || [key isEqualToString:@"visitor_data"]) {
            return trimmedString(queryItem.value);
        }
    }
    return nil;
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
    if (![data isKindOfClass:[NSData class]] || data.length == 0 || data.length > (1024 * 1024)) {
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

static NSString *currentVisitorData() {
    __block NSString *value = nil;
    dispatch_sync(visitorDataQueue(), ^{
        if (!cachedVisitorData.length) {
            cachedVisitorData = trimmedString([[NSUserDefaults standardUserDefaults] stringForKey:kCachedVisitorDataKey]);
        }
        value = cachedVisitorData;
    });
    return value;
}

static void bootstrapVisitorDataFromWebIfNeeded(void) {
    if (visitorBootstrapRequested || currentVisitorData().length) {
        return;
    }

    visitorBootstrapRequested = YES;
    NSURL *url = [NSURL URLWithString:@"https://www.youtube.com"];
    if (!url) {
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:12.0];
    [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"en-US,en;q=0.9" forHTTPHeaderField:@"Accept-Language"];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            return;
        }

        NSString *visitorDataFromHeaders = nil;
        if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSDictionary *headers = ((NSHTTPURLResponse *)response).allHeaderFields;
            visitorDataFromHeaders = headerValueForKey(headers, @"X-Goog-Visitor-Id");
            if (!visitorDataFromHeaders.length) {
                visitorDataFromHeaders = headerValueForKey(headers, @"X-Youtube-Client-Visitor-Id");
            }
            if (!visitorDataFromHeaders.length) {
                visitorDataFromHeaders = extractVisitorDataFromSetCookieHeader(headers);
            }
        }

        NSString *resolvedVisitorData = visitorDataFromHeaders.length ? visitorDataFromHeaders : extractVisitorDataFromBody(data);
        if (resolvedVisitorData.length) {
            cacheVisitorData(resolvedVisitorData);
        }
    }];
    [task resume];
}

static NSURLRequest *requestByInjectingVisitorDataIfNeeded(NSURLRequest *request) {
    if (![request isKindOfClass:[NSURLRequest class]]) {
        return request;
    }

    NSURL *requestURL = request.URL;
    BOOL isInnerTube = isInnerTubeRequest(requestURL);
    BOOL shouldNormalizePlaybackIdentity = shouldStripSignedInHeadersForURL(requestURL);

    if (!isInnerTube && !shouldNormalizePlaybackIdentity) {
        return request;
    }

    NSDictionary *headers = request.allHTTPHeaderFields;
    NSString *authorizationHeader = headerValueForKey(headers, @"Authorization");
    NSString *cookieHeader = headerValueForKey(headers, @"Cookie");
    NSString *authUserHeader = headerValueForKey(headers, @"X-Goog-AuthUser");

    BOOL hasSignedInCookie = NO;
    if (cookieHeader.length) {
        hasSignedInCookie = ([cookieHeader rangeOfString:@"SAPISID" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                             [cookieHeader rangeOfString:@"__Secure-3PAPISID" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                             [cookieHeader rangeOfString:@"SID=" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                             [cookieHeader rangeOfString:@"HSID=" options:NSCaseInsensitiveSearch].location != NSNotFound);
    }
    BOOL shouldStripSignedInHeadersForPlayback = shouldNormalizePlaybackIdentity &&
        (authorizationHeader.length > 0 || authUserHeader.length > 0 || hasSignedInCookie || headerLooksLoggedIn(headers));

    NSString *visitorData = nil;
    NSString *visitorDataFromHeaders = headerValueForKey(headers, @"X-Goog-Visitor-Id");
    if (visitorDataFromHeaders.length) {
        cacheVisitorData(visitorDataFromHeaders);
        visitorData = visitorDataFromHeaders;
    }

    NSString *visitorDataFromCookie = extractVisitorDataFromCookies(cookieHeader);
    if (visitorDataFromCookie.length) {
        cacheVisitorData(visitorDataFromCookie);
        if (!visitorData.length) {
            visitorData = visitorDataFromCookie;
        }
    }

    if (!visitorData.length) {
        visitorData = currentVisitorData();
    }

    if (isInnerTube) {
        if (!visitorData.length) {
            visitorData = extractVisitorDataFromURL(requestURL);
        }
        if (!visitorData.length) {
            visitorData = extractVisitorDataFromBody(request.HTTPBody);
        }
    }

    BOOL shouldInjectVisitorHeader = isInnerTube && visitorData.length > 0;
    if (isInnerTube && !shouldInjectVisitorHeader) {
        bootstrapVisitorDataFromWebIfNeeded();
    }

    if (!shouldStripSignedInHeadersForPlayback && !shouldInjectVisitorHeader) {
        return request;
    }

    NSMutableURLRequest *mutableRequest = [request mutableCopy];
    if (shouldInjectVisitorHeader) {
        [mutableRequest setValue:visitorData forHTTPHeaderField:@"X-Goog-Visitor-Id"];
    }

    if (shouldStripSignedInHeadersForPlayback) {
        [mutableRequest setValue:nil forHTTPHeaderField:@"Authorization"];
        [mutableRequest setValue:nil forHTTPHeaderField:@"Cookie"];
        [mutableRequest setValue:nil forHTTPHeaderField:@"X-Goog-AuthUser"];
        [mutableRequest setValue:nil forHTTPHeaderField:@"X-Goog-PageId"];
        [mutableRequest setValue:nil forHTTPHeaderField:@"X-Goog-Device-Auth"];
        [mutableRequest setValue:@"0" forHTTPHeaderField:@"X-Goog-Logged-In"];
        [mutableRequest setValue:@"0" forHTTPHeaderField:@"X-Youtube-Bootstrap-Logged-In"];
    }

    return mutableRequest;
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

%group gVisitorDataFix
%hook NSMutableURLRequest
- (void)setValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    NSURL *requestURL = self.URL;

    if (shouldStripSignedInHeadersForURL(requestURL) && isBlockedSignedInHeaderField(field) && value.length) {
        %orig(nil, field);
        return;
    }

    if ([field isKindOfClass:[NSString class]] && [field caseInsensitiveCompare:@"X-Goog-Visitor-Id"] == NSOrderedSame) {
        cacheVisitorData(value);
    }
    %orig;
}

- (void)setAllHTTPHeaderFields:(NSDictionary<NSString *, NSString *> *)headerFields {
    NSMutableDictionary<NSString *, NSString *> *normalizedHeaders = [headerFields isKindOfClass:[NSDictionary class]] ? [headerFields mutableCopy] : [NSMutableDictionary dictionary];

    NSURL *requestURL = self.URL;
    if (shouldStripSignedInHeadersForURL(requestURL)) {
        NSArray<NSString *> *blockedFields = @[@"Authorization", @"Cookie", @"X-Goog-AuthUser", @"X-Goog-PageId", @"X-Goog-Device-Auth"];
        for (NSString *blockedField in blockedFields) {
            [normalizedHeaders removeObjectForKey:blockedField];
            NSString *matchedHeader = nil;
            for (NSString *existingKey in normalizedHeaders.allKeys) {
                if ([existingKey caseInsensitiveCompare:blockedField] == NSOrderedSame) {
                    matchedHeader = existingKey;
                    break;
                }
            }
            if (matchedHeader) {
                [normalizedHeaders removeObjectForKey:matchedHeader];
            }
        }
    }

    cacheVisitorData(headerValueForKey(normalizedHeaders, @"X-Goog-Visitor-Id"));
    %orig(normalizedHeaders);
}
%end

%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    return %orig(requestByInjectingVisitorDataIfNeeded(request));
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    NSURLRequest *patchedRequest = requestByInjectingVisitorDataIfNeeded(request);
    void (^wrappedCompletion)(NSData *data, NSURLResponse *response, NSError *error) = ^(NSData *data, NSURLResponse *response, NSError *error) {
        cacheVisitorDataFromResponse(response, data);
        if (completionHandler) {
            completionHandler(data, response, error);
        }
    };
    return %orig(patchedRequest, wrappedCompletion);
}

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)bodyData completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    NSURLRequest *patchedRequest = requestByInjectingVisitorDataIfNeeded(request);
    void (^wrappedCompletion)(NSData *data, NSURLResponse *response, NSError *error) = ^(NSData *data, NSURLResponse *response, NSError *error) {
        cacheVisitorDataFromResponse(response, data);
        if (completionHandler) {
            completionHandler(data, response, error);
        }
    };
    return %orig(patchedRequest, bodyData, wrappedCompletion);
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

    bootstrapVisitorDataFromWebIfNeeded();
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
