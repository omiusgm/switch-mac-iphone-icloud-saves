#pragma once
#import <UIKit/UIKit.h>
#include "botw_picture.h"

typedef NS_ENUM(NSInteger, BOTWSceneQuality) {
    BOTWSceneQualityFaster, BOTWSceneQualityBalanced, BOTWSceneQualitySharper
};

@protocol BOTWGraphicsSettingsDelegate <NSObject>
- (void)graphicsSetMetalFX:(BOOL)on;
- (void)graphicsSetOutputRows:(long)rows;
- (BOOL)graphicsSetSceneQualityForNextLaunch:(BOTWSceneQuality)quality;
- (BOOL)graphicsSceneQualitySaveWarning;
- (void)settingsSetTouchCameraSensitivity:(NSInteger)percent;
- (void)settingsSetFloatingCameraStick:(BOOL)enabled;
- (void)graphicsSetFormat:(BOTWPictureFormat)format;
- (void)graphicsSetDocked:(BOOL)docked;
- (void)settingsSetSwipeControls:(BOOL)enabled;
- (void)settingsEditSheikahLayout;
- (NSString *)graphicsMetalStatus;
- (void)graphicsSettingsClosed;
- (void)graphicsSettingsDidDismiss;
@optional
- (NSInteger)graphicsDisplayedFPS;
- (BOOL)graphicsSetOverlayMode:(int)mode;
@end

UIColor *BOTWGraphicsPanelBackground(void);

@interface BOTWGraphicsSettings : UIViewController
@property(nonatomic, weak) id<BOTWGraphicsSettingsDelegate> delegate;
@property(nonatomic) int overlayMode;
@property(nonatomic) BOOL overlayForcedOff;
@property(nonatomic) BOOL metalFX;
@property(nonatomic) BOOL metalFXSupported;
@property(nonatomic) long outputRows;
@property(nonatomic) BOOL sceneQualitySupported;
@property(nonatomic) BOTWSceneQuality sceneQualityCurrent, sceneQualityNext;
@property(nonatomic) BOOL sceneQualityRecovered, sceneQualityCommitFailed;
@property(nonatomic) BOOL touchCameraSupported;
@property(nonatomic) BOOL floatingCameraSupported, floatingCameraStick;
@property(nonatomic) NSInteger touchCameraSensitivity;
@property(nonatomic) BOTWPictureFormat format;
@property(nonatomic) BOOL dockedCurrent;
@property(nonatomic) BOOL dockedNext;
@property(nonatomic) BOOL dockedRecovered;
@property(nonatomic) BOOL showsTouchSettings;
@property(nonatomic) BOOL swipeControls;
@end
