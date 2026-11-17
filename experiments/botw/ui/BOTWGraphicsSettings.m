#import "BOTWGraphicsSettings.h"
#include "fps_overlay.h"
#include <math.h>

static const int overlayModes[] = {HUD_MODE_OFF, HUD_MODE_MINIMAL, HUD_MODE_ALL};

static NSInteger overlaySelection(int mode) {
    if (mode == HUD_MODE_OFF) return 0;
    return mode == HUD_MODE_MINIMAL ? 1 : 2;
}

UIColor *BOTWGraphicsPanelBackground(void) {
    return [UIColor colorWithWhite:0.10 alpha:1];
}

static UILabel *textLabel(NSString *text, UIFontTextStyle style, UIColor *color) {
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = [UIFont preferredFontForTextStyle:style];
    label.textColor = color;
    label.adjustsFontForContentSizeCategory = YES;
    label.numberOfLines = 0;
    return label;
}

static UILabel *detailLabel(NSString *text) {
    return textLabel(text, UIFontTextStyleFootnote, [UIColor colorWithWhite:0.80 alpha:1]);
}

static UIStackView *addSection(UIStackView *stack, NSString *title, UIView *control, UILabel *detail) {
    UILabel *heading = textLabel(title, UIFontTextStyleHeadline, UIColor.whiteColor);
    heading.accessibilityTraits |= UIAccessibilityTraitHeader;
    NSMutableArray *items = [NSMutableArray arrayWithObjects:heading, control, nil];
    if (detail) [items addObject:detail];
    UIStackView *section = [[UIStackView alloc] initWithArrangedSubviews:items];
    section.axis = UILayoutConstraintAxisVertical;
    section.spacing = 8;
    [stack addArrangedSubview:section];
    return section;
}

static UISegmentedControl *choices(NSArray<NSString *> *titles, NSInteger selection, NSString *name,
                                   id target, SEL action) {
    UISegmentedControl *control = [[UISegmentedControl alloc] initWithItems:titles];
    control.selectedSegmentIndex = selection;
    control.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1];
    control.selectedSegmentTintColor = [UIColor colorWithWhite:0.34 alpha:1];
    NSDictionary *ink = @{NSForegroundColorAttributeName: UIColor.whiteColor};
    [control setTitleTextAttributes:ink forState:UIControlStateNormal];
    [control setTitleTextAttributes:ink forState:UIControlStateSelected];
    control.accessibilityLabel = name;
    [control addTarget:target action:action forControlEvents:UIControlEventValueChanged];
    [control.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    return control;
}

static NSArray<NSString *> *qualityNames(void) { return @[@"Экономия", @"Баланс", @"Чётче"]; }
static NSArray<NSString *> *qualityPixels(void) { return @[@"640×360", @"768×432", @"960×540"]; }

static UIStackView *verticalStack(void) {
    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 20;
    return stack;
}

@interface BOTWTouchSensitivitySlider : UISlider
@end

@implementation BOTWTouchSensitivitySlider
- (void)accessibilityIncrement { [self adjustBy:25]; }
- (void)accessibilityDecrement { [self adjustBy:-25]; }
- (void)adjustBy:(float)step {
    self.value = MIN(self.maximumValue, MAX(self.minimumValue, self.value + step));
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}
@end

@implementation BOTWGraphicsSettings {
    UILabel *_metalDetail;
    UILabel *_modeDetail;
    UILabel *_fpsDetail;
    NSTimer *_statusTimer;
    UIButton *_editLayout;
    UIScrollView *_scroll;
    UIStackView *_summary;
    UIStackView *_primaryGraphics;
    UIStackView *_qualityChoices;
    NSArray<UIButton *> *_qualityButtons;
    UILabel *_qualityStatus, *_sensitivityValue, *_scrollHint;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.showsTouchSettings || self.touchCameraSupported ? @"Настройки" : @"Графика";
    self.view.backgroundColor = BOTWGraphicsPanelBackground();
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"Готово" style:UIBarButtonItemStylePlain
                                      target:self action:@selector(done)];
    UIScrollView *scroll = _scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.backgroundColor = BOTWGraphicsPanelBackground();
    scroll.opaque = YES;
    [self.view addSubview:scroll];
    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 20;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-20],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:16],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40]
    ]];

    _summary = verticalStack();
    _summary.spacing = 6;
    _scrollHint = detailLabel(self.touchCameraSupported ? @"Камера и другие настройки ниже" : @"Другие настройки ниже");
    _scrollHint.accessibilityIdentifier = @"settings.scroll.hint";
    _scrollHint.isAccessibilityElement = NO;
    _scrollHint.hidden = YES;
    [_summary addArrangedSubview:_scrollHint];
    [_summary addArrangedSubview:detailLabel(@"Игра продолжается. Кнопки и стики временно отключены.")];
    _fpsDetail = detailLabel(@"");
    [_summary addArrangedSubview:_fpsDetail];
    [stack addArrangedSubview:_summary];
    [self updateFPSDetail];

    UIStackView *scene = verticalStack(), *display = verticalStack();
    if (self.sceneQualitySupported) [self addSceneQualityTo:scene];
    NSInteger outputIndex = self.outputRows == 720 ? 0 : self.outputRows == 1080 ? 1 : self.outputRows == 0 ? 2 : UISegmentedControlNoSegment;
    UISegmentedControl *output = choices(@[@"720p", @"1080p", @"Экран"], outputIndex,
                                         @"Разрешение вывода", self, @selector(outputChanged:));
    output.accessibilityIdentifier = @"settings.output";
    addSection(display, @"Разрешение вывода", output,
               detailLabel(@"Размер готового кадра. Меняется сразу. «Экран» использует разрешение дисплея."));
    _primaryGraphics = verticalStack();
    if (scene.arrangedSubviews.count) [_primaryGraphics addArrangedSubview:scene];
    [_primaryGraphics addArrangedSubview:display];
    [stack addArrangedSubview:_primaryGraphics];

    if (self.touchCameraSupported) {
        BOTWTouchSensitivitySlider *slider = [BOTWTouchSensitivitySlider new];
        slider.minimumValue = 75;
        slider.maximumValue = 200;
        slider.value = self.touchCameraSensitivity >= 75 && self.touchCameraSensitivity <= 200 ? self.touchCameraSensitivity : 100;
        slider.minimumTrackTintColor = [UIColor colorWithRed:.65 green:.82 blue:1 alpha:1];
        slider.accessibilityLabel = @"Скорость экранной камеры";
        slider.accessibilityIdentifier = @"settings.camera.speed";
        slider.accessibilityHint = @"Меняет чувствительность экранной камеры";
        [slider.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
        [slider addTarget:self action:@selector(touchCameraChanged:) forControlEvents:UIControlEventValueChanged];
        _sensitivityValue = textLabel(@"", UIFontTextStyleCallout, UIColor.whiteColor);
        _sensitivityValue.isAccessibilityElement = NO;
        _sensitivityValue.textAlignment = NSTextAlignmentRight;
        [_sensitivityValue setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [_sensitivityValue.widthAnchor constraintGreaterThanOrEqualToConstant:50].active = YES;
        UIStackView *speed = [[UIStackView alloc] initWithArrangedSubviews:@[slider, _sensitivityValue]];
        speed.spacing = 12;
        speed.alignment = UIStackViewAlignmentCenter;
        [self updateSensitivity:slider];
        UIStackView *camera = addSection(stack, @"Скорость камеры", speed,
            detailLabel(@"Чем выше, тем меньше движения пальца нужно для поворота. Предельную скорость задаёт настройка камеры в самой Zelda. Отклик геймпада не меняется."));
        camera.accessibilityIdentifier = @"settings.camera.section";
    }
    if (self.floatingCameraSupported) {
        UISegmentedControl *mode = choices(@[@"Стик", @"Свайпы"], self.floatingCameraStick ? 0 : 1,
                                             @"Способ управления экранной камерой", self, @selector(cameraModeChanged:));
        mode.accessibilityIdentifier = @"settings.camera.mode";
        addSection(stack, @"Камера", mode,
            detailLabel(@"В режиме «Шиика» стик появляется в точке касания и исчезает, когда отпускаете палец."));
    }
    if (self.showsTouchSettings) {
        UISegmentedControl *touch = choices(@[@"Классика", @"Шиика"], self.swipeControls ? 1 : 0,
                                             @"Управление", self, @selector(touchChanged:));
        addSection(stack, @"Управление", touch,
                   detailLabel(@"В режиме «Шиика» двигайся слева и поворачивай камеру справа. Нажми на руну, чтобы использовать её; удерживай для выбора. Лук и бросок можно навести, удерживая кнопку и ведя пальцем."));
        _editLayout = [UIButton buttonWithType:UIButtonTypeSystem];
        UIButtonConfiguration *edit = [UIButtonConfiguration tintedButtonConfiguration];
        edit.title = @"Изменить раскладку";
        edit.image = [UIImage systemImageNamed:@"arrow.up.and.down.and.arrow.left.and.right"];
        edit.imagePadding = 7;
        edit.baseForegroundColor = [UIColor colorWithRed:.65 green:.82 blue:1 alpha:1];
        _editLayout.configuration = edit;
        _editLayout.accessibilityIdentifier = @"sheikah.settings.edit";
        _editLayout.hidden = !self.swipeControls;
        [_editLayout addTarget:self action:@selector(editLayout) forControlEvents:UIControlEventTouchUpInside];
        NSLayoutConstraint *editHeight = [_editLayout.heightAnchor constraintGreaterThanOrEqualToConstant:44];
        editHeight.priority = UILayoutPriorityRequired - 1;
        editHeight.active = YES;
        UIStackView *touchSection = (UIStackView *)stack.arrangedSubviews.lastObject;
        [touchSection insertArrangedSubview:_editLayout atIndex:2];

    }

    BOOL compact = self.traitCollection.userInterfaceIdiom == UIUserInterfaceIdiomPhone &&
                   !UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory);
    UIStackView *left = stack, *right = stack;
    if (compact) {
        left = [UIStackView new]; right = [UIStackView new];
        left.axis = right.axis = UILayoutConstraintAxisVertical;
        left.spacing = right.spacing = stack.spacing;
        UIStackView *columns = [[UIStackView alloc] initWithArrangedSubviews:@[left, right]];
        columns.distribution = UIStackViewDistributionFillEqually;
        columns.alignment = UIStackViewAlignmentTop;
        columns.spacing = 20;
        [stack addArrangedSubview:columns];
    }

    UISegmentedControl *format = choices(@[@"Авто", @"16:9", @"Обрезка"], self.format,
                                         @"Формат экрана", self, @selector(formatChanged:));
    addSection(right, @"Формат экрана", format,
               detailLabel(@"Меняется сразу. «Авто» включает широкую камеру на широком экране. «Обрезка» может скрыть края игрового интерфейса."));

    if ([self.delegate respondsToSelector:@selector(graphicsSetOverlayMode:)]) {
        NSString *title = @"Показатели поверх игры";
        NSInteger selection = self.overlayForcedOff ? UISegmentedControlNoSegment : overlaySelection(self.overlayMode);
        UISegmentedControl *overlay = choices(@[@"Выкл", @"FPS", @"Подробнее"], selection,
                                               title, self, @selector(overlayChanged:));
        overlay.enabled = !self.overlayForcedOff;
        NSString *help = self.overlayForcedOff
            ? @"Строка FPS скрыта параметром запуска. Остальные показатели зависят от настроек запуска."
            : @"«FPS» показывает частоту и разрешение. «Подробнее» добавляет доступные строки диагностики.";
        overlay.accessibilityHint = help;
        addSection(left, title, overlay, detailLabel(help));
    }

    UILabel *metalTitle = textLabel(@"MetalFX", UIFontTextStyleHeadline, UIColor.whiteColor);
    UISwitch *metal = [UISwitch new];
    metal.on = self.metalFX;
    metal.enabled = self.metalFXSupported;
    metal.accessibilityLabel = @"MetalFX";
    [metal setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [metal addTarget:self action:@selector(metalChanged:) forControlEvents:UIControlEventValueChanged];
    UIStackView *metalRow = [[UIStackView alloc] initWithArrangedSubviews:@[metalTitle, metal]];
    metalRow.alignment = UIStackViewAlignmentCenter;
    metalRow.spacing = 12;
    _metalDetail = detailLabel(@"");
    UIStackView *metalSection = [[UIStackView alloc] initWithArrangedSubviews:@[metalRow, _metalDetail]];
    metalSection.axis = UILayoutConstraintAxisVertical;
    metalSection.spacing = 8;
    [left addArrangedSubview:metalSection];
    [self updateMetalDetail];

    UISegmentedControl *mode = choices(@[@"Портативный", @"Стационарный"], self.dockedNext ? 1 : 0,
                                       @"Режим Switch", self, @selector(modeChanged:));
    _modeDetail = detailLabel(@"");
    addSection(right, @"Режим Switch", mode, _modeDetail);
    [self updateModeDetail];
}

- (void)addSceneQualityTo:(UIStackView *)stack {
    NSArray<NSString *> *names = qualityNames(), *pixels = qualityPixels();
    NSMutableArray *buttons = [NSMutableArray new];
    for (NSInteger index = 0; index < (NSInteger)names.count; index++) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        UIButtonConfiguration *config = [UIButtonConfiguration plainButtonConfiguration];
        config.title = names[index];
        config.subtitle = pixels[index];
        config.titleAlignment = UIButtonConfigurationTitleAlignmentCenter;
        config.titlePadding = 2;
        config.contentInsets = NSDirectionalEdgeInsetsMake(6, 4, 6, 4);
        config.baseForegroundColor = UIColor.whiteColor;
        config.cornerStyle = UIButtonConfigurationCornerStyleMedium;
        button.configuration = config;
        button.tag = index;
        button.accessibilityLabel = names[index];
        button.accessibilityHint = @"Качество 3D применяется после полного перезапуска";
        button.accessibilityIdentifier = [NSString stringWithFormat:@"settings.quality.%ld", (long)index];
        [button addTarget:self action:@selector(sceneQualityChanged:) forControlEvents:UIControlEventTouchUpInside];
        [button.heightAnchor constraintGreaterThanOrEqualToConstant:48].active = YES;
        [buttons addObject:button];
    }
    _qualityButtons = buttons.copy;
    _qualityChoices = [[UIStackView alloc] initWithArrangedSubviews:_qualityButtons];
    _qualityChoices.distribution = UIStackViewDistributionFillEqually;
    _qualityChoices.spacing = 3;
    _qualityChoices.layer.cornerRadius = 10;
    _qualityChoices.backgroundColor = [UIColor colorWithWhite:.18 alpha:1];
    _qualityStatus = detailLabel(@"");
    _qualityStatus.accessibilityIdentifier = @"settings.quality.status";
    addSection(stack, @"Качество 3D", _qualityChoices, _qualityStatus);
    [self updateSceneQuality];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // Measure the natural content height without the hint so the hint itself
    // cannot make a previously fitting panel scroll.
    CGFloat viewportHeight = CGRectGetHeight(_scroll.bounds);
    CGFloat contentHeight = _scroll.contentSize.height;
    if (!_scrollHint.hidden) contentHeight -= CGRectGetHeight(_scrollHint.bounds) + _summary.spacing;
    _scrollHint.hidden = !(viewportHeight > 0 && contentHeight > viewportHeight + .5);
    CGFloat width = CGRectGetWidth(_scroll.bounds) - 40;
    BOOL accessibility = UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory);
    BOOL sideBySide = width >= 560 && !accessibility;
    _primaryGraphics.axis = sideBySide ? UILayoutConstraintAxisHorizontal : UILayoutConstraintAxisVertical;
    _primaryGraphics.distribution = sideBySide ? UIStackViewDistributionFillEqually : UIStackViewDistributionFill;
    _primaryGraphics.alignment = sideBySide ? UIStackViewAlignmentTop : UIStackViewAlignmentFill;
    CGFloat qualityWidth = sideBySide ? (width - _primaryGraphics.spacing) / 2 : width;
    _qualityChoices.axis = qualityWidth < 280 || accessibility ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
}

- (void)updateSceneQuality {
    NSArray<NSString *> *names = qualityNames(), *pixels = qualityPixels();
    NSInteger current = self.sceneQualityCurrent, next = self.sceneQualityNext;
    if (current < 0 || current >= (NSInteger)names.count) current = BOTWSceneQualitySharper;
    if (next < 0 || next >= (NSInteger)names.count) next = current;
    for (UIButton *button in _qualityButtons) {
        BOOL selected = button.tag == next;
        UIButtonConfiguration *config = button.configuration;
        config.background.backgroundColor = [UIColor colorWithWhite:selected ? .34 : .18 alpha:1];
        button.configuration = config;
        button.accessibilityValue = [NSString stringWithFormat:@"%@%@", pixels[button.tag],
            button.tag == current && !self.dockedCurrent ? @", сейчас" :
            (selected ? (self.dockedNext ? @", для портативного режима" : @", после перезапуска") : @"")];
        if (selected) button.accessibilityTraits |= UIAccessibilityTraitSelected;
        else button.accessibilityTraits &= ~UIAccessibilityTraitSelected;
    }
    NSString *selectedPreset = [NSString stringWithFormat:@"«%@» · %@", names[next], pixels[next]];
    NSString *selectedStatus = @"Для смены полностью перезапустите игру.";
    if (self.dockedNext) {
        selectedStatus = [NSString stringWithFormat:@"Выбор сохранён для портативного режима — %@. Стационарный режим использует своё разрешение.", selectedPreset];
    } else if (self.dockedCurrent || current != next) {
        selectedStatus = [NSString stringWithFormat:@"После полного перезапуска в портативном режиме — %@. Полностью закройте игру и откройте её снова.", selectedPreset];
    }
    NSString *active = self.dockedCurrent ? @"Сейчас стационарный режим использует своё разрешение."
        : [NSString stringWithFormat:@"Сейчас «%@» · %@", names[current], pixels[current]];
    _qualityStatus.text = [NSString stringWithFormat:@"Размер 3D-сцены в портативном режиме.\n%@\n%@", active, selectedStatus];
    if (self.sceneQualityRecovered)
        _qualityStatus.text = [_qualityStatus.text stringByAppendingString:@"\nПосле незавершённого запуска восстановлено последнее рабочее качество."];
    if (self.sceneQualityCommitFailed)
        _qualityStatus.text = [_qualityStatus.text stringByAppendingString:@"\nНе удалось сохранить данные запуска. Для следующего запуска выберите качество ещё раз."];
}

- (void)sceneQualityChanged:(UIButton *)button {
    BOTWSceneQuality quality = (BOTWSceneQuality)button.tag;
    BOOL saved = [self.delegate graphicsSetSceneQualityForNextLaunch:quality];
    if (saved) {
        self.sceneQualityNext = quality;
        self.sceneQualityCommitFailed = [self.delegate graphicsSceneQualitySaveWarning];
    }
    [self updateSceneQuality];
    if (!saved) {
        NSString *message = @"Качество не сохранилось. Нажмите на вариант ещё раз.";
        _qualityStatus.text = [_qualityStatus.text stringByAppendingFormat:@"\n%@", message];
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, message);
    }
}

- (void)updateSensitivity:(UISlider *)slider {
    NSString *value = [NSString stringWithFormat:@"%ld%%", (long)lroundf(slider.value)];
    _sensitivityValue.text = value;
    slider.accessibilityValue = value;
}

- (void)touchCameraChanged:(UISlider *)slider {
    NSInteger percent = lroundf(slider.value / 25) * 25;
    slider.value = percent;
    self.touchCameraSensitivity = percent;
    [self updateSensitivity:slider];
    [self.delegate settingsSetTouchCameraSensitivity:percent];
}

- (void)cameraModeChanged:(UISegmentedControl *)control {
    self.floatingCameraStick = control.selectedSegmentIndex == 0;
    [self.delegate settingsSetFloatingCameraStick:self.floatingCameraStick];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self updateMetalDetail];
    __weak typeof(self) weakSelf = self;
    [self updateFPSDetail];
    _statusTimer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
        [weakSelf updateMetalDetail];
        [weakSelf updateFPSDetail];
    }];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [_statusTimer invalidate];
    _statusTimer = nil;
    if (self.isBeingDismissed || self.navigationController.isBeingDismissed)
        [self.delegate graphicsSettingsDidDismiss];
}

- (void)updateMetalDetail {
    NSString *detail = self.metalFXSupported ? [self.delegate graphicsMetalStatus]
                                             : @"Устройство не поддерживает этот вариант MetalFX.";
    if (![_metalDetail.text isEqualToString:detail]) _metalDetail.text = detail;
}

- (void)updateFPSDetail {
    id<BOTWGraphicsSettingsDelegate> delegate = self.delegate;
    NSInteger fps = [delegate respondsToSelector:@selector(graphicsDisplayedFPS)] ? [delegate graphicsDisplayedFPS] : -1;
    NSString *detail = fps > 0
        ? [NSString stringWithFormat:@"На экране %ld FPS.", (long)fps]
        : @"Пока нет замера FPS.";
    if (![_fpsDetail.text isEqualToString:detail]) _fpsDetail.text = detail;
}

- (void)updateModeDetail {
    NSString *current = self.dockedCurrent ? @"Сейчас стационарный." : @"Сейчас портативный.";
    NSString *restart = self.dockedNext == self.dockedCurrent
        ? @"Смена режима требует перезапуска."
        : @"Сохрани игру, полностью закрой приложение и открой снова.";
    NSString *recovery = self.dockedRecovered ? @" После незавершённого запуска восстановлен портативный режим." : @"";
    _modeDetail.text = [NSString stringWithFormat:@"%@ %@ Стационарный режим экспериментальный и может сильнее нагружать устройство.%@",
                        current, restart, recovery];
}

- (void)overlayChanged:(UISegmentedControl *)control {
    NSInteger selected = control.selectedSegmentIndex;
    id<BOTWGraphicsSettingsDelegate> delegate = self.delegate;
    if (!self.overlayForcedOff && selected >= 0 && selected < (NSInteger)(sizeof overlayModes / sizeof overlayModes[0]) &&
        [delegate respondsToSelector:@selector(graphicsSetOverlayMode:)] &&
        [delegate graphicsSetOverlayMode:overlayModes[selected]]) {
        self.overlayMode = overlayModes[selected];
    } else {
        control.selectedSegmentIndex = self.overlayForcedOff ? UISegmentedControlNoSegment : overlaySelection(self.overlayMode);
    }
}

- (void)metalChanged:(UISwitch *)control {
    [self.delegate graphicsSetMetalFX:control.on];
    [self updateMetalDetail];
}

- (void)outputChanged:(UISegmentedControl *)control {
    static const long rows[] = {720, 1080, 0};
    [self.delegate graphicsSetOutputRows:rows[control.selectedSegmentIndex]];
}

- (void)formatChanged:(UISegmentedControl *)control {
    [self.delegate graphicsSetFormat:(BOTWPictureFormat)control.selectedSegmentIndex];
}

- (void)modeChanged:(UISegmentedControl *)control {
    self.dockedNext = control.selectedSegmentIndex == 1;
    [self.delegate graphicsSetDocked:self.dockedNext];
    [self updateModeDetail];
    if (self.sceneQualitySupported) [self updateSceneQuality];
}

- (void)touchChanged:(UISegmentedControl *)control {
    self.swipeControls = control.selectedSegmentIndex == 1;
    _editLayout.hidden = !self.swipeControls;
    [self.delegate settingsSetSwipeControls:self.swipeControls];
}

- (void)editLayout { [self.delegate settingsEditSheikahLayout]; }

- (void)done {
    [self.delegate graphicsSettingsClosed];
}

@end
