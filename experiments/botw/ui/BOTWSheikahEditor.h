#import "BOTWSheikahHUD.h"

@interface BOTWSheikahEditor : UIView
- (instancetype)initWithFrame:(CGRect)frame
                    overrides:(BOTWSheikahOverrides *)overrides
                         icon:(UIImage *(^)(BOTWSheikahControl control))icon
                   completion:(void (^)(BOTWSheikahOverrides *saved))completion;
- (void)showSaveFailure;
@end
