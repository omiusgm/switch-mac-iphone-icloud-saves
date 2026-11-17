#import <UIKit/UIKit.h>

typedef NS_ENUM(NSUInteger, BOTWSheikahControl) {
    BOTWSheikahWeapon, BOTWSheikahShield, BOTWSheikahUp, BOTWSheikahWhistle, BOTWSheikahCrouch,
    BOTWSheikahSlate, BOTWSheikahMap, BOTWSheikahInventory, BOTWSheikahRune, BOTWSheikahThrow,
    BOTWSheikahBow, BOTWSheikahBlock, BOTWSheikahAttack, BOTWSheikahJump, BOTWSheikahSprint,
    BOTWSheikahInteract, BOTWSheikahCancel, BOTWSheikahArrows, BOTWSheikahControlCount
};

typedef struct {
    CGPoint center;
    CGFloat radius;
    CGRect hit;
} BOTWSheikahTarget;

typedef struct {
    BOTWSheikahTarget target[BOTWSheikahControlCount];
    CGPoint stick;
    CGFloat stickRadius, fanInner, fanOuter;
} BOTWSheikahLayout;

BOTWSheikahLayout BOTWSheikahLayoutMake(CGRect area);
BOOL BOTWSheikahVisible(BOTWSheikahControl control, uint64_t buttons, BOOL fanOpen);
BOTWSheikahControl BOTWSheikahHit(BOTWSheikahLayout layout, CGPoint point, uint64_t buttons, BOOL fanOpen);
uint64_t BOTWSheikahButton(BOTWSheikahControl control);
NSString *BOTWSheikahLabel(BOTWSheikahControl control);
int BOTWSheikahFanPick(BOTWSheikahLayout layout, CGPoint point, uint8_t owned);
void BOTWSheikahDrawControl(BOTWSheikahTarget target, BOTWSheikahControl control, UIImage *item, BOOL held);
void BOTWSheikahDrawStick(CGPoint center, CGPoint knob, CGFloat radius, BOOL held);
void BOTWSheikahDrawFan(BOTWSheikahLayout layout, uint8_t owned, int selected, int hovered, NSDictionary<NSNumber *, UIImage *> *runes);
UIImage *BOTWSheikahSettingsArtwork(void);
enum { BOTWSheikahSettingsSize = 44, BOTWSheikahSettingsTop = 4 };
CGRect BOTWSheikahSettingsFrame(CGRect area);

/* Layout records are sparse so untouched controls retain their original anchors and scale. */
enum { BOTWSheikahMove = BOTWSheikahControlCount, BOTWSheikahEditableCount };
typedef NSDictionary<NSString *, NSDictionary<NSString *, NSNumber *> *> BOTWSheikahOverrides;
BOTWSheikahOverrides *BOTWSheikahLoadLayout(NSUserDefaults *defaults);
BOOL BOTWSheikahSaveLayout(NSUserDefaults *defaults, BOTWSheikahOverrides *overrides);
BOTWSheikahLayout BOTWSheikahLayoutApply(CGRect area, BOTWSheikahOverrides *overrides);
BOTWSheikahTarget BOTWSheikahEditTarget(BOTWSheikahLayout layout, NSUInteger index);
NSUInteger BOTWSheikahEditHit(BOTWSheikahLayout layout, CGPoint point);
NSString *BOTWSheikahEditLabel(NSUInteger index);
NSString *BOTWSheikahEditKey(NSUInteger index);
typedef NS_ENUM(NSUInteger, BOTWSheikahLayoutIssue) {
    BOTWSheikahLayoutValid, BOTWSheikahLayoutOverlappingControls,
    BOTWSheikahLayoutUnderEditorPanel, BOTWSheikahLayoutRuneFanClipped, BOTWSheikahLayoutRuneFanOverlap
};
BOTWSheikahLayoutIssue BOTWSheikahValidateLayout(CGRect area, BOTWSheikahOverrides *overrides);
BOOL BOTWSheikahLayoutCanSave(CGRect area, BOTWSheikahOverrides *overrides);
CGRect BOTWSheikahEditorInspectorFrame(CGRect area);
