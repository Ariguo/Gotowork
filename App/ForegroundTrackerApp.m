#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <EventKit/EventKit.h>
#import <Foundation/Foundation.h>
#import <math.h>

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

static NSString *ClockString(NSDate *date) {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"HH:mm:ss";
    return [formatter stringFromDate:date];
}

static NSString *DayString(NSDate *date) {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd";
    return [formatter stringFromDate:date];
}

static NSString *DisplayTitle(NSString *title) {
    return title.length == 0 ? @"(untitled)" : title;
}

static NSString * const TrackerCalendarTitle = @"前台记录";
static NSString * const GotoworkBundleIdentifier = @"com.ariguo.Gotowork";
static NSString * const ResidentMeetingBundleIdentifier = @"com.electron.lark.iron";
static NSString * const ResidentMeetingDisplayName = @"飞书会议";
static NSString * const GeneratedEventMarkerPrefix = @"ForegroundTrackerGenerated";
static NSString * const GeneratedBlockMarkerPrefix = @"ForegroundTrackerBlock";
static NSString * const SettingIdleSecondsKey = @"idle_seconds";
static NSString * const SettingShortInterruptionSecondsKey = @"short_interruption_seconds";
static NSString * const SettingRawMergeInterruptionSecondsKey = @"raw_merge_interruption_seconds";
static NSString * const SettingCalendarWindowMinutesKey = @"calendar_window_minutes";
static NSString * const SettingCalendarMinBlockMinutesKey = @"calendar_min_block_minutes";
static NSString * const SettingAutoCalendarWriteHourKey = @"auto_calendar_write_hour";
static NSString * const AutoCalendarLastRunDayKey = @"auto_calendar_last_run_day";
static NSString * const TargetCalendarIdentifierKey = @"target_calendar_identifier";
static NSString * const IgnoredCalendarBlockKeysKey = @"ignored_calendar_block_keys";
static NSString * const IgnoredAppKeysKey = @"ignored_app_keys";
static NSString * const ProjectLabelsByBlockKeyKey = @"project_labels_by_block_key";
static NSString * const BlockTitlesByBlockKeyKey = @"block_titles_by_block_key";
static NSString * const AppWriteMappingsByKeyKey = @"app_write_mappings_by_key";
static NSString * const AppColorOverridesByKeyKey = @"app_color_overrides_by_key";
static NSString * const ManualCalendarBlocksKey = @"manual_calendar_blocks";

static NSTimeInterval MinimumRecordedSegmentSeconds(void) {
    return 1.0;
}

static NSSet<NSString *> *TemporaryIgnoredAppKeys = nil;

static void RegisterDefaultSettings(void) {
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        SettingIdleSecondsKey: @120.0,
        SettingShortInterruptionSecondsKey: @30.0,
        SettingRawMergeInterruptionSecondsKey: @2.0,
        SettingCalendarWindowMinutesKey: @3.0,
        SettingCalendarMinBlockMinutesKey: @5.0,
        SettingAutoCalendarWriteHourKey: @-1.0
    }];
}

static double SettingDouble(NSString *key, double fallback) {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    return value ? [[NSUserDefaults standardUserDefaults] doubleForKey:key] : fallback;
}

static NSTimeInterval IdleThresholdSetting(void) {
    return SettingDouble(SettingIdleSecondsKey, 120.0);
}

static NSTimeInterval ShortInterruptionSetting(void) {
    return SettingDouble(SettingShortInterruptionSecondsKey, 30.0);
}

static NSTimeInterval RawMergeInterruptionSetting(void) {
    return SettingDouble(SettingRawMergeInterruptionSecondsKey, 2.0);
}

static NSTimeInterval CalendarWindowSecondsSetting(void) {
    return SettingDouble(SettingCalendarWindowMinutesKey, 3.0) * 60.0;
}

static NSTimeInterval CalendarMinBlockSecondsSetting(void) {
    return SettingDouble(SettingCalendarMinBlockMinutesKey, 5.0) * 60.0;
}

static double AutoCalendarWriteHourSetting(void) {
    return SettingDouble(SettingAutoCalendarWriteHourKey, -1.0);
}

static BOOL AutoCalendarWriteEnabled(void) {
    return AutoCalendarWriteHourSetting() >= 0;
}

static NSString *AutoCalendarWriteSummary(void) {
    double hour = AutoCalendarWriteHourSetting();
    return hour >= 0 ? [NSString stringWithFormat:@"每天 %.0f:00 后自动写入", hour] : @"自动写入已关闭";
}

static NSString *CalendarRuleSummary(void) {
    return [NSString stringWithFormat:@"规则：<=%.0fs切换忽略；1分钟>=40s 或 %.0f分钟>=%.0fs/65%%，<=%.0fs短打断吸收，最终>=%.0fm",
            MinimumRecordedSegmentSeconds(),
            SettingDouble(SettingCalendarWindowMinutesKey, 3.0),
            CalendarWindowSecondsSetting() * (2.0 / 3.0),
            ShortInterruptionSetting(),
            SettingDouble(SettingCalendarMinBlockMinutesKey, 5.0)];
}

static NSString *CalendarRuleDisplaySummary(void) {
    return [NSString stringWithFormat:@"%.0f 秒内切换忽略；1 分钟命中 40s，或 %.0f 分钟命中 %.0f 分钟。",
            MinimumRecordedSegmentSeconds(),
            SettingDouble(SettingCalendarWindowMinutesKey, 3.0),
            CalendarWindowSecondsSetting() * (2.0 / 3.0) / 60.0];
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
    NSString *executablePath = app.executableURL.path ?: @"";
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
        @"executable_path": executablePath,
        @"pid": @(pid),
        @"window_title": title,
        @"window_role": role,
        @"window_subrole": subrole,
        @"identity": identity
    };
}

static NSDictionary *ResidentMeetingSnapshot(void) {
    for (NSRunningApplication *app in [NSWorkspace sharedWorkspace].runningApplications) {
        if (app.terminated || ![app.bundleIdentifier isEqualToString:ResidentMeetingBundleIdentifier]) {
            continue;
        }
        pid_t pid = app.processIdentifier;
        return @{
            @"captured_at": [ISOFormatter() stringFromDate:[NSDate date]],
            @"bundle_id": ResidentMeetingBundleIdentifier,
            @"app_name": ResidentMeetingDisplayName,
            @"executable_path": app.executableURL.path ?: @"",
            @"pid": @(pid),
            @"window_title": @"",
            @"window_role": @"",
            @"window_subrole": @"",
            @"identity": ResidentMeetingBundleIdentifier
        };
    }
    return nil;
}

static NSDate *RawSegmentDate(NSDictionary *segment, NSString *key) {
    id value = segment[key];
    if ([value isKindOfClass:NSDate.class]) {
        return value;
    }
    if (![value isKindOfClass:NSString.class]) {
        return nil;
    }
    return [ISOFormatter() dateFromString:value];
}

static double RawSegmentDuration(NSDictionary *segment) {
    double duration = [segment[@"duration_seconds"] doubleValue];
    if (duration > 0) {
        return duration;
    }
    NSDate *start = RawSegmentDate(segment, @"start_at");
    NSDate *end = RawSegmentDate(segment, @"end_at");
    return start && end ? [end timeIntervalSinceDate:start] : 0;
}

static NSString *RawSegmentMergeIdentity(NSDictionary *segment) {
    NSString *bundleID = segment[@"bundle_id"] ?: @"";
    NSString *appName = segment[@"app_name"] ?: @"";
    NSString *key = bundleID.length > 0 ? bundleID : appName;
    if (key.length == 0) {
        return @"";
    }
    if (IsBrowserBundle(bundleID)) {
        return key;
    }
    return [NSString stringWithFormat:@"%@\t%@", key, segment[@"window_title"] ?: @""];
}

static BOOL RawSegmentEndReasonIsBoundary(NSString *reason) {
    if (reason.length == 0) {
        return NO;
    }
    return [reason isEqualToString:@"idle"] ||
           [reason containsString:@"sleep"] ||
           [reason containsString:@"locked"] ||
           [reason isEqualToString:@"no-frontmost-window"] ||
           [reason isEqualToString:@"app-terminate"] ||
           [reason isEqualToString:@"quit"] ||
           [reason isEqualToString:@"dealloc"];
}

static BOOL RawSegmentsTouch(NSDictionary *left, NSDictionary *right) {
    NSDate *leftEnd = RawSegmentDate(left, @"end_at");
    NSDate *rightStart = RawSegmentDate(right, @"start_at");
    if (!leftEnd || !rightStart) {
        return NO;
    }
    double gap = [rightStart timeIntervalSinceDate:leftEnd];
    return gap >= -0.5 && gap <= 5.0;
}

static BOOL CanAbsorbRawInterruption(NSDictionary *previous,
                                     NSDictionary *interruption,
                                     NSDictionary *next) {
    if ([interruption[@"resident"] boolValue] || [previous[@"resident"] boolValue] || [next[@"resident"] boolValue]) {
        return NO;
    }
    NSString *previousIdentity = RawSegmentMergeIdentity(previous);
    NSString *nextIdentity = RawSegmentMergeIdentity(next);
    if (previousIdentity.length == 0 || ![previousIdentity isEqualToString:nextIdentity]) {
        return NO;
    }
    if (RawSegmentEndReasonIsBoundary(interruption[@"end_reason"])) {
        return NO;
    }
    double duration = RawSegmentDuration(interruption);
    if (duration <= 0 || duration > RawMergeInterruptionSetting()) {
        return NO;
    }
    return RawSegmentsTouch(previous, interruption) && RawSegmentsTouch(interruption, next);
}

static void AbsorbRawInterruptionIntoPrevious(NSMutableDictionary *previous,
                                              NSDictionary *interruption,
                                              NSDictionary *next) {
    NSDate *start = RawSegmentDate(previous, @"start_at");
    NSDate *end = RawSegmentDate(next, @"end_at");
    if (!start || !end) {
        return;
    }
    previous[@"end_at"] = next[@"end_at"];
    previous[@"duration_seconds"] = @([end timeIntervalSinceDate:start]);
    previous[@"sample_count"] = @([previous[@"sample_count"] integerValue] + [next[@"sample_count"] integerValue]);
    previous[@"end_reason"] = next[@"end_reason"] ?: previous[@"end_reason"] ?: @"merged-short-interruption";
    previous[@"absorbed_short_interruption_count"] = @([previous[@"absorbed_short_interruption_count"] integerValue] +
                                                       [interruption[@"absorbed_short_interruption_count"] integerValue] +
                                                       [next[@"absorbed_short_interruption_count"] integerValue] + 1);
    previous[@"absorbed_short_interruption_seconds"] = @([previous[@"absorbed_short_interruption_seconds"] doubleValue] +
                                                         [interruption[@"absorbed_short_interruption_seconds"] doubleValue] +
                                                         [next[@"absorbed_short_interruption_seconds"] doubleValue] +
                                                         RawSegmentDuration(interruption));
}

@interface SegmentStore : NSObject
@property(nonatomic, strong) NSURL *dataDirectory;
- (instancetype)initWithDataDirectory:(NSURL *)dataDirectory;
- (NSURL *)todayRawURL;
- (NSURL *)rawURLForDate:(NSDate *)date;
- (NSURL *)residentRawURLForDate:(NSDate *)date;
- (BOOL)compactRawURLForDate:(NSDate *)date error:(NSError **)error;
- (BOOL)appendSegment:(NSDictionary *)segment startDate:(NSDate *)startDate error:(NSError **)error;
- (BOOL)appendResidentSegment:(NSDictionary *)segment startDate:(NSDate *)startDate error:(NSError **)error;
@end

@implementation SegmentStore
- (instancetype)initWithDataDirectory:(NSURL *)dataDirectory {
    self = [super init];
    if (self) {
        _dataDirectory = dataDirectory;
    }
    return self;
}

- (NSURL *)todayRawURL {
    NSString *name = [NSString stringWithFormat:@"raw_%@.jsonl", DayString([NSDate date])];
    return [self.dataDirectory URLByAppendingPathComponent:name];
}

- (NSURL *)rawURLForDate:(NSDate *)date {
    NSString *name = [NSString stringWithFormat:@"raw_%@.jsonl", DayString(date)];
    return [self.dataDirectory URLByAppendingPathComponent:name];
}

- (NSURL *)residentRawURLForDate:(NSDate *)date {
    NSString *name = [NSString stringWithFormat:@"resident_raw_%@.jsonl", DayString(date)];
    return [self.dataDirectory URLByAppendingPathComponent:name];
}

- (BOOL)appendSegment:(NSDictionary *)segment toURL:(NSURL *)outputURL error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm createDirectoryAtURL:self.dataDirectory withIntermediateDirectories:YES attributes:nil error:error]) {
        return NO;
    }

    if (![fm fileExistsAtPath:outputURL.path]) {
        if (![fm createFileAtPath:outputURL.path contents:nil attributes:nil]) {
            if (error) {
                *error = [NSError errorWithDomain:@"ForegroundTracker" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Could not create raw data file."}];
            }
            return NO;
        }
    }

    NSData *data = [NSJSONSerialization dataWithJSONObject:segment options:NSJSONWritingSortedKeys error:error];
    if (!data) {
        return NO;
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:outputURL error:error];
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
            *error = [NSError errorWithDomain:@"ForegroundTracker" code:2 userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"File write failed."}];
        }
        return NO;
    }
}

- (BOOL)compactRawURL:(NSURL *)rawURL error:(NSError **)error {
    if (![[NSFileManager defaultManager] fileExistsAtPath:rawURL.path]) {
        return YES;
    }
    NSString *body = [NSString stringWithContentsOfURL:rawURL encoding:NSUTF8StringEncoding error:error];
    if (!body) {
        return NO;
    }
    if (body.length == 0) {
        return YES;
    }

    NSMutableArray<NSMutableDictionary *> *compacted = [NSMutableArray array];
    BOOL changed = NO;
    for (NSString *line in [body componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        if (line.length == 0) {
            continue;
        }
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSMutableDictionary *segment = [[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:error] mutableCopy];
        if (![segment isKindOfClass:NSDictionary.class]) {
            return NO;
        }
        [compacted addObject:segment];

        while (compacted.count >= 3) {
            NSUInteger count = compacted.count;
            NSMutableDictionary *previous = compacted[count - 3];
            NSDictionary *interruption = compacted[count - 2];
            NSDictionary *next = compacted[count - 1];
            if (!CanAbsorbRawInterruption(previous, interruption, next)) {
                break;
            }
            AbsorbRawInterruptionIntoPrevious(previous, interruption, next);
            [compacted removeLastObject];
            [compacted removeLastObject];
            changed = YES;
        }
    }

    if (!changed) {
        return YES;
    }

    NSMutableString *output = [NSMutableString string];
    for (NSDictionary *segment in compacted) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:segment options:NSJSONWritingSortedKeys error:error];
        if (!data) {
            return NO;
        }
        NSString *line = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (line.length == 0) {
            continue;
        }
        [output appendString:line];
        [output appendString:@"\n"];
    }
    return [output writeToURL:rawURL atomically:YES encoding:NSUTF8StringEncoding error:error];
}

- (BOOL)compactRawURLForDate:(NSDate *)date error:(NSError **)error {
    return [self compactRawURL:[self rawURLForDate:date] error:error];
}

- (BOOL)appendSegment:(NSDictionary *)segment startDate:(NSDate *)startDate error:(NSError **)error {
    if (![self appendSegment:segment toURL:[self rawURLForDate:startDate] error:error]) {
        return NO;
    }
    return [self compactRawURLForDate:startDate error:error];
}

- (BOOL)appendResidentSegment:(NSDictionary *)segment startDate:(NSDate *)startDate error:(NSError **)error {
    return [self appendSegment:segment toURL:[self residentRawURLForDate:startDate] error:error];
}
@end

@class TrackerController;
static void AXCallback(AXObserverRef observer, AXUIElementRef element, CFStringRef notification, void *refcon);

@interface TrackerController : NSObject
@property(nonatomic, strong) SegmentStore *store;
@property(nonatomic, strong) NSMutableDictionary *current;
@property(nonatomic, strong) NSMutableDictionary *residentMeeting;
@property(nonatomic, strong) NSMutableDictionary *pendingTransition;
@property(nonatomic, strong) NSTimer *pendingTransitionTimer;
@property(nonatomic, strong) NSMutableArray *timers;
@property(nonatomic, strong) NSMutableArray *observerTokens;
@property(nonatomic) AXObserverRef axObserver;
@property(nonatomic) BOOL isRecording;
@property(nonatomic) BOOL isLocked;
@property(nonatomic) BOOL isSleeping;
@property(nonatomic) NSTimeInterval pollInterval;
@property(nonatomic) NSTimeInterval idleThreshold;
@property(nonatomic) NSTimeInterval reconcileInterval;
@property(nonatomic, copy) void (^statusChanged)(NSString *);
- (instancetype)initWithStore:(SegmentStore *)store;
- (void)start;
- (void)stopWithReason:(NSString *)reason;
- (void)checkpointWithReason:(NSString *)reason;
- (NSDictionary *)currentDashboardSegment;
- (NSDictionary *)currentResidentMeetingSegment;
- (void)sampleResidentMeetingAt:(NSDate *)now reason:(NSString *)reason;
- (void)closeResidentMeetingAt:(NSDate *)proposedEnd reason:(NSString *)reason;
@end

@implementation TrackerController
- (instancetype)initWithStore:(SegmentStore *)store {
    self = [super init];
    if (self) {
        _store = store;
        _timers = [NSMutableArray array];
        _observerTokens = [NSMutableArray array];
        _pollInterval = 5;
        _idleThreshold = IdleThresholdSetting();
        _reconcileInterval = 60;
    }
    return self;
}

- (void)dealloc {
    [self stopWithReason:@"dealloc"];
}

- (void)start {
    if (self.isRecording) {
        return;
    }
    self.isRecording = YES;
    RequestAccessibilityIfNeeded();
    [self installWorkspaceObservers];
    [self bindAXObserverForFrontmostApp];
    [self sampleWithReason:@"startup"];

    NSTimer *pollTimer = [NSTimer scheduledTimerWithTimeInterval:self.pollInterval repeats:YES block:^(NSTimer *timer) {
        [self sampleWithReason:@"poll"];
    }];
    NSTimer *reconcileTimer = [NSTimer scheduledTimerWithTimeInterval:self.reconcileInterval repeats:YES block:^(NSTimer *timer) {
        [self bindAXObserverForFrontmostApp];
        [self sampleWithReason:@"reconcile"];
    }];
    [self.timers addObject:pollTimer];
    [self.timers addObject:reconcileTimer];
    [self emitStatus:@"Recording"];
}

- (void)stopWithReason:(NSString *)reason {
    if (!self.isRecording && !self.current && !self.residentMeeting) {
        return;
    }
    [self clearPendingTransition];
    [self closeCurrentAt:[NSDate date] reason:reason];
    [self closeResidentMeetingAt:[NSDate date] reason:reason];
    for (NSTimer *timer in self.timers) {
        [timer invalidate];
    }
    [self.timers removeAllObjects];
    NSNotificationCenter *workspaceCenter = [NSWorkspace sharedWorkspace].notificationCenter;
    NSDistributedNotificationCenter *distributedCenter = [NSDistributedNotificationCenter defaultCenter];
    for (id token in self.observerTokens) {
        [workspaceCenter removeObserver:token];
        [distributedCenter removeObserver:token];
    }
    [self.observerTokens removeAllObjects];
    if (self.axObserver) {
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(self.axObserver), kCFRunLoopDefaultMode);
        CFRelease(self.axObserver);
        self.axObserver = NULL;
    }
    self.isRecording = NO;
    [self emitStatus:@"Stopped"];
}

- (void)checkpointWithReason:(NSString *)reason {
    if (!self.isRecording) {
        return;
    }
    [self clearPendingTransition];
    [self closeCurrentAt:[NSDate date] reason:reason ?: @"checkpoint"];
    [self closeResidentMeetingAt:[NSDate date] reason:reason ?: @"checkpoint"];
    [self sampleWithReason:@"checkpoint-resume"];
}

- (NSDictionary *)currentDashboardSegment {
    if (!self.isRecording || !self.current) {
        return nil;
    }
    NSDictionary *open = [self.current copy];
    NSDictionary *snapshot = open[@"snapshot"];
    NSDate *startAt = open[@"start_at"];
    NSDate *endAt = [NSDate date];
    double duration = MAX(0, [endAt timeIntervalSinceDate:startAt]);
    if (duration <= MinimumRecordedSegmentSeconds()) {
        return nil;
    }
    return @{
        @"id": open[@"id"] ?: [NSUUID UUID].UUIDString,
        @"start_at": [ISOFormatter() stringFromDate:startAt],
        @"end_at": [ISOFormatter() stringFromDate:endAt],
        @"duration_seconds": @(duration),
        @"bundle_id": snapshot[@"bundle_id"] ?: @"",
        @"app_name": snapshot[@"app_name"] ?: @"",
        @"executable_path": snapshot[@"executable_path"] ?: @"",
        @"pid": snapshot[@"pid"] ?: @0,
        @"window_title": snapshot[@"window_title"] ?: @"",
        @"window_role": snapshot[@"window_role"] ?: @"",
        @"window_subrole": snapshot[@"window_subrole"] ?: @"",
        @"sample_count": open[@"sample_count"] ?: @1,
        @"end_reason": @"ongoing",
        @"__ongoing": @YES
    };
}

- (NSDictionary *)currentResidentMeetingSegment {
    if (!self.isRecording || !self.residentMeeting) {
        return nil;
    }
    NSDictionary *open = [self.residentMeeting copy];
    NSDictionary *snapshot = open[@"snapshot"];
    NSDate *startAt = open[@"start_at"];
    NSDate *endAt = [NSDate date];
    double duration = MAX(0, [endAt timeIntervalSinceDate:startAt]);
    if (duration <= MinimumRecordedSegmentSeconds()) {
        return nil;
    }
    return @{
        @"id": open[@"id"] ?: [NSUUID UUID].UUIDString,
        @"start_at": [ISOFormatter() stringFromDate:startAt],
        @"end_at": [ISOFormatter() stringFromDate:endAt],
        @"duration_seconds": @(duration),
        @"bundle_id": snapshot[@"bundle_id"] ?: ResidentMeetingBundleIdentifier,
        @"app_name": snapshot[@"app_name"] ?: ResidentMeetingDisplayName,
        @"executable_path": snapshot[@"executable_path"] ?: @"",
        @"pid": snapshot[@"pid"] ?: @0,
        @"window_title": snapshot[@"window_title"] ?: @"",
        @"window_role": snapshot[@"window_role"] ?: @"",
        @"window_subrole": snapshot[@"window_subrole"] ?: @"",
        @"sample_count": open[@"sample_count"] ?: @1,
        @"end_reason": @"ongoing",
        @"resident": @YES,
        @"resident_kind": @"meeting",
        @"__ongoing": @YES
    };
}

- (void)clearPendingTransition {
    [self.pendingTransitionTimer invalidate];
    self.pendingTransitionTimer = nil;
    self.pendingTransition = nil;
}

- (void)schedulePendingTransitionCheck {
    [self.pendingTransitionTimer invalidate];
    self.pendingTransitionTimer = nil;
    if (!self.pendingTransition || !self.isRecording) {
        return;
    }

    NSDate *startAt = self.pendingTransition[@"start_at"];
    NSTimeInterval elapsed = startAt ? [[NSDate date] timeIntervalSinceDate:startAt] : 0;
    NSTimeInterval delay = MAX(0.05, MinimumRecordedSegmentSeconds() - elapsed + 0.05);
    __weak typeof(self) weakSelf = self;
    self.pendingTransitionTimer = [NSTimer scheduledTimerWithTimeInterval:delay repeats:NO block:^(NSTimer *timer) {
        TrackerController *strongSelf = weakSelf;
        strongSelf.pendingTransitionTimer = nil;
        [strongSelf sampleWithReason:@"switch-debounce"];
    }];
}

- (void)emitStatusForSnapshot:(NSDictionary *)snapshot {
    NSString *windowTitle = snapshot[@"window_title"] ?: @"";
    NSString *status = windowTitle.length > 0
        ? [NSString stringWithFormat:@"%@ %@", snapshot[@"app_name"], DisplayTitle(windowTitle)]
        : (snapshot[@"app_name"] ?: @"");
    [self emitStatus:status];
}

- (BOOL)promotePendingTransitionIfReadyAt:(NSDate *)now reason:(NSString *)reason {
    if (!self.current || !self.pendingTransition) {
        return NO;
    }

    NSDate *startAt = self.pendingTransition[@"start_at"];
    if (!startAt || [now timeIntervalSinceDate:startAt] <= MinimumRecordedSegmentSeconds()) {
        return NO;
    }

    NSMutableDictionary *confirmed = [self.pendingTransition mutableCopy];
    NSString *transitionReason = confirmed[@"reason"] ?: reason ?: @"switch";
    [confirmed removeObjectForKey:@"reason"];
    [self clearPendingTransition];
    [self closeCurrentAt:startAt reason:transitionReason];
    self.current = confirmed;
    [self emitStatusForSnapshot:confirmed[@"snapshot"]];
    return YES;
}

- (void)installWorkspaceObservers {
    if (self.observerTokens.count > 0) {
        return;
    }
    NSNotificationCenter *center = [NSWorkspace sharedWorkspace].notificationCenter;
    id token = [center addObserverForName:NSWorkspaceDidActivateApplicationNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        [self bindAXObserverForFrontmostApp];
        [self sampleWithReason:@"app-activated"];
    }];
    [self.observerTokens addObject:token];

    token = [center addObserverForName:NSWorkspaceWillSleepNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        self.isSleeping = YES;
        [self clearPendingTransition];
        [self closeCurrentAt:[NSDate date] reason:@"sleep"];
        [self closeResidentMeetingAt:[NSDate date] reason:@"sleep"];
    }];
    [self.observerTokens addObject:token];

    token = [center addObserverForName:NSWorkspaceDidWakeNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        self.isSleeping = NO;
        [self sampleWithReason:@"wake"];
    }];
    [self.observerTokens addObject:token];

    token = [center addObserverForName:NSWorkspaceScreensDidSleepNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        [self clearPendingTransition];
        [self closeCurrentAt:[NSDate date] reason:@"screen-sleep"];
        [self closeResidentMeetingAt:[NSDate date] reason:@"screen-sleep"];
    }];
    [self.observerTokens addObject:token];

    NSDistributedNotificationCenter *distributed = [NSDistributedNotificationCenter defaultCenter];
    token = [distributed addObserverForName:@"com.apple.screenIsLocked" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        self.isLocked = YES;
        [self clearPendingTransition];
        [self closeCurrentAt:[NSDate date] reason:@"screen-locked"];
        [self closeResidentMeetingAt:[NSDate date] reason:@"screen-locked"];
    }];
    [self.observerTokens addObject:token];

    token = [distributed addObserverForName:@"com.apple.screenIsUnlocked" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        self.isLocked = NO;
        [self sampleWithReason:@"screen-unlocked"];
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

- (void)sampleWithReason:(NSString *)reason {
    if (!self.isRecording) {
        return;
    }
    NSDate *now = [NSDate date];
    if (self.isLocked || self.isSleeping) {
        [self closeResidentMeetingAt:now reason:reason ?: @"inactive"];
    } else {
        [self sampleResidentMeetingAt:now reason:reason];
    }

    double idle = IdleSeconds();
    NSDate *idleCutoff = [now dateByAddingTimeInterval:-MAX(0, idle - self.idleThreshold)];
    if (self.isLocked || self.isSleeping || idle >= self.idleThreshold) {
        [self clearPendingTransition];
        [self closeCurrentAt:(idle >= self.idleThreshold ? idleCutoff : now) reason:(idle >= self.idleThreshold ? @"idle" : reason)];
        return;
    }

    NSDictionary *snapshot = CurrentSnapshot(idle);
    if (!snapshot) {
        [self clearPendingTransition];
        [self closeCurrentAt:now reason:@"no-frontmost-window"];
        return;
    }

    NSString *identity = snapshot[@"identity"];
    if (!self.current) {
        [self clearPendingTransition];
        self.current = [@{
            @"id": [NSUUID UUID].UUIDString,
            @"start_at": now,
            @"last_seen_at": now,
            @"sample_count": @1,
            @"snapshot": snapshot,
            @"identity": identity
        } mutableCopy];
        [self emitStatusForSnapshot:snapshot];
        return;
    }

    if (self.current && [self.current[@"identity"] isEqualToString:identity]) {
        [self clearPendingTransition];
        self.current[@"last_seen_at"] = now;
        self.current[@"sample_count"] = @([self.current[@"sample_count"] integerValue] + 1);
        return;
    }

    if (self.pendingTransition && [self.pendingTransition[@"identity"] isEqualToString:identity]) {
        self.pendingTransition[@"last_seen_at"] = now;
        self.pendingTransition[@"sample_count"] = @([self.pendingTransition[@"sample_count"] integerValue] + 1);
        self.pendingTransition[@"snapshot"] = snapshot;
        if (![self promotePendingTransitionIfReadyAt:now reason:reason]) {
            [self schedulePendingTransitionCheck];
        }
        return;
    }

    if (self.pendingTransition) {
        if (![self promotePendingTransitionIfReadyAt:now reason:reason]) {
            [self clearPendingTransition];
        }
        if ([self.current[@"identity"] isEqualToString:identity]) {
            self.current[@"last_seen_at"] = now;
            self.current[@"sample_count"] = @([self.current[@"sample_count"] integerValue] + 1);
            return;
        }
    }

    self.pendingTransition = [@{
        @"id": [NSUUID UUID].UUIDString,
        @"start_at": now,
        @"last_seen_at": now,
        @"sample_count": @1,
        @"snapshot": snapshot,
        @"identity": identity,
        @"reason": reason ?: @"switch"
    } mutableCopy];
    [self schedulePendingTransitionCheck];
}

- (void)sampleResidentMeetingAt:(NSDate *)now reason:(NSString *)reason {
    NSDictionary *snapshot = ResidentMeetingSnapshot();
    if (!snapshot) {
        [self closeResidentMeetingAt:now reason:@"meeting-ended"];
        return;
    }

    if (!self.residentMeeting) {
        self.residentMeeting = [@{
            @"id": [NSUUID UUID].UUIDString,
            @"start_at": now,
            @"last_seen_at": now,
            @"sample_count": @1,
            @"snapshot": snapshot,
            @"identity": snapshot[@"identity"] ?: ResidentMeetingBundleIdentifier
        } mutableCopy];
        return;
    }

    self.residentMeeting[@"last_seen_at"] = now;
    self.residentMeeting[@"sample_count"] = @([self.residentMeeting[@"sample_count"] integerValue] + 1);
    self.residentMeeting[@"snapshot"] = snapshot;
}

- (void)closeResidentMeetingAt:(NSDate *)proposedEnd reason:(NSString *)reason {
    if (!self.residentMeeting) {
        return;
    }
    NSDictionary *open = [self.residentMeeting copy];
    self.residentMeeting = nil;

    NSDate *startAt = open[@"start_at"];
    NSDate *endAt = [proposedEnd compare:startAt] == NSOrderedAscending ? startAt : proposedEnd;
    double duration = [endAt timeIntervalSinceDate:startAt];
    if (duration <= MinimumRecordedSegmentSeconds()) {
        return;
    }

    NSDictionary *snapshot = open[@"snapshot"];
    NSDictionary *segment = @{
        @"id": open[@"id"],
        @"start_at": [ISOFormatter() stringFromDate:startAt],
        @"end_at": [ISOFormatter() stringFromDate:endAt],
        @"duration_seconds": @(duration),
        @"bundle_id": snapshot[@"bundle_id"] ?: ResidentMeetingBundleIdentifier,
        @"app_name": snapshot[@"app_name"] ?: ResidentMeetingDisplayName,
        @"executable_path": snapshot[@"executable_path"] ?: @"",
        @"pid": snapshot[@"pid"] ?: @0,
        @"window_title": snapshot[@"window_title"] ?: @"",
        @"window_role": snapshot[@"window_role"] ?: @"",
        @"window_subrole": snapshot[@"window_subrole"] ?: @"",
        @"sample_count": open[@"sample_count"] ?: @1,
        @"end_reason": reason ?: @"meeting-ended",
        @"resident": @YES,
        @"resident_kind": @"meeting"
    };

    NSError *error = nil;
    if (![self.store appendResidentSegment:segment startDate:startAt error:&error]) {
        [self emitStatus:[NSString stringWithFormat:@"Write failed: %@", error.localizedDescription]];
    }
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
    if (duration <= MinimumRecordedSegmentSeconds()) {
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
        @"executable_path": snapshot[@"executable_path"] ?: @"",
        @"pid": snapshot[@"pid"],
        @"window_title": snapshot[@"window_title"] ?: @"",
        @"window_role": snapshot[@"window_role"] ?: @"",
        @"window_subrole": snapshot[@"window_subrole"] ?: @"",
        @"sample_count": open[@"sample_count"],
        @"end_reason": reason
    };

    NSError *error = nil;
    if (![self.store appendSegment:segment startDate:startAt error:&error]) {
        [self emitStatus:[NSString stringWithFormat:@"Write failed: %@", error.localizedDescription]];
    }
}

- (void)emitStatus:(NSString *)status {
    if (self.statusChanged) {
        self.statusChanged(status);
    }
}
@end

static void AXCallback(AXObserverRef observer, AXUIElementRef element, CFStringRef notification, void *refcon) {
    TrackerController *controller = (__bridge TrackerController *)refcon;
    [controller sampleWithReason:(__bridge NSString *)notification];
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

static NSString *LocalizedStatusText(NSString *status) {
    if (status.length == 0) {
        return @"等待数据";
    }
    if ([status isEqualToString:@"Recording"]) {
        return @"记录中";
    }
    if ([status isEqualToString:@"Stopped"]) {
        return @"已暂停";
    }
    if ([status hasPrefix:@"Write failed"]) {
        return @"写入 raw 失败";
    }
    return status;
}

static BOOL SegmentIsGotoworkSelf(NSDictionary *segment) {
    NSString *bundleID = segment[@"bundle_id"] ?: @"";
    NSString *app = segment[@"app_name"] ?: bundleID;
    return [bundleID isEqualToString:GotoworkBundleIdentifier] ||
           [app containsString:@"Gotowork"] ||
           [app containsString:@"Foreground Tracker"];
}

static NSString *SegmentKey(NSDictionary *segment) {
    NSString *bundleID = segment[@"bundle_id"] ?: @"";
    NSString *app = segment[@"app_name"] ?: bundleID;
    if (SegmentIsGotoworkSelf(segment)) {
        return GotoworkBundleIdentifier;
    }
    if ([app isEqualToString:@"loginwindow"] || [bundleID isEqualToString:@"com.apple.loginwindow"]) {
        return @"com.apple.loginwindow";
    }
    if ([app isEqualToString:@"universalAccessAuthWarn"]) {
        return @"system:accessibility-warning";
    }
    if (IsBrowserBundle(bundleID)) {
        return bundleID;
    }
    return bundleID;
}

static NSString *SegmentTitle(NSDictionary *segment) {
    NSString *bundleID = segment[@"bundle_id"] ?: @"";
    NSString *app = segment[@"app_name"] ?: bundleID;
    if (SegmentIsGotoworkSelf(segment)) {
        return @"前台记录";
    }
    if ([app isEqualToString:@"loginwindow"] || [bundleID isEqualToString:@"com.apple.loginwindow"]) {
        return @"登录窗口";
    }
    if ([app isEqualToString:@"universalAccessAuthWarn"]) {
        return @"辅助功能提醒";
    }
    if (IsBrowserBundle(bundleID)) {
        return app;
    }
    return app;
}

static NSSet<NSString *> *IgnoredAppKeysSetting(void) {
    NSArray *keys = [[NSUserDefaults standardUserDefaults] arrayForKey:IgnoredAppKeysKey];
    NSMutableSet *ignored = keys.count ? [NSMutableSet setWithArray:keys] : [NSMutableSet set];
    if (TemporaryIgnoredAppKeys.count > 0) {
        [ignored unionSet:TemporaryIgnoredAppKeys];
    }
    return ignored;
}

static BOOL SegmentShouldHideFromStats(NSDictionary *segment) {
    if (SegmentIsGotoworkSelf(segment)) {
        return YES;
    }
    NSString *key = segment[@"__key"] ?: SegmentKey(segment);
    return key.length > 0 && [IgnoredAppKeysSetting() containsObject:key];
}

static NSString *SuggestedAppFilterReason(NSString *key, NSString *title, NSString *bundleID) {
    NSString *safeKey = key ?: @"";
    NSString *safeTitle = title ?: @"";
    NSString *safeBundleID = bundleID ?: @"";
    if ([safeKey isEqualToString:@"com.apple.loginwindow"] || [safeTitle isEqualToString:@"登录窗口"]) {
        return @"登录/锁屏切换";
    }
    if ([safeKey isEqualToString:@"system:accessibility-warning"] || [safeTitle isEqualToString:@"辅助功能提醒"]) {
        return @"权限提醒弹窗";
    }
    if ([safeBundleID isEqualToString:@"com.apple.dock"] || [safeTitle isEqualToString:@"程序坞"]) {
        return @"系统界面";
    }
    if ([safeBundleID isEqualToString:@"com.apple.systempreferences"] || [safeTitle isEqualToString:@"系统设置"]) {
        return @"临时设置";
    }
    if ([safeBundleID isEqualToString:@"com.apple.SystemUIServer"] || [safeTitle isEqualToString:@"控制中心"]) {
        return @"菜单栏/系统控制";
    }
    return @"";
}

static NSColor *RGB(CGFloat red, CGFloat green, CGFloat blue) {
    return [NSColor colorWithCalibratedRed:red / 255.0 green:green / 255.0 blue:blue / 255.0 alpha:1.0];
}

static BOOL AppIsDark(void) {
    NSAppearance *appearance = NSApp.effectiveAppearance ?: NSAppearance.currentDrawingAppearance ?: [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    NSString *match = [appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
    return [match isEqualToString:NSAppearanceNameDarkAqua];
}

static NSColor *DynamicRGB(CGFloat lightRed, CGFloat lightGreen, CGFloat lightBlue,
                           CGFloat darkRed, CGFloat darkGreen, CGFloat darkBlue) {
    return AppIsDark() ? RGB(darkRed, darkGreen, darkBlue) : RGB(lightRed, lightGreen, lightBlue);
}

static NSColor *SurfaceColor(void) { return DynamicRGB(247, 247, 250, 28, 28, 30); }
static NSColor *PanelColor(void) { return DynamicRGB(255, 255, 255, 38, 38, 40); }
static NSColor *RaisedPanelColor(void) { return DynamicRGB(250, 250, 252, 50, 50, 52); }
static NSColor *SidebarColor(void) { return DynamicRGB(246, 246, 249, 32, 32, 34); }
static NSColor *InspectorColor(void) { return DynamicRGB(253, 253, 255, 36, 36, 38); }
static NSColor *BorderColor(void) { return [DynamicRGB(60, 60, 67, 142, 142, 147) colorWithAlphaComponent:(AppIsDark() ? 0.034 : 0.028)]; }
static NSColor *MutedTextColor(void) { return DynamicRGB(99, 99, 104, 174, 174, 178); }
static NSColor *SecondaryTextColor(void) { return DynamicRGB(72, 72, 76, 202, 202, 207); }
static NSColor *SoftTextColor(void) { return DynamicRGB(22, 22, 24, 245, 245, 247); }
static NSColor *CalendarGridColor(void) { return [DynamicRGB(60, 60, 67, 142, 142, 147) colorWithAlphaComponent:(AppIsDark() ? 0.022 : 0.026)]; }
static NSColor *CalendarGridStrokeColor(CGFloat lightAlpha, CGFloat darkAlpha) { return [DynamicRGB(60, 60, 67, 142, 142, 147) colorWithAlphaComponent:(AppIsDark() ? darkAlpha : lightAlpha)]; }
static NSColor *CalendarHourBandColor(void) { return [DynamicRGB(118, 118, 128, 118, 118, 128) colorWithAlphaComponent:(AppIsDark() ? 0.030 : 0.022)]; }
static NSColor *PillFillColor(void) { return [NSColor.controlAccentColor colorWithAlphaComponent:(AppIsDark() ? 0.24 : 0.12)]; }
static NSColor *GapFillColor(void) { return [DynamicRGB(174, 174, 178, 99, 99, 102) colorWithAlphaComponent:(AppIsDark() ? 0.08 : 0.06)]; }
static NSColor *QuietControlFillColor(void) { return [DynamicRGB(118, 118, 128, 118, 118, 128) colorWithAlphaComponent:(AppIsDark() ? 0.095 : 0.052)]; }
static NSColor *PressedControlFillColor(void) { return [DynamicRGB(255, 255, 255, 255, 255, 255) colorWithAlphaComponent:(AppIsDark() ? 0.16 : 0.86)]; }
static NSColor *ToolbarControlFillColor(void) { return [DynamicRGB(118, 118, 128, 118, 118, 128) colorWithAlphaComponent:(AppIsDark() ? 0.085 : 0.050)]; }
static NSColor *PendingNoticeFillColor(void) { return [NSColor.controlAccentColor colorWithAlphaComponent:(AppIsDark() ? 0.145 : 0.075)]; }
static NSColor *SegmentSeparatorColor(void) { return [PanelColor() colorWithAlphaComponent:(AppIsDark() ? 0.62 : 0.72)]; }
static NSColor *ManualCreationInputFillColor(void) { return [DynamicRGB(255, 255, 255, 58, 58, 60) colorWithAlphaComponent:(AppIsDark() ? 0.34 : 0.84)]; }
static NSColor *ManualCreationInputStrokeColor(void) { return [DynamicRGB(60, 60, 67, 142, 142, 147) colorWithAlphaComponent:(AppIsDark() ? 0.16 : 0.12)]; }
static NSColor *ManualCreationSecondaryButtonFillColor(void) { return [DynamicRGB(118, 118, 128, 118, 118, 128) colorWithAlphaComponent:(AppIsDark() ? 0.18 : 0.10)]; }
static NSColor *NowIndicatorColor(void) { return RGB(255, 69, 58); }

static CGFloat Clamp01(CGFloat value) {
    return MAX(0, MIN(1, value));
}

static NSDate *DashboardNowOverride = nil;

static NSDate *DashboardNow(void) {
    return DashboardNowOverride ?: [NSDate date];
}

static BOOL AppsHaveMeaningfulMix(NSArray *apps) {
    if (apps.count < 2) {
        return NO;
    }

    double first = 0;
    double second = 0;
    double total = 0;
    for (NSDictionary *app in apps) {
        double ratio = MAX(0, [app[@"ratio"] doubleValue]);
        total += ratio;
        if (ratio > first) {
            second = first;
            first = ratio;
        } else if (ratio > second) {
            second = ratio;
        }
    }
    if (total <= 0) {
        return NO;
    }
    first /= total;
    second /= total;
    return first < 0.88 || second >= 0.10;
}

static void FillRoundedRect(NSRect rect, CGFloat radius, NSColor *color) {
    [color setFill];
    [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:radius yRadius:radius] fill];
}

static void StrokeRoundedRect(NSRect rect, CGFloat radius, NSColor *color, CGFloat width) {
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(rect, width / 2.0, width / 2.0)
                                                        xRadius:radius
                                                        yRadius:radius];
    [color setStroke];
    [path setLineWidth:width];
    [path stroke];
}

static void DrawSoftPanel(NSRect rect, NSColor *fill) {
    FillRoundedRect(rect, 13, fill);
    StrokeRoundedRect(rect, 13, BorderColor(), 0.35);
}

static void DrawCenteredString(NSString *text, NSRect rect, NSDictionary *attributes) {
    NSSize size = [text sizeWithAttributes:attributes];
    NSRect drawRect = NSMakeRect(rect.origin.x + floor((rect.size.width - size.width) / 2.0),
                                 rect.origin.y + floor((rect.size.height - size.height) / 2.0) - 0.5,
                                 ceil(size.width) + 2,
                                 ceil(size.height) + 2);
    [text drawInRect:drawRect withAttributes:attributes];
}

static NSAttributedString *ManualCreationButtonTitle(NSString *title, BOOL primary) {
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12 weight:(primary ? NSFontWeightSemibold : NSFontWeightMedium)],
        NSForegroundColorAttributeName: primary ? NSColor.whiteColor : SoftTextColor()
    };
    return [[NSAttributedString alloc] initWithString:title attributes:attrs];
}

static NSColor *ColorForKey(NSString *key);
static void DrawAppIdentityMark(NSDictionary *app, NSString *key, NSRect rect);
static void DrawAppIdentityMarkVariant(NSDictionary *app, NSString *key, NSRect rect, BOOL accentDot, NSColor *fallbackColor, NSColor *dotBackingColor);

static NSRect TimelineLegendChipRect(NSDictionary *app, CGFloat x, CGFloat y, CGFloat maxX, NSDictionary *attributes) {
    NSString *name = app[@"title"] ?: @"未知";
    if (name.length == 0 || x + 48 > maxX) {
        return NSZeroRect;
    }

    CGFloat naturalWidth = [name sizeWithAttributes:attributes].width + 38.0;
    CGFloat width = MIN(MAX(64.0, naturalWidth), 150.0);
    if (x + width > maxX || width < 48.0) {
        return NSZeroRect;
    }
    return NSMakeRect(x, y, width, 20.0);
}

static CGFloat DrawTimelineLegendChip(NSDictionary *app,
                                      CGFloat x,
                                      CGFloat y,
                                      CGFloat maxX,
                                      NSDictionary *attributes,
                                      NSString *highlightedKey) {
    NSString *name = app[@"title"] ?: @"未知";
    NSString *key = app[@"key"] ?: @"__other__";
    NSRect chip = TimelineLegendChipRect(app, x, y, maxX, attributes);
    if (NSEqualRects(chip, NSZeroRect)) {
        return x;
    }

    BOOL highlighted = highlightedKey.length > 0 && [highlightedKey isEqualToString:key];
    NSColor *fill = highlighted
        ? [ColorForKey(key) colorWithAlphaComponent:(AppIsDark() ? 0.18 : 0.105)]
        : [DynamicRGB(118, 118, 128, 118, 118, 128) colorWithAlphaComponent:(AppIsDark() ? 0.052 : 0.042)];
    FillRoundedRect(chip, 7, fill);
    if (highlighted) {
        StrokeRoundedRect(chip, 7, [ColorForKey(key) colorWithAlphaComponent:(AppIsDark() ? 0.26 : 0.18)], 0.55);
    }
    DrawAppIdentityMark(app, key, NSMakeRect(chip.origin.x + 7, chip.origin.y + 3, 14, 14));
    [name drawInRect:NSMakeRect(chip.origin.x + 27, chip.origin.y + 3, chip.size.width - 32, 14)
      withAttributes:attributes];
    return NSMaxX(chip) + 6.0;
}

static CGFloat CalendarEventDisplayHeight(CGFloat naturalHeight, CGFloat gap) {
    if (naturalHeight <= 2.0) {
        return MAX(1.5, naturalHeight);
    }
    if (naturalHeight < 8.0) {
        return MIN(8.0, naturalHeight + 2.4);
    }
    if (naturalHeight < 14.0) {
        return naturalHeight + 1.0;
    }
    if (naturalHeight < 18.0) {
        return MIN(naturalHeight + 0.75, naturalHeight * 1.04);
    }
    return MAX(1.0, naturalHeight - gap);
}

static BOOL ShouldUseCompactCalendarChrome(CGFloat height, BOOL hovered, BOOL selected) {
    return !hovered && !selected && height < 18.0;
}

static NSRect CenteredTimelineRailRect(NSRect rect, CGFloat maxHeight) {
    CGFloat height = MIN(MAX(2.0, rect.size.height), maxHeight);
    return NSMakeRect(rect.origin.x,
                      rect.origin.y + floor((rect.size.height - height) / 2.0),
                      rect.size.width,
                      height);
}

static NSColor *PolishedAppColor(NSColor *color) {
    NSColor *rgb = [color colorUsingColorSpace:NSColorSpace.genericRGBColorSpace] ?: color;
    CGFloat hue = 0;
    CGFloat saturation = 0;
    CGFloat brightness = 0;
    CGFloat alpha = 1;
    [rgb getHue:&hue saturation:&saturation brightness:&brightness alpha:&alpha];
    if (AppIsDark()) {
        saturation *= 0.80;
        brightness = MIN(1.0, brightness * 0.94 + 0.04);
    } else {
        saturation = MIN(1.0, saturation * 0.90 + 0.03);
        brightness = MIN(1.0, brightness * 0.94 + 0.03);
    }
    return [NSColor colorWithCalibratedHue:hue saturation:saturation brightness:brightness alpha:alpha];
}

static NSString *HexStringFromColor(NSColor *color) {
    NSColor *rgb = [color colorUsingColorSpace:NSColorSpace.genericRGBColorSpace] ?: color;
    CGFloat red = 0;
    CGFloat green = 0;
    CGFloat blue = 0;
    CGFloat alpha = 1;
    [rgb getRed:&red green:&green blue:&blue alpha:&alpha];
    NSInteger r = MAX(0, MIN(255, (NSInteger)lrint(red * 255.0)));
    NSInteger g = MAX(0, MIN(255, (NSInteger)lrint(green * 255.0)));
    NSInteger b = MAX(0, MIN(255, (NSInteger)lrint(blue * 255.0)));
    return [NSString stringWithFormat:@"%02lX%02lX%02lX", (long)r, (long)g, (long)b];
}

static NSColor *ColorFromHexString(NSString *hex) {
    if (![hex isKindOfClass:NSString.class] || hex.length == 0) {
        return nil;
    }
    NSString *clean = [[hex stringByReplacingOccurrencesOfString:@"#" withString:@""] uppercaseString];
    if (clean.length != 6) {
        return nil;
    }
    unsigned int value = 0;
    NSScanner *scanner = [NSScanner scannerWithString:clean];
    if (![scanner scanHexInt:&value]) {
        return nil;
    }
    return RGB((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF);
}

static NSColor *StoredColorForKey(NSString *key) {
    if (key.length == 0) {
        return nil;
    }
    NSDictionary *overrides = [[NSUserDefaults standardUserDefaults] dictionaryForKey:AppColorOverridesByKeyKey];
    NSColor *color = ColorFromHexString(overrides[key]);
    return color ? PolishedAppColor(color) : nil;
}

static void StoreColorForKey(NSString *key, NSColor *color) {
    if (key.length == 0 || !color) {
        return;
    }
    NSMutableDictionary *overrides = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:AppColorOverridesByKeyKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    overrides[key] = HexStringFromColor(color);
    [[NSUserDefaults standardUserDefaults] setObject:overrides forKey:AppColorOverridesByKeyKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

static NSUInteger StablePaletteIndexForKey(NSString *key, NSUInteger count) {
    if (count == 0) {
        return 0;
    }
    NSData *data = [key ?: @"" dataUsingEncoding:NSUTF8StringEncoding];
    const unsigned char *bytes = (const unsigned char *)data.bytes;
    NSUInteger length = data.length;
    uint64_t hash = 1469598103934665603ULL;
    for (NSUInteger i = 0; i < length; i++) {
        hash ^= bytes[i];
        hash *= 1099511628211ULL;
    }
    return (NSUInteger)(hash % count);
}

static NSColor *ColorForKey(NSString *key) {
    static NSDictionary<NSString *, NSColor *> *palette;
    static NSArray<NSColor *> *fallback;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        palette = @{
            @"com.ariguo.Gotowork": DynamicRGB(255, 149, 0, 255, 159, 10),
            @"com.apple.loginwindow": DynamicRGB(90, 200, 245, 100, 210, 255),
            @"system:accessibility-warning": DynamicRGB(255, 149, 0, 255, 159, 10),
            @"__manual_block__": DynamicRGB(88, 86, 214, 94, 92, 230),
            @"__mixed_work__": DynamicRGB(99, 99, 102, 142, 142, 147),
            @"__other__": DynamicRGB(99, 99, 102, 142, 142, 147)
        };
        fallback = @[
            DynamicRGB(0, 122, 255, 10, 132, 255),
            DynamicRGB(52, 199, 89, 48, 209, 88),
            DynamicRGB(255, 149, 0, 255, 159, 10),
            DynamicRGB(175, 82, 222, 191, 90, 242),
            DynamicRGB(255, 45, 85, 255, 55, 95),
            DynamicRGB(50, 173, 230, 64, 200, 224),
            DynamicRGB(88, 86, 214, 94, 92, 230),
            DynamicRGB(90, 200, 245, 100, 210, 255)
        ];
    });
    NSString *safeKey = key ?: @"";
    NSColor *stored = StoredColorForKey(safeKey);
    if (stored) {
        return stored;
    }
    NSColor *known = palette[safeKey];
    if (known) {
        return PolishedAppColor(known);
    }
    return PolishedAppColor(fallback[StablePaletteIndexForKey(safeKey, fallback.count)]);
}

static NSImage *AppIconForBundleID(NSString *bundleID) {
    if (bundleID.length == 0 ||
        [bundleID hasPrefix:@"__"] ||
        [bundleID hasPrefix:@"system:"]) {
        return nil;
    }

    static NSMutableDictionary<NSString *, NSImage *> *iconCache;
    static NSMutableSet<NSString *> *misses;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        iconCache = [NSMutableDictionary dictionary];
        misses = [NSMutableSet set];
    });

    NSImage *cached = iconCache[bundleID];
    if (cached) {
        return cached;
    }
    if ([misses containsObject:bundleID]) {
        return nil;
    }

    NSURL *appURL = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:bundleID];
    NSString *path = appURL.path;
    if (path.length == 0) {
        [misses addObject:bundleID];
        return nil;
    }

    NSImage *icon = [[NSWorkspace sharedWorkspace] iconForFile:path];
    if (!icon || !icon.valid) {
        [misses addObject:bundleID];
        return nil;
    }
    icon.size = NSMakeSize(32, 32);
    iconCache[bundleID] = icon;
    return icon;
}

static void DrawAppIdentityMarkVariant(NSDictionary *app, NSString *key, NSRect rect, BOOL accentDot, NSColor *fallbackColor, NSColor *dotBackingColor) {
    NSString *safeKey = key.length ? key : (app[@"key"] ?: @"__other__");
    NSColor *color = ColorForKey(safeKey);
    NSImage *icon = AppIconForBundleID(app[@"bundle_id"]);
    if (!icon) {
        CGFloat size = MIN(10.0, MIN(rect.size.width, rect.size.height));
        NSRect dot = NSMakeRect(rect.origin.x + floor((rect.size.width - size) / 2.0),
                                rect.origin.y + floor((rect.size.height - size) / 2.0),
                                size,
                                size);
        NSColor *fill = fallbackColor ?: [color colorWithAlphaComponent:0.92];
        [fill setFill];
        [[NSBezierPath bezierPathWithOvalInRect:dot] fill];
        return;
    }

    NSBezierPath *clip = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:3.5 yRadius:3.5];
    [NSGraphicsContext saveGraphicsState];
    [clip addClip];
    [icon drawInRect:rect
            fromRect:NSZeroRect
           operation:NSCompositingOperationSourceOver
            fraction:1.0
      respectFlipped:YES
               hints:nil];
    [NSGraphicsContext restoreGraphicsState];

    StrokeRoundedRect(NSInsetRect(rect, 0.25, 0.25),
                      3.5,
                      [NSColor.whiteColor colorWithAlphaComponent:(AppIsDark() ? 0.12 : 0.28)],
                      0.45);
    if (!accentDot) {
        return;
    }

    CGFloat dotSize = MAX(4.0, MIN(5.5, rect.size.width * 0.34));
    NSRect dot = NSMakeRect(NSMaxX(rect) - dotSize + 0.5,
                            NSMaxY(rect) - dotSize + 0.5,
                            dotSize,
                            dotSize);
    FillRoundedRect(NSInsetRect(dot, -1.0, -1.0), dotSize / 2.0 + 1.0, dotBackingColor ?: InspectorColor());
    [[color colorWithAlphaComponent:0.95] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:dot] fill];
}

static void DrawAppIdentityMark(NSDictionary *app, NSString *key, NSRect rect) {
    DrawAppIdentityMarkVariant(app, key, rect, YES, nil, InspectorColor());
}

static NSColor *ProjectColorForTitle(NSString *title) {
    static NSArray<NSColor *> *projectPalette;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        projectPalette = @[
            DynamicRGB(255, 149, 0, 255, 159, 10),
            DynamicRGB(255, 204, 0, 255, 214, 10),
            DynamicRGB(255, 45, 85, 255, 55, 95),
            DynamicRGB(175, 82, 222, 191, 90, 242),
            DynamicRGB(90, 200, 245, 100, 210, 255),
            DynamicRGB(52, 199, 89, 48, 209, 88),
            DynamicRGB(88, 86, 214, 94, 92, 230)
        ];
    });
    NSString *safeTitle = title.length > 0 ? title : @"项目";
    NSString *key = [@"project:" stringByAppendingString:safeTitle];
    return PolishedAppColor(projectPalette[StablePaletteIndexForKey(key, projectPalette.count)]);
}

static BOOL DecorateSegment(NSMutableDictionary *segment) {
    NSDate *start = [segment[@"__start"] isKindOfClass:NSDate.class] ? segment[@"__start"] : [ISOFormatter() dateFromString:segment[@"start_at"]];
    NSDate *end = [segment[@"__end"] isKindOfClass:NSDate.class] ? segment[@"__end"] : [ISOFormatter() dateFromString:segment[@"end_at"]];
    if (!segment || !start || !end) {
        return NO;
    }
    segment[@"__start"] = start;
    segment[@"__end"] = end;
    segment[@"__key"] = SegmentKey(segment);
    segment[@"__title"] = SegmentTitle(segment);
    return YES;
}

static NSString *DashboardDateTitle(NSDate *date);

static NSArray<NSMutableDictionary *> *ReadRawSegmentsFromURL(NSURL *rawURL,
                                                              BOOL includeShortSegments,
                                                              BOOL includeIgnoredApps) {
    if (![[NSFileManager defaultManager] fileExistsAtPath:rawURL.path]) {
        return @[];
    }
    NSString *body = [NSString stringWithContentsOfURL:rawURL encoding:NSUTF8StringEncoding error:nil];
    if (body.length == 0) {
        return @[];
    }

    NSMutableArray *segments = [NSMutableArray array];
    for (NSString *line in [body componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        if (line.length == 0) {
            continue;
        }
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSMutableDictionary *segment = [[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil] mutableCopy];
        if (!DecorateSegment(segment)) {
            continue;
        }
        if (SegmentIsGotoworkSelf(segment) || (!includeIgnoredApps && SegmentShouldHideFromStats(segment))) {
            continue;
        }
        double duration = [segment[@"duration_seconds"] doubleValue];
        if (duration <= 0) {
            duration = [segment[@"__end"] timeIntervalSinceDate:segment[@"__start"]];
        }
        if (duration <= 0 || (!includeShortSegments && duration <= MinimumRecordedSegmentSeconds())) {
            continue;
        }
        segment[@"__duration_seconds"] = @(duration);
        [segments addObject:segment];
    }

    [segments sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"__start"] compare:b[@"__start"]];
    }];
    return segments;
}

static NSArray<NSMutableDictionary *> *ReadRawSegments(NSURL *rawURL) {
    return ReadRawSegmentsFromURL(rawURL, NO, NO);
}

static NSArray<NSMutableDictionary *> *ReadRawSegmentsIncludingShort(NSURL *rawURL) {
    return ReadRawSegmentsFromURL(rawURL, YES, NO);
}

static NSArray<NSMutableDictionary *> *ReadRawSegmentsForAppFiltering(NSURL *rawURL) {
    return ReadRawSegmentsFromURL(rawURL, YES, YES);
}

static NSArray<NSString *> *DurationDistributionBucketLabels(void) {
    return @[@"<=1s", @"1-2s", @"2-5s", @"5-10s", @"10-30s", @"30-60s", @"1-3m", @"3-5m", @"5-10m", @">10m"];
}

static NSInteger DurationDistributionBucketIndex(double seconds) {
    if (seconds <= 1.0) {
        return 0;
    }
    if (seconds <= 2.0) {
        return 1;
    }
    if (seconds <= 5.0) {
        return 2;
    }
    if (seconds <= 10.0) {
        return 3;
    }
    if (seconds <= 30.0) {
        return 4;
    }
    if (seconds <= 60.0) {
        return 5;
    }
    if (seconds <= 180.0) {
        return 6;
    }
    if (seconds <= 300.0) {
        return 7;
    }
    if (seconds <= 600.0) {
        return 8;
    }
    return 9;
}

static NSDictionary *SegmentDurationDistribution(NSArray<NSMutableDictionary *> *segments) {
    NSArray<NSString *> *labels = DurationDistributionBucketLabels();
    NSMutableArray<NSMutableDictionary *> *buckets = [NSMutableArray array];
    for (NSString *label in labels) {
        [buckets addObject:[@{@"label": label, @"count": @0, @"seconds": @0.0} mutableCopy]];
    }

    NSInteger recordedCount = 0;
    NSInteger filteredCount = 0;
    NSInteger absorbedCount = 0;
    double totalSeconds = 0;
    double recordedSeconds = 0;
    double filteredSeconds = 0;
    double absorbedSeconds = 0;

    for (NSDictionary *segment in segments ?: @[]) {
        double duration = [segment[@"__duration_seconds"] doubleValue];
        if (duration <= 0) {
            duration = RawSegmentDuration(segment);
        }
        if (duration <= 0) {
            continue;
        }

        NSInteger bucketIndex = DurationDistributionBucketIndex(duration);
        NSMutableDictionary *bucket = buckets[bucketIndex];
        bucket[@"count"] = @([bucket[@"count"] integerValue] + 1);
        bucket[@"seconds"] = @([bucket[@"seconds"] doubleValue] + duration);
        totalSeconds += duration;

        if (duration <= MinimumRecordedSegmentSeconds()) {
            filteredCount += 1;
            filteredSeconds += duration;
        } else {
            recordedCount += 1;
            recordedSeconds += duration;
        }

        absorbedCount += [segment[@"absorbed_short_interruption_count"] integerValue];
        absorbedSeconds += [segment[@"absorbed_short_interruption_seconds"] doubleValue];
    }

    return @{
        @"buckets": buckets,
        @"raw_segment_count": @(segments.count),
        @"recorded_segment_count": @(recordedCount),
        @"filtered_segment_count": @(filteredCount),
        @"total_seconds": @(totalSeconds),
        @"recorded_seconds": @(recordedSeconds),
        @"filtered_seconds": @(filteredSeconds),
        @"absorbed_short_interruption_count": @(absorbedCount),
        @"absorbed_short_interruption_seconds": @(absorbedSeconds)
    };
}

static NSString *DurationDistributionReportSection(NSString *title, NSDictionary *distribution) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSInteger rawCount = [distribution[@"raw_segment_count"] integerValue];
    NSInteger recordedCount = [distribution[@"recorded_segment_count"] integerValue];
    NSInteger filteredCount = [distribution[@"filtered_segment_count"] integerValue];
    NSInteger absorbedCount = [distribution[@"absorbed_short_interruption_count"] integerValue];
    double recordedSeconds = [distribution[@"recorded_seconds"] doubleValue];
    double filteredSeconds = [distribution[@"filtered_seconds"] doubleValue];
    double absorbedSeconds = [distribution[@"absorbed_short_interruption_seconds"] doubleValue];

    [lines addObject:[NSString stringWithFormat:@"%@：%@ · %ld 段", title, ShortDuration(recordedSeconds), (long)recordedCount]];
    if (filteredCount > 0) {
        [lines addObject:[NSString stringWithFormat:@"<=1s 已过滤：%ld 段 · %@", (long)filteredCount, ShortDuration(filteredSeconds)]];
    }
    if (absorbedCount > 0) {
        [lines addObject:[NSString stringWithFormat:@"来回切换已合并：%ld 次 · %@", (long)absorbedCount, ShortDuration(absorbedSeconds)]];
    }
    if (rawCount == 0) {
        [lines addObject:@"还没有 raw 片段。"];
        return [lines componentsJoinedByString:@"\n"];
    }

    [lines addObject:@""];
    [lines addObject:@"区间\t段数\t时长"];
    for (NSDictionary *bucket in distribution[@"buckets"] ?: @[]) {
        NSInteger count = [bucket[@"count"] integerValue];
        double seconds = [bucket[@"seconds"] doubleValue];
        [lines addObject:[NSString stringWithFormat:@"%@\t%ld\t%@",
                          bucket[@"label"] ?: @"",
                          (long)count,
                          ShortDuration(seconds)]];
    }
    return [lines componentsJoinedByString:@"\n"];
}

static NSString *DurationDistributionReport(NSArray<NSMutableDictionary *> *foregroundSegments,
                                            NSArray<NSMutableDictionary *> *residentSegments) {
    NSMutableArray<NSString *> *sections = [NSMutableArray array];
    [sections addObject:DurationDistributionReportSection(@"前台", SegmentDurationDistribution(foregroundSegments))];
    if (residentSegments.count > 0) {
        [sections addObject:DurationDistributionReportSection(@"常驻", SegmentDurationDistribution(residentSegments))];
    }
    return [sections componentsJoinedByString:@"\n\n"];
}

static NSString *DurationDistributionSettingsSummary(NSDate *date, NSDictionary *distribution) {
    NSArray *buckets = distribution[@"buckets"] ?: @[];
    NSInteger oneToTwo = buckets.count > 1 ? [buckets[1][@"count"] integerValue] : 0;
    NSInteger twoToFive = buckets.count > 2 ? [buckets[2][@"count"] integerValue] : 0;
    NSInteger fiveToTen = buckets.count > 3 ? [buckets[3][@"count"] integerValue] : 0;
    NSInteger absorbedCount = [distribution[@"absorbed_short_interruption_count"] integerValue];
    double absorbedSeconds = [distribution[@"absorbed_short_interruption_seconds"] doubleValue];
    NSInteger recordedCount = [distribution[@"recorded_segment_count"] integerValue];
    if (recordedCount == 0) {
        return [NSString stringWithFormat:@"%@还没有可统计的片段。", DashboardDateTitle(date)];
    }
    NSString *absorbed = absorbedCount > 0
        ? [NSString stringWithFormat:@"，已合并 %ld 次/%@", (long)absorbedCount, ShortDuration(absorbedSeconds)]
        : @"";
    return [NSString stringWithFormat:@"%@碎片：1-2s %ld 段，2-5s %ld 段，5-10s %ld 段%@。",
            DashboardDateTitle(date),
            (long)oneToTwo,
            (long)twoToFive,
            (long)fiveToTen,
            absorbed];
}

static void PrintDurationDistribution(NSDate *date,
                                      NSString *source,
                                      NSArray<NSMutableDictionary *> *segments) {
    NSDictionary *distribution = SegmentDurationDistribution(segments);
    printf("date=%s source=%s raw_segments=%ld recorded_segments=%ld filtered_le_1s=%ld recorded_seconds=%.1f filtered_seconds=%.1f absorbed_count=%ld absorbed_seconds=%.1f raw_merge_threshold=%.1f\n",
           [DayString(date) UTF8String],
           [(source ?: @"foreground") UTF8String],
           (long)[distribution[@"raw_segment_count"] integerValue],
           (long)[distribution[@"recorded_segment_count"] integerValue],
           (long)[distribution[@"filtered_segment_count"] integerValue],
           [distribution[@"recorded_seconds"] doubleValue],
           [distribution[@"filtered_seconds"] doubleValue],
           (long)[distribution[@"absorbed_short_interruption_count"] integerValue],
           [distribution[@"absorbed_short_interruption_seconds"] doubleValue],
           RawMergeInterruptionSetting());
    for (NSDictionary *bucket in distribution[@"buckets"] ?: @[]) {
        printf("date=%s source=%s bucket=%s count=%ld seconds=%.1f\n",
               [DayString(date) UTF8String],
               [(source ?: @"foreground") UTF8String],
               [bucket[@"label"] ?: @"" UTF8String],
               (long)[bucket[@"count"] integerValue],
               [bucket[@"seconds"] doubleValue]);
    }
}

static void AddSecondsToApps(NSMutableDictionary<NSString *, NSMutableDictionary *> *apps,
                             NSString *key,
                             NSString *title,
                             NSString *bundleID,
                             double seconds) {
    if (seconds <= 0) {
        return;
    }
    NSString *safeKey = key.length ? key : @"unknown";
    if (!apps[safeKey]) {
        apps[safeKey] = [@{
            @"key": safeKey,
            @"title": title.length ? title : safeKey,
            @"bundle_id": bundleID ?: @"",
            @"seconds": @0.0
        } mutableCopy];
    }
    NSMutableDictionary *entry = apps[safeKey];
    entry[@"seconds"] = @([entry[@"seconds"] doubleValue] + seconds);
}

static NSArray *SortedAppsBySeconds(NSDictionary<NSString *, NSMutableDictionary *> *apps) {
    return [apps.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"seconds"] compare:a[@"seconds"]];
    }];
}

static NSDictionary *AppSummaryFromSegments(NSArray<NSMutableDictionary *> *segments) {
    NSMutableDictionary<NSString *, NSMutableDictionary *> *apps = [NSMutableDictionary dictionary];
    double total = 0;
    for (NSMutableDictionary *segment in segments ?: @[]) {
        double duration = [segment[@"duration_seconds"] doubleValue];
        if (duration <= 0) {
            duration = [segment[@"__end"] timeIntervalSinceDate:segment[@"__start"]];
        }
        if (duration <= 0) {
            continue;
        }
        total += duration;

        NSString *key = segment[@"__key"] ?: @"unknown";
        if (!apps[key]) {
            apps[key] = [@{
                @"key": key,
                @"title": segment[@"__title"] ?: @"",
                @"bundle_id": segment[@"bundle_id"] ?: @"",
                @"seconds": @0.0,
                @"count": @0
            } mutableCopy];
        }
        apps[key][@"seconds"] = @([apps[key][@"seconds"] doubleValue] + duration);
        apps[key][@"count"] = @([apps[key][@"count"] integerValue] + 1);
    }

    for (NSMutableDictionary *app in apps.allValues) {
        double seconds = [app[@"seconds"] doubleValue];
        app[@"ratio"] = @(total > 0 ? seconds / total : 0);
    }

    return @{
        @"top_apps": SortedAppsBySeconds(apps),
        @"total_seconds": @(total),
        @"segment_count": @(segments.count)
    };
}

static NSDate *CalendarStartOfDay(NSDate *date) {
    return [[NSCalendar currentCalendar] startOfDayForDate:date ?: [NSDate date]];
}

static NSDate *DateByAddingDays(NSDate *date, NSInteger days) {
    return [[NSCalendar currentCalendar] dateByAddingUnit:NSCalendarUnitDay
                                                    value:days
                                                   toDate:date ?: [NSDate date]
                                                  options:0];
}

static NSDate *DateOnDayAtHour(NSDate *day, NSInteger hour) {
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDateComponents *components = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay
                                               fromDate:CalendarStartOfDay(day)];
    components.hour = MAX(0, MIN(23, hour));
    components.minute = 0;
    components.second = 0;
    return [calendar dateFromComponents:components] ?: CalendarStartOfDay(day);
}

static NSDate *StartOfWeekForDate(NSDate *date) {
    NSCalendar *calendar = [NSCalendar currentCalendar];
    calendar.firstWeekday = 2;
    NSDate *start = nil;
    NSTimeInterval interval = 0;
    if ([calendar rangeOfUnit:NSCalendarUnitWeekOfYear startDate:&start interval:&interval forDate:date ?: [NSDate date]]) {
        return start;
    }
    return CalendarStartOfDay(date);
}

static NSDate *StartOfMonthForDate(NSDate *date) {
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDateComponents *components = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth fromDate:date ?: [NSDate date]];
    components.day = 1;
    return [calendar dateFromComponents:components] ?: CalendarStartOfDay(date);
}

static NSString *ScopeRangeLabel(NSDate *startInclusive, NSDate *endExclusive) {
    NSDate *endInclusive = DateByAddingDays(endExclusive, -1);
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    formatter.dateFormat = @"M月d日";
    if ([DayString(startInclusive) isEqualToString:DayString(endInclusive)]) {
        return [formatter stringFromDate:startInclusive];
    }
    return [NSString stringWithFormat:@"%@-%@",
            [formatter stringFromDate:startInclusive],
            [formatter stringFromDate:endInclusive]];
}

static NSDate *EndOfMonthForDate(NSDate *date) {
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDate *start = StartOfMonthForDate(date);
    return [calendar dateByAddingUnit:NSCalendarUnitMonth value:1 toDate:start options:0] ?: DateByAddingDays(start, 31);
}

static NSDate *EarlierDate(NSDate *a, NSDate *b) {
    if (!a) {
        return b;
    }
    if (!b) {
        return a;
    }
    return [a compare:b] == NSOrderedDescending ? b : a;
}

static BOOL SameDay(NSDate *a, NSDate *b) {
    return [DayString(a) isEqualToString:DayString(b)];
}

static NSString *DashboardDateTitle(NSDate *date) {
    NSDate *day = CalendarStartOfDay(date);
    NSDate *today = CalendarStartOfDay([NSDate date]);
    if (SameDay(day, today)) {
        return @"今日";
    }
    if (SameDay(day, DateByAddingDays(today, -1))) {
        return @"昨日";
    }
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    formatter.dateFormat = @"M月d日";
    return [formatter stringFromDate:day];
}

static NSString *DashboardDateSubtitle(NSDate *date) {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    formatter.dateFormat = @"yyyy年M月d日 EEEE";
    return [formatter stringFromDate:CalendarStartOfDay(date)];
}

static void AddOpenSegmentIfInRange(NSMutableArray<NSMutableDictionary *> *segments,
                                    NSDictionary *openSegment,
                                    NSDate *startInclusive,
                                    NSDate *endExclusive) {
    if (!openSegment) {
        return;
    }
    NSMutableDictionary *open = [openSegment mutableCopy];
    if (DecorateSegment(open) &&
        !SegmentShouldHideFromStats(open) &&
        [open[@"__start"] compare:startInclusive] != NSOrderedAscending &&
        [open[@"__start"] compare:endExclusive] == NSOrderedAscending) {
        [segments addObject:open];
    }
}

static NSMutableArray<NSMutableDictionary *> *ReadSegmentsForRange(SegmentStore *store,
                                                                    NSDate *startInclusive,
                                                                    NSDate *endExclusive,
                                                                    NSDictionary *openSegment) {
    NSMutableArray<NSMutableDictionary *> *segments = [NSMutableArray array];
    NSDate *day = CalendarStartOfDay(startInclusive);
    NSDate *end = CalendarStartOfDay(endExclusive);
    while ([day compare:end] == NSOrderedAscending) {
        [segments addObjectsFromArray:ReadRawSegments([store rawURLForDate:day])];
        day = DateByAddingDays(day, 1);
    }

    AddOpenSegmentIfInRange(segments, openSegment, startInclusive, endExclusive);

    [segments sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"__start"] compare:b[@"__start"]];
    }];
    return segments;
}

static NSMutableArray<NSMutableDictionary *> *ReadResidentSegmentsForRange(SegmentStore *store,
                                                                            NSDate *startInclusive,
                                                                            NSDate *endExclusive,
                                                                            NSDictionary *openSegment) {
    NSMutableArray<NSMutableDictionary *> *segments = [NSMutableArray array];
    NSDate *day = CalendarStartOfDay(startInclusive);
    NSDate *end = CalendarStartOfDay(endExclusive);
    while ([day compare:end] == NSOrderedAscending) {
        [segments addObjectsFromArray:ReadRawSegments([store residentRawURLForDate:day])];
        day = DateByAddingDays(day, 1);
    }

    AddOpenSegmentIfInRange(segments, openSegment, startInclusive, endExclusive);

    [segments sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"__start"] compare:b[@"__start"]];
    }];
    return segments;
}

static NSDictionary *ScopeSummary(NSString *title,
                                  NSDate *startInclusive,
                                  NSDate *endExclusive,
                                  NSArray<NSMutableDictionary *> *segments) {
    NSMutableDictionary *summary = [AppSummaryFromSegments(segments) mutableCopy];
    summary[@"title"] = title ?: @"";
    summary[@"range_label"] = ScopeRangeLabel(startInclusive, endExclusive);
    return summary;
}

static NSArray<NSMutableDictionary *> *SegmentsWithAbsorbedShortInterruptions(NSArray<NSMutableDictionary *> *segments) {
    NSMutableArray *smoothed = [NSMutableArray arrayWithCapacity:segments.count];
    NSTimeInterval absorbSeconds = ShortInterruptionSetting();
    for (NSInteger i = 0; i < segments.count; i++) {
        NSMutableDictionary *copy = [segments[i] mutableCopy];
        if (i > 0 && i + 1 < segments.count) {
            NSDictionary *previous = segments[i - 1];
            NSDictionary *current = segments[i];
            NSDictionary *next = segments[i + 1];
            double duration = [current[@"__end"] timeIntervalSinceDate:current[@"__start"]];
            BOOL sameAround = [previous[@"__key"] isEqualToString:next[@"__key"]];
            BOOL differentMiddle = ![current[@"__key"] isEqualToString:previous[@"__key"]];
            BOOL touchesPrevious = fabs([current[@"__start"] timeIntervalSinceDate:previous[@"__end"]]) <= 5.0;
            BOOL touchesNext = fabs([next[@"__start"] timeIntervalSinceDate:current[@"__end"]]) <= 5.0;
            if (duration <= absorbSeconds && sameAround && differentMiddle && touchesPrevious && touchesNext) {
                copy[@"__key"] = previous[@"__key"] ?: copy[@"__key"] ?: @"";
                copy[@"__title"] = previous[@"__title"] ?: copy[@"__title"] ?: @"";
                copy[@"bundle_id"] = previous[@"bundle_id"] ?: copy[@"bundle_id"] ?: @"";
                copy[@"app_name"] = previous[@"__title"] ?: copy[@"app_name"] ?: @"";
                copy[@"__absorbed_interruption"] = @YES;
            }
        }
        [smoothed addObject:copy];
    }
    return smoothed;
}

static NSDictionary<NSNumber *, NSMutableDictionary *> *MinuteBucketsFromSegments(NSArray<NSMutableDictionary *> *segments) {
    NSMutableDictionary<NSNumber *, NSMutableDictionary *> *buckets = [NSMutableDictionary dictionary];
    for (NSMutableDictionary *segment in segments) {
        double cursor = [segment[@"__start"] timeIntervalSince1970];
        double end = [segment[@"__end"] timeIntervalSince1970];
        while (cursor < end - 0.001) {
            double minuteStart = floor(cursor / 60.0) * 60.0;
            double sliceEnd = MIN(end, minuteStart + 60.0);
            double seconds = sliceEnd - cursor;
            if (seconds <= 0) {
                break;
            }

            NSNumber *bucketKey = @(minuteStart);
            if (!buckets[bucketKey]) {
                buckets[bucketKey] = [@{
                    @"start": [NSDate dateWithTimeIntervalSince1970:minuteStart],
                    @"end": [NSDate dateWithTimeIntervalSince1970:minuteStart + 60.0],
                    @"observed_seconds": @0.0,
                    @"apps": [NSMutableDictionary dictionary]
                } mutableCopy];
            }

            NSMutableDictionary *bucket = buckets[bucketKey];
            bucket[@"observed_seconds"] = @([bucket[@"observed_seconds"] doubleValue] + seconds);
            AddSecondsToApps(bucket[@"apps"], segment[@"__key"], segment[@"__title"], segment[@"bundle_id"], seconds);
            cursor = sliceEnd;
        }
    }
    return buckets;
}

static NSMutableDictionary *AssignmentForMinute(NSNumber *minuteKey,
                                                NSDictionary *app,
                                                NSString *kind,
                                                NSString *mode,
                                                double assignedSeconds,
                                                double observedSeconds,
                                                double score) {
    BOOL mixed = [kind isEqualToString:@"mixed"];
    NSString *key = mixed ? @"__mixed_work__" : (app[@"key"] ?: @"unknown");
    NSString *title = mixed ? @"混合工作" : (app[@"title"] ?: key);
    NSString *bundleID = mixed ? @"__mixed_work__" : (app[@"bundle_id"] ?: @"");
    return [@{
        @"start": [NSDate dateWithTimeIntervalSince1970:minuteKey.doubleValue],
        @"end": [NSDate dateWithTimeIntervalSince1970:minuteKey.doubleValue + 60.0],
        @"active_seconds": @(assignedSeconds),
        @"observed_seconds": @(observedSeconds),
        @"key": key,
        @"bundle_id": bundleID,
        @"title": title,
        @"kind": mixed ? @"mixed" : @"app",
        @"mode": mode,
        @"score": @(score)
    } mutableCopy];
}

static NSInteger AssignmentPriority(NSDictionary *assignment) {
    return [assignment[@"kind"] isEqualToString:@"app"] ? 2 : 1;
}

static BOOL ShouldReplaceAssignment(NSDictionary *existing, NSDictionary *candidate) {
    if (!existing) {
        return YES;
    }
    NSInteger existingPriority = AssignmentPriority(existing);
    NSInteger candidatePriority = AssignmentPriority(candidate);
    if (candidatePriority > existingPriority) {
        return YES;
    }
    if (candidatePriority < existingPriority) {
        return NO;
    }
    return [candidate[@"score"] doubleValue] > [existing[@"score"] doubleValue] + 0.1;
}

static NSArray *TopAppsForInterval(NSArray<NSMutableDictionary *> *segments, NSDate *start, NSDate *end) {
    NSMutableDictionary<NSString *, NSMutableDictionary *> *apps = [NSMutableDictionary dictionary];
    double observed = 0;
    for (NSDictionary *segment in segments) {
        double overlap = MAX(0, MIN([segment[@"__end"] timeIntervalSinceDate:start], [end timeIntervalSinceDate:start]) -
                                MAX([segment[@"__start"] timeIntervalSinceDate:start], 0));
        if (overlap <= 0) {
            continue;
        }
        observed += overlap;
        AddSecondsToApps(apps, segment[@"__key"], segment[@"__title"], segment[@"bundle_id"], overlap);
    }

    NSArray *sorted = SortedAppsBySeconds(apps);
    NSMutableArray *topSummaries = [NSMutableArray array];
    double listed = 0;
    for (NSInteger i = 0; i < MIN(3, sorted.count); i++) {
        NSDictionary *app = sorted[i];
        double seconds = [app[@"seconds"] doubleValue];
        listed += seconds;
        [topSummaries addObject:@{
            @"title": app[@"title"] ?: @"未知",
            @"key": app[@"key"] ?: @"unknown",
            @"bundle_id": app[@"bundle_id"] ?: @"",
            @"seconds": @(seconds),
            @"ratio": @(observed > 0 ? seconds / observed : 0)
        }];
    }
    double other = observed - listed;
    if (other > 1.0 && sorted.count > 3) {
        [topSummaries addObject:@{
            @"title": @"其他",
            @"key": @"__other__",
            @"bundle_id": @"__other__",
            @"seconds": @(other),
            @"ratio": @(observed > 0 ? other / observed : 0)
        }];
    }
    return topSummaries;
}

static void AddCalendarBlockIfEligible(NSMutableArray *blocks,
                                       NSMutableDictionary *block,
                                       NSArray<NSMutableDictionary *> *rawSegments,
                                       double minDuration) {
    if (!block) {
        return;
    }
    NSDate *start = block[@"start"];
    NSDate *end = block[@"end"];
    double wall = [end timeIntervalSinceDate:start];
    if (wall < minDuration) {
        return;
    }
    double observed = [block[@"observed_seconds"] doubleValue];
    block[@"wall_seconds"] = @(wall);
    block[@"active_ratio"] = @(wall > 0 ? MIN(1.0, observed / wall) : 0);
    block[@"top_apps"] = TopAppsForInterval(rawSegments, start, end);
    [blocks addObject:block];
}

static NSArray *CalendarCandidatesFromSegments(NSArray<NSMutableDictionary *> *segments) {
    NSArray<NSMutableDictionary *> *smoothedSegments = SegmentsWithAbsorbedShortInterruptions(segments);
    NSDictionary<NSNumber *, NSMutableDictionary *> *buckets = MinuteBucketsFromSegments(smoothedSegments);
    NSMutableDictionary<NSNumber *, NSMutableDictionary *> *assignments = [NSMutableDictionary dictionary];
    NSArray *minuteKeys = [buckets.allKeys sortedArrayUsingSelector:@selector(compare:)];
    NSTimeInterval windowSeconds = CalendarWindowSecondsSetting();
    NSTimeInterval windowHitSeconds = windowSeconds * (2.0 / 3.0);

    for (NSNumber *minuteKey in minuteKeys) {
        NSMutableDictionary *bucket = buckets[minuteKey];
        double observedSeconds = [bucket[@"observed_seconds"] doubleValue];
        if (observedSeconds < 40.0) {
            continue;
        }
        NSArray *sorted = SortedAppsBySeconds(bucket[@"apps"]);
        NSDictionary *dominant = sorted.firstObject;
        if (!dominant) {
            continue;
        }
        double active = [dominant[@"seconds"] doubleValue];
        double ratio = observedSeconds > 0 ? active / observedSeconds : 0;
        NSString *kind = (active >= 40.0 || ratio >= 0.65) ? @"app" : @"mixed";
        double assigned = [kind isEqualToString:@"app"] ? active : observedSeconds;
        double score = [kind isEqualToString:@"app"] ? active : observedSeconds;
        assignments[minuteKey] = AssignmentForMinute(minuteKey, dominant, kind, @"1分钟", assigned, observedSeconds, score);
    }

    if (minuteKeys.count > 0) {
        double firstMinute = [minuteKeys.firstObject doubleValue];
        double lastMinute = [minuteKeys.lastObject doubleValue];
        for (double windowStart = firstMinute; windowStart <= lastMinute; windowStart += 60.0) {
            NSMutableDictionary<NSString *, NSMutableDictionary *> *windowApps = [NSMutableDictionary dictionary];
            double observed = 0;
            for (double minuteStart = windowStart; minuteStart < windowStart + windowSeconds; minuteStart += 60.0) {
                NSMutableDictionary *bucket = buckets[@(minuteStart)];
                if (!bucket) {
                    continue;
                }
                observed += [bucket[@"observed_seconds"] doubleValue];
                for (NSDictionary *app in [bucket[@"apps"] allValues]) {
                    AddSecondsToApps(windowApps, app[@"key"], app[@"title"], app[@"bundle_id"], [app[@"seconds"] doubleValue]);
                }
            }
            if (observed < windowHitSeconds) {
                continue;
            }

            NSArray *sorted = SortedAppsBySeconds(windowApps);
            NSDictionary *dominant = sorted.firstObject;
            if (!dominant) {
                continue;
            }
            double dominantSeconds = [dominant[@"seconds"] doubleValue];
            double dominantRatio = observed > 0 ? dominantSeconds / observed : 0;
            NSString *kind = (dominantSeconds >= windowHitSeconds || dominantRatio >= 0.65) ? @"app" : @"mixed";

            for (double minuteStart = windowStart; minuteStart < windowStart + windowSeconds; minuteStart += 60.0) {
                NSNumber *minuteKey = @(minuteStart);
                NSMutableDictionary *bucket = buckets[minuteKey];
                if (!bucket || [bucket[@"observed_seconds"] doubleValue] <= 0) {
                    continue;
                }
                NSDictionary *minuteApp = [bucket[@"apps"] objectForKey:dominant[@"key"]];
                double minuteObserved = [bucket[@"observed_seconds"] doubleValue];
                double assigned = [kind isEqualToString:@"app"] ? [minuteApp[@"seconds"] doubleValue] : minuteObserved;
                double score = [kind isEqualToString:@"app"] ? dominantSeconds : observed;
                NSString *mode = [NSString stringWithFormat:@"%.0f分钟", windowSeconds / 60.0];
                NSMutableDictionary *claim = AssignmentForMinute(minuteKey, dominant, kind, mode, assigned, minuteObserved, score);
                if (ShouldReplaceAssignment(assignments[minuteKey], claim)) {
                    assignments[minuteKey] = claim;
                }
            }
        }
    }

    NSMutableArray *blocks = [NSMutableArray array];
    NSMutableDictionary *current = nil;
    NSArray *assignedKeys = [assignments.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSNumber *minuteKey in assignedKeys) {
        NSDictionary *minute = assignments[minuteKey];
        BOOL canMerge = current &&
            [current[@"key"] isEqualToString:minute[@"key"]] &&
            fabs([minute[@"start"] timeIntervalSinceDate:current[@"end"]]) < 0.001;
        if (canMerge) {
            current[@"end"] = minute[@"end"];
            current[@"active_seconds"] = @([current[@"active_seconds"] doubleValue] + [minute[@"active_seconds"] doubleValue]);
            current[@"observed_seconds"] = @([current[@"observed_seconds"] doubleValue] + [minute[@"observed_seconds"] doubleValue]);
            current[@"minute_count"] = @([current[@"minute_count"] integerValue] + 1);
            if (![current[@"mode"] isEqualToString:minute[@"mode"]]) {
                current[@"mode"] = @"混合规则";
            }
        } else {
            AddCalendarBlockIfEligible(blocks, current, segments, CalendarMinBlockSecondsSetting());
            current = [@{
                @"start": minute[@"start"],
                @"end": minute[@"end"],
                @"active_seconds": minute[@"active_seconds"],
                @"observed_seconds": minute[@"observed_seconds"],
                @"key": minute[@"key"],
                @"bundle_id": minute[@"bundle_id"],
                @"title": minute[@"title"],
                @"kind": minute[@"kind"],
                @"minute_count": @1,
                @"mode": minute[@"mode"]
            } mutableCopy];
        }
    }
    AddCalendarBlockIfEligible(blocks, current, segments, CalendarMinBlockSecondsSetting());
    return blocks;
}

static NSArray *MixedBlocksFromSegments(NSArray<NSMutableDictionary *> *segments) {
    if (segments.count == 0) {
        return @[];
    }
    NSTimeInterval visualWindow = 600.0;
    NSInteger visualMinutes = 10;
    NSDate *start = segments.firstObject[@"__start"];
    NSDate *end = segments.lastObject[@"__end"];
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDateComponents *components = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitHour | NSCalendarUnitMinute fromDate:start];
    components.minute = (components.minute / visualMinutes) * visualMinutes;
    components.second = 0;
    NSDate *cursorDate = [calendar dateFromComponents:components];
    NSTimeInterval cursor = cursorDate.timeIntervalSince1970;
    NSTimeInterval endTime = end.timeIntervalSince1970;
    NSMutableArray *blocks = [NSMutableArray array];

    while (cursor < endTime) {
        NSTimeInterval windowEnd = cursor + visualWindow;
        NSMutableDictionary<NSString *, NSMutableDictionary *> *apps = [NSMutableDictionary dictionary];
        double observed = 0;

        for (NSDictionary *segment in segments) {
            NSTimeInterval s = [segment[@"__start"] timeIntervalSince1970];
            NSTimeInterval e = [segment[@"__end"] timeIntervalSince1970];
            NSTimeInterval overlap = MAX(0, MIN(e, windowEnd) - MAX(s, cursor));
            if (overlap <= 0) {
                continue;
            }
            observed += overlap;
            NSString *key = segment[@"__key"];
            if (!apps[key]) {
                apps[key] = [@{
                    @"key": key,
                    @"title": segment[@"__title"] ?: @"",
                    @"bundle_id": segment[@"bundle_id"] ?: @"",
                    @"seconds": @0.0
                } mutableCopy];
            }
            apps[key][@"seconds"] = @([apps[key][@"seconds"] doubleValue] + overlap);
        }

        if (observed > 20) {
            NSArray *top = [apps.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                return [b[@"seconds"] compare:a[@"seconds"]];
            }];
            NSMutableArray *topSummaries = [NSMutableArray array];
            for (NSInteger i = 0; i < MIN(3, top.count); i++) {
                NSDictionary *app = top[i];
                [topSummaries addObject:@{
                    @"title": app[@"title"],
                    @"key": app[@"key"],
                    @"bundle_id": app[@"bundle_id"],
                    @"seconds": app[@"seconds"],
                    @"ratio": @([app[@"seconds"] doubleValue] / observed)
                }];
            }
            NSDictionary *dominant = top.firstObject;
            [blocks addObject:@{
                @"start": [NSDate dateWithTimeIntervalSince1970:cursor],
                @"end": [NSDate dateWithTimeIntervalSince1970:windowEnd],
                @"wall_seconds": @(visualWindow),
                @"active_seconds": @(observed),
                @"active_ratio": @(observed / visualWindow),
                @"title": @"混合时间",
                @"key": @"__mixed__",
                @"bundle_id": @"__mixed__",
                @"mode": @"碎片",
                @"granularity": @"10分钟",
                @"top_apps": topSummaries,
                @"dominant_key": dominant[@"key"] ?: @""
            }];
        }
        cursor += visualWindow;
    }
    return blocks;
}

static BOOL IsMixedActivityVisualBlock(NSDictionary *block) {
    return [block[@"visual_layer"] isEqualToString:@"activity"] &&
           [block[@"key"] isEqualToString:@"__mixed__"];
}

static NSMutableDictionary *MergedMixedActivityBlock(NSDictionary *left,
                                                     NSDictionary *right,
                                                     NSArray<NSMutableDictionary *> *segments) {
    NSDate *start = left[@"start"];
    NSDate *end = right[@"end"];
    if (!start || !end || [end compare:start] != NSOrderedDescending) {
        return [left mutableCopy];
    }
    NSArray *topApps = TopAppsForInterval(segments, start, end);
    double observed = 0;
    for (NSDictionary *app in topApps) {
        observed += [app[@"seconds"] doubleValue];
    }
    double wall = [end timeIntervalSinceDate:start];
    NSMutableDictionary *merged = [left mutableCopy];
    merged[@"start"] = start;
    merged[@"end"] = end;
    merged[@"wall_seconds"] = @(wall);
    merged[@"active_seconds"] = @(observed);
    merged[@"observed_seconds"] = @(observed);
    merged[@"active_ratio"] = @(wall > 0 ? MIN(1.0, observed / wall) : 0);
    merged[@"top_apps"] = topApps;
    merged[@"granularity"] = @"合并";
    NSDictionary *dominant = topApps.firstObject;
    merged[@"dominant_key"] = dominant[@"key"] ?: @"";
    return merged;
}

static NSArray *MergeAdjacentMixedActivityBlocks(NSArray *blocks,
                                                 NSArray<NSMutableDictionary *> *segments) {
    if (blocks.count < 2) {
        return blocks ?: @[];
    }
    NSMutableArray *merged = [NSMutableArray array];
    for (NSDictionary *block in blocks) {
        NSMutableDictionary *previous = merged.lastObject;
        NSDate *previousEnd = previous[@"end"];
        NSDate *start = block[@"start"];
        BOOL canMerge = previous &&
            IsMixedActivityVisualBlock(previous) &&
            IsMixedActivityVisualBlock(block) &&
            previousEnd &&
            start &&
            fabs([start timeIntervalSinceDate:previousEnd]) <= MinimumRecordedSegmentSeconds();
        if (canMerge) {
            [merged removeLastObject];
            [merged addObject:MergedMixedActivityBlock(previous, block, segments)];
        } else {
            [merged addObject:[block mutableCopy]];
        }
    }
    return merged;
}

static NSString *GapTitleForReason(NSString *reason) {
    if ([reason isEqualToString:@"idle"]) {
        return @"空闲";
    }
    if ([reason containsString:@"sleep"]) {
        return @"睡眠";
    }
    if ([reason containsString:@"locked"]) {
        return @"锁屏";
    }
    if ([reason isEqualToString:@"ongoing-gap"]) {
        return @"当前空白";
    }
    return @"未记录";
}

static NSArray *GapBlocksFromSegments(NSArray<NSMutableDictionary *> *segments, NSDate *rangeEnd) {
    if (segments.count == 0) {
        return @[];
    }
    NSMutableArray *gaps = [NSMutableArray array];
    NSMutableArray *points = [segments mutableCopy];
    [points sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"__start"] compare:b[@"__start"]];
    }];

    for (NSInteger i = 0; i + 1 < points.count; i++) {
        NSDictionary *previous = points[i];
        NSDictionary *next = points[i + 1];
        NSDate *start = previous[@"__end"];
        NSDate *end = next[@"__start"];
        double gap = [end timeIntervalSinceDate:start];
        if (gap <= 10.0) {
            continue;
        }
        NSString *reason = previous[@"end_reason"] ?: @"gap";
        NSString *title = GapTitleForReason(reason);
        [gaps addObject:@{
            @"start": start,
            @"end": end,
            @"wall_seconds": @(gap),
            @"active_seconds": @0.0,
            @"observed_seconds": @0.0,
            @"active_ratio": @0.0,
            @"title": title,
            @"key": [NSString stringWithFormat:@"__gap_%@", reason],
            @"bundle_id": @"__gap__",
            @"kind": @"gap",
            @"mode": title,
            @"gap_reason": reason,
            @"visual_layer": @"activity"
        }];
    }

    NSDictionary *last = points.lastObject;
    if (rangeEnd && ![last[@"__ongoing"] boolValue]) {
        NSDate *start = last[@"__end"];
        double gap = [rangeEnd timeIntervalSinceDate:start];
        if (gap > 10.0 && [DayString(start) isEqualToString:DayString(rangeEnd)]) {
            NSString *reason = [last[@"end_reason"] isEqualToString:@"idle"] ? @"idle" : @"ongoing-gap";
            NSString *title = GapTitleForReason(reason);
            [gaps addObject:@{
                @"start": start,
                @"end": rangeEnd,
                @"wall_seconds": @(gap),
                @"active_seconds": @0.0,
                @"observed_seconds": @0.0,
                @"active_ratio": @0.0,
                @"title": title,
                @"key": [NSString stringWithFormat:@"__gap_%@", reason],
                @"bundle_id": @"__gap__",
                @"kind": @"gap",
                @"mode": title,
                @"gap_reason": reason,
                @"visual_layer": @"activity"
            }];
        }
    }
    return gaps;
}

static NSDictionary *OngoingBlockFromSegment(NSDictionary *segment) {
    if (![segment[@"__ongoing"] boolValue]) {
        return nil;
    }
    double wall = [segment[@"__end"] timeIntervalSinceDate:segment[@"__start"]];
    if (wall <= 0) {
        return nil;
    }
    return @{
        @"start": segment[@"__start"],
        @"end": segment[@"__end"],
        @"wall_seconds": @(wall),
        @"active_seconds": @(wall),
        @"observed_seconds": @(wall),
        @"active_ratio": @1.0,
        @"title": segment[@"__title"] ?: @"进行中",
        @"key": segment[@"__key"] ?: @"__ongoing__",
        @"bundle_id": segment[@"bundle_id"] ?: @"",
        @"kind": @"ongoing",
        @"mode": @"进行中",
        @"visual_layer": @"activity",
        @"top_apps": @[@{
            @"title": segment[@"__title"] ?: @"进行中",
            @"key": segment[@"__key"] ?: @"__ongoing__",
            @"bundle_id": segment[@"bundle_id"] ?: @"",
            @"seconds": @(wall),
            @"ratio": @1.0
        }]
    };
}

static NSString *CalendarBlockKeyForDates(NSDate *start, NSDate *end) {
    if (!start || !end) {
        return @"";
    }
    long long startSecond = llround([start timeIntervalSince1970]);
    long long endSecond = llround([end timeIntervalSince1970]);
    return [NSString stringWithFormat:@"%lld-%lld", startSecond, endSecond];
}

static NSString *CalendarBlockKeyForBlock(NSDictionary *block) {
    NSString *base = CalendarBlockKeyForDates(block[@"start"], block[@"end"]);
    if (base.length > 0 && [block[@"resident"] boolValue]) {
        NSString *suffix = block[@"key"] ?: block[@"resident_kind"] ?: @"resident";
        return [base stringByAppendingFormat:@"-%@", suffix];
    }
    return base;
}

static NSString *TrimmedUserText(NSString *value) {
    return [[value ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] copy];
}

static NSDictionary *AppWriteMappingForBlock(NSDictionary *block, NSDictionary *appWriteMappings) {
    NSString *appKey = block[@"key"];
    NSDictionary *mapping = appKey.length > 0 ? appWriteMappings[appKey] : nil;
    return [mapping isKindOfClass:NSDictionary.class] ? mapping : nil;
}

static NSArray *CalendarCandidatesWithState(NSArray *candidates,
                                            NSSet<NSString *> *existingKeys,
                                            NSSet<NSString *> *ignoredKeys,
                                            NSDictionary<NSString *, NSDictionary *> *appWriteMappings,
                                            NSDictionary<NSString *, NSString *> *projectLabels,
                                            NSDictionary<NSString *, NSString *> *blockTitles) {
    NSMutableArray *annotated = [NSMutableArray arrayWithCapacity:candidates.count];
    for (NSDictionary *candidate in candidates) {
        NSMutableDictionary *copy = [candidate mutableCopy];
        copy[@"visual_layer"] = @"calendar";
        NSDictionary *mapping = AppWriteMappingForBlock(copy, appWriteMappings ?: @{});
        NSString *mappedProject = mapping[@"project_title"];
        if (mappedProject.length > 0) {
            copy[@"project_title"] = mappedProject;
        }
        NSString *mappedTitle = mapping[@"event_title"];
        if (mappedTitle.length > 0) {
            copy[@"event_title"] = mappedTitle;
        }
        NSString *key = CalendarBlockKeyForBlock(copy);
        if (key.length > 0 && [ignoredKeys containsObject:key]) {
            continue;
        }
        if (key.length > 0) {
            copy[@"calendar_block_key"] = key;
            copy[@"calendar_confirmed"] = @([existingKeys containsObject:key]);
            NSString *project = projectLabels[key];
            if (project.length > 0) {
                copy[@"project_title"] = project;
            }
            NSString *customTitle = blockTitles[key];
            if (customTitle.length > 0) {
                copy[@"event_title"] = customTitle;
            }
        } else {
            copy[@"calendar_confirmed"] = @NO;
        }
        [annotated addObject:copy];
    }
    return annotated;
}

static NSArray *PendingCalendarCandidates(NSArray *candidates,
                                          NSSet<NSString *> *existingKeys,
                                          NSSet<NSString *> *ignoredKeys) {
    NSMutableArray *pending = [NSMutableArray array];
    for (NSDictionary *candidate in candidates) {
        NSString *key = CalendarBlockKeyForBlock(candidate);
        if (key.length > 0 && [ignoredKeys containsObject:key]) {
            continue;
        }
        if (key.length > 0 && [existingKeys containsObject:key]) {
            continue;
        }
        [pending addObject:candidate];
    }
    return pending;
}

static NSInteger PendingCalendarCandidateCount(NSArray *candidates) {
    NSInteger count = 0;
    for (NSDictionary *candidate in candidates) {
        if (![candidate[@"calendar_confirmed"] boolValue]) {
            count++;
        }
    }
    return count;
}

static NSInteger ConfirmedCalendarCandidateCount(NSArray *candidates) {
    NSInteger count = 0;
    for (NSDictionary *candidate in candidates) {
        if ([candidate[@"calendar_confirmed"] boolValue]) {
            count++;
        }
    }
    return count;
}

static NSArray *ManualCalendarCandidatesFromRecords(NSArray *records,
                                                    NSArray<NSMutableDictionary *> *segments,
                                                    NSDate *day) {
    if (![records isKindOfClass:NSArray.class] || records.count == 0) {
        return @[];
    }
    NSMutableArray *manualCandidates = [NSMutableArray array];
    NSString *targetDay = DayString(day ?: [NSDate date]);
    for (NSDictionary *record in records) {
        if (![record isKindOfClass:NSDictionary.class]) {
            continue;
        }
        NSDate *start = [ISOFormatter() dateFromString:record[@"start_at"]];
        NSDate *end = [ISOFormatter() dateFromString:record[@"end_at"]];
        if (!start || !end || ![DayString(start) isEqualToString:targetDay]) {
            continue;
        }
        double wall = [end timeIntervalSinceDate:start];
        if (wall < 60.0) {
            continue;
        }

        NSArray *topApps = TopAppsForInterval(segments ?: @[], start, end);
        double observed = 0;
        for (NSDictionary *app in topApps) {
            observed += [app[@"seconds"] doubleValue];
        }

        NSString *title = [record[@"title"] isKindOfClass:NSString.class] && [record[@"title"] length] > 0
            ? record[@"title"]
            : @"手动时段";
        NSString *key = @"__manual_block__";
        NSString *bundleID = @"__manual_block__";
        if (topApps.count > 0) {
            NSDictionary *first = topApps.firstObject;
            key = first[@"key"] ?: key;
            bundleID = first[@"bundle_id"] ?: bundleID;
        } else {
            topApps = @[@{
                @"title": title,
                @"key": key,
                @"bundle_id": bundleID,
                @"seconds": @(wall),
                @"ratio": @1.0
            }];
            observed = wall;
        }

        [manualCandidates addObject:@{
            @"start": start,
            @"end": end,
            @"wall_seconds": @(wall),
            @"active_seconds": @(observed),
            @"observed_seconds": @(observed),
            @"active_ratio": @(wall > 0 ? MIN(1.0, observed / wall) : 0),
            @"title": title,
            @"event_title": title,
            @"key": key,
            @"bundle_id": bundleID,
            @"kind": @"manual",
            @"mode": @"手动",
            @"manual_id": record[@"id"] ?: CalendarBlockKeyForDates(start, end),
            @"top_apps": topApps
        }];
    }
    [manualCandidates sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"start"] compare:b[@"start"]];
    }];
    return manualCandidates;
}

static NSMutableDictionary *ResidentMeetingCandidate(NSDate *start, NSDate *end) {
    return [@{
        @"start": start,
        @"end": end,
        @"key": ResidentMeetingBundleIdentifier,
        @"bundle_id": ResidentMeetingBundleIdentifier,
        @"title": ResidentMeetingDisplayName,
        @"event_title": ResidentMeetingDisplayName,
        @"kind": @"app",
        @"mode": @"常驻",
        @"resident": @YES,
        @"resident_kind": @"meeting"
    } mutableCopy];
}

static void AddResidentMeetingCandidateIfEligible(NSMutableArray *blocks,
                                                  NSMutableDictionary *block,
                                                  double minDuration) {
    if (!block) {
        return;
    }
    NSDate *start = block[@"start"];
    NSDate *end = block[@"end"];
    double wall = [end timeIntervalSinceDate:start];
    if (wall < minDuration) {
        return;
    }
    block[@"wall_seconds"] = @(wall);
    block[@"active_seconds"] = @(wall);
    block[@"observed_seconds"] = @(wall);
    block[@"active_ratio"] = @1.0;
    block[@"top_apps"] = @[@{
        @"title": ResidentMeetingDisplayName,
        @"key": ResidentMeetingBundleIdentifier,
        @"bundle_id": ResidentMeetingBundleIdentifier,
        @"seconds": @(wall),
        @"ratio": @1.0
    }];
    [blocks addObject:block];
}

static NSArray *ResidentMeetingCandidatesFromSegments(NSArray<NSMutableDictionary *> *residentSegments) {
    if (residentSegments.count == 0) {
        return @[];
    }

    NSMutableArray *blocks = [NSMutableArray array];
    NSMutableDictionary *current = nil;
    NSTimeInterval mergeGap = MAX(5.0, MinimumRecordedSegmentSeconds());
    for (NSDictionary *segment in residentSegments) {
        BOOL isMeeting = [segment[@"resident_kind"] isEqualToString:@"meeting"] ||
                         [segment[@"bundle_id"] isEqualToString:ResidentMeetingBundleIdentifier];
        if (!isMeeting) {
            continue;
        }
        NSDate *start = segment[@"__start"];
        NSDate *end = segment[@"__end"];
        if (!start || !end || [end timeIntervalSinceDate:start] <= MinimumRecordedSegmentSeconds()) {
            continue;
        }

        if (current) {
            double gap = [start timeIntervalSinceDate:current[@"end"]];
            if (gap >= -0.001 && gap <= mergeGap) {
                current[@"end"] = [end compare:current[@"end"]] == NSOrderedDescending ? end : current[@"end"];
                continue;
            }
            AddResidentMeetingCandidateIfEligible(blocks, current, CalendarMinBlockSecondsSetting());
        }
        current = ResidentMeetingCandidate(start, end);
    }
    AddResidentMeetingCandidateIfEligible(blocks, current, CalendarMinBlockSecondsSetting());
    return blocks;
}

static NSArray *CalendarCandidatesIncludingManual(NSArray<NSMutableDictionary *> *segments,
                                                  NSArray<NSMutableDictionary *> *residentSegments,
                                                  NSArray *manualRecords,
                                                  NSDate *day) {
    NSMutableArray *candidates = [CalendarCandidatesFromSegments(segments ?: @[]) mutableCopy] ?: [NSMutableArray array];
    [candidates addObjectsFromArray:ResidentMeetingCandidatesFromSegments(residentSegments ?: @[])];
    [candidates addObjectsFromArray:ManualCalendarCandidatesFromRecords(manualRecords, segments ?: @[], day ?: [NSDate date])];
    [candidates sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult result = [a[@"start"] compare:b[@"start"]];
        if (result != NSOrderedSame) {
            return result;
        }
        return [a[@"end"] compare:b[@"end"]];
    }];
    return candidates;
}

static NSArray *VisualBlocksFromSegments(NSArray<NSMutableDictionary *> *segments, NSArray *candidates, NSDate *rangeEnd) {
    NSMutableArray *visual = [NSMutableArray array];
    NSArray *mixed = MixedBlocksFromSegments(segments);
    for (NSDictionary *mixedBlock in mixed) {
        NSMutableArray<NSDictionary *> *visibleRanges = [NSMutableArray arrayWithObject:@{
            @"start": mixedBlock[@"start"],
            @"end": mixedBlock[@"end"]
        }];
        for (NSDictionary *candidate in candidates) {
            NSDate *candidateStart = candidate[@"start"];
            NSDate *candidateEnd = candidate[@"end"];
            NSMutableArray<NSDictionary *> *nextRanges = [NSMutableArray array];
            for (NSDictionary *range in visibleRanges) {
                NSDate *rangeStart = range[@"start"];
                NSDate *rangeEnd = range[@"end"];
                BOOL overlaps = [rangeStart compare:candidateEnd] == NSOrderedAscending &&
                                [rangeEnd compare:candidateStart] == NSOrderedDescending;
                if (!overlaps) {
                    [nextRanges addObject:range];
                    continue;
                }
                NSDate *leftEnd = [candidateStart compare:rangeEnd] == NSOrderedAscending ? candidateStart : rangeEnd;
                NSDate *rightStart = [candidateEnd compare:rangeStart] == NSOrderedDescending ? candidateEnd : rangeStart;
                if ([leftEnd timeIntervalSinceDate:rangeStart] > MinimumRecordedSegmentSeconds()) {
                    [nextRanges addObject:@{@"start": rangeStart, @"end": leftEnd}];
                }
                if ([rangeEnd timeIntervalSinceDate:rightStart] > MinimumRecordedSegmentSeconds()) {
                    [nextRanges addObject:@{@"start": rightStart, @"end": rangeEnd}];
                }
            }
            visibleRanges = nextRanges;
            if (visibleRanges.count == 0) {
                break;
            }
        }

        for (NSDictionary *range in visibleRanges) {
            NSDate *rangeStart = range[@"start"];
            NSDate *rangeEnd = range[@"end"];
            double wall = [rangeEnd timeIntervalSinceDate:rangeStart];
            if (wall <= MinimumRecordedSegmentSeconds()) {
                continue;
            }
            NSArray *topApps = TopAppsForInterval(segments, rangeStart, rangeEnd);
            double observed = 0;
            for (NSDictionary *app in topApps) {
                observed += [app[@"seconds"] doubleValue];
            }
            if (observed <= MinimumRecordedSegmentSeconds()) {
                continue;
            }
            NSMutableDictionary *partial = [mixedBlock mutableCopy];
            partial[@"start"] = rangeStart;
            partial[@"end"] = rangeEnd;
            partial[@"wall_seconds"] = @(wall);
            partial[@"active_seconds"] = @(observed);
            partial[@"observed_seconds"] = @(observed);
            partial[@"active_ratio"] = @(wall > 0 ? MIN(1.0, observed / wall) : 0);
            partial[@"top_apps"] = topApps;
            partial[@"granularity"] = wall >= 590 ? @"10分钟" : @"补足";
            partial[@"visual_layer"] = @"activity";
            [visual addObject:partial];
        }
    }
    NSArray *mergedMixed = MergeAdjacentMixedActivityBlocks(visual, segments);
    visual = [mergedMixed mutableCopy];

    [visual addObjectsFromArray:GapBlocksFromSegments(segments, rangeEnd ?: [NSDate date])];
    for (NSDictionary *segment in segments) {
        NSDictionary *ongoing = OngoingBlockFromSegment(segment);
        if (ongoing) {
            [visual addObject:ongoing];
        }
    }

    for (NSDictionary *candidate in candidates) {
        NSMutableDictionary *copy = [candidate mutableCopy];
        copy[@"visual_layer"] = @"calendar";
        [visual addObject:copy];
    }
    [visual sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult result = [a[@"start"] compare:b[@"start"]];
        if (result != NSOrderedSame) {
            return result;
        }
        NSString *leftLayer = a[@"visual_layer"] ?: @"";
        NSString *rightLayer = b[@"visual_layer"] ?: @"";
        return [leftLayer compare:rightLayer];
    }];
    return visual;
}

static NSDictionary *DashboardStats(SegmentStore *store,
                                    NSDate *displayDate,
                                    NSDictionary *openSegment,
                                    NSDictionary *openResidentSegment,
                                    NSSet<NSString *> *existingCalendarKeys,
                                    NSSet<NSString *> *ignoredCalendarKeys,
                                    NSDictionary<NSString *, NSDictionary *> *appWriteMappings,
                                    NSDictionary<NSString *, NSString *> *projectLabels,
                                    NSDictionary<NSString *, NSString *> *blockTitles,
                                    NSArray *manualRecords) {
    NSDate *selectedStart = CalendarStartOfDay(displayDate ?: [NSDate date]);
    NSDate *selectedEnd = DateByAddingDays(selectedStart, 1);
    NSDate *todayStart = CalendarStartOfDay([NSDate date]);
    NSDate *tomorrowStart = DateByAddingDays(todayStart, 1);
    BOOL selectedIsToday = SameDay(selectedStart, todayStart);
    NSDate *visibleRangeEnd = selectedIsToday ? [NSDate date] : selectedEnd;
    NSMutableArray<NSMutableDictionary *> *segments = [ReadSegmentsForRange(store, selectedStart, selectedEnd, selectedIsToday ? openSegment : nil) mutableCopy];
    NSMutableArray<NSMutableDictionary *> *residentSegments = [ReadResidentSegmentsForRange(store, selectedStart, selectedEnd, selectedIsToday ? openResidentSegment : nil) mutableCopy];

    NSDate *start = nil;
    NSDate *end = nil;

    for (NSMutableDictionary *segment in segments) {
        if (!start || [segment[@"__start"] compare:start] == NSOrderedAscending) {
            start = segment[@"__start"];
        }
        if (!end || [segment[@"__end"] compare:end] == NSOrderedDescending) {
            end = segment[@"__end"];
        }
    }

    NSDictionary *todaySummary = AppSummaryFromSegments(segments);
    NSArray *topApps = todaySummary[@"top_apps"] ?: @[];
    NSArray *recent = [[segments reverseObjectEnumerator] allObjects];
    if (recent.count > 6) {
        recent = [recent subarrayWithRange:NSMakeRange(0, 6)];
    }

    NSDate *weekStart = StartOfWeekForDate(selectedStart);
    NSDate *scopeEnd = EarlierDate(selectedEnd, tomorrowStart);
    NSDate *weekEnd = EarlierDate(DateByAddingDays(weekStart, 7), scopeEnd);
    NSDate *monthStart = StartOfMonthForDate(selectedStart);
    NSDate *monthEnd = EarlierDate(EndOfMonthForDate(selectedStart), scopeEnd);
    NSArray *weekSegments = ReadSegmentsForRange(store, weekStart, weekEnd, selectedIsToday ? openSegment : nil);
    NSArray *monthSegments = ReadSegmentsForRange(store, monthStart, monthEnd, selectedIsToday ? openSegment : nil);
    NSString *dayScopeTitle = selectedIsToday ? @"今日" : @"当日";
    NSArray *scopeStats = @[
        ScopeSummary(dayScopeTitle, selectedStart, selectedEnd, segments),
        ScopeSummary(@"本周", weekStart, weekEnd, weekSegments),
        ScopeSummary(@"本月", monthStart, monthEnd, monthSegments)
    ];

    NSArray *candidates = CalendarCandidatesWithState(CalendarCandidatesIncludingManual(segments, residentSegments, manualRecords, selectedStart),
                                                      existingCalendarKeys ?: [NSSet set],
                                                      ignoredCalendarKeys ?: [NSSet set],
                                                      appWriteMappings ?: @{},
                                                      projectLabels ?: @{},
                                                      blockTitles ?: @{});
    NSMutableSet<NSString *> *projectSet = [NSMutableSet set];
    for (NSString *project in (projectLabels ?: @{}).allValues) {
        if (project.length > 0) {
            [projectSet addObject:project];
        }
    }
    for (NSDictionary *mapping in (appWriteMappings ?: @{}).allValues) {
        if (![mapping isKindOfClass:NSDictionary.class]) {
            continue;
        }
        NSString *project = mapping[@"project_title"];
        if (project.length > 0) {
            [projectSet addObject:project];
        }
    }
    NSArray *projectLabelList = [projectSet.allObjects sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    return @{
        @"segments": segments,
        @"resident_segments": residentSegments,
        @"top_apps": topApps,
        @"recent": recent,
        @"candidates": candidates,
        @"visual_blocks": VisualBlocksFromSegments(segments, candidates, visibleRangeEnd),
        @"scope_stats": scopeStats,
        @"project_labels": projectLabelList,
        @"pending_candidate_count": @(PendingCalendarCandidateCount(candidates)),
        @"confirmed_candidate_count": @(ConfirmedCalendarCandidateCount(candidates)),
        @"total_seconds": todaySummary[@"total_seconds"] ?: @0,
        @"segment_count": @(segments.count + residentSegments.count),
        @"foreground_segment_count": @(segments.count),
        @"resident_segment_count": @(residentSegments.count),
        @"display_date": selectedStart,
        @"date_title": DashboardDateTitle(selectedStart),
        @"date_subtitle": DashboardDateSubtitle(selectedStart),
        @"day_scope_title": dayScopeTitle,
        @"is_today": @(selectedIsToday),
        @"start": start ?: selectedStart,
        @"end": end ?: visibleRangeEnd
    };
}

static NSDate *StartOfDay(NSDate *date) {
    return [[NSCalendar currentCalendar] startOfDayForDate:date ?: [NSDate date]];
}

static NSDate *DateBySnappingToMinutes(NSDate *date, NSInteger minutes) {
    if (!date || minutes <= 0) {
        return date;
    }
    NSTimeInterval interval = minutes * 60.0;
    NSTimeInterval snapped = round(date.timeIntervalSince1970 / interval) * interval;
    return [NSDate dateWithTimeIntervalSince1970:snapped];
}

static NSString *GeneratedMarkerForDay(NSDate *day) {
    return [NSString stringWithFormat:@"%@:%@", GeneratedEventMarkerPrefix, DayString(StartOfDay(day))];
}

static NSString *GeneratedBlockMarkerForBlock(NSDictionary *block) {
    NSString *key = CalendarBlockKeyForBlock(block);
    return key.length ? [NSString stringWithFormat:@"%@:%@", GeneratedBlockMarkerPrefix, key] : @"";
}

static NSString *GeneratedBlockKeyFromNotes(NSString *notes) {
    if (notes.length == 0) {
        return @"";
    }
    NSString *prefix = [GeneratedBlockMarkerPrefix stringByAppendingString:@":"];
    for (NSString *line in [notes componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        if ([line hasPrefix:prefix]) {
            return [line substringFromIndex:prefix.length];
        }
    }
    return @"";
}

static NSString *CalendarEventTitleForBlock(NSDictionary *block) {
    NSString *override = block[@"event_title"];
    if (override.length > 0) {
        return override;
    }
    if ([block[@"kind"] isEqualToString:@"mixed"]) {
        return @"混合工作";
    }
    NSString *title = block[@"title"] ?: @"未知应用";
    return title;
}

static NSString *CalendarNotesForBlock(NSDictionary *block) {
    NSMutableArray *lines = [NSMutableArray array];
    [lines addObject:GeneratedMarkerForDay(block[@"start"])];
    NSString *blockMarker = GeneratedBlockMarkerForBlock(block);
    if (blockMarker.length > 0) {
        [lines addObject:blockMarker];
    }
    [lines addObject:@"由 Gotowork 生成"];
    [lines addObject:CalendarRuleSummary()];
    [lines addObject:[NSString stringWithFormat:@"时间：%@-%@", ClockString(block[@"start"]), ClockString(block[@"end"])]];
    [lines addObject:[NSString stringWithFormat:@"活跃：%@ / 日历块：%@",
                      ShortDuration([block[@"observed_seconds"] doubleValue]),
                      ShortDuration([block[@"wall_seconds"] doubleValue])]];
    NSString *project = block[@"project_title"];
    if (project.length > 0) {
        [lines addObject:[NSString stringWithFormat:@"项目：%@", project]];
    }

    NSArray *topApps = block[@"top_apps"] ?: @[];
    if (topApps.count > 0) {
        [lines addObject:@"应用占比："];
        for (NSDictionary *app in topApps) {
            [lines addObject:[NSString stringWithFormat:@"%@ %.0f%% (%@)",
                              app[@"title"] ?: @"未知",
                              [app[@"ratio"] doubleValue] * 100.0,
                              ShortDuration([app[@"seconds"] doubleValue])]];
        }
    }
    return [lines componentsJoinedByString:@"\n"];
}

static BOOL CalendarStatusAllowsFullAccess(EKAuthorizationStatus status) {
    return (NSInteger)status == 3;
}

@interface DashboardView : NSView <NSTextFieldDelegate>
@property(nonatomic, strong) NSDictionary *stats;
@property(nonatomic) BOOL recording;
@property(nonatomic, copy) NSString *statusText;
@property(nonatomic, strong) NSTrackingArea *trackingArea;
@property(nonatomic, strong) NSDictionary *hoveredBlock;
@property(nonatomic, strong) NSDictionary *selectedBlock;
@property(nonatomic, copy) NSString *highlightedAppKey;
@property(nonatomic, copy) NSString *selectedProjectFilter;
@property(nonatomic) NSInteger selectedScopeIndex;
@property(nonatomic, copy) NSString *activeColorEditKey;
@property(nonatomic) BOOL pendingPanelVisible;
@property(nonatomic) BOOL draggingManualBlock;
@property(nonatomic) BOOL manualDragMoved;
@property(nonatomic) NSPoint hoverPoint;
@property(nonatomic, strong) NSDate *manualDragStartDate;
@property(nonatomic, strong) NSDate *manualDragEndDate;
@property(nonatomic, strong) NSDictionary *manualDraftBlock;
@property(nonatomic, strong) NSDictionary *manualCreationBlock;
@property(nonatomic, strong) NSTextField *manualCreationTitleField;
@property(nonatomic, strong) NSButton *manualCreationSaveButton;
@property(nonatomic, strong) NSButton *manualCreationCancelButton;
@property(nonatomic, strong) NSDictionary *detailTitleEditBlock;
@property(nonatomic, strong) NSTextField *detailTitleEditField;
@property(nonatomic, strong) NSButton *detailTitleEditSaveButton;
@property(nonatomic, strong) NSButton *detailTitleEditCancelButton;
@property(nonatomic, strong) NSDictionary *detailProjectEditBlock;
@property(nonatomic, strong) NSTextField *detailProjectEditField;
@property(nonatomic, strong) NSButton *detailProjectEditSaveButton;
@property(nonatomic, strong) NSButton *detailProjectEditCancelButton;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *flashStartByBlockKey;
@property(nonatomic, strong) NSTimer *longPressTimer;
@property(nonatomic, strong) NSDictionary *longPressBlock;
@property(nonatomic) NSPoint longPressStartPoint;
@property(nonatomic) BOOL longPressTriggered;
@property(nonatomic) CGFloat timelineScrollY;
@property(nonatomic) BOOL timelineUserScrolled;
@property(nonatomic) NSInteger timelineAutoScrollSignature;
@property(nonatomic) NSTimeInterval timelineLoadAnimationStart;
@property(nonatomic) NSInteger timelineLoadAnimationSignature;
@property(nonatomic, weak) id actionTarget;
@property(nonatomic) NSTimeInterval pulseStart;
- (NSDictionary *)primaryDetailBlock;
- (NSDictionary *)pendingManualCreationBlock;
- (NSString *)pendingManualCreationTitle;
- (void)ensureManualCreationControls;
- (void)layoutManualCreationControls;
- (NSDictionary *)manualDraftBlockFromStart:(NSDate *)start end:(NSDate *)end;
- (NSDictionary *)pendingDetailTitleEditBlock;
- (NSString *)pendingDetailTitleEditText;
- (NSDictionary *)pendingDetailProjectEditBlock;
- (NSString *)pendingDetailProjectEditText;
- (void)reconcileInlineEditorsWithVisualBlocks:(NSArray *)visualBlocks;
- (void)drawPendingBannerInRect:(NSRect)rect;
- (void)drawCompactHoverLabelForBlock:(NSDictionary *)block nearRect:(NSRect)nearRect timelineRect:(NSRect)timelineRect;
- (void)drawSubtleStackedRatioBarForApps:(NSArray *)apps inRect:(NSRect)rect;
- (void)drawManualCreationPanel;
- (void)prepareTimelineForPresentation;
- (void)autoPositionTimelineIfNeeded;
- (void)noteTimelineSignature:(NSInteger)signature;
- (void)flashCalendarBlockKeys:(NSArray<NSString *> *)keys;
- (BOOL)hasActiveFlashes;
- (BOOL)hasActiveTimelineLoadAnimation;
@end

@implementation DashboardView
- (BOOL)isFlipped {
    return YES;
}

- (NSMutableDictionary<NSString *, NSNumber *> *)flashStartByBlockKey {
    if (!_flashStartByBlockKey) {
        _flashStartByBlockKey = [NSMutableDictionary dictionary];
    }
    return _flashStartByBlockKey;
}

- (void)prepareTimelineForPresentation {
    self.timelineUserScrolled = NO;
    self.timelineAutoScrollSignature = 0;
}

- (void)autoPositionTimelineIfNeeded {
    NSDictionary *layout = [self timelineLayoutInRect:[self timelineRect]];
    if (!layout) {
        return;
    }
    NSDate *rangeStart = layout[@"range_start"];
    NSDate *rangeEnd = layout[@"range_end"];
    CGFloat gridHeight = [layout[@"grid_height"] doubleValue];
    CGFloat visibleGridHeight = [layout[@"visible_grid_height"] doubleValue];
    CGFloat maxScroll = [layout[@"max_scroll"] doubleValue];
    NSInteger signature = ((NSInteger)llround(rangeStart.timeIntervalSince1970 / 3600.0)) * 31 +
                          ((NSInteger)llround(rangeEnd.timeIntervalSince1970 / 3600.0));
    if (signature == self.timelineAutoScrollSignature) {
        return;
    }
    self.timelineAutoScrollSignature = signature;
    if (self.timelineUserScrolled || maxScroll <= 0.5) {
        self.timelineScrollY = MAX(0, MIN(self.timelineScrollY, maxScroll));
        return;
    }

    NSDate *focusDate = DashboardNow();
    NSDate *statsEnd = self.stats[@"end"];
    if ([focusDate compare:rangeStart] == NSOrderedAscending || [focusDate compare:rangeEnd] != NSOrderedAscending) {
        focusDate = [statsEnd isKindOfClass:NSDate.class] ? statsEnd : rangeEnd;
    }
    NSTimeInterval span = [rangeEnd timeIntervalSinceDate:rangeStart];
    CGFloat contentY = span > 0 ? ([focusDate timeIntervalSinceDate:rangeStart] / span) * gridHeight : 0;
    CGFloat target = contentY - visibleGridHeight * 0.70;
    self.timelineScrollY = MAX(0, MIN(maxScroll, target));
}

- (void)noteTimelineSignature:(NSInteger)signature {
    if (signature == self.timelineLoadAnimationSignature) {
        return;
    }
    self.timelineLoadAnimationSignature = signature;
    self.timelineLoadAnimationStart = [NSDate timeIntervalSinceReferenceDate];
    [self setNeedsDisplayInRect:[self timelineRect]];
}

- (BOOL)hasActiveTimelineLoadAnimation {
    if (self.timelineLoadAnimationStart <= 0) {
        return NO;
    }
    return [NSDate timeIntervalSinceReferenceDate] - self.timelineLoadAnimationStart < 0.46;
}

- (void)flashCalendarBlockKeys:(NSArray<NSString *> *)keys {
    if (keys.count == 0) {
        return;
    }
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    for (NSString *key in keys) {
        if (key.length > 0) {
            self.flashStartByBlockKey[key] = @(now);
        }
    }
    [self setNeedsDisplay:YES];
}

- (CGFloat)flashAlphaForBlock:(NSDictionary *)block {
    NSString *key = CalendarBlockKeyForBlock(block);
    NSNumber *start = key.length > 0 ? self.flashStartByBlockKey[key] : nil;
    if (!start) {
        return 0;
    }
    NSTimeInterval age = [NSDate timeIntervalSinceReferenceDate] - start.doubleValue;
    if (age >= 1.1) {
        [self.flashStartByBlockKey removeObjectForKey:key];
        return 0;
    }
    CGFloat envelope = MAX(0, 1.0 - age / 1.1);
    CGFloat pulse = sin(MIN(1.0, age / 0.55) * M_PI);
    return 0.10 + 0.52 * envelope * MAX(0.25, pulse);
}

- (BOOL)hasActiveFlashes {
    if (_flashStartByBlockKey.count == 0) {
        return NO;
    }
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSMutableArray *expired = [NSMutableArray array];
    for (NSString *key in _flashStartByBlockKey) {
        if (now - _flashStartByBlockKey[key].doubleValue >= 1.1) {
            [expired addObject:key];
        }
    }
    [_flashStartByBlockKey removeObjectsForKeys:expired];
    return _flashStartByBlockKey.count > 0;
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    self.window.acceptsMouseMovedEvents = YES;
    if (self.pulseStart <= 0) {
        self.pulseStart = [NSDate timeIntervalSinceReferenceDate];
    }
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self setNeedsDisplay:YES];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.trackingArea) {
        [self removeTrackingArea:self.trackingArea];
    }
    NSTrackingAreaOptions options = NSTrackingMouseMoved |
                                   NSTrackingMouseEnteredAndExited |
                                   NSTrackingActiveAlways |
                                   NSTrackingInVisibleRect;
    self.trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                     options:options
                                                       owner:self
                                                    userInfo:nil];
    [self addTrackingArea:self.trackingArea];
}

- (NSRect)timelineRect {
    NSRect sidebar = [self sidebarRect];
    NSRect detail = [self detailRect];
    CGFloat x = NSMaxX(sidebar) + 22;
    return NSMakeRect(x, 76, detail.origin.x - x - 22, self.bounds.size.height - 104);
}

- (NSRect)sidebarRect {
    return NSMakeRect(22, 76, 214, self.bounds.size.height - 104);
}

- (NSRect)detailRect {
    CGFloat width = 320;
    return NSMakeRect(self.bounds.size.width - width - 22, 76, width, self.bounds.size.height - 104);
}

- (NSRect)pendingBannerRect {
    NSRect timeline = [self timelineRect];
    CGFloat width = 178;
    return NSMakeRect(NSMaxX(timeline) - width - 16, timeline.origin.y + 10, width, 28);
}

- (NSRect)topToggleButtonRect {
    NSRect status = [self topRecordingStatusRect];
    return NSMakeRect(status.origin.x - 78, status.origin.y + 1, 64, status.size.height - 2);
}

- (NSRect)topMoreButtonRect {
    return NSMakeRect(self.bounds.size.width - 54, 22, 32, 28);
}

- (NSRect)topRecordingStatusRect {
    NSRect more = [self topMoreButtonRect];
    return NSMakeRect(more.origin.x - 126, 21, 112, 30);
}

- (NSRect)sidebarDatePreviousRect {
    NSRect rect = [self sidebarRect];
    return NSMakeRect(NSMaxX(rect) - 66, rect.origin.y + 17, 24, 24);
}

- (NSRect)sidebarDateNextRect {
    NSRect rect = [self sidebarRect];
    return NSMakeRect(NSMaxX(rect) - 36, rect.origin.y + 17, 24, 24);
}

- (NSRect)scopeChipRectAtIndex:(NSInteger)index {
    NSRect rect = [self sidebarRect];
    CGFloat gap = 4;
    CGFloat width = (rect.size.width - 32 - gap * 2) / 3.0;
    return NSMakeRect(rect.origin.x + 16 + index * (width + gap), rect.origin.y + 112, width, 26);
}

- (NSRect)projectChipRectAtIndex:(NSInteger)index {
    NSRect rect = [self sidebarRect];
    CGFloat x = rect.origin.x + 16;
    CGFloat y = rect.origin.y + 166;
    if (index == 0) {
        return NSMakeRect(x, y, 68, 26);
    }
    NSArray *projects = self.stats[@"project_labels"] ?: @[];
    NSString *label = index - 1 < projects.count ? projects[index - 1] : @"项目";
    CGFloat width = MIN(rect.size.width - 32, MAX(72, label.length * 13 + 28));
    return NSMakeRect(x, y + index * 31, width, 26);
}

- (NSDictionary *)selectedSidebarScopeStats {
    NSArray *scopes = self.stats[@"scope_stats"] ?: @[];
    NSInteger index = MAX(0, MIN(self.selectedScopeIndex, (NSInteger)scopes.count - 1));
    if (index >= 0 && index < scopes.count) {
        return scopes[index];
    }
    return @{
        @"title": @"今日",
        @"range_label": @"",
        @"top_apps": self.stats[@"top_apps"] ?: @[],
        @"total_seconds": self.stats[@"total_seconds"] ?: @0,
        @"segment_count": self.stats[@"segment_count"] ?: @0
    };
}

- (CGFloat)sidebarAppListStartY {
    return [self sidebarAppSectionY] + 28;
}

- (CGFloat)sidebarAppSectionY {
    NSRect rect = [self sidebarRect];
    NSArray *projects = self.stats[@"project_labels"] ?: @[];
    NSInteger projectRows = 1 + MIN(3, (NSInteger)projects.count);
    CGFloat lastProjectMaxY = rect.origin.y + 166 + (projectRows - 1) * 31.0 + 26.0;
    return lastProjectMaxY + 24.0;
}

- (NSInteger)sidebarAppRowCapacity {
    NSRect rect = [self sidebarRect];
    CGFloat startY = [self sidebarAppListStartY];
    return MAX(3, (NSInteger)floor((NSMaxY(rect) - startY - 18) / 42.0));
}

- (NSRect)sidebarAppRowRectAtIndex:(NSInteger)index {
    NSRect rect = [self sidebarRect];
    CGFloat y = [self sidebarAppListStartY] + index * 42.0;
    return NSMakeRect(rect.origin.x + 6, y - 7, rect.size.width - 12, 34);
}

- (NSString *)appKeyAtSidebarPoint:(NSPoint)point {
    if (!NSPointInRect(point, [self sidebarRect])) {
        return nil;
    }
    NSArray *topApps = [self selectedSidebarScopeStats][@"top_apps"] ?: @[];
    NSInteger maxRows = MIN([self sidebarAppRowCapacity], (NSInteger)topApps.count);
    for (NSInteger i = 0; i < maxRows; i++) {
        if (NSPointInRect(point, [self sidebarAppRowRectAtIndex:i])) {
            NSString *key = topApps[i][@"key"];
            return key.length > 0 ? key : @"__other__";
        }
    }
    return nil;
}

- (NSString *)appKeyAtTimelineLegendPoint:(NSPoint)point {
    NSRect rect = [self timelineRect];
    if (!NSPointInRect(point, rect)) {
        return nil;
    }
    NSDictionary *layout = [self timelineLayoutInRect:rect];
    if (!layout) {
        return nil;
    }

    NSMutableParagraphStyle *truncate = [[NSMutableParagraphStyle alloc] init];
    truncate.lineBreakMode = NSLineBreakByTruncatingTail;
    NSDictionary *legendAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:10 weight:NSFontWeightMedium],
                                  NSForegroundColorAttributeName: MutedTextColor(),
                                  NSParagraphStyleAttributeName: truncate};
    NSArray *legendApps = [self selectedSidebarScopeStats][@"top_apps"] ?: self.stats[@"top_apps"] ?: @[];
    CGFloat x = [layout[@"calendar_left"] doubleValue] + 58.0;
    CGFloat y = rect.origin.y + 10.0;
    CGFloat maxX = NSMaxX(rect) - 16.0;
    for (NSInteger i = 0; i < MIN(4, legendApps.count); i++) {
        NSDictionary *app = legendApps[i];
        NSRect chip = TimelineLegendChipRect(app, x, y, maxX, legendAttrs);
        if (NSEqualRects(chip, NSZeroRect)) {
            break;
        }
        if (NSPointInRect(point, chip)) {
            NSString *key = app[@"key"];
            return key.length > 0 ? key : @"__other__";
        }
        x = NSMaxX(chip) + 6.0;
    }
    return nil;
}

- (NSArray *)pendingDashboardCandidates {
    NSMutableArray *pending = [NSMutableArray array];
    for (NSDictionary *candidate in self.stats[@"candidates"] ?: @[]) {
        if (![candidate[@"calendar_confirmed"] boolValue]) {
            [pending addObject:candidate];
        }
    }
    return pending;
}

- (NSRect)pendingPanelRect {
    NSArray *pending = [self pendingDashboardCandidates];
    NSRect sidebar = [self sidebarRect];
    NSRect detail = [self detailRect];
    CGFloat minX = NSMaxX(sidebar) + 12.0;
    CGFloat maxX = detail.origin.x - 12.0;
    CGFloat width = MIN(372.0, MAX(294.0, maxX - minX));
    CGFloat rows = MIN(5, pending.count);
    CGFloat height = 126 + rows * 58 + (pending.count > 5 ? 22 : 0);
    height = MAX(202, MIN(452, height));
    NSRect banner = [self pendingBannerRect];
    CGFloat x = MIN(NSMaxX([self timelineRect]) - width, banner.origin.x - 110);
    x = MAX(minX, MIN(x, maxX - width));
    return NSMakeRect(x, NSMaxY(banner) + 10, width, height);
}

- (NSRect)pendingPanelCloseRect {
    NSRect panel = [self pendingPanelRect];
    return NSMakeRect(NSMaxX(panel) - 42, panel.origin.y + 14, 28, 28);
}

- (NSRect)pendingPanelWriteRect {
    NSRect panel = [self pendingPanelRect];
    return NSMakeRect(NSMaxX(panel) - 134, NSMaxY(panel) - 48, 114, 32);
}

- (NSRect)pendingPanelRowRectAtIndex:(NSInteger)index {
    NSRect panel = [self pendingPanelRect];
    return NSMakeRect(panel.origin.x + 16, panel.origin.y + 74 + index * 58, panel.size.width - 32, 50);
}

- (NSRect)detailWriteButtonRect {
    NSRect action = [self detailActionAreaRect];
    return NSMakeRect(action.origin.x, action.origin.y + 2, action.size.width, 34);
}

- (NSRect)detailProjectButtonRect {
    NSRect action = [self detailActionAreaRect];
    return NSMakeRect(action.origin.x, action.origin.y + 46, (action.size.width - 10) / 2.0, 30);
}

- (NSRect)detailIgnoreButtonRect {
    NSRect action = [self detailActionAreaRect];
    CGFloat width = (action.size.width - 10) / 2.0;
    return NSMakeRect(action.origin.x + width + 10, action.origin.y + 46, width, 30);
}

- (NSRect)detailActionAreaRect {
    NSRect rect = [self detailRect];
    NSDictionary *block = [self primaryDetailBlock];
    NSArray *apps = block ? (block[@"top_apps"] ?: @[]) : (self.stats[@"top_apps"] ?: @[]);
    BOOL hasAppBreakdown = apps.count > 0;
    NSInteger detailRowCount = hasAppBreakdown ? MIN(5, (NSInteger)apps.count) : 0;
    CGFloat breakdownBottom = 0;
    if (hasAppBreakdown) {
        breakdownBottom = detailRowCount > 0
            ? NSMaxY([self detailAppRowRectAtIndex:detailRowCount - 1])
            : NSMaxY([self detailDonutRect]);
    } else {
        breakdownBottom = rect.origin.y + 216;
    }

    CGFloat contentBottom = breakdownBottom;
    if (block && [self detailBlockCanEditTitle:block]) {
        contentBottom += 20 + 58;
    }
    if ([self isEditingProjectForBlock:block]) {
        contentBottom += 58;
    }

    CGFloat y = MIN(NSMaxY(rect) - 98, contentBottom + 16);
    y = MAX(rect.origin.y + 372, y);
    return NSMakeRect(rect.origin.x + 18, y, rect.size.width - 36, 80);
}

- (NSRect)detailDonutRect {
    NSRect rect = [self detailRect];
    return NSMakeRect(rect.origin.x + 18, rect.origin.y + 146, 92, 92);
}

- (NSRect)detailRatioBarRect {
    NSRect rect = [self detailRect];
    return NSMakeRect(rect.origin.x + 124, rect.origin.y + 184, rect.size.width - 148, 8);
}

- (NSRect)detailAppRowRectAtIndex:(NSInteger)index {
    NSRect rect = [self detailRect];
    CGFloat y = rect.origin.y + 250 + index * 34;
    return NSMakeRect(rect.origin.x + 16, y, rect.size.width - 32, 30);
}

- (NSRect)detailRenameButtonRect {
    NSRect rect = [self detailRect];
    return NSMakeRect(NSMaxX(rect) - 64, rect.origin.y + 14, 46, 24);
}

- (BOOL)detailBlockCanEditTitle:(NSDictionary *)block {
    return [block[@"visual_layer"] isEqualToString:@"calendar"] && CalendarBlockKeyForBlock(block).length > 0;
}

- (BOOL)isEditingTitleForBlock:(NSDictionary *)block {
    NSString *editingKey = CalendarBlockKeyForBlock(self.detailTitleEditBlock);
    NSString *blockKey = CalendarBlockKeyForBlock(block);
    return editingKey.length > 0 && [editingKey isEqualToString:blockKey];
}

- (NSDictionary *)pendingDetailTitleEditBlock {
    return self.detailTitleEditBlock;
}

- (NSString *)pendingDetailTitleEditText {
    NSString *title = [self.detailTitleEditField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return title ?: @"";
}

- (void)ensureDetailTitleEditControls {
    if (!self.detailTitleEditField) {
        self.detailTitleEditField = [[NSTextField alloc] initWithFrame:NSZeroRect];
        self.detailTitleEditField.font = [NSFont systemFontOfSize:14 weight:NSFontWeightRegular];
        self.detailTitleEditField.bezeled = NO;
        self.detailTitleEditField.drawsBackground = NO;
        self.detailTitleEditField.focusRingType = NSFocusRingTypeNone;
        self.detailTitleEditField.placeholderString = @"标题";
        self.detailTitleEditField.target = self;
        self.detailTitleEditField.action = @selector(commitDetailTitleEdit:);
        self.detailTitleEditField.delegate = self;
        self.detailTitleEditField.hidden = YES;
        [self addSubview:self.detailTitleEditField];
    }
    if (!self.detailTitleEditSaveButton) {
        self.detailTitleEditSaveButton = [NSButton buttonWithTitle:@"保存" target:self action:@selector(commitDetailTitleEdit:)];
        self.detailTitleEditSaveButton.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
        self.detailTitleEditSaveButton.bordered = NO;
        self.detailTitleEditSaveButton.attributedTitle = ManualCreationButtonTitle(@"保存", YES);
        self.detailTitleEditSaveButton.hidden = YES;
        [self addSubview:self.detailTitleEditSaveButton];
    }
    if (!self.detailTitleEditCancelButton) {
        self.detailTitleEditCancelButton = [NSButton buttonWithTitle:@"取消" target:self action:@selector(cancelDetailTitleEdit:)];
        self.detailTitleEditCancelButton.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
        self.detailTitleEditCancelButton.bordered = NO;
        self.detailTitleEditCancelButton.attributedTitle = ManualCreationButtonTitle(@"取消", NO);
        self.detailTitleEditCancelButton.hidden = YES;
        [self addSubview:self.detailTitleEditCancelButton];
    }
}

- (void)layoutDetailTitleEditControls {
    [self ensureDetailTitleEditControls];
    NSRect rect = [self detailRect];
    BOOL visible = self.detailTitleEditBlock != nil;
    self.detailTitleEditField.hidden = !visible;
    self.detailTitleEditSaveButton.hidden = !visible;
    self.detailTitleEditCancelButton.hidden = !visible;
    if (!visible) {
        return;
    }
    self.detailTitleEditField.textColor = SoftTextColor();
    self.detailTitleEditField.backgroundColor = NSColor.clearColor;
    self.detailTitleEditSaveButton.attributedTitle = ManualCreationButtonTitle(@"保存", YES);
    self.detailTitleEditCancelButton.attributedTitle = ManualCreationButtonTitle(@"取消", NO);
    self.detailTitleEditField.frame = NSMakeRect(rect.origin.x + 14, rect.origin.y + 14, rect.size.width - 126, 24);
    self.detailTitleEditCancelButton.frame = NSMakeRect(NSMaxX(rect) - 104, rect.origin.y + 14, 44, 24);
    self.detailTitleEditSaveButton.frame = NSMakeRect(NSMaxX(rect) - 56, rect.origin.y + 14, 42, 24);
}

- (void)beginDetailTitleEditForBlock:(NSDictionary *)block {
    if (![self detailBlockCanEditTitle:block]) {
        return;
    }
    if (self.detailProjectEditBlock) {
        [self cancelDetailProjectEdit:nil];
    }
    self.detailTitleEditBlock = block;
    [self ensureDetailTitleEditControls];
    self.detailTitleEditField.stringValue = block[@"event_title"] ?: CalendarEventTitleForBlock(block);
    [self layoutDetailTitleEditControls];
    [self.window makeFirstResponder:self.detailTitleEditField];
    [self.detailTitleEditField selectText:self];
    [self setNeedsDisplayInRect:[self detailRect]];
}

- (void)cancelDetailTitleEdit:(id)sender {
    self.detailTitleEditBlock = nil;
    self.detailTitleEditField.hidden = YES;
    self.detailTitleEditSaveButton.hidden = YES;
    self.detailTitleEditCancelButton.hidden = YES;
    [self.window makeFirstResponder:self];
    [self setNeedsDisplayInRect:[self detailRect]];
}

- (void)commitDetailTitleEdit:(id)sender {
    if (!self.detailTitleEditBlock) {
        return;
    }
    [self sendDashboardAction:@selector(saveInlineDashboardBlockTitle:)];
    [self cancelDetailTitleEdit:nil];
}

- (BOOL)isEditingProjectForBlock:(NSDictionary *)block {
    NSString *editingKey = CalendarBlockKeyForBlock(self.detailProjectEditBlock);
    NSString *blockKey = CalendarBlockKeyForBlock(block);
    return editingKey.length > 0 && [editingKey isEqualToString:blockKey];
}

- (NSDictionary *)pendingDetailProjectEditBlock {
    return self.detailProjectEditBlock;
}

- (NSString *)pendingDetailProjectEditText {
    NSString *project = [self.detailProjectEditField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return project ?: @"";
}

- (NSRect)detailProjectEditPanelRect {
    NSRect action = [self detailActionAreaRect];
    return NSMakeRect(action.origin.x, action.origin.y - 58, action.size.width, 48);
}

- (void)ensureDetailProjectEditControls {
    if (!self.detailProjectEditField) {
        self.detailProjectEditField = [[NSTextField alloc] initWithFrame:NSZeroRect];
        self.detailProjectEditField.font = [NSFont systemFontOfSize:13 weight:NSFontWeightRegular];
        self.detailProjectEditField.bezeled = NO;
        self.detailProjectEditField.drawsBackground = NO;
        self.detailProjectEditField.focusRingType = NSFocusRingTypeNone;
        self.detailProjectEditField.placeholderString = @"项目标签";
        self.detailProjectEditField.target = self;
        self.detailProjectEditField.action = @selector(commitDetailProjectEdit:);
        self.detailProjectEditField.delegate = self;
        self.detailProjectEditField.hidden = YES;
        [self addSubview:self.detailProjectEditField];
    }
    if (!self.detailProjectEditSaveButton) {
        self.detailProjectEditSaveButton = [NSButton buttonWithTitle:@"保存" target:self action:@selector(commitDetailProjectEdit:)];
        self.detailProjectEditSaveButton.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
        self.detailProjectEditSaveButton.bordered = NO;
        self.detailProjectEditSaveButton.attributedTitle = ManualCreationButtonTitle(@"保存", YES);
        self.detailProjectEditSaveButton.hidden = YES;
        [self addSubview:self.detailProjectEditSaveButton];
    }
    if (!self.detailProjectEditCancelButton) {
        self.detailProjectEditCancelButton = [NSButton buttonWithTitle:@"取消" target:self action:@selector(cancelDetailProjectEdit:)];
        self.detailProjectEditCancelButton.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
        self.detailProjectEditCancelButton.bordered = NO;
        self.detailProjectEditCancelButton.attributedTitle = ManualCreationButtonTitle(@"取消", NO);
        self.detailProjectEditCancelButton.hidden = YES;
        [self addSubview:self.detailProjectEditCancelButton];
    }
}

- (void)layoutDetailProjectEditControls {
    [self ensureDetailProjectEditControls];
    NSRect panel = [self detailProjectEditPanelRect];
    BOOL visible = self.detailProjectEditBlock != nil;
    self.detailProjectEditField.hidden = !visible;
    self.detailProjectEditSaveButton.hidden = !visible;
    self.detailProjectEditCancelButton.hidden = !visible;
    if (!visible) {
        return;
    }
    self.detailProjectEditField.textColor = SoftTextColor();
    self.detailProjectEditField.backgroundColor = NSColor.clearColor;
    self.detailProjectEditSaveButton.attributedTitle = ManualCreationButtonTitle(@"保存", YES);
    self.detailProjectEditCancelButton.attributedTitle = ManualCreationButtonTitle(@"取消", NO);
    self.detailProjectEditField.frame = NSMakeRect(panel.origin.x + 10, panel.origin.y + 12, panel.size.width - 118, 24);
    self.detailProjectEditCancelButton.frame = NSMakeRect(NSMaxX(panel) - 102, panel.origin.y + 12, 44, 24);
    self.detailProjectEditSaveButton.frame = NSMakeRect(NSMaxX(panel) - 54, panel.origin.y + 12, 44, 24);
}

- (void)beginDetailProjectEditForBlock:(NSDictionary *)block {
    if (![self detailBlockCanEditTitle:block]) {
        return;
    }
    if (self.detailTitleEditBlock) {
        [self cancelDetailTitleEdit:nil];
    }
    self.detailProjectEditBlock = block;
    [self ensureDetailProjectEditControls];
    self.detailProjectEditField.stringValue = block[@"project_title"] ?: @"";
    [self layoutDetailProjectEditControls];
    [self.window makeFirstResponder:self.detailProjectEditField];
    [self.detailProjectEditField selectText:self];
    [self setNeedsDisplayInRect:[self detailRect]];
}

- (void)cancelDetailProjectEdit:(id)sender {
    self.detailProjectEditBlock = nil;
    self.detailProjectEditField.hidden = YES;
    self.detailProjectEditSaveButton.hidden = YES;
    self.detailProjectEditCancelButton.hidden = YES;
    [self.window makeFirstResponder:self];
    [self setNeedsDisplayInRect:[self detailRect]];
}

- (void)commitDetailProjectEdit:(id)sender {
    if (!self.detailProjectEditBlock) {
        return;
    }
    [self sendDashboardAction:@selector(saveInlineDashboardBlockProject:)];
    [self cancelDetailProjectEdit:nil];
}

- (NSDictionary *)visualBlockInBlocks:(NSArray *)blocks matchingCalendarKey:(NSString *)key {
    if (key.length == 0) {
        return nil;
    }
    for (NSDictionary *block in blocks ?: @[]) {
        if ([block[@"calendar_block_key"] isEqualToString:key]) {
            return block;
        }
    }
    return nil;
}

- (void)reconcileInlineEditorsWithVisualBlocks:(NSArray *)visualBlocks {
    NSString *titleKey = CalendarBlockKeyForBlock(self.detailTitleEditBlock);
    if (titleKey.length > 0) {
        NSDictionary *fresh = [self visualBlockInBlocks:visualBlocks matchingCalendarKey:titleKey];
        if (fresh) {
            self.detailTitleEditBlock = fresh;
        } else {
            [self cancelDetailTitleEdit:nil];
        }
    }

    NSString *projectKey = CalendarBlockKeyForBlock(self.detailProjectEditBlock);
    if (projectKey.length > 0) {
        NSDictionary *fresh = [self visualBlockInBlocks:visualBlocks matchingCalendarKey:projectKey];
        if (fresh) {
            self.detailProjectEditBlock = fresh;
        } else {
            [self cancelDetailProjectEdit:nil];
        }
    }
}

- (BOOL)hasActiveInlineEditor {
    return self.manualCreationBlock || self.detailTitleEditBlock || self.detailProjectEditBlock;
}

- (BOOL)pointIsInsideActiveInlineEditor:(NSPoint)point {
    if (self.manualCreationBlock) {
        NSRect panel = [self manualCreationPanelRectForBlock:self.manualCreationBlock];
        if (!NSEqualRects(panel, NSZeroRect) && NSPointInRect(point, panel)) {
            return YES;
        }
    }
    if (self.detailTitleEditBlock) {
        if (NSPointInRect(point, self.detailTitleEditField.frame) ||
            NSPointInRect(point, self.detailTitleEditSaveButton.frame) ||
            NSPointInRect(point, self.detailTitleEditCancelButton.frame)) {
            return YES;
        }
    }
    if (self.detailProjectEditBlock) {
        NSRect panel = [self detailProjectEditPanelRect];
        if (NSPointInRect(point, panel) ||
            NSPointInRect(point, self.detailProjectEditField.frame) ||
            NSPointInRect(point, self.detailProjectEditSaveButton.frame) ||
            NSPointInRect(point, self.detailProjectEditCancelButton.frame)) {
            return YES;
        }
    }
    return NO;
}

- (void)cancelInlineEditors {
    if (self.manualCreationBlock) {
        [self cancelManualCreation:nil];
    }
    if (self.detailTitleEditBlock) {
        [self cancelDetailTitleEdit:nil];
    }
    if (self.detailProjectEditBlock) {
        [self cancelDetailProjectEdit:nil];
    }
}

- (void)cancelOperation:(id)sender {
    if (self.pendingPanelVisible || [self hasActiveInlineEditor]) {
        self.pendingPanelVisible = NO;
        [self cancelInlineEditors];
        [self setNeedsDisplay:YES];
        return;
    }
    [super cancelOperation:sender];
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)commandSelector {
    if (commandSelector == @selector(cancelOperation:)) {
        [self cancelOperation:control];
        return YES;
    }
    return NO;
}

- (void)sendDashboardAction:(SEL)selector {
    if (self.actionTarget && [self.actionTarget respondsToSelector:selector]) {
        [NSApp sendAction:selector to:self.actionTarget from:self];
    }
}

- (NSDictionary *)timelineLayoutInRect:(NSRect)rect {
    NSArray *segments = self.stats[@"segments"] ?: @[];
    if (segments.count == 0) {
        return nil;
    }

    NSDate *start = self.stats[@"start"];
    NSDate *end = self.stats[@"end"];
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDateComponents *startComponents = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitHour fromDate:start];
    startComponents.minute = 0;
    startComponents.second = 0;
    NSDate *rangeStart = [calendar dateFromComponents:startComponents];
    NSDateComponents *endComponents = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitHour fromDate:end];
    endComponents.minute = 0;
    endComponents.second = 0;
    NSDate *rangeEnd = [[calendar dateFromComponents:endComponents] dateByAddingTimeInterval:3600];
    if ([rangeEnd timeIntervalSinceDate:rangeStart] < 3600) {
        rangeEnd = [rangeStart dateByAddingTimeInterval:3600];
    }

    CGFloat headerHeight = 54;
    CGFloat labelWidth = 58;
    CGFloat left = rect.origin.x + labelWidth;
    CGFloat width = rect.size.width - labelWidth - 12;
    CGFloat visibleGridTop = rect.origin.y + headerHeight;
    NSInteger hourCount = (NSInteger)ceil(MAX(3600, [rangeEnd timeIntervalSinceDate:rangeStart]) / 3600.0);
    CGFloat hourHeight = 60.0;
    CGFloat gridHeight = hourCount * hourHeight;
    CGFloat visibleGridHeight = MAX(120.0, rect.size.height - headerHeight - 18.0);
    CGFloat maxScroll = MAX(0, gridHeight - visibleGridHeight);
    CGFloat scrollY = MAX(0, MIN(self.timelineScrollY, maxScroll));
    if (fabs(scrollY - self.timelineScrollY) > 0.5) {
        self.timelineScrollY = scrollY;
    }
    CGFloat gridTop = visibleGridTop - scrollY;
    CGFloat laneLeft = left + 12;
    CGFloat laneWidth = MAX(80, width - 18);
    return @{
        @"range_start": rangeStart,
        @"range_end": rangeEnd,
        @"span": @(MAX(3600, [rangeEnd timeIntervalSinceDate:rangeStart])),
        @"left": @(left),
        @"width": @(width),
        @"calendar_left": @(laneLeft),
        @"calendar_width": @(laneWidth),
        @"activity_left": @(laneLeft + 12),
        @"activity_width": @(MAX(40, laneWidth - 24)),
        @"grid_top": @(gridTop),
        @"grid_height": @(gridHeight),
        @"visible_grid_top": @(visibleGridTop),
        @"visible_grid_height": @(visibleGridHeight),
        @"max_scroll": @(maxScroll),
        @"scroll_y": @(scrollY),
        @"header_height": @(headerHeight)
    };
}

- (NSRect)eventRectForBlock:(NSDictionary *)block layout:(NSDictionary *)layout timelineRect:(NSRect)rect {
    NSDate *rangeStart = layout[@"range_start"];
    NSDate *rangeEnd = layout[@"range_end"];
    NSDate *blockStart = block[@"start"];
    NSDate *blockEnd = block[@"end"];
    if ([blockEnd compare:rangeStart] != NSOrderedDescending || [blockStart compare:rangeEnd] != NSOrderedAscending) {
        return NSZeroRect;
    }

    NSDate *clampedStart = [blockStart compare:rangeStart] == NSOrderedAscending ? rangeStart : blockStart;
    NSDate *clampedEnd = [blockEnd compare:rangeEnd] == NSOrderedDescending ? rangeEnd : blockEnd;
    double span = [layout[@"span"] doubleValue];
    double s = [clampedStart timeIntervalSinceDate:rangeStart] / span;
    double e = [clampedEnd timeIntervalSinceDate:rangeStart] / span;
    CGFloat gridTop = [layout[@"grid_top"] doubleValue];
    CGFloat gridHeight = [layout[@"grid_height"] doubleValue];
    CGFloat y = gridTop + s * gridHeight;
    CGFloat naturalHeight = MAX(0.5, (e - s) * gridHeight);
    BOOL calendarLayer = [block[@"visual_layer"] isEqualToString:@"calendar"];
    CGFloat gap = calendarLayer
        ? (naturalHeight >= 18 ? 2 : 1)
        : (naturalHeight >= 7 ? 1 : 0);
    CGFloat height = calendarLayer
        ? CalendarEventDisplayHeight(naturalHeight, gap)
        : MAX(1, naturalHeight - gap);
    CGFloat left = [layout[calendarLayer ? @"calendar_left" : @"activity_left"] doubleValue];
    CGFloat width = [layout[calendarLayer ? @"calendar_width" : @"activity_width"] doubleValue];
    CGFloat displayY = y + gap / 2;
    CGFloat gridBottom = gridTop + gridHeight;
    if (calendarLayer && naturalHeight < height) {
        displayY = y + (naturalHeight - height) / 2.0;
        displayY = MAX(gridTop, MIN(displayY, gridBottom - height));
    }
    return NSMakeRect(left, displayY, width, height);
}

- (BOOL)isMixedTimelineBlock:(NSDictionary *)block {
    return [block[@"mode"] isEqualToString:@"碎片"] ||
           [block[@"kind"] isEqualToString:@"mixed"] ||
           [block[@"key"] isEqualToString:@"__mixed_work__"];
}

- (NSRect)timelineHitRectForBlock:(NSDictionary *)block eventRect:(NSRect)eventRect {
    if (!block || NSEqualRects(eventRect, NSZeroRect)) {
        return NSZeroRect;
    }
    if ([block[@"visual_layer"] isEqualToString:@"calendar"] ||
        [block[@"kind"] isEqualToString:@"gap"]) {
        return NSInsetRect(eventRect, -2.0, -2.0);
    }

    CGFloat railHeight = [self isMixedTimelineBlock:block] ? 8.0 : 7.0;
    return NSInsetRect(CenteredTimelineRailRect(eventRect, railHeight), -3.0, -3.0);
}

- (NSDate *)timelineDateForPoint:(NSPoint)point clampToRange:(BOOL)clamp {
    NSRect rect = [self timelineRect];
    NSDictionary *layout = [self timelineLayoutInRect:rect];
    if (!layout) {
        return nil;
    }
    CGFloat laneLeft = [layout[@"calendar_left"] doubleValue];
    CGFloat laneWidth = [layout[@"calendar_width"] doubleValue];
    CGFloat gridTop = [layout[@"grid_top"] doubleValue];
    CGFloat gridHeight = [layout[@"grid_height"] doubleValue];
    CGFloat visibleGridTop = [layout[@"visible_grid_top"] doubleValue];
    CGFloat visibleGridHeight = [layout[@"visible_grid_height"] doubleValue];
    if (!clamp) {
        BOOL inLane = point.x >= laneLeft && point.x <= laneLeft + laneWidth;
        BOOL inGrid = point.y >= visibleGridTop && point.y <= visibleGridTop + visibleGridHeight;
        if (!inLane || !inGrid) {
            return nil;
        }
    }

    CGFloat y = clamp
        ? MAX(visibleGridTop, MIN(visibleGridTop + visibleGridHeight, point.y))
        : point.y;
    y = MAX(gridTop, MIN(gridTop + gridHeight, y));
    double ratio = gridHeight > 0 ? (y - gridTop) / gridHeight : 0;
    ratio = MAX(0, MIN(1, ratio));
    NSDate *rangeStart = layout[@"range_start"];
    NSTimeInterval span = [layout[@"span"] doubleValue];
    return DateBySnappingToMinutes([rangeStart dateByAddingTimeInterval:ratio * span], 5);
}

- (BOOL)canStartManualDragAtPoint:(NSPoint)point {
    NSDictionary *block = [self timelineBlockAtPoint:point];
    if (!NSPointInRect(point, [self timelineRect]) ||
        (block && ![block[@"kind"] isEqualToString:@"gap"])) {
        return NO;
    }
    return [self timelineDateForPoint:point clampToRange:NO] != nil;
}

- (BOOL)beginManualDragAtPoint:(NSPoint)point {
    NSDate *start = [self timelineDateForPoint:point clampToRange:NO];
    if (!start) {
        return NO;
    }
    self.draggingManualBlock = YES;
    self.manualDragMoved = NO;
    self.manualDragStartDate = start;
    self.manualDragEndDate = start;
    self.manualDraftBlock = nil;
    [self setNeedsDisplay:YES];
    return YES;
}

- (NSDictionary *)manualDraftBlockFromStart:(NSDate *)start end:(NSDate *)end {
    if (!start || !end) {
        return nil;
    }
    NSDate *blockStart = [start compare:end] == NSOrderedAscending ? start : end;
    NSDate *blockEnd = [start compare:end] == NSOrderedAscending ? end : start;
    double wall = [blockEnd timeIntervalSinceDate:blockStart];
    if (wall < MinimumRecordedSegmentSeconds()) {
        return nil;
    }
    return @{
        @"start": blockStart,
        @"end": blockEnd,
        @"wall_seconds": @(wall),
        @"active_seconds": @(wall),
        @"observed_seconds": @(wall),
        @"active_ratio": @1.0,
        @"title": @"新时段",
        @"event_title": @"新时段",
        @"key": @"__manual_block__",
        @"bundle_id": @"__manual_block__",
        @"kind": @"manual",
        @"mode": @"手动",
        @"visual_layer": @"calendar",
        @"calendar_block_key": CalendarBlockKeyForDates(blockStart, blockEnd),
        @"calendar_confirmed": @NO,
        @"top_apps": @[@{
            @"title": @"新时段",
            @"key": @"__manual_block__",
            @"bundle_id": @"__manual_block__",
            @"seconds": @(wall),
            @"ratio": @1.0
        }]
    };
}

- (NSDictionary *)pendingManualCreationBlock {
    NSDictionary *block = self.manualCreationBlock ?: self.manualDraftBlock;
    double wall = [block[@"wall_seconds"] doubleValue];
    return wall >= 180.0 ? block : nil;
}

- (NSString *)pendingManualCreationTitle {
    NSString *title = [self.manualCreationTitleField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return title.length > 0 ? title : @"手动时段";
}

- (NSRect)manualCreationPanelRectForBlock:(NSDictionary *)block {
    if (!block) {
        return NSZeroRect;
    }
    NSRect timeline = [self timelineRect];
    NSDictionary *layout = [self timelineLayoutInRect:timeline];
    if (!layout) {
        return NSZeroRect;
    }
    NSRect eventRect = [self eventRectForBlock:block layout:layout timelineRect:timeline];
    if (NSEqualRects(eventRect, NSZeroRect)) {
        return NSZeroRect;
    }
    CGFloat width = MIN(318.0, timeline.size.width - 32.0);
    CGFloat height = 126.0;
    CGFloat x = eventRect.origin.x + 10.0;
    CGFloat y = NSMaxY(eventRect) + 8.0;
    if (y + height > NSMaxY(timeline) - 10.0) {
        y = eventRect.origin.y - height - 8.0;
    }
    x = MAX(timeline.origin.x + 14.0, MIN(x, NSMaxX(timeline) - width - 14.0));
    y = MAX(timeline.origin.y + 54.0, MIN(y, NSMaxY(timeline) - height - 10.0));
    return NSMakeRect(x, y, width, height);
}

- (void)ensureManualCreationControls {
    if (!self.manualCreationTitleField) {
        self.manualCreationTitleField = [[NSTextField alloc] initWithFrame:NSZeroRect];
        self.manualCreationTitleField.font = [NSFont systemFontOfSize:13 weight:NSFontWeightRegular];
        self.manualCreationTitleField.bezeled = NO;
        self.manualCreationTitleField.drawsBackground = NO;
        self.manualCreationTitleField.focusRingType = NSFocusRingTypeNone;
        self.manualCreationTitleField.placeholderString = @"标题";
        self.manualCreationTitleField.target = self;
        self.manualCreationTitleField.action = @selector(commitManualCreation:);
        self.manualCreationTitleField.delegate = self;
        self.manualCreationTitleField.hidden = YES;
        [self addSubview:self.manualCreationTitleField];
    }
    if (!self.manualCreationSaveButton) {
        self.manualCreationSaveButton = [NSButton buttonWithTitle:@"保存" target:self action:@selector(commitManualCreation:)];
        self.manualCreationSaveButton.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
        self.manualCreationSaveButton.bordered = NO;
        self.manualCreationSaveButton.attributedTitle = ManualCreationButtonTitle(@"保存", YES);
        self.manualCreationSaveButton.hidden = YES;
        [self addSubview:self.manualCreationSaveButton];
    }
    if (!self.manualCreationCancelButton) {
        self.manualCreationCancelButton = [NSButton buttonWithTitle:@"取消" target:self action:@selector(cancelManualCreation:)];
        self.manualCreationCancelButton.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
        self.manualCreationCancelButton.bordered = NO;
        self.manualCreationCancelButton.attributedTitle = ManualCreationButtonTitle(@"取消", NO);
        self.manualCreationCancelButton.hidden = YES;
        [self addSubview:self.manualCreationCancelButton];
    }
}

- (void)layoutManualCreationControls {
    [self ensureManualCreationControls];
    NSRect panel = [self manualCreationPanelRectForBlock:self.manualCreationBlock];
    BOOL visible = self.manualCreationBlock && !NSEqualRects(panel, NSZeroRect);
    self.manualCreationTitleField.hidden = !visible;
    self.manualCreationSaveButton.hidden = !visible;
    self.manualCreationCancelButton.hidden = !visible;
    if (!visible) {
        return;
    }
    self.manualCreationTitleField.textColor = SoftTextColor();
    self.manualCreationTitleField.backgroundColor = NSColor.clearColor;
    self.manualCreationSaveButton.attributedTitle = ManualCreationButtonTitle(@"保存", YES);
    self.manualCreationCancelButton.attributedTitle = ManualCreationButtonTitle(@"取消", NO);
    self.manualCreationTitleField.frame = NSMakeRect(panel.origin.x + 17, panel.origin.y + 51, panel.size.width - 34, 24);
    self.manualCreationCancelButton.frame = NSMakeRect(NSMaxX(panel) - 136, panel.origin.y + 89, 62, 24);
    self.manualCreationSaveButton.frame = NSMakeRect(NSMaxX(panel) - 67, panel.origin.y + 89, 50, 24);
}

- (void)beginManualCreationForBlock:(NSDictionary *)block {
    self.manualCreationBlock = block;
    self.selectedBlock = block;
    self.hoveredBlock = block;
    [self ensureManualCreationControls];
    self.manualCreationTitleField.stringValue = block[@"event_title"] ?: @"手动时段";
    [self layoutManualCreationControls];
    self.manualCreationTitleField.hidden = NO;
    self.manualCreationSaveButton.hidden = NO;
    self.manualCreationCancelButton.hidden = NO;
    [self.window makeFirstResponder:self.manualCreationTitleField];
    [self.manualCreationTitleField selectText:self];
    [self setNeedsDisplay:YES];
}

- (void)cancelManualCreation:(id)sender {
    self.manualCreationBlock = nil;
    self.manualCreationTitleField.hidden = YES;
    self.manualCreationSaveButton.hidden = YES;
    self.manualCreationCancelButton.hidden = YES;
    [self.window makeFirstResponder:self];
    [self setNeedsDisplay:YES];
}

- (void)commitManualCreation:(id)sender {
    if (!self.manualCreationBlock) {
        return;
    }
    [self sendDashboardAction:@selector(createManualDashboardBlock:)];
    [self cancelManualCreation:nil];
}

- (void)drawManualCreationPanel {
    if (!self.manualCreationBlock) {
        return;
    }
    [self layoutManualCreationControls];
    NSRect panel = [self manualCreationPanelRectForBlock:self.manualCreationBlock];
    if (NSEqualRects(panel, NSZeroRect)) {
        return;
    }

    NSShadow *shadow = [[NSShadow alloc] init];
    shadow.shadowColor = [NSColor.blackColor colorWithAlphaComponent:(AppIsDark() ? 0.36 : 0.14)];
    shadow.shadowBlurRadius = 18;
    shadow.shadowOffset = NSMakeSize(0, -5);
    [NSGraphicsContext saveGraphicsState];
    [shadow set];
    FillRoundedRect(panel, 13, InspectorColor());
    [NSGraphicsContext restoreGraphicsState];
    FillRoundedRect(panel, 13, InspectorColor());
    StrokeRoundedRect(panel, 13, BorderColor(), 0.7);

    NSRect inputRect = self.manualCreationTitleField.frame;
    FillRoundedRect(inputRect, 7, ManualCreationInputFillColor());
    StrokeRoundedRect(inputRect, 7, ManualCreationInputStrokeColor(), 0.7);

    NSRect cancelRect = self.manualCreationCancelButton.frame;
    FillRoundedRect(cancelRect, 8, ManualCreationSecondaryButtonFillColor());
    StrokeRoundedRect(cancelRect, 8, BorderColor(), 0.45);
    NSRect saveRect = self.manualCreationSaveButton.frame;
    FillRoundedRect(saveRect, 8, [NSColor.controlAccentColor colorWithAlphaComponent:(AppIsDark() ? 0.92 : 0.88)]);
    StrokeRoundedRect(saveRect, 8, [NSColor.whiteColor colorWithAlphaComponent:(AppIsDark() ? 0.10 : 0.18)], 0.5);

    NSDictionary *titleAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold],
                                 NSForegroundColorAttributeName: SoftTextColor()};
    NSDictionary *captionAttrs = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular],
                                   NSForegroundColorAttributeName: MutedTextColor()};
    NSColor *draftColor = ColorForKey(@"__manual_block__");
    FillRoundedRect(NSMakeRect(panel.origin.x + 12, panel.origin.y + 15, 4, 28),
                    2,
                    [draftColor colorWithAlphaComponent:0.80]);
    [@"新时段" drawAtPoint:NSMakePoint(panel.origin.x + 26, panel.origin.y + 12) withAttributes:titleAttrs];
    NSString *time = [NSString stringWithFormat:@"%@-%@ · %@",
                      [ClockString(self.manualCreationBlock[@"start"]) substringToIndex:5],
                      [ClockString(self.manualCreationBlock[@"end"]) substringToIndex:5],
                      ShortDuration([self.manualCreationBlock[@"wall_seconds"] doubleValue])];
    [time drawInRect:NSMakeRect(panel.origin.x + 26, panel.origin.y + 31, panel.size.width - 44, 14)
      withAttributes:captionAttrs];

}

- (NSDictionary *)timelineBlockAtPoint:(NSPoint)point {
    NSRect rect = [self timelineRect];
    if (!NSPointInRect(point, rect)) {
        return nil;
    }
    NSDictionary *layout = [self timelineLayoutInRect:rect];
    if (!layout) {
        return nil;
    }
    NSArray *visualBlocks = self.stats[@"visual_blocks"] ?: @[];
    for (NSDictionary *block in [visualBlocks reverseObjectEnumerator]) {
        if (![block[@"visual_layer"] isEqualToString:@"calendar"]) {
            continue;
        }
        NSRect eventRect = [self eventRectForBlock:block layout:layout timelineRect:rect];
        NSRect hitRect = [self timelineHitRectForBlock:block eventRect:eventRect];
        if (!NSEqualRects(hitRect, NSZeroRect) && NSPointInRect(point, hitRect)) {
            return block;
        }
    }
    for (NSDictionary *block in [visualBlocks reverseObjectEnumerator]) {
        if (![block[@"visual_layer"] isEqualToString:@"activity"]) {
            continue;
        }
        NSRect eventRect = [self eventRectForBlock:block layout:layout timelineRect:rect];
        NSRect hitRect = [self timelineHitRectForBlock:block eventRect:eventRect];
        if (!NSEqualRects(hitRect, NSZeroRect) && NSPointInRect(point, hitRect)) {
            return block;
        }
    }
    return nil;
}

- (NSString *)appKeyAtDetailPoint:(NSPoint)point block:(NSDictionary *)block {
    if (!block) {
        return nil;
    }
    NSArray *apps = block[@"top_apps"] ?: @[];
    if (apps.count == 0) {
        return nil;
    }

    NSString *donutKey = [self appKeyAtDonutPoint:point block:block];
    if (donutKey) {
        return donutKey;
    }

    NSRect ratioBar = [self detailRatioBarRect];
    if (NSPointInRect(point, NSInsetRect(ratioBar, 0, -6))) {
        double total = 0;
        for (NSDictionary *app in apps) {
            total += MAX(0, [app[@"ratio"] doubleValue]);
        }
        if (total <= 0) {
            total = 1;
        }
        CGFloat x = point.x - ratioBar.origin.x;
        CGFloat widthCursor = 0;
        for (NSInteger i = 0; i < apps.count; i++) {
            NSDictionary *app = apps[i];
            double ratio = MAX(0, [app[@"ratio"] doubleValue]) / total;
            if (ratio <= 0.006) {
                continue;
            }
            CGFloat segmentWidth = (i == apps.count - 1)
                ? ratioBar.size.width - widthCursor
                : ratioBar.size.width * ratio;
            if (x >= widthCursor && x <= widthCursor + segmentWidth) {
                return app[@"key"] ?: @"__other__";
            }
            widthCursor += segmentWidth;
        }
        NSDictionary *last = apps.lastObject;
        return last[@"key"] ?: @"__other__";
    }

    for (NSInteger i = 0; i < MIN(5, apps.count); i++) {
        if (NSPointInRect(point, [self detailAppRowRectAtIndex:i])) {
            NSDictionary *app = apps[i];
            return app[@"key"] ?: @"__other__";
        }
    }

    NSRect detail = [self detailRect];
    BOOL inRatioArea = point.x >= detail.origin.x + 8 &&
                       point.x <= NSMaxX(detail) - 8 &&
                       point.y >= [self detailDonutRect].origin.y - 8 &&
                       point.y <= NSMaxY([self detailAppRowRectAtIndex:MIN(4, MAX(0, (NSInteger)apps.count - 1))]);
    if (inRatioArea) {
        return @"";
    }
    return nil;
}

- (NSString *)appKeyAtDonutPoint:(NSPoint)point block:(NSDictionary *)block {
    if (!block) {
        return nil;
    }
    NSRect donut = [self detailDonutRect];
    if (!NSPointInRect(point, donut)) {
        return nil;
    }

    NSArray *apps = block[@"top_apps"] ?: @[];
    if (apps.count == 0) {
        return nil;
    }

    double totalSeconds = 0;
    double totalWeight = 0;
    for (NSDictionary *app in apps) {
        totalSeconds += MAX(0, [app[@"seconds"] doubleValue]);
        totalWeight += MAX(0, [app[@"ratio"] doubleValue]);
    }
    if (totalSeconds <= 0) {
        totalSeconds = 1;
    }
    if (totalWeight <= 0) {
        totalWeight = 1;
    }

    NSPoint center = NSMakePoint(NSMidX(donut), NSMidY(donut));
    CGFloat dx = point.x - center.x;
    CGFloat dy = point.y - center.y;
    CGFloat distance = sqrt(dx * dx + dy * dy);
    CGFloat radius = donut.size.width / 2.0;
    if (distance > radius || distance < radius * 0.50) {
        return @"";
    }
    CGFloat angle = atan2(dy, dx) * 180.0 / M_PI + 90.0;
    while (angle < 0) {
        angle += 360.0;
    }
    while (angle >= 360.0) {
        angle -= 360.0;
    }
    double cursor = 0;
    for (NSDictionary *app in apps) {
        double ratio = [app[@"ratio"] doubleValue] > 0
            ? MAX(0, [app[@"ratio"] doubleValue]) / totalWeight
            : MAX(0, [app[@"seconds"] doubleValue]) / totalSeconds;
        if (ratio <= 0.005) {
            continue;
        }
        cursor += ratio * 360.0;
        if (angle <= cursor) {
            return app[@"key"] ?: @"__other__";
        }
    }
    NSDictionary *last = apps.lastObject;
    return last[@"key"] ?: @"__other__";
}

- (BOOL)block:(NSDictionary *)block containsAppKey:(NSString *)appKey {
    if (appKey.length == 0 || !block) {
        return NO;
    }
    if ([block[@"key"] isEqualToString:appKey]) {
        return YES;
    }
    for (NSDictionary *app in block[@"top_apps"] ?: @[]) {
        if ([app[@"key"] isEqualToString:appKey]) {
            return YES;
        }
    }
    return NO;
}

- (CGFloat)timelineAlphaForBlock:(NSDictionary *)block selected:(BOOL)selected hovered:(BOOL)hovered calendarLayer:(BOOL)calendarLayer {
    if (self.highlightedAppKey.length == 0) {
        return 1.0;
    }
    if ([block[@"kind"] isEqualToString:@"gap"]) {
        return hovered || selected ? 0.70 : 0.42;
    }
    if ([self block:block containsAppKey:self.highlightedAppKey]) {
        return 1.0;
    }
    if (hovered || selected) {
        return calendarLayer ? 0.72 : 0.62;
    }
    return calendarLayer ? 0.28 : 0.22;
}

- (void)drawTimelineFocusForBlock:(NSDictionary *)block inRect:(NSRect)displayRect mixed:(BOOL)mixed calendarLayer:(BOOL)calendarLayer {
    if (self.highlightedAppKey.length == 0 ||
        [block[@"kind"] isEqualToString:@"gap"] ||
        ![self block:block containsAppKey:self.highlightedAppKey]) {
        return;
    }

    NSColor *highlight = ColorForKey(self.highlightedAppKey);
    if (calendarLayer) {
        CGFloat insetY = displayRect.size.height >= 14.0 ? 5.0 : MAX(1.0, floor((displayRect.size.height - 4.0) / 2.0));
        CGFloat accentHeight = MAX(2.5, displayRect.size.height - insetY * 2.0);
        NSRect accent = NSMakeRect(displayRect.origin.x + 4.0,
                                   displayRect.origin.y + insetY,
                                   2.5,
                                   accentHeight);
        FillRoundedRect(accent, 1.25, [highlight colorWithAlphaComponent:(AppIsDark() ? 0.54 : 0.48)]);
        StrokeRoundedRect(displayRect,
                          MIN(7.0, MAX(3.0, displayRect.size.height / 2.0)),
                          [highlight colorWithAlphaComponent:(AppIsDark() ? 0.30 : 0.24)],
                          0.75);
    } else {
        NSRect focusRect = mixed ? CenteredTimelineRailRect(displayRect, 4.8) : CenteredTimelineRailRect(displayRect, 5.4);
        StrokeRoundedRect(NSInsetRect(focusRect, -1.0, -1.0), 4, [highlight colorWithAlphaComponent:(AppIsDark() ? 0.34 : 0.27)], 0.75);
    }
}

- (NSString *)colorKeyForBlock:(NSDictionary *)block {
    if (!block) {
        return nil;
    }
    if ([block[@"kind"] isEqualToString:@"gap"]) {
        return nil;
    }
    if ([block[@"kind"] isEqualToString:@"mixed"] || [block[@"mode"] isEqualToString:@"碎片"]) {
        NSDictionary *firstApp = [block[@"top_apps"] firstObject];
        NSString *key = firstApp[@"key"];
        if (key.length > 0) {
            return key;
        }
    }
    NSString *key = block[@"key"];
    return key.length > 0 ? key : nil;
}

- (BOOL)openColorPanelForAppKey:(NSString *)key {
    if (key.length == 0 || [key isEqualToString:@"__other__"]) {
        self.activeColorEditKey = nil;
        return NO;
    }
    self.activeColorEditKey = key;
    NSColorPanel *panel = [NSColorPanel sharedColorPanel];
    panel.showsAlpha = NO;
    panel.color = ColorForKey(key);
    [panel setTarget:self];
    [panel setAction:@selector(colorPanelChanged:)];
    [NSApp activateIgnoringOtherApps:YES];
    [panel orderFront:self];
    return YES;
}

- (void)openColorPanelForBlock:(NSDictionary *)block {
    [self openColorPanelForAppKey:[self colorKeyForBlock:block]];
}

- (NSString *)colorEditableAppKeyAtPoint:(NSPoint)point {
    NSString *key = [self appKeyAtSidebarPoint:point];
    if (key.length > 0) {
        return key;
    }
    key = [self appKeyAtTimelineLegendPoint:point];
    if (key.length > 0) {
        return key;
    }
    NSDictionary *detailBlock = [self primaryDetailBlock];
    if (detailBlock) {
        key = [self appKeyAtDetailPoint:point block:detailBlock];
        if (key.length > 0) {
            return key;
        }
    }
    NSDictionary *block = [self timelineBlockAtPoint:point];
    key = [self colorKeyForBlock:block];
    if (key.length > 0) {
        return key;
    }
    return [self colorKeyForBlock:detailBlock];
}

- (void)colorPanelChanged:(NSColorPanel *)sender {
    if (self.activeColorEditKey.length == 0) {
        return;
    }
    StoreColorForKey(self.activeColorEditKey, sender.color);
    [self setNeedsDisplay:YES];
}

- (void)cancelLongPress {
    [self.longPressTimer invalidate];
    self.longPressTimer = nil;
    self.longPressBlock = nil;
    self.longPressTriggered = NO;
}

- (void)beginLongPressForBlock:(NSDictionary *)block atPoint:(NSPoint)point {
    [self cancelLongPress];
    NSString *key = [self colorKeyForBlock:block];
    if (key.length == 0 || [key isEqualToString:@"__other__"]) {
        return;
    }
    self.longPressBlock = block;
    self.longPressStartPoint = point;
    self.longPressTriggered = NO;
    __weak DashboardView *weakSelf = self;
    NSTimer *timer = [NSTimer timerWithTimeInterval:0.55 repeats:NO block:^(NSTimer *timer) {
        DashboardView *strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.longPressBlock) {
            return;
        }
        strongSelf.longPressTriggered = YES;
        NSDictionary *targetBlock = strongSelf.longPressBlock;
        strongSelf.longPressBlock = nil;
        strongSelf.longPressTimer = nil;
        [strongSelf openColorPanelForBlock:targetBlock];
    }];
    self.longPressTimer = timer;
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
}

- (void)cancelLongPressIfMovedToPoint:(NSPoint)point {
    if (!self.longPressTimer) {
        return;
    }
    CGFloat dx = point.x - self.longPressStartPoint.x;
    CGFloat dy = point.y - self.longPressStartPoint.y;
    if (sqrt(dx * dx + dy * dy) > 6.0) {
        [self cancelLongPress];
    }
}

- (void)rightMouseDown:(NSEvent *)event {
    [self cancelLongPress];
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    [self openColorPanelForAppKey:[self colorEditableAppKeyAtPoint:point]];
}

- (void)mouseMoved:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSDictionary *block = [self timelineBlockAtPoint:point];
    BOOL changed = block != self.hoveredBlock;
    self.hoveredBlock = block;
    self.hoverPoint = point;
    if (changed || block) {
        [self setNeedsDisplay:YES];
    }
}

- (void)scrollWheel:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (!NSPointInRect(point, [self timelineRect])) {
        [super scrollWheel:event];
        return;
    }
    NSDictionary *layout = [self timelineLayoutInRect:[self timelineRect]];
    CGFloat maxScroll = [layout[@"max_scroll"] doubleValue];
    if (maxScroll <= 0.5) {
        [super scrollWheel:event];
        return;
    }
    CGFloat delta = event.scrollingDeltaY;
    if (!event.hasPreciseScrollingDeltas) {
        delta *= 6.0;
    }
    self.timelineScrollY = MAX(0, MIN(maxScroll, self.timelineScrollY - delta));
    self.timelineUserScrolled = YES;
    self.hoverPoint = point;
    self.hoveredBlock = [self timelineBlockAtPoint:point];
    [self setNeedsDisplay:YES];
}

- (void)mouseDown:(NSEvent *)event {
    [self cancelLongPress];
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if ((event.modifierFlags & NSEventModifierFlagControl) != 0) {
        [self openColorPanelForAppKey:[self colorEditableAppKeyAtPoint:point]];
        return;
    }
    if ([self hasActiveInlineEditor]) {
        if ([self pointIsInsideActiveInlineEditor:point]) {
            return;
        }
        [self cancelInlineEditors];
    }
    if (NSPointInRect(point, [self topToggleButtonRect])) {
        [self sendDashboardAction:@selector(toggleRecording:)];
        return;
    }
    if (NSPointInRect(point, [self topMoreButtonRect])) {
        [self sendDashboardAction:@selector(showMoreMenu:)];
        return;
    }
    if (NSPointInRect(point, [self pendingBannerRect])) {
        if ([self pendingDashboardCandidates].count == 0) {
            self.pendingPanelVisible = NO;
            [self setNeedsDisplay:YES];
            return;
        }
        self.pendingPanelVisible = !self.pendingPanelVisible;
        [self setNeedsDisplay:YES];
        return;
    }

    if (self.pendingPanelVisible) {
        NSRect panel = [self pendingPanelRect];
        if (NSPointInRect(point, [self pendingPanelCloseRect])) {
            self.pendingPanelVisible = NO;
            [self setNeedsDisplay:YES];
            return;
        }
        if (NSPointInRect(point, [self pendingPanelWriteRect])) {
            if ([self pendingDashboardCandidates].count == 0) {
                self.pendingPanelVisible = NO;
                [self setNeedsDisplay:YES];
                return;
            }
            self.pendingPanelVisible = NO;
            [self setNeedsDisplay:YES];
            [self sendDashboardAction:@selector(writeDashboardPendingBlocksToCalendar:)];
            return;
        }
        NSArray *pending = [self pendingDashboardCandidates];
        for (NSInteger i = 0; i < MIN(5, pending.count); i++) {
            if (NSPointInRect(point, [self pendingPanelRowRectAtIndex:i])) {
                self.selectedBlock = pending[i];
                self.hoveredBlock = pending[i];
                [self setNeedsDisplay:YES];
                return;
            }
        }
        if (!NSPointInRect(point, panel)) {
            self.pendingPanelVisible = NO;
            [self setNeedsDisplay:YES];
            return;
        }
    }

    NSRect sidebar = [self sidebarRect];
    if (NSPointInRect(point, sidebar)) {
        if (NSPointInRect(point, [self sidebarDatePreviousRect])) {
            [self sendDashboardAction:@selector(selectPreviousDashboardDay:)];
            return;
        }
        if (NSPointInRect(point, [self sidebarDateNextRect])) {
            if (![self.stats[@"is_today"] boolValue]) {
                [self sendDashboardAction:@selector(selectNextDashboardDay:)];
            }
            return;
        }
        for (NSInteger i = 0; i < 3; i++) {
            if (NSPointInRect(point, [self scopeChipRectAtIndex:i])) {
                self.selectedScopeIndex = i;
                [self setNeedsDisplay:YES];
                return;
            }
        }
        NSArray *projects = self.stats[@"project_labels"] ?: @[];
        if (NSPointInRect(point, [self projectChipRectAtIndex:0])) {
            self.selectedProjectFilter = nil;
            [self setNeedsDisplay:YES];
            return;
        }
        for (NSInteger i = 0; i < MIN(3, projects.count); i++) {
            NSString *project = projects[i];
            if (NSPointInRect(point, [self projectChipRectAtIndex:i + 1])) {
                self.selectedProjectFilter = [self.selectedProjectFilter isEqualToString:project] ? nil : project;
                [self setNeedsDisplay:YES];
                return;
            }
        }
        NSString *sidebarAppKey = [self appKeyAtSidebarPoint:point];
        if (sidebarAppKey) {
            self.highlightedAppKey = [self.highlightedAppKey isEqualToString:sidebarAppKey] ? nil : sidebarAppKey;
            [self setNeedsDisplay:YES];
            return;
        }
    }

    NSString *timelineLegendAppKey = [self appKeyAtTimelineLegendPoint:point];
    if (timelineLegendAppKey) {
        self.highlightedAppKey = [self.highlightedAppKey isEqualToString:timelineLegendAppKey] ? nil : timelineLegendAppKey;
        [self setNeedsDisplay:YES];
        return;
    }

    NSDictionary *detailBlock = [self primaryDetailBlock];
    if (detailBlock) {
        if (NSPointInRect(point, [self detailRenameButtonRect])) {
            [self beginDetailTitleEditForBlock:detailBlock];
            return;
        }
        NSString *detailAppKey = [self appKeyAtDetailPoint:point block:detailBlock];
        if (detailAppKey) {
            self.highlightedAppKey = detailAppKey.length == 0 || [self.highlightedAppKey isEqualToString:detailAppKey] ? nil : detailAppKey;
            [self setNeedsDisplay:YES];
            return;
        }
        if ([self detailBlockCanEditTitle:detailBlock]) {
            if (NSPointInRect(point, [self detailWriteButtonRect])) {
                if ([detailBlock[@"calendar_confirmed"] boolValue]) {
                    self.pendingPanelVisible = NO;
                    [self setNeedsDisplay:YES];
                    return;
                }
                [self sendDashboardAction:@selector(writeSelectedDashboardBlockToCalendar:)];
                return;
            }
            if (NSPointInRect(point, [self detailProjectButtonRect])) {
                [self beginDetailProjectEditForBlock:detailBlock];
                return;
            }
            if (NSPointInRect(point, [self detailIgnoreButtonRect])) {
                [self sendDashboardAction:@selector(ignoreSelectedDashboardBlock:)];
                return;
            }
        }
    }

    NSDictionary *block = [self timelineBlockAtPoint:point];
    if ((!block || [block[@"kind"] isEqualToString:@"gap"]) && [self canStartManualDragAtPoint:point]) {
        if (block) {
            self.selectedBlock = block;
            self.hoveredBlock = block;
        }
        [self beginManualDragAtPoint:point];
        return;
    }
    if (block) {
        self.selectedBlock = block;
        self.hoveredBlock = block;
        if (![block[@"kind"] isEqualToString:@"gap"]) {
            [self beginLongPressForBlock:block atPoint:point];
        }
        [self setNeedsDisplay:YES];
    }
}

- (void)mouseDragged:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    [self cancelLongPressIfMovedToPoint:point];
    if (!self.draggingManualBlock) {
        [super mouseDragged:event];
        return;
    }
    NSDate *end = [self timelineDateForPoint:point clampToRange:YES];
    if (!end) {
        return;
    }
    self.manualDragEndDate = end;
    self.manualDraftBlock = [self manualDraftBlockFromStart:self.manualDragStartDate end:self.manualDragEndDate];
    if (self.manualDraftBlock) {
        self.manualDragMoved = YES;
        self.selectedBlock = self.manualDraftBlock;
        self.hoveredBlock = self.manualDraftBlock;
    }
    self.hoverPoint = point;
    [self setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent *)event {
    BOOL longPressHandled = self.longPressTriggered;
    [self cancelLongPress];
    if (longPressHandled && !self.draggingManualBlock) {
        return;
    }
    if (!self.draggingManualBlock) {
        [super mouseUp:event];
        return;
    }
    NSDictionary *block = self.manualDragMoved ? [self pendingManualCreationBlock] : nil;
    self.draggingManualBlock = NO;
    self.manualDragMoved = NO;
    if (block) {
        self.selectedBlock = block;
        self.hoveredBlock = block;
        self.manualDraftBlock = nil;
        self.manualDragStartDate = nil;
        self.manualDragEndDate = nil;
        [self beginManualCreationForBlock:block];
        return;
    }
    self.manualDragStartDate = nil;
    self.manualDragEndDate = nil;
    self.manualDraftBlock = nil;
    [self setNeedsDisplay:YES];
}

- (void)mouseExited:(NSEvent *)event {
    [self cancelLongPress];
    if (self.hoveredBlock) {
        self.hoveredBlock = nil;
        [self setNeedsDisplay:YES];
    }
}

- (NSString *)displayTitleForHoverBlock:(NSDictionary *)block {
    NSString *customTitle = block[@"event_title"];
    if (customTitle.length > 0) {
        return customTitle;
    }
    if ([block[@"kind"] isEqualToString:@"gap"]) {
        return block[@"title"] ?: @"空白";
    }
    if ([block[@"kind"] isEqualToString:@"ongoing"]) {
        return [NSString stringWithFormat:@"进行中：%@", block[@"title"] ?: @"未知"];
    }
    BOOL mixed = [block[@"mode"] isEqualToString:@"碎片"] || [block[@"kind"] isEqualToString:@"mixed"];
    if ([block[@"kind"] isEqualToString:@"mixed"]) {
        return @"混合工作";
    }
    if (mixed) {
        return [NSString stringWithFormat:@"%@概览", block[@"granularity"] ?: @"混合"];
    }
    return block[@"title"] ?: @"未知";
}

- (NSArray<NSString *> *)hoverLinesForBlock:(NSDictionary *)block {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSString *time = [NSString stringWithFormat:@"%@-%@",
                      [ClockString(block[@"start"]) substringToIndex:5],
                      [ClockString(block[@"end"]) substringToIndex:5]];
    [lines addObject:[NSString stringWithFormat:@"%@  %@", time, [self displayTitleForHoverBlock:block]]];

    double wall = [block[@"wall_seconds"] doubleValue];
    if (wall <= 0) {
        wall = [block[@"end"] timeIntervalSinceDate:block[@"start"]];
    }
    double active = [block[@"observed_seconds"] doubleValue] > 0
        ? [block[@"observed_seconds"] doubleValue]
        : [block[@"active_seconds"] doubleValue];
    if ([block[@"kind"] isEqualToString:@"gap"]) {
        [lines addObject:[NSString stringWithFormat:@"空白 %@，原因：%@", ShortDuration(wall), block[@"mode"] ?: @"未记录"]];
        [lines addObject:@"这段不会写入日历"];
        return lines;
    }
    if ([block[@"kind"] isEqualToString:@"ongoing"]) {
        [lines addObject:[NSString stringWithFormat:@"已持续 %@，还没有写入 raw", ShortDuration(wall)]];
    } else {
        [lines addObject:[NSString stringWithFormat:@"块长 %@，活跃 %@，%@",
                          ShortDuration(wall),
                          ShortDuration(active),
                          block[@"mode"] ?: @"记录"]];
    }

    NSArray *topApps = block[@"top_apps"] ?: @[];
    for (NSInteger i = 0; i < MIN(4, topApps.count); i++) {
        NSDictionary *app = topApps[i];
        [lines addObject:[NSString stringWithFormat:@"%@ %.0f%% · %@",
                          app[@"title"] ?: @"未知",
                          [app[@"ratio"] doubleValue] * 100.0,
                          ShortDuration([app[@"seconds"] doubleValue])]];
    }
    return lines;
}

- (void)drawHoverCardForBlock:(NSDictionary *)block {
    if (!block) {
        return;
    }
    NSArray<NSString *> *lines = [self hoverLinesForBlock:block];
    CGFloat width = 272;
    CGFloat height = 20 + lines.count * 18;
    CGFloat x = self.hoverPoint.x + 14;
    CGFloat y = self.hoverPoint.y + 14;
    if (x + width > self.bounds.size.width - 12) {
        x = self.hoverPoint.x - width - 14;
    }
    if (y + height > self.bounds.size.height - 12) {
        y = self.hoverPoint.y - height - 14;
    }
    x = MAX(12, MIN(x, self.bounds.size.width - width - 12));
    y = MAX(12, MIN(y, self.bounds.size.height - height - 12));

    NSRect card = NSMakeRect(x, y, width, height);
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:card xRadius:11 yRadius:11];
    NSShadow *shadow = [[NSShadow alloc] init];
    shadow.shadowColor = [NSColor.blackColor colorWithAlphaComponent:(AppIsDark() ? 0.42 : 0.16)];
    shadow.shadowBlurRadius = 18;
    shadow.shadowOffset = NSMakeSize(0, -5);
    [NSGraphicsContext saveGraphicsState];
    [shadow set];
    [PanelColor() setFill];
    [path fill];
    [NSGraphicsContext restoreGraphicsState];
    [PanelColor() setFill];
    [path fill];
    StrokeRoundedRect(card, 11, BorderColor(), 0.7);

    NSDictionary *titleAttrs = @{NSFontAttributeName: [NSFont boldSystemFontOfSize:12],
                                 NSForegroundColorAttributeName: SoftTextColor()};
    NSDictionary *bodyAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:11],
                                NSForegroundColorAttributeName: MutedTextColor()};
    for (NSInteger i = 0; i < lines.count; i++) {
        NSDictionary *attrs = i == 0 ? titleAttrs : bodyAttrs;
        [lines[i] drawInRect:NSMakeRect(card.origin.x + 10,
                                        card.origin.y + 8 + i * 18,
                                        card.size.width - 20,
                                        16)
             withAttributes:attrs];
    }
}

- (void)drawCompactHoverLabelForBlock:(NSDictionary *)block nearRect:(NSRect)nearRect timelineRect:(NSRect)timelineRect {
    if (!block) {
        return;
    }

    NSString *time = [NSString stringWithFormat:@"%@-%@",
                      [ClockString(block[@"start"]) substringToIndex:5],
                      [ClockString(block[@"end"]) substringToIndex:5]];
    NSString *line = [NSString stringWithFormat:@"%@  %@", time, [self displayTitleForHoverBlock:block]];

    NSMutableParagraphStyle *truncate = [[NSMutableParagraphStyle alloc] init];
    truncate.lineBreakMode = NSLineBreakByTruncatingTail;
    NSDictionary *attrs = @{NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold],
                            NSForegroundColorAttributeName: SoftTextColor(),
                            NSParagraphStyleAttributeName: truncate};
    CGFloat maxWidth = MIN(292.0, timelineRect.size.width - 36.0);
    CGFloat width = MIN(maxWidth, [line sizeWithAttributes:attrs].width + 36.0);
    CGFloat height = 26.0;
    CGFloat x = nearRect.origin.x + 8.0;
    CGFloat y = nearRect.origin.y - height - 6.0;
    if (y < timelineRect.origin.y + 52.0) {
        y = NSMaxY(nearRect) + 6.0;
    }
    x = MAX(timelineRect.origin.x + 12.0, MIN(x, NSMaxX(timelineRect) - width - 12.0));
    y = MAX(timelineRect.origin.y + 52.0, MIN(y, NSMaxY(timelineRect) - height - 10.0));

    NSRect pill = NSMakeRect(x, y, width, height);
    NSShadow *shadow = [[NSShadow alloc] init];
    shadow.shadowColor = [NSColor.blackColor colorWithAlphaComponent:(AppIsDark() ? 0.24 : 0.10)];
    shadow.shadowBlurRadius = 9;
    shadow.shadowOffset = NSMakeSize(0, -2);
    [NSGraphicsContext saveGraphicsState];
    [shadow set];
    FillRoundedRect(pill, 9, RaisedPanelColor());
    [NSGraphicsContext restoreGraphicsState];
    FillRoundedRect(pill, 9, RaisedPanelColor());
    StrokeRoundedRect(pill, 9, BorderColor(), 0.7);

    NSColor *color = ColorForKey([self colorKeyForBlock:block] ?: @"__other__");
    [[color colorWithAlphaComponent:0.92] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(pill.origin.x + 10, pill.origin.y + 9, 8, 8)] fill];
    [line drawInRect:NSMakeRect(pill.origin.x + 24, pill.origin.y + 6, pill.size.width - 32, 14)
      withAttributes:attrs];
}

- (void)drawCalendarEventBlockWithColor:(NSColor *)color inRect:(NSRect)eventRect hovered:(BOOL)hovered muted:(BOOL)muted {
    NSRect roundedRect = NSInsetRect(eventRect, 0, 0.25);
    CGFloat radius = MIN(8.0, MAX(3.0, roundedRect.size.height / 2.0));
    CGFloat fillAlpha = muted
        ? (AppIsDark() ? 0.18 : 0.12)
        : (hovered ? (AppIsDark() ? 0.82 : 0.84) : (AppIsDark() ? 0.62 : 0.58));
    FillRoundedRect(roundedRect, radius, [color colorWithAlphaComponent:fillAlpha]);
    CGFloat accentWidth = eventRect.size.height >= 18.0 ? 4.0 : 3.0;
    NSRect accent = NSMakeRect(roundedRect.origin.x,
                               roundedRect.origin.y + 3.0,
                               accentWidth,
                               MAX(2.0, roundedRect.size.height - 6.0));
    FillRoundedRect(accent, accentWidth / 2.0, [color colorWithAlphaComponent:(muted ? 0.42 : 0.78)]);
    if (!muted) {
        StrokeRoundedRect(roundedRect, radius, [NSColor.whiteColor colorWithAlphaComponent:(AppIsDark() ? 0.12 : 0.24)], 0.7);
    }
}

- (void)drawCompactCalendarEventBlockWithColor:(NSColor *)color
                                        inRect:(NSRect)eventRect
                                          apps:(NSArray *)apps
                                     confirmed:(BOOL)confirmed
                                         muted:(BOOL)muted {
    if (eventRect.size.height < 1.0 || eventRect.size.width < 12.0) {
        return;
    }

    NSRect roundedRect = NSInsetRect(eventRect, 0, 0.25);
    CGFloat radius = MIN(6.0, MAX(2.5, roundedRect.size.height / 2.0));
    BOOL hasMix = AppsHaveMeaningfulMix(apps);

    CGFloat fillAlpha = 0;
    if (muted) {
        fillAlpha = AppIsDark() ? 0.040 : 0.028;
    } else if (confirmed) {
        fillAlpha = AppIsDark() ? 0.30 : 0.24;
    } else {
        fillAlpha = AppIsDark() ? 0.46 : 0.36;
    }
    FillRoundedRect(roundedRect, radius, [color colorWithAlphaComponent:fillAlpha]);

    CGFloat accentWidth = confirmed ? 3.5 : 3.0;
    NSRect accentRect = NSMakeRect(roundedRect.origin.x,
                                   roundedRect.origin.y + MAX(1.0, floor((roundedRect.size.height - MAX(2.0, roundedRect.size.height - 3.0)) / 2.0)),
                                   accentWidth,
                                   MAX(2.0, roundedRect.size.height - 3.0));
    FillRoundedRect(accentRect, accentWidth / 2.0, [color colorWithAlphaComponent:(muted ? 0.20 : 0.68)]);

    if (hasMix && roundedRect.size.width >= 36 && roundedRect.size.height >= 2.0) {
        CGFloat stripHeight = MIN(MAX(2.4, roundedRect.size.height - 3.0), 7.0);
        NSRect strip = NSMakeRect(roundedRect.origin.x + 5.0,
                                  roundedRect.origin.y + floor((roundedRect.size.height - stripHeight) / 2.0),
                                  MAX(0, roundedRect.size.width - 10.0),
                                  stripHeight);
        if (strip.size.width >= 18.0) {
            [self drawSubtleStackedRatioBarForApps:apps inRect:strip];
        }
    }

    if (confirmed || muted) {
        StrokeRoundedRect(NSInsetRect(roundedRect, 0.5, 0.5),
                          radius,
                          [color colorWithAlphaComponent:(muted ? 0.080 : (AppIsDark() ? 0.18 : 0.14))],
                          0.45);
    }
}

- (void)drawCalendarStateForBlock:(NSDictionary *)block inRect:(NSRect)eventRect color:(NSColor *)color hovered:(BOOL)hovered {
    BOOL confirmed = [block[@"calendar_confirmed"] boolValue];
    if (eventRect.size.height < 6 || eventRect.size.width < 28) {
        return;
    }
    CGFloat radius = MIN(8.0, MAX(3.0, eventRect.size.height / 2.0));
    NSRect borderRect = NSInsetRect(eventRect, 1.0, 1.0);
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:borderRect xRadius:radius yRadius:radius];
    if (confirmed) {
        [path setLineWidth:1.1];
        [[NSColor.whiteColor colorWithAlphaComponent:(AppIsDark() ? 0.50 : 0.68)] setStroke];
        [path stroke];

        if (eventRect.size.height >= 8 && eventRect.size.width >= 44) {
            CGFloat size = eventRect.size.height >= 22 ? 12.0 : 6.0;
            CGFloat insetRight = eventRect.size.height >= 22 ? 7.0 : 6.0;
            NSRect badge = NSMakeRect(NSMaxX(eventRect) - size - insetRight,
                                      eventRect.origin.y + floor((eventRect.size.height - size) / 2.0),
                                      size,
                                      size);
            NSColor *badgeFill = eventRect.size.height >= 22
                ? [NSColor.whiteColor colorWithAlphaComponent:(AppIsDark() ? 0.24 : 0.34)]
                : [NSColor.systemGreenColor colorWithAlphaComponent:(AppIsDark() ? 0.82 : 0.76)];
            FillRoundedRect(badge, size / 2.0, badgeFill);
            if (eventRect.size.height >= 22) {
                NSDictionary *attrs = @{NSFontAttributeName: [NSFont systemFontOfSize:8 weight:NSFontWeightBold],
                                        NSForegroundColorAttributeName: NSColor.whiteColor};
                DrawCenteredString(@"✓", badge, attrs);
            }
        }
    } else {
        CGFloat dash[] = {4.0, 3.5};
        [path setLineDash:dash count:2 phase:0];
        [path setLineWidth:hovered ? 1.0 : 0.8];
        [[NSColor.whiteColor colorWithAlphaComponent:(hovered ? 0.54 : (AppIsDark() ? 0.26 : 0.38))] setStroke];
        [path stroke];

        if (!hovered || eventRect.size.height < 18 || eventRect.size.width < 54) {
            return;
        }
        CGFloat size = 10;
        NSRect badge = NSMakeRect(NSMaxX(eventRect) - size - 7, eventRect.origin.y + 6, size, size);
        StrokeRoundedRect(NSInsetRect(badge, 2.5, 2.5), 3, [NSColor.whiteColor colorWithAlphaComponent:0.72], 1.0);
    }
}

- (void)drawActivityRailBlockWithColor:(NSColor *)color inRect:(NSRect)eventRect hovered:(BOOL)hovered {
    NSRect ambientRect = hovered ? eventRect : CenteredTimelineRailRect(eventRect, 3.2);
    [[color colorWithAlphaComponent:(hovered ? 0.20 : (AppIsDark() ? 0.080 : 0.046))] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:ambientRect xRadius:4 yRadius:4] fill];
    if (hovered) {
        [[color colorWithAlphaComponent:0.34] setStroke];
        NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(ambientRect, 0.5, 0.5) xRadius:4 yRadius:4];
        [path setLineWidth:0.8];
        [path stroke];
    }
}

- (void)drawActivitySpineForBlock:(NSDictionary *)block inRect:(NSRect)eventRect layout:(NSDictionary *)layout {
    if (eventRect.size.height < 1.0) {
        return;
    }

    BOOL hasHighlight = self.highlightedAppKey.length > 0;
    BOOL highlighted = hasHighlight && [self block:block containsAppKey:self.highlightedAppKey];
    BOOL gap = [block[@"kind"] isEqualToString:@"gap"];
    NSDictionary *dominantApp = [block[@"top_apps"] firstObject];
    NSString *dominantKey = dominantApp[@"key"] ?: block[@"key"];

    CGFloat xInset = gap ? 4.0 : 2.0;
    CGFloat yInset = eventRect.size.height >= 5.0 ? (gap ? 1.7 : 0.8) : 0.0;
    NSRect spine = NSInsetRect(eventRect, xInset, yInset);
    spine.size.height = MAX(gap ? 1.0 : 1.8, spine.size.height);
    NSColor *color = nil;
    if (highlighted) {
        color = ColorForKey(self.highlightedAppKey);
    } else if (gap) {
        color = DynamicRGB(174, 174, 178, 118, 118, 128);
    } else if (dominantKey.length > 0 && ![dominantKey hasPrefix:@"__gap_"]) {
        color = ColorForKey(dominantKey);
    } else {
        color = DynamicRGB(118, 118, 128, 142, 142, 147);
    }
    CGFloat activeRatio = [block[@"active_ratio"] doubleValue] > 0 ? [block[@"active_ratio"] doubleValue] : 1.0;
    CGFloat baseAlpha = 0;
    if (highlighted) {
        baseAlpha = AppIsDark() ? 0.22 : 0.17;
    } else if (gap) {
        baseAlpha = AppIsDark() ? 0.018 : 0.012;
    } else {
        baseAlpha = AppIsDark() ? 0.058 : 0.034;
    }
    if (hasHighlight && !highlighted) {
        baseAlpha *= 0.36;
    }
    CGFloat alpha = baseAlpha * (0.45 + 0.55 * Clamp01(activeRatio));
    FillRoundedRect(spine, MIN(5.0, MAX(2.0, spine.size.height / 2.0)), [color colorWithAlphaComponent:alpha]);

    if (!gap && eventRect.size.height >= 3.0) {
        NSRect accent = NSMakeRect(eventRect.origin.x + 1.0,
                                   eventRect.origin.y + yInset,
                                   highlighted ? 3.0 : 2.0,
                                   MAX(1.8, eventRect.size.height - yInset * 2.0));
        FillRoundedRect(accent, accent.size.width / 2.0, [color colorWithAlphaComponent:alpha * 2.2]);
    }
}

- (void)drawActivityTraceForBlock:(NSDictionary *)block inRect:(NSRect)eventRect layout:(NSDictionary *)layout visualBlocks:(NSArray *)visualBlocks {
    NSDate *blockStart = block[@"start"];
    NSDate *blockEnd = block[@"end"];
    if (!blockStart || !blockEnd || [blockEnd compare:blockStart] != NSOrderedDescending) {
        [self drawActivitySpineForBlock:block inRect:eventRect layout:layout];
        return;
    }

    NSMutableArray<NSDictionary *> *visibleRanges = [@[@{@"start": blockStart, @"end": blockEnd}] mutableCopy];
    for (NSDictionary *calendarBlock in visualBlocks ?: @[]) {
        if (![calendarBlock[@"visual_layer"] isEqualToString:@"calendar"]) {
            continue;
        }
        NSDate *calendarStart = calendarBlock[@"start"];
        NSDate *calendarEnd = calendarBlock[@"end"];
        if (!calendarStart || !calendarEnd ||
            [calendarEnd compare:blockStart] != NSOrderedDescending ||
            [calendarStart compare:blockEnd] != NSOrderedAscending) {
            continue;
        }

        NSMutableArray<NSDictionary *> *nextRanges = [NSMutableArray array];
        for (NSDictionary *range in visibleRanges) {
            NSDate *rangeStart = range[@"start"];
            NSDate *rangeEnd = range[@"end"];
            if ([calendarStart compare:rangeEnd] != NSOrderedAscending ||
                [calendarEnd compare:rangeStart] != NSOrderedDescending) {
                [nextRanges addObject:range];
                continue;
            }

            NSDate *leftEnd = [calendarStart compare:rangeEnd] == NSOrderedAscending ? calendarStart : rangeEnd;
            NSDate *rightStart = [calendarEnd compare:rangeStart] == NSOrderedDescending ? calendarEnd : rangeStart;
            if ([leftEnd timeIntervalSinceDate:rangeStart] > MinimumRecordedSegmentSeconds()) {
                [nextRanges addObject:@{@"start": rangeStart, @"end": leftEnd}];
            }
            if ([rangeEnd timeIntervalSinceDate:rightStart] > MinimumRecordedSegmentSeconds()) {
                [nextRanges addObject:@{@"start": rightStart, @"end": rangeEnd}];
            }
        }
        visibleRanges = nextRanges;
        if (visibleRanges.count == 0) {
            return;
        }
    }

    double totalSeconds = [blockEnd timeIntervalSinceDate:blockStart];
    if (totalSeconds <= 0) {
        return;
    }
    for (NSDictionary *range in visibleRanges) {
        NSDate *rangeStart = range[@"start"];
        NSDate *rangeEnd = range[@"end"];
        double startOffset = [rangeStart timeIntervalSinceDate:blockStart] / totalSeconds;
        double endOffset = [rangeEnd timeIntervalSinceDate:blockStart] / totalSeconds;
        CGFloat y = eventRect.origin.y + eventRect.size.height * Clamp01(startOffset);
        CGFloat height = eventRect.size.height * MAX(0, Clamp01(endOffset) - Clamp01(startOffset));
        if (height < 0.8) {
            continue;
        }
        NSRect clippedRect = NSMakeRect(eventRect.origin.x, y, eventRect.size.width, height);
        [self drawActivitySpineForBlock:block inRect:clippedRect layout:layout];
    }
}

- (void)drawProportionalFillForMixedBlock:(NSDictionary *)block inRect:(NSRect)eventRect hovered:(BOOL)hovered muted:(BOOL)muted {
    NSArray *topApps = block[@"top_apps"] ?: @[];
    if (topApps.count == 0) {
        [self drawCalendarEventBlockWithColor:NSColor.systemGrayColor inRect:eventRect hovered:hovered muted:muted];
        return;
    }

    NSRect outerRect = NSInsetRect(eventRect, 0, 0.25);
    CGFloat radius = MIN(8.0, MAX(5.0, outerRect.size.height / 4.0));
    NSBezierPath *clipPath = [NSBezierPath bezierPathWithRoundedRect:outerRect xRadius:radius yRadius:radius];
    [NSGraphicsContext saveGraphicsState];
    [clipPath addClip];

    double totalRatio = 0;
    double totalSeconds = 0;
    for (NSDictionary *app in topApps) {
        totalRatio += MAX(0, [app[@"ratio"] doubleValue]);
        totalSeconds += MAX(0, [app[@"seconds"] doubleValue]);
    }

    NSMutableArray<NSDictionary *> *visibleApps = [NSMutableArray array];
    double visibleTotal = 0;
    for (NSDictionary *app in topApps) {
        double rawWeight = totalRatio > 0
            ? MAX(0, [app[@"ratio"] doubleValue])
            : MAX(0, [app[@"seconds"] doubleValue]);
        double denominator = totalRatio > 0 ? totalRatio : totalSeconds;
        double normalizedWeight = denominator > 0 ? rawWeight / denominator : 0;
        if (normalizedWeight > 0.006) {
            [visibleApps addObject:app];
            visibleTotal += rawWeight;
        }
    }
    if (visibleApps.count == 0 || visibleTotal <= 0) {
        [visibleApps addObject:topApps.firstObject];
        visibleTotal = totalRatio > 0
            ? MAX(0.001, [topApps.firstObject[@"ratio"] doubleValue])
            : MAX(0.001, [topApps.firstObject[@"seconds"] doubleValue]);
    }

    NSDictionary *dominantApp = visibleApps.firstObject ?: topApps.firstObject;
    NSString *dominantKey = dominantApp[@"key"] ?: @"__other__";
    BOOL dominantOther = [dominantKey isEqualToString:@"__other__"];
    NSColor *dominantColor = dominantOther ? NSColor.systemGrayColor : ColorForKey(dominantKey);

    if (muted) {
        CGFloat railHeight = hovered ? 6.0 : 4.2;
        NSRect railRect = CenteredTimelineRailRect(outerRect, railHeight);
        NSColor *trackFill = [dominantColor colorWithAlphaComponent:(hovered
            ? (AppIsDark() ? 0.15 : 0.085)
            : (AppIsDark() ? 0.075 : 0.040))];
        FillRoundedRect(railRect, railRect.size.height / 2.0, trackFill);

        NSRect strip = NSInsetRect(railRect, hovered ? 1.0 : 0.7, hovered ? 1.0 : 0.7);
        if (strip.size.width >= 8 && strip.size.height >= 1.4) {
            [self drawStackedRatioBarForApps:visibleApps inRect:strip];
        }
        if (hovered) {
            StrokeRoundedRect(railRect, railRect.size.height / 2.0, [dominantColor colorWithAlphaComponent:(AppIsDark() ? 0.22 : 0.16)], 0.55);
        }
        [NSGraphicsContext restoreGraphicsState];
        return;
    }

    CGFloat baseAlpha = hovered ? (AppIsDark() ? 0.78 : 0.76) : (AppIsDark() ? 0.64 : 0.62);
    if (self.highlightedAppKey.length > 0 && ![self block:block containsAppKey:self.highlightedAppKey]) {
        baseAlpha *= 0.48;
    }
    FillRoundedRect(outerRect, radius, [dominantColor colorWithAlphaComponent:(AppIsDark() ? 0.14 : 0.10)]);

    CGFloat cursor = outerRect.origin.x;
    for (NSDictionary *app in visibleApps) {
        double rawWeight = totalRatio > 0
            ? MAX(0, [app[@"ratio"] doubleValue])
            : MAX(0, [app[@"seconds"] doubleValue]);
        double ratio = visibleTotal > 0 ? rawWeight / visibleTotal : 0;
        if (ratio <= 0) {
            continue;
        }
        BOOL lastVisible = app == visibleApps.lastObject;
        CGFloat width = lastVisible ? NSMaxX(outerRect) - cursor : outerRect.size.width * ratio;
        width = MAX(1.0, MIN(width, NSMaxX(outerRect) - cursor));
        if (width <= 0) {
            break;
        }
        NSString *key = app[@"key"] ?: @"__other__";
        BOOL emphasized = self.highlightedAppKey.length == 0 || [self.highlightedAppKey isEqualToString:key];
        CGFloat appAlpha = emphasized ? baseAlpha : baseAlpha * 0.38;
        [[ColorForKey(key) colorWithAlphaComponent:appAlpha] setFill];
        NSRectFill(NSMakeRect(cursor, outerRect.origin.y, width, outerRect.size.height));
        if (!lastVisible && width >= 1.0) {
            [[SegmentSeparatorColor() colorWithAlphaComponent:(AppIsDark() ? 0.48 : 0.58)] setFill];
            NSRectFill(NSMakeRect(cursor + width - 0.5, outerRect.origin.y + 1.0, 1.0, MAX(0, outerRect.size.height - 2.0)));
        }
        cursor += width;
    }

    NSGradient *softWash = [[NSGradient alloc] initWithStartingColor:[NSColor.whiteColor colorWithAlphaComponent:(AppIsDark() ? 0.12 : 0.20)]
                                                         endingColor:[NSColor.whiteColor colorWithAlphaComponent:0.015]];
    [softWash drawInRect:NSInsetRect(outerRect, 0.5, 0.5) angle:90];

    CGFloat stripHeight = outerRect.size.height >= 32 ? 4.5 : (outerRect.size.height >= 18 ? 3.2 : 0);
    CGFloat stripInsetX = outerRect.size.width >= 92 ? 8.0 : 5.0;
    CGFloat stripBottomInset = outerRect.size.height >= 28 ? 5.0 : 3.0;
    NSRect strip = NSMakeRect(outerRect.origin.x + stripInsetX,
                              NSMaxY(outerRect) - stripBottomInset - stripHeight,
                              MAX(0, outerRect.size.width - stripInsetX * 2.0),
                              stripHeight);
    if (strip.size.width >= 18 && strip.size.height >= 2.0 && outerRect.size.height >= 18) {
        [self drawStackedRatioBarForApps:visibleApps inRect:strip];
    }

    BOOL drawLabels = outerRect.size.height >= 32 && outerRect.size.width >= 150;
    if (drawLabels) {
        NSMutableParagraphStyle *truncate = [[NSMutableParagraphStyle alloc] init];
        truncate.lineBreakMode = NSLineBreakByTruncatingTail;
        NSDictionary *titleAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold],
                                     NSForegroundColorAttributeName: [NSColor.whiteColor colorWithAlphaComponent:(AppIsDark() ? 0.95 : 0.92)],
                                     NSParagraphStyleAttributeName: truncate};
        NSDictionary *subtitleAttrs = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:9.5 weight:NSFontWeightRegular],
                                        NSForegroundColorAttributeName: [NSColor.whiteColor colorWithAlphaComponent:(AppIsDark() ? 0.70 : 0.76)],
                                        NSParagraphStyleAttributeName: truncate};
        NSString *title = block[@"title"] ?: @"混合工作";
        if (title.length == 0) {
            title = @"混合工作";
        }

        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        for (NSInteger i = 0; i < MIN(2, (NSInteger)visibleApps.count); i++) {
            NSDictionary *app = visibleApps[i];
            double rawWeight = totalRatio > 0
                ? MAX(0, [app[@"ratio"] doubleValue])
                : MAX(0, [app[@"seconds"] doubleValue]);
            double displayRatio = [app[@"ratio"] doubleValue] > 0
                ? [app[@"ratio"] doubleValue]
                : (visibleTotal > 0 ? rawWeight / visibleTotal : 0);
            NSString *name = app[@"title"] ?: @"未知";
            if (name.length > 0) {
                [parts addObject:[NSString stringWithFormat:@"%@ %.0f%%", name, displayRatio * 100.0]];
            }
        }
        NSString *subtitle = parts.count > 0 ? [parts componentsJoinedByString:@" · "] : @"多应用切换";
        CGFloat textX = outerRect.origin.x + 9.0;
        CGFloat textWidth = outerRect.size.width - 18.0;
        [title drawInRect:NSMakeRect(textX, outerRect.origin.y + 5.0, textWidth, 14.0) withAttributes:titleAttrs];
        if (strip.origin.y - outerRect.origin.y >= 27.0) {
            [subtitle drawInRect:NSMakeRect(textX, outerRect.origin.y + 20.0, textWidth, 12.0) withAttributes:subtitleAttrs];
        }
    }

    if (outerRect.size.height >= 12) {
        [[NSColor.whiteColor colorWithAlphaComponent:(AppIsDark() ? 0.060 : 0.12)] setFill];
        NSRectFill(NSMakeRect(outerRect.origin.x + 1.0, outerRect.origin.y + 1.0, outerRect.size.width - 2.0, 0.8));
    }
    [NSGraphicsContext restoreGraphicsState];

    StrokeRoundedRect(outerRect, radius, [NSColor.whiteColor colorWithAlphaComponent:(AppIsDark() ? 0.16 : 0.28)], 0.65);
}

- (void)drawInlineRatioStripForApps:(NSArray *)apps inRect:(NSRect)eventRect {
    if (!AppsHaveMeaningfulMix(apps) || eventRect.size.width < 64 || eventRect.size.height < 16) {
        return;
    }

    CGFloat height = eventRect.size.height >= 26 ? 5.0 : 3.5;
    CGFloat insetX = eventRect.size.height >= 24 ? 7.0 : 5.0;
    NSRect strip = NSMakeRect(eventRect.origin.x + insetX,
                              NSMaxY(eventRect) - height - 4.0,
                              eventRect.size.width - insetX * 2.0,
                              height);
    [self drawStackedRatioBarForApps:apps inRect:strip];
}

- (NSDictionary *)primaryDetailBlock {
    if (self.detailTitleEditBlock) {
        return self.detailTitleEditBlock;
    }
    if (self.detailProjectEditBlock) {
        return self.detailProjectEditBlock;
    }
    if (self.hoveredBlock) {
        return self.hoveredBlock;
    }
    if (self.selectedBlock) {
        return self.selectedBlock;
    }
    NSArray *candidates = self.stats[@"candidates"] ?: @[];
    return candidates.firstObject;
}

- (void)drawDonutForApps:(NSArray *)apps inRect:(NSRect)rect backgroundColor:(NSColor *)backgroundColor {
    if (apps.count == 0) {
        [[NSColor.tertiaryLabelColor colorWithAlphaComponent:0.16] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:rect] fill];
        [backgroundColor setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(rect, rect.size.width * 0.28, rect.size.height * 0.28)] fill];
        return;
    }

    double totalSeconds = 0;
    double totalWeight = 0;
    for (NSDictionary *app in apps) {
        totalSeconds += MAX(0, [app[@"seconds"] doubleValue]);
        totalWeight += MAX(0, [app[@"ratio"] doubleValue]);
    }
    if (totalSeconds <= 0) {
        totalSeconds = 1;
    }
    if (totalWeight <= 0) {
        totalWeight = 1;
    }

    NSPoint center = NSMakePoint(NSMidX(rect), NSMidY(rect));
    CGFloat radius = MIN(rect.size.width, rect.size.height) / 2.0;
    FillRoundedRect(rect, radius, QuietControlFillColor());

    CGFloat startAngle = -90;
    for (NSDictionary *app in apps) {
        double ratio = [app[@"ratio"] doubleValue] > 0
            ? [app[@"ratio"] doubleValue] / totalWeight
            : [app[@"seconds"] doubleValue] / totalSeconds;
        if (ratio <= 0.005) {
            continue;
        }
        CGFloat endAngle = startAngle + ratio * 360.0;
        NSString *key = app[@"key"] ?: @"__other__";
        BOOL emphasized = self.highlightedAppKey.length == 0 || [self.highlightedAppKey isEqualToString:key];
        [[ColorForKey(key) colorWithAlphaComponent:(emphasized ? 0.86 : 0.34)] setFill];
        NSBezierPath *slice = [NSBezierPath bezierPath];
        [slice moveToPoint:center];
        [slice appendBezierPathWithArcWithCenter:center radius:radius startAngle:startAngle endAngle:endAngle clockwise:NO];
        [slice closePath];
        [slice fill];
        startAngle = endAngle;
    }

    [backgroundColor setFill];
    NSRect hole = NSInsetRect(rect, radius * 0.50, radius * 0.50);
    [[NSBezierPath bezierPathWithOvalInRect:hole] fill];
    [[NSColor.whiteColor colorWithAlphaComponent:(AppIsDark() ? 0.10 : 0.22)] setStroke];
    NSBezierPath *outer = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(rect, 0.5, 0.5)];
    [outer setLineWidth:0.8];
    [outer stroke];
    [[NSColor.whiteColor colorWithAlphaComponent:(AppIsDark() ? 0.08 : 0.18)] setStroke];
    NSBezierPath *inner = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(hole, 0.5, 0.5)];
    [inner setLineWidth:0.7];
    [inner stroke];

    NSDictionary *firstApp = apps.firstObject;
    double firstRatio = firstApp ? [firstApp[@"ratio"] doubleValue] : 0;
    if (firstRatio > 0 && rect.size.width >= 58) {
        NSString *label = [NSString stringWithFormat:@"%.0f%%", firstRatio * 100.0];
        NSDictionary *centerAttrs = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightSemibold],
                                      NSForegroundColorAttributeName: SoftTextColor()};
        DrawCenteredString(label, NSInsetRect(hole, -5, -2), centerAttrs);
    }
}

- (void)drawStackedRatioBarForApps:(NSArray *)apps inRect:(NSRect)rect {
    CGFloat radius = rect.size.height / 2.0;
    NSBezierPath *clipPath = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:radius yRadius:radius];
    [NSGraphicsContext saveGraphicsState];
    [clipPath addClip];
    [QuietControlFillColor() setFill];
    NSRectFill(rect);

    double total = 0;
    for (NSDictionary *app in apps ?: @[]) {
        double ratio = [app[@"ratio"] doubleValue];
        total += MAX(0, ratio);
    }
    if (total <= 0) {
        total = 1;
    }

    NSMutableArray<NSDictionary *> *visibleApps = [NSMutableArray array];
    for (NSDictionary *app in apps ?: @[]) {
        double ratio = MAX(0, [app[@"ratio"] doubleValue]) / total;
        if (ratio > 0.006) {
            [visibleApps addObject:app];
        }
    }

    CGFloat gap = 0.0;
    CGFloat availableWidth = MAX(1.0, rect.size.width - gap * MAX(0, (NSInteger)visibleApps.count - 1));
    CGFloat cursor = rect.origin.x;
    for (NSInteger i = 0; i < apps.count; i++) {
        NSDictionary *app = apps[i];
        double ratio = MAX(0, [app[@"ratio"] doubleValue]) / total;
        if (ratio <= 0.006) {
            continue;
        }
        BOOL lastVisible = app == visibleApps.lastObject;
        CGFloat width = lastVisible ? NSMaxX(rect) - cursor : availableWidth * ratio;
        width = MAX(1.0, MIN(width, NSMaxX(rect) - cursor));
        if (width <= 0) {
            break;
        }
        NSString *key = app[@"key"] ?: @"__other__";
        BOOL emphasized = self.highlightedAppKey.length == 0 || [self.highlightedAppKey isEqualToString:key];
        [[ColorForKey(key) colorWithAlphaComponent:(emphasized ? 0.92 : 0.32)] setFill];
        NSRectFill(NSMakeRect(cursor, rect.origin.y, width, rect.size.height));
        if (!lastVisible && width >= 1.0) {
            [[SegmentSeparatorColor() colorWithAlphaComponent:0.64] setFill];
            NSRectFill(NSMakeRect(cursor + width - 0.5, rect.origin.y, 1.0, rect.size.height));
        }
        cursor += width + gap;
    }

    [NSGraphicsContext restoreGraphicsState];
    StrokeRoundedRect(rect, radius, [NSColor.whiteColor colorWithAlphaComponent:(AppIsDark() ? 0.08 : 0.22)], 0.6);
}

- (void)drawSubtleStackedRatioBarForApps:(NSArray *)apps inRect:(NSRect)rect {
    CGFloat radius = rect.size.height / 2.0;
    NSBezierPath *clipPath = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:radius yRadius:radius];
    [NSGraphicsContext saveGraphicsState];
    [clipPath addClip];
    [[QuietControlFillColor() colorWithAlphaComponent:(AppIsDark() ? 0.42 : 0.50)] setFill];
    NSRectFill(rect);

    double total = 0;
    for (NSDictionary *app in apps ?: @[]) {
        total += MAX(0, [app[@"ratio"] doubleValue]);
    }
    if (total <= 0) {
        total = 1;
    }

    CGFloat cursor = rect.origin.x;
    NSMutableArray<NSDictionary *> *visibleApps = [NSMutableArray array];
    for (NSDictionary *app in apps ?: @[]) {
        double ratio = MAX(0, [app[@"ratio"] doubleValue]) / total;
        if (ratio > 0.006) {
            [visibleApps addObject:app];
        }
    }

    for (NSDictionary *app in visibleApps) {
        double ratio = MAX(0, [app[@"ratio"] doubleValue]) / total;
        BOOL lastVisible = app == visibleApps.lastObject;
        CGFloat width = lastVisible ? NSMaxX(rect) - cursor : rect.size.width * ratio;
        width = MAX(1.0, MIN(width, NSMaxX(rect) - cursor));
        if (width <= 0) {
            break;
        }
        NSString *key = app[@"key"] ?: @"__other__";
        BOOL emphasized = self.highlightedAppKey.length == 0 || [self.highlightedAppKey isEqualToString:key];
        [[ColorForKey(key) colorWithAlphaComponent:(emphasized ? (AppIsDark() ? 0.56 : 0.48) : 0.24)] setFill];
        NSRectFill(NSMakeRect(cursor, rect.origin.y, width, rect.size.height));
        if (!lastVisible && width >= 1.0) {
            [[SegmentSeparatorColor() colorWithAlphaComponent:0.46] setFill];
            NSRectFill(NSMakeRect(cursor + width - 0.5, rect.origin.y, 1.0, rect.size.height));
        }
        cursor += width;
    }

    [NSGraphicsContext restoreGraphicsState];
    StrokeRoundedRect(rect, radius, [NSColor.whiteColor colorWithAlphaComponent:(AppIsDark() ? 0.050 : 0.12)], 0.45);
}

- (void)drawSidebarInRect:(NSRect)rect {
    DrawSoftPanel(rect, SidebarColor());

    NSMutableParagraphStyle *truncate = [[NSMutableParagraphStyle alloc] init];
    truncate.lineBreakMode = NSLineBreakByTruncatingTail;
    NSDictionary *eyebrowAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
                                   NSForegroundColorAttributeName: MutedTextColor()};
    NSDictionary *titleAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:22 weight:NSFontWeightSemibold],
                                 NSForegroundColorAttributeName: SoftTextColor()};
    NSDictionary *labelAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightMedium],
                                 NSForegroundColorAttributeName: SoftTextColor(),
                                 NSParagraphStyleAttributeName: truncate};
    NSDictionary *captionAttrs = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular],
                                   NSForegroundColorAttributeName: MutedTextColor(),
                                   NSParagraphStyleAttributeName: truncate};
    NSDictionary *metricCaptionAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:10 weight:NSFontWeightMedium],
                                         NSForegroundColorAttributeName: MutedTextColor(),
                                         NSParagraphStyleAttributeName: truncate};
    NSDictionary *metricValueAttrs = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightSemibold],
                                       NSForegroundColorAttributeName: SoftTextColor(),
                                       NSParagraphStyleAttributeName: truncate};
    NSDictionary *sectionAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold],
                                   NSForegroundColorAttributeName: SoftTextColor()};
    NSDictionary *chipAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold],
                                NSForegroundColorAttributeName: SoftTextColor(),
                                NSParagraphStyleAttributeName: truncate};
    NSDictionary *disabledChipAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
                                        NSForegroundColorAttributeName: MutedTextColor(),
                                        NSParagraphStyleAttributeName: truncate};

    NSDictionary *scopeStats = [self selectedSidebarScopeStats];
    NSString *dateTitle = self.stats[@"date_title"] ?: @"今日";
    NSString *dateSubtitle = self.stats[@"date_subtitle"] ?: @"";
    [dateTitle drawInRect:NSMakeRect(rect.origin.x + 16, rect.origin.y + 16, rect.size.width - 92, 26) withAttributes:titleAttrs];

    NSRect previousDate = [self sidebarDatePreviousRect];
    NSRect nextDate = [self sidebarDateNextRect];
    FillRoundedRect(previousDate, 7, ToolbarControlFillColor());
    FillRoundedRect(nextDate, 7, ToolbarControlFillColor());
    StrokeRoundedRect(previousDate, 7, BorderColor(), 0.5);
    StrokeRoundedRect(nextDate, 7, BorderColor(), 0.5);
    NSDictionary *dateButtonAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold],
                                      NSForegroundColorAttributeName: SoftTextColor()};
    BOOL isToday = [self.stats[@"is_today"] boolValue];
    NSMutableDictionary *nextAttrs = [dateButtonAttrs mutableCopy];
    if (isToday) {
        nextAttrs[NSForegroundColorAttributeName] = [MutedTextColor() colorWithAlphaComponent:0.52];
    }
    DrawCenteredString(@"‹", previousDate, dateButtonAttrs);
    DrawCenteredString(@"›", nextDate, nextAttrs);

    [dateSubtitle drawAtPoint:NSMakePoint(rect.origin.x + 16, rect.origin.y + 46) withAttributes:eyebrowAttrs];

    double total = [scopeStats[@"total_seconds"] doubleValue];
    NSInteger count = [scopeStats[@"segment_count"] integerValue];
    NSRect summaryBand = NSMakeRect(rect.origin.x + 16, rect.origin.y + 68, rect.size.width - 32, 32);
    CGFloat summaryColumnWidth = summaryBand.size.width / 2.0;
    [@"活跃" drawInRect:NSMakeRect(summaryBand.origin.x, summaryBand.origin.y, summaryColumnWidth - 8, 12)
        withAttributes:metricCaptionAttrs];
    [ShortDuration(total) drawInRect:NSMakeRect(summaryBand.origin.x, summaryBand.origin.y + 15, summaryColumnWidth - 8, 16)
                      withAttributes:metricValueAttrs];
    NSBezierPath *summarySeparator = [NSBezierPath bezierPath];
    [CalendarGridStrokeColor(0.050, 0.055) setStroke];
    [summarySeparator moveToPoint:NSMakePoint(summaryBand.origin.x + summaryColumnWidth, summaryBand.origin.y + 4)];
    [summarySeparator lineToPoint:NSMakePoint(summaryBand.origin.x + summaryColumnWidth, NSMaxY(summaryBand) - 4)];
    [summarySeparator setLineWidth:0.55];
    [summarySeparator stroke];
    [@"片段" drawInRect:NSMakeRect(summaryBand.origin.x + summaryColumnWidth + 12, summaryBand.origin.y, summaryColumnWidth - 12, 12)
        withAttributes:metricCaptionAttrs];
    NSString *countText = [NSString stringWithFormat:@"%ld", (long)count];
    [countText drawInRect:NSMakeRect(summaryBand.origin.x + summaryColumnWidth + 12, summaryBand.origin.y + 15, summaryColumnWidth - 12, 16)
           withAttributes:metricValueAttrs];

    NSArray *scopeTitles = @[self.stats[@"day_scope_title"] ?: @"今日", @"本周", @"本月"];
    NSRect scopeGroup = NSUnionRect([self scopeChipRectAtIndex:0], [self scopeChipRectAtIndex:2]);
    FillRoundedRect(scopeGroup, 9, QuietControlFillColor());
    for (NSInteger i = 0; i < scopeTitles.count; i++) {
        NSRect chip = [self scopeChipRectAtIndex:i];
        BOOL active = i == self.selectedScopeIndex;
        if (active) {
            FillRoundedRect(NSInsetRect(chip, 2, 2), 7, PressedControlFillColor());
        }
        NSDictionary *attrs = active ? chipAttrs : disabledChipAttrs;
        DrawCenteredString(scopeTitles[i], chip, attrs);
    }

    CGFloat y = rect.origin.y + 154;
    [@"项目" drawAtPoint:NSMakePoint(rect.origin.x + 16, y) withAttributes:sectionAttrs];
    NSArray *projects = self.stats[@"project_labels"] ?: @[];
    NSRect allChip = [self projectChipRectAtIndex:0];
    BOOL allActive = self.selectedProjectFilter.length == 0;
    FillRoundedRect(allChip, 8, allActive ? PillFillColor() : ToolbarControlFillColor());
    if (allActive) {
        StrokeRoundedRect(allChip, 8, [NSColor.controlAccentColor colorWithAlphaComponent:(AppIsDark() ? 0.18 : 0.14)], 0.45);
    }
    DrawCenteredString(@"全部", allChip, allActive ? chipAttrs : disabledChipAttrs);

    for (NSInteger i = 0; i < MIN(3, projects.count); i++) {
        NSString *project = projects[i];
        NSRect chip = [self projectChipRectAtIndex:i + 1];
        BOOL active = [self.selectedProjectFilter isEqualToString:project];
        NSColor *projectColor = ProjectColorForTitle(project);
        if (active) {
            FillRoundedRect(chip, 8, [projectColor colorWithAlphaComponent:(AppIsDark() ? 0.22 : 0.14)]);
        }
        [[projectColor colorWithAlphaComponent:0.86] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(chip.origin.x + 10, chip.origin.y + 9, 6, 6)] fill];
        [project drawInRect:NSMakeRect(chip.origin.x + 24, chip.origin.y + 5, chip.size.width - 32, 16)
             withAttributes:active ? chipAttrs : disabledChipAttrs];
    }
    y = [self sidebarAppSectionY];
    [@"应用排行" drawAtPoint:NSMakePoint(rect.origin.x + 16, y) withAttributes:sectionAttrs];
    y = [self sidebarAppListStartY];

    NSArray *topApps = scopeStats[@"top_apps"] ?: @[];
    double maxSeconds = MAX(1, [topApps.firstObject[@"seconds"] doubleValue]);
    NSInteger maxRows = [self sidebarAppRowCapacity];
    for (NSInteger i = 0; i < MIN(maxRows, topApps.count); i++) {
        NSDictionary *app = topApps[i];
        NSString *key = app[@"key"] ?: @"__other__";
        NSColor *appColor = ColorForKey(key);
        NSString *name = app[@"title"] ?: @"未知";
        BOOL activeLegend = [self.highlightedAppKey isEqualToString:key];
        NSRect rowRect = [self sidebarAppRowRectAtIndex:i];
        if (activeLegend) {
            FillRoundedRect(rowRect, 9, [appColor colorWithAlphaComponent:(AppIsDark() ? 0.22 : 0.13)]);
            StrokeRoundedRect(rowRect, 9, [appColor colorWithAlphaComponent:(AppIsDark() ? 0.34 : 0.25)], 0.7);
        }
        CGFloat timeWidth = 62;
        CGFloat iconSize = 17;
        CGFloat iconX = rowRect.origin.x + 10;
        CGFloat nameX = iconX + iconSize + 8;
        CGFloat nameWidth = MAX(60, NSMaxX(rowRect) - timeWidth - 10 - nameX);
        CGFloat contentY = rowRect.origin.y + 5;
        DrawAppIdentityMark(app, key, NSMakeRect(iconX, contentY, iconSize, iconSize));
        [name drawInRect:NSMakeRect(nameX, contentY, nameWidth, 16) withAttributes:labelAttrs];
        [ShortDuration([app[@"seconds"] doubleValue]) drawInRect:NSMakeRect(NSMaxX(rowRect) - timeWidth - 10, contentY, timeWidth, 16) withAttributes:captionAttrs];
        NSRect track = NSMakeRect(nameX, rowRect.origin.y + 26, NSMaxX(rowRect) - 10 - nameX, 4);
        FillRoundedRect(track, 2.0, DynamicRGB(225, 225, 232, 58, 58, 63));
        NSRect fill = track;
        fill.size.width *= [app[@"seconds"] doubleValue] / maxSeconds;
        FillRoundedRect(fill, 2.0, [appColor colorWithAlphaComponent:(AppIsDark() ? 0.72 : 0.66)]);
        y += 42;
    }
}

- (void)drawDetailPanelInRect:(NSRect)rect {
    DrawSoftPanel(rect, InspectorColor());

    NSMutableParagraphStyle *truncate = [[NSMutableParagraphStyle alloc] init];
    truncate.lineBreakMode = NSLineBreakByTruncatingTail;
    NSDictionary *titleAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:18 weight:NSFontWeightSemibold],
                                 NSForegroundColorAttributeName: SoftTextColor(),
                                 NSParagraphStyleAttributeName: truncate};
    NSDictionary *captionAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:12],
                                   NSForegroundColorAttributeName: MutedTextColor(),
                                   NSParagraphStyleAttributeName: truncate};
    NSDictionary *labelAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightMedium],
                                 NSForegroundColorAttributeName: SoftTextColor(),
                                 NSParagraphStyleAttributeName: truncate};
    NSDictionary *monoAttrs = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular],
                                NSForegroundColorAttributeName: MutedTextColor(),
                                NSParagraphStyleAttributeName: truncate};
    NSMutableParagraphStyle *rightAlign = [[NSMutableParagraphStyle alloc] init];
    rightAlign.lineBreakMode = NSLineBreakByTruncatingTail;
    rightAlign.alignment = NSTextAlignmentRight;
    NSDictionary *rightMonoAttrs = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightSemibold],
                                     NSForegroundColorAttributeName: SecondaryTextColor(),
                                     NSParagraphStyleAttributeName: rightAlign};
    NSDictionary *metricLabelAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium],
                                       NSForegroundColorAttributeName: MutedTextColor(),
                                       NSParagraphStyleAttributeName: truncate};
    NSDictionary *metricValueAttrs = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightSemibold],
                                       NSForegroundColorAttributeName: SoftTextColor(),
                                       NSParagraphStyleAttributeName: truncate};

    NSDictionary *block = [self primaryDetailBlock];
    NSArray *apps = block ? (block[@"top_apps"] ?: @[]) : (self.stats[@"top_apps"] ?: @[]);
    NSString *title = block ? [self displayTitleForHoverBlock:block] : @"今日概览";
    BOOL calendarDetail = [self detailBlockCanEditTitle:block];
    NSString *detailKind = block[@"kind"] ?: @"";
    NSDictionary *headerApp = nil;
    if (block && ![detailKind isEqualToString:@"gap"]) {
        headerApp = apps.firstObject;
        if (!headerApp && [block[@"key"] length] > 0) {
            headerApp = @{
                @"key": block[@"key"] ?: @"",
                @"bundle_id": block[@"bundle_id"] ?: @"",
                @"title": block[@"title"] ?: title ?: @""
            };
        }
    }
    CGFloat headerTextX = rect.origin.x + 16;
    CGFloat headerRightInset = block && [self detailBlockCanEditTitle:block] ? 84.0 : 16.0;
    BOOL editingTitle = [self isEditingTitleForBlock:block];
    if (editingTitle) {
        [self layoutDetailTitleEditControls];
        FillRoundedRect(self.detailTitleEditField.frame, 7, ManualCreationInputFillColor());
        StrokeRoundedRect(self.detailTitleEditField.frame, 7, ManualCreationInputStrokeColor(), 0.7);
        FillRoundedRect(self.detailTitleEditCancelButton.frame, 8, ManualCreationSecondaryButtonFillColor());
        StrokeRoundedRect(self.detailTitleEditCancelButton.frame, 8, BorderColor(), 0.45);
        FillRoundedRect(self.detailTitleEditSaveButton.frame, 8, [NSColor.controlAccentColor colorWithAlphaComponent:(AppIsDark() ? 0.92 : 0.88)]);
        StrokeRoundedRect(self.detailTitleEditSaveButton.frame, 8, [NSColor.whiteColor colorWithAlphaComponent:(AppIsDark() ? 0.10 : 0.18)], 0.5);
    } else {
        if (headerApp) {
            NSRect iconRect = NSMakeRect(rect.origin.x + 16, rect.origin.y + 17, 26, 26);
            DrawAppIdentityMark(headerApp, headerApp[@"key"] ?: block[@"key"], iconRect);
            headerTextX = rect.origin.x + 54;
        }
        [title drawInRect:NSMakeRect(headerTextX, rect.origin.y + 14, NSMaxX(rect) - headerRightInset - headerTextX, 24) withAttributes:titleAttrs];
    }
    if (block && !editingTitle && [self detailBlockCanEditTitle:block]) {
        NSRect renameRect = [self detailRenameButtonRect];
        FillRoundedRect(renameRect, 8, QuietControlFillColor());
        NSDictionary *renameAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold],
                                      NSForegroundColorAttributeName: MutedTextColor()};
        DrawCenteredString(@"编辑", renameRect, renameAttrs);
    }

    NSString *subtitle = @"暂无可写入时段";
    if (block) {
        subtitle = [NSString stringWithFormat:@"%@-%@ · %@",
                    [ClockString(block[@"start"]) substringToIndex:5],
                    [ClockString(block[@"end"]) substringToIndex:5],
                    ShortDuration([block[@"wall_seconds"] doubleValue] > 0
                                  ? [block[@"wall_seconds"] doubleValue]
                                  : [block[@"end"] timeIntervalSinceDate:block[@"start"]])];
    } else if ([self.stats[@"total_seconds"] doubleValue] > 0) {
        subtitle = [NSString stringWithFormat:@"活跃 %@", ShortDuration([self.stats[@"total_seconds"] doubleValue])];
    }
    [subtitle drawInRect:NSMakeRect(headerTextX, rect.origin.y + 43, NSMaxX(rect) - 16 - headerTextX, 18) withAttributes:captionAttrs];

    double wallSeconds = block ? ([block[@"wall_seconds"] doubleValue] > 0
        ? [block[@"wall_seconds"] doubleValue]
        : [block[@"end"] timeIntervalSinceDate:block[@"start"]]) : [self.stats[@"total_seconds"] doubleValue];
    double activeSeconds = block ? ([block[@"observed_seconds"] doubleValue] > 0
        ? [block[@"observed_seconds"] doubleValue]
        : [block[@"active_seconds"] doubleValue]) : [self.stats[@"total_seconds"] doubleValue];
    NSString *stateText = @"今日";
    if (block) {
        if (calendarDetail) {
            stateText = [block[@"calendar_confirmed"] boolValue] ? @"已写" : @"待写";
        } else if ([detailKind isEqualToString:@"gap"]) {
            stateText = @"空白";
        } else if ([detailKind isEqualToString:@"ongoing"]) {
            stateText = @"进行中";
        } else {
            stateText = @"轨迹";
        }
    }
    NSArray *metrics = @[
        @[@"时长", ShortDuration(wallSeconds)],
        @[@"活跃", ShortDuration(activeSeconds)],
        @[@"状态", stateText]
    ];
    NSColor *stateAccent = MutedTextColor();
    if (block) {
        if (calendarDetail) {
            stateAccent = [block[@"calendar_confirmed"] boolValue] ? NSColor.systemGreenColor : NSColor.controlAccentColor;
        } else if ([detailKind isEqualToString:@"gap"]) {
            stateAccent = DynamicRGB(142, 142, 147, 174, 174, 178);
        } else if ([detailKind isEqualToString:@"ongoing"]) {
            stateAccent = NSColor.systemGreenColor;
        }
    }
    CGFloat metricGap = 8;
    CGFloat metricWidth = (rect.size.width - 32 - metricGap * 2) / 3.0;
    NSRect metricBand = NSMakeRect(rect.origin.x + 16, rect.origin.y + 72, rect.size.width - 32, 42);
    for (NSInteger i = 0; i < metrics.count; i++) {
        NSRect metric = NSMakeRect(metricBand.origin.x + i * (metricWidth + metricGap), metricBand.origin.y, metricWidth, metricBand.size.height);
        NSColor *metricFill = i == 2
            ? [stateAccent colorWithAlphaComponent:(AppIsDark() ? 0.135 : 0.070)]
            : ToolbarControlFillColor();
        NSColor *metricStroke = i == 2
            ? [stateAccent colorWithAlphaComponent:(AppIsDark() ? 0.18 : 0.13)]
            : BorderColor();
        FillRoundedRect(metric, 9, metricFill);
        StrokeRoundedRect(metric, 9, metricStroke, 0.45);
        NSArray *item = metrics[i];
        NSDictionary *valueAttrs = i == 2
            ? @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightSemibold],
                NSForegroundColorAttributeName: stateAccent,
                NSParagraphStyleAttributeName: truncate}
            : metricValueAttrs;
        CGFloat textInset = 10;
        [item[0] drawInRect:NSMakeRect(metric.origin.x + textInset, metric.origin.y + 5, metric.size.width - textInset - 10, 13) withAttributes:metricLabelAttrs];
        [item[1] drawInRect:NSMakeRect(metric.origin.x + textInset, metric.origin.y + 21, metric.size.width - textInset - 10, 16) withAttributes:valueAttrs];
    }

    CGFloat y = rect.origin.y + 124;
    BOOL mixedDetail = [block[@"kind"] isEqualToString:@"mixed"] || [block[@"mode"] isEqualToString:@"碎片"];
    NSString *ratioTitle = [detailKind isEqualToString:@"gap"]
        ? @"空白时段"
        : (mixedDetail ? @"混合占比" : @"应用占比");
    NSRect donut = [self detailDonutRect];
    BOOL hasAppBreakdown = apps.count > 0;
    NSInteger detailRowCount = hasAppBreakdown ? MIN(5, (NSInteger)apps.count) : 0;
    NSColor *detailSurface = InspectorColor();
    [ratioTitle drawAtPoint:NSMakePoint(rect.origin.x + 16, y) withAttributes:labelAttrs];
    if (self.highlightedAppKey.length > 0) {
        NSDictionary *highlightedApp = nil;
        for (NSDictionary *app in apps ?: @[]) {
            if ([app[@"key"] isEqualToString:self.highlightedAppKey]) {
                highlightedApp = app;
                break;
            }
        }
        if (!highlightedApp) {
            for (NSDictionary *app in self.stats[@"top_apps"] ?: @[]) {
                if ([app[@"key"] isEqualToString:self.highlightedAppKey]) {
                    highlightedApp = app;
                    break;
                }
            }
        }
        NSString *highlightTitle = highlightedApp[@"title"] ?: self.highlightedAppKey;
        NSDictionary *chipTextAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold],
                                        NSForegroundColorAttributeName: SoftTextColor(),
                                        NSParagraphStyleAttributeName: truncate};
        CGFloat chipWidth = MIN(122.0, MAX(74.0, [highlightTitle sizeWithAttributes:chipTextAttrs].width + 36.0));
        NSRect chip = NSMakeRect(NSMaxX(rect) - 16.0 - chipWidth, y - 4.0, chipWidth, 22.0);
        NSColor *chipColor = ColorForKey(self.highlightedAppKey);
        FillRoundedRect(chip, 8, [chipColor colorWithAlphaComponent:(AppIsDark() ? 0.16 : 0.095)]);
        StrokeRoundedRect(chip, 8, [chipColor colorWithAlphaComponent:(AppIsDark() ? 0.26 : 0.18)], 0.55);
        NSDictionary *chipApp = highlightedApp ?: @{
            @"key": self.highlightedAppKey ?: @"__other__",
            @"title": highlightTitle ?: @"",
            @"bundle_id": @""
        };
        DrawAppIdentityMark(chipApp, self.highlightedAppKey, NSMakeRect(chip.origin.x + 7, chip.origin.y + 4, 14, 14));
        [highlightTitle drawInRect:NSMakeRect(chip.origin.x + 27, chip.origin.y + 4, chip.size.width - 34, 14)
                     withAttributes:chipTextAttrs];
    }

    CGFloat breakdownBottom = donut.origin.y + 96;
    if (hasAppBreakdown) {
        [self drawDonutForApps:apps inRect:donut backgroundColor:detailSurface];

        NSRect ratioBar = [self detailRatioBarRect];
        [self drawStackedRatioBarForApps:apps inRect:ratioBar];
        for (NSInteger i = 0; i < detailRowCount; i++) {
            NSDictionary *app = apps[i];
            NSString *key = app[@"key"] ?: @"__other__";
            NSColor *color = ColorForKey(key);
            NSString *name = app[@"title"] ?: @"未知";
            double seconds = [app[@"seconds"] doubleValue];
            double ratio = [app[@"ratio"] doubleValue];
            NSRect row = [self detailAppRowRectAtIndex:i];
            if ([self.highlightedAppKey isEqualToString:key]) {
                FillRoundedRect(row, 8, [color colorWithAlphaComponent:(AppIsDark() ? 0.18 : 0.10)]);
            }
            NSString *percent = ratio > 0 ? [NSString stringWithFormat:@"%.0f%%", ratio * 100.0] : @"--";
            DrawAppIdentityMark(app, key, NSMakeRect(row.origin.x + 2, row.origin.y + 2, 16, 16));
            [name drawInRect:NSMakeRect(row.origin.x + 24, row.origin.y + 2, row.size.width - 88, 15) withAttributes:labelAttrs];
            [percent drawInRect:NSMakeRect(NSMaxX(row) - 58, row.origin.y + 2, 50, 15) withAttributes:rightMonoAttrs];
            [ShortDuration(seconds) drawInRect:NSMakeRect(row.origin.x + 24, row.origin.y + 16, 90, 13) withAttributes:monoAttrs];
            NSRect rowTrack = NSMakeRect(row.origin.x + 118, row.origin.y + 21, row.size.width - 128, 3);
            FillRoundedRect(rowTrack, 1.5, QuietControlFillColor());
            NSRect rowFill = rowTrack;
            rowFill.size.width *= MAX(0, MIN(1, ratio));
            FillRoundedRect(rowFill, 1.5, [color colorWithAlphaComponent:(AppIsDark() ? 0.76 : 0.70)]);
        }
        breakdownBottom = detailRowCount > 0 ? NSMaxY([self detailAppRowRectAtIndex:detailRowCount - 1]) : NSMaxY(donut);
    } else {
        NSString *emptyTitle = [detailKind isEqualToString:@"gap"] ? @"这段没有应用活动" : @"暂无应用数据";
        NSString *emptyMeta = block ? @"当前时段没有可统计的应用占比" : @"今天还没有形成应用占比";
        [emptyTitle drawInRect:NSMakeRect(rect.origin.x + 16, y + 36, rect.size.width - 32, 18)
                withAttributes:labelAttrs];
        [emptyMeta drawInRect:NSMakeRect(rect.origin.x + 16, y + 58, rect.size.width - 32, 18)
               withAttributes:captionAttrs];
        breakdownBottom = y + 92;
    }

    if (block && calendarDetail) {
        y = breakdownBottom + 20;
        BOOL confirmed = [block[@"calendar_confirmed"] boolValue];
        NSRect calendarRow = NSMakeRect(rect.origin.x + 16, y, rect.size.width - 32, 58);
        FillRoundedRect(calendarRow, 11, ToolbarControlFillColor());
        StrokeRoundedRect(calendarRow, 11, BorderColor(), 0.45);

        NSColor *stateColor = confirmed ? NSColor.systemGreenColor : NSColor.controlAccentColor;
        [[stateColor colorWithAlphaComponent:(confirmed ? 0.72 : 0.82)] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(calendarRow.origin.x + 12, calendarRow.origin.y + 15, 8, 8)] fill];
        [@"日历" drawAtPoint:NSMakePoint(calendarRow.origin.x + 28, calendarRow.origin.y + 10) withAttributes:labelAttrs];
        NSRect statePill = NSMakeRect(NSMaxX(calendarRow) - 78, calendarRow.origin.y + 8, 62, 24);
        FillRoundedRect(statePill, 8, confirmed ? [NSColor.systemGreenColor colorWithAlphaComponent:(AppIsDark() ? 0.20 : 0.13)] : QuietControlFillColor());
        NSDictionary *stateAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold],
                                     NSForegroundColorAttributeName: confirmed ? NSColor.systemGreenColor : MutedTextColor()};
        DrawCenteredString(confirmed ? @"已写入" : @"待确认", statePill, stateAttrs);

        NSString *project = block[@"project_title"];
        NSString *stateDetail = project.length > 0
            ? [NSString stringWithFormat:@"%@ · %@ · %@", ShortDuration(wallSeconds), project, CalendarEventTitleForBlock(block)]
            : [NSString stringWithFormat:@"%@ · %@", ShortDuration(wallSeconds), CalendarEventTitleForBlock(block)];
        [stateDetail drawInRect:NSMakeRect(calendarRow.origin.x + 28, calendarRow.origin.y + 34, calendarRow.size.width - 44, 16) withAttributes:captionAttrs];
    }

    BOOL editingProject = [self isEditingProjectForBlock:block];
    if (editingProject) {
        [self layoutDetailProjectEditControls];
        NSRect projectPanel = [self detailProjectEditPanelRect];
        NSString *projectTitle = self.detailProjectEditField.stringValue.length > 0 ? self.detailProjectEditField.stringValue : (block[@"project_title"] ?: @"项目");
        NSColor *projectColor = ProjectColorForTitle(projectTitle);
        FillRoundedRect(projectPanel, 10, [projectColor colorWithAlphaComponent:(AppIsDark() ? 0.14 : 0.075)]);
        StrokeRoundedRect(projectPanel, 10, [projectColor colorWithAlphaComponent:(AppIsDark() ? 0.24 : 0.18)], 0.6);
        FillRoundedRect(self.detailProjectEditField.frame, 7, ManualCreationInputFillColor());
        StrokeRoundedRect(self.detailProjectEditField.frame, 7, ManualCreationInputStrokeColor(), 0.7);
        FillRoundedRect(self.detailProjectEditCancelButton.frame, 8, ManualCreationSecondaryButtonFillColor());
        StrokeRoundedRect(self.detailProjectEditCancelButton.frame, 8, BorderColor(), 0.45);
        FillRoundedRect(self.detailProjectEditSaveButton.frame, 8, [NSColor.controlAccentColor colorWithAlphaComponent:(AppIsDark() ? 0.92 : 0.88)]);
        StrokeRoundedRect(self.detailProjectEditSaveButton.frame, 8, [NSColor.whiteColor colorWithAlphaComponent:(AppIsDark() ? 0.10 : 0.18)], 0.5);
    }

    if (block && calendarDetail) {
        NSDictionary *buttonAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold],
                                      NSForegroundColorAttributeName: NSColor.whiteColor};
        NSDictionary *secondaryButtonAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightMedium],
                                               NSForegroundColorAttributeName: SoftTextColor()};
        NSDictionary *confirmedButtonAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold],
                                               NSForegroundColorAttributeName: NSColor.systemGreenColor};
        NSRect actionArea = [self detailActionAreaRect];

        NSRect writeRect = [self detailWriteButtonRect];
        BOOL confirmed = [block[@"calendar_confirmed"] boolValue];
        NSColor *writeFill = confirmed
            ? [NSColor.systemGreenColor colorWithAlphaComponent:(AppIsDark() ? 0.16 : 0.095)]
            : [NSColor.controlAccentColor colorWithAlphaComponent:(AppIsDark() ? 0.82 : 0.88)];
        NSColor *writeStroke = confirmed
            ? [NSColor.systemGreenColor colorWithAlphaComponent:(AppIsDark() ? 0.24 : 0.18)]
            : [NSColor.controlAccentColor colorWithAlphaComponent:(AppIsDark() ? 0.28 : 0.18)];
        FillRoundedRect(writeRect, 9, writeFill);
        StrokeRoundedRect(writeRect, 9, writeStroke, 0.6);
        NSString *writeTitle = [block[@"calendar_confirmed"] boolValue] ? @"已写入日历" : @"写入此段";
        DrawCenteredString(writeTitle, writeRect, confirmed ? confirmedButtonAttrs : buttonAttrs);

        NSRect projectRect = [self detailProjectButtonRect];
        FillRoundedRect(projectRect, 9, ToolbarControlFillColor());
        StrokeRoundedRect(projectRect, 9, CalendarGridStrokeColor(0.030, 0.036), 0.45);
        NSString *projectTitle = [block[@"project_title"] length] ? @"改项目" : @"标记项目";
        DrawCenteredString(projectTitle, projectRect, secondaryButtonAttrs);

        NSRect ignoreRect = [self detailIgnoreButtonRect];
        FillRoundedRect(ignoreRect, 9, ToolbarControlFillColor());
        StrokeRoundedRect(ignoreRect, 9, CalendarGridStrokeColor(0.030, 0.036), 0.45);
        DrawCenteredString(@"忽略", ignoreRect, secondaryButtonAttrs);
    } else if (block) {
        NSRect actionArea = [self detailActionAreaRect];

        NSString *statusTitle = @"真实轨迹";
        NSString *statusText = block[@"mode"] ?: @"记录";
        NSColor *statusColor = ColorForKey([self colorKeyForBlock:block] ?: @"__other__");
        if ([detailKind isEqualToString:@"gap"]) {
            statusTitle = @"空白";
            statusText = block[@"mode"] ?: @"未记录";
            statusColor = NSColor.systemGrayColor;
        } else if ([detailKind isEqualToString:@"ongoing"]) {
            statusTitle = @"进行中";
            statusText = @"尚未结束";
            statusColor = NSColor.systemGreenColor;
        }

        NSRect statusRow = NSMakeRect(actionArea.origin.x + 2, actionArea.origin.y + 10, actionArea.size.width - 4, 64);
        FillRoundedRect(statusRow, 12, [statusColor colorWithAlphaComponent:(AppIsDark() ? 0.105 : 0.062)]);
        StrokeRoundedRect(statusRow, 12, [statusColor colorWithAlphaComponent:(AppIsDark() ? 0.18 : 0.12)], 0.55);
        [[statusColor colorWithAlphaComponent:0.82] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(statusRow.origin.x + 14, statusRow.origin.y + 14, 8, 8)] fill];
        [statusTitle drawInRect:NSMakeRect(statusRow.origin.x + 30, statusRow.origin.y + 7, statusRow.size.width - 60, 18)
                 withAttributes:labelAttrs];
        [statusText drawInRect:NSMakeRect(statusRow.origin.x + 30, statusRow.origin.y + 30, statusRow.size.width - 60, 18)
                withAttributes:captionAttrs];

        NSRect ratioRect = NSMakeRect(statusRow.origin.x + 14, statusRow.origin.y + 51, statusRow.size.width - 28, 5);
        FillRoundedRect(ratioRect, 2.5, QuietControlFillColor());
        NSRect activeRect = ratioRect;
        activeRect.size.width *= wallSeconds > 0 ? MAX(0, MIN(1, activeSeconds / wallSeconds)) : 0;
        FillRoundedRect(activeRect, 2.5, [statusColor colorWithAlphaComponent:(AppIsDark() ? 0.70 : 0.62)]);
    }
}

- (void)drawPendingPanel {
    if (!self.pendingPanelVisible) {
        return;
    }

    NSArray *pending = [self pendingDashboardCandidates];
    NSRect panel = [self pendingPanelRect];
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:panel xRadius:14 yRadius:14];
    NSShadow *shadow = [[NSShadow alloc] init];
    shadow.shadowColor = [NSColor.blackColor colorWithAlphaComponent:(AppIsDark() ? 0.44 : 0.16)];
    shadow.shadowBlurRadius = 24;
    shadow.shadowOffset = NSMakeSize(0, 10);
    [NSGraphicsContext saveGraphicsState];
    [shadow set];
    [InspectorColor() setFill];
    [path fill];
    [NSGraphicsContext restoreGraphicsState];
    [InspectorColor() setFill];
    [path fill];
    StrokeRoundedRect(panel, 14, BorderColor(), 0.7);

    NSMutableParagraphStyle *truncate = [[NSMutableParagraphStyle alloc] init];
    truncate.lineBreakMode = NSLineBreakByTruncatingTail;
    NSDictionary *titleAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:16 weight:NSFontWeightSemibold],
                                 NSForegroundColorAttributeName: SoftTextColor(),
                                 NSParagraphStyleAttributeName: truncate};
    NSDictionary *captionAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightRegular],
                                   NSForegroundColorAttributeName: MutedTextColor(),
                                   NSParagraphStyleAttributeName: truncate};
    NSDictionary *pillAttrs = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightMedium],
                                NSForegroundColorAttributeName: SoftTextColor(),
                                NSParagraphStyleAttributeName: truncate};
    NSDictionary *rowTitleAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold],
                                    NSForegroundColorAttributeName: SoftTextColor(),
                                    NSParagraphStyleAttributeName: truncate};
    NSDictionary *rowMetaAttrs = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular],
                                   NSForegroundColorAttributeName: MutedTextColor(),
                                   NSParagraphStyleAttributeName: truncate};
    NSDictionary *buttonAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold],
                                  NSForegroundColorAttributeName: SoftTextColor()};

    double pendingSeconds = 0;
    for (NSDictionary *block in pending) {
        pendingSeconds += [block[@"wall_seconds"] doubleValue];
    }

    [[NSColor.controlAccentColor colorWithAlphaComponent:0.88] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(panel.origin.x + 18, panel.origin.y + 21, 8, 8)] fill];
    [@"待确认" drawAtPoint:NSMakePoint(panel.origin.x + 34, panel.origin.y + 14) withAttributes:titleAttrs];

    NSString *countText = [NSString stringWithFormat:@"%ld 段", (long)pending.count];
    NSSize countSize = [countText sizeWithAttributes:pillAttrs];
    NSRect countPill = NSMakeRect(panel.origin.x + 96, panel.origin.y + 13, countSize.width + 18, 24);
    FillRoundedRect(countPill, 9, [NSColor.controlAccentColor colorWithAlphaComponent:(AppIsDark() ? 0.18 : 0.10)]);
    StrokeRoundedRect(countPill, 9, [NSColor.controlAccentColor colorWithAlphaComponent:(AppIsDark() ? 0.26 : 0.16)], 0.5);
    DrawCenteredString(countText, countPill, pillAttrs);

    NSString *subtitle = pending.count == 0 ? @"今天没有新的时段" : [NSString stringWithFormat:@"合计 %@", ShortDuration(pendingSeconds)];
    [subtitle drawInRect:NSMakeRect(panel.origin.x + 34, panel.origin.y + 40, panel.size.width - 86, 16) withAttributes:captionAttrs];

    NSRect closeRect = [self pendingPanelCloseRect];
    FillRoundedRect(closeRect, 9, ToolbarControlFillColor());
    DrawCenteredString(@"×", closeRect, captionAttrs);

    for (NSInteger i = 0; i < MIN(5, pending.count); i++) {
        NSDictionary *block = pending[i];
        NSRect row = [self pendingPanelRowRectAtIndex:i];
        NSString *key = block[@"key"] ?: @"__other__";
        NSDictionary *firstApp = [block[@"top_apps"] firstObject];
        if ([block[@"kind"] isEqualToString:@"mixed"] && firstApp[@"key"]) {
            key = firstApp[@"key"];
        }
        NSDictionary *rowApp = firstApp ?: @{
            @"key": key,
            @"bundle_id": block[@"bundle_id"] ?: @"",
            @"title": block[@"title"] ?: @""
        };
        NSColor *color = ColorForKey(key);
        BOOL selected = [CalendarBlockKeyForBlock(block) isEqualToString:CalendarBlockKeyForBlock(self.selectedBlock)];
        NSColor *rowFill = selected
            ? [color colorWithAlphaComponent:(AppIsDark() ? 0.22 : 0.13)]
            : [RaisedPanelColor() colorWithAlphaComponent:(AppIsDark() ? 0.80 : 0.70)];
        FillRoundedRect(row, 10, rowFill);
        StrokeRoundedRect(row, 10, selected
                          ? [color colorWithAlphaComponent:(AppIsDark() ? 0.34 : 0.22)]
                          : BorderColor(), 0.55);
        [[color colorWithAlphaComponent:0.88] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(row.origin.x + 1, row.origin.y + 8, 4, row.size.height - 16)
                                         xRadius:2
                                         yRadius:2] fill];
        DrawAppIdentityMark(rowApp, key, NSMakeRect(row.origin.x + 13, row.origin.y + 8, 18, 18));

        NSString *eventTitle = CalendarEventTitleForBlock(block);
        NSString *timeRange = [NSString stringWithFormat:@"%@-%@",
                               [ClockString(block[@"start"]) substringToIndex:5],
                               [ClockString(block[@"end"]) substringToIndex:5]];
        NSString *project = block[@"project_title"];
        NSString *mode = block[@"mode"] ?: @"";
        NSString *metaTail = project.length > 0
            ? project
            : (mode.length > 0 ? [NSString stringWithFormat:@"按%@规则", mode] : @"待确认");
        NSString *meta = metaTail.length > 0
            ? [NSString stringWithFormat:@"%@ · %@", timeRange, metaTail]
            : timeRange;
        CGFloat textX = row.origin.x + 40;
        [eventTitle drawInRect:NSMakeRect(textX, row.origin.y + 8, NSMaxX(row) - 92 - textX, 16) withAttributes:rowTitleAttrs];
        [meta drawInRect:NSMakeRect(textX, row.origin.y + 26, NSMaxX(row) - 92 - textX, 14) withAttributes:rowMetaAttrs];
        NSString *duration = ShortDuration([block[@"wall_seconds"] doubleValue]);
        NSSize durationSize = [duration sizeWithAttributes:rowMetaAttrs];
        [duration drawInRect:NSMakeRect(NSMaxX(row) - durationSize.width - 18, row.origin.y + 17, durationSize.width + 2, 14)
              withAttributes:rowMetaAttrs];

        NSRect ratioBar = NSMakeRect(textX, row.origin.y + 42, NSMaxX(row) - 18 - textX, 3.5);
        [self drawStackedRatioBarForApps:block[@"top_apps"] ?: @[] inRect:ratioBar];
    }

    if (pending.count > 5) {
        NSString *more = [NSString stringWithFormat:@"另有 %ld 段", (long)(pending.count - 5)];
        [more drawInRect:NSMakeRect(panel.origin.x + 20, NSMaxY(panel) - 41, panel.size.width - 170, 16) withAttributes:captionAttrs];
    }

    NSRect writeRect = [self pendingPanelWriteRect];
    FillRoundedRect(writeRect, 9, pending.count > 0 ? [NSColor.controlAccentColor colorWithAlphaComponent:0.92] : QuietControlFillColor());
    StrokeRoundedRect(writeRect, 9, pending.count > 0
                      ? [NSColor.controlAccentColor colorWithAlphaComponent:(AppIsDark() ? 0.34 : 0.18)]
                      : BorderColor(), 0.55);
    NSString *writeTitle = pending.count > 0 ? @"全部写入" : @"无待写";
    NSDictionary *writeAttrs = pending.count > 0
        ? @{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold], NSForegroundColorAttributeName: NSColor.whiteColor}
        : buttonAttrs;
    DrawCenteredString(writeTitle, writeRect, writeAttrs);
}

- (void)drawToolbarButtonTitle:(NSString *)title rect:(NSRect)rect primary:(BOOL)primary {
    NSColor *fill = primary
        ? [NSColor.controlAccentColor colorWithAlphaComponent:(AppIsDark() ? 0.88 : 0.92)]
        : ToolbarControlFillColor();
    FillRoundedRect(rect, 9, fill);
    StrokeRoundedRect(rect, 9, [BorderColor() colorWithAlphaComponent:(AppIsDark() ? 0.62 : 0.50)], 0.55);
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: primary ? NSColor.whiteColor : SoftTextColor()
    };
    DrawCenteredString(title, rect, attrs);
}

- (void)drawPendingBannerInRect:(NSRect)pendingRect {
    NSMutableParagraphStyle *truncateStyle = [[NSMutableParagraphStyle alloc] init];
    truncateStyle.lineBreakMode = NSLineBreakByTruncatingTail;
    NSDictionary *chipAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold],
                                NSForegroundColorAttributeName: SoftTextColor(),
                                NSParagraphStyleAttributeName: truncateStyle};

    NSInteger pendingCount = [self.stats[@"pending_candidate_count"] integerValue];
    NSInteger confirmedCount = [self.stats[@"confirmed_candidate_count"] integerValue];
    double pendingSeconds = 0;
    for (NSDictionary *candidate in self.stats[@"candidates"] ?: @[]) {
        if (![candidate[@"calendar_confirmed"] boolValue]) {
            pendingSeconds += [candidate[@"wall_seconds"] doubleValue];
        }
    }
    BOOL hasPending = pendingCount > 0;
    NSColor *fill = hasPending
        ? [NSColor.controlAccentColor colorWithAlphaComponent:(AppIsDark() ? 0.135 : 0.078)]
        : ToolbarControlFillColor();
    NSColor *stroke = hasPending
        ? [NSColor.controlAccentColor colorWithAlphaComponent:(AppIsDark() ? 0.24 : 0.18)]
        : [BorderColor() colorWithAlphaComponent:(AppIsDark() ? 0.58 : 0.48)];
    FillRoundedRect(pendingRect, 9, fill);
    StrokeRoundedRect(pendingRect, 9, stroke, 0.55);

    NSString *pendingText = pendingCount == 0
        ? (confirmedCount > 0 ? [NSString stringWithFormat:@"已写 %ld", (long)confirmedCount] : @"无待写")
        : [NSString stringWithFormat:@"待确认 %ld · %@", (long)pendingCount, ShortDuration(pendingSeconds)];
    NSColor *noticeColor = hasPending ? NSColor.controlAccentColor : MutedTextColor();
    [[noticeColor colorWithAlphaComponent:(hasPending ? 0.86 : 0.50)] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(pendingRect.origin.x + 10, pendingRect.origin.y + 10, 8, 8)] fill];
    NSMutableDictionary *pendingAttrs = [chipAttrs mutableCopy];
    pendingAttrs[NSForegroundColorAttributeName] = hasPending ? SoftTextColor() : MutedTextColor();
    [pendingText drawInRect:NSMakeRect(pendingRect.origin.x + 25, pendingRect.origin.y + 6, pendingRect.size.width - 46, 16)
             withAttributes:pendingAttrs];
    if (hasPending) {
        [@"›" drawInRect:NSMakeRect(NSMaxX(pendingRect) - 19, pendingRect.origin.y + 6, 10, 16) withAttributes:pendingAttrs];
    }
}

- (void)drawTopToolbar {
    NSMutableParagraphStyle *truncateStyle = [[NSMutableParagraphStyle alloc] init];
    truncateStyle.lineBreakMode = NSLineBreakByTruncatingTail;
    NSDictionary *statusAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold],
                                  NSForegroundColorAttributeName: SoftTextColor(),
                                  NSParagraphStyleAttributeName: truncateStyle};

    NSRect toggleRect = [self topToggleButtonRect];
    [self drawToolbarButtonTitle:(self.recording ? @"暂停" : @"开始")
                            rect:toggleRect
                         primary:NO];

    NSRect statusRect = [self topRecordingStatusRect];
    FillRoundedRect(statusRect, 10, ToolbarControlFillColor());
    StrokeRoundedRect(statusRect, 10, [BorderColor() colorWithAlphaComponent:(AppIsDark() ? 0.58 : 0.48)], 0.55);
    NSString *state = self.recording ? @"正在记录" : @"已暂停";
    NSColor *dotColor = self.recording ? NSColor.systemGreenColor : NSColor.systemOrangeColor;
    CGFloat dotCenterX = statusRect.origin.x + 15.0;
    CGFloat dotCenterY = statusRect.origin.y + statusRect.size.height / 2.0;
    CGFloat pulse = 0;
    if (self.recording) {
        NSTimeInterval elapsed = [NSDate timeIntervalSinceReferenceDate] - self.pulseStart;
        pulse = (1.0 - cos(fmod(elapsed, 2.0) / 2.0 * M_PI * 2.0)) / 2.0;
        CGFloat haloRadius = 7.0 + pulse * 3.0;
        [[dotColor colorWithAlphaComponent:0.16 * (1.0 - pulse) + 0.05] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(dotCenterX - haloRadius,
                                                          dotCenterY - haloRadius,
                                                          haloRadius * 2.0,
                                                          haloRadius * 2.0)] fill];
    }
    [[dotColor colorWithAlphaComponent:0.95] setFill];
    CGFloat dotSize = self.recording ? 7.0 + pulse * 1.6 : 7.0;
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(dotCenterX - dotSize / 2.0,
                                                      dotCenterY - dotSize / 2.0,
                                                      dotSize,
                                                      dotSize)] fill];
    [state drawInRect:NSMakeRect(statusRect.origin.x + 28, statusRect.origin.y + 7, statusRect.size.width - 38, 16)
       withAttributes:statusAttrs];

    NSRect more = [self topMoreButtonRect];
    FillRoundedRect(more, 9, ToolbarControlFillColor());
    StrokeRoundedRect(more, 9, [BorderColor() colorWithAlphaComponent:(AppIsDark() ? 0.58 : 0.48)], 0.55);
    NSDictionary *moreAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:16 weight:NSFontWeightSemibold],
                                NSForegroundColorAttributeName: MutedTextColor()};
    DrawCenteredString(@"…", more, moreAttrs);
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    [SurfaceColor() setFill];
    NSRectFill(self.bounds);

    NSMutableParagraphStyle *truncateStyle = [[NSMutableParagraphStyle alloc] init];
    truncateStyle.lineBreakMode = NSLineBreakByTruncatingTail;

    NSDictionary *titleAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:21 weight:NSFontWeightSemibold],
                                 NSForegroundColorAttributeName: SoftTextColor(),
                                 NSParagraphStyleAttributeName: truncateStyle};
    NSDictionary *subAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:12],
                               NSForegroundColorAttributeName: MutedTextColor(),
                               NSParagraphStyleAttributeName: truncateStyle};

    [@"前台记录" drawAtPoint:NSMakePoint(20, 18) withAttributes:titleAttrs];

    double total = [self.stats[@"total_seconds"] doubleValue];
    NSInteger count = [self.stats[@"segment_count"] integerValue];
    NSString *summary = [NSString stringWithFormat:@"%@活跃 %@ · %ld 段",
                         self.stats[@"date_title"] ?: @"今日",
                         ShortDuration(total),
                         (long)count];
    [summary drawInRect:NSMakeRect(126, 22, 244, 16) withAttributes:subAttrs];

    NSString *status = LocalizedStatusText(self.statusText);
    [status drawInRect:NSMakeRect(126, 44, 252, 16) withAttributes:subAttrs];

    [self drawTopToolbar];

    [self drawSidebarInRect:[self sidebarRect]];
    [self drawCalendarTimelineInRect:[self timelineRect]];
    [self drawDetailPanelInRect:[self detailRect]];
    [self drawPendingPanel];
    [self drawManualCreationPanel];
}

- (void)drawCalendarTimelineInRect:(NSRect)rect {
    NSArray *segments = self.stats[@"segments"] ?: @[];
    NSBezierPath *panelPath = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(rect, 0.5, 0.5) xRadius:13 yRadius:13];
    [PanelColor() setFill];
    [panelPath fill];

    if (segments.count == 0) {
        NSMutableParagraphStyle *center = [[NSMutableParagraphStyle alloc] init];
        center.alignment = NSTextAlignmentCenter;
        center.lineBreakMode = NSLineBreakByTruncatingTail;
        NSDictionary *titleAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold],
                                     NSForegroundColorAttributeName: SoftTextColor(),
                                     NSParagraphStyleAttributeName: center};
        NSDictionary *captionAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightRegular],
                                       NSForegroundColorAttributeName: MutedTextColor(),
                                       NSParagraphStyleAttributeName: center};
        CGFloat centerY = rect.origin.y + rect.size.height * 0.42;
        [@"暂无记录" drawInRect:NSMakeRect(rect.origin.x + 42, centerY - 16, rect.size.width - 84, 20)
                 withAttributes:titleAttrs];
        NSString *caption = self.recording ? @"正在等待新的窗口片段" : @"记录暂停中";
        [caption drawInRect:NSMakeRect(rect.origin.x + 42, centerY + 8, rect.size.width - 84, 18)
             withAttributes:captionAttrs];
        return;
    }

    NSDictionary *layout = [self timelineLayoutInRect:rect];
    [NSGraphicsContext saveGraphicsState];
    [panelPath addClip];
    NSDate *rangeStart = layout[@"range_start"];
    double span = [layout[@"span"] doubleValue];
    CGFloat left = [layout[@"left"] doubleValue];
    CGFloat gridTop = [layout[@"grid_top"] doubleValue];
    CGFloat gridHeight = [layout[@"grid_height"] doubleValue];
    CGFloat visibleGridTop = [layout[@"visible_grid_top"] doubleValue];
    CGFloat visibleGridHeight = [layout[@"visible_grid_height"] doubleValue];
    CGFloat visibleGridBottom = visibleGridTop + visibleGridHeight;
    CGFloat laneLeft = [layout[@"calendar_left"] doubleValue];
    CGFloat laneWidth = [layout[@"calendar_width"] doubleValue];
    CGFloat right = laneLeft + laneWidth;
    NSMutableParagraphStyle *truncateStyle = [[NSMutableParagraphStyle alloc] init];
    truncateStyle.lineBreakMode = NSLineBreakByTruncatingTail;
    NSDictionary *timeAttrs = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightRegular],
                                NSForegroundColorAttributeName: MutedTextColor()};
    NSDictionary *laneAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold],
                                NSForegroundColorAttributeName: SoftTextColor()};
    NSDictionary *eventAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold],
                                 NSForegroundColorAttributeName: NSColor.whiteColor,
                                 NSParagraphStyleAttributeName: truncateStyle};
    NSDictionary *eventSubAttrs = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightRegular],
                                    NSForegroundColorAttributeName: [NSColor.whiteColor colorWithAlphaComponent:0.80],
                                    NSParagraphStyleAttributeName: truncateStyle};
    NSDictionary *legendAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:10 weight:NSFontWeightMedium],
                                  NSForegroundColorAttributeName: MutedTextColor(),
                                  NSParagraphStyleAttributeName: truncateStyle};

    NSInteger hourCount = (NSInteger)ceil(span / 3600.0);

    NSRect pendingHeaderRect = [self pendingBannerRect];
    BOOL headerHasTitleRoom = pendingHeaderRect.origin.x - laneLeft >= 78.0;
    if (headerHasTitleRoom) {
        [@"时间线" drawAtPoint:NSMakePoint(laneLeft, rect.origin.y + 14) withAttributes:laneAttrs];
    }

    NSArray *legendApps = [self selectedSidebarScopeStats][@"top_apps"] ?: self.stats[@"top_apps"] ?: @[];
    CGFloat legendX = laneLeft + (headerHasTitleRoom ? 58.0 : 0.0);
    CGFloat legendY = rect.origin.y + 10.0;
    CGFloat legendMaxX = pendingHeaderRect.origin.x - 10.0;
    if (legendMaxX - legendX >= 82.0) {
        for (NSInteger i = 0; i < MIN(4, legendApps.count); i++) {
            CGFloat nextX = DrawTimelineLegendChip(legendApps[i], legendX, legendY, legendMaxX, legendAttrs, self.highlightedAppKey);
            if (nextX <= legendX + 0.5) {
                break;
            }
            legendX = nextX;
        }
    }
    [self drawPendingBannerInRect:pendingHeaderRect];

    NSInteger halfHourCount = hourCount * 2;
    for (NSInteger i = 1; i < halfHourCount; i++) {
        if (i % 2 == 0) {
            continue;
        }
        NSDate *tick = [rangeStart dateByAddingTimeInterval:i * 1800.0];
        double offset = [tick timeIntervalSinceDate:rangeStart] / span;
        CGFloat y = gridTop + offset * gridHeight;
        if (y < visibleGridTop - 8 || y > visibleGridBottom + 8) {
            continue;
        }
        [CalendarGridStrokeColor(0.008, 0.012) setStroke];
        NSBezierPath *minorLine = [NSBezierPath bezierPath];
        [minorLine moveToPoint:NSMakePoint(left + 4, y)];
        [minorLine lineToPoint:NSMakePoint(right - 2, y)];
        [minorLine setLineWidth:0.16];
        [minorLine stroke];
    }

    for (NSInteger i = 0; i <= hourCount; i++) {
        NSDate *tick = [rangeStart dateByAddingTimeInterval:i * 3600.0];
        double offset = [tick timeIntervalSinceDate:rangeStart] / span;
        CGFloat y = gridTop + offset * gridHeight;
        if (y < visibleGridTop - 8 || y > visibleGridBottom + 8) {
            continue;
        }
        NSString *time = [ClockString(tick) substringToIndex:5];
        [time drawAtPoint:NSMakePoint(rect.origin.x + 10, y - 7) withAttributes:timeAttrs];
        [CalendarGridStrokeColor(0.022, 0.030) setStroke];
        NSBezierPath *line = [NSBezierPath bezierPath];
        [line moveToPoint:NSMakePoint(left + 4, y)];
        [line lineToPoint:NSMakePoint(right - 2, y)];
        [line setLineWidth:(i == 0 || i == hourCount) ? 0.20 : 0.24];
        [line stroke];
    }

    NSArray *visualBlocks = self.stats[@"visual_blocks"] ?: @[];
    NSTimeInterval animationAge = self.timelineLoadAnimationStart > 0
        ? [NSDate timeIntervalSinceReferenceDate] - self.timelineLoadAnimationStart
        : DBL_MAX;
    BOOL animatingLoad = animationAge < 0.42;
    NSInteger activityDrawIndex = 0;
    NSInteger calendarDrawIndex = 0;
    NSDictionary *hoverLabelBlock = nil;
    NSRect hoverLabelRect = NSZeroRect;
    NSRect gridClipRect = NSMakeRect(left, visibleGridTop, right - left, visibleGridHeight);
    BOOL shouldDrawNowLabel = NO;
    CGFloat nowYForLabel = 0;
    NSString *nowLabelText = nil;
    [NSGraphicsContext saveGraphicsState];
    [[NSBezierPath bezierPathWithRect:gridClipRect] addClip];

    for (NSDictionary *block in visualBlocks) {
        if (![block[@"visual_layer"] isEqualToString:@"activity"]) {
            continue;
        }
        NSRect eventRect = [self eventRectForBlock:block layout:layout timelineRect:rect];
        if (NSEqualRects(eventRect, NSZeroRect)) {
            continue;
        }
        NSInteger blockAnimationIndex = activityDrawIndex++;
        BOOL mixed = [block[@"mode"] isEqualToString:@"碎片"] ||
                     [block[@"kind"] isEqualToString:@"mixed"] ||
                     [block[@"key"] isEqualToString:@"__mixed_work__"];
        BOOL hovered = (block == self.hoveredBlock);
        BOOL selected = (block == self.selectedBlock);
        NSRect displayRect = eventRect;
        if (hovered || selected) {
            displayRect = NSOffsetRect(displayRect, 0, -1);
        }

        CGFloat animationAlpha = 1.0;
        if (animatingLoad) {
            double delay = MIN(0.10, blockAnimationIndex * 0.006);
            double rawProgress = (animationAge - delay) / 0.26;
            rawProgress = MAX(0, MIN(1, rawProgress));
            double eased = 1.0 - pow(1.0 - rawProgress, 3.0);
            animationAlpha = 0.12 + 0.88 * eased;
            displayRect = NSOffsetRect(displayRect, -14.0 * (1.0 - eased), 0);
        }

        CGFloat focusAlpha = animationAlpha * [self timelineAlphaForBlock:block selected:selected hovered:hovered calendarLayer:NO];
        [NSGraphicsContext saveGraphicsState];
        if (focusAlpha < 0.999) {
            CGContextSetAlpha(NSGraphicsContext.currentContext.CGContext, focusAlpha);
        }

        if (!hovered && !selected) {
            [self drawActivityTraceForBlock:block inRect:eventRect layout:layout visualBlocks:visualBlocks];
            [NSGraphicsContext restoreGraphicsState];
            continue;
        }

        if ([block[@"kind"] isEqualToString:@"gap"]) {
            if (hovered || selected) {
                FillRoundedRect(displayRect, 5, [GapFillColor() colorWithAlphaComponent:(AppIsDark() ? 0.22 : 0.18)]);
            }
        } else if (mixed) {
            NSRect railRect = (hovered || selected) ? displayRect : CenteredTimelineRailRect(displayRect, 2.0);
            [self drawProportionalFillForMixedBlock:block inRect:railRect hovered:hovered muted:YES];
        } else {
            NSColor *baseColor = ColorForKey(block[@"key"]);
            [self drawActivityRailBlockWithColor:baseColor inRect:displayRect hovered:hovered || selected];
        }
        [self drawTimelineFocusForBlock:block inRect:displayRect mixed:mixed calendarLayer:NO];
        if (hovered || selected) {
            StrokeRoundedRect(displayRect, 6, [NSColor.whiteColor colorWithAlphaComponent:(AppIsDark() ? 0.18 : 0.30)], 0.7);
        }
        if (hovered) {
            hoverLabelBlock = block;
            hoverLabelRect = displayRect;
        }
        [NSGraphicsContext restoreGraphicsState];
    }

    for (NSDictionary *block in visualBlocks) {
        if (![block[@"visual_layer"] isEqualToString:@"calendar"]) {
            continue;
        }
        NSDate *blockStart = block[@"start"];
        NSDate *blockEnd = block[@"end"];
        NSRect eventRect = [self eventRectForBlock:block layout:layout timelineRect:rect];
        if (NSEqualRects(eventRect, NSZeroRect)) {
            continue;
        }
        NSInteger blockAnimationIndex = calendarDrawIndex++;
        BOOL mixed = [block[@"mode"] isEqualToString:@"碎片"] ||
                     [block[@"kind"] isEqualToString:@"mixed"] ||
                     [block[@"key"] isEqualToString:@"__mixed_work__"];
        BOOL mixedRule = [block[@"mode"] isEqualToString:@"混合规则"];
	        BOOL ratioSegmented = mixed || mixedRule;
	        BOOL hovered = (block == self.hoveredBlock);
	        BOOL calendarLayer = [block[@"visual_layer"] isEqualToString:@"calendar"];
	        BOOL selected = (block == self.selectedBlock);
	        BOOL projectFilteredOut = self.selectedProjectFilter.length > 0 &&
	            ![block[@"project_title"] isEqualToString:self.selectedProjectFilter];
	        NSRect displayRect = eventRect;
	        if ((hovered || selected) && calendarLayer) {
	            displayRect = NSOffsetRect(displayRect, 0, -2);
	        }
	        BOOL compactCalendar = calendarLayer &&
	            ShouldUseCompactCalendarChrome(displayRect.size.height, hovered, selected) &&
	            ![block[@"kind"] isEqualToString:@"gap"];

        CGFloat animationAlpha = 1.0;
        if (animatingLoad) {
            double delay = MIN(0.12, blockAnimationIndex * 0.010);
            double rawProgress = (animationAge - delay) / 0.30;
            rawProgress = MAX(0, MIN(1, rawProgress));
            double eased = 1.0 - pow(1.0 - rawProgress, 3.0);
            animationAlpha = 0.15 + 0.85 * eased;
            displayRect = NSOffsetRect(displayRect, -20.0 * (1.0 - eased), 0);
        }

        CGFloat focusAlpha = animationAlpha * [self timelineAlphaForBlock:block selected:selected hovered:hovered calendarLayer:YES];
        [NSGraphicsContext saveGraphicsState];
        if (focusAlpha < 0.999) {
            CGContextSetAlpha(NSGraphicsContext.currentContext.CGContext, focusAlpha);
        }

        if ((hovered || selected) && calendarLayer) {
            NSShadow *shadow = [[NSShadow alloc] init];
            shadow.shadowColor = [NSColor.blackColor colorWithAlphaComponent:(AppIsDark() ? 0.32 : 0.16)];
            shadow.shadowBlurRadius = hovered ? 9 : 5;
            shadow.shadowOffset = NSMakeSize(0, -1);
            [NSGraphicsContext saveGraphicsState];
            [shadow set];
            [[NSColor.blackColor colorWithAlphaComponent:0.05] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:displayRect xRadius:6 yRadius:6] fill];
            [NSGraphicsContext restoreGraphicsState];
	        }
	        if (compactCalendar) {
	            NSArray *apps = block[@"top_apps"] ?: @[];
	            NSDictionary *firstApp = apps.firstObject;
	            NSColor *baseColor = firstApp ? ColorForKey(firstApp[@"key"]) : ColorForKey(block[@"key"]);
	            [self drawCompactCalendarEventBlockWithColor:baseColor
	                                                  inRect:displayRect
	                                                    apps:apps
	                                               confirmed:[block[@"calendar_confirmed"] boolValue]
	                                                   muted:projectFilteredOut];
	        } else if ([block[@"kind"] isEqualToString:@"gap"]) {
	            if (hovered) {
	                FillRoundedRect(displayRect, 5, [GapFillColor() colorWithAlphaComponent:0.24]);
	            }
	        } else if ([block[@"kind"] isEqualToString:@"ongoing"]) {
            NSColor *baseColor = ColorForKey(block[@"key"]);
            if (calendarLayer) {
                [self drawCalendarEventBlockWithColor:baseColor inRect:displayRect hovered:hovered muted:YES];
            } else {
                [self drawActivityRailBlockWithColor:baseColor inRect:displayRect hovered:hovered];
            }
        } else if (ratioSegmented) {
            if (calendarLayer) {
                [self drawProportionalFillForMixedBlock:block inRect:displayRect hovered:hovered muted:NO];
            } else {
                NSDictionary *firstApp = [block[@"top_apps"] firstObject];
                NSColor *baseColor = firstApp ? ColorForKey(firstApp[@"key"]) : NSColor.systemGrayColor;
                [self drawActivityRailBlockWithColor:baseColor inRect:displayRect hovered:hovered];
            }
        } else {
            NSColor *baseColor = ColorForKey(block[@"key"]);
            if (calendarLayer) {
                [self drawCalendarEventBlockWithColor:baseColor inRect:displayRect hovered:hovered muted:NO];
                if ((hovered || selected) && AppsHaveMeaningfulMix(block[@"top_apps"] ?: @[])) {
                    [self drawInlineRatioStripForApps:block[@"top_apps"] ?: @[] inRect:displayRect];
                }
                [self drawCalendarStateForBlock:block inRect:displayRect color:baseColor hovered:hovered];
            } else {
                [self drawActivityRailBlockWithColor:baseColor inRect:displayRect hovered:hovered];
            }
	        }
	        if (calendarLayer && ratioSegmented && !compactCalendar) {
	            NSDictionary *firstApp = [block[@"top_apps"] firstObject];
	            NSColor *stateColor = firstApp ? ColorForKey(firstApp[@"key"]) : NSColor.systemGrayColor;
	            [self drawCalendarStateForBlock:block inRect:displayRect color:stateColor hovered:hovered];
	        }
        if (calendarLayer && [block[@"project_title"] length] > 0) {
            CGFloat projectInsetY = displayRect.size.height >= 14.0 ? 4.0 : MAX(1.0, floor((displayRect.size.height - 4.0) / 2.0));
            NSRect projectStrip = NSMakeRect(displayRect.origin.x + 4,
                                             displayRect.origin.y + projectInsetY,
                                             3,
                                             MAX(2.5, displayRect.size.height - projectInsetY * 2.0));
            FillRoundedRect(projectStrip, 1.5, [ProjectColorForTitle(block[@"project_title"]) colorWithAlphaComponent:0.86]);
        }
        if (calendarLayer && projectFilteredOut) {
            FillRoundedRect(displayRect, 7, [PanelColor() colorWithAlphaComponent:0.68]);
        }
        [self drawTimelineFocusForBlock:block inRect:displayRect mixed:ratioSegmented calendarLayer:calendarLayer];
        CGFloat flashAlpha = calendarLayer ? [self flashAlphaForBlock:block] : 0;
        if (flashAlpha > 0) {
            FillRoundedRect(displayRect, 7, [NSColor.whiteColor colorWithAlphaComponent:flashAlpha]);
            StrokeRoundedRect(displayRect, 7, [NSColor.whiteColor colorWithAlphaComponent:MIN(0.92, flashAlpha + 0.18)], 1.2);
        }
        if (hovered) {
            StrokeRoundedRect(displayRect, 7, [NSColor.whiteColor colorWithAlphaComponent:0.74], 1.1);
        } else if (selected) {
            StrokeRoundedRect(displayRect, 7, [NSColor.controlAccentColor colorWithAlphaComponent:0.70], 1.1);
        }

        double naturalSeconds = MAX(0, [blockEnd timeIntervalSinceDate:blockStart]);
        CGFloat naturalEventHeight = span > 0 ? naturalSeconds / span * gridHeight : displayRect.size.height;
        BOOL collidesWithNeighbor = NO;
        if (calendarLayer) {
            for (NSDictionary *otherBlock in visualBlocks) {
                if (otherBlock == block || ![otherBlock[@"visual_layer"] isEqualToString:@"calendar"]) {
                    continue;
                }
                NSRect otherRect = [self eventRectForBlock:otherBlock layout:layout timelineRect:rect];
                if (!NSEqualRects(otherRect, NSZeroRect) && NSIntersectsRect(NSInsetRect(displayRect, 0, -0.5), NSInsetRect(otherRect, 0, -0.5))) {
                    collidesWithNeighbor = YES;
                    break;
                }
            }
        }
        CGFloat textThreshold = calendarLayer ? 18 : 30;
        BOOL textHasRoom = displayRect.size.height >= textThreshold && (!collidesWithNeighbor || naturalEventHeight >= 28);
        BOOL inlineSegmentLabels = ratioSegmented && displayRect.size.height >= 30 && displayRect.size.width >= 150;
        if (hovered && calendarLayer && !projectFilteredOut && !textHasRoom && ![block[@"kind"] isEqualToString:@"gap"]) {
            hoverLabelBlock = block;
            hoverLabelRect = displayRect;
        }
        if (calendarLayer && !projectFilteredOut && textHasRoom && !inlineSegmentLabels && ![block[@"kind"] isEqualToString:@"gap"]) {
            NSString *name = block[@"title"] ?: @"未知";
            if ([block[@"kind"] isEqualToString:@"ongoing"]) {
                name = [NSString stringWithFormat:@"进行中：%@", name];
            }
            NSString *time = [NSString stringWithFormat:@"%@-%@", [[ClockString(blockStart) substringToIndex:5] copy], [[ClockString(blockEnd) substringToIndex:5] copy]];
            if (ratioSegmented) {
                name = (mixed || mixedRule) ? @"混合工作" : (block[@"title"] ?: @"应用占比");
            }
            NSRect textRect = NSInsetRect(displayRect, 10, 4);
            CGFloat titleX = textRect.origin.x;
            CGFloat titleWidth = textRect.size.width - 18;
            BOOL drawTimelineIcon = !ratioSegmented && displayRect.size.height >= 20.0 && displayRect.size.width >= 116.0;
            if (drawTimelineIcon) {
                NSDictionary *iconApp = [block[@"top_apps"] firstObject] ?: @{
                    @"key": block[@"key"] ?: @"",
                    @"bundle_id": block[@"bundle_id"] ?: @"",
                    @"title": block[@"title"] ?: @""
                };
                NSRect iconRect = NSMakeRect(textRect.origin.x,
                                             textRect.origin.y + 1.0,
                                             12.0,
                                             12.0);
                DrawAppIdentityMarkVariant(iconApp,
                                           iconApp[@"key"] ?: block[@"key"],
                                           iconRect,
                                           NO,
                                           [NSColor.whiteColor colorWithAlphaComponent:0.82],
                                           nil);
                titleX += 17.0;
                titleWidth -= 17.0;
            }
            [name drawInRect:NSMakeRect(titleX, textRect.origin.y, MAX(24.0, titleWidth), 14) withAttributes:eventAttrs];
            if (displayRect.size.height >= 38 || (calendarLayer && displayRect.size.height >= 34)) {
                [time drawInRect:NSMakeRect(textRect.origin.x, textRect.origin.y + 15, textRect.size.width - 18, 12) withAttributes:eventSubAttrs];
            }
        }
        [NSGraphicsContext restoreGraphicsState];
    }

    if (self.manualDraftBlock) {
        NSRect draftRect = [self eventRectForBlock:self.manualDraftBlock layout:layout timelineRect:rect];
        if (!NSEqualRects(draftRect, NSZeroRect)) {
            NSColor *draftColor = ColorForKey(@"__manual_block__");
            double draftSeconds = [self.manualDraftBlock[@"wall_seconds"] doubleValue];
            BOOL ready = draftSeconds >= 180.0;
            NSShadow *shadow = [[NSShadow alloc] init];
            shadow.shadowColor = [NSColor.blackColor colorWithAlphaComponent:(AppIsDark() ? 0.30 : 0.14)];
            shadow.shadowBlurRadius = ready ? 10 : 5;
            shadow.shadowOffset = NSMakeSize(0, -2);
            [NSGraphicsContext saveGraphicsState];
            [shadow set];
            FillRoundedRect(draftRect, 7, [draftColor colorWithAlphaComponent:ready ? (AppIsDark() ? 0.64 : 0.58) : (AppIsDark() ? 0.30 : 0.22)]);
            [NSGraphicsContext restoreGraphicsState];
            NSBezierPath *draftPath = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(draftRect, 0.5, 0.5) xRadius:7 yRadius:7];
            if (!ready) {
                CGFloat dash[] = {4.0, 3.5};
                [draftPath setLineDash:dash count:2 phase:0];
            }
            [draftPath setLineWidth:ready ? 1.1 : 0.9];
            [[NSColor.whiteColor colorWithAlphaComponent:ready ? 0.68 : 0.46] setStroke];
            [draftPath stroke];

            NSString *time = [NSString stringWithFormat:@"%@-%@",
                              [ClockString(self.manualDraftBlock[@"start"]) substringToIndex:5],
                              [ClockString(self.manualDraftBlock[@"end"]) substringToIndex:5]];
            NSString *label = ready
                ? [NSString stringWithFormat:@"新时段 · %@", time]
                : [NSString stringWithFormat:@"至少 3 分钟 · %@", time];
            NSRect textRect = NSInsetRect(draftRect, 10, 4);
            [label drawInRect:NSMakeRect(textRect.origin.x, textRect.origin.y, textRect.size.width - 8, 14)
                withAttributes:eventAttrs];
            if (draftRect.size.height >= 34) {
                NSString *sub = ready ? @"松开后命名" : ShortDuration(MAX(0, 180.0 - draftSeconds));
                [sub drawInRect:NSMakeRect(textRect.origin.x, textRect.origin.y + 15, textRect.size.width - 8, 12)
                 withAttributes:eventSubAttrs];
            }
        }
    }

    NSDate *now = DashboardNow();
    NSDate *rangeEnd = layout[@"range_end"];
    if ([now compare:rangeStart] != NSOrderedAscending && [now compare:rangeEnd] == NSOrderedAscending) {
        double offset = [now timeIntervalSinceDate:rangeStart] / span;
        CGFloat y = gridTop + offset * gridHeight;
        if (y >= visibleGridTop && y <= visibleGridBottom) {
            NSColor *nowColor = NowIndicatorColor();
            [[nowColor colorWithAlphaComponent:0.18] setStroke];
            NSBezierPath *glow = [NSBezierPath bezierPath];
            [glow moveToPoint:NSMakePoint(left, y)];
            [glow lineToPoint:NSMakePoint(right, y)];
            [glow setLineWidth:4];
            [glow stroke];
            [[nowColor colorWithAlphaComponent:0.86] setStroke];
            NSBezierPath *nowLine = [NSBezierPath bezierPath];
            [nowLine moveToPoint:NSMakePoint(left, y)];
            [nowLine lineToPoint:NSMakePoint(right, y)];
            [nowLine setLineWidth:1.2];
            [nowLine stroke];
            shouldDrawNowLabel = YES;
            nowYForLabel = y;
            nowLabelText = [ClockString(now) substringToIndex:5];
        }
    }
    [NSGraphicsContext restoreGraphicsState];

    if (shouldDrawNowLabel) {
        NSColor *nowColor = NowIndicatorColor();
        CGFloat labelWidth = 48;
        CGFloat labelHeight = 18;
        CGFloat labelY = MAX(visibleGridTop + 3, MIN(nowYForLabel - labelHeight / 2.0, visibleGridBottom - labelHeight - 3));
        NSRect nowPill = NSMakeRect(left - labelWidth - 6, labelY, labelWidth, labelHeight);
        FillRoundedRect(nowPill, 7, [nowColor colorWithAlphaComponent:0.96]);
        NSDictionary *nowAttrs = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightSemibold],
                                   NSForegroundColorAttributeName: NSColor.whiteColor};
        DrawCenteredString(nowLabelText ?: @"现在", nowPill, nowAttrs);
        [[nowColor colorWithAlphaComponent:0.96] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(left - 4, nowYForLabel - 3, 6, 6)] fill];
    }

    if (hoverLabelBlock) {
        [self drawCompactHoverLabelForBlock:hoverLabelBlock nearRect:hoverLabelRect timelineRect:rect];
    }

    CGFloat maxScroll = [layout[@"max_scroll"] doubleValue];
    if (maxScroll > 0.5) {
        CGFloat visibleGridTop = [layout[@"visible_grid_top"] doubleValue];
        CGFloat visibleGridHeight = [layout[@"visible_grid_height"] doubleValue];
        CGFloat scrollY = [layout[@"scroll_y"] doubleValue];
        CGFloat thumbHeight = MAX(36.0, visibleGridHeight * visibleGridHeight / MAX(visibleGridHeight, gridHeight));
        CGFloat travel = MAX(1.0, visibleGridHeight - thumbHeight);
        CGFloat thumbY = visibleGridTop + travel * (scrollY / maxScroll);
        NSRect thumb = NSMakeRect(NSMaxX(rect) - 10, thumbY, 2.5, thumbHeight);
        FillRoundedRect(thumb, 1.25, [DynamicRGB(60, 60, 67, 245, 245, 247) colorWithAlphaComponent:(AppIsDark() ? 0.090 : 0.13)]);
    }
    [NSGraphicsContext restoreGraphicsState];
}
@end

@interface DashboardViewController : NSViewController
@property(nonatomic, weak) id actionTarget;
@property(nonatomic, strong) DashboardView *dashboardView;
@property(nonatomic, strong) NSTimer *pulseTimer;
- (void)refreshWithStore:(SegmentStore *)store
             displayDate:(NSDate *)displayDate
             openSegment:(NSDictionary *)openSegment
      openResidentSegment:(NSDictionary *)openResidentSegment
     existingCalendarKeys:(NSSet<NSString *> *)existingCalendarKeys
     ignoredCalendarKeys:(NSSet<NSString *> *)ignoredCalendarKeys
	    appWriteMappings:(NSDictionary<NSString *, NSDictionary *> *)appWriteMappings
           projectLabels:(NSDictionary<NSString *, NSString *> *)projectLabels
             blockTitles:(NSDictionary<NSString *, NSString *> *)blockTitles
             manualBlocks:(NSArray *)manualBlocks
               recording:(BOOL)recording
                  status:(NSString *)status;
@end

@implementation DashboardViewController
- (void)dealloc {
    [self.pulseTimer invalidate];
}

- (void)loadView {
    NSVisualEffectView *root = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, 1160, 760)];
    root.material = NSVisualEffectMaterialPopover;
    root.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    root.state = NSVisualEffectStateActive;
    root.wantsLayer = YES;
    root.layer.cornerRadius = 16;
    self.dashboardView = [[DashboardView alloc] initWithFrame:root.bounds];
    self.dashboardView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.dashboardView.actionTarget = self.actionTarget;
    [root addSubview:self.dashboardView];

    self.view = root;

    __weak DashboardViewController *weakSelf = self;
    self.pulseTimer = [NSTimer timerWithTimeInterval:1.0 / 24.0 repeats:YES block:^(NSTimer *timer) {
        DashboardViewController *strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.view.window) {
            return;
        }
        [strongSelf.dashboardView setNeedsDisplayInRect:NSMakeRect(strongSelf.view.bounds.size.width - 190, 12, 150, 38)];
        if ([strongSelf.dashboardView hasActiveFlashes] || [strongSelf.dashboardView hasActiveTimelineLoadAnimation]) {
            [strongSelf.dashboardView setNeedsDisplayInRect:[strongSelf.dashboardView timelineRect]];
        }
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.pulseTimer forMode:NSRunLoopCommonModes];
}

- (void)setActionTarget:(id)actionTarget {
    _actionTarget = actionTarget;
    self.dashboardView.actionTarget = actionTarget;
}

- (void)refreshWithStore:(SegmentStore *)store
             displayDate:(NSDate *)displayDate
             openSegment:(NSDictionary *)openSegment
      openResidentSegment:(NSDictionary *)openResidentSegment
     existingCalendarKeys:(NSSet<NSString *> *)existingCalendarKeys
     ignoredCalendarKeys:(NSSet<NSString *> *)ignoredCalendarKeys
	    appWriteMappings:(NSDictionary<NSString *, NSDictionary *> *)appWriteMappings
           projectLabels:(NSDictionary<NSString *, NSString *> *)projectLabels
             blockTitles:(NSDictionary<NSString *, NSString *> *)blockTitles
             manualBlocks:(NSArray *)manualBlocks
               recording:(BOOL)recording
                  status:(NSString *)status {
    NSString *selectedKey = self.dashboardView.selectedBlock[@"calendar_block_key"];
    NSDictionary *stats = DashboardStats(store,
                                         displayDate,
                                         openSegment,
                                         openResidentSegment,
                                         existingCalendarKeys,
                                         ignoredCalendarKeys,
                                         appWriteMappings,
                                         projectLabels,
                                         blockTitles,
                                         manualBlocks ?: @[]);
    self.dashboardView.stats = stats;
    NSArray *visualBlocks = stats[@"visual_blocks"] ?: @[];
    NSArray *candidates = stats[@"candidates"] ?: @[];
    [self.dashboardView reconcileInlineEditorsWithVisualBlocks:visualBlocks];
    NSInteger timelineSignature = [stats[@"segment_count"] integerValue];
    timelineSignature = timelineSignature * 31 + (NSInteger)visualBlocks.count;
    timelineSignature = timelineSignature * 31 + (NSInteger)candidates.count;
    timelineSignature = timelineSignature * 31 + [stats[@"pending_candidate_count"] integerValue];
    NSDate *statsDisplayDate = stats[@"display_date"];
    timelineSignature = timelineSignature * 31 + (NSInteger)llround((statsDisplayDate ?: [NSDate date]).timeIntervalSince1970 / 86400.0);
    NSDictionary *lastVisualBlock = visualBlocks.lastObject;
    NSString *lastKey = lastVisualBlock[@"calendar_block_key"] ?: lastVisualBlock[@"key"] ?: @"";
    timelineSignature = timelineSignature * 31 + (NSInteger)lastKey.hash;
    [self.dashboardView noteTimelineSignature:timelineSignature];
    [self.dashboardView autoPositionTimelineIfNeeded];
    self.dashboardView.recording = recording;
    self.dashboardView.statusText = status;
    self.dashboardView.hoveredBlock = nil;
    self.dashboardView.selectedBlock = nil;
    if (selectedKey.length > 0) {
        for (NSDictionary *block in stats[@"visual_blocks"] ?: @[]) {
            if ([block[@"calendar_block_key"] isEqualToString:selectedKey]) {
                self.dashboardView.selectedBlock = block;
                break;
            }
        }
    }
    [self.dashboardView setNeedsDisplay:YES];
}
@end

static NSArray<NSDictionary *> *AppFilterRowsForDate(SegmentStore *store,
                                                      NSDate *date,
                                                      NSSet<NSString *> *ignoredKeys,
                                                      NSDictionary *existingMappings) {
    NSDate *safeDate = date ?: [NSDate date];
    NSSet *safeIgnoredKeys = ignoredKeys ?: [NSSet set];
    NSDictionary *safeExistingMappings = [existingMappings isKindOfClass:NSDictionary.class] ? existingMappings : @{};
    NSArray *segments = ReadRawSegmentsForAppFiltering([store rawURLForDate:safeDate]);
    NSArray *residentSegments = ReadRawSegmentsForAppFiltering([store residentRawURLForDate:safeDate]);
    NSDictionary *summary = AppSummaryFromSegments([segments arrayByAddingObjectsFromArray:residentSegments]);
    NSArray *topApps = summary[@"top_apps"] ?: @[];
    NSMutableDictionary<NSString *, NSMutableDictionary *> *rowsByKey = [NSMutableDictionary dictionary];

    for (NSDictionary *app in topApps) {
        NSString *key = app[@"key"];
        if (key.length == 0 || [key hasPrefix:@"__"]) {
            continue;
        }
        rowsByKey[key] = [@{
            @"key": key,
            @"title": app[@"title"] ?: key,
            @"bundle_id": app[@"bundle_id"] ?: @"",
            @"seconds": app[@"seconds"] ?: @0,
            @"suggested_filter_reason": SuggestedAppFilterReason(key, app[@"title"] ?: key, app[@"bundle_id"] ?: @"")
        } mutableCopy];
    }

    for (NSString *key in safeIgnoredKeys) {
        if (key.length == 0 || rowsByKey[key]) {
            continue;
        }
        NSDictionary *mapping = safeExistingMappings[key];
        NSString *title = [mapping isKindOfClass:NSDictionary.class] && [mapping[@"event_title"] length] > 0 ? mapping[@"event_title"] : key;
        rowsByKey[key] = [@{
            @"key": key,
            @"title": title,
            @"bundle_id": @"",
            @"seconds": @0,
            @"suggested_filter_reason": SuggestedAppFilterReason(key, title, @"")
        } mutableCopy];
    }

    NSArray *rows = [rowsByKey.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        BOOL leftIgnored = [safeIgnoredKeys containsObject:a[@"key"]];
        BOOL rightIgnored = [safeIgnoredKeys containsObject:b[@"key"]];
        if (leftIgnored != rightIgnored) {
            return leftIgnored ? NSOrderedAscending : NSOrderedDescending;
        }
        BOOL leftSuggested = [a[@"suggested_filter_reason"] length] > 0;
        BOOL rightSuggested = [b[@"suggested_filter_reason"] length] > 0;
        if (leftSuggested != rightSuggested) {
            return leftSuggested ? NSOrderedAscending : NSOrderedDescending;
        }
        return [b[@"seconds"] compare:a[@"seconds"]];
    }];
    return rows.count > 16 ? [rows subarrayWithRange:NSMakeRange(0, 16)] : rows;
}

static void PrintAppFilterRows(NSDate *date,
                               SegmentStore *store,
                               NSSet<NSString *> *ignoredKeys,
                               NSDictionary *existingMappings) {
    NSArray<NSDictionary *> *rows = AppFilterRowsForDate(store, date, ignoredKeys, existingMappings);
    NSInteger suggestedCount = 0;
    for (NSDictionary *row in rows) {
        if ([row[@"suggested_filter_reason"] length] > 0) {
            suggestedCount++;
        }
    }
    printf("date=%s rows=%ld suggested_rows=%ld ignored_rows=%ld\n",
           [DayString(date) UTF8String],
           (long)rows.count,
           (long)suggestedCount,
           (long)ignoredKeys.count);
    for (NSDictionary *row in rows) {
        NSString *key = row[@"key"] ?: @"";
        NSString *title = row[@"title"] ?: key;
        NSString *reason = row[@"suggested_filter_reason"] ?: @"";
        BOOL ignored = [ignoredKeys containsObject:key];
        printf("key=%s title=%s seconds=%.1f ignored=%s suggested=%s\n",
               key.UTF8String,
               title.UTF8String,
               [row[@"seconds"] doubleValue],
               ignored ? "yes" : "no",
               reason.UTF8String);
    }
}

typedef void (^AppFilterSettingsSaveHandler)(NSSet<NSString *> *ignoredKeys, BOOL appliedSuggestions);

@interface AppFilterSettingsController : NSWindowController <NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate>
@property(nonatomic, copy) NSArray<NSDictionary *> *allRows;
@property(nonatomic, copy) NSArray<NSDictionary *> *visibleRows;
@property(nonatomic, strong) NSMutableSet<NSString *> *ignoredKeys;
@property(nonatomic, strong) NSTableView *tableView;
@property(nonatomic, strong) NSSearchField *searchField;
@property(nonatomic, strong) NSTextField *summaryLabel;
@property(nonatomic, copy) AppFilterSettingsSaveHandler saveHandler;
@property(nonatomic, assign) BOOL didApplySuggestions;
- (instancetype)initWithRows:(NSArray<NSDictionary *> *)rows
                 ignoredKeys:(NSSet<NSString *> *)ignoredKeys
                 saveHandler:(AppFilterSettingsSaveHandler)saveHandler;
@end

@implementation AppFilterSettingsController

- (instancetype)initWithRows:(NSArray<NSDictionary *> *)rows
                 ignoredKeys:(NSSet<NSString *> *)ignoredKeys
                 saveHandler:(AppFilterSettingsSaveHandler)saveHandler {
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 680, 500)
                                                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    self = [super initWithWindow:panel];
    if (self) {
        _allRows = [rows copy] ?: @[];
        _visibleRows = _allRows;
        _ignoredKeys = [ignoredKeys mutableCopy] ?: [NSMutableSet set];
        _saveHandler = [saveHandler copy];
        panel.title = @"应用过滤";
        panel.minSize = NSMakeSize(560, 380);
        panel.releasedWhenClosed = NO;
        [self buildInterface];
        [self updateSummary];
    }
    return self;
}

- (void)buildInterface {
    NSView *content = self.window.contentView;
    content.wantsLayer = YES;
    content.layer.backgroundColor = NSColor.windowBackgroundColor.CGColor;

    NSTextField *title = [NSTextField labelWithString:@"应用过滤"];
    title.font = [NSFont systemFontOfSize:22 weight:NSFontWeightSemibold];
    title.frame = NSMakeRect(24, 452, 180, 28);
    title.autoresizingMask = NSViewMinYMargin;
    [content addSubview:title];

    NSTextField *info = [NSTextField wrappingLabelWithString:@"取消勾选后，这个应用不进入统计、片段分布和日历候选；raw 记录仍保留。"];
    info.font = [NSFont systemFontOfSize:12];
    info.textColor = NSColor.secondaryLabelColor;
    info.frame = NSMakeRect(24, 420, 632, 32);
    info.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [content addSubview:info];

    self.searchField = [[NSSearchField alloc] initWithFrame:NSMakeRect(24, 382, 290, 28)];
    self.searchField.placeholderString = @"搜索应用或标识";
    self.searchField.delegate = self;
    self.searchField.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [content addSubview:self.searchField];

    NSButton *suggestButton = [NSButton buttonWithTitle:@"应用建议" target:self action:@selector(applySuggestedFilters:)];
    suggestButton.bezelStyle = NSBezelStyleRounded;
    suggestButton.enabled = [self suggestedRowCount] > 0;
    suggestButton.frame = NSMakeRect(326, 382, 92, 28);
    suggestButton.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [content addSubview:suggestButton];

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(24, 78, 632, 292)];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    self.tableView = [[NSTableView alloc] initWithFrame:scroll.bounds];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.rowHeight = 34.0;
    self.tableView.usesAlternatingRowBackgroundColors = YES;
    self.tableView.allowsColumnResizing = YES;

    NSTableColumn *enabledColumn = [[NSTableColumn alloc] initWithIdentifier:@"enabled"];
    enabledColumn.title = @"统计";
    enabledColumn.width = 56;
    enabledColumn.minWidth = 48;
    enabledColumn.maxWidth = 64;
    [self.tableView addTableColumn:enabledColumn];

    NSTableColumn *appColumn = [[NSTableColumn alloc] initWithIdentifier:@"app"];
    appColumn.title = @"应用";
    appColumn.width = 160;
    appColumn.minWidth = 120;
    [self.tableView addTableColumn:appColumn];

    NSTableColumn *durationColumn = [[NSTableColumn alloc] initWithIdentifier:@"duration"];
    durationColumn.title = @"今日";
    durationColumn.width = 82;
    durationColumn.minWidth = 70;
    [self.tableView addTableColumn:durationColumn];

    NSTableColumn *keyColumn = [[NSTableColumn alloc] initWithIdentifier:@"key"];
    keyColumn.title = @"标识";
    keyColumn.width = 190;
    keyColumn.minWidth = 120;
    [self.tableView addTableColumn:keyColumn];

    NSTableColumn *reasonColumn = [[NSTableColumn alloc] initWithIdentifier:@"reason"];
    reasonColumn.title = @"建议";
    reasonColumn.width = 128;
    reasonColumn.minWidth = 90;
    [self.tableView addTableColumn:reasonColumn];

    scroll.documentView = self.tableView;
    [content addSubview:scroll];

    self.summaryLabel = [NSTextField labelWithString:@""];
    self.summaryLabel.font = [NSFont systemFontOfSize:12];
    self.summaryLabel.textColor = NSColor.secondaryLabelColor;
    self.summaryLabel.frame = NSMakeRect(24, 42, 360, 18);
    self.summaryLabel.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [content addSubview:self.summaryLabel];

    NSButton *cancelButton = [NSButton buttonWithTitle:@"取消" target:self action:@selector(cancel:)];
    cancelButton.bezelStyle = NSBezelStyleRounded;
    cancelButton.frame = NSMakeRect(474, 24, 82, 30);
    cancelButton.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [content addSubview:cancelButton];

    NSButton *saveButton = [NSButton buttonWithTitle:@"保存" target:self action:@selector(save:)];
    saveButton.bezelStyle = NSBezelStyleRounded;
    saveButton.keyEquivalent = @"\r";
    saveButton.frame = NSMakeRect(570, 24, 86, 30);
    saveButton.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [content addSubview:saveButton];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return self.visibleRows.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    NSDictionary *app = row >= 0 && row < (NSInteger)self.visibleRows.count ? self.visibleRows[row] : @{};
    NSString *identifier = tableColumn.identifier;
    NSString *key = app[@"key"] ?: @"";

    if ([identifier isEqualToString:@"enabled"]) {
        NSButton *check = [tableView makeViewWithIdentifier:@"enabledCheck" owner:self];
        if (!check) {
            check = [NSButton checkboxWithTitle:@"" target:self action:@selector(toggleIncluded:)];
            check.identifier = @"enabledCheck";
        }
        check.tag = row;
        check.state = [self.ignoredKeys containsObject:key] ? NSControlStateValueOff : NSControlStateValueOn;
        return check;
    }

    NSString *text = @"";
    NSColor *textColor = NSColor.labelColor;
    NSFont *font = [NSFont systemFontOfSize:12];
    if ([identifier isEqualToString:@"app"]) {
        text = app[@"title"] ?: key;
        font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    } else if ([identifier isEqualToString:@"duration"]) {
        double seconds = [app[@"seconds"] doubleValue];
        text = seconds > 0 ? ShortDuration(seconds) : @"无";
        textColor = NSColor.secondaryLabelColor;
    } else if ([identifier isEqualToString:@"key"]) {
        text = key;
        textColor = NSColor.secondaryLabelColor;
    } else if ([identifier isEqualToString:@"reason"]) {
        NSString *reason = app[@"suggested_filter_reason"] ?: @"";
        text = reason.length > 0 ? reason : @"";
        textColor = reason.length > 0 ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor;
    }

    NSTextField *label = [tableView makeViewWithIdentifier:identifier owner:self];
    if (!label) {
        label = [NSTextField labelWithString:@""];
        label.identifier = identifier;
        label.lineBreakMode = NSLineBreakByTruncatingMiddle;
    }
    label.stringValue = text;
    label.textColor = textColor;
    label.font = font;
    return label;
}

- (void)toggleIncluded:(NSButton *)sender {
    NSInteger row = sender.tag;
    if (row < 0 || row >= (NSInteger)self.visibleRows.count) {
        return;
    }
    NSString *key = self.visibleRows[row][@"key"] ?: @"";
    if (key.length == 0) {
        return;
    }
    if (sender.state == NSControlStateValueOn) {
        [self.ignoredKeys removeObject:key];
    } else {
        [self.ignoredKeys addObject:key];
    }
    [self updateSummary];
}

- (void)controlTextDidChange:(NSNotification *)notification {
    [self applySearchFilter];
}

- (void)applySearchFilter {
    NSString *query = self.searchField.stringValue ?: @"";
    if (query.length == 0) {
        self.visibleRows = self.allRows;
    } else {
        NSMutableArray *matches = [NSMutableArray array];
        for (NSDictionary *row in self.allRows) {
            NSString *haystack = [NSString stringWithFormat:@"%@ %@ %@ %@",
                                  row[@"title"] ?: @"",
                                  row[@"key"] ?: @"",
                                  row[@"bundle_id"] ?: @"",
                                  row[@"suggested_filter_reason"] ?: @""];
            if ([haystack rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [matches addObject:row];
            }
        }
        self.visibleRows = matches;
    }
    [self.tableView reloadData];
    [self updateSummary];
}

- (NSInteger)suggestedRowCount {
    NSInteger count = 0;
    for (NSDictionary *row in self.allRows) {
        if ([row[@"suggested_filter_reason"] length] > 0) {
            count++;
        }
    }
    return count;
}

- (void)applySuggestedFilters:(id)sender {
    self.didApplySuggestions = YES;
    for (NSDictionary *row in self.allRows) {
        NSString *key = row[@"key"] ?: @"";
        if (key.length > 0 && [row[@"suggested_filter_reason"] length] > 0) {
            [self.ignoredKeys addObject:key];
        }
    }
    [self.tableView reloadData];
    [self updateSummary];
}

- (void)updateSummary {
    NSInteger visibleIgnored = 0;
    for (NSDictionary *row in self.visibleRows) {
        NSString *key = row[@"key"] ?: @"";
        if ([self.ignoredKeys containsObject:key]) {
            visibleIgnored++;
        }
    }
    self.summaryLabel.stringValue = [NSString stringWithFormat:@"显示 %ld 个应用，已过滤 %ld 个；建议 %ld 个。保存后生效。",
                                     (long)self.visibleRows.count,
                                     (long)visibleIgnored,
                                     (long)[self suggestedRowCount]];
}

- (void)cancel:(id)sender {
    [self close];
}

- (void)save:(id)sender {
    if (self.saveHandler) {
        self.saveHandler([self.ignoredKeys copy], self.didApplySuggestions);
    }
    [self close];
}

@end

@interface AppDelegate : NSObject <NSApplicationDelegate, NSPopoverDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSPopover *popover;
@property(nonatomic, strong) DashboardViewController *dashboardController;
@property(nonatomic, strong) SegmentStore *store;
@property(nonatomic, strong) TrackerController *tracker;
@property(nonatomic, strong) EKEventStore *eventStore;
@property(nonatomic, strong) NSTimer *dashboardRefreshTimer;
@property(nonatomic, strong) NSTimer *autoCalendarWriteTimer;
@property(nonatomic, strong) NSDate *selectedDashboardDate;
@property(nonatomic, copy) NSString *lastStatus;
@property(nonatomic, strong) AppFilterSettingsController *appFilterSettingsController;
@end

@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    RegisterDefaultSettings();
    NSURL *dataDirectory = [self applicationSupportDirectory];
    self.store = [[SegmentStore alloc] initWithDataDirectory:dataDirectory];
    self.tracker = [[TrackerController alloc] initWithStore:self.store];
    self.eventStore = [[EKEventStore alloc] init];
    self.selectedDashboardDate = CalendarStartOfDay([NSDate date]);
    __weak AppDelegate *weakSelf = self;
    self.tracker.statusChanged = ^(NSString *status) {
        [weakSelf updateStatus:status];
    };

    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"FT";
    self.statusItem.button.target = self;
    self.statusItem.button.action = @selector(togglePopover:);

    self.dashboardController = [[DashboardViewController alloc] init];
    self.dashboardController.actionTarget = self;
    self.popover = [[NSPopover alloc] init];
    self.popover.behavior = NSPopoverBehaviorTransient;
    self.popover.contentSize = NSMakeSize(1160, 760);
    self.popover.contentViewController = self.dashboardController;
    self.popover.delegate = self;

    [self.tracker start];
    [self refreshDashboard];
    [self refreshMenu];
    [self scheduleAutoCalendarWriteTimer];
}

- (NSURL *)applicationSupportDirectory {
    NSURL *base = [[NSFileManager defaultManager] URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil];
    return [base URLByAppendingPathComponent:@"Gotowork" isDirectory:YES];
}

- (NSDate *)dashboardDate {
    NSDate *date = CalendarStartOfDay(self.selectedDashboardDate ?: [NSDate date]);
    NSDate *today = CalendarStartOfDay([NSDate date]);
    if ([date compare:today] == NSOrderedDescending) {
        date = today;
        self.selectedDashboardDate = date;
    }
    return date;
}

- (void)selectPreviousDashboardDay:(id)sender {
    self.selectedDashboardDate = DateByAddingDays([self dashboardDate], -1);
    [self updateStatus:[NSString stringWithFormat:@"查看 %@", DashboardDateTitle(self.selectedDashboardDate)]];
    [self refreshDashboard];
}

- (void)selectNextDashboardDay:(id)sender {
    NSDate *today = CalendarStartOfDay([NSDate date]);
    NSDate *next = DateByAddingDays([self dashboardDate], 1);
    self.selectedDashboardDate = [next compare:today] == NSOrderedDescending ? today : next;
    [self updateStatus:[NSString stringWithFormat:@"查看 %@", DashboardDateTitle(self.selectedDashboardDate)]];
    [self refreshDashboard];
}

- (void)updateStatus:(NSString *)status {
    self.lastStatus = status ?: @"";
    if (self.popover.isShown) {
        [self refreshDashboard];
    }
    [self refreshMenu];
}

- (EKCalendar *)existingTrackerCalendar {
    for (EKCalendar *calendar in [self.eventStore calendarsForEntityType:EKEntityTypeEvent]) {
        if ([calendar.title isEqualToString:TrackerCalendarTitle]) {
            return calendar;
        }
    }
    return nil;
}

- (NSString *)targetCalendarIdentifier {
    NSString *identifier = [[NSUserDefaults standardUserDefaults] stringForKey:TargetCalendarIdentifierKey];
    return identifier.length > 0 ? identifier : @"";
}

- (NSArray<EKCalendar *> *)writableEventCalendars {
    NSArray *calendars = [self.eventStore calendarsForEntityType:EKEntityTypeEvent];
    NSMutableArray<EKCalendar *> *writable = [NSMutableArray array];
    for (EKCalendar *calendar in calendars) {
        if (!calendar.allowsContentModifications) {
            continue;
        }
        [writable addObject:calendar];
    }
    [writable sortUsingComparator:^NSComparisonResult(EKCalendar *left, EKCalendar *right) {
        NSComparisonResult titleOrder = [left.title localizedCaseInsensitiveCompare:right.title];
        if (titleOrder != NSOrderedSame) {
            return titleOrder;
        }
        return [(left.source.title ?: @"") localizedCaseInsensitiveCompare:(right.source.title ?: @"")];
    }];
    return writable;
}

- (EKCalendar *)selectedExistingCalendar {
    NSString *identifier = [self targetCalendarIdentifier];
    if (identifier.length == 0) {
        return nil;
    }
    EKCalendar *calendar = [self.eventStore calendarWithIdentifier:identifier];
    if (!calendar || !calendar.allowsContentModifications) {
        return nil;
    }
    return calendar;
}

- (EKCalendar *)existingTargetCalendar {
    if ([self targetCalendarIdentifier].length > 0) {
        return [self selectedExistingCalendar];
    }
    return [self existingTrackerCalendar];
}

- (NSString *)targetCalendarDisplayTitle {
    EKCalendar *selected = [self selectedExistingCalendar];
    return selected.title.length > 0 ? selected.title : TrackerCalendarTitle;
}

- (NSSet<NSString *> *)existingCalendarBlockKeysForDay:(NSDate *)day {
    if (!CalendarStatusAllowsFullAccess([EKEventStore authorizationStatusForEntityType:EKEntityTypeEvent])) {
        return [NSSet set];
    }
    EKCalendar *calendar = [self existingTargetCalendar];
    if (!calendar) {
        return [NSSet set];
    }

    NSDate *dayStart = StartOfDay(day);
    NSDate *dayEnd = [dayStart dateByAddingTimeInterval:24 * 60 * 60];
    NSPredicate *predicate = [self.eventStore predicateForEventsWithStartDate:dayStart endDate:dayEnd calendars:@[calendar]];
    NSArray<EKEvent *> *events = [self.eventStore eventsMatchingPredicate:predicate];
    NSMutableSet<NSString *> *keys = [NSMutableSet set];
    for (EKEvent *event in events) {
        NSString *key = GeneratedBlockKeyFromNotes(event.notes);
        if (key.length == 0 && [event.notes containsString:GeneratedEventMarkerPrefix]) {
            key = CalendarBlockKeyForDates(event.startDate, event.endDate);
        }
        if (key.length > 0) {
            [keys addObject:key];
        }
    }
    return keys;
}

- (NSSet<NSString *> *)ignoredCalendarBlockKeys {
    NSArray *keys = [[NSUserDefaults standardUserDefaults] arrayForKey:IgnoredCalendarBlockKeysKey];
    return keys.count ? [NSSet setWithArray:keys] : [NSSet set];
}

- (NSSet<NSString *> *)ignoredAppKeys {
    return IgnoredAppKeysSetting();
}

- (NSDictionary<NSString *, NSString *> *)projectLabelsByBlockKey {
    NSDictionary *labels = [[NSUserDefaults standardUserDefaults] dictionaryForKey:ProjectLabelsByBlockKeyKey];
    return [labels isKindOfClass:NSDictionary.class] ? labels : @{};
}

- (NSDictionary<NSString *, NSString *> *)blockTitlesByBlockKey {
    NSDictionary *titles = [[NSUserDefaults standardUserDefaults] dictionaryForKey:BlockTitlesByBlockKeyKey];
    return [titles isKindOfClass:NSDictionary.class] ? titles : @{};
}

- (NSDictionary<NSString *, NSDictionary *> *)appWriteMappingsByAppKey {
    NSDictionary *mappings = [[NSUserDefaults standardUserDefaults] dictionaryForKey:AppWriteMappingsByKeyKey];
    return [mappings isKindOfClass:NSDictionary.class] ? mappings : @{};
}

- (NSArray *)manualCalendarBlockRecords {
    NSArray *records = [[NSUserDefaults standardUserDefaults] arrayForKey:ManualCalendarBlocksKey];
    return [records isKindOfClass:NSArray.class] ? records : @[];
}

- (NSDictionary *)selectedDashboardBlock {
    return [self.dashboardController.dashboardView primaryDetailBlock];
}

- (BOOL)blockIsCalendarCandidate:(NSDictionary *)block {
    return [block[@"visual_layer"] isEqualToString:@"calendar"] && CalendarBlockKeyForBlock(block).length > 0;
}

- (void)flashWrittenBlockKeys:(NSArray *)keys {
    NSMutableArray<NSString *> *safeKeys = [NSMutableArray array];
    for (NSString *key in keys ?: @[]) {
        if ([key isKindOfClass:NSString.class] && key.length > 0) {
            [safeKeys addObject:key];
        }
    }
    [self.dashboardController.dashboardView flashCalendarBlockKeys:safeKeys];
}

- (void)refreshDashboard {
    NSDate *dashboardDate = [self dashboardDate];
    NSSet<NSString *> *existingKeys = [self existingCalendarBlockKeysForDay:dashboardDate];
    NSSet<NSString *> *ignoredKeys = [self ignoredCalendarBlockKeys];
    NSDictionary<NSString *, NSDictionary *> *appWriteMappings = [self appWriteMappingsByAppKey];
    NSDictionary<NSString *, NSString *> *projectLabels = [self projectLabelsByBlockKey];
    NSDictionary<NSString *, NSString *> *blockTitles = [self blockTitlesByBlockKey];
    NSArray *manualBlocks = [self manualCalendarBlockRecords];
    [self.dashboardController refreshWithStore:self.store
                                   displayDate:dashboardDate
                                   openSegment:[self.tracker currentDashboardSegment]
                           openResidentSegment:[self.tracker currentResidentMeetingSegment]
                            existingCalendarKeys:existingKeys
                             ignoredCalendarKeys:ignoredKeys
	                          appWriteMappings:appWriteMappings
                                  projectLabels:projectLabels
                                    blockTitles:blockTitles
                                   manualBlocks:manualBlocks
                                     recording:self.tracker.isRecording
                                        status:self.lastStatus ?: @""];
}

- (void)startDashboardRefreshTimer {
    [self.dashboardRefreshTimer invalidate];
    self.dashboardRefreshTimer = [NSTimer scheduledTimerWithTimeInterval:5.0 repeats:YES block:^(NSTimer *timer) {
        if (!self.popover.isShown) {
            [timer invalidate];
            return;
        }
        [self refreshDashboard];
    }];
}

- (NSDate *)nextAutoCalendarWriteFireDateAfter:(NSDate *)date {
    if (!AutoCalendarWriteEnabled()) {
        return nil;
    }
    NSDate *now = date ?: [NSDate date];
    NSInteger hour = (NSInteger)llround(AutoCalendarWriteHourSetting());
    NSDate *today = CalendarStartOfDay(now);
    NSDate *todayFire = DateOnDayAtHour(today, hour);
    NSString *lastRunDay = [[NSUserDefaults standardUserDefaults] stringForKey:AutoCalendarLastRunDayKey] ?: @"";
    if ([now compare:todayFire] == NSOrderedAscending) {
        return todayFire;
    }
    if (![lastRunDay isEqualToString:DayString(today)]) {
        return [now dateByAddingTimeInterval:5.0];
    }
    return DateOnDayAtHour(DateByAddingDays(today, 1), hour);
}

- (void)scheduleAutoCalendarWriteTimer {
    [self.autoCalendarWriteTimer invalidate];
    self.autoCalendarWriteTimer = nil;
    NSDate *fireDate = [self nextAutoCalendarWriteFireDateAfter:[NSDate date]];
    if (!fireDate) {
        return;
    }

    NSTimeInterval interval = MAX(1.0, [fireDate timeIntervalSinceNow]);
    __weak AppDelegate *weakSelf = self;
    self.autoCalendarWriteTimer = [NSTimer timerWithTimeInterval:interval repeats:NO block:^(NSTimer *timer) {
        AppDelegate *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        strongSelf.autoCalendarWriteTimer = nil;
        [strongSelf runAutoCalendarWriteIfDue];
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.autoCalendarWriteTimer forMode:NSRunLoopCommonModes];
}

- (void)markAutoCalendarWriteRunForDay:(NSDate *)day {
    [[NSUserDefaults standardUserDefaults] setObject:DayString(day ?: [NSDate date]) forKey:AutoCalendarLastRunDayKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self scheduleAutoCalendarWriteTimer];
}

- (NSArray *)pendingCalendarCandidatesForDay:(NSDate *)day checkpointReason:(NSString *)checkpointReason {
    NSDate *dashboardDate = CalendarStartOfDay(day ?: [NSDate date]);
    if (checkpointReason.length > 0 && SameDay(dashboardDate, [NSDate date])) {
        [self.tracker checkpointWithReason:checkpointReason];
    }
    BOOL selectedIsToday = SameDay(dashboardDate, [NSDate date]);
    NSArray *segments = ReadSegmentsForRange(self.store,
                                             dashboardDate,
                                             DateByAddingDays(dashboardDate, 1),
                                             selectedIsToday ? [self.tracker currentDashboardSegment] : nil);
    NSArray *residentSegments = ReadResidentSegmentsForRange(self.store,
                                                             dashboardDate,
                                                             DateByAddingDays(dashboardDate, 1),
                                                             selectedIsToday ? [self.tracker currentResidentMeetingSegment] : nil);
    NSSet<NSString *> *existingKeys = [self existingCalendarBlockKeysForDay:dashboardDate];
    NSSet<NSString *> *ignoredKeys = [self ignoredCalendarBlockKeys];
    NSArray *candidates = CalendarCandidatesWithState(CalendarCandidatesIncludingManual(segments,
                                                                                       residentSegments,
                                                                                       [self manualCalendarBlockRecords],
                                                                                       dashboardDate),
                                                      existingKeys,
                                                      ignoredKeys,
                                                      [self appWriteMappingsByAppKey],
                                                      [self projectLabelsByBlockKey],
                                                      [self blockTitlesByBlockKey]);
    return PendingCalendarCandidates(candidates, existingKeys, ignoredKeys);
}

- (void)runAutoCalendarWriteIfDue {
    if (!AutoCalendarWriteEnabled()) {
        return;
    }
    NSDate *now = [NSDate date];
    NSDate *today = CalendarStartOfDay(now);
    NSDate *fireDate = DateOnDayAtHour(today, (NSInteger)llround(AutoCalendarWriteHourSetting()));
    NSString *lastRunDay = [[NSUserDefaults standardUserDefaults] stringForKey:AutoCalendarLastRunDayKey] ?: @"";
    if ([now compare:fireDate] == NSOrderedAscending || [lastRunDay isEqualToString:DayString(today)]) {
        [self scheduleAutoCalendarWriteTimer];
        return;
    }

    if (!CalendarStatusAllowsFullAccess([EKEventStore authorizationStatusForEntityType:EKEntityTypeEvent])) {
        [self updateStatus:@"自动写入需要日历权限"];
        [self markAutoCalendarWriteRunForDay:today];
        return;
    }

    NSArray *candidates = [self pendingCalendarCandidatesForDay:today checkpointReason:@"auto-calendar-export"];
    if (candidates.count == 0) {
        [self updateStatus:@"自动写入：没有新的日历块"];
        [self markAutoCalendarWriteRunForDay:today];
        [self refreshDashboard];
        return;
    }

    NSError *writeError = nil;
    NSDictionary *result = [self writeCalendarBlocks:candidates day:today error:&writeError];
    if (!result) {
        [self updateStatus:@"自动写入日历失败"];
        NSLog(@"auto calendar write failed: %@", writeError.localizedDescription ?: @"unknown error");
        [self markAutoCalendarWriteRunForDay:today];
        [self refreshDashboard];
        return;
    }

    NSInteger written = [result[@"written"] integerValue];
    NSInteger skipped = [result[@"skipped"] integerValue];
    NSString *status = skipped > 0
        ? [NSString stringWithFormat:@"自动写入 %ld 条，跳过 %ld 条", (long)written, (long)skipped]
        : [NSString stringWithFormat:@"自动写入 %ld 条日历", (long)written];
    [self updateStatus:status];
    [self markAutoCalendarWriteRunForDay:today];
    [self refreshDashboard];
    [self flashWrittenBlockKeys:result[@"written_keys"]];
}

- (void)popoverDidClose:(NSNotification *)notification {
    [self.dashboardRefreshTimer invalidate];
    self.dashboardRefreshTimer = nil;
}

- (void)popoverWillShow:(NSNotification *)notification {
    [self.dashboardController.dashboardView prepareTimelineForPresentation];
    [self refreshDashboard];
    [self startDashboardRefreshTimer];
}

- (void)refreshMenu {
    self.statusItem.button.title = self.tracker.isRecording ? @"FT Rec" : @"FT";
}

- (void)togglePopover:(id)sender {
    if (self.popover.isShown) {
        [self.popover performClose:sender];
        return;
    }
    [self.dashboardController.dashboardView prepareTimelineForPresentation];
    [self refreshDashboard];
    NSButton *button = self.statusItem.button;
    [self.popover showRelativeToRect:button.bounds ofView:button preferredEdge:NSRectEdgeMinY];
    [self startDashboardRefreshTimer];
}

- (void)showMoreMenu:(id)sender {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"更多"];
    NSArray *items = @[
        @[@"设置", NSStringFromSelector(@selector(openSettings:))],
        @[@"片段分布", NSStringFromSelector(@selector(openDurationDistribution:))],
        @[@"应用过滤", NSStringFromSelector(@selector(openAppFilters:))],
        @[@"预览写入今天", NSStringFromSelector(@selector(writeTodayCalendar:))],
        @[@"日历设置", NSStringFromSelector(@selector(openCalendarSettings:))],
        @[@"应用写入映射", NSStringFromSelector(@selector(openAppWriteMappings:))],
        @[@"打开数据目录", NSStringFromSelector(@selector(openDataFolder:))],
        @[@"检查权限", NSStringFromSelector(@selector(requestPermission:))],
        @[@"退出", NSStringFromSelector(@selector(quit:))]
    ];
    for (NSArray *itemInfo in items) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:itemInfo[0]
                                                     action:NSSelectorFromString(itemInfo[1])
                                              keyEquivalent:@""];
        item.target = self;
        [menu addItem:item];
    }
    NSView *view = [sender isKindOfClass:NSView.class] ? sender : self.dashboardController.view;
    NSEvent *event = NSApp.currentEvent ?: [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                                              location:NSMakePoint(NSMidX(view.bounds), NSMidY(view.bounds))
                                                         modifierFlags:0
                                                             timestamp:0
                                                          windowNumber:view.window.windowNumber
                                                               context:nil
                                                           eventNumber:0
                                                            clickCount:1
                                                              pressure:1];
    [NSMenu popUpContextMenu:menu withEvent:event forView:view];
}

- (void)toggleRecording:(id)sender {
    if (self.tracker.isRecording) {
        [self.tracker stopWithReason:@"manual-stop"];
    } else {
        [self.tracker start];
    }
    [self refreshMenu];
    [self refreshDashboard];
}

- (void)openDataFolder:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:self.store.dataDirectory];
}

- (void)openTodayFile:(id)sender {
    NSURL *today = [self.store todayRawURL];
    if ([[NSFileManager defaultManager] fileExistsAtPath:today.path]) {
        [[NSWorkspace sharedWorkspace] openURL:today];
    } else {
        [[NSWorkspace sharedWorkspace] openURL:self.store.dataDirectory];
    }
}

- (void)openDurationDistribution:(id)sender {
    NSDate *dashboardDate = [self dashboardDate];
    NSArray *foregroundSegments = ReadRawSegmentsIncludingShort([self.store rawURLForDate:dashboardDate]);
    NSArray *residentSegments = ReadRawSegmentsIncludingShort([self.store residentRawURLForDate:dashboardDate]);
    if (foregroundSegments.count == 0 && residentSegments.count == 0) {
        [self showAlertWithTitle:@"还没有片段"
                         message:@"Gotowork 需要先记录到一些前台或常驻时段，才会显示片段分布。"];
        return;
    }

    NSString *report = DurationDistributionReport(foregroundSegments, residentSegments);
    NSArray *lines = [report componentsSeparatedByString:@"\n"];
    CGFloat documentHeight = MAX(220.0, lines.count * 18.0 + 24.0);
    NSTextView *textView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 430, documentHeight)];
    textView.string = report;
    textView.editable = NO;
    textView.selectable = YES;
    textView.drawsBackground = NO;
    textView.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
    textView.textContainerInset = NSMakeSize(10, 10);

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 450, 280)];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    scroll.documentView = textView;

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"片段时长分布";
    alert.informativeText = [NSString stringWithFormat:@"%@ · 原始切换合并 %.0fs",
                             DashboardDateTitle(dashboardDate),
                             RawMergeInterruptionSetting()];
    alert.accessoryView = scroll;
    [alert addButtonWithTitle:@"好"];
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
}

- (NSPopUpButton *)settingsPopupWithValues:(NSArray<NSNumber *> *)values current:(double)current suffix:(NSString *)suffix {
    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 150, 28) pullsDown:NO];
    NSInteger selected = 0;
    double bestDelta = DBL_MAX;
    for (NSInteger i = 0; i < values.count; i++) {
        NSNumber *value = values[i];
        NSString *title = value.doubleValue <= 0 ? @"关闭" : [NSString stringWithFormat:@"%.0f %@", value.doubleValue, suffix ?: @""];
        [popup addItemWithTitle:title];
        popup.itemArray.lastObject.representedObject = value;
        double delta = fabs(value.doubleValue - current);
        if (delta < bestDelta) {
            bestDelta = delta;
            selected = i;
        }
    }
    [popup selectItemAtIndex:selected];
    return popup;
}

- (NSTextField *)settingsLabel:(NSString *)text {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont systemFontOfSize:13];
    label.textColor = [NSColor labelColor];
    label.frame = NSMakeRect(0, 0, 120, 24);
    return label;
}

- (void)openSettings:(id)sender {
    NSMutableDictionary<NSString *, NSPopUpButton *> *popups = [NSMutableDictionary dictionary];
    NSTimeInterval previousRawMergeSeconds = RawMergeInterruptionSetting();
    double previousAutoCalendarHour = AutoCalendarWriteHourSetting();
    NSDate *summaryDate = [self dashboardDate];
    NSDictionary *durationDistribution = SegmentDurationDistribution(ReadRawSegmentsIncludingShort([self.store rawURLForDate:summaryDate]));
    NSArray *rows = @[
        @{@"label": @"idle 判定", @"key": SettingIdleSecondsKey, @"values": @[@60, @120, @300], @"suffix": @"秒"},
        @{@"label": @"原始切换合并", @"key": SettingRawMergeInterruptionSecondsKey, @"values": @[@0, @1, @2, @3, @5], @"suffix": @"秒"},
        @{@"label": @"短打断吸收", @"key": SettingShortInterruptionSecondsKey, @"values": @[@15, @30, @60], @"suffix": @"秒"},
        @{@"label": @"日历聚合窗口", @"key": SettingCalendarWindowMinutesKey, @"values": @[@3, @5, @10], @"suffix": @"分钟"},
        @{@"label": @"最小写入块", @"key": SettingCalendarMinBlockMinutesKey, @"values": @[@3, @5, @10], @"suffix": @"分钟"},
        @{@"label": @"自动写入日历", @"key": SettingAutoCalendarWriteHourKey, @"values": @[@-1, @22, @23], @"suffix": @"点后"}
    ];

    NSStackView *stack = [[NSStackView alloc] initWithFrame:NSMakeRect(0, 0, 330, 292)];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.spacing = 10;
    stack.alignment = NSLayoutAttributeLeading;

    for (NSDictionary *row in rows) {
        NSStackView *line = [[NSStackView alloc] initWithFrame:NSMakeRect(0, 0, 330, 28)];
        line.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        line.spacing = 12;
        NSTextField *label = [self settingsLabel:row[@"label"]];
        NSPopUpButton *popup = [self settingsPopupWithValues:row[@"values"]
                                                     current:SettingDouble(row[@"key"], [row[@"values"][0] doubleValue])
                                                      suffix:row[@"suffix"]];
        [line addArrangedSubview:label];
        [line addArrangedSubview:popup];
        [stack addArrangedSubview:line];
        popups[row[@"key"]] = popup;
    }

    NSString *settingsSummary = [NSString stringWithFormat:@"%@\n%@", DurationDistributionSettingsSummary(summaryDate, durationDistribution), AutoCalendarWriteSummary()];
    NSTextField *summary = [NSTextField wrappingLabelWithString:settingsSummary];
    summary.font = [NSFont systemFontOfSize:11];
    summary.textColor = [NSColor secondaryLabelColor];
    summary.frame = NSMakeRect(0, 0, 320, 48);
    [stack addArrangedSubview:summary];

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"记录规则设置";
    alert.informativeText = @"自动写入默认关闭；打开后，Gotowork 运行时会在设定时间后每天写入一次当天未确认的新时段。";
    alert.accessoryView = stack;
    [alert addButtonWithTitle:@"保存"];
    [alert addButtonWithTitle:@"取消"];
    if ([alert runModal] != NSAlertFirstButtonReturn) {
        return;
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    for (NSString *key in popups) {
        NSNumber *value = popups[key].selectedItem.representedObject;
        [defaults setDouble:value.doubleValue forKey:key];
    }
    [defaults synchronize];
    self.tracker.idleThreshold = IdleThresholdSetting();
    if (AutoCalendarWriteHourSetting() != previousAutoCalendarHour) {
        [defaults removeObjectForKey:AutoCalendarLastRunDayKey];
        [defaults synchronize];
    }
    [self scheduleAutoCalendarWriteTimer];
    NSTimeInterval currentRawMergeSeconds = RawMergeInterruptionSetting();
    BOOL compactedToday = NO;
    if (currentRawMergeSeconds > previousRawMergeSeconds && currentRawMergeSeconds > 0) {
        NSError *compactError = nil;
        compactedToday = [self.store compactRawURLForDate:[NSDate date] error:&compactError];
        if (!compactedToday && compactError) {
            NSLog(@"compact raw after settings failed: %@", compactError.localizedDescription);
        }
    }
    [self updateStatus:compactedToday ? @"设置已更新，今天已整理" : @"设置已更新"];
    if (AutoCalendarWriteEnabled()) {
        [self requestCalendarAccessWithCompletion:^(BOOL granted, NSError *error) {
            if (!granted) {
                [self showAlertWithTitle:@"自动写入需要日历权限"
                                 message:error.localizedDescription ?: @"请允许 Gotowork 完整访问日历，才能自动写入并跳过重复事件。"];
            }
        }];
    }
    if (self.popover.isShown) {
        [self refreshDashboard];
    }
}

- (NSString *)calendarPopupTitleForCalendar:(EKCalendar *)calendar {
    NSString *source = calendar.source.title ?: @"";
    if (source.length == 0) {
        return calendar.title ?: @"未命名日历";
    }
    return [NSString stringWithFormat:@"%@ · %@", calendar.title ?: @"未命名日历", source];
}

- (void)presentCalendarSettings {
    NSString *currentIdentifier = [self targetCalendarIdentifier];
    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 360, 28) pullsDown:NO];
    [popup addItemWithTitle:[NSString stringWithFormat:@"使用或新建“%@”", TrackerCalendarTitle]];
    popup.itemArray.lastObject.representedObject = @"";
    NSInteger selectedIndex = 0;

    for (EKCalendar *calendar in [self writableEventCalendars]) {
        NSString *identifier = calendar.calendarIdentifier ?: @"";
        if (identifier.length == 0) {
            continue;
        }
        [popup addItemWithTitle:[self calendarPopupTitleForCalendar:calendar]];
        popup.itemArray.lastObject.representedObject = identifier;
        if (currentIdentifier.length > 0 && [identifier isEqualToString:currentIdentifier]) {
            selectedIndex = popup.numberOfItems - 1;
        }
    }
    [popup selectItemAtIndex:selectedIndex];

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"写入日历";
    alert.informativeText = @"默认会使用或创建“前台记录”日历；也可以选择一个已有可写日历。重复检测只会检查当前选中的写入日历。";
    alert.accessoryView = popup;
    [alert addButtonWithTitle:@"保存"];
    [alert addButtonWithTitle:@"取消"];
    [NSApp activateIgnoringOtherApps:YES];
    if ([alert runModal] != NSAlertFirstButtonReturn) {
        return;
    }

    NSString *identifier = popup.selectedItem.representedObject;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (identifier.length > 0) {
        [defaults setObject:identifier forKey:TargetCalendarIdentifierKey];
    } else {
        [defaults removeObjectForKey:TargetCalendarIdentifierKey];
    }
    [defaults synchronize];
    [self updateStatus:[NSString stringWithFormat:@"写入日历：%@", [self targetCalendarDisplayTitle]]];
    [self refreshDashboard];
}

- (void)openCalendarSettings:(id)sender {
    [self requestCalendarAccessWithCompletion:^(BOOL granted, NSError *error) {
        if (!granted) {
            [self showAlertWithTitle:@"没拿到日历权限"
                             message:error.localizedDescription ?: @"需要完整日历访问权限，才能选择已有日历并检查重复写入。"];
            return;
        }
        [self presentCalendarSettings];
    }];
}

- (NSArray<NSDictionary *> *)appWriteMappingRows {
    NSDate *dashboardDate = [self dashboardDate];
    BOOL selectedIsToday = SameDay(dashboardDate, [NSDate date]);
    NSArray *segments = ReadSegmentsForRange(self.store,
                                             dashboardDate,
                                             DateByAddingDays(dashboardDate, 1),
                                             selectedIsToday ? [self.tracker currentDashboardSegment] : nil);
    NSArray *residentSegments = ReadResidentSegmentsForRange(self.store,
                                                             dashboardDate,
                                                             DateByAddingDays(dashboardDate, 1),
                                                             selectedIsToday ? [self.tracker currentResidentMeetingSegment] : nil);
    NSDictionary *summary = AppSummaryFromSegments([segments arrayByAddingObjectsFromArray:residentSegments]);
    NSArray *topApps = summary[@"top_apps"] ?: @[];
    NSDictionary *existingMappings = [self appWriteMappingsByAppKey];
    NSMutableDictionary<NSString *, NSMutableDictionary *> *rowsByKey = [NSMutableDictionary dictionary];

    for (NSDictionary *app in topApps) {
        NSString *key = app[@"key"];
        if (key.length == 0 || [key hasPrefix:@"__"]) {
            continue;
        }
        rowsByKey[key] = [@{
            @"key": key,
            @"title": app[@"title"] ?: key,
            @"bundle_id": app[@"bundle_id"] ?: @"",
            @"seconds": app[@"seconds"] ?: @0,
            @"suggested_filter_reason": SuggestedAppFilterReason(key, app[@"title"] ?: key, app[@"bundle_id"] ?: @"")
        } mutableCopy];
    }

    for (NSString *key in existingMappings) {
        if (key.length == 0) {
            continue;
        }
        NSDictionary *mapping = existingMappings[key];
        NSString *title = [mapping isKindOfClass:NSDictionary.class] && [mapping[@"event_title"] length] > 0 ? mapping[@"event_title"] : key;
        if (!rowsByKey[key]) {
            rowsByKey[key] = [@{
                @"key": key,
                @"title": title,
                @"bundle_id": @"",
                @"seconds": @0
            } mutableCopy];
        }
    }

    NSArray *rows = [rowsByKey.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        BOOL leftMapped = existingMappings[a[@"key"]] != nil;
        BOOL rightMapped = existingMappings[b[@"key"]] != nil;
        if (leftMapped != rightMapped) {
            return leftMapped ? NSOrderedAscending : NSOrderedDescending;
        }
        return [b[@"seconds"] compare:a[@"seconds"]];
    }];
    return rows.count > 12 ? [rows subarrayWithRange:NSMakeRange(0, 12)] : rows;
}

- (NSTextField *)mappingTextFieldWithPlaceholder:(NSString *)placeholder value:(NSString *)value width:(CGFloat)width {
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, width, 24)];
    field.font = [NSFont systemFontOfSize:12];
    field.bezelStyle = NSTextFieldRoundedBezel;
    field.placeholderString = placeholder ?: @"";
    field.stringValue = value ?: @"";
    return field;
}

- (NSArray<NSDictionary *> *)appFilterRows {
    return AppFilterRowsForDate(self.store,
                                [self dashboardDate],
                                [self ignoredAppKeys],
                                [self appWriteMappingsByAppKey]);
}

- (void)openAppFilters:(id)sender {
    NSArray<NSDictionary *> *apps = [self appFilterRows];
    if (apps.count == 0) {
        [self showAlertWithTitle:@"还没有可过滤的应用"
                         message:@"Gotowork 需要先记录到一些前台应用，才会在这里显示应用过滤。"];
        return;
    }

    __weak AppDelegate *weakSelf = self;
    self.appFilterSettingsController = [[AppFilterSettingsController alloc] initWithRows:apps
                                                                             ignoredKeys:[self ignoredAppKeys]
                                                                             saveHandler:^(NSSet<NSString *> *ignoredKeys, BOOL appliedSuggestions) {
        AppDelegate *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        [[NSUserDefaults standardUserDefaults] setObject:ignoredKeys.allObjects forKey:IgnoredAppKeysKey];
        [[NSUserDefaults standardUserDefaults] synchronize];
        [strongSelf updateStatus:appliedSuggestions ? @"已应用建议过滤" : @"应用过滤已更新"];
        [strongSelf refreshDashboard];
    }];
    [NSApp activateIgnoringOtherApps:YES];
    [self.appFilterSettingsController.window center];
    [self.appFilterSettingsController showWindow:nil];
    [self.appFilterSettingsController.window makeKeyAndOrderFront:nil];
}

- (void)openAppWriteMappings:(id)sender {
    NSArray<NSDictionary *> *apps = [self appWriteMappingRows];
    NSMutableDictionary *existingMappings = [[self appWriteMappingsByAppKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    if (apps.count == 0) {
        [self showAlertWithTitle:@"还没有可配置的应用"
                         message:@"Gotowork 需要先记录到一些前台应用，才会在这里显示应用写入映射。"];
        return;
    }

    NSMutableArray<NSDictionary *> *controls = [NSMutableArray array];
    CGFloat rowHeight = 74.0;
    CGFloat documentHeight = MAX(92.0, apps.count * rowHeight + 16.0);
    NSView *document = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 540, documentHeight)];
    NSStackView *stack = [[NSStackView alloc] initWithFrame:NSMakeRect(10, 8, 520, documentHeight - 16)];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.spacing = 10;
    stack.alignment = NSLayoutAttributeLeading;

    for (NSDictionary *app in apps) {
        NSString *key = app[@"key"] ?: @"";
        NSString *title = app[@"title"] ?: key;
        NSDictionary *mapping = existingMappings[key];
        NSString *mappedTitle = [mapping isKindOfClass:NSDictionary.class] ? mapping[@"event_title"] : @"";
        NSString *mappedProject = [mapping isKindOfClass:NSDictionary.class] ? mapping[@"project_title"] : @"";

        NSStackView *row = [[NSStackView alloc] initWithFrame:NSMakeRect(0, 0, 520, 64)];
        row.orientation = NSUserInterfaceLayoutOrientationVertical;
        row.spacing = 5;

        NSString *labelText = [NSString stringWithFormat:@"%@  %@", title, key];
        NSTextField *label = [NSTextField labelWithString:labelText];
        label.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
        label.textColor = [NSColor secondaryLabelColor];
        label.lineBreakMode = NSLineBreakByTruncatingMiddle;
        label.frame = NSMakeRect(0, 0, 520, 16);

        NSStackView *fields = [[NSStackView alloc] initWithFrame:NSMakeRect(0, 0, 520, 26)];
        fields.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        fields.spacing = 8;
        NSTextField *titleField = [self mappingTextFieldWithPlaceholder:title value:mappedTitle width:250];
        NSTextField *projectField = [self mappingTextFieldWithPlaceholder:@"项目标签（可选）" value:mappedProject width:250];
        [fields addArrangedSubview:titleField];
        [fields addArrangedSubview:projectField];

        [row addArrangedSubview:label];
        [row addArrangedSubview:fields];
        [stack addArrangedSubview:row];
        [controls addObject:@{@"key": key, @"title": titleField, @"project": projectField}];
    }

    [document addSubview:stack];
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 560, 330)];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    scroll.documentView = document;

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"应用写入映射";
    alert.informativeText = @"按应用设置默认日历标题和项目标签。单个时段手动编辑会优先于这里的默认映射；留空则使用原应用名或清除映射。";
    alert.accessoryView = scroll;
    [alert addButtonWithTitle:@"保存"];
    [alert addButtonWithTitle:@"取消"];
    [NSApp activateIgnoringOtherApps:YES];
    if ([alert runModal] != NSAlertFirstButtonReturn) {
        return;
    }

    for (NSDictionary *row in controls) {
        NSString *key = row[@"key"];
        NSTextField *titleField = row[@"title"];
        NSTextField *projectField = row[@"project"];
        NSString *mappedTitle = TrimmedUserText(titleField.stringValue);
        NSString *mappedProject = TrimmedUserText(projectField.stringValue);
        if (mappedTitle.length == 0 && mappedProject.length == 0) {
            [existingMappings removeObjectForKey:key];
            continue;
        }
        NSMutableDictionary *mapping = [NSMutableDictionary dictionary];
        if (mappedTitle.length > 0) {
            mapping[@"event_title"] = mappedTitle;
        }
        if (mappedProject.length > 0) {
            mapping[@"project_title"] = mappedProject;
        }
        existingMappings[key] = mapping;
    }

    [[NSUserDefaults standardUserDefaults] setObject:existingMappings forKey:AppWriteMappingsByKeyKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self updateStatus:@"应用写入映射已更新"];
    [self refreshDashboard];
}

- (NSArray *)previewCalendarBlocks:(NSArray *)candidates {
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    NSStackView *stack = [[NSStackView alloc] initWithFrame:NSMakeRect(0, 0, 360, 1)];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.spacing = 8;
    stack.alignment = NSLayoutAttributeLeading;

    for (NSDictionary *block in candidates) {
        NSStackView *row = [[NSStackView alloc] initWithFrame:NSMakeRect(0, 0, 340, 56)];
        row.orientation = NSUserInterfaceLayoutOrientationVertical;
        row.spacing = 4;

        NSString *summary = [NSString stringWithFormat:@"%@-%@  %@  %@",
                             [ClockString(block[@"start"]) substringToIndex:5],
                             [ClockString(block[@"end"]) substringToIndex:5],
                             block[@"title"] ?: @"未知",
                             ShortDuration([block[@"wall_seconds"] doubleValue])];
        NSButton *check = [NSButton checkboxWithTitle:summary target:nil action:nil];
        check.state = NSControlStateValueOn;
        check.font = [NSFont systemFontOfSize:12];

        NSTextField *titleField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 330, 24)];
        titleField.stringValue = CalendarEventTitleForBlock(block);
        titleField.font = [NSFont systemFontOfSize:12];
        titleField.bezelStyle = NSTextFieldRoundedBezel;

        [row addArrangedSubview:check];
        [row addArrangedSubview:titleField];
        [stack addArrangedSubview:row];
        [rows addObject:@{@"block": block, @"check": check, @"title": titleField}];
    }

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 370, 280)];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    NSView *document = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 350, MAX(60, candidates.count * 68))];
    stack.frame = NSMakeRect(10, 8, 340, MAX(40, candidates.count * 64));
    [document addSubview:stack];
    scroll.documentView = document;

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"确认写入日历";
    alert.informativeText = [NSString stringWithFormat:@"将写入到“%@”日历。可取消某条，也可以改标题。", [self targetCalendarDisplayTitle]];
    alert.accessoryView = scroll;
    [alert addButtonWithTitle:@"写入"];
    [alert addButtonWithTitle:@"取消"];
    if ([alert runModal] != NSAlertFirstButtonReturn) {
        return nil;
    }

    NSMutableArray *selected = [NSMutableArray array];
    for (NSDictionary *row in rows) {
        NSButton *check = row[@"check"];
        if (check.state != NSControlStateValueOn) {
            continue;
        }
        NSTextField *field = row[@"title"];
        NSMutableDictionary *block = [row[@"block"] mutableCopy];
        if (field.stringValue.length > 0) {
            block[@"event_title"] = field.stringValue;
        }
        [selected addObject:block];
    }
    return selected;
}

- (void)createManualDashboardBlock:(id)sender {
    DashboardView *view = [sender isKindOfClass:DashboardView.class] ? sender : self.dashboardController.dashboardView;
    NSDictionary *block = [view respondsToSelector:@selector(pendingManualCreationBlock)] ? [view pendingManualCreationBlock] : nil;
    NSDate *start = block[@"start"];
    NSDate *end = block[@"end"];
    if (!start || !end || [end timeIntervalSinceDate:start] < 180.0) {
        [self updateStatus:@"手动时段至少 3 分钟"];
        return;
    }

    NSString *title = [view respondsToSelector:@selector(pendingManualCreationTitle)] ? [view pendingManualCreationTitle] : @"手动时段";
    NSMutableArray *records = [[self manualCalendarBlockRecords] mutableCopy] ?: [NSMutableArray array];
    [records addObject:@{
        @"id": [NSUUID UUID].UUIDString,
        @"start_at": [ISOFormatter() stringFromDate:start],
        @"end_at": [ISOFormatter() stringFromDate:end],
        @"title": title
    }];
    [[NSUserDefaults standardUserDefaults] setObject:records forKey:ManualCalendarBlocksKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self updateStatus:[NSString stringWithFormat:@"已创建手动时段：%@", title]];
    [self refreshDashboard];
}

- (void)writeDashboardPendingBlocksToCalendar:(id)sender {
    NSDate *dashboardDate = [self dashboardDate];
    NSArray *candidates = [self pendingCalendarCandidatesForDay:dashboardDate checkpointReason:@"calendar-export"];
    if (candidates.count == 0) {
        [self updateStatus:@"没有新的日历块"];
        [self showAlertWithTitle:@"没有新的日历块"
                          message:@"这一天满足规则的时间块已经写入过或已忽略，不会重复写入。"];
        [self refreshDashboard];
        return;
    }

    [self updateStatus:@"准备写入待确认时段"];
    [self requestCalendarAccessWithCompletion:^(BOOL granted, NSError *error) {
        if (!granted) {
            NSString *message = error.localizedDescription ?: @"需要给 Foreground Tracker 日历完整访问权限，才能创建专用日历并避免重复写入。";
            [self updateStatus:@"日历权限未授权"];
            [self showAlertWithTitle:@"没拿到日历权限" message:message];
            return;
        }

        NSError *writeError = nil;
        NSDictionary *result = [self writeCalendarBlocks:candidates day:dashboardDate error:&writeError];
        if (!result) {
            [self updateStatus:@"写入日历失败"];
            [self showAlertWithTitle:@"写入日历失败" message:writeError.localizedDescription ?: @"未知错误"];
            return;
        }

        NSInteger written = [result[@"written"] integerValue];
        NSInteger skipped = [result[@"skipped"] integerValue];
        NSString *status = skipped > 0
            ? [NSString stringWithFormat:@"已写入 %ld 条，跳过 %ld 条", (long)written, (long)skipped]
            : [NSString stringWithFormat:@"已写入 %ld 条日历", (long)written];
        [self updateStatus:status];
        [self refreshDashboard];
        [self flashWrittenBlockKeys:result[@"written_keys"]];
    }];
}

- (void)writeTodayCalendar:(id)sender {
    NSDate *dashboardDate = [self dashboardDate];
    if (SameDay(dashboardDate, [NSDate date])) {
        [self.tracker checkpointWithReason:@"calendar-export"];
    }
    BOOL selectedIsToday = SameDay(dashboardDate, [NSDate date]);
    NSArray *segments = ReadSegmentsForRange(self.store, dashboardDate, DateByAddingDays(dashboardDate, 1), selectedIsToday ? [self.tracker currentDashboardSegment] : nil);
    NSArray *residentSegments = ReadResidentSegmentsForRange(self.store, dashboardDate, DateByAddingDays(dashboardDate, 1), selectedIsToday ? [self.tracker currentResidentMeetingSegment] : nil);
    NSSet<NSString *> *existingKeys = [self existingCalendarBlockKeysForDay:dashboardDate];
    NSSet<NSString *> *ignoredKeys = [self ignoredCalendarBlockKeys];
    NSArray *candidates = CalendarCandidatesWithState(CalendarCandidatesIncludingManual(segments, residentSegments, [self manualCalendarBlockRecords], dashboardDate),
                                                      existingKeys,
                                                      ignoredKeys,
                                                      [self appWriteMappingsByAppKey],
                                                      [self projectLabelsByBlockKey],
                                                      [self blockTitlesByBlockKey]);
    if (candidates.count == 0) {
        [self updateStatus:@"没有可写入日历的时间块"];
        [self showAlertWithTitle:@"这一天还没有可写入日历的时间块"
                          message:CalendarRuleSummary()];
        [self refreshDashboard];
        return;
    }

    candidates = PendingCalendarCandidates(candidates, existingKeys, ignoredKeys);
    if (candidates.count == 0) {
        [self updateStatus:@"没有新的日历块"];
        [self showAlertWithTitle:@"没有新的日历块"
                          message:@"这一天满足规则的时间块已经写入过或已忽略，不会重复写入。"];
        [self refreshDashboard];
        return;
    }

    NSArray *selectedCandidates = [self previewCalendarBlocks:candidates];
    if (!selectedCandidates) {
        [self updateStatus:@"已取消写入日历"];
        return;
    }
    if (selectedCandidates.count == 0) {
        [self updateStatus:@"没有选择日历块"];
        [self showAlertWithTitle:@"没有选择要写入的时间块" message:@"预览列表里至少保留一条勾选项才会写入。"];
        return;
    }

    selectedCandidates = PendingCalendarCandidates(selectedCandidates,
                                                   [self existingCalendarBlockKeysForDay:dashboardDate],
                                                   [self ignoredCalendarBlockKeys]);
    if (selectedCandidates.count == 0) {
        [self updateStatus:@"选择的日历块都已存在"];
        [self showAlertWithTitle:@"没有新的日历块"
                          message:@"刚才选择的时间块已经在“前台记录”日历里了，不会重复写入。"];
        [self refreshDashboard];
        return;
    }

    [self updateStatus:@"准备写入日历"];
    [self requestCalendarAccessWithCompletion:^(BOOL granted, NSError *error) {
        if (!granted) {
            NSString *message = error.localizedDescription ?: @"需要给 Foreground Tracker 日历完整访问权限，才能创建专用日历并避免重复写入。";
            [self updateStatus:@"日历权限未授权"];
            [self showAlertWithTitle:@"没拿到日历权限" message:message];
            return;
        }

        NSError *writeError = nil;
        NSDictionary *result = [self writeCalendarBlocks:selectedCandidates day:dashboardDate error:&writeError];
        if (!result) {
            [self updateStatus:@"写入日历失败"];
            [self showAlertWithTitle:@"写入日历失败" message:writeError.localizedDescription ?: @"未知错误"];
            return;
        }

        NSInteger written = [result[@"written"] integerValue];
        NSInteger skipped = [result[@"skipped"] integerValue];
        NSString *status = skipped > 0
            ? [NSString stringWithFormat:@"已写入 %ld 条，跳过 %ld 条", (long)written, (long)skipped]
            : [NSString stringWithFormat:@"已写入 %ld 条日历", (long)written];
        [self updateStatus:status];
        [self refreshDashboard];
        [self flashWrittenBlockKeys:result[@"written_keys"]];
    }];
}

- (void)writeSelectedDashboardBlockToCalendar:(id)sender {
    NSDictionary *block = [self selectedDashboardBlock];
    if (![self blockIsCalendarCandidate:block]) {
        [self showAlertWithTitle:@"这段还不能单独写入" message:@"请选择时间轴里的日历候选块。"];
        return;
    }
    if ([block[@"calendar_confirmed"] boolValue]) {
        [self updateStatus:@"此段已写入日历"];
        [self refreshDashboard];
        return;
    }

    [self requestCalendarAccessWithCompletion:^(BOOL granted, NSError *error) {
        if (!granted) {
            [self showAlertWithTitle:@"没拿到日历权限" message:error.localizedDescription ?: @"需要完整日历访问权限。"];
            return;
        }

        NSError *writeError = nil;
        NSDictionary *result = [self writeCalendarBlocks:@[block] day:block[@"start"] ?: [NSDate date] error:&writeError];
        if (!result) {
            [self showAlertWithTitle:@"写入日历失败" message:writeError.localizedDescription ?: @"未知错误"];
            return;
        }
        NSInteger written = [result[@"written"] integerValue];
        NSInteger skipped = [result[@"skipped"] integerValue];
        if (written == 0 && skipped > 0) {
            [self updateStatus:@"此段已存在，未重复写入"];
            [self refreshDashboard];
            return;
        }
        [self updateStatus:[NSString stringWithFormat:@"此段写入 %ld 条，跳过 %ld 条", (long)written, (long)skipped]];
        [self refreshDashboard];
        [self flashWrittenBlockKeys:result[@"written_keys"]];
    }];
}

- (void)ignoreSelectedDashboardBlock:(id)sender {
    NSDictionary *block = [self selectedDashboardBlock];
    if (![self blockIsCalendarCandidate:block]) {
        [self showAlertWithTitle:@"不能忽略这段" message:@"请选择时间轴里的日历候选块。"];
        return;
    }
    NSString *key = CalendarBlockKeyForBlock(block);
    NSMutableSet *keys = [[self ignoredCalendarBlockKeys] mutableCopy];
    [keys addObject:key];
    [[NSUserDefaults standardUserDefaults] setObject:keys.allObjects forKey:IgnoredCalendarBlockKeysKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self updateStatus:@"已忽略这个日历候选块"];
    [self refreshDashboard];
}

- (void)renameSelectedDashboardBlock:(id)sender {
    NSDictionary *block = [self selectedDashboardBlock];
    if (![self blockIsCalendarCandidate:block]) {
        [self showAlertWithTitle:@"不能编辑这段" message:@"请选择时间轴里的日历候选块。"];
        return;
    }

    NSString *key = CalendarBlockKeyForBlock(block);
    NSMutableDictionary *titles = [[self blockTitlesByBlockKey] mutableCopy];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"编辑时段标题";
    alert.informativeText = @"这个标题会用于右侧详情和之后写入日历，不会改原始 raw 记录。";
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 280, 24)];
    field.stringValue = titles[key] ?: CalendarEventTitleForBlock(block);
    field.placeholderString = CalendarEventTitleForBlock(block);
    alert.accessoryView = field;
    [alert addButtonWithTitle:@"保存"];
    [alert addButtonWithTitle:@"清除"];
    [alert addButtonWithTitle:@"取消"];
    [NSApp activateIgnoringOtherApps:YES];
    NSModalResponse response = [alert runModal];
    if (response == NSAlertThirdButtonReturn) {
        return;
    }
    if (response == NSAlertSecondButtonReturn || field.stringValue.length == 0) {
        [titles removeObjectForKey:key];
    } else {
        titles[key] = field.stringValue;
    }
    [[NSUserDefaults standardUserDefaults] setObject:titles forKey:BlockTitlesByBlockKeyKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self updateStatus:@"时段标题已更新"];
    [self refreshDashboard];
}

- (void)saveInlineDashboardBlockTitle:(id)sender {
    DashboardView *view = [sender isKindOfClass:DashboardView.class] ? sender : self.dashboardController.dashboardView;
    NSDictionary *block = [view respondsToSelector:@selector(pendingDetailTitleEditBlock)] ? [view pendingDetailTitleEditBlock] : nil;
    if (![self blockIsCalendarCandidate:block]) {
        [self updateStatus:@"不能编辑这段"];
        return;
    }

    NSString *key = CalendarBlockKeyForBlock(block);
    NSString *title = [view respondsToSelector:@selector(pendingDetailTitleEditText)] ? [view pendingDetailTitleEditText] : @"";
    NSMutableDictionary *titles = [[self blockTitlesByBlockKey] mutableCopy];
    if (title.length == 0 || [title isEqualToString:CalendarEventTitleForBlock(block)]) {
        [titles removeObjectForKey:key];
    } else {
        titles[key] = title;
    }
    [[NSUserDefaults standardUserDefaults] setObject:titles forKey:BlockTitlesByBlockKeyKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self updateStatus:@"时段标题已更新"];
    [self refreshDashboard];
}

- (void)markSelectedDashboardBlockAsProject:(id)sender {
    NSDictionary *block = [self selectedDashboardBlock];
    if (![self blockIsCalendarCandidate:block]) {
        [self showAlertWithTitle:@"不能标记这段" message:@"请选择时间轴里的日历候选块。"];
        return;
    }

    NSString *key = CalendarBlockKeyForBlock(block);
    NSMutableDictionary *labels = [[self projectLabelsByBlockKey] mutableCopy];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"标记项目";
    alert.informativeText = @"给这段时间加一个项目标签，会在时间轴左侧显示项目色带。";
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
    field.stringValue = labels[key] ?: @"";
    field.placeholderString = @"例如：Kimi 项目";
    alert.accessoryView = field;
    [alert addButtonWithTitle:@"保存"];
    [alert addButtonWithTitle:@"取消"];
    [NSApp activateIgnoringOtherApps:YES];
    if ([alert runModal] != NSAlertFirstButtonReturn) {
        return;
    }
    if (field.stringValue.length > 0) {
        labels[key] = field.stringValue;
    } else {
        [labels removeObjectForKey:key];
    }
    [[NSUserDefaults standardUserDefaults] setObject:labels forKey:ProjectLabelsByBlockKeyKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self updateStatus:@"项目标签已更新"];
    [self refreshDashboard];
}

- (void)saveInlineDashboardBlockProject:(id)sender {
    DashboardView *view = [sender isKindOfClass:DashboardView.class] ? sender : self.dashboardController.dashboardView;
    NSDictionary *block = [view respondsToSelector:@selector(pendingDetailProjectEditBlock)] ? [view pendingDetailProjectEditBlock] : nil;
    if (![self blockIsCalendarCandidate:block]) {
        [self updateStatus:@"不能标记这段"];
        return;
    }

    NSString *key = CalendarBlockKeyForBlock(block);
    NSString *project = [view respondsToSelector:@selector(pendingDetailProjectEditText)] ? [view pendingDetailProjectEditText] : @"";
    NSMutableDictionary *labels = [[self projectLabelsByBlockKey] mutableCopy];
    if (project.length > 0) {
        labels[key] = project;
    } else {
        [labels removeObjectForKey:key];
    }
    [[NSUserDefaults standardUserDefaults] setObject:labels forKey:ProjectLabelsByBlockKeyKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self updateStatus:@"项目标签已更新"];
    [self refreshDashboard];
}

- (void)requestCalendarAccessWithCompletion:(void (^)(BOOL granted, NSError *error))completion {
    EKAuthorizationStatus status = [EKEventStore authorizationStatusForEntityType:EKEntityTypeEvent];
    if (CalendarStatusAllowsFullAccess(status)) {
        completion(YES, nil);
        return;
    }

    if (status == EKAuthorizationStatusDenied || status == EKAuthorizationStatusRestricted) {
        NSError *error = [NSError errorWithDomain:@"ForegroundTracker"
                                             code:10
                                         userInfo:@{NSLocalizedDescriptionKey: @"系统设置里还没有允许 Foreground Tracker 访问日历。"}];
        completion(NO, error);
        return;
    }

    if ((NSInteger)status == 4) {
        NSError *error = [NSError errorWithDomain:@"ForegroundTracker"
                                             code:11
                                         userInfo:@{NSLocalizedDescriptionKey: @"当前像是只有日历写入权限；这个功能需要完整访问权限读取已有事件，才能跳过已经写过的记录。"}];
        completion(NO, error);
        return;
    }

    if (@available(macOS 14.0, *)) {
        [self.eventStore requestFullAccessToEventsWithCompletion:^(BOOL granted, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(granted, error);
            });
        }];
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [self.eventStore requestAccessToEntityType:EKEntityTypeEvent completion:^(BOOL granted, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(granted, error);
            });
        }];
#pragma clang diagnostic pop
    }
}

- (NSArray<EKSource *> *)calendarCandidateSources {
    NSMutableArray<EKSource *> *sources = [NSMutableArray array];
    EKCalendar *defaultCalendar = self.eventStore.defaultCalendarForNewEvents;
    if (defaultCalendar.source) {
        [sources addObject:defaultCalendar.source];
    }
    for (EKSource *source in self.eventStore.sources) {
        if ([sources containsObject:source]) {
            continue;
        }
        if (source.sourceType == EKSourceTypeLocal ||
            source.sourceType == EKSourceTypeCalDAV ||
            source.sourceType == EKSourceTypeExchange ||
            source.sourceType == EKSourceTypeMobileMe) {
            [sources addObject:source];
        }
    }
    return sources;
}

- (EKCalendar *)trackerCalendarWithError:(NSError **)error {
    NSString *selectedIdentifier = [self targetCalendarIdentifier];
    if (selectedIdentifier.length > 0) {
        EKCalendar *selected = [self selectedExistingCalendar];
        if (selected) {
            return selected;
        }
        if (error) {
            *error = [NSError errorWithDomain:@"ForegroundTracker"
                                         code:13
                                     userInfo:@{NSLocalizedDescriptionKey: @"选中的写入日历不存在或不可写，请在“写入日历”里重新选择。"}];
        }
        return nil;
    }

    for (EKCalendar *calendar in [self.eventStore calendarsForEntityType:EKEntityTypeEvent]) {
        if ([calendar.title isEqualToString:TrackerCalendarTitle]) {
            return calendar;
        }
    }

    NSError *lastError = nil;
    for (EKSource *source in [self calendarCandidateSources]) {
        EKCalendar *calendar = [EKCalendar calendarForEntityType:EKEntityTypeEvent eventStore:self.eventStore];
        calendar.title = TrackerCalendarTitle;
        calendar.source = source;
        if ([self.eventStore saveCalendar:calendar commit:YES error:&lastError]) {
            return calendar;
        }
    }

    if (error) {
        *error = lastError ?: [NSError errorWithDomain:@"ForegroundTracker"
                                                  code:12
                                              userInfo:@{NSLocalizedDescriptionKey: @"没有找到能创建新日历的账户。"}];
    }
    return nil;
}

- (NSDictionary *)writeCalendarBlocks:(NSArray *)blocks day:(NSDate *)day error:(NSError **)error {
    EKCalendar *calendar = [self trackerCalendarWithError:error];
    if (!calendar) {
        return nil;
    }

    NSDate *dayStart = StartOfDay(day);
    NSDate *dayEnd = [dayStart dateByAddingTimeInterval:24 * 60 * 60];
    NSPredicate *predicate = [self.eventStore predicateForEventsWithStartDate:dayStart endDate:dayEnd calendars:@[calendar]];
    NSArray<EKEvent *> *events = [self.eventStore eventsMatchingPredicate:predicate];
    NSMutableSet<NSString *> *existingKeys = [NSMutableSet set];
    for (EKEvent *event in events) {
        NSString *key = GeneratedBlockKeyFromNotes(event.notes);
        if (key.length == 0 && [event.notes containsString:GeneratedEventMarkerPrefix]) {
            key = CalendarBlockKeyForDates(event.startDate, event.endDate);
        }
        if (key.length > 0) {
            [existingKeys addObject:key];
        }
    }

    NSInteger written = 0;
    NSInteger skipped = 0;
    NSMutableArray<NSString *> *writtenKeys = [NSMutableArray array];
    for (NSDictionary *block in blocks) {
        NSString *key = CalendarBlockKeyForBlock(block);
        if (key.length > 0 && [existingKeys containsObject:key]) {
            skipped++;
            continue;
        }
        EKEvent *event = [EKEvent eventWithEventStore:self.eventStore];
        event.calendar = calendar;
        event.title = CalendarEventTitleForBlock(block);
        event.startDate = block[@"start"];
        event.endDate = block[@"end"];
        event.notes = CalendarNotesForBlock(block);
        event.availability = EKEventAvailabilityBusy;
        if (![self.eventStore saveEvent:event span:EKSpanThisEvent commit:NO error:error]) {
            return nil;
        }
        written++;
        if (key.length > 0) {
            [existingKeys addObject:key];
            [writtenKeys addObject:key];
        }
    }

    if (![self.eventStore commit:error]) {
        return nil;
    }

    return @{@"written": @(written), @"skipped": @(skipped), @"written_keys": writtenKeys};
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = title ?: @"";
        alert.informativeText = message ?: @"";
        [alert addButtonWithTitle:@"好"];
        [NSApp activateIgnoringOtherApps:YES];
        [alert runModal];
    });
}

- (void)requestPermission:(id)sender {
    RequestAccessibilityIfNeeded();
}

- (void)quit:(id)sender {
    [self.tracker stopWithReason:@"quit"];
    [NSApp terminate:nil];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.tracker stopWithReason:@"app-terminate"];
}
@end

static NSURL *DefaultApplicationSupportDirectory(void) {
    NSURL *base = [[NSFileManager defaultManager] URLForDirectory:NSApplicationSupportDirectory
                                                         inDomain:NSUserDomainMask
                                                appropriateForURL:nil
                                                           create:YES
                                                            error:nil];
    return [base URLByAppendingPathComponent:@"Gotowork" isDirectory:YES];
}

static NSDate *DateOnDayFromClockText(NSDate *day, NSString *clockText) {
    NSArray<NSString *> *parts = [clockText componentsSeparatedByString:@":"];
    if (parts.count < 2) {
        return nil;
    }
    NSInteger hour = parts[0].integerValue;
    NSInteger minute = parts[1].integerValue;
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
        return nil;
    }

    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDateComponents *components = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate:day ?: [NSDate date]];
    components.hour = hour;
    components.minute = minute;
    components.second = 0;
    return [calendar dateFromComponents:components];
}

static NSDictionary *FirstCalendarPreviewBlock(NSArray *visualBlocks) {
    for (NSDictionary *block in visualBlocks ?: @[]) {
        if ([block[@"visual_layer"] isEqualToString:@"calendar"] &&
            ![block[@"kind"] isEqualToString:@"gap"]) {
            return block;
        }
    }
    return nil;
}

static NSDictionary *FirstActivityPreviewBlock(NSArray *visualBlocks) {
    for (NSDictionary *block in visualBlocks ?: @[]) {
        if ([block[@"visual_layer"] isEqualToString:@"activity"] &&
            ![block[@"kind"] isEqualToString:@"gap"]) {
            return block;
        }
    }
    return nil;
}

static void PreviewSetCalendarConfirmedInBlocks(NSArray *blocks, NSString *calendarKey) {
    if (calendarKey.length == 0) {
        return;
    }
    for (id block in blocks ?: @[]) {
        if (![block isKindOfClass:NSMutableDictionary.class]) {
            continue;
        }
        NSMutableDictionary *mutableBlock = block;
        NSString *key = CalendarBlockKeyForBlock(mutableBlock);
        if ([key isEqualToString:calendarKey]) {
            mutableBlock[@"calendar_confirmed"] = @YES;
        }
    }
}

static NSDictionary *StatsByPreviewConfirmingFirstCalendar(NSDictionary *stats, NSString **confirmedKeyOut) {
    NSDictionary *firstCalendar = FirstCalendarPreviewBlock(stats[@"visual_blocks"]);
    NSString *calendarKey = CalendarBlockKeyForBlock(firstCalendar);
    if (calendarKey.length == 0) {
        return stats;
    }

    PreviewSetCalendarConfirmedInBlocks(stats[@"visual_blocks"], calendarKey);
    PreviewSetCalendarConfirmedInBlocks(stats[@"candidates"], calendarKey);

    NSInteger pendingCount = 0;
    NSInteger confirmedCount = 0;
    for (NSDictionary *candidate in stats[@"candidates"] ?: @[]) {
        if ([candidate[@"calendar_confirmed"] boolValue]) {
            confirmedCount++;
        } else {
            pendingCount++;
        }
    }

    NSMutableDictionary *mutableStats = [stats mutableCopy];
    mutableStats[@"pending_candidate_count"] = @(pendingCount);
    mutableStats[@"confirmed_candidate_count"] = @(confirmedCount);
    if (confirmedKeyOut) {
        *confirmedKeyOut = calendarKey;
    }
    return mutableStats;
}

static int RenderDashboardPreviewIfRequested(int argc, const char *argv[]) {
    NSString *outputPath = nil;
    NSString *dateString = nil;
    NSString *highlightAppKey = nil;
    NSString *manualDraftSpec = nil;
    NSString *previewNowClock = nil;
    NSMutableSet<NSString *> *temporaryIgnoredAppKeys = [NSMutableSet set];
    CGFloat previewWidth = 1160.0;
    CGFloat previewHeight = 760.0;
    BOOL compactRaw = NO;
    BOOL dark = NO;
    BOOL dumpBlocks = NO;
    BOOL dumpAppFilterRows = NO;
    BOOL dumpDurationDistribution = NO;
    BOOL selectFirstCalendar = NO;
    BOOL hoverFirstCalendar = NO;
    BOOL selectFirstActivity = NO;
    BOOL hoverFirstActivity = NO;
    BOOL showPending = NO;
    BOOL showManualCreation = NO;
    BOOL showDetailTitleEdit = NO;
    BOOL showDetailProjectEdit = NO;
    BOOL confirmFirstCalendar = NO;
    BOOL flashFirstCalendar = NO;
    for (int i = 1; i < argc; i++) {
        NSString *arg = [NSString stringWithUTF8String:argv[i]];
        if ([arg isEqualToString:@"--render-dashboard-preview"] && i + 1 < argc) {
            outputPath = [NSString stringWithUTF8String:argv[++i]];
        } else if ([arg isEqualToString:@"--date"] && i + 1 < argc) {
            dateString = [NSString stringWithUTF8String:argv[++i]];
        } else if ([arg isEqualToString:@"--dark"]) {
            dark = YES;
        } else if ([arg isEqualToString:@"--dump-dashboard-blocks"]) {
            dumpBlocks = YES;
        } else if ([arg isEqualToString:@"--dump-app-filter-rows"]) {
            dumpAppFilterRows = YES;
        } else if ([arg isEqualToString:@"--dump-duration-distribution"] ||
                   [arg isEqualToString:@"--dump-segment-duration-distribution"]) {
            dumpDurationDistribution = YES;
        } else if ([arg isEqualToString:@"--compact-raw"]) {
            compactRaw = YES;
        } else if ([arg isEqualToString:@"--highlight-app"] && i + 1 < argc) {
            highlightAppKey = [NSString stringWithUTF8String:argv[++i]];
        } else if ([arg isEqualToString:@"--ignore-app"] && i + 1 < argc) {
            NSString *ignoredKey = [NSString stringWithUTF8String:argv[++i]];
            if (ignoredKey.length > 0) {
                [temporaryIgnoredAppKeys addObject:ignoredKey];
            }
        } else if ([arg isEqualToString:@"--select-first-calendar"]) {
            selectFirstCalendar = YES;
        } else if ([arg isEqualToString:@"--hover-first-calendar"]) {
            hoverFirstCalendar = YES;
        } else if ([arg isEqualToString:@"--select-first-activity"]) {
            selectFirstActivity = YES;
        } else if ([arg isEqualToString:@"--hover-first-activity"]) {
            hoverFirstActivity = YES;
        } else if ([arg isEqualToString:@"--show-pending"]) {
            showPending = YES;
        } else if ([arg isEqualToString:@"--confirm-first-calendar"]) {
            confirmFirstCalendar = YES;
        } else if ([arg isEqualToString:@"--flash-first-calendar"]) {
            flashFirstCalendar = YES;
        } else if ([arg isEqualToString:@"--manual-creation"]) {
            showManualCreation = YES;
        } else if ([arg isEqualToString:@"--edit-detail-title"]) {
            showDetailTitleEdit = YES;
        } else if ([arg isEqualToString:@"--edit-detail-project"]) {
            showDetailProjectEdit = YES;
        } else if ([arg isEqualToString:@"--manual-draft"] && i + 1 < argc) {
            manualDraftSpec = [NSString stringWithUTF8String:argv[++i]];
        } else if ([arg isEqualToString:@"--now"] && i + 1 < argc) {
            previewNowClock = [NSString stringWithUTF8String:argv[++i]];
        } else if ([arg isEqualToString:@"--preview-size"] && i + 1 < argc) {
            NSString *sizeSpec = [NSString stringWithUTF8String:argv[++i]];
            NSArray<NSString *> *parts = [sizeSpec componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"xX"]];
            if (parts.count == 2) {
                CGFloat width = [parts[0] doubleValue];
                CGFloat height = [parts[1] doubleValue];
                if (width > 0 && height > 0) {
                    previewWidth = width;
                    previewHeight = height;
                }
            }
        } else if ([arg isEqualToString:@"--width"] && i + 1 < argc) {
            CGFloat width = [[NSString stringWithUTF8String:argv[++i]] doubleValue];
            if (width > 0) {
                previewWidth = width;
            }
        } else if ([arg isEqualToString:@"--height"] && i + 1 < argc) {
            CGFloat height = [[NSString stringWithUTF8String:argv[++i]] doubleValue];
            if (height > 0) {
                previewHeight = height;
            }
        }
    }
    if (outputPath.length == 0 && !dumpBlocks && !dumpAppFilterRows && !compactRaw && !dumpDurationDistribution) {
        return -1;
    }

    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    NSAppearanceName appearanceName = dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua;
    NSApp.appearance = [NSAppearance appearanceNamed:appearanceName];
    RegisterDefaultSettings();
    TemporaryIgnoredAppKeys = temporaryIgnoredAppKeys.count > 0 ? [temporaryIgnoredAppKeys copy] : nil;

    SegmentStore *store = [[SegmentStore alloc] initWithDataDirectory:DefaultApplicationSupportDirectory()];
    NSDictionary *appWriteMappings = [[NSUserDefaults standardUserDefaults] dictionaryForKey:AppWriteMappingsByKeyKey] ?: @{};
    NSDictionary *projectLabels = [[NSUserDefaults standardUserDefaults] dictionaryForKey:ProjectLabelsByBlockKeyKey] ?: @{};
    NSDictionary *blockTitles = [[NSUserDefaults standardUserDefaults] dictionaryForKey:BlockTitlesByBlockKeyKey] ?: @{};
    NSArray *manualBlocks = [[NSUserDefaults standardUserDefaults] arrayForKey:ManualCalendarBlocksKey] ?: @[];
    NSDate *previewDate = [NSDate date];
    if (dateString.length > 0) {
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd";
        previewDate = [formatter dateFromString:dateString] ?: previewDate;
    }
    if (compactRaw) {
        NSError *compactError = nil;
        if (![store compactRawURLForDate:previewDate error:&compactError]) {
            fprintf(stderr, "failed to compact raw: %s\n", (compactError.localizedDescription ?: @"unknown").UTF8String);
            return 2;
        }
        printf("%s\n", [[store rawURLForDate:previewDate].path UTF8String]);
        return 0;
    }
    if (dumpDurationDistribution) {
        PrintDurationDistribution(previewDate, @"foreground", ReadRawSegmentsIncludingShort([store rawURLForDate:previewDate]));
        NSArray *residentSegments = ReadRawSegmentsIncludingShort([store residentRawURLForDate:previewDate]);
        if (residentSegments.count > 0) {
            PrintDurationDistribution(previewDate, @"resident", residentSegments);
        }
        return 0;
    }
    if (dumpAppFilterRows) {
        PrintAppFilterRows(previewDate, store, IgnoredAppKeysSetting(), appWriteMappings);
        return 0;
    }
    if (previewNowClock.length > 0) {
        DashboardNowOverride = DateOnDayFromClockText(previewDate, previewNowClock);
    }
    NSDictionary *stats = DashboardStats(store,
                                         previewDate,
                                         nil,
                                         nil,
                                         [NSSet set],
                                         [NSSet set],
                                         appWriteMappings,
                                         projectLabels,
                                         blockTitles,
                                         manualBlocks);
    NSString *previewConfirmedKey = nil;
    if (confirmFirstCalendar) {
        stats = StatsByPreviewConfirmingFirstCalendar(stats, &previewConfirmedKey);
    }

    if (dumpBlocks) {
        for (NSDictionary *block in stats[@"visual_blocks"] ?: @[]) {
            NSString *start = [ClockString(block[@"start"]) substringToIndex:5];
            NSString *end = [ClockString(block[@"end"]) substringToIndex:5];
            NSMutableArray<NSString *> *parts = [NSMutableArray array];
            for (NSDictionary *app in block[@"top_apps"] ?: @[]) {
                [parts addObject:[NSString stringWithFormat:@"%@:%.0f%%",
                                  app[@"title"] ?: @"未知",
                                  [app[@"ratio"] doubleValue] * 100.0]];
            }
            printf("%s %s-%s kind=%s layer=%s key=%s title=%s event=%s project=%s mode=%s apps=%s\n",
                   [DayString(block[@"start"]) UTF8String],
                   start.UTF8String,
                   end.UTF8String,
                   [block[@"kind"] ?: @"" UTF8String],
                   [block[@"visual_layer"] ?: @"" UTF8String],
                   [block[@"key"] ?: @"" UTF8String],
                   [block[@"title"] ?: @"" UTF8String],
                   [CalendarEventTitleForBlock(block) UTF8String],
                   [block[@"project_title"] ?: @"" UTF8String],
                   [block[@"mode"] ?: @"" UTF8String],
                   [[parts componentsJoinedByString:@","] UTF8String]);
        }
        return 0;
    }

    previewWidth = MAX(760.0, previewWidth);
    previewHeight = MAX(520.0, previewHeight);
    NSRect frame = NSMakeRect(0, 0, previewWidth, previewHeight);
    DashboardView *view = [[DashboardView alloc] initWithFrame:frame];
    view.stats = stats;
    view.recording = YES;
    view.statusText = @"预览";
    view.pulseStart = [NSDate timeIntervalSinceReferenceDate];
    [view prepareTimelineForPresentation];
    [view autoPositionTimelineIfNeeded];
    if (highlightAppKey.length > 0) {
        view.highlightedAppKey = highlightAppKey;
    }
    NSDictionary *firstCalendar = FirstCalendarPreviewBlock(stats[@"visual_blocks"]);
    if ((selectFirstCalendar || hoverFirstCalendar) && firstCalendar) {
        view.selectedBlock = firstCalendar;
        if (hoverFirstCalendar) {
            view.hoveredBlock = firstCalendar;
        }
    }
    if ((showDetailTitleEdit || showDetailProjectEdit) && firstCalendar) {
        view.selectedBlock = firstCalendar;
        view.hoveredBlock = nil;
        if (showDetailTitleEdit) {
            view.detailTitleEditBlock = firstCalendar;
            [view ensureDetailTitleEditControls];
            view.detailTitleEditField.stringValue = firstCalendar[@"event_title"] ?: CalendarEventTitleForBlock(firstCalendar);
            [view layoutDetailTitleEditControls];
        } else {
            view.detailProjectEditBlock = firstCalendar;
            [view ensureDetailProjectEditControls];
            view.detailProjectEditField.stringValue = firstCalendar[@"project_title"] ?: @"Kimi 项目";
            [view layoutDetailProjectEditControls];
        }
    }
    NSDictionary *firstActivity = FirstActivityPreviewBlock(stats[@"visual_blocks"]);
    if ((selectFirstActivity || hoverFirstActivity) && firstActivity) {
        view.selectedBlock = firstActivity;
        if (hoverFirstActivity) {
            view.hoveredBlock = firstActivity;
        }
    }
    if (showPending) {
        view.pendingPanelVisible = YES;
    }
    if (flashFirstCalendar && firstCalendar) {
        NSString *flashKey = previewConfirmedKey ?: CalendarBlockKeyForBlock(firstCalendar);
        if (flashKey.length > 0) {
            [view flashCalendarBlockKeys:@[flashKey]];
        }
    }
    if (manualDraftSpec.length > 0) {
        NSArray<NSString *> *rangeParts = [manualDraftSpec componentsSeparatedByString:@"-"];
        if (rangeParts.count == 2) {
            NSDate *start = DateOnDayFromClockText(previewDate, rangeParts[0]);
            NSDate *end = DateOnDayFromClockText(previewDate, rangeParts[1]);
            NSDictionary *draft = [view manualDraftBlockFromStart:start end:end];
            if (draft) {
                view.selectedBlock = draft;
                view.hoveredBlock = draft;
                if (showManualCreation) {
                    view.manualCreationBlock = draft;
                    [view ensureManualCreationControls];
                    view.manualCreationTitleField.stringValue = draft[@"event_title"] ?: @"手动时段";
                    [view layoutManualCreationControls];
                } else {
                    view.manualDraftBlock = draft;
                    view.draggingManualBlock = YES;
                    view.manualDragMoved = YES;
                }
            }
        }
    }

    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                  styleMask:NSWindowStyleMaskBorderless
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
    window.contentView = view;
    [window layoutIfNeeded];

    NSBitmapImageRep *rep = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    rep.size = view.bounds.size;
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
    NSData *data = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (![data writeToFile:outputPath atomically:YES]) {
        fprintf(stderr, "failed to write preview: %s\n", outputPath.UTF8String);
        return 2;
    }
    printf("%s\n", outputPath.UTF8String);
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        int previewStatus = RenderDashboardPreviewIfRequested(argc, argv);
        if (previewStatus >= 0) {
            return previewStatus;
        }
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
