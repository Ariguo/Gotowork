#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <signal.h>

#ifndef kCGAnyInputEventType
#define kCGAnyInputEventType ((CGEventType)~0)
#endif

static NSISO8601DateFormatter *ISOFormatter(void) {
    static NSISO8601DateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSISO8601DateFormatter alloc] init];
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    });
    return formatter;
}

static NSString *ExpandPath(NSString *path) {
    if ([path isEqualToString:@"~"]) {
        return NSHomeDirectory();
    }
    if ([path hasPrefix:@"~/"]) {
        return [[NSHomeDirectory() stringByAppendingPathComponent:[path substringFromIndex:2]] stringByStandardizingPath];
    }
    if (![path isAbsolutePath]) {
        path = [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:path];
    }
    return [path stringByStandardizingPath];
}

static NSString *ArgValue(NSArray<NSString *> *args, NSString *name, NSString *defaultValue) {
    NSUInteger index = [args indexOfObject:name];
    if (index == NSNotFound || index + 1 >= args.count) {
        return defaultValue;
    }
    return args[index + 1];
}

static BOOL ArgBool(NSArray<NSString *> *args, NSString *name) {
    return [args containsObject:name];
}

static double ArgDouble(NSArray<NSString *> *args, NSString *name, double defaultValue) {
    return [ArgValue(args, name, [NSString stringWithFormat:@"%f", defaultValue]) doubleValue];
}

static NSString *ClockString(NSDate *date) {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"HH:mm:ss";
    return [formatter stringFromDate:date];
}

static NSString *LocalDayString(NSDate *date) {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd";
    return [formatter stringFromDate:date];
}

static NSURL *GotoworkDataDirectoryURL(void) {
    NSURL *base = [[NSFileManager defaultManager] URLForDirectory:NSApplicationSupportDirectory
                                                         inDomain:NSUserDomainMask
                                                appropriateForURL:nil
                                                           create:YES
                                                            error:nil];
    return [base URLByAppendingPathComponent:@"Gotowork" isDirectory:YES];
}

static NSString *GotoworkRawPathForDay(NSString *day) {
    NSString *name = [NSString stringWithFormat:@"raw_%@.jsonl", day];
    return [[GotoworkDataDirectoryURL() URLByAppendingPathComponent:name] path];
}

static NSString *ShortDuration(double seconds) {
    NSInteger total = MAX(0, (NSInteger)llround(seconds));
    if (total < 60) {
        return [NSString stringWithFormat:@"%lds", (long)total];
    }
    NSInteger minutes = total / 60;
    NSInteger remainder = total % 60;
    if (minutes < 60) {
        return remainder == 0
            ? [NSString stringWithFormat:@"%ldm", (long)minutes]
            : [NSString stringWithFormat:@"%ldm%lds", (long)minutes, (long)remainder];
    }
    return [NSString stringWithFormat:@"%ldh%ldm", (long)(minutes / 60), (long)(minutes % 60)];
}

static NSString *DisplayTitle(NSString *title) {
    return title.length == 0 ? @"(untitled)" : title;
}

static BOOL IsBrowserBundle(NSString *bundleID) {
    static NSSet<NSString *> *browserBundles;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        browserBundles = [NSSet setWithArray:@[
            @"com.apple.Safari",
            @"com.google.Chrome",
            @"com.google.Chrome.canary",
            @"com.microsoft.edgemac",
            @"com.microsoft.edgemac.Canary",
            @"org.mozilla.firefox",
            @"com.brave.Browser",
            @"company.thebrowser.Browser",
            @"com.vivaldi.Vivaldi",
            @"com.operasoftware.Opera"
        ]];
    });
    return [browserBundles containsObject:bundleID ?: @""];
}

static NSString *Padded(NSString *value, NSUInteger width) {
    if (value.length >= width) {
        return value;
    }
    return [value stringByPaddingToLength:width withString:@" " startingAtIndex:0];
}

static double IdleSeconds(void) {
    return CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateHIDSystemState, kCGAnyInputEventType);
}

static id CopyAXAttribute(AXUIElementRef element, CFStringRef attribute) {
    CFTypeRef value = NULL;
    AXError error = AXUIElementCopyAttributeValue(element, attribute, &value);
    if (error != kAXErrorSuccess || value == NULL) {
        return nil;
    }
    return CFBridgingRelease(value);
}

static NSString *AXString(AXUIElementRef element, CFStringRef attribute) {
    id value = CopyAXAttribute(element, attribute);
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static NSString *FallbackWindowTitle(pid_t pid) {
    NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID
    ));
    for (NSDictionary *window in windows) {
        NSNumber *ownerPID = window[(NSString *)kCGWindowOwnerPID];
        NSNumber *layer = window[(NSString *)kCGWindowLayer];
        if (ownerPID.intValue == pid && layer.integerValue == 0) {
            NSString *title = window[(NSString *)kCGWindowName];
            if ([title isKindOfClass:[NSString class]]) {
                return title;
            }
        }
    }
    return @"";
}

static BOOL RequestAccessibilityIfNeeded(void) {
    NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
    return AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
}

static NSDictionary *CurrentSnapshot(double idleSeconds) {
    NSRunningApplication *app = [NSWorkspace sharedWorkspace].frontmostApplication;
    if (!app) {
        return nil;
    }

    pid_t pid = app.processIdentifier;
    NSString *bundleID = app.bundleIdentifier ?: [NSString stringWithFormat:@"pid:%d", pid];
    NSString *appName = app.localizedName ?: bundleID;
    AXUIElementRef axApp = AXUIElementCreateApplication(pid);
    id focusedWindow = CopyAXAttribute(axApp, kAXFocusedWindowAttribute);
    NSString *title = @"";
    NSString *role = @"";
    NSString *subrole = @"";

    if (focusedWindow) {
        AXUIElementRef window = (__bridge AXUIElementRef)focusedWindow;
        title = AXString(window, kAXTitleAttribute) ?: @"";
        role = AXString(window, kAXRoleAttribute) ?: @"";
        subrole = AXString(window, kAXSubroleAttribute) ?: @"";
    }
    if (title.length == 0) {
        title = FallbackWindowTitle(pid) ?: @"";
    }
    if (IsBrowserBundle(bundleID)) {
        title = @"";
    }
    if (axApp) {
        CFRelease(axApp);
    }

    NSString *identity = IsBrowserBundle(bundleID)
        ? bundleID
        : [NSString stringWithFormat:@"%@\t%@", bundleID, title];

    return @{
        @"captured_at": [ISOFormatter() stringFromDate:[NSDate date]],
        @"idle_seconds": @(idleSeconds),
        @"bundle_id": bundleID,
        @"app_name": appName,
        @"pid": @(pid),
        @"window_title": title,
        @"window_role": role,
        @"window_subrole": subrole,
        @"identity": identity
    };
}

@interface SegmentStore : NSObject
@property(nonatomic, strong) NSURL *outputURL;
- (instancetype)initWithOutputURL:(NSURL *)outputURL;
- (BOOL)appendSegment:(NSDictionary *)segment error:(NSError **)error;
@end

@implementation SegmentStore
- (instancetype)initWithOutputURL:(NSURL *)outputURL {
    self = [super init];
    if (self) {
        _outputURL = outputURL;
    }
    return self;
}

- (BOOL)appendSegment:(NSDictionary *)segment error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *directory = self.outputURL.URLByDeletingLastPathComponent;
    if (![fm createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:error]) {
        return NO;
    }
    if (![fm fileExistsAtPath:self.outputURL.path]) {
        if (![fm createFileAtPath:self.outputURL.path contents:nil attributes:nil]) {
            if (error) {
                *error = [NSError errorWithDomain:@"foreground-tracker" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Could not create output file."}];
            }
            return NO;
        }
    }

    NSData *data = [NSJSONSerialization dataWithJSONObject:segment options:NSJSONWritingSortedKeys error:error];
    if (!data) {
        return NO;
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:self.outputURL error:error];
    if (!handle) {
        return NO;
    }
    @try {
        [handle seekToEndOfFile];
        [handle writeData:data];
        [handle writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:@"foreground-tracker" code:2 userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"File write failed."}];
        }
        return NO;
    }
}
@end

@class ForegroundRecorder;
static void AXCallback(AXObserverRef observer, AXUIElementRef element, CFStringRef notification, void *refcon);

@interface ForegroundRecorder : NSObject
@property(nonatomic, strong) SegmentStore *store;
@property(nonatomic) NSTimeInterval pollInterval;
@property(nonatomic) NSTimeInterval idleThreshold;
@property(nonatomic) NSTimeInterval reconcileInterval;
@property(nonatomic, strong) NSMutableDictionary *current;
@property(nonatomic, strong) NSMutableArray *observerTokens;
@property(nonatomic, strong) NSMutableArray *timers;
@property(nonatomic, strong) NSMutableArray *signalSources;
@property(nonatomic) BOOL isLocked;
@property(nonatomic) BOOL isSleeping;
@property(nonatomic) AXObserverRef axObserver;
- (instancetype)initWithOutputURL:(NSURL *)outputURL poll:(NSTimeInterval)poll idle:(NSTimeInterval)idle reconcile:(NSTimeInterval)reconcile;
- (void)start;
- (void)sampleWithReason:(NSString *)reason forceCloseOnly:(BOOL)forceCloseOnly;
- (void)stopWithReason:(NSString *)reason;
@end

@implementation ForegroundRecorder
- (instancetype)initWithOutputURL:(NSURL *)outputURL poll:(NSTimeInterval)poll idle:(NSTimeInterval)idle reconcile:(NSTimeInterval)reconcile {
    self = [super init];
    if (self) {
        _store = [[SegmentStore alloc] initWithOutputURL:outputURL];
        _pollInterval = poll;
        _idleThreshold = idle;
        _reconcileInterval = reconcile;
        _observerTokens = [NSMutableArray array];
        _timers = [NSMutableArray array];
        _signalSources = [NSMutableArray array];
    }
    return self;
}

- (void)dealloc {
    if (_axObserver) {
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(_axObserver), kCFRunLoopDefaultMode);
        CFRelease(_axObserver);
    }
}

- (void)start {
    BOOL trusted = RequestAccessibilityIfNeeded();
    printf("foreground-tracker recording\n");
    printf("output: %s\n", self.store.outputURL.path.UTF8String);
    printf("poll: %.0fs, idle: %.0fs, reconcile: %.0fs\n", self.pollInterval, self.idleThreshold, self.reconcileInterval);
    if (!trusted) {
        printf("accessibility: not trusted yet; approve this binary in System Settings > Privacy & Security > Accessibility, then restart.\n");
    }

    [self installSignalHandlers];
    [self installWorkspaceObservers];
    [self bindAXObserverForFrontmostApp];
    [self sampleWithReason:@"startup" forceCloseOnly:NO];

    NSTimer *pollTimer = [NSTimer scheduledTimerWithTimeInterval:self.pollInterval repeats:YES block:^(NSTimer *timer) {
        [self sampleWithReason:@"poll" forceCloseOnly:NO];
    }];
    NSTimer *reconcileTimer = [NSTimer scheduledTimerWithTimeInterval:self.reconcileInterval repeats:YES block:^(NSTimer *timer) {
        [self bindAXObserverForFrontmostApp];
        [self sampleWithReason:@"reconcile" forceCloseOnly:NO];
    }];
    [self.timers addObject:pollTimer];
    [self.timers addObject:reconcileTimer];

    [[NSRunLoop currentRunLoop] run];
}

- (void)installSignalHandlers {
    signal(SIGINT, SIG_IGN);
    signal(SIGTERM, SIG_IGN);

    dispatch_source_t intSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGINT, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(intSource, ^{
        [self stopWithReason:@"sigint"];
    });
    dispatch_resume(intSource);
    [self.signalSources addObject:intSource];

    dispatch_source_t termSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(termSource, ^{
        [self stopWithReason:@"sigterm"];
    });
    dispatch_resume(termSource);
    [self.signalSources addObject:termSource];
}

- (void)installWorkspaceObservers {
    NSNotificationCenter *center = [NSWorkspace sharedWorkspace].notificationCenter;
    id token = [center addObserverForName:NSWorkspaceDidActivateApplicationNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        [self bindAXObserverForFrontmostApp];
        [self sampleWithReason:@"app-activated" forceCloseOnly:NO];
    }];
    [self.observerTokens addObject:token];

    token = [center addObserverForName:NSWorkspaceWillSleepNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        self.isSleeping = YES;
        [self closeCurrentAt:[NSDate date] reason:@"sleep"];
    }];
    [self.observerTokens addObject:token];

    token = [center addObserverForName:NSWorkspaceDidWakeNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        self.isSleeping = NO;
        [self sampleWithReason:@"wake" forceCloseOnly:NO];
    }];
    [self.observerTokens addObject:token];

    token = [center addObserverForName:NSWorkspaceScreensDidSleepNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        [self closeCurrentAt:[NSDate date] reason:@"screen-sleep"];
    }];
    [self.observerTokens addObject:token];

    NSDistributedNotificationCenter *distributed = [NSDistributedNotificationCenter defaultCenter];
    token = [distributed addObserverForName:@"com.apple.screenIsLocked" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        self.isLocked = YES;
        [self closeCurrentAt:[NSDate date] reason:@"screen-locked"];
    }];
    [self.observerTokens addObject:token];

    token = [distributed addObserverForName:@"com.apple.screenIsUnlocked" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        self.isLocked = NO;
        [self sampleWithReason:@"screen-unlocked" forceCloseOnly:NO];
    }];
    [self.observerTokens addObject:token];
}

- (void)bindAXObserverForFrontmostApp {
    if (self.axObserver) {
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(self.axObserver), kCFRunLoopDefaultMode);
        CFRelease(self.axObserver);
        self.axObserver = NULL;
    }

    NSRunningApplication *app = [NSWorkspace sharedWorkspace].frontmostApplication;
    if (!app) {
        return;
    }
    AXObserverRef observer = NULL;
    AXError error = AXObserverCreate(app.processIdentifier, AXCallback, &observer);
    if (error != kAXErrorSuccess || !observer) {
        return;
    }

    AXUIElementRef axApp = AXUIElementCreateApplication(app.processIdentifier);
    void *refcon = (__bridge void *)self;
    AXObserverAddNotification(observer, axApp, kAXFocusedWindowChangedNotification, refcon);
    AXObserverAddNotification(observer, axApp, kAXFocusedUIElementChangedNotification, refcon);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), kCFRunLoopDefaultMode);
    if (axApp) {
        CFRelease(axApp);
    }
    self.axObserver = observer;
}

- (void)sampleWithReason:(NSString *)reason forceCloseOnly:(BOOL)forceCloseOnly {
    NSDate *now = [NSDate date];
    double idle = IdleSeconds();
    NSDate *idleCutoff = [now dateByAddingTimeInterval:-MAX(0, idle - self.idleThreshold)];
    if (forceCloseOnly || self.isLocked || self.isSleeping || idle >= self.idleThreshold) {
        [self closeCurrentAt:(idle >= self.idleThreshold ? idleCutoff : now) reason:(idle >= self.idleThreshold ? @"idle" : reason)];
        return;
    }

    NSDictionary *snapshot = CurrentSnapshot(idle);
    if (!snapshot) {
        [self closeCurrentAt:now reason:@"no-frontmost-window"];
        return;
    }

    NSString *identity = snapshot[@"identity"];
    if (self.current && [self.current[@"identity"] isEqualToString:identity]) {
        self.current[@"last_seen_at"] = now;
        self.current[@"sample_count"] = @([self.current[@"sample_count"] integerValue] + 1);
        return;
    }

    [self closeCurrentAt:now reason:reason];
    self.current = [@{
        @"id": [NSUUID UUID].UUIDString,
        @"start_at": now,
        @"last_seen_at": now,
        @"sample_count": @1,
        @"snapshot": snapshot,
        @"identity": identity
    } mutableCopy];
    printf("start %s %s %s\n", ClockString(now).UTF8String, [snapshot[@"app_name"] UTF8String], DisplayTitle(snapshot[@"window_title"]).UTF8String);
}

- (void)closeCurrentAt:(NSDate *)proposedEnd reason:(NSString *)reason {
    if (!self.current) {
        return;
    }
    NSDictionary *open = [self.current copy];
    self.current = nil;

    NSDate *startAt = open[@"start_at"];
    NSDate *endAt = [proposedEnd compare:startAt] == NSOrderedAscending ? startAt : proposedEnd;
    double duration = [endAt timeIntervalSinceDate:startAt];
    if (duration <= 0.2) {
        return;
    }

    NSDictionary *snapshot = open[@"snapshot"];
    NSDictionary *segment = @{
        @"id": open[@"id"],
        @"start_at": [ISOFormatter() stringFromDate:startAt],
        @"end_at": [ISOFormatter() stringFromDate:endAt],
        @"duration_seconds": @(duration),
        @"bundle_id": snapshot[@"bundle_id"],
        @"app_name": snapshot[@"app_name"],
        @"pid": snapshot[@"pid"],
        @"window_title": snapshot[@"window_title"] ?: @"",
        @"window_role": snapshot[@"window_role"] ?: @"",
        @"window_subrole": snapshot[@"window_subrole"] ?: @"",
        @"sample_count": open[@"sample_count"],
        @"end_reason": reason
    };

    NSError *error = nil;
    if (![self.store appendSegment:segment error:&error]) {
        fprintf(stderr, "write failed: %s\n", error.localizedDescription.UTF8String);
        return;
    }
    printf("close %s-%s %s %s reason=%s\n",
           ClockString(startAt).UTF8String,
           ClockString(endAt).UTF8String,
           [snapshot[@"app_name"] UTF8String],
           DisplayTitle(snapshot[@"window_title"]).UTF8String,
           reason.UTF8String);
}

- (void)stopWithReason:(NSString *)reason {
    [self closeCurrentAt:[NSDate date] reason:reason];
    printf("stopped\n");
    exit(0);
}
@end

static void AXCallback(AXObserverRef observer, AXUIElementRef element, CFStringRef notification, void *refcon) {
    ForegroundRecorder *recorder = (__bridge ForegroundRecorder *)refcon;
    NSString *reason = (__bridge NSString *)notification;
    [recorder sampleWithReason:reason forceCloseOnly:NO];
}

static NSArray<NSMutableDictionary *> *ReadSegments(NSURL *inputURL, NSString *keyMode, NSError **error) {
    if (![[NSFileManager defaultManager] fileExistsAtPath:inputURL.path]) {
        return @[];
    }
    NSString *body = [NSString stringWithContentsOfURL:inputURL encoding:NSUTF8StringEncoding error:error];
    if (!body) {
        return nil;
    }

    NSMutableArray *segments = [NSMutableArray array];
    NSArray *lines = [body componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSUInteger lineNumber = 0;
    for (NSString *line in lines) {
        lineNumber += 1;
        if (line.length == 0) {
            continue;
        }
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSMutableDictionary *segment = [[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:error] mutableCopy];
        if (!segment) {
            return nil;
        }
        NSDate *start = [ISOFormatter() dateFromString:segment[@"start_at"]];
        NSDate *end = [ISOFormatter() dateFromString:segment[@"end_at"]];
        if (!start || !end) {
            if (error) {
                *error = [NSError errorWithDomain:@"foreground-tracker" code:3 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Invalid date at line %lu", (unsigned long)lineNumber]}];
            }
            return nil;
        }
        segment[@"__start"] = start;
        segment[@"__end"] = end;
        BOOL browser = IsBrowserBundle(segment[@"bundle_id"]);
        if (browser) {
            segment[@"window_title"] = @"";
        }
        segment[@"__key"] = [keyMode isEqualToString:@"window"] && !browser
            ? [NSString stringWithFormat:@"%@\t%@", segment[@"bundle_id"] ?: @"", segment[@"window_title"] ?: @""]
            : segment[@"bundle_id"] ?: @"";
        [segments addObject:segment];
    }

    [segments sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"__start"] compare:b[@"__start"]];
    }];
    return segments;
}

static void AddBlockIfEligible(NSMutableArray *blocks, NSMutableDictionary *block, double minDuration) {
    if (!block) {
        return;
    }
    NSDate *start = block[@"start"];
    NSDate *end = block[@"end"];
    double wall = [end timeIntervalSinceDate:start];
    double active = [block[@"active_seconds"] doubleValue];
    double ratio = wall > 0 ? MIN(1.0, active / wall) : 0;
    if (wall >= minDuration) {
        block[@"wall_seconds"] = @(wall);
        block[@"active_ratio"] = @(ratio);
        [blocks addObject:block];
    }
}

static NSArray *MergedBlocks(NSArray<NSMutableDictionary *> *segments, NSDictionary *options) {
    NSString *day = options[@"day"];
    NSString *bundle = options[@"bundle"];
    NSString *contains = [options[@"contains"] lowercaseString];
    double minDuration = [options[@"min_duration"] doubleValue];
    double minuteMinActive = [options[@"minute_min_active"] doubleValue];
    double minuteMinRatio = [options[@"minute_min_ratio"] doubleValue];
    NSInteger rollupWindowMinutes = [options[@"rollup_window_minutes"] integerValue];
    double rollupMinActive = [options[@"rollup_min_active"] doubleValue];

    NSMutableDictionary<NSNumber *, NSMutableDictionary<NSString *, NSMutableDictionary *> *> *buckets = [NSMutableDictionary dictionary];
    for (NSMutableDictionary *segment in segments) {
        if (bundle.length > 0 && ![segment[@"bundle_id"] isEqualToString:bundle]) {
            continue;
        }
        if (contains.length > 0) {
            NSString *haystack = [[NSString stringWithFormat:@"%@ %@ %@", segment[@"app_name"] ?: @"", segment[@"window_title"] ?: @"", segment[@"bundle_id"] ?: @""] lowercaseString];
            if ([haystack rangeOfString:contains].location == NSNotFound) {
                continue;
            }
        }
        if (day.length > 0 && ![LocalDayString(segment[@"__start"]) isEqualToString:day]) {
            continue;
        }

        double cursor = [segment[@"__start"] timeIntervalSince1970];
        double end = [segment[@"__end"] timeIntervalSince1970];
        while (cursor < end) {
            double minuteStart = floor(cursor / 60.0) * 60.0;
            double minuteEnd = minuteStart + 60.0;
            double sliceEnd = MIN(end, minuteEnd);
            double seconds = sliceEnd - cursor;
            NSNumber *bucketKey = @(minuteStart);
            NSString *appKey = segment[@"__key"];

            if (!buckets[bucketKey]) {
                buckets[bucketKey] = [NSMutableDictionary dictionary];
            }
            if (!buckets[bucketKey][appKey]) {
                buckets[bucketKey][appKey] = [@{
                    @"key": appKey,
                    @"active_seconds": @0.0,
                    @"bundle_id": segment[@"bundle_id"] ?: @"",
                    @"app_name": segment[@"app_name"] ?: @"",
                    @"window_title": segment[@"window_title"] ?: @"",
                    @"source_ids": [NSMutableSet set]
                } mutableCopy];
            }
            NSMutableDictionary *bucketApp = buckets[bucketKey][appKey];
            bucketApp[@"active_seconds"] = @([bucketApp[@"active_seconds"] doubleValue] + seconds);
            NSMutableSet *sourceIDs = bucketApp[@"source_ids"];
            if (segment[@"id"]) {
                [sourceIDs addObject:segment[@"id"]];
            }
            cursor = sliceEnd;
        }
    }

    NSMutableDictionary<NSNumber *, NSMutableDictionary *> *assignmentsByMinute = [NSMutableDictionary dictionary];
    NSArray *minuteKeys = [buckets.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSNumber *minuteKey in minuteKeys) {
        NSDictionary<NSString *, NSMutableDictionary *> *bucket = buckets[minuteKey];
        double observedSeconds = 0;
        NSMutableDictionary *dominant = nil;
        for (NSMutableDictionary *candidate in bucket.allValues) {
            double seconds = [candidate[@"active_seconds"] doubleValue];
            observedSeconds += seconds;
            if (!dominant || seconds > [dominant[@"active_seconds"] doubleValue]) {
                dominant = candidate;
            }
        }
        if (!dominant || observedSeconds <= 0) {
            continue;
        }

        double active = [dominant[@"active_seconds"] doubleValue];
        double ratio = active / observedSeconds;
        if (active < minuteMinActive && ratio < minuteMinRatio) {
            continue;
        }

        NSMutableSet *sourceIDs = dominant[@"source_ids"];
        assignmentsByMinute[minuteKey] = [@{
            @"start": [NSDate dateWithTimeIntervalSince1970:minuteKey.doubleValue],
            @"end": [NSDate dateWithTimeIntervalSince1970:minuteKey.doubleValue + 60.0],
            @"active_seconds": @(active),
            @"observed_seconds": @(observedSeconds),
            @"key": dominant[@"key"],
            @"bundle_id": dominant[@"bundle_id"],
            @"app_name": dominant[@"app_name"],
            @"window_title": dominant[@"window_title"],
            @"source_count": @(sourceIDs.count),
            @"assignment": @"minute",
            @"score": @(active)
        } mutableCopy];
    }

    if (rollupWindowMinutes > 1 && rollupMinActive > 0 && minuteKeys.count > 0) {
        NSMutableDictionary<NSNumber *, NSMutableDictionary *> *claimsByMinute = [NSMutableDictionary dictionary];
        double firstMinute = [minuteKeys.firstObject doubleValue];
        double lastMinute = [minuteKeys.lastObject doubleValue];
        double windowSeconds = rollupWindowMinutes * 60.0;

        for (double windowStart = firstMinute; windowStart <= lastMinute; windowStart += 60.0) {
            NSMutableDictionary<NSString *, NSMutableDictionary *> *windowApps = [NSMutableDictionary dictionary];
            for (double minuteStart = windowStart; minuteStart < windowStart + windowSeconds; minuteStart += 60.0) {
                NSDictionary<NSString *, NSMutableDictionary *> *bucket = buckets[@(minuteStart)];
                for (NSMutableDictionary *candidate in bucket.allValues) {
                    NSString *key = candidate[@"key"];
                    if (!windowApps[key]) {
                        windowApps[key] = [@{
                            @"key": key,
                            @"active_seconds": @0.0,
                            @"bundle_id": candidate[@"bundle_id"],
                            @"app_name": candidate[@"app_name"],
                            @"window_title": candidate[@"window_title"],
                            @"source_ids": [NSMutableSet set]
                        } mutableCopy];
                    }
                    NSMutableDictionary *windowApp = windowApps[key];
                    windowApp[@"active_seconds"] = @([windowApp[@"active_seconds"] doubleValue] + [candidate[@"active_seconds"] doubleValue]);
                    NSMutableSet *windowSourceIDs = windowApp[@"source_ids"];
                    [windowSourceIDs unionSet:candidate[@"source_ids"]];
                }
            }

            NSMutableDictionary *dominant = nil;
            for (NSMutableDictionary *candidate in windowApps.allValues) {
                if (!dominant || [candidate[@"active_seconds"] doubleValue] > [dominant[@"active_seconds"] doubleValue]) {
                    dominant = candidate;
                }
            }
            if (!dominant || [dominant[@"active_seconds"] doubleValue] < rollupMinActive) {
                continue;
            }

            NSString *dominantKey = dominant[@"key"];
            double rollupScore = [dominant[@"active_seconds"] doubleValue];
            for (double minuteStart = windowStart; minuteStart < windowStart + windowSeconds; minuteStart += 60.0) {
                NSNumber *minuteKey = @(minuteStart);
                NSDictionary<NSString *, NSMutableDictionary *> *bucket = buckets[minuteKey];
                NSMutableDictionary *actual = bucket[dominantKey];
                double actualActive = [actual[@"active_seconds"] doubleValue];
                double observedSeconds = 0;
                for (NSMutableDictionary *candidate in bucket.allValues) {
                    observedSeconds += [candidate[@"active_seconds"] doubleValue];
                }
                NSMutableSet *sourceIDs = actual[@"source_ids"] ?: [NSMutableSet set];
                NSMutableDictionary *claim = [@{
                    @"start": [NSDate dateWithTimeIntervalSince1970:minuteStart],
                    @"end": [NSDate dateWithTimeIntervalSince1970:minuteStart + 60.0],
                    @"active_seconds": @(actualActive),
                    @"observed_seconds": @(observedSeconds),
                    @"key": dominant[@"key"],
                    @"bundle_id": dominant[@"bundle_id"],
                    @"app_name": dominant[@"app_name"],
                    @"window_title": dominant[@"window_title"],
                    @"source_count": @(sourceIDs.count),
                    @"assignment": @"rollup",
                    @"score": @(rollupScore)
                } mutableCopy];
                NSMutableDictionary *previous = claimsByMinute[minuteKey];
                if (!previous || [claim[@"score"] doubleValue] > [previous[@"score"] doubleValue]) {
                    claimsByMinute[minuteKey] = claim;
                }
            }
        }

        for (NSNumber *minuteKey in claimsByMinute) {
            NSMutableDictionary *claim = claimsByMinute[minuteKey];
            NSMutableDictionary *current = assignmentsByMinute[minuteKey];
            if (!current || [claim[@"score"] doubleValue] >= [current[@"score"] doubleValue]) {
                assignmentsByMinute[minuteKey] = claim;
            }
        }
    }

    NSMutableArray *blocks = [NSMutableArray array];
    NSMutableDictionary *current = nil;
    NSArray *acceptedMinuteKeys = [assignmentsByMinute.allKeys sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray *acceptedMinutes = [NSMutableArray array];
    for (NSNumber *minuteKey in acceptedMinuteKeys) {
        [acceptedMinutes addObject:assignmentsByMinute[minuteKey]];
    }
    for (NSDictionary *minute in acceptedMinutes) {
        if (current &&
            [current[@"key"] isEqualToString:minute[@"key"]] &&
            fabs([minute[@"start"] timeIntervalSinceDate:current[@"end"]]) < 0.001) {
            current[@"end"] = minute[@"end"];
            current[@"active_seconds"] = @([current[@"active_seconds"] doubleValue] + [minute[@"active_seconds"] doubleValue]);
            current[@"observed_seconds"] = @([current[@"observed_seconds"] doubleValue] + [minute[@"observed_seconds"] doubleValue]);
            current[@"minute_count"] = @([current[@"minute_count"] integerValue] + 1);
            current[@"source_count"] = @([current[@"source_count"] integerValue] + [minute[@"source_count"] integerValue]);
            if (![current[@"assignment"] isEqualToString:minute[@"assignment"]]) {
                current[@"assignment"] = @"mixed";
            }
        } else {
            AddBlockIfEligible(blocks, current, minDuration);
            current = [@{
                @"start": minute[@"start"],
                @"end": minute[@"end"],
                @"active_seconds": minute[@"active_seconds"],
                @"observed_seconds": minute[@"observed_seconds"],
                @"key": minute[@"key"],
                @"bundle_id": minute[@"bundle_id"],
                @"app_name": minute[@"app_name"],
                @"window_title": minute[@"window_title"],
                @"minute_count": @1,
                @"source_count": minute[@"source_count"],
                @"assignment": minute[@"assignment"]
            } mutableCopy];
        }
    }
    AddBlockIfEligible(blocks, current, minDuration);

    [blocks sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"start"] compare:b[@"start"]];
    }];
    return blocks;
}

static NSString *CalendarTitle(NSDictionary *block) {
    NSString *title = block[@"window_title"] ?: @"";
    NSString *app = block[@"app_name"] ?: @"";
    if (IsBrowserBundle(block[@"bundle_id"])) {
        return app;
    }
    return title.length == 0 ? app : [NSString stringWithFormat:@"%@ - %@", app, title];
}

static void PrintReport(NSArray *blocks, BOOL json) {
    if (json) {
        NSMutableArray *payload = [NSMutableArray array];
        for (NSDictionary *block in blocks) {
            [payload addObject:@{
                @"start_at": [ISOFormatter() stringFromDate:block[@"start"]],
                @"end_at": [ISOFormatter() stringFromDate:block[@"end"]],
                @"wall_seconds": @((NSInteger)llround([block[@"wall_seconds"] doubleValue])),
                @"active_seconds": @((NSInteger)llround([block[@"active_seconds"] doubleValue])),
                @"active_ratio": block[@"active_ratio"],
                @"bundle_id": block[@"bundle_id"],
                @"title": CalendarTitle(block),
                @"minute_count": block[@"minute_count"],
                @"source_count": block[@"source_count"],
                @"assignment": block[@"assignment"]
            }];
        }
        NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
        printf("%s\n", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
        return;
    }

    if (blocks.count == 0) {
        printf("No merged blocks matched.\n");
        return;
    }

    printf("time                 wall   active ratio min mode   title\n");
    printf("-------------------  -----  ------ ----- --- ------ -----\n");
    for (NSDictionary *block in blocks) {
        NSString *range = [NSString stringWithFormat:@"%@-%@", ClockString(block[@"start"]), ClockString(block[@"end"])];
        NSString *wall = ShortDuration([block[@"wall_seconds"] doubleValue]);
        NSString *active = ShortDuration([block[@"active_seconds"] doubleValue]);
        NSString *ratio = [NSString stringWithFormat:@"%.0f%%", [block[@"active_ratio"] doubleValue] * 100.0];
        NSString *minutes = [NSString stringWithFormat:@"%ld", (long)[block[@"minute_count"] integerValue]];
        NSString *assignment = block[@"assignment"] ?: @"";
        printf("%s  %s  %s %s %s %s %s\n",
               Padded(range, 19).UTF8String,
               Padded(wall, 5).UTF8String,
               Padded(active, 6).UTF8String,
               Padded(ratio, 5).UTF8String,
               Padded(minutes, 3).UTF8String,
               Padded(assignment, 6).UTF8String,
               CalendarTitle(block).UTF8String);
    }
}

static void PrintHelp(void) {
    printf(
        "foreground-tracker\n\n"
        "Commands:\n"
        "  sample\n"
        "    Print the current frontmost app/window once.\n\n"
        "  record [--output path] [--poll 5] [--idle 120] [--reconcile 60]\n"
        "    Record active frontmost-window segments as JSONL under Gotowork app data by default.\n\n"
        "  report [--input path] [--day yyyy-mm-dd] [--min-duration 180]\n"
        "         [--minute-min-active 40] [--minute-min-ratio 0.60]\n"
        "         [--rollup-window 3] [--rollup-min-active 120] [--key app|window]\n"
        "         [--bundle com.example.App] [--contains text] [--json]\n"
        "    Preview calendar-like blocks by assigning each minute to its dominant app/window,\n"
        "    reading the selected day's Gotowork app data by default,\n"
        "    smoothing with a 3-minute raw-data window when one app exceeds 2 minutes, then merging.\n"
        "    Browser titles/URLs are ignored.\n"
    );
}

static int Run(NSArray<NSString *> *args) {
    if (args.count == 0) {
        PrintHelp();
        return 0;
    }

    NSString *command = args[0];
    NSArray *rest = args.count > 1 ? [args subarrayWithRange:NSMakeRange(1, args.count - 1)] : @[];

    if ([command isEqualToString:@"sample"]) {
        BOOL trusted = RequestAccessibilityIfNeeded();
        double idle = IdleSeconds();
        NSDictionary *snapshot = CurrentSnapshot(idle);
        if (!snapshot) {
            fprintf(stderr, "No frontmost app/window could be read.\n");
            return 1;
        }
        printf("accessibility_trusted=%s\n", trusted ? "true" : "false");
        printf("idle_seconds=%.1f\n", idle);
        printf("bundle_id=%s\n", [snapshot[@"bundle_id"] UTF8String]);
        printf("app_name=%s\n", [snapshot[@"app_name"] UTF8String]);
        printf("pid=%d\n", [snapshot[@"pid"] intValue]);
        printf("window_title=%s\n", DisplayTitle(snapshot[@"window_title"]).UTF8String);
        printf("window_role=%s\n", [snapshot[@"window_role"] UTF8String]);
        printf("window_subrole=%s\n", [snapshot[@"window_subrole"] UTF8String]);
        return 0;
    }

    if ([command isEqualToString:@"record"]) {
        NSString *output = ExpandPath(ArgValue(rest, @"--output", GotoworkRawPathForDay(LocalDayString([NSDate date]))));
        ForegroundRecorder *recorder = [[ForegroundRecorder alloc] initWithOutputURL:[NSURL fileURLWithPath:output]
                                                                                poll:ArgDouble(rest, @"--poll", 5)
                                                                                idle:ArgDouble(rest, @"--idle", 120)
                                                                           reconcile:ArgDouble(rest, @"--reconcile", 60)];
        [recorder start];
        return 0;
    }

    if ([command isEqualToString:@"report"]) {
        NSString *key = ArgValue(rest, @"--key", @"app");
        NSString *explicitDay = ArgValue(rest, @"--day", @"");
        NSString *day = explicitDay.length > 0 ? explicitDay : LocalDayString([NSDate date]);
        NSString *input = ExpandPath(ArgValue(rest, @"--input", GotoworkRawPathForDay(day)));
        NSError *error = nil;
        NSArray *segments = ReadSegments([NSURL fileURLWithPath:input], key, &error);
        if (!segments) {
            fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
            return 1;
        }
        NSArray *blocks = MergedBlocks(segments, @{
            @"day": day,
            @"bundle": ArgValue(rest, @"--bundle", @""),
            @"contains": ArgValue(rest, @"--contains", @""),
            @"min_duration": @(ArgDouble(rest, @"--min-duration", ArgDouble(rest, @"--min-active", 180))),
            @"minute_min_active": @(ArgDouble(rest, @"--minute-min-active", 40)),
            @"minute_min_ratio": @(ArgDouble(rest, @"--minute-min-ratio", ArgDouble(rest, @"--min-ratio", 0.60))),
            @"rollup_window_minutes": @(ArgDouble(rest, @"--rollup-window", 3)),
            @"rollup_min_active": @(ArgDouble(rest, @"--rollup-min-active", 120))
        });
        PrintReport(blocks, ArgBool(rest, @"--json"));
        return 0;
    }

    if ([command isEqualToString:@"help"] || [command isEqualToString:@"--help"] || [command isEqualToString:@"-h"]) {
        PrintHelp();
        return 0;
    }

    fprintf(stderr, "Unknown command: %s\n", command.UTF8String);
    return 1;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSMutableArray<NSString *> *args = [NSMutableArray array];
        for (int i = 1; i < argc; i++) {
            [args addObject:@(argv[i])];
        }
        return Run(args);
    }
}
