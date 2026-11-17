#import "touch_pad.h"
#import "BOTWSheikahHUD.h"
#import <GameController/GameController.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "runtime.h"
#if defined(GAME_BOTW160)
#include "botw_touch.h"
#include <os/log.h>
#include <stdatomic.h>
#include <stdio.h>

typedef struct {
    unsigned polls, selectedKnown, selectedUnknown, unknownUnclassified;
    unsigned ownedKnown, equipmentKnown, artMissing;
    unsigned unknownReasons[BOTW_TOUCH_REASON_COUNT];
} BOTWTouchHUDCounters;
#endif

/* The Classic layout mirrors a Switch controller. The Sheikah layout uses the artwork and
   gameplay gestures from BOTWRecompAndroid. In either mode, the production runtime merges
   these touch inputs with physical controller inputs. Connected controllers can hide the
   overlay after a touch-free interval. */
typedef struct {
    CGPoint at;
    uint64_t bit;
    NSString *label;
    CGFloat size;
} TouchButton;
enum { kButtonCount = 16 };
enum { kTouchAimThrow = 128, kTouchAimBow = 512, kTouchAimMask = kTouchAimThrow | kTouchAimBow };
static const CGFloat kButtonSize = 46;
static const NSTimeInterval kHideAfter = 3;   // seconds after the last finger lifts, with a controller connected

NSInteger BOTWTouchCameraSensitivityNormalize(NSInteger value) {
    if (value >= 75 && value <= 200 && value % 25 == 0) return value;
    return BOTWTouchCameraSensitivityDefault;
}

@interface BOTWSheikahAccessibilityButton : UIAccessibilityElement
@property(nonatomic, copy) BOOL (^activate)(void);
@end

@implementation BOTWSheikahAccessibilityButton
- (BOOL)accessibilityActivate { return self.activate ? self.activate() : NO; }
@end

@interface BOTWSheikahPickerTouch : NSObject
@property(nonatomic, strong) id contact;
@property(nonatomic) CGPoint origin, position;
@property(nonatomic) uint64_t button;
@end

@implementation BOTWSheikahPickerTouch
@end

@implementation TOTKTouchPad {
    NSMapTable<id, NSNumber *> *buttonTouches;
    NSMapTable<id, NSValue *> *aimTouches;
    id leftOwner, rightOwner, freeLookOwner;
    CGPoint leftOrigin, leftPosition, rightOrigin, rightPosition, freeLookOrigin, freeLookPosition;
    CGPoint floatingCameraOrigin;
    NSMutableArray<BOTWSheikahPickerTouch *> *pickerTouches;
    id runeOwner, bufferedRuneOwner;
    CGPoint runePosition, bufferedRuneOrigin;
    CFTimeInterval bufferedRuneDownAt, bufferedRuneTapAt, runeNeutralUntil, runeConfirmAfter;
    uint64_t runeNeutralReads, runePulseToken;
    NSString *runeHint;
    int runeTarget;
    BOOL runeCommitReading;
    BOOL runeHeld, runeFallback, runeGoal, runeChecking, preferNativeRuneWheel;
    NSUInteger runeGeneration;
    int fanSelection, fanCurrent, runeSteps, flickDirection;
    uint8_t fanOwned;
    CGFloat wheelAnchor;
    CFTimeInterval runeSince, flickEnd, flickNext, wheelRelease, runeRetryUntil;
    CGFloat cameraDX, cameraDY;
    CFTimeInterval cameraTickAt;
    uint64_t touchButtons;
    BOOL gamepad, concealed;
    CGRect _customLayoutArea;
    BOTWSheikahLayout _customLayout;
    BOOL _customLayoutCached;
    NSTimer *hideTimer, *cameraTimer, *runeTimer;
#if defined(GAME_BOTW160)
    BOTWTouchSnapshot hudSnapshot;
    NSDictionary<NSString *, UIImage *> *hudIcons;
    NSDictionary<NSNumber *, UIImage *> *runeIcons;
    NSTimer *hudTimer;
    dispatch_queue_t hudQueue;
    NSCache<NSString *, UIImage *> *iconCache;
    NSMutableDictionary<NSString *, NSNumber *> *iconRetries;
    BOOL hudInFlight, hudForeground;
    BOTWTouchHUDCounters hudDiagnosticCounters;  // hudQueue only
#endif
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _touchCameraSensitivity = BOTWTouchCameraSensitivityDefault;
        self.multipleTouchEnabled = YES;
#if defined(GAME_BOTW160)
        hudSnapshot.selected_rune = -1;
        hudForeground = YES;
        hudQueue = dispatch_queue_create("org.macnativegames.botw.touch-hud", DISPATCH_QUEUE_SERIAL);
        iconCache = [NSCache new];
        iconCache.countLimit = 64;
        iconRetries = [NSMutableDictionary new];
#endif
        self.opaque = NO;
        self.backgroundColor = UIColor.clearColor;
        self.contentMode = UIViewContentModeRedraw;
        buttonTouches = [NSMapTable strongToStrongObjectsMapTable];
        aimTouches = [NSMapTable strongToStrongObjectsMapTable];
        pickerTouches = [NSMutableArray new];
        runeTarget = -1;
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserver:self selector:@selector(controllersChanged:) name:GCControllerDidConnectNotification object:nil];
        [center addObserver:self selector:@selector(controllersChanged:) name:GCControllerDidDisconnectNotification object:nil];
        [center addObserver:self selector:@selector(lostFocus:) name:UIApplicationWillResignActiveNotification object:nil];
        [center addObserver:self selector:@selector(gainedFocus:) name:UIApplicationDidBecomeActiveNotification object:nil];
        [self controllersChanged:nil];
    }
    return self;
}

- (void)controllersChanged:(NSNotification *)note {
    BOOL connected = NO;
    for (GCController *controller in GCController.controllers)
        if (controller.extendedGamepad && !([note.name isEqualToString:GCControllerDidDisconnectNotification] && controller == note.object)) connected = YES;
    if (connected == gamepad) return;
    gamepad = connected; [hideTimer invalidate]; hideTimer = nil;
    if (gamepad && !self.extraControls) [self conceal];
    else { concealed = NO; [self setNeedsDisplay]; }
}

- (void)conceal {
    concealed = YES;
    // Fingers on the screen when it hides would otherwise hold their buttons and sticks.
    [self releaseTouches];
}

- (void)releaseTouches {
    [buttonTouches removeAllObjects];
    [aimTouches removeAllObjects];
    leftOwner = rightOwner = freeLookOwner = nil;
    [pickerTouches removeAllObjects];
    runeOwner = nil;
    [self clearBufferedRune];
    runePulseToken = 0;
    runeHint = nil;
    runeHeld = runeFallback = runeGoal = runeChecking = preferNativeRuneWheel = NO;
    runeGeneration++;
    fanSelection = fanCurrent = -1;
    fanOwned = 0;
    runeSteps = flickDirection = 0;
    runeSince = flickEnd = flickNext = wheelRelease = runeRetryUntil = 0;
    [runeTimer invalidate]; runeTimer = nil;
    touchButtons = 0;
    [self stopCamera];
    runtime_touch_pad_clear();
    [self setNeedsDisplay];
}

- (void)lostFocus:(NSNotification *)notification {
    (void)notification;
#if defined(GAME_BOTW160)
    hudForeground = NO;
    [self updateHUDPolling];
#endif
    [self releaseTouches];
    [self hideLater];
}

- (void)gainedFocus:(NSNotification *)notification {
    (void)notification;
#if defined(GAME_BOTW160)
    hudForeground = YES;
    [self updateHUDPolling];
#endif
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) [self releaseTouches];
#if defined(GAME_BOTW160)
    [self updateHUDPolling];
#endif
}

- (void)dealloc {
    [cameraTimer invalidate];
    [hideTimer invalidate];
    [runeTimer invalidate];
#if defined(GAME_BOTW160)
    [hudTimer invalidate];
#endif
}

- (void)setSwipeLayout:(BOOL)swipeLayout {
    if (_swipeLayout == swipeLayout) return;
    _swipeLayout = swipeLayout;
    [self releaseTouches];
#if defined(GAME_BOTW160)
    [self updateHUDPolling];
#endif
}

- (void)setFloatingCameraStick:(BOOL)floatingCameraStick {
    if (_floatingCameraStick == floatingCameraStick) return;
    _floatingCameraStick = floatingCameraStick;
    [self releaseTouches];
    [self hideLater];
}

- (void)setTouchCameraSensitivity:(NSInteger)touchCameraSensitivity {
    NSInteger normalized = BOTWTouchCameraSensitivityNormalize(touchCameraSensitivity);
    if (_touchCameraSensitivity == normalized) return;
    _touchCameraSensitivity = normalized;
    [self releaseTouches];
    [self hideLater];
}

- (void)setExtraControls:(BOOL)extraControls {
    if (_extraControls == extraControls) return;
    _extraControls = extraControls;
    concealed = NO;
    [self setNeedsDisplay];
    [self hideLater];
}

+ (UIImage *)sheikahSettingsArtwork { return BOTWSheikahSettingsArtwork(); }

- (void)setUserInteractionEnabled:(BOOL)enabled {
    if (self.userInteractionEnabled == enabled) return;
    [super setUserInteractionEnabled:enabled];
    if (!enabled) [self releaseTouches];
#if defined(GAME_BOTW160)
    [self updateHUDPolling];
#endif
}

- (void)setHidden:(BOOL)hidden {
    if (self.hidden == hidden) return;
    [super setHidden:hidden];
    if (hidden) [self releaseTouches];
}

- (BOOL)hasTouches {
    return leftOwner || rightOwner || freeLookOwner || runeOwner || runeGoal || runeChecking || runeNeutralUntil || runePulseToken ||
           buttonTouches.count || pickerTouches.count;
}

- (void)hideLater {
    [hideTimer invalidate]; hideTimer = nil;
    if (!gamepad || self.extraControls || self.hasTouches) return;
    __weak TOTKTouchPad *weakSelf = self;
    hideTimer = [NSTimer scheduledTimerWithTimeInterval:kHideAfter repeats:NO block:^(NSTimer *timer) {
        (void)timer; TOTKTouchPad *pad = weakSelf; if (pad) [pad concealIfIdle];
    }];
}
- (void)concealIfIdle { if (gamepad && !self.extraControls && !self.hasTouches) [self conceal]; }

- (CGRect)area { return UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets); }

- (void)setSheikahOverrides:(BOTWSheikahOverrides *)sheikahOverrides {
    if ([_sheikahOverrides isEqualToDictionary:sheikahOverrides]) return;
    _sheikahOverrides = [sheikahOverrides copy];
    _customLayoutCached = NO;
    [self releaseTouches];
}

- (BOTWSheikahLayout)sheikahLayout {
    CGRect area = self.area;
    if (!self.sheikahOverrides.count) return BOTWSheikahLayoutMake(area);
    if (!_customLayoutCached || !CGRectEqualToRect(_customLayoutArea, area)) {
        _customLayoutArea = area;
        _customLayout = BOTWSheikahLayoutCanSave(area, self.sheikahOverrides)
            ? BOTWSheikahLayoutApply(area, self.sheikahOverrides) : BOTWSheikahLayoutMake(area);
        _customLayoutCached = YES;
    }
    return _customLayout;
}

- (CGFloat)stickRadius {
    return self.swipeLayout ? self.sheikahLayout.stickRadius : MIN(70, self.area.size.height * .16);
}

- (CGFloat)floatingCameraRadius { return BOTWSheikahLayoutMake(self.area).stickRadius * .83; }

- (BOOL)showsFloatingCameraStick {
    return self.swipeLayout && self.floatingCameraStick && freeLookOwner && rightOwner == freeLookOwner &&
           !pickerTouches.count && !(touchButtons & kTouchAimMask) &&
           !runeHeld && !runeGoal && !runeChecking && !runeNeutralUntil && !runePulseToken;
}

- (NSDictionary<NSNumber *, UIImage *> *)sheikahEditorIcons {
    NSMutableDictionary<NSNumber *, UIImage *> *images = [NSMutableDictionary new];
#if defined(GAME_BOTW160)
    for (BOTWSheikahControl control = 0; control < BOTWSheikahControlCount; control++) {
        UIImage *image = [self iconForControl:control];
        if (image) images[@(control)] = image;
    }
#endif
    return images.copy;
}
/* Distance between the centre of a button diamond (A/B/X/Y, the d-pad) and each of its buttons. */
- (CGFloat)diamond { return MIN(52, self.area.size.height * .14); }
- (CGFloat)hitRadius { return MIN(36, self.diamond * .68); }
/* How far the two columns sit inside the safe area: 14% of its width. On an iPhone they move halfway from there toward
   the screen edge, so the gap between the screen edge and the d-pad or A/B/X/Y is half as wide (the user's choice,
   2026-10-19; about 38 points on an iPhone 14, clear of the notch); the stick rings stay inside the safe area. */
- (CGFloat)columnInset {
    CGFloat full = self.area.size.width * .14;
    if (self.traitCollection.userInterfaceIdiom != UIUserInterfaceIdiomPhone) return full;
    CGFloat side = MAX(self.safeAreaInsets.left, self.safeAreaInsets.right), edgeGap = side + full - (self.diamond + kButtonSize / 2);
    return MAX(full - edgeGap / 2, self.stickRadius + 4);
}
/* The shoulder buttons move outward the same way on an iPhone: the gap between the screen edge and ZL / ZR is halved,
   and L / R move with them. */
- (CGFloat)shoulderShift {
    if (self.traitCollection.userInterfaceIdiom != UIUserInterfaceIdiomPhone) return 0;
    CGFloat side = MAX(self.safeAreaInsets.left, self.safeAreaInsets.right);
    return (side + self.area.size.width * .05 - kButtonSize / 2) / 2;
}
- (CGPoint)restingStick:(BOOL)right {
    CGRect a = self.area;
    CGFloat inset = self.columnInset + self.stickRadius * 1.9;
    return CGPointMake(right ? CGRectGetMaxX(a) - inset : CGRectGetMinX(a) + inset, CGRectGetMinY(a) + a.size.height * .80);
}

static int aimPriority(uint64_t bit) { return bit == kTouchAimBow ? 2 : bit == kTouchAimThrow ? 1 : 0; }
static BOOL isPicker(BOTWSheikahControl control) {
    return control == BOTWSheikahWeapon || control == BOTWSheikahShield || control == BOTWSheikahArrows;
}

- (void)buttons:(TouchButton *)b {
    CGRect a = self.area; CGFloat x = CGRectGetMinX(a), y = CGRectGetMinY(a), w = a.size.width, h = a.size.height, d = self.diamond;
    CGFloat top = y + h * .12, bottom = y + h * .88;
    CGFloat inset = self.columnInset, shift = self.shoulderShift;
    CGPoint face = CGPointMake(x + w - inset, y + h * .42), pad = CGPointMake(x + inset, y + h * .42);
    TouchButton all[kButtonCount] = {
        {{face.x + d, face.y}, 1, @"A", kButtonSize}, {{face.x, face.y + d}, 2, @"B", kButtonSize}, {{face.x, face.y - d}, 4, @"X", kButtonSize}, {{face.x - d, face.y}, 8, @"Y", kButtonSize},
        {{x + w * .05 - shift, top}, 256, @"ZL", kButtonSize}, {{x + w * .16 - shift, top}, 64, @"L", kButtonSize}, {{x + w * .84 + shift, top}, 128, @"R", kButtonSize}, {{x + w * .95 + shift, top}, 512, @"ZR", kButtonSize},
        {{x + w * .40, top}, 2048, @"−", kButtonSize}, {{x + w * .60, top}, 1024, @"+", kButtonSize},
        {{pad.x - d, pad.y}, 4096, @"◀", kButtonSize}, {{pad.x, pad.y - d}, 8192, @"▲", kButtonSize}, {{pad.x + d, pad.y}, 16384, @"▶", kButtonSize}, {{pad.x, pad.y + d}, 32768, @"▼", kButtonSize},
        {{x + w * .05 - shift, bottom}, 16, @"L3", kButtonSize}, {{x + w * .95 + shift, bottom}, 32, @"R3", kButtonSize}};
    for (int i = 0; i < kButtonCount; i++) b[i] = all[i];
}

- (uint64_t)buttonAt:(CGPoint)point {
    TouchButton buttons[kButtonCount];
    [self buttons:buttons];
    CGFloat hit = self.hitRadius;
    uint64_t bits = 0;
    for (int i = 0; i < kButtonCount; i++) {
        TouchButton button = buttons[i];
        if (hypot(point.x - button.at.x, point.y - button.at.y) < MIN(hit, button.size * .75))
            bits |= button.bit;
    }
    return bits;
}

static void stick_axes(CGPoint from, CGPoint to, CGFloat radius, int32_t *x, int32_t *y) {
    if (radius <= 0) { *x = *y = 0; return; }
    CGFloat dx = to.x - from.x, dy = from.y - to.y, dist = hypot(dx, dy);
    if (dist > radius) { dx *= radius / dist; dy *= radius / dist; }
    *x = (int32_t)(dx / radius * 32767); *y = (int32_t)(dy / radius * 32767);
}

static void floating_camera_axes(CGPoint origin, CGPoint point, CGFloat radius, CGFloat gain, int32_t *x, int32_t *y) {
    CGFloat dx = point.x - origin.x, dy = origin.y - point.y;
    CGFloat distance = hypot(dx, dy);
    CGFloat deadzone = radius * .16;
    if (radius <= 0 || !isfinite(distance) || distance <= deadzone) { *x = *y = 0; return; }
    CGFloat throwLength = MIN(1, (distance - deadzone) / (radius - deadzone) * gain);
    *x = (int32_t)(32767 * throwLength * (dx / distance));
    *y = (int32_t)(32767 * throwLength * (dy / distance));
}

- (void)publishState {
    RuntimeGamepadState state = {.connected = 1, .buttons = touchButtons};
    BOOL floating = [self showsFloatingCameraStick];
    CGFloat cameraGain = self.touchCameraSensitivity / 100.0;
    // A finger can stay down while a picker or aim control owns the camera. Resume
    // around its current position so the previous tilt cannot reappear on release.
    if (self.floatingCameraStick && !floating) floatingCameraOrigin = freeLookPosition;
    if (leftOwner) stick_axes(leftOrigin, leftPosition, self.stickRadius, &state.lx, &state.ly);
    if (rightOwner && !self.swipeLayout) {
        CGFloat gain = touchButtons & kTouchAimMask ? 1 : cameraGain;
        stick_axes(rightOrigin, rightPosition, self.stickRadius / gain, &state.rx, &state.ry);
    } else if (self.swipeLayout && (runeFallback || runeGoal)) {
        state.buttons |= BOTWSheikahButton(BOTWSheikahUp);
        if (CACurrentMediaTime() < flickEnd) state.rx = flickDirection * 32767;
    } else if (pickerTouches.count && !fanOwned) {
        BOTWSheikahPickerTouch *picker = pickerTouches.firstObject;
        CGPoint origin = freeLookOwner ? freeLookOrigin : picker.origin;
        CGPoint position = freeLookOwner ? freeLookPosition : picker.position;
        CGFloat dx = position.x - origin.x;
        CGFloat deadzone = self.stickRadius * .07;
        if (fabs(dx) > deadzone)
            state.rx = copysign(MIN(32767, (fabs(dx) - deadzone) / MAX(1, self.stickRadius * .63) * 32767), dx);
    } else if (floating) {
        // Unlike a swipe pulse, the virtual stick stays tilted until the finger moves
        // or lifts. The runtime publishes the same axes on every game poll.
        floating_camera_axes(floatingCameraOrigin, freeLookPosition, self.floatingCameraRadius, cameraGain, &state.rx, &state.ry);
    }
    runtime_touch_pad_set(&state, floating);
}

- (void)contactsChanged {
    touchButtons = 0;
    for (BOTWSheikahPickerTouch *picker in pickerTouches) touchButtons |= picker.button;
    for (NSNumber *bits in buttonTouches.objectEnumerator) touchButtons |= bits.unsignedLongLongValue;
    [self publishState];
    [self setNeedsDisplay];
}

#if defined(GAME_BOTW160)
static UIImage *copyHUDIcon(NSString *actor) {
    BOTWTouchIcon decoded;
    if (!botw_touch_icon(actor.UTF8String, &decoded)) return nil;
    size_t length = (size_t)decoded.width * decoded.height * 4;
    NSData *pixels = [NSData dataWithBytesNoCopy:decoded.rgba length:length freeWhenDone:YES];
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
    if (!provider) return nil;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGImageRef image = CGImageCreate(decoded.width, decoded.height, 8, 32, decoded.width * 4,
                                     space, kCGImageAlphaLast | kCGBitmapByteOrder32Big,
                                     provider, NULL, true, kCGRenderingIntentDefault);
    UIImage *result = image ? [UIImage imageWithCGImage:image] : nil;
    if (image) CGImageRelease(image);
    CGColorSpaceRelease(space);
    CGDataProviderRelease(provider);
    return result;
}

static BOOL hudDiagnosticEnabled(void) {
    static BOOL enabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *setting = getenv("TOTK_HUD_DIAGNOSTICS");
        enabled = setting && !strcmp(setting, "1");
    });
    return enabled;
}

static void emitHUDDiagnostic(BOTWTouchHUDCounters counts) {
    static atomic_bool pending;
    if (atomic_exchange_explicit(&pending, true, memory_order_relaxed)) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        static const char *const names[BOTW_TOUCH_REASON_COUNT] = {
            [BOTW_TOUCH_RUNTIME_UNAVAILABLE] = "runtime_unavailable",
            [BOTW_TOUCH_MODULE_SLOT] = "module_slot",
            [BOTW_TOUCH_MODULE_BUSY] = "module_busy",
            [BOTW_TOUCH_MEMORY_BUSY] = "memory_busy",
            [BOTW_TOUCH_LOCK_ERROR] = "lock_error",
            [BOTW_TOUCH_DATA_RANGE] = "data_range",
            [BOTW_TOUCH_DATA_UNMAPPED] = "data_unmapped",
            [BOTW_TOUCH_DATA_MOVED] = "data_moved",
            [BOTW_TOUCH_VM_COPY] = "vm_copy",
            [BOTW_TOUCH_GDT_LAYOUT] = "gdt_layout",
            [BOTW_TOUCH_FLAG_TYPE] = "flag_type",
            [BOTW_TOUCH_FLAG_MISSING] = "flag_missing",
            [BOTW_TOUCH_SELECTION_RANGE] = "selection_range",
            [BOTW_TOUCH_UNSTABLE] = "unstable",
        };
        char text[512];
        int used = snprintf(text, sizeof text,
                            "polls=%u selected_known=%u selected_unknown=%u unknown_unclassified=%u"
                            " owned_known=%u equipment_known=%u art_missing=%u",
                            counts.polls, counts.selectedKnown, counts.selectedUnknown, counts.unknownUnclassified,
                            counts.ownedKnown, counts.equipmentKnown, counts.artMissing);
        for (unsigned i = 0; i < BOTW_TOUCH_REASON_COUNT && used >= 0 && (size_t)used < sizeof text; i++)
            used += snprintf(text + used, sizeof text - (size_t)used, " unknown_%s=%u", names[i], counts.unknownReasons[i]);
        os_log_t logger = os_log_create("org.macnativegames.botw", "sheikah-rune");
        os_log_with_type(logger, OS_LOG_TYPE_DEFAULT, "[botw-hud] %{public}s", text);
        atomic_store_explicit(&pending, false, memory_order_relaxed);
    });
}

static void countHUDDiagnostic(BOTWTouchHUDCounters *counts, uint32_t reasons, bool selectedKnown,
                               bool ownedKnown, bool equipmentKnown, bool artMissing) {
    counts->polls++;
    counts->ownedKnown += ownedKnown;
    counts->equipmentKnown += equipmentKnown;
    if (selectedKnown) {
        counts->selectedKnown++;
        counts->artMissing += artMissing;
    } else {
        counts->selectedUnknown++;
        counts->unknownUnclassified += !reasons;
        for (unsigned i = 0; i < BOTW_TOUCH_REASON_COUNT; i++) counts->unknownReasons[i] += !!(reasons & (1u << i));
    }
}

- (void)recordHUDDiagnosticReasons:(uint32_t)reasons selectedKnown:(BOOL)selectedKnown
                        ownedKnown:(BOOL)ownedKnown equipmentKnown:(BOOL)equipmentKnown artMissing:(BOOL)artMissing {
    BOTWTouchHUDCounters *counts = &hudDiagnosticCounters;
    countHUDDiagnostic(counts, reasons, selectedKnown, ownedKnown, equipmentKnown, artMissing);
    if (counts->polls == 16) {
        emitHUDDiagnostic(*counts);
        *counts = (BOTWTouchHUDCounters){0};
    }
}

- (void)readHUD {
    if (hudInFlight) return;
    hudInFlight = YES;
    NSCache<NSString *, UIImage *> *cache = iconCache;
    NSMutableDictionary<NSString *, NSNumber *> *retries = iconRetries;
    __weak typeof(self) weakSelf = self;
    dispatch_async(hudQueue, ^{
        BOTWTouchSnapshot snapshot = {.selected_rune = -1};
        BOOL diagnostics = hudDiagnosticEnabled();
        uint32_t reasons = 0;
        if (diagnostics) botw_touch_snapshot_diagnostic(&snapshot, &reasons);
        else botw_touch_snapshot(&snapshot);
        NSMutableSet<NSString *> *actors = [NSMutableSet setWithObject:@"Obj_DRStone_Get"];
        if (snapshot.equipment_known) {
            for (unsigned i = 0; i < 4; i++) {
                NSString *name = @(snapshot.equipped[i]);
                if (name.length) [actors addObject:name];
            }
        }
        NSMutableDictionary<NSNumber *, NSString *> *runeActors = [NSMutableDictionary dictionary];
        for (unsigned i = 0; i < 8; i++) {
            if ((snapshot.owned_runes_known && (snapshot.owned_runes & (1 << i))) || snapshot.selected_rune == (int)i) {
                const char *actor = botw_touch_rune_actor(i);
                if (actor) { [actors addObject:@(actor)]; runeActors[@(i)] = @(actor); }
            }
        }
        for (NSString *actor in retries.allKeys) if (![actors containsObject:actor]) [retries removeObjectForKey:actor];
        CFTimeInterval now = CACurrentMediaTime();
        NSMutableDictionary<NSString *, UIImage *> *available = [NSMutableDictionary dictionary];
        for (NSString *actor in actors) {
            UIImage *image = [cache objectForKey:actor];
            if (!image && now >= retries[actor].doubleValue) {
                image = copyHUDIcon(actor);
                if (image) {
                    [cache setObject:image forKey:actor];
                    [retries removeObjectForKey:actor];
                } else retries[actor] = @(now + 2);
            }
            if (image) available[actor] = image;
        }
        NSMutableDictionary<NSNumber *, UIImage *> *availableRunes = [NSMutableDictionary dictionary];
        for (NSNumber *rune in runeActors) {
            UIImage *image = available[runeActors[rune]];
            if (image) availableRunes[rune] = image;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf applyHUD:snapshot items:available.copy runes:availableRunes.copy];
        });
        if (diagnostics)
            [weakSelf recordHUDDiagnosticReasons:reasons selectedKnown:snapshot.selected_rune >= 0
                                       ownedKnown:snapshot.owned_runes_known equipmentKnown:snapshot.equipment_known
                                       artMissing:snapshot.selected_rune >= 0 && !availableRunes[@(snapshot.selected_rune)]];
    });
}

- (void)applyHUD:(BOTWTouchSnapshot)snapshot items:(NSDictionary<NSString *, UIImage *> *)items
           runes:(NSDictionary<NSNumber *, UIImage *> *)runes {
    hudInFlight = NO;
    if (!hudTimer) return;
    if (!memcmp(&snapshot, &hudSnapshot, sizeof snapshot) && [items isEqualToDictionary:hudIcons]) return;
    hudSnapshot = snapshot;
    hudIcons = items;
    runeIcons = runes;
    [self setNeedsDisplay];
}

- (void)updateHUDPolling {
    BOOL active = self.swipeLayout && self.window && self.userInteractionEnabled && hudForeground;
    if (!active) {
        [hudTimer invalidate]; hudTimer = nil;
        hudSnapshot = (BOTWTouchSnapshot){.selected_rune = -1};
        hudIcons = nil;
        runeIcons = nil;
        [self setNeedsDisplay];
        return;
    }
    if (hudTimer) return;
    __weak typeof(self) weakSelf = self;
    hudTimer = [NSTimer timerWithTimeInterval:.5 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        [weakSelf readHUD];
    }];
    [NSRunLoop.mainRunLoop addTimer:hudTimer forMode:NSRunLoopCommonModes];
    [self readHUD];
}

- (UIImage *)iconForControl:(BOTWSheikahControl)control {
    int equippedSlot = -1;
    switch (control) {
        case BOTWSheikahWeapon:
            equippedSlot = touchButtons & BOTWSheikahButton(BOTWSheikahBow) ? 1 : 0;
            break;
        case BOTWSheikahAttack: equippedSlot = 0; break;
        case BOTWSheikahBow: equippedSlot = 1; break;
        case BOTWSheikahBlock:
        case BOTWSheikahShield: equippedSlot = 2; break;
        case BOTWSheikahArrows: equippedSlot = 3; break;
        case BOTWSheikahRune: return runeIcons[@(hudSnapshot.selected_rune)];
        case BOTWSheikahSlate: return hudIcons[@"Obj_DRStone_Get"];
        default: break;
    }
    return equippedSlot >= 0 && hudSnapshot.equipment_known ? hudIcons[@(hudSnapshot.equipped[equippedSlot])] : nil;
}
#endif

// The Android control uses a 280 ms hold, a 110 ms tilt and a matching neutral gap.
// Hold Up while stepping the game’s picker so the game, rather than this overlay, commits the selection.
static const CFTimeInterval kRuneHold = .280, kRuneFlick = .110, kWheelSettle = .250;

- (void)clearBufferedRune {
    bufferedRuneOwner = nil;
    bufferedRuneDownAt = bufferedRuneTapAt = runeNeutralUntil = runeConfirmAfter = 0;
    runeNeutralReads = 0;
    runeCommitReading = NO;
    runeTarget = -1;
}

- (void)pulseRune {
    touchButtons |= BOTWSheikahButton(BOTWSheikahRune);
    [self publishState]; // Runtime latches the edge for the next Npad sample.
}

- (void)showRuneHint:(NSString *)message {
    runeHint = message;
    runeRetryUntil = CACurrentMediaTime() + 1.8;
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, message);
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf setNeedsDisplay];
    });
    [self setNeedsDisplay];
}

#if defined(GAME_BOTW160)
- (void)pollBufferedRunePulse {
    if (!runePulseToken) return;
    int result = runtime_touch_pad_rune_pulse_result(runePulseToken);
    if (!result) return;
    runePulseToken = 0;
    if (result < 0) [self showRuneHint:@"Нажми руну ещё раз"];
    if (self.floatingCameraStick) [self contactsChanged];
    [self hideLater];
}

- (void)awaitBufferedRuneAfterNeutral:(CFTimeInterval)now {
    if (runeTarget < 0) return;
    if (!bufferedRuneOwner && !bufferedRuneTapAt) { [self clearBufferedRune]; return; }
    runeNeutralReads = runtime_input_rune_neutral_reads();
    runeNeutralUntil = now + .32;
    if (self.floatingCameraStick) [self contactsChanged];
    [self startRuneTimer];
}

- (void)sendBufferedRuneAt:(CFTimeInterval)now {
    if (!runeNeutralUntil) return;
    if (now >= runeNeutralUntil || (bufferedRuneTapAt && now - bufferedRuneTapAt > 2.5)) {
        BOOL hadTap = bufferedRuneTapAt != 0;
        [self clearBufferedRune];
        if (hadTap) [self showRuneHint:@"Выбери руну снова"];
        if (self.floatingCameraStick) [self contactsChanged];
        [self hideLater];
        return;
    }
    if (!bufferedRuneTapAt || runeCommitReading || now < runeConfirmAfter ||
        runtime_input_rune_neutral_reads() == runeNeutralReads) return;

    runeCommitReading = YES;
    NSUInteger generation = runeGeneration;
    int target = runeTarget;
    __weak typeof(self) weakSelf = self;
    dispatch_async(hudQueue, ^{
        BOTWTouchSnapshot snapshot = {.selected_rune = -1};
        botw_touch_snapshot(&snapshot);
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf finishBufferedRune:generation target:target snapshot:snapshot];
        });
    });
}

- (void)finishBufferedRune:(NSUInteger)generation target:(int)target snapshot:(BOTWTouchSnapshot)snapshot {
    if (generation != runeGeneration || !runeNeutralUntil || runeTarget != target) return;
    runeCommitReading = NO;
    CFTimeInterval now = CACurrentMediaTime();
    if (now >= runeNeutralUntil || now - bufferedRuneTapAt > 2.5) return;
    if (snapshot.selected_rune != target || !snapshot.owned_runes_known || !(snapshot.owned_runes & (1u << target))) {
        runeConfirmAfter = now + .04;
        return;
    }
    [self clearBufferedRune];
    // A stalled game can resume much later. The runtime consumes this edge at most once before its deadline.
    runePulseToken = runtime_touch_pad_rune_pulse(runtime_now_ns() + 125000000ull);
    if (!runePulseToken) [self showRuneHint:@"Нажми руну ещё раз"];
    [self contactsChanged];
    [self hideLater];
}
#endif

- (void)runeTickAt:(CFTimeInterval)now {
    BOOL changed = NO, goalClosed = NO;
    if (runeOwner && !runeHeld && now - runeSince >= kRuneHold) {
        runeHeld = changed = YES;
        [self interruptCamera];
#if defined(GAME_BOTW160)
        int rune = hudSnapshot.selected_rune;
        if (!preferNativeRuneWheel && hudSnapshot.owned_runes_known && rune >= 0 && rune < 8 &&
            (hudSnapshot.owned_runes & (1 << rune))) {
            fanOwned = hudSnapshot.owned_runes;
            fanCurrent = rune;
        }
#endif
        preferNativeRuneWheel = NO;
        if (fanOwned) fanSelection = BOTWSheikahFanPick(self.sheikahLayout, runePosition, fanOwned);
        else {
            runeFallback = YES;
            wheelAnchor = runePosition.x;
            flickNext = now + kWheelSettle;
        }
    }
    if (runeGoal || runeFallback) {
        if (flickDirection && now >= flickEnd) { flickDirection = 0; changed = YES; }
        if (runeSteps && now >= flickNext) {
            flickDirection = runeSteps > 0 ? 1 : -1;
            runeSteps -= flickDirection;
            flickEnd = now + kRuneFlick;
            flickNext = flickEnd + kRuneFlick;
            changed = YES;
        }
        if (runeGoal && ((!runeSteps && now >= flickNext + kWheelSettle) || now >= wheelRelease)) {
            runeGoal = NO;
            changed = YES;
            goalClosed = now < wheelRelease;
            if (!goalClosed) {
                BOOL hadTap = bufferedRuneTapAt != 0;
                [self clearBufferedRune];
                if (hadTap) [self showRuneHint:@"Выбери руну снова"];
            }
        }
    }
    if (changed) [self contactsChanged];
#if defined(GAME_BOTW160)
    if (goalClosed) [self awaitBufferedRuneAfterNeutral:now];
    [self sendBufferedRuneAt:now];
    [self pollBufferedRunePulse];
#endif
    if (changed) [self hideLater];
    if (!runeGoal && !runeNeutralUntil && !runePulseToken && (!runeOwner || fanOwned)) {
        [runeTimer invalidate];
        runeTimer = nil;
    }
}

- (void)startRuneTimer {
    if (runeTimer) return;
    __weak typeof(self) weakSelf = self;
    runeTimer = [NSTimer timerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        [weakSelf runeTickAt:CACurrentMediaTime()];
    }];
    [NSRunLoop.mainRunLoop addTimer:runeTimer forMode:NSRunLoopCommonModes];
}

- (void)moveRune:(CGPoint)point {
    runePosition = point;
    if (fanOwned) {
        fanSelection = BOTWSheikahFanPick(self.sheikahLayout, point, fanOwned);
        [self setNeedsDisplay];
    } else if (runeFallback) {
        CGFloat step = MAX(26, CGRectGetWidth(self.area) * .06);
        int crossed = (int)((point.x - wheelAnchor) / step);
        runeSteps = MAX(-7, MIN(7, runeSteps + crossed));
        wheelAnchor += crossed * step;
    }
}

#if defined(GAME_BOTW160)
static const CFTimeInterval kRuneVerifyDeadline = .18;

- (void)finishRuneVerification:(NSUInteger)generation target:(int)target
                      snapshot:(BOTWTouchSnapshot)snapshot deadline:(CFTimeInterval)deadline {
    if (!runeChecking || generation != runeGeneration) return;
    runeChecking = NO;
    CFTimeInterval now = CACurrentMediaTime();
    int current = snapshot.selected_rune;
    uint8_t mask = snapshot.owned_runes;
    BOOL fresh = now <= deadline && snapshot.owned_runes_known && current >= 0 && current < 8 &&
                 (mask & (1u << current)) && (mask & (1u << target));
    if (!fresh) {
        [self clearBufferedRune];
        preferNativeRuneWheel = YES;
        [self showRuneHint:@"Выбери руну снова"];
        [self readHUD];
    } else if (target != current) {
        unsigned targetMask = (1u << target) - 1, currentMask = (1u << current) - 1;
        runeSteps = __builtin_popcount(mask & targetMask) - __builtin_popcount(mask & currentMask);
        runeGoal = YES;
        [self interruptCamera];
        flickDirection = 0;
        flickEnd = 0;
        flickNext = now + kWheelSettle;
        wheelRelease = now + 4;
        [self startRuneTimer];
    }
    [self contactsChanged];
    if (fresh && target == current) [self awaitBufferedRuneAfterNeutral:now];
    [self hideLater];
}

- (void)verifyRuneSelection:(int)target {
    runeChecking = YES;
    runeTarget = target;
    NSUInteger generation = ++runeGeneration;
    CFTimeInterval deadline = CACurrentMediaTime() + kRuneVerifyDeadline;
    __weak typeof(self) weakSelf = self;
    dispatch_async(hudQueue, ^{
        BOTWTouchSnapshot snapshot = {.selected_rune = -1};
        botw_touch_snapshot(&snapshot);
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf finishRuneVerification:generation target:target snapshot:snapshot deadline:deadline];
        });
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRuneVerifyDeadline * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf finishRuneVerification:generation target:target snapshot:(BOTWTouchSnapshot){.selected_rune = -1}
                                  deadline:deadline];
    });
}
#endif

- (void)endRune {
    CFTimeInterval now = CACurrentMediaTime();
    if (!runeHeld && now - runeSince >= kRuneHold) [self runeTickAt:now];
    if (!runeHeld) {
        [self pulseRune];
    } else if (fanOwned && fanSelection >= 0) {
#if defined(GAME_BOTW160)
        [self verifyRuneSelection:fanSelection];
#endif
    } else if (runeFallback && (runeSteps || now < flickEnd)) {
        // A fast release can precede the next game's poll. Let the queued tilt finish first.
        runeGoal = YES;
        wheelRelease = now + 4;
    } else runeSteps = 0;
    runeOwner = nil;
    runeHeld = runeFallback = NO;
    fanOwned = 0;
    if (runeGoal) [self startRuneTimer];
    else { [runeTimer invalidate]; runeTimer = nil; flickEnd = 0; }
    [self contactsChanged];
    [self hideLater];
}

- (void)stopCamera {
    [cameraTimer invalidate];
    cameraTimer = nil;
    cameraDX = cameraDY = 0;
    cameraTickAt = 0;
}

- (void)interruptCamera {
    [self stopCamera];
    // A released aim can still be queued. Discard every camera channel before changing the button state.
    runtime_touch_pad_camera_sample(0, 0, 0);
    runtime_touch_pad_camera_sample(0, 0, BOTWSheikahButton(BOTWSheikahThrow));
    runtime_touch_pad_camera_sample(0, 0, BOTWSheikahButton(BOTWSheikahBow));
}

- (BOTWSheikahPickerTouch *)pickerForContact:(id)contact {
    for (BOTWSheikahPickerTouch *picker in pickerTouches) if (picker.contact == contact) return picker;
    return nil;
}

- (uint64_t)cameraSampleAim {
    uint64_t ownerAim = rightOwner ? [buttonTouches objectForKey:rightOwner].unsignedLongLongValue : 0;
    if (self.floatingCameraStick && rightOwner && rightOwner == freeLookOwner)
        return touchButtons & kTouchAimBow ? kTouchAimBow : touchButtons & kTouchAimThrow;
    return ownerAim;
}

/* Sample the latest motion once for the next Npad read. An idle finger emits no further samples. */
- (void)sampleCameraAt:(CFTimeInterval)now {
    CFTimeInterval dt = cameraTickAt > 0 ? now - cameraTickAt : 0;
    cameraTickAt = now;
    if (dt < 1.0 / 120 || dt > .10) dt = 1.0 / 60;
    CGFloat dx = cameraDX, dy = cameraDY, distance = hypot(dx, dy);
    cameraDX = cameraDY = 0;
    if (distance >= .5 && self.area.size.height > 0) {
        CGFloat speed = distance / (self.area.size.height * dt);
        uint64_t aim = self.cameraSampleAim;
        CGFloat gain = aim || (touchButtons & kTouchAimMask) ? 1 : self.touchCameraSensitivity / 100.0;
        CGFloat length = MIN(1, (.15 + .85 * speed) * gain);
        int32_t x = (int32_t)(32767 * length * dx / distance);
        int32_t y = (int32_t)(-32767 * length * dy / distance);
        runtime_touch_pad_camera_sample(x, y, aim);
    } else {
        [self stopCamera];
    }
}

- (void)startCameraTimer {
    if (cameraTimer) return;
    cameraTickAt = CACurrentMediaTime();
    __weak typeof(self) weakSelf = self;
    cameraTimer = [NSTimer timerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        [weakSelf sampleCameraAt:CACurrentMediaTime()];
    }];
    [NSRunLoop.mainRunLoop addTimer:cameraTimer forMode:NSRunLoopCommonModes];
}

- (void)beginContact:(id)contact at:(CGPoint)point {
    CGRect area = self.area;
    if (self.hidden || !self.userInteractionEnabled || !CGRectContainsPoint(area, point)) return;
    BOTWSheikahControl control = BOTWSheikahControlCount;
    uint64_t bit;
    BOOL restingStickTouched = NO;
    if (self.swipeLayout) {
        BOTWSheikahLayout layout = self.sheikahLayout;
        control = BOTWSheikahHit(layout, point, touchButtons, fanOwned != 0);
        bit = control == BOTWSheikahControlCount ? 0 : BOTWSheikahButton(control);
        restingStickTouched = self.sheikahOverrides[BOTWSheikahEditKey(BOTWSheikahMove)] &&
            CGRectContainsPoint(BOTWSheikahEditTarget(layout, BOTWSheikahMove).hit, point);
        if (restingStickTouched && control < BOTWSheikahControlCount &&
            hypot(point.x - layout.stick.x, point.y - layout.stick.y) <
            hypot(point.x - layout.target[control].center.x, point.y - layout.target[control].center.y)) {
            control = BOTWSheikahControlCount;
            bit = 0;
        }
        if (!bit && !restingStickTouched && point.x < CGRectGetMidX(area) &&
            point.y < CGRectGetMinY(area) + CGRectGetHeight(area) * .30) return;
    } else bit = [self buttonAt:point];
    concealed = NO;
    [hideTimer invalidate]; hideTimer = nil;
    if (control == BOTWSheikahRune) {
#if defined(GAME_BOTW160)
        [self pollBufferedRunePulse];
#endif
        if (runeOwner || runePulseToken) return;
        if (runeChecking || runeGoal || runeNeutralUntil) {
            if (runeTarget >= 0 && !bufferedRuneOwner && !bufferedRuneTapAt) {
                bufferedRuneOwner = contact;
                bufferedRuneOrigin = point;
                bufferedRuneDownAt = CACurrentMediaTime();
            }
            return;
        }
        runeOwner = contact;
        runeRetryUntil = 0;
        runePosition = point;
        runeSince = CACurrentMediaTime();
        [self startRuneTimer];
    } else if (isPicker(control)) {
        BOTWSheikahPickerTouch *picker = [BOTWSheikahPickerTouch new];
        picker.contact = contact;
        picker.origin = picker.position = point;
        picker.button = bit;
        if (!pickerTouches.count) {
            freeLookOrigin = freeLookPosition;
            [self interruptCamera];
        }
        [pickerTouches addObject:picker];
    } else if (bit) {
        if (self.swipeLayout && self.floatingCameraStick && freeLookOwner && rightOwner == freeLookOwner && aimPriority(bit))
            [self stopCamera]; // A released, tagged aim sample still belongs to the next Npad read.
        [buttonTouches setObject:@(bit) forKey:contact];
        if (self.swipeLayout && aimPriority(bit))
            [aimTouches setObject:[NSValue valueWithCGPoint:point] forKey:contact];
    } else if (restingStickTouched || point.x < CGRectGetMidX(area)) {
        if (leftOwner) return;
        leftOwner = contact;
        leftPosition = leftOrigin = point;
    } else {
        if (self.swipeLayout) {
            if (freeLookOwner) return;
            freeLookOwner = contact;
            freeLookPosition = freeLookOrigin = point;
            floatingCameraOrigin = point;
        } else if (rightOwner) return;
        if (!rightOwner) {
            rightOwner = contact;
            rightPosition = rightOrigin = point;
        }
    }
    [self contactsChanged];
}

- (void)moveContact:(id)contact to:(CGPoint)point {
    if (contact == runeOwner) { [self moveRune:point]; return; }
    if (contact == bufferedRuneOwner) {
        if (hypot(point.x - bufferedRuneOrigin.x, point.y - bufferedRuneOrigin.y) > 18) bufferedRuneOwner = nil;
        return;
    }
    BOTWSheikahPickerTouch *picker = [self pickerForContact:contact];
    if (picker) {
        picker.position = point;
        if (picker == pickerTouches.firstObject) [self contactsChanged];
        return;
    }
    if (contact == freeLookOwner) {
        freeLookPosition = point;
        BOOL freeAim = self.floatingCameraStick && contact == rightOwner && (touchButtons & kTouchAimMask);
        if (freeAim) floatingCameraOrigin = point;
        if (pickerTouches.count || (self.floatingCameraStick && !freeAim)) {
            if (contact == rightOwner) rightPosition = point;
            [self contactsChanged];
            return;
        }
        if (contact != rightOwner) return;
    }
    if (contact == leftOwner) {
        leftPosition = point;
        [self contactsChanged];
        return;
    }
    if (self.swipeLayout && (pickerTouches.count || runeFallback || runeGoal ||
                            (fanOwned && ![aimTouches objectForKey:contact]))) {
        if (contact == rightOwner) rightPosition = point;
        if ([aimTouches objectForKey:contact]) [aimTouches setObject:[NSValue valueWithCGPoint:point] forKey:contact];
        return;
    }
    NSValue *aim = [aimTouches objectForKey:contact];
    if (aim && contact != rightOwner) {
        CGPoint previous = aim.CGPointValue;
        if (hypot(point.x - previous.x, point.y - previous.y) < 1) return;
        [aimTouches setObject:[NSValue valueWithCGPoint:point] forKey:contact];
        int priority = aimPriority([buttonTouches objectForKey:contact].unsignedLongLongValue);
        uint64_t ownerAim = rightOwner ? [buttonTouches objectForKey:rightOwner].unsignedLongLongValue : 0;
        if (priority <= aimPriority(ownerAim)) return;
        [self stopCamera];
        if (rightOwner) runtime_touch_pad_camera_sample(0, 0, ownerAim);
        rightOwner = contact;
        rightPosition = previous;
    } else if (aim) {
        [aimTouches setObject:[NSValue valueWithCGPoint:point] forKey:contact];
    }
    if (contact == rightOwner) {
        if (self.swipeLayout) {
            cameraDX += point.x - rightPosition.x;
            cameraDY += point.y - rightPosition.y;
            rightPosition = point;
            if (cameraDX || cameraDY) [self startCameraTimer];
            return;
        }
        rightPosition = point;
    } else if ([buttonTouches objectForKey:contact]) {
        if (self.swipeLayout) return; // Each action belongs to the finger that took it.
        [buttonTouches setObject:@([self buttonAt:point]) forKey:contact];
    } else return;
    [self contactsChanged];
}

- (void)endContact:(id)contact {
    if (contact == runeOwner) { [self endRune]; return; }
    if (contact == bufferedRuneOwner) {
        CFTimeInterval now = CACurrentMediaTime();
        bufferedRuneOwner = nil;
        if (now - bufferedRuneDownAt < kRuneHold) bufferedRuneTapAt = now;
        return;
    }
    BOTWSheikahPickerTouch *picker = [self pickerForContact:contact];
    if (picker) {
        BOOL wasOwner = picker == pickerTouches.firstObject;
        [pickerTouches removeObjectIdenticalTo:picker];
        if (wasOwner) {
            BOTWSheikahPickerTouch *next = pickerTouches.firstObject;
            if (next) next.origin = next.position;
            freeLookOrigin = freeLookPosition;
        }
        [self contactsChanged];
        [self hideLater];
        return;
    }
    NSNumber *button = [buttonTouches objectForKey:contact];
    BOOL hadButton = button != nil;
    BOOL hadFreeLook = contact == freeLookOwner;
    // The final free-finger aim sample needs the original camera owner and held button.
    if (contact == rightOwner && self.swipeLayout && (cameraDX || cameraDY))
        [self sampleCameraAt:CACurrentMediaTime()];
    if (hadFreeLook) {
        freeLookOwner = nil;
        BOTWSheikahPickerTouch *active = pickerTouches.firstObject;
        if (active) active.origin = active.position;
    }
    if (contact == leftOwner) leftOwner = nil;
    else if (contact == rightOwner) {
        [self stopCamera];
        rightOwner = freeLookOwner;
        rightPosition = freeLookPosition;
    } else if (!hadButton && !hadFreeLook) return;
    if (self.swipeLayout && self.floatingCameraStick && freeLookOwner && rightOwner == freeLookOwner &&
        self.cameraSampleAim == button.unsignedLongLongValue && aimPriority(button.unsignedLongLongValue)) {
        if (cameraDX || cameraDY) [self sampleCameraAt:CACurrentMediaTime()];
        [self stopCamera];
    }
    if (hadButton) [buttonTouches removeObjectForKey:contact];
    [aimTouches removeObjectForKey:contact];
    [self contactsChanged];
    [self hideLater];
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return self.swipeLayout ? CGRectContainsPoint(self.area, point) : [super pointInside:point withEvent:event];
}

- (NSArray *)accessibilityElements {
    if (!self.swipeLayout || concealed || !self.userInteractionEnabled) return [super accessibilityElements];
    BOTWSheikahLayout layout = self.sheikahLayout;
    NSMutableArray *elements = [NSMutableArray array];
    __weak typeof(self) weakSelf = self;
    for (BOTWSheikahControl i = 0; i < BOTWSheikahControlCount; i++) {
        if (!BOTWSheikahVisible(i, touchButtons, fanOwned != 0)) continue;
        BOTWSheikahAccessibilityButton *button = [[BOTWSheikahAccessibilityButton alloc] initWithAccessibilityContainer:self];
        button.accessibilityLabel = BOTWSheikahLabel(i);
        button.accessibilityTraits = UIAccessibilityTraitButton;
        button.accessibilityFrameInContainerSpace = layout.target[i].hit;
        CGPoint point = layout.target[i].center;
        button.activate = ^BOOL{
            TOTKTouchPad *pad = weakSelf;
            if (!pad) return NO;
            NSObject *contact = [NSObject new];
            [pad beginContact:contact at:point];
            [pad endContact:contact];
            return YES;
        };
        [elements addObject:button];
    }
    return elements;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    for (UITouch *touch in touches) [self beginContact:touch at:[touch locationInView:self]];
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    for (UITouch *touch in touches) [self moveContact:touch to:[touch locationInView:self]];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    for (UITouch *touch in touches) {
        if (touch == runeOwner || touch == bufferedRuneOwner)
            [self moveContact:touch to:[touch locationInView:self]];
        [self endContact:touch];
    }
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches; (void)event;
    [self releaseTouches];
    [self hideLater];
}
- (void)safeAreaInsetsDidChange {
    [super safeAreaInsetsDidChange];
    [self releaseTouches];
    [self hideLater];
}

static void draw_stick(CGContextRef c, CGPoint o, CGPoint p, CGFloat r) {
    int32_t x, y; stick_axes(o, p, r, &x, &y); CGContextStrokeEllipseInRect(c, CGRectMake(o.x - r, o.y - r, 2 * r, 2 * r));
    CGPoint k = CGPointMake(o.x + x / 32767.0 * r, o.y - y / 32767.0 * r);
    CGRect knob = CGRectMake(k.x - kButtonSize / 2, k.y - kButtonSize / 2, kButtonSize, kButtonSize);
    CGContextFillEllipseInRect(c, knob); CGContextStrokeEllipseInRect(c, knob);
}

- (void)drawSheikah:(CGContextRef)context {
    CGRect area = self.area;
    BOTWSheikahLayout layout = self.sheikahLayout;
    if (layout.stickRadius <= 0) return;
    CGContextSaveGState(context);
    CGContextClipToRect(context, area);
    CGPoint stick = leftOwner ? leftOrigin : layout.stick;
    CGFloat r = layout.stickRadius;
    stick.x = MAX(CGRectGetMinX(area) + r, MIN(stick.x, CGRectGetMaxX(area) - r));
    stick.y = MAX(CGRectGetMinY(area) + r, MIN(stick.y, CGRectGetMaxY(area) - r));
    int32_t lx = 0, ly = 0;
    if (leftOwner) stick_axes(leftOrigin, leftPosition, r, &lx, &ly);
    CGPoint knob = CGPointMake(stick.x + lx / 32767.0 * r, stick.y - ly / 32767.0 * r);
    BOTWSheikahDrawStick(stick, knob, r, leftOwner != nil);

    if ([self showsFloatingCameraStick]) {
        CGFloat radius = self.floatingCameraRadius;
        int32_t x, y;
        floating_camera_axes(floatingCameraOrigin, freeLookPosition, radius, self.touchCameraSensitivity / 100.0, &x, &y);
        CGPoint thumb = CGPointMake(floatingCameraOrigin.x + x / 32767.0 * radius,
                                    floatingCameraOrigin.y - y / 32767.0 * radius);
        BOTWSheikahDrawStick(floatingCameraOrigin, thumb, radius, YES);
    }

    for (BOTWSheikahControl i = 0; i < BOTWSheikahControlCount; i++) {
        if (!BOTWSheikahVisible(i, touchButtons, fanOwned != 0)) continue;
        UIImage *icon = nil;
#if defined(GAME_BOTW160)
        icon = [self iconForControl:i];
#endif
        BOOL held = i == BOTWSheikahRune ? runeOwner || runeGoal || runeChecking : (touchButtons & BOTWSheikahButton(i)) != 0;
        BOTWSheikahDrawControl(layout.target[i], i, icon, held);
    }

    if (fanOwned) {
        NSDictionary *icons = nil;
#if defined(GAME_BOTW160)
        icons = runeIcons;
#endif
        BOTWSheikahDrawFan(layout, fanOwned, fanCurrent, fanSelection, icons);
    }
    if (CACurrentMediaTime() < runeRetryUntil) {
        NSShadow *shadow = [NSShadow new];
        shadow.shadowColor = UIColor.blackColor;
        shadow.shadowOffset = CGSizeMake(0, 1);
        shadow.shadowBlurRadius = 2;
        UIFont *font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
        NSDictionary *attributes = @{NSFontAttributeName:font, NSForegroundColorAttributeName:UIColor.whiteColor,
                                     NSShadowAttributeName:shadow};
        CGSize size = [runeHint sizeWithAttributes:attributes];
        BOTWSheikahTarget rune = layout.target[BOTWSheikahRune];
        [runeHint drawAtPoint:CGPointMake(rune.center.x - rune.radius - size.width - 9, rune.center.y - size.height / 2)
           withAttributes:attributes];
    }
    CGContextRestoreGState(context);
}

- (void)drawRect:(CGRect)rect {
    if (concealed) return;
    if (self.swipeLayout) { [self drawSheikah:UIGraphicsGetCurrentContext()]; return; }
    (void)rect; CGContextRef c = UIGraphicsGetCurrentContext(); UIColor *ink = [UIColor colorWithWhite:1 alpha:.32];
    // One fill for every button and knob, set before each fill: drawing a label leaves the context's fill colour at the
    // label's, which once made every button after A (the first drawn) brighter than A and the stick knobs.
    CGColorRef fill = ink.CGColor; CGContextSetStrokeColorWithColor(c, ink.CGColor); CGContextSetFillColorWithColor(c, fill); CGContextSetLineWidth(c, 2);
    CGFloat r = self.stickRadius;
    CGPoint left = leftOwner ? leftOrigin : [self restingStick:NO];
    CGPoint right = rightOwner ? rightOrigin : [self restingStick:YES];
    if (r > 0) {
        draw_stick(c, left, leftOwner ? leftPosition : left, r);
        draw_stick(c, right, rightOwner ? rightPosition : right, r);
    }
    NSDictionary *attrs = @{NSFontAttributeName: [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold], NSForegroundColorAttributeName: ink};
    TouchButton b[kButtonCount]; [self buttons:b];
    for (int i = 0; i < kButtonCount; i++) {
        CGFloat size = b[i].size; CGRect box = CGRectMake(b[i].at.x - size / 2, b[i].at.y - size / 2, size, size);
        CGContextSetFillColorWithColor(c, fill); CGContextFillEllipseInRect(c, box); CGContextStrokeEllipseInRect(c, box);
        CGSize z = [b[i].label sizeWithAttributes:attrs]; [b[i].label drawAtPoint:CGPointMake(b[i].at.x - z.width / 2, b[i].at.y - z.height / 2) withAttributes:attrs];
    }
}
@end
