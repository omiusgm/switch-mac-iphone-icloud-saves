// Layout and rune-fan code adapt BOTWRecompAndroid runtime/ui/touch_controls.mm
// at 3d9beeb0c25c65845e805c91c4bba1bbb860cae9 (Peiikai). See ../licenses/NOTICE.md.
// Artwork is excluded; the public settings control uses a system gear symbol.
#import "BOTWSheikahHUD.h"
#include <float.h>
#include <math.h>

typedef NS_ENUM(NSUInteger, AtlasSprite) {
    AtlasButton, AtlasShoulder, AtlasStick, AtlasKnob,
    AtlasJump, AtlasSprint, AtlasCrouch, AtlasWhistle, AtlasBag
};

static const struct {
    uint64_t bit;
    __unsafe_unretained NSString *key;
    __unsafe_unretained NSString *label;
    int action;
} controls[BOTWSheikahControlCount] = {
    [BOTWSheikahWeapon] = {1 << 14, @">", @"Сменить оружие", -1},
    [BOTWSheikahShield] = {1 << 12, @"<", @"Сменить щит", -1},
    [BOTWSheikahUp] = {1 << 13, @"", @"Крестовина вверх", -1},
    [BOTWSheikahWhistle] = {1 << 15, @"", @"Свист и крестовина вниз", AtlasWhistle},
    [BOTWSheikahCrouch] = {1 << 4, @"L3", @"Присесть", AtlasCrouch},
    [BOTWSheikahSlate] = {1 << 5, @"R3", @"Прицел Шиика", -1},
    [BOTWSheikahMap] = {1 << 11, @"−", @"Карта", -1},
    [BOTWSheikahInventory] = {1 << 10, @"+", @"Инвентарь", AtlasBag},
    [BOTWSheikahRune] = {1 << 6, @"L", @"Руна. Удерживайте для выбора руны", -1},
    [BOTWSheikahThrow] = {1 << 7, @"R", @"Бросить оружие", -1},
    [BOTWSheikahBow] = {1 << 9, @"ZR", @"Лук", -1},
    [BOTWSheikahBlock] = {1 << 8, @"ZL", @"Защита и захват цели", -1},
    [BOTWSheikahAttack] = {1 << 3, @"Y", @"Удар", -1},
    [BOTWSheikahJump] = {1 << 2, @"X", @"Прыжок", AtlasJump},
    [BOTWSheikahSprint] = {1 << 1, @"B", @"Бег и отмена", AtlasSprint},
    [BOTWSheikahInteract] = {1 << 0, @"A", @"Действие", -1},
    [BOTWSheikahCancel] = {1 << 1, @"", @"Отменить прицеливание", -1},
    [BOTWSheikahArrows] = {1 << 12, @"<", @"Сменить стрелы", -1},
};

uint64_t BOTWSheikahButton(BOTWSheikahControl control) { return controls[control].bit; }
NSString *BOTWSheikahLabel(BOTWSheikahControl control) { return controls[control].label; }

static CGFloat clamp(CGFloat value, CGFloat low, CGFloat high) { return MAX(low, MIN(value, high)); }
static const CGFloat runeSliceInset = .025;

BOTWSheikahLayout BOTWSheikahLayoutMake(CGRect area) {
    // The original uses screen-relative anchors and height-relative radii. Limit the control spread on
    // tablets and reserve the lower right for the iOS minimap, plus the lower middle for game text.
    CGFloat width = CGRectGetWidth(area), height = CGRectGetHeight(area);
    CGFloat left = CGRectGetMinX(area), right = CGRectGetMaxX(area), top = CGRectGetMinY(area);
    CGFloat edgeWidth = MIN(width, height * 2.45);
    CGFloat unit = MIN(height, 460);
    CGFloat leftInset = MAX(22, .054 * edgeWidth), leftStep = MAX(46, .071 * edgeWidth);
    const struct { CGFloat x, y, r; BOOL right; } anchors[BOTWSheikahControlCount] = {
        [BOTWSheikahWeapon] = {.054, .56, .050, NO},
        [BOTWSheikahShield] = {.125, .56, .050, NO},
        [BOTWSheikahUp] = {.054, .42, .043, NO},
        [BOTWSheikahWhistle] = {.125, .42, .043, NO},
        [BOTWSheikahCrouch] = {.190, .820, .046, NO},
        [BOTWSheikahSlate] = {.195, .56, .043, NO},
        [BOTWSheikahMap] = {.145, .27, .045, YES},
        [BOTWSheikahInventory] = {.060, .27, .045, YES},
        [BOTWSheikahRune] = {.170, .43, .0624, YES},
        [BOTWSheikahThrow] = {.035, .42, .045, YES},
        [BOTWSheikahBow] = {.280, .57, .067, YES},
        [BOTWSheikahBlock] = {.060, .57, .052, YES},
        [BOTWSheikahAttack] = {.170, .62, .097, YES},
        [BOTWSheikahJump] = {.280, .720, .050, YES},
        [BOTWSheikahSprint] = {.030, .855, .050, YES},
        [BOTWSheikahInteract] = {.060, .715, .050, YES},
        [BOTWSheikahCancel] = {.265, .42, .050, NO},
        [BOTWSheikahArrows] = {.195, .42, .050, NO},
    };
    BOTWSheikahLayout layout = {0};
    for (BOTWSheikahControl i = 0; i < BOTWSheikahControlCount; i++) {
        CGFloat r = unit * anchors[i].r;
        CGFloat halfHit = MAX(22, r * 1.10);
        CGFloat x = anchors[i].right ? right - anchors[i].x * edgeWidth
                                    : left + leftInset + (anchors[i].x - .054) / .071 * leftStep;
        CGFloat y = top + anchors[i].y * height;
        x = clamp(x, left + halfHit, right - halfHit);
        y = clamp(y, top + halfHit, CGRectGetMaxY(area) - halfHit);
        layout.target[i] = (BOTWSheikahTarget){
            CGPointMake(x, y), r, CGRectMake(x - halfHit, y - halfHit, 2 * halfHit, 2 * halfHit)
        };
    }
    layout.stickRadius = .13 * unit;
    layout.stick = CGPointMake(left + MAX(layout.stickRadius + 2, .09 * edgeWidth), top + .75 * height);
    BOTWSheikahTarget rune = layout.target[BOTWSheikahRune];
    CGFloat throwEdge = CGRectGetMinX(layout.target[BOTWSheikahThrow].hit);
    layout.fanInner = rune.radius * 1.2;
    // Keep the full 44-point throw target available while the rune fan is up.
    layout.fanOuter = MIN(rune.radius * 3.2, MIN(rune.center.y - top - 4, throwEdge - rune.center.x - 3));
    return layout;
}

// Editor behavior adapted from the MIT-licensed BOTWRecompAndroid runtime/ui/touch_controls.mm
// (3d9beeb0, Peiikai). See BOTWSheikahLicense.txt.
static NSString *const layoutKey = @"BOTWSheikahLayout.v1";

NSString *BOTWSheikahEditKey(NSUInteger index) {
    static NSString *const keys[] = {
        @"weapon", @"shield", @"up", @"whistle", @"crouch", @"slate", @"map", @"inventory", @"rune",
        @"throw", @"bow", @"block", @"attack", @"jump", @"sprint", @"interact", @"cancel", @"arrows", @"move"
    };
    return keys[index];
}

NSString *BOTWSheikahEditLabel(NSUInteger index) {
    switch (index) {
        case BOTWSheikahMove: return @"Движение";
        case BOTWSheikahRune: return @"Руна";
        case BOTWSheikahWhistle: return @"Свист";
        case BOTWSheikahBlock: return @"Защита";
        default: return BOTWSheikahLabel(index);
    }
}

static BOOL numberInRange(id number, double low, double high) {
    if (![number isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)number) == CFBooleanGetTypeID()) return NO;
    double value = [number doubleValue];
    return isfinite(value) && value >= low && value <= high;
}

BOTWSheikahOverrides *BOTWSheikahLoadLayout(NSUserDefaults *defaults) {
    id raw = [defaults objectForKey:layoutKey];
    if (![raw isKindOfClass:NSDictionary.class]) return @{};
    NSMutableDictionary *overrides = [NSMutableDictionary new];
    for (NSUInteger i = 0; i < BOTWSheikahEditableCount; i++) {
        NSString *key = BOTWSheikahEditKey(i);
        id value = raw[key];
        if (![value isKindOfClass:NSDictionary.class]) continue;
        NSMutableDictionary *entry = [NSMutableDictionary new];
        if (numberInRange(value[@"x"], 0, 1) && numberInRange(value[@"y"], 0, 1)) {
            entry[@"x"] = value[@"x"];
            entry[@"y"] = value[@"y"];
        }
        if (numberInRange(value[@"scale"], .5, 2)) entry[@"scale"] = value[@"scale"];
        if (entry.count) overrides[key] = entry.copy;
    }
    return overrides.copy;
}

BOOL BOTWSheikahSaveLayout(NSUserDefaults *defaults, BOTWSheikahOverrides *overrides) {
    // One property-list value is committed on Save. Wait for this explicit commit
    // before closing the editor, since the app can be closed immediately afterwards.
    id previous = [defaults objectForKey:layoutKey];
    [defaults setObject:overrides forKey:layoutKey];
    if ([defaults synchronize]) return YES;
    if (previous) [defaults setObject:previous forKey:layoutKey];
    else [defaults removeObjectForKey:layoutKey];
    [defaults synchronize];
    return NO;
}

BOTWSheikahTarget BOTWSheikahEditTarget(BOTWSheikahLayout layout, NSUInteger index) {
    if (index < BOTWSheikahControlCount) return layout.target[index];
    CGPoint p = layout.stick;
    CGFloat r = MAX(22, layout.stickRadius);
    return (BOTWSheikahTarget){p, layout.stickRadius, CGRectMake(p.x - r, p.y - r, r * 2, r * 2)};
}

CGRect BOTWSheikahEditorInspectorFrame(CGRect area) {
    CGFloat width = MIN(344, CGRectGetWidth(area) - 16);
    return CGRectMake(CGRectGetMidX(area) - width / 2, CGRectGetMaxY(area) - 54, width, 48);
}

CGRect BOTWSheikahSettingsFrame(CGRect area) {
    return CGRectMake(CGRectGetMidX(area) - BOTWSheikahSettingsSize / 2.0,
                      CGRectGetMinY(area) + BOTWSheikahSettingsTop,
                      BOTWSheikahSettingsSize, BOTWSheikahSettingsSize);
}

BOTWSheikahLayout BOTWSheikahLayoutApply(CGRect area, BOTWSheikahOverrides *overrides) {
    BOTWSheikahLayout layout = BOTWSheikahLayoutMake(area);
    if (!overrides.count || CGRectIsEmpty(area)) return layout;
    for (NSUInteger i = 0; i < BOTWSheikahEditableCount; i++) {
        NSDictionary *entry = overrides[BOTWSheikahEditKey(i)];
        if (!entry) continue;
        BOTWSheikahTarget target = BOTWSheikahEditTarget(layout, i);
        CGFloat scale = entry[@"scale"] ? [entry[@"scale"] doubleValue] : 1;
        CGFloat radius = target.radius * scale;
        CGFloat halfHit = MAX(22, radius * (i == BOTWSheikahMove ? 1 : 1.10));
        CGPoint center = target.center;
        if (entry[@"x"] && entry[@"y"]) {
            center = CGPointMake(CGRectGetMinX(area) + CGRectGetWidth(area) * [entry[@"x"] doubleValue],
                                 CGRectGetMinY(area) + CGRectGetHeight(area) * [entry[@"y"] doubleValue]);
        }
        center.x = clamp(center.x, CGRectGetMinX(area) + halfHit + 3, CGRectGetMaxX(area) - halfHit - 3);
        center.y = clamp(center.y, CGRectGetMinY(area) + halfHit + 3, CGRectGetMaxY(area) - halfHit - 3);
        if (i == BOTWSheikahMove) {
            layout.stick = center;
            layout.stickRadius = radius;
        } else {
            layout.target[i] = (BOTWSheikahTarget){center, radius, CGRectMake(center.x - halfHit, center.y - halfHit,
                                                                               2 * halfHit, 2 * halfHit)};
        }
    }
    if (overrides[BOTWSheikahEditKey(BOTWSheikahRune)]) {
        BOTWSheikahTarget rune = layout.target[BOTWSheikahRune];
        CGFloat left = rune.center.x - CGRectGetMinX(area) - 4;
        CGFloat top = rune.center.y - CGRectGetMinY(area) - 4;
        CGFloat right = CGRectGetMaxX(area) - rune.center.x - 4;
        // A smaller rune button keeps a usable fan. A larger button increases the inner radius.
        CGFloat band = layout.fanOuter - layout.fanInner;
        layout.fanInner = MAX(layout.fanInner, rune.radius * 1.2);
        layout.fanOuter = MIN(layout.fanInner + band, MIN(left, MIN(top, right)));
    }
    return layout;
}

NSUInteger BOTWSheikahEditHit(BOTWSheikahLayout layout, CGPoint point) {
    NSUInteger selected = BOTWSheikahEditableCount;
    CGFloat closest = CGFLOAT_MAX;
    for (NSUInteger i = 0; i < BOTWSheikahEditableCount; i++) {
        BOTWSheikahTarget target = BOTWSheikahEditTarget(layout, i);
        if (!CGRectContainsPoint(target.hit, point)) continue;
        CGFloat distance = hypot(point.x - target.center.x, point.y - target.center.y);
        if (distance < closest) { selected = i; closest = distance; }
    }
    return selected;
}

static CGFloat hitOverlap(CGRect a, CGRect b) {
    CGRect common = CGRectIntersection(a, b);
    return CGRectIsEmpty(common) ? 0 : common.size.width * common.size.height;
}

static CGFloat centerDistance(BOTWSheikahTarget a, BOTWSheikahTarget b) {
    return hypot(a.center.x - b.center.x, a.center.y - b.center.y);
}

static CGFloat circleOverlap(BOTWSheikahTarget a, BOTWSheikahTarget b, CGFloat distance) {
    CGFloat r = a.radius, s = b.radius;
    if (distance >= r + s || r <= 0 || s <= 0) return 0;
    if (distance <= fabs(r - s)) return M_PI * MIN(r * r, s * s);
    // The intersecting lens consists of one circular segment from each disk.
    CGFloat aAngle = acos(clamp((distance * distance + r * r - s * s) / (2 * distance * r), -1, 1));
    CGFloat bAngle = acos(clamp((distance * distance + s * s - r * r) / (2 * distance * s), -1, 1));
    return r * r * (aAngle - sin(aAngle) * cos(aAngle)) + s * s * (bAngle - sin(bAngle) * cos(bAngle));
}

static BOOL hitIntersectsRuneFan(CGRect hit, BOTWSheikahLayout layout) {
    CGFloat inner = layout.fanInner, outer = layout.fanOuter;
    if (outer <= inner) return NO;
    CGPoint center = layout.target[BOTWSheikahRune].center;
    // The single-rune slice is the maximum visible sector. Its straight edges
    // bound the upper wedge by y <= -tan(inset)*abs(x) in rune-relative coordinates.
    CGFloat slope = tan(runeSliceInset);
    CGFloat bottom = CGRectGetMaxY(hit) - center.y;
    CGFloat top = CGRectGetMinY(hit) - center.y;
    if (top >= 0) return NO;
    CGFloat limit = -top / slope;
    CGFloat left = MAX(CGRectGetMinX(hit) - center.x, -limit);
    CGFloat right = MIN(CGRectGetMaxX(hit) - center.x, limit);
    if (left >= right) return NO;
    CGFloat nearestX = clamp(0, left, right);
    CGFloat nearestY = MIN(bottom, -slope * fabs(nearestX));
    CGFloat farthestX = MAX(fabs(left), fabs(right));
    // Distances over the clipped box fill the interval between its extremes.
    return hypot(nearestX, nearestY) < outer && hypot(farthestX, top) > inner;
}

BOTWSheikahLayoutIssue BOTWSheikahValidateLayout(CGRect area, BOTWSheikahOverrides *overrides) {
    if (!overrides.count || CGRectIsEmpty(area)) return BOTWSheikahLayoutValid;
    BOTWSheikahLayout base = BOTWSheikahLayoutMake(area);
    BOTWSheikahLayout draft = BOTWSheikahLayoutApply(area, overrides);
    CGRect inspector = BOTWSheikahEditorInspectorFrame(area);
    CGRect toolbar = CGRectMake(CGRectGetMinX(area), CGRectGetMinY(area), CGRectGetWidth(area), 54);
    for (NSUInteger i = 0; i < BOTWSheikahEditableCount; i++) {
        if (!overrides[BOTWSheikahEditKey(i)]) continue;
        BOTWSheikahTarget target = BOTWSheikahEditTarget(draft, i);
        if (hitOverlap(target.hit, toolbar) > 0 || hitOverlap(target.hit, inspector) > 0)
            return BOTWSheikahLayoutUnderEditorPanel;
    }
    // Include the movement stick and both contextual aiming controls. Cancel and Arrows
    // can be on screen together while the bow is held.
    for (NSUInteger i = 0; i < BOTWSheikahEditableCount; i++) {
        BOTWSheikahTarget a = BOTWSheikahEditTarget(draft, i), originalA = BOTWSheikahEditTarget(base, i);
        for (NSUInteger j = i + 1; j < BOTWSheikahEditableCount; j++) {
            if (!overrides[BOTWSheikahEditKey(i)] && !overrides[BOTWSheikahEditKey(j)]) continue;
            BOTWSheikahTarget b = BOTWSheikahEditTarget(draft, j), originalB = BOTWSheikahEditTarget(base, j);
            CGFloat before = centerDistance(originalA, originalB), after = centerDistance(a, b);
            if (after + .01 < MIN(44, before) ||
                hitOverlap(a.hit, b.hit) > hitOverlap(originalA.hit, originalB.hit) + .0001 ||
                circleOverlap(a, b, after) > circleOverlap(originalA, originalB, before) + .0001)
                return BOTWSheikahLayoutOverlappingControls;
        }
    }
    if (overrides[BOTWSheikahEditKey(BOTWSheikahRune)] &&
        draft.fanOuter - draft.fanInner < MIN(24, base.fanOuter - base.fanInner))
        return BOTWSheikahLayoutRuneFanClipped;

    CGPoint originalRune = base.target[BOTWSheikahRune].center, movedRune = draft.target[BOTWSheikahRune].center;
    BOOL fanChanged = !CGPointEqualToPoint(originalRune, movedRune) ||
        base.fanInner != draft.fanInner || base.fanOuter != draft.fanOuter;
    if (fanChanged && hitIntersectsRuneFan(BOTWSheikahSettingsFrame(area), draft))
        return BOTWSheikahLayoutRuneFanOverlap;
    uint64_t bowHeld = BOTWSheikahButton(BOTWSheikahBow);
    for (NSUInteger i = 0; i < BOTWSheikahEditableCount; i++) {
        if (i == BOTWSheikahRune || (i != BOTWSheikahMove && !BOTWSheikahVisible(i, bowHeld, YES))) continue;
        CGRect hit = BOTWSheikahEditTarget(draft, i).hit;
        if ((fanChanged || !CGRectEqualToRect(hit, BOTWSheikahEditTarget(base, i).hit)) && hitIntersectsRuneFan(hit, draft))
            return BOTWSheikahLayoutRuneFanOverlap;
    }
    return BOTWSheikahLayoutValid;
}

BOOL BOTWSheikahLayoutCanSave(CGRect area, BOTWSheikahOverrides *overrides) {
    return BOTWSheikahValidateLayout(area, overrides) == BOTWSheikahLayoutValid;
}

BOOL BOTWSheikahVisible(BOTWSheikahControl control, uint64_t buttons, BOOL fanOpen) {
    if (fanOpen && (control == BOTWSheikahMap || control == BOTWSheikahInventory)) return NO;
    if (control == BOTWSheikahCancel) return (buttons & (BOTWSheikahButton(BOTWSheikahBow) | BOTWSheikahButton(BOTWSheikahThrow))) != 0;
    if (control == BOTWSheikahArrows) return (buttons & BOTWSheikahButton(BOTWSheikahBow)) != 0;
    return YES;
}

BOTWSheikahControl BOTWSheikahHit(BOTWSheikahLayout layout, CGPoint point, uint64_t buttons, BOOL fanOpen) {
    BOTWSheikahControl best = BOTWSheikahControlCount;
    CGFloat closest = CGFLOAT_MAX;
    for (BOTWSheikahControl i = 0; i < BOTWSheikahControlCount; i++) {
        BOTWSheikahTarget target = layout.target[i];
        if (!BOTWSheikahVisible(i, buttons, fanOpen) || !CGRectContainsPoint(target.hit, point)) continue;
        CGFloat distance = hypot(point.x - target.center.x, point.y - target.center.y);
        if (distance < closest) { best = i; closest = distance; }
    }
    return best;
}

static UIImage *sprite(AtlasSprite index) {
    static NSArray<UIImage *> *sprites;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CGImageRef skin = [UIImage imageNamed:@"BOTWSheikahFrame"].CGImage;
        CGImageRef actions = [UIImage imageNamed:@"BOTWSheikahActions"].CGImage;
        // Original UV crop coordinates, in the unmodified 1254-pixel atlas.
        const CGRect skinRects[] = {{ {24, 26}, {578, 536}}, {{633, 185}, {614, 227}},
                                    {{22, 617}, {584, 570}}, {{706, 677}, {469, 461}}};
        NSMutableArray *images = [NSMutableArray array];
        for (AtlasSprite i = AtlasButton; i <= AtlasBag; i++) {
            CGImageRef source = i <= AtlasKnob ? skin : actions;
            CGRect box = i <= AtlasKnob ? skinRects[i] : CGRectMake((i - AtlasJump) * 256, 0, 256, 256);
            CGImageRef crop = source ? CGImageCreateWithImageInRect(source, box) : NULL;
            [images addObject:crop ? [UIImage imageWithCGImage:crop] : [UIImage new]];
            if (crop) CGImageRelease(crop);
        }
        sprites = images.copy;
    });
    return sprites[index];
}

static CGRect around(CGPoint center, CGFloat radius) {
    return CGRectMake(center.x - radius, center.y - radius, radius * 2, radius * 2);
}

static UIColor *shade(BOOL active) {
    return active ? [UIColor colorWithRed:45/255.0 green:205/255.0 blue:235/255.0 alpha:120/255.0]
                  : [UIColor colorWithRed:20/255.0 green:30/255.0 blue:33/255.0 alpha:40/255.0];
}

static UIColor *cyan(void) { return [UIColor colorWithRed:.26 green:.84 blue:.96 alpha:.86]; }
static UIColor *ink(void) { return [UIColor colorWithRed:.94 green:.92 blue:.86 alpha:.90]; }

static void disk(CGPoint center, CGFloat radius, UIColor *fill) {
    [fill setFill];
    [[UIBezierPath bezierPathWithOvalInRect:around(center, radius)] fill];
}

static void frame(AtlasSprite index, CGRect box, CGFloat opacity) {
    UIImage *image = sprite(index);
    if (image.CGImage) {
        [image drawInRect:box blendMode:kCGBlendModeNormal alpha:opacity];
    } else {
        [[UIColor colorWithWhite:1 alpha:opacity] setStroke];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectInset(box, 1, 1)] stroke];
    }
}

static void caption(NSString *label, CGPoint center, CGFloat radius) {
    UIFont *font = [UIFont monospacedSystemFontOfSize:MAX(11, radius * .85) weight:UIFontWeightSemibold];
    NSShadow *shadow = [NSShadow new];
    shadow.shadowColor = [UIColor colorWithWhite:0 alpha:.65];
    shadow.shadowOffset = CGSizeMake(0, 1);
    shadow.shadowBlurRadius = 2;
    NSDictionary *style = @{NSFontAttributeName:font, NSForegroundColorAttributeName:ink(), NSShadowAttributeName:shadow};
    CGSize size = [label sizeWithAttributes:style];
    [label drawAtPoint:CGPointMake(center.x - size.width / 2, center.y - size.height / 2) withAttributes:style];
}

static void symbol(NSString *name, CGPoint center, CGFloat size, UIColor *color) {
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:size weight:UIImageSymbolWeightMedium];
    UIImage *image = [[UIImage systemImageNamed:name withConfiguration:config] imageWithTintColor:color renderingMode:UIImageRenderingModeAlwaysOriginal];
    [image drawAtPoint:CGPointMake(center.x - image.size.width / 2, center.y - image.size.height / 2)];
}

static void swapArrows(CGPoint center, CGFloat radius) {
    [cyan() setStroke]; [cyan() setFill];
    CGFloat ring = radius * .86, head = radius * .19;
    for (int i = 0; i < 2; i++) {
        CGFloat start = i ? .35 : 3.49, end = start + 1.60;
        UIBezierPath *arc = [UIBezierPath bezierPathWithArcCenter:center radius:ring startAngle:start endAngle:end clockwise:YES];
        arc.lineWidth = MAX(1.1, radius * .09);
        [arc stroke];
        CGFloat x = center.x + cos(end) * ring, y = center.y + sin(end) * ring;
        UIBezierPath *arrow = [UIBezierPath bezierPath];
        [arrow moveToPoint:CGPointMake(x - sin(end) * head, y + cos(end) * head)];
        [arrow addLineToPoint:CGPointMake(x + cos(end) * head * .6, y + sin(end) * head * .6)];
        [arrow addLineToPoint:CGPointMake(x - cos(end) * head * .6, y - sin(end) * head * .6)];
        [arrow closePath];
        [arrow fill];
    }
}

void BOTWSheikahDrawControl(BOTWSheikahTarget target, BOTWSheikahControl control, UIImage *item, BOOL held) {
    CGPoint center = target.center;
    CGFloat r = target.radius;
    disk(center, r, shade(held));
    frame(AtlasButton, around(center, r), held ? .85 : .63);
    int action = controls[control].action;
    BOOL picker = control == BOTWSheikahWeapon || control == BOTWSheikahShield || control == BOTWSheikahArrows;
    if (action >= 0 && sprite(action).CGImage) {
        [sprite(action) drawInRect:around(center, r * .75) blendMode:kCGBlendModeNormal alpha:.92];
    } else if (item) {
        CGFloat size = r * (picker ? .55 : control == BOTWSheikahBow ? .57 : .72);
        [item drawInRect:around(center, size) blendMode:kCGBlendModeNormal alpha:.94];
    } else {
        switch (control) {
            case BOTWSheikahUp: symbol(@"arrow.up", center, r * .85, ink()); break;
            case BOTWSheikahWhistle: symbol(@"arrow.down", center, r * .85, ink()); break;
            case BOTWSheikahMap: symbol(@"map", center, r * .92, ink()); break;
            case BOTWSheikahCancel: symbol(@"xmark", center, r * .90, [UIColor colorWithRed:.95 green:.40 blue:.32 alpha:.95]); break;
            default: caption(controls[control].key, center, r); break;
        }
    }
    if (picker) swapArrows(center, r);
}

void BOTWSheikahDrawStick(CGPoint center, CGPoint knob, CGFloat radius, BOOL held) {
    disk(center, radius, shade(NO));
    frame(AtlasStick, around(center, radius), .63);
    frame(AtlasKnob, around(knob, radius * .45), held ? .68 : .42);
}

static int runeAtSlot(uint8_t owned, unsigned slot) {
    for (int i = 0; i < 8; i++) {
        if ((owned & (1 << i)) && slot-- == 0) return i;
    }
    return -1;
}

int BOTWSheikahFanPick(BOTWSheikahLayout layout, CGPoint point, uint8_t owned) {
    unsigned count = __builtin_popcount(owned);
    CGPoint center = layout.target[BOTWSheikahRune].center;
    CGFloat dx = point.x - center.x, dy = point.y - center.y;
    CGFloat distance = hypot(dx, dy);
    if (!count || dy > 8 || distance < layout.fanInner * .70 || distance > layout.fanOuter + 2) return -1;
    CGFloat theta = atan2(MIN(0, dy), dx);
    if (theta > 0) theta = -M_PI;
    unsigned slot = MIN(count - 1, (unsigned)((theta + M_PI) * count / M_PI));
    return runeAtSlot(owned, slot);
}

void BOTWSheikahDrawFan(BOTWSheikahLayout layout, uint8_t owned, int selected, int hovered, NSDictionary<NSNumber *, UIImage *> *runes) {
    if (!owned || layout.fanOuter <= layout.fanInner) return;
    NSString *const symbols[] = {@"circle.fill", @"square.fill", @"u.circle.fill", @"lock.fill",
                                 @"snowflake", @"camera.fill", @"motorcycle", @"figure.stand"};
    CGPoint center = layout.target[BOTWSheikahRune].center;
    unsigned count = __builtin_popcount(owned);
    CGFloat inner = layout.fanInner, outer = layout.fanOuter, middle = (inner + outer) / 2;
    CGFloat span = M_PI / count;
    for (unsigned slot = 0; slot < count; slot++) {
        int rune = runeAtSlot(owned, slot);
        CGFloat start = -M_PI + slot * span + runeSliceInset, end = -M_PI + (slot + 1) * span - runeSliceInset;
        UIBezierPath *slice = [UIBezierPath bezierPathWithArcCenter:center radius:outer startAngle:start endAngle:end clockwise:YES];
        [slice addLineToPoint:CGPointMake(center.x + cos(end) * inner, center.y + sin(end) * inner)];
        [slice addArcWithCenter:center radius:inner startAngle:end endAngle:start clockwise:NO];
        [slice closePath];
        [(rune == hovered ? shade(YES) : [UIColor colorWithRed:.08 green:.12 blue:.13 alpha:.59]) setFill];
        [slice fill];
        [(rune == selected || rune == hovered ? cyan() : [UIColor colorWithWhite:1 alpha:.55]) setStroke];
        slice.lineWidth = rune == selected ? 1.8 : 1;
        [slice stroke];
        CGFloat angle = (start + end) / 2;
        CGPoint anchor = CGPointMake(center.x + cos(angle) * middle, center.y + sin(angle) * middle);
        CGFloat r = MIN((outer - inner) * .35, middle * span * .38);
        UIImage *icon = runes[@(rune)];
        if (icon) [icon drawInRect:around(anchor, r) blendMode:kCGBlendModeNormal alpha:.95];
        else symbol(symbols[rune], anchor, r * 1.45, rune == selected ? cyan() : ink());
    }
}

UIImage *BOTWSheikahSettingsArtwork(void) {
    // Public archive sanitization: use a system symbol instead of a game emblem.
    return [[UIImage systemImageNamed:@"gearshape.fill"]
        imageWithTintColor:UIColor.systemTealColor renderingMode:UIImageRenderingModeAlwaysOriginal];
}
