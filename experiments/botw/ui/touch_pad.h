#import <UIKit/UIKit.h>
#import "BOTWSheikahHUD.h"

enum { BOTWTouchCameraSensitivityDefault = 100 };
FOUNDATION_EXPORT NSInteger BOTWTouchCameraSensitivityNormalize(NSInteger value);

/* On-screen controller for iPhone/iPad, laid out like a Switch controller. It reports its state to the runtime through
   runtime_touch_pad_set (runtime/gamepad.m), which merges it with any physical controller. */
@interface TOTKTouchPad : UIView
@property(nonatomic) BOOL swipeLayout;
// Sheikah only. Classic continues to draw its two existing sticks.
@property(nonatomic) BOOL floatingCameraStick;
// Applies to free touch camera control. Aim buttons and hardware keep their own response.
@property(nonatomic) NSInteger touchCameraSensitivity;
@property(nonatomic) BOOL extraControls;
@property(nonatomic, copy) BOTWSheikahOverrides *sheikahOverrides;
- (NSDictionary<NSNumber *, UIImage *> *)sheikahEditorIcons;
+ (UIImage *)sheikahSettingsArtwork;
- (void)releaseTouches;
@end
