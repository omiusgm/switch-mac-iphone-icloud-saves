#import <UIKit/UIKit.h>
#import <AVFAudio/AVFAudio.h>
#import <QuartzCore/CAMetalLayer.h>
#import <GameController/GameController.h>
#include <TargetConditionals.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <math.h>
#include "runtime.h"
#include "dmsh_chain.h"
#import "touch_pad.h"
#if defined(GAME_BOTW160)
#import "BOTWCloud-Swift.h"
#import "BOTWGraphicsSettings.h"
#import "BOTWSheikahEditor.h"
#import <MetalFX/MetalFX.h>
#include "totk_mfx_up.h"
#include "fps_overlay.h"
#include "botw_scene_resolution.h"
#endif

int totk_host_main(int argc, char **argv);
void runtime_ios_attach_layer(CAMetalLayer *layer, UIView *host);
void runtime_ios_sync_drawable(UIView *host);
void runtime_ios_sync_safe_area(UIView *host);
#if defined(GAME_BOTW160)
long runtime_ios_drawable_rows(void);
void runtime_ios_set_drawable_rows(long rows);
int runtime_mfx_recent(void);
static NSString *const graphicsOutputKey = @"BOTWGraphicsOutputRows";
static NSString *const graphicsFormatKey = @"BOTWGraphicsFormat";
static NSString *const graphicsMetalKey = @"BOTWGraphicsMetalFX";
static NSString *const graphicsOverlayKey = @"BOTWGraphicsOverlayMode";
static NSString *const graphicsDockedKey = @"BOTWGraphicsDocked";
static NSString *const graphicsDockedPendingKey = @"BOTWGraphicsDockedPending";
static NSString *const swipeControlsKey = @"BOTWSwipeControls";
static NSString *const graphicsSceneRowsKey = @"BOTWGraphicsSceneRows";
static NSString *const touchCameraSensitivityKey = @"BOTWTouchCameraSensitivityPercent";
static NSString *const floatingCameraStickKey = @"BOTWFloatingCameraStick";
static NSString *const scenePresentedNotification = @"BOTWFirstValidScenePresentation";
static BOOL graphicsDocked, graphicsDockedRecovered;

#if TARGET_OS_IOS
void runtime_ios_note_scene_presented(double presented_time, int interpolated) {
    static _Atomic BOOL sent;
    if (interpolated || !isfinite(presented_time) || presented_time <= 0 || atomic_load_explicit(&sent, memory_order_relaxed))
        return;
    if (atomic_exchange_explicit(&sent, YES, memory_order_relaxed)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:scenePresentedNotification object:nil];
    });
}
#endif

static double strictIntegerValue(id stored) {
    if (![stored isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)stored) == CFBooleanGetTypeID()) return NAN;
    double value = [stored doubleValue];
    return isfinite(value) && trunc(value) == value ? value : NAN;
}

static long validatedSceneRows(id stored) {
    double rows = strictIntegerValue(stored);
    return rows == 360 || rows == 432 || rows == 540 ? (long)rows : 0;
}

static long savedSceneRows(NSUserDefaults *defaults) {
    return validatedSceneRows([defaults objectForKey:graphicsSceneRowsKey]);
}

static BOOL commitScenePreference(NSUserDefaults *defaults, NSString *key, id value) {
    id previous = [defaults objectForKey:key];
    [defaults setObject:value forKey:key];
    // A player may force-quit immediately to apply the next launch's setting.
    if ([defaults synchronize]) return YES;
    if (previous) [defaults setObject:previous forKey:key];
    else [defaults removeObjectForKey:key];
    [defaults synchronize];
    return NO;
}

static BOOL saveSceneRows(NSUserDefaults *defaults, long rows) {
    return commitScenePreference(defaults, graphicsSceneRowsKey, @(rows));
}

static NSString *sceneBootKey(BOOL ipad) {
    return ipad ? @"BOTWGraphicsSceneBoot.iPad" : @"BOTWGraphicsSceneBoot.iPhone";
}

static NSDictionary *sceneBootRecord(NSUserDefaults *defaults, BOOL ipad) {
    id record = [defaults objectForKey:sceneBootKey(ipad)];
    return [record isKindOfClass:NSDictionary.class] ? record : @{};
}

static BOOL saveSceneBootRecord(NSUserDefaults *defaults, BOOL ipad, long confirmed, long pending) {
    return commitScenePreference(defaults, sceneBootKey(ipad), @{@"confirmed": @(confirmed), @"pending": @(pending)});
}

static BOOL stageSceneRows(NSUserDefaults *defaults, BOOL ipad, long rows) {
    NSDictionary *record = sceneBootRecord(defaults, ipad);
    if (validatedSceneRows(record[@"pending"]) == rows) {
        // An explicit retry makes a matching interrupted trial eligible again. Leave
        // the next choice alone unless the old marker has been durably cleared.
        long confirmed = botw_handheld_scene_rows(validatedSceneRows(record[@"confirmed"]), ipad);
        if (!saveSceneBootRecord(defaults, ipad, confirmed, 0)) return NO;
        if (savedSceneRows(defaults) == rows) return YES;
    }
    return saveSceneRows(defaults, rows);
}

typedef struct {
    long rawRows, blockedRows;
    BOOL confirmOnFirstFrame, recovered, commitFailed;
} SceneLaunchChoice;

static SceneLaunchChoice prepareSceneLaunch(NSUserDefaults *defaults, BOOL ipad, BOOL docked) {
    long desired = savedSceneRows(defaults);
    if (docked) return (SceneLaunchChoice){.rawRows = desired};
    NSDictionary *record = sceneBootRecord(defaults, ipad);
    long confirmed = botw_handheld_scene_rows(validatedSceneRows(record[@"confirmed"]), ipad);
    long pending = validatedSceneRows(record[@"pending"]);
    if (pending && pending == desired && pending != confirmed) {
        // Put the working choice back first. If that write fails, retaining the old
        // pending marker makes the next launch choose the safe base again.
        BOOL restored = saveSceneRows(defaults, confirmed);
        BOOL cleared = restored && saveSceneBootRecord(defaults, ipad, confirmed, 0);
        return (SceneLaunchChoice){.rawRows = confirmed, .blockedRows = restored ? 0 : pending,
                                   .recovered = YES, .commitFailed = !cleared};
    }
    if (desired && desired != confirmed) {
        if (saveSceneBootRecord(defaults, ipad, confirmed, desired))
            return (SceneLaunchChoice){.rawRows = desired, .confirmOnFirstFrame = YES};
        return (SceneLaunchChoice){.rawRows = confirmed, .blockedRows = desired, .commitFailed = YES};
    }
    long active = botw_handheld_scene_rows(desired, ipad);
    return (SceneLaunchChoice){.rawRows = desired, .confirmOnFirstFrame = active != confirmed || pending != 0};
}

static BOTWSceneQuality sceneQualityForRows(long rows) {
    if (rows == 360) return BOTWSceneQualityFaster;
    if (rows == 432) return BOTWSceneQualityBalanced;
    return BOTWSceneQualitySharper;
}

static NSInteger savedTouchCameraSensitivity(NSUserDefaults *defaults) {
    double percent = strictIntegerValue([defaults objectForKey:touchCameraSensitivityKey]);
    return percent >= 75 && percent <= 200 ? BOTWTouchCameraSensitivityNormalize((NSInteger)percent)
                                          : BOTWTouchCameraSensitivityDefault;
}

static BOOL savedFloatingCameraStick(NSUserDefaults *defaults) {
    id stored = [defaults objectForKey:floatingCameraStickKey];
    return [stored isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)stored) == CFBooleanGetTypeID()
        ? [stored boolValue] : YES;
}

static BOOL metalFXSupported(void) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    return device && [MTLFXSpatialScalerDescriptor supportsMetal4FX:device];
}

static void setGraphicsMetalFX(BOOL on) {
    mfxup_set(on);
    mfxup_output_set(on);
}
#endif

static char *host_argv[3];
static NSString *g_no_game_data;   // set when there is no RomFS image to play from (didFinishLaunching)
static NSString *g_seed_pack, *g_seed_unpack_to;   // a pushed shader pack to unpack before the game starts (seed_unpack)

/* The startup shaders arrive as one stream cut into 1 GiB parts (<folder>.pack.000, .001, ...; ios/tools/install_device.py
   push_seed): devicectl stops after ~25,000 of the seed's 128,000 files when it copies a folder (2026-10-23). Stream:
   "TOTKPACK1", then per file a little-endian u16 name length, the name, a u64 size and the bytes; a zero name length
   ends it. Unpacked into <folder>.tmp, renamed to <folder> when complete, the parts removed. Returns nil or the reason. */
static NSString *seed_unpack(NSString *base, NSString *dest, void (^progress)(uint64_t done, uint64_t total)) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *parts = [NSMutableArray array]; uint64_t total = 0;
    for (int i = 0;; i++) {
        NSString *p = [base stringByAppendingFormat:@".%03d", i];
        NSDictionary *a = [fm attributesOfItemAtPath:p error:nil]; if (!a) break;
        [parts addObject:p]; total += a.fileSize;
    }
    if (!parts.count) return @"no pack";
    __block NSUInteger at = 0; __block FILE *f = fopen(parts[0].fileSystemRepresentation, "rb"); __block uint64_t done = 0;
    BOOL (^take)(void *, size_t) = ^BOOL(void *out, size_t n) {   // n bytes of the stream, across part boundaries
        uint8_t *o = out;
        while (n) {
            if (!f) return NO;
            size_t got = fread(o, 1, n, f); o += got; n -= got; done += got;
            if (n) { fclose(f); f = ++at < parts.count ? fopen(parts[at].fileSystemRepresentation, "rb") : NULL; }
        }
        return YES;
    };
    NSString *tmp = [dest stringByAppendingString:@".tmp"]; [fm removeItemAtPath:tmp error:nil];
    if (![fm createDirectoryAtPath:tmp withIntermediateDirectories:YES attributes:nil error:nil]) { if (f) fclose(f); return @"cannot make the folder"; }
    char magic[9]; NSString *why = nil; size_t cap = 1 << 20; uint8_t *buf = malloc(cap); uint64_t files = 0, last = 0;
    if (!take(magic, 9) || memcmp(magic, "TOTKPACK1", 9)) why = @"not a shader pack";
    while (!why) {
        uint16_t nl; if (!take(&nl, 2)) { why = @"truncated"; break; }
        if (!nl) break;
        char name[256]; uint64_t size;
        if (nl >= sizeof name || !take(name, nl)) { why = @"bad name"; break; }
        name[nl] = 0;
        if (strchr(name, '/') || !strcmp(name, ".") || !strcmp(name, "..") || !take(&size, 8)) { why = @"bad entry"; break; }
        FILE *o = fopen([tmp stringByAppendingPathComponent:@(name)].fileSystemRepresentation, "wb"); if (!o) { why = @"cannot write"; break; }
        while (size && !why) { size_t n = size < cap ? (size_t)size : cap; if (!take(buf, n) || fwrite(buf, 1, n, o) != n) why = @"truncated or disk full"; size -= n; }
        fclose(o); files++;
        if (progress && done - last > (32u << 20)) { last = done; progress(done, total); }
    }
    free(buf); if (f) fclose(f);
    if (why) { [fm removeItemAtPath:tmp error:nil]; return why; }
    [fm removeItemAtPath:dest error:nil];
    if (![fm moveItemAtPath:tmp toPath:dest error:nil]) return @"cannot rename";
    for (NSString *p in parts) [fm removeItemAtPath:p error:nil];
    fprintf(stderr, "[totk] shader pack unpacked: %llu files, %.0f MB\n", (unsigned long long)files, total / 1048576.0);
    return nil;
}
static void *run_host(void *unused) { (void)unused; return (void *)(intptr_t)totk_host_main(3, host_argv); }
/* The desktop keyboard-overlay shortcut has no counterpart on iOS. */
void runtime_shortcut_help_toggle(void) {}

@interface TOTKMetalView : UIView @end
@implementation TOTKMetalView
+ (Class)layerClass { return CAMetalLayer.class; }
#if TARGET_OS_VISION
- (void)layoutSubviews { [super layoutSubviews]; runtime_ios_sync_drawable(self); }
#endif
- (void)safeAreaInsetsDidChange { [super safeAreaInsetsDidChange]; runtime_ios_sync_safe_area(self); }   // the HUD boxes keep out of the notch
@end

#if defined(GAME_BOTW160)
@interface TOTKSheikahEditorController : UIViewController
@end
@implementation TOTKSheikahEditorController
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
@end

@interface TOTKGameController : UIViewController <BOTWGraphicsSettingsDelegate, UIPopoverPresentationControllerDelegate>
#else
@interface TOTKGameController : UIViewController
#endif
@property(nonatomic,strong) TOTKMetalView *gameView;
#if defined(GAME_BOTW160)
@property(nonatomic,strong) TOTKTouchPad *touchPad;
@property(nonatomic,strong) UIButton *graphicsButton;
@property(nonatomic,strong) UIButton *extraControlsButton;
@property(nonatomic) BOOL graphicsOpen;
@property(nonatomic) BOOL openingSheikahEditor;
@property(nonatomic,strong) BOTWSheikahEditor *sheikahEditor;
@property(nonatomic,copy) NSDictionary<NSNumber *, UIImage *> *sheikahEditorIcons;
@property(nonatomic) CGSize lastTouchSize;
@property(nonatomic) long sceneRowsAtLaunch;
@property(nonatomic) SceneLaunchChoice sceneLaunchChoice;
#endif
@end
@implementation TOTKGameController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
#if defined(GAME_BOTW160)
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSNumber *rows = [defaults objectForKey:graphicsOutputKey];
    if ([rows isKindOfClass:NSNumber.class]) runtime_ios_set_drawable_rows(rows.longValue);
    NSNumber *format = [defaults objectForKey:graphicsFormatKey];
    if ([format isKindOfClass:NSNumber.class] && format.integerValue >= BOTWPictureAutomatic &&
        format.integerValue <= BOTWPictureFill) runtime_ios_set_picture_format((BOTWPictureFormat)format.integerValue);
#endif
    self.gameView = [[TOTKMetalView alloc] initWithFrame:self.view.bounds];
    self.gameView.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
#if TARGET_OS_VISION
    // Keep gamepad actions in GameController instead of visionOS converting them to pinch events.
    GCEventInteraction *controllerInput = [GCEventInteraction new];
    controllerInput.handledEventTypes = GCUIEventTypeGamepad;
    [self.gameView addInteraction:controllerInput];
#endif
    [self.view addSubview:self.gameView];
    runtime_ios_attach_layer((CAMetalLayer *)self.gameView.layer, self.gameView);
    TOTKTouchPad *pad = [[TOTKTouchPad alloc] initWithFrame:self.view.bounds];
    pad.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:pad];
#if defined(GAME_BOTW160)
    self.touchPad = pad;
    self.touchPad.swipeLayout = self.supportsSwipeControls && [defaults boolForKey:swipeControlsKey];
    if (self.supportsTouchCamera) {
        self.touchPad.touchCameraSensitivity = savedTouchCameraSensitivity(defaults);
        self.touchPad.floatingCameraStick = self.supportsSwipeControls && savedFloatingCameraStick(defaults);
    }
    self.touchPad.sheikahOverrides = BOTWSheikahLoadLayout(defaults);
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.tintColor = UIColor.whiteColor;
    button.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.75];
    button.layer.cornerRadius = 22;
    [button setImage:[UIImage systemImageNamed:@"gearshape"
        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightMedium]]
        forState:UIControlStateNormal];
    button.accessibilityLabel = self.supportsTouchCamera ? @"Настройки" : @"Настройки графики";
    button.hidden = YES;
    [button addTarget:self action:@selector(openGraphicsSettings) forControlEvents:UIControlEventTouchUpInside];
    self.graphicsButton = button;
    [self.view addSubview:button];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [button.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [button.topAnchor constraintEqualToAnchor:safe.topAnchor constant:BOTWSheikahSettingsTop],
        [button.widthAnchor constraintEqualToConstant:BOTWSheikahSettingsSize],
        [button.heightAnchor constraintEqualToConstant:BOTWSheikahSettingsSize]
    ]];
    if (self.supportsSwipeControls) {
        UIButton *extra = [UIButton buttonWithType:UIButtonTypeSystem];
        extra.translatesAutoresizingMaskIntoConstraints = NO;
        extra.tintColor = button.tintColor;
        extra.layer.cornerRadius = 22;
        [extra setImage:[UIImage systemImageNamed:@"ellipsis"
            withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightMedium]]
            forState:UIControlStateNormal];
        [extra addTarget:self action:@selector(toggleExtraControls) forControlEvents:UIControlEventTouchUpInside];
        self.extraControlsButton = extra;
        [self.view addSubview:extra];
        [NSLayoutConstraint activateConstraints:@[
            [extra.leadingAnchor constraintEqualToAnchor:button.trailingAnchor constant:6],
            [extra.topAnchor constraintEqualToAnchor:button.topAnchor],
            [extra.widthAnchor constraintEqualToAnchor:button.widthAnchor],
            [extra.heightAnchor constraintEqualToAnchor:button.heightAnchor]
        ]];
        [self updateExtraControlsButton];
    }
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(firstPresentedFrame:)
                                              name:@"BOTWFirstPresentedFrame" object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(firstValidScenePresentation:)
                                              name:scenePresentedNotification object:nil];
#endif
}
#if defined(GAME_BOTW160)
- (BOOL)supportsSwipeControls {
    return TARGET_OS_IOS && self.traitCollection.userInterfaceIdiom == UIUserInterfaceIdiomPhone;
}

- (BOOL)supportsTouchCamera {
    return TARGET_OS_IOS && (self.traitCollection.userInterfaceIdiom == UIUserInterfaceIdiomPhone ||
                             self.traitCollection.userInterfaceIdiom == UIUserInterfaceIdiomPad);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    runtime_ios_sync_drawable(self.gameView);
    CGSize size = self.touchPad.bounds.size;
    if (!CGSizeEqualToSize(size, self.lastTouchSize)) {
        self.lastTouchSize = size;
        [self.touchPad releaseTouches];
    }
}

- (void)firstPresentedFrame:(NSNotification *)notification {
    self.graphicsButton.hidden = self.sheikahEditor != nil;
    [self updateExtraControlsButton];
    if (graphicsDocked) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:graphicsDockedPendingKey];
        [NSUserDefaults.standardUserDefaults synchronize];
    }
}

- (void)firstValidScenePresentation:(NSNotification *)notification {
    (void)notification;
    SceneLaunchChoice choice = self.sceneLaunchChoice;
    if (choice.confirmOnFirstFrame) {
        BOOL ipad = self.traitCollection.userInterfaceIdiom == UIUserInterfaceIdiomPad;
        BOOL confirmed = saveSceneBootRecord(NSUserDefaults.standardUserDefaults, ipad, self.sceneRowsAtLaunch, 0);
        choice.confirmOnFirstFrame = !confirmed;
        choice.commitFailed = !confirmed;
        self.sceneLaunchChoice = choice;
    }
}

- (void)updateExtraControlsButton {
    BOOL sheikah = self.supportsSwipeControls && self.touchPad.swipeLayout;
    UIImage *art = sheikah ? [TOTKTouchPad sheikahSettingsArtwork] :
        [UIImage systemImageNamed:@"gearshape"
            withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightMedium]];
    [self.graphicsButton setImage:art forState:UIControlStateNormal];
    self.graphicsButton.backgroundColor = sheikah ? UIColor.clearColor : [UIColor colorWithWhite:0.08 alpha:0.75];
    // Every game control is available in the Sheikah layout; no separate overflow is needed.
    self.extraControlsButton.hidden = YES;
}

- (void)toggleExtraControls {
    if (!self.touchPad.swipeLayout || self.graphicsOpen) return;
    self.touchPad.extraControls = !self.touchPad.extraControls;
    [self updateExtraControlsButton];
}

- (void)openGraphicsSettings {
    if (self.graphicsOpen || self.presentedViewController || !self.view.window) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    BOTWGraphicsSettings *settings = [BOTWGraphicsSettings new];
    settings.delegate = self;
    settings.outputRows = runtime_ios_drawable_rows();
    settings.sceneQualitySupported = self.supportsTouchCamera;
    if (settings.sceneQualitySupported) {
        BOOL ipad = self.traitCollection.userInterfaceIdiom == UIUserInterfaceIdiomPad;
        SceneLaunchChoice choice = self.sceneLaunchChoice;
        long nextRows = savedSceneRows(defaults);
        if (choice.blockedRows && nextRows == choice.blockedRows) nextRows = self.sceneRowsAtLaunch;
        settings.sceneQualityCurrent = sceneQualityForRows(self.sceneRowsAtLaunch);
        settings.sceneQualityNext = sceneQualityForRows(botw_handheld_scene_rows(nextRows, ipad));
        settings.sceneQualityRecovered = choice.recovered;
        settings.sceneQualityCommitFailed = choice.commitFailed;
    }
    settings.touchCameraSupported = self.supportsTouchCamera;
    settings.touchCameraSensitivity = self.touchPad.touchCameraSensitivity;
    settings.floatingCameraSupported = self.supportsSwipeControls;
    settings.floatingCameraStick = self.touchPad.floatingCameraStick;
    int format = runtime_ios_picture_format();
    settings.format = format < 0 ? BOTWPictureAutomatic : (BOTWPictureFormat)format;
    settings.metalFXSupported = metalFXSupported();
    settings.metalFX = settings.metalFXSupported && mfxup_enabled();
    settings.overlayMode = fps_overlay_hud_mode();
    settings.overlayForcedOff = !fps_overlay_enabled();
    settings.dockedCurrent = graphicsDocked;
    settings.dockedNext = [defaults boolForKey:graphicsDockedKey];
    settings.dockedRecovered = graphicsDockedRecovered;
    settings.showsTouchSettings = self.supportsSwipeControls;
    settings.swipeControls = self.touchPad.swipeLayout;

    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:settings];
    navigation.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    navigation.view.backgroundColor = BOTWGraphicsPanelBackground();
    UINavigationBarAppearance *appearance = [UINavigationBarAppearance new];
    [appearance configureWithOpaqueBackground];
    appearance.backgroundColor = BOTWGraphicsPanelBackground();
    appearance.titleTextAttributes = @{NSForegroundColorAttributeName: UIColor.whiteColor};
    navigation.navigationBar.tintColor = [UIColor colorWithRed:0.65 green:0.82 blue:1 alpha:1];
    navigation.navigationBar.standardAppearance = appearance;
    navigation.navigationBar.scrollEdgeAppearance = appearance;
    navigation.navigationBar.compactAppearance = appearance;
    navigation.modalPresentationStyle = UIModalPresentationPopover;
    CGSize safeSize = self.view.safeAreaLayoutGuide.layoutFrame.size;
    BOOL phone = self.traitCollection.userInterfaceIdiom == UIUserInterfaceIdiomPhone;
    navigation.preferredContentSize = CGSizeMake(MIN(phone ? 700 : 450, safeSize.width - 32),
                                                 MIN(phone ? 520 : 620, safeSize.height - 64));
    UIPopoverPresentationController *popover = navigation.popoverPresentationController;
    popover.sourceView = self.graphicsButton;
    popover.sourceRect = self.graphicsButton.bounds;
    popover.permittedArrowDirections = UIPopoverArrowDirectionUp;
#if !TARGET_OS_VISION
    popover.backgroundColor = BOTWGraphicsPanelBackground();
#endif
    popover.delegate = self;

    self.graphicsOpen = YES;
    runtime_input_set_menu_open(1);
    self.sheikahEditorIcons = [self.touchPad sheikahEditorIcons];
    [self.touchPad releaseTouches];
    self.touchPad.userInteractionEnabled = NO;
    [self updateExtraControlsButton];
    [self presentViewController:navigation animated:YES completion:^{
        navigation.presentationController.delegate = self;
    }];
}

- (void)graphicsSetMetalFX:(BOOL)on {
    setGraphicsMetalFX(on);
    [NSUserDefaults.standardUserDefaults setBool:on forKey:graphicsMetalKey];
}

- (void)graphicsSetOutputRows:(long)rows {
    runtime_ios_set_drawable_rows(rows);
    [NSUserDefaults.standardUserDefaults setInteger:rows forKey:graphicsOutputKey];
    runtime_ios_sync_drawable(self.gameView);
}

- (BOOL)graphicsSetSceneQualityForNextLaunch:(BOTWSceneQuality)quality {
    if (!self.supportsTouchCamera) return NO;
    long rows;
    switch (quality) {
    case BOTWSceneQualityFaster: rows = 360; break;
    case BOTWSceneQualityBalanced: rows = 432; break;
    case BOTWSceneQualitySharper: rows = 540; break;
    default: return NO;
    }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    BOOL ipad = self.traitCollection.userInterfaceIdiom == UIUserInterfaceIdiomPad;
    SceneLaunchChoice choice = self.sceneLaunchChoice;
    long pending = validatedSceneRows(sceneBootRecord(defaults, ipad)[@"pending"]);
    // The old boot overlay event can make Settings available before a valid
    // drawable. Re-selecting this live trial must keep its recovery marker.
    BOOL currentTrial = choice.confirmOnFirstFrame && !choice.commitFailed &&
        pending == rows && self.sceneRowsAtLaunch == rows;
    BOOL saved = currentTrial ? saveSceneRows(defaults, rows) : stageSceneRows(defaults, ipad, rows);
    if (!saved) return NO;
    choice.blockedRows = 0;
    // A successful selection clears a previous save/recovery warning. Keep an
    // unresolved confirmation for the current live trial if its marker remains.
    choice.commitFailed = choice.commitFailed && choice.confirmOnFirstFrame &&
        validatedSceneRows(sceneBootRecord(defaults, ipad)[@"pending"]) == self.sceneRowsAtLaunch;
    self.sceneLaunchChoice = choice;
    return YES;
}

- (BOOL)graphicsSceneQualitySaveWarning {
    return self.sceneLaunchChoice.commitFailed;
}

- (void)settingsSetTouchCameraSensitivity:(NSInteger)percent {
    if (!self.supportsTouchCamera || BOTWTouchCameraSensitivityNormalize(percent) != percent) return;
    self.touchPad.touchCameraSensitivity = percent;
    [NSUserDefaults.standardUserDefaults setInteger:percent forKey:touchCameraSensitivityKey];
}

- (void)settingsSetFloatingCameraStick:(BOOL)enabled {
    if (!self.supportsSwipeControls) return;
    self.touchPad.floatingCameraStick = enabled;
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:floatingCameraStickKey];
}

- (void)graphicsSetFormat:(BOTWPictureFormat)format {
    runtime_ios_set_picture_format(format);
    [NSUserDefaults.standardUserDefaults setInteger:format forKey:graphicsFormatKey];
}

- (void)graphicsSetDocked:(BOOL)docked {
    [NSUserDefaults.standardUserDefaults setBool:docked forKey:graphicsDockedKey];
}

- (void)settingsSetSwipeControls:(BOOL)enabled {
    if (!self.supportsSwipeControls || self.touchPad.swipeLayout == enabled) return;
    self.touchPad.extraControls = NO;
    self.touchPad.swipeLayout = enabled;
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:swipeControlsKey];
    [self updateExtraControlsButton];
}

- (void)settingsEditSheikahLayout {
    UIViewController *menu = self.presentedViewController;
    if (!self.graphicsOpen || !self.touchPad.swipeLayout || !menu || self.openingSheikahEditor || self.sheikahEditor) return;
    self.openingSheikahEditor = YES;
    // Keep the existing native menu input gate closed throughout the UIKit dismissal.
    [menu dismissViewControllerAnimated:NO completion:^{
        self.openingSheikahEditor = NO;
        if (!self.view.window) { [self graphicsDidDismiss]; return; }
        self.touchPad.hidden = YES;
        self.graphicsButton.hidden = YES;
        NSDictionary<NSNumber *, UIImage *> *icons = self.sheikahEditorIcons;
        __weak typeof(self) weakSelf = self;
        BOTWSheikahEditor *editor = [[BOTWSheikahEditor alloc] initWithFrame:self.view.bounds
            overrides:self.touchPad.sheikahOverrides
            icon:^UIImage *(BOTWSheikahControl control) { return icons[@(control)]; }
            completion:^(BOTWSheikahOverrides *saved) { [weakSelf finishSheikahEditor:saved]; }];
        self.sheikahEditor = editor;
        // iCloud already defers resume alerts while a native controller is presented.
        TOTKSheikahEditorController *screen = [TOTKSheikahEditorController new];
        screen.view = editor;
        screen.modalPresentationStyle = UIModalPresentationOverFullScreen;
        screen.modalInPresentation = YES;
        [self presentViewController:screen animated:NO completion:^{
            [self setNeedsUpdateOfSupportedInterfaceOrientations];
            [screen setNeedsUpdateOfSupportedInterfaceOrientations];
            UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, nil);
        }];
    }];
}

- (void)finishSheikahEditor:(BOTWSheikahOverrides *)saved {
    if (!self.sheikahEditor) return;
    if (saved) {
        if (!BOTWSheikahSaveLayout(NSUserDefaults.standardUserDefaults, saved)) {
            [self.sheikahEditor showSaveFailure];
            return;
        }
        self.touchPad.sheikahOverrides = saved;
    }
    [self dismissViewControllerAnimated:NO completion:^{
#if TARGET_OS_IOS
        runtime_gamepad_block_until_release();
#endif
        self.sheikahEditor = nil;
        self.touchPad.hidden = NO;
        self.graphicsButton.hidden = NO;
        [self graphicsDidDismiss];
        UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, self.graphicsButton);
    }];
}

- (BOOL)graphicsSetOverlayMode:(int)mode {
    if (!fps_overlay_enabled() || !fps_overlay_set_hud_mode(mode)) return NO;
    [NSUserDefaults.standardUserDefaults setInteger:mode forKey:graphicsOverlayKey];
    return YES;
}

- (NSInteger)graphicsDisplayedFPS {
    return fps_overlay_displayed_value(CACurrentMediaTime());
}

- (NSString *)graphicsMetalStatus {
    if (!mfxup_enabled()) return @"Меняется сразу. MetalFX меняет алгоритм масштабирования, когда это позволяет размер изображения.";
    if (runtime_mfx_recent()) return @"Масштабирование MetalFX применялось в последних кадрах.";
    return @"Включено. Применяется, когда размер кадра и видеоустройство позволяют масштабирование.";
}

- (void)graphicsDidDismiss {
    if (self.openingSheikahEditor || self.sheikahEditor) return;
    if (self.graphicsOpen) {
        self.sheikahEditorIcons = nil;
        self.graphicsOpen = NO;
        [self.touchPad releaseTouches];
        self.touchPad.userInteractionEnabled = YES;
        runtime_input_set_menu_open(0);
        [self updateExtraControlsButton];
    }
    if (!self.presentedViewController) [BOTWCloudController completeDeferredResume];
}

- (void)graphicsSettingsClosed {
    UIViewController *menu = self.presentedViewController;
    if (menu) {
        [menu dismissViewControllerAnimated:YES completion:^{ [self graphicsDidDismiss]; }];
    } else {
        [self graphicsDidDismiss];
    }
}

- (void)graphicsSettingsDidDismiss {
    [self graphicsDidDismiss];
}

- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    [self graphicsDidDismiss];
}

- (UIModalPresentationStyle)adaptivePresentationStyleForPresentationController:(UIPresentationController *)controller
                                                               traitCollection:(UITraitCollection *)traits {
    return UIModalPresentationNone;
}
#endif

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    static BOOL started; if (started) return; started = YES;
    /* What happens before the game starts is said on the boot screen (runtime/frontend_ios.m), not on a label of its own:
       one laid over it showed both texts on top of each other (2026-10-23). */
    BOOL zh = [NSLocale.preferredLanguages.firstObject hasPrefix:@"zh"];   // the same rule as the boot screen (totk_ui_lang.h)
    if (g_no_game_data) {
        runtime_boot_status(zh ? "无法开始游戏" : "Cannot start the game", g_no_game_data.UTF8String);
        return;
    }
    if (g_seed_pack) {   // shaders installed as a pack: unpack once, on screen, then start (not on the main thread: a long launch is killed)
        static const char *stage_zh = "正在准备着色器（更新后只做一次）", *stage_en = "Preparing the shaders (once after an update)";
        const char *stage = zh ? stage_zh : stage_en;
        runtime_boot_progress(stage, 0, 0);
        NSString *pack = g_seed_pack, *to = g_seed_unpack_to; g_seed_pack = nil;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
            NSString *why = seed_unpack(pack, to, ^(uint64_t done, uint64_t total) { runtime_boot_progress(stage, done, total); });
            fprintf(stderr, "[totk] shader pack: %s in %.1f s\n", why ? why.UTF8String : "ready", CFAbsoluteTimeGetCurrent() - t0);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (why) { runtime_boot_status(zh ? "着色器准备失败" : "Could not prepare the shaders", (zh
                               ? [NSString stringWithFormat:@"%@。请在 Mac 上用 ios/tools/install_device.py 重新安装。", why]
                               : [NSString stringWithFormat:@"%@. Install again from the Mac with ios/tools/install_device.py.", why]).UTF8String); return; }
                [self startGame];
            });
        });
        return;
    }
    [self startGame];
}
- (void)startGame {
#if defined(GAME_BOTW160)
    NSString *profile = [NSString stringWithUTF8String:getenv("TOTK_PROFILE_DIR")];
    [BOTWCloudController prepareWithPresenter:self profile:profile completion:^{ [self startNativeGame]; }];
#else
    [self startNativeGame];
#endif
}
- (void)startNativeGame {
#if defined(GAME_BOTW160)
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    id savedOverlay = [defaults objectForKey:graphicsOverlayKey];
    if ([savedOverlay isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)savedOverlay) != CFBooleanGetTypeID()) {
        NSNumber *value = savedOverlay;
        int mode = value.intValue;
        if ([value isEqualToNumber:@(mode)]) fps_overlay_set_hud_mode(mode);
    }
    NSNumber *metal = [defaults objectForKey:graphicsMetalKey];
    if ([metal isKindOfClass:NSNumber.class]) setGraphicsMetalFX(metal.boolValue && metalFXSupported());
    else { (void)mfxup_enabled(); (void)mfxup_output_enabled(); }
    if (graphicsDocked) {
        [defaults setBool:YES forKey:graphicsDockedPendingKey];
        [defaults synchronize];
    }
#endif
    /* Playback category (PR #97): plays with the ring / silent switch off and routes to the speaker. Without an active
       session the game's CoreAudio output stays on a null sink on iOS 27 ("no device sink in use"); activating it in
       didFinishLaunching blocked the main thread before the log file was opened. Interruptions: audio_observe. */
    AVAudioSession *audio = AVAudioSession.sharedInstance;
    NSError *catErr = nil, *actErr = nil;
    [audio setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:0 error:&catErr];
    BOOL activated = [audio setActive:YES error:&actErr];
    fprintf(stderr, "[totk-audio] audio session category=%s active=%d route=%s err=%s%s\n",
            audio.category.UTF8String ?: "?", (int)activated, audio.currentRoute.outputs.firstObject.portType.UTF8String ?: "?",
            catErr ? catErr.localizedDescription.UTF8String : "none", actErr ? actErr.localizedDescription.UTF8String : "");
#if defined(GAME_BOTW160) && TARGET_OS_IOS
    if (self.supportsTouchCamera) {
        BOOL ipad = self.traitCollection.userInterfaceIdiom == UIUserInterfaceIdiomPad;
        SceneLaunchChoice choice = prepareSceneLaunch(NSUserDefaults.standardUserDefaults, ipad, graphicsDocked);
        self.sceneLaunchChoice = choice;
        long rows = choice.rawRows;
        self.sceneRowsAtLaunch = botw_handheld_scene_rows(rows, ipad);
        runtime_ios_set_boot_scene_rows(rows, ipad);
    }
#endif
    pthread_attr_t attr; pthread_attr_init(&attr); pthread_attr_setstacksize(&attr, 64u << 20);
    pthread_t thread; pthread_create(&thread, &attr, run_host, NULL);
    pthread_detach(thread); pthread_attr_destroy(&attr);
}
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
@end

/* iOS 27 ends apps linked against its SDK that keep the window in the app delegate (UIKit traps in
   _UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption at launch), so the window belongs to a window scene. */
@interface TOTKSceneDelegate : UIResponder <UIWindowSceneDelegate> @property(nonatomic,strong) UIWindow *window; @end
@implementation TOTKSceneDelegate
#if defined(GAME_BOTW160) && TARGET_OS_IOS
- (void)windowScene:(UIWindowScene *)windowScene didUpdateEffectiveGeometry:(UIWindowSceneGeometry *)previousGeometry {
    if (windowScene.effectiveGeometry.interfaceOrientation == previousGeometry.interfaceOrientation) return;
    TOTKGameController *game = (TOTKGameController *)self.window.rootViewController;
    [game.touchPad releaseTouches];
}
#endif
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    (void)session; (void)options;
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [TOTKGameController new]; [self.window makeKeyAndVisible];
#if TARGET_OS_VISION
    UIWindowSceneGeometryPreferencesVision *prefs = [[UIWindowSceneGeometryPreferencesVision alloc] initWithSize:CGSizeMake(1280, 720)];
    prefs.resizingRestrictions = UIWindowSceneResizingRestrictionsUniform;
    [(UIWindowScene *)scene requestGeometryUpdateWithPreferences:prefs errorHandler:^(NSError *error) {
        fprintf(stderr, "[totk] 16:9 window refused: %s\n", error.localizedDescription.UTF8String);
    }];
#endif
}
@end

/* Game audio after interruptions (from nxnative b301431). A call, Siri or an alarm takes the audio session and the
   system stops the game's output unit; a media services reset invalidates it. Nothing started it again, so the game
   stayed silent. When an interruption ends the session is made active again and the output started
   (runtime_audio_output_restart); a reset rebuilds the output. Becoming active does the same, for an interruption
   whose "ended" never came. Becoming active also turns the idle timer off again. */
static BOOL g_audio_interrupted;
static void audio_resume(int recreate, const char *why) {
    NSError *err = nil;
    if (![AVAudioSession.sharedInstance setActive:YES error:&err]) fprintf(stderr,"[totk-audio] audio session not active again (%s): %s\n",why,err.localizedDescription.UTF8String);
    g_audio_interrupted = NO; runtime_audio_output_restart(recreate);
}
static void audio_observe(void) {
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter; NSOperationQueue *main = NSOperationQueue.mainQueue;
    [nc addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:main usingBlock:^(NSNotification *n) {
        NSUInteger type = [n.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
        fprintf(stderr,"[totk-audio] audio session interruption %s\n",type == AVAudioSessionInterruptionTypeBegan ? "began" : "ended");
        if (type == AVAudioSessionInterruptionTypeBegan) g_audio_interrupted = YES; else audio_resume(0,"interruption ended");
    }];
    [nc addObserverForName:AVAudioSessionMediaServicesWereResetNotification object:nil queue:main usingBlock:^(NSNotification *n) {
        (void)n; fprintf(stderr,"[totk-audio] media services were reset\n"); audio_resume(1,"media services reset");
    }];
    [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:main usingBlock:^(NSNotification *n) {
        (void)n; UIApplication.sharedApplication.idleTimerDisabled = YES;
        if (g_audio_interrupted) audio_resume(0,"became active during an interruption");
    }];
}

@interface TOTKApp : UIResponder <UIApplicationDelegate> @end
@implementation TOTKApp
- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    (void)application; (void)options;
    UISceneConfiguration *c = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:session.role];
    c.delegateClass = TOTKSceneDelegate.class; return c;
}
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)options;
    // Controller input does not reset the idle timer; auto-lock would suspend the game mid-play or mid shader import.
    application.idleTimerDisabled = YES;
    audio_observe();
    /* The Mac launcher passes the preferred language as TOTK_LOCALE (PR #97); "zh-Hans-CN" maps to zh-Hans in services.c. */
    NSString *preferred = NSLocale.preferredLanguages.firstObject;
    if (preferred.length) setenv("TOTK_LOCALE", preferred.UTF8String, 1);
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    NSString *res = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"GameData"];
    for (NSString *name in @[@"save", @"temp", @"shader-cache", @"game-slot"]) [fm createDirectoryAtPath:[docs stringByAppendingPathComponent:name] withIntermediateDirectories:YES attributes:nil error:nil];
    /* The log is written only with debug on: the Settings app (Settings.bundle › TOTK_DEBUG_LOG) or TOTK_DEBUG_LOG=1 from
       devicectl (it wins over the setting). Off, stderr goes to /dev/null fully buffered, so nothing reaches the phone's
       storage (a line per write had stalled the game in bursts), and an old log.txt is removed. */
    NSString *log = [docs stringByAppendingPathComponent:@"log.txt"];
    const char *debugEnv = getenv("TOTK_DEBUG_LOG");
    BOOL debugLog = debugEnv ? (*debugEnv && strcmp(debugEnv,"0")) : [NSUserDefaults.standardUserDefaults boolForKey:@"TOTK_DEBUG_LOG"];
    if (debugLog) { if (freopen(log.fileSystemRepresentation,"w",stderr)) setvbuf(stderr,NULL,_IOLBF,0); }
    else { [fm removeItemAtPath:log error:nil]; if (freopen("/dev/null","w",stderr)) setvbuf(stderr,NULL,_IOFBF,1<<16); }
    setenv("TOTK_ROMFS",[res stringByAppendingPathComponent:@"romfs"].fileSystemRepresentation,1);
    /* The 17 GB image may live in Documents/GameData instead of the app (romfs.bin or romfs.bin.000, ...; ios/tools/
       install_device.py --game-data puts it there): a new build then installs without it, and reinstalling keeps it.
       Excluded from iCloud backups. The runtime still hashes it once against the build's pin (TOTK_ROMFS_PROOF_DIR). */
    NSString *gameData = [docs stringByAppendingPathComponent:@"GameData"];
    BOOL image = [fm fileExistsAtPath:[gameData stringByAppendingPathComponent:@"romfs.bin"]] ||
                 [fm fileExistsAtPath:[gameData stringByAppendingPathComponent:@"romfs.bin.000"]];
    NSString *mark = [NSString stringWithContentsOfFile:[gameData stringByAppendingPathComponent:@"romfs.sha256"] encoding:NSUTF8StringEncoding error:nil];
    BOOL copying = mark && [mark stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length != 64;   // install_device.py writes the hash last
    if (image && !copying) {
        [[NSURL fileURLWithPath:gameData isDirectory:YES] setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
        setenv("TOTK_ROMFS_DATA",gameData.fileSystemRepresentation,1);
    } else if (![fm fileExistsAtPath:[res stringByAppendingPathComponent:@"romfs/romfs.bin"]]) {
        /* No image to play from: said on the screen instead of the game ending at once (runtime_fail exits). */
        BOOL zh = [NSLocale.preferredLanguages.firstObject hasPrefix:@"zh"];
        NSString *app = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: @"TOTK";   // the Files app's folder name
        g_no_game_data = copying || image
            ? [NSString stringWithFormat:(zh ? @"游戏数据还在复制到“文件 › 我的 iPhone › %@ › GameData”，复制完再打开游戏。"
                                             : @"The game data is still being copied to Files › On My iPhone › %@ › GameData. Open the game again when it is done."), app]
            : [NSString stringWithFormat:(zh ? @"没有游戏数据。请在 Mac 上用 ios/tools/install_device.py --game-data 把它复制到“文件 › 我的 iPhone › %@ › GameData”。"
                                             : @"No game data. On the Mac, copy it to Files › On My iPhone › %@ › GameData with ios/tools/install_device.py --game-data."), app];
        fprintf(stderr, "[totk] no game image: %s\n", g_no_game_data.UTF8String);
    }
    /* The startup shaders likewise (build_app.py --ios-game-data documents): install_device.py puts the seed into its own
       folder in Documents/GameData once per content and writes shader-seed.txt last ("<folder>\n<fingerprint>"), so the app
       carries none and a new build installs in seconds. Read in place like the app's own (totk_shader_seed.h); folders of
       earlier seeds are removed in the background. Without either seed the game has no shaders: said on the screen. */
    NSString *seedDir = [res stringByAppendingPathComponent:@"shader-seed"];
    NSArray<NSString *> *seedMark = [[NSString stringWithContentsOfFile:[gameData stringByAppendingPathComponent:@"shader-seed.txt"] encoding:NSUTF8StringEncoding error:nil] componentsSeparatedByString:@"\n"];
    NSString *pushedName = seedMark.count >= 2 && seedMark[1].length == 64 && [seedMark[0] hasPrefix:@"shader-seed-"] && ![seedMark[0] containsString:@"/"] ? seedMark[0] : nil;
    NSString *pushed = pushedName ? [gameData stringByAppendingPathComponent:pushedName] : nil;
    BOOL packed = pushed && ![fm fileExistsAtPath:[pushed stringByAppendingPathComponent:@"seed-manifest.json"]] &&
                  [fm fileExistsAtPath:[pushed stringByAppendingString:@".pack.000"]];
    if (packed) { g_seed_pack = [pushed stringByAppendingString:@".pack"]; g_seed_unpack_to = pushed; }   // unpacked in viewDidAppear
    if (pushed && (packed || [fm fileExistsAtPath:[pushed stringByAppendingPathComponent:@"seed-manifest.json"]])) {
        seedDir = pushed; setenv("TOTK_SHADER_SEED_PUSHED", pushed.fileSystemRepresentation, 1);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
            NSFileManager *files = [NSFileManager new];
            for (NSString *name in [files contentsOfDirectoryAtPath:gameData error:nil] ?: @[])
                if ([name hasPrefix:@"shader-seed-"] && ![name hasPrefix:pushedName]) [files removeItemAtPath:[gameData stringByAppendingPathComponent:name] error:nil];
        });
    } else if (!g_no_game_data && ![fm fileExistsAtPath:[seedDir stringByAppendingPathComponent:@"seed-manifest.json"]]) {
        BOOL zh = [NSLocale.preferredLanguages.firstObject hasPrefix:@"zh"];
        g_no_game_data = zh ? @"没有着色器。请在 Mac 上用 ios/tools/install_device.py 重新安装（会把着色器复制到手机上）。"
                            : @"No shaders. Install the game again from the Mac with ios/tools/install_device.py (it copies them to the device).";
        fprintf(stderr, "[totk] no shader seed: %s\n", g_no_game_data.UTF8String);
    }
#if TARGET_OS_VISION
    setenv("TOTK_OPERATION_MODE","docked",1);
    setenv("TOTK_IOS_DRAWABLE_H","1080",0);
    setenv("TOTK_RENDER_RES","1600x900",0);   // avoid the iPhone's default 960x540 in 1.4.3
    setenv("TOTK_MFX_UPSCALE","0",0);
    setenv("TOTK_FPS_OVERLAY","0",0);
#else
#if defined(GAME_BOTW160)
    NSUserDefaults *graphicsDefaults = NSUserDefaults.standardUserDefaults;
    graphicsDocked = [graphicsDefaults boolForKey:graphicsDockedKey];
    if ([graphicsDefaults boolForKey:graphicsDockedPendingKey]) {
        graphicsDockedRecovered = graphicsDocked;
        graphicsDocked = NO;
        [graphicsDefaults setBool:NO forKey:graphicsDockedKey];
        [graphicsDefaults removeObjectForKey:graphicsDockedPendingKey];
        [graphicsDefaults synchronize];
    }
    setenv("TOTK_OPERATION_MODE",graphicsDocked ? "docked" : "handheld",1);
#else
    setenv("TOTK_OPERATION_MODE","handheld",1);
#endif
#endif
    // Game language: the Settings app (Settings.bundle › TOTK_LANG) stores the choice in our defaults; empty means the
    // system language, which is what the runtime already follows. iOS 27 does not honour Info.plist LSEnvironment, so
    // the value must be applied here. overwrite=0 keeps devicectl --environment-variables winning when testing from the Mac.
    NSString *lang = [NSUserDefaults.standardUserDefaults stringForKey:@"TOTK_LANG"];
    if (lang.length>0&&lang.length<8) setenv("TOTK_LANG",lang.UTF8String,0);
    setenv("TOTK_ROMFS_PATCHES",[res stringByAppendingPathComponent:@"romfs-patches"].fileSystemRepresentation,1);
    setenv("TOTK_ROMFS_PATCHES_OUT",[res stringByAppendingPathComponent:@"romfs-patches-out"].fileSystemRepresentation,1);
    setenv("TOTK_SHARED_FONTS",[res stringByAppendingPathComponent:@"shared-fonts"].fileSystemRepresentation,1);
    NSString *aoc = [res stringByAppendingPathComponent:@"aoc"];   // Breath of the Wild's add-on content packs (build_ipa.py; runtime/aoc_romfs.c)
    if ([fm fileExistsAtPath:aoc]) setenv("TOTK_AOC",aoc.fileSystemRepresentation,1);
    setenv("TOTK_SHADER_SEED_DIR",seedDir.fileSystemRepresentation,1);
    /* One folder per translation chain, as on the Mac: the runtime refuses translations of another chain, and the seed
       import keeps files that are already there. Builds before the v5 chain (2026-10-20) kept them directly in
       shader-cache; those, and other chains' folders, are only cache and are removed in the background. */
    NSString *cacheRoot = [docs stringByAppendingPathComponent:@"shader-cache"], *chainDir = @"rt-" DMSH_CHAIN;
    NSString *cache = [cacheRoot stringByAppendingPathComponent:chainDir];
    /* Test launches (devicectl --environment-variables '{"TOTK_SHADER_CACHE":"cache-test/1"}') can name another folder
       in Documents, e.g. an empty one to time a first start; it lies outside shader-cache, so the cleanup leaves it. */
    const char *testCache = getenv("TOTK_SHADER_CACHE");
    if (testCache && *testCache && !strstr(testCache, "..")) cache = [docs stringByAppendingPathComponent:@(testCache)];
    [fm createDirectoryAtPath:cache withIntermediateDirectories:YES attributes:nil error:nil];
    setenv("TOTK_SHADER_CACHE",cache.fileSystemRepresentation,1);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        NSFileManager *files = [NSFileManager new]; NSUInteger removed = 0;
        for (NSString *name in [files contentsOfDirectoryAtPath:cacheRoot error:nil] ?: @[]) {
            if ([name isEqualToString:chainDir]) continue;
            if ([files removeItemAtPath:[cacheRoot stringByAppendingPathComponent:name] error:nil]) removed++;
        }
        if (removed) fprintf(stderr,"[shader-cache] removed %lu entries of earlier translation chains\n",(unsigned long)removed);
    });
    // Shaders the shared list lacks (totk_shader_contrib.h), in the Files app for players who want to send them; only the Mac asks.
    setenv("TOTK_SHADER_CONTRIB",[docs stringByAppendingPathComponent:@"shader-list-contribution.txt"].fileSystemRepresentation,1);
    setenv("DM_NVN_SHMAP",[seedDir stringByAppendingPathComponent:@"shader_map.tsv"].fileSystemRepresentation,1);
    setenv("DM_MSL_DIR",seedDir.fileSystemRepresentation,1);
    NSString *font = [res stringByAppendingPathComponent:@"font"]; setenv("TOTK_FONT_DIR",font.fileSystemRepresentation,1);
    // Same player environment as the Mac launcher (app/launcher.m); the bundle is read-only, so state goes to Documents.
    setenv("TOTK_PROFILE_DIR",[docs stringByAppendingPathComponent:@"save"].fileSystemRepresentation,1);
    setenv("TOTK_GAME_SLOT_DIR",[docs stringByAppendingPathComponent:@"game-slot"].fileSystemRepresentation,1);
    setenv("TOTK_ROMFS_PROOF_DIR",docs.fileSystemRepresentation,1);   // hash the 17 GB RomFS once, not on every launch
    for (NSString *name in @[@"TOTK_GPU_ALLOW_SUBMIT",@"TOTK_GPU_WIDEN",@"TOTK_GPU_BLOCKRT",@"TOTK_GPU_MIDCLEAR"]) setenv(name.UTF8String,"1",1);
    setenv("TOTK_SLOT_OWNER","user",0); setenv("TOTK_SLOT_PURPOSE","player",0);
    unsetenv("TOTK_AUTOLOAD");
    chdir(docs.fileSystemRepresentation);
    host_argv[0] = strdup("TOTK"); host_argv[1] = strdup(res.fileSystemRepresentation); host_argv[2] = strdup("boot");
    return YES;   // the window is made when the window scene connects (TOTKSceneDelegate)
}
@end

int main(int argc, char **argv) { @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(TOTKApp.class)); } }
