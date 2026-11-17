#import "BOTWSheikahEditor.h"
#include <math.h>

@interface BOTWSheikahEditorElement : UIAccessibilityElement
@property(nonatomic, copy) void (^selectControl)(void);
@end

@implementation BOTWSheikahEditorElement
- (BOOL)accessibilityActivate {
    if (!self.selectControl) return NO;
    self.selectControl();
    return YES;
}
@end

@implementation BOTWSheikahEditor {
    NSMutableDictionary<NSString *, NSDictionary<NSString *, NSNumber *> *> *_draft;
    UIImage *(^_icon)(BOTWSheikahControl);
    void (^_completion)(BOTWSheikahOverrides *);
    UIView *_toolbar, *_inspector;
    UILabel *_title, *_status, *_selectedLabel, *_scale;
    NSLayoutConstraint *_actionsWidth, *_accessibleActionsWidth;
    BOOL _largeType, _saveFailed;
    UIButton *_save, *_cancel, *_reset, *_smaller, *_bigger;
    NSUInteger _selected;
    UITouch *_tracking;
    CGPoint _grabOffset, _grabPoint;
    CGRect _grabArea;
    BOOL _dragging;
}

static UIColor *panelColor(void) {
    return [UIColor colorWithRed:.06 green:.10 blue:.12 alpha:.94];
}

static UIColor *accentColor(void) {
    return [UIColor colorWithRed:.63 green:.94 blue:.98 alpha:1];
}

static UIFont *editorFont(UIFontTextStyle style, UITraitCollection *traits, CGFloat maximumSize) {
    UIFont *font = [UIFont preferredFontForTextStyle:style compatibleWithTraitCollection:traits];
    return font.pointSize > maximumSize ? [font fontWithSize:maximumSize] : font;
}

static UILabel *editorLabel(NSString *text, UIFontTextStyle style) {
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = [UIFont preferredFontForTextStyle:style];
    label.adjustsFontForContentSizeCategory = YES;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = .75;
    label.textColor = UIColor.whiteColor;
    return label;
}

static UIView *editorPanel(void) {
    UIView *panel = [UIView new];
    panel.backgroundColor = panelColor();
    panel.layer.cornerRadius = 12;
    return panel;
}

- (UIButton *)button:(NSString *)title icon:(NSString *)icon action:(SEL)action id:(NSString *)identifier {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *config = [UIButtonConfiguration plainButtonConfiguration];
    config.title = title;
    config.image = icon ? [UIImage systemImageNamed:icon] : nil;
    config.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleCallout
                                                                                                 scale:UIImageSymbolScaleSmall];
    config.baseForegroundColor = UIColor.whiteColor;
    config.contentInsets = NSDirectionalEdgeInsetsMake(0, 9, 0, 9);
    config.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
        NSMutableDictionary *style = [attributes mutableCopy];
        style[NSFontAttributeName] = editorFont(UIFontTextStyleCallout, nil, 27);
        return style;
    };
    button.configuration = config;
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = .7;
    button.accessibilityIdentifier = identifier;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (instancetype)initWithFrame:(CGRect)frame
                    overrides:(BOTWSheikahOverrides *)overrides
                         icon:(UIImage *(^)(BOTWSheikahControl))icon
                   completion:(void (^)(BOTWSheikahOverrides *))completion {
    if ((self = [super initWithFrame:frame])) {
        self.opaque = NO;
        self.backgroundColor = UIColor.clearColor;
        self.contentMode = UIViewContentModeRedraw;
        self.accessibilityViewIsModal = YES;
        self.accessibilityIdentifier = @"sheikah.editor";
        _draft = [overrides mutableCopy] ?: [NSMutableDictionary new];
        _icon = [icon copy];
        _completion = [completion copy];
        _selected = BOTWSheikahEditableCount;

        _toolbar = editorPanel();
        [self addSubview:_toolbar];
        _title = editorLabel(@"Раскладка «Шиика»", UIFontTextStyleHeadline);
        _title.accessibilityTraits = UIAccessibilityTraitHeader;
        _title.adjustsFontForContentSizeCategory = NO;
        _status = editorLabel(@"Перетащите кнопку", UIFontTextStyleCaption1);
        _status.adjustsFontForContentSizeCategory = NO;
        _status.accessibilityIdentifier = @"sheikah.editor.status";
        UIStackView *heading = [[UIStackView alloc] initWithArrangedSubviews:@[_title, _status]];
        heading.axis = UILayoutConstraintAxisVertical;
        heading.spacing = 1;
        heading.translatesAutoresizingMaskIntoConstraints = NO;
        [heading setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
        [_toolbar addSubview:heading];

        _cancel = [self button:@"Отмена" icon:nil action:@selector(cancel) id:@"sheikah.editor.cancel"];
        _reset = [self button:@"Стандарт" icon:nil action:@selector(reset) id:@"sheikah.editor.reset"];
        _reset.accessibilityLabel = @"Стандартная раскладка";
        _save = [self button:@"Сохранить" icon:nil action:@selector(save) id:@"sheikah.editor.save"];
        UIButtonConfiguration *saveConfig = _save.configuration;
        saveConfig.baseForegroundColor = accentColor();
        _save.configuration = saveConfig;
        UIStackView *actions = [[UIStackView alloc] initWithArrangedSubviews:@[_cancel, _reset, _save]];
        actions.spacing = 1;
        actions.distribution = UIStackViewDistributionFillEqually;
        actions.translatesAutoresizingMaskIntoConstraints = NO;
        [_toolbar addSubview:actions];
        _actionsWidth = [actions.widthAnchor constraintEqualToAnchor:_toolbar.widthAnchor multiplier:.71];
        _accessibleActionsWidth = [actions.widthAnchor constraintEqualToAnchor:_toolbar.widthAnchor multiplier:.63];
        [NSLayoutConstraint activateConstraints:@[
            [heading.leadingAnchor constraintEqualToAnchor:_toolbar.leadingAnchor constant:12],
            [heading.centerYAnchor constraintEqualToAnchor:_toolbar.centerYAnchor],
            [heading.heightAnchor constraintLessThanOrEqualToAnchor:_toolbar.heightAnchor constant:-2],
            [heading.trailingAnchor constraintEqualToAnchor:actions.leadingAnchor constant:-6],
            [actions.trailingAnchor constraintEqualToAnchor:_toolbar.trailingAnchor constant:-4],
            _actionsWidth,
            [actions.topAnchor constraintEqualToAnchor:_toolbar.topAnchor],
            [actions.bottomAnchor constraintEqualToAnchor:_toolbar.bottomAnchor],
            [_cancel.widthAnchor constraintGreaterThanOrEqualToConstant:44],
            [_reset.widthAnchor constraintGreaterThanOrEqualToConstant:44],
            [_save.widthAnchor constraintGreaterThanOrEqualToConstant:44]
        ]];

        _inspector = editorPanel();
        [self addSubview:_inspector];
        _selectedLabel = editorLabel(@"Выберите кнопку", UIFontTextStyleCallout);
        _scale = editorLabel(@"", UIFontTextStyleFootnote);
        _scale.textAlignment = NSTextAlignmentCenter;
        _scale.accessibilityIdentifier = @"sheikah.editor.scale";
        _smaller = [self button:nil icon:@"minus" action:@selector(shrink) id:@"sheikah.editor.smaller"];
        _smaller.accessibilityLabel = @"Уменьшить кнопку";
        _bigger = [self button:nil icon:@"plus" action:@selector(grow) id:@"sheikah.editor.bigger"];
        _bigger.accessibilityLabel = @"Увеличить кнопку";
        UIStackView *inspectorContent = [[UIStackView alloc] initWithArrangedSubviews:@[_selectedLabel, _smaller, _scale, _bigger]];
        inspectorContent.translatesAutoresizingMaskIntoConstraints = NO;
        [_inspector addSubview:inspectorContent];
        [NSLayoutConstraint activateConstraints:@[
            [inspectorContent.leadingAnchor constraintEqualToAnchor:_inspector.leadingAnchor constant:12],
            [inspectorContent.trailingAnchor constraintEqualToAnchor:_inspector.trailingAnchor constant:-3],
            [inspectorContent.topAnchor constraintEqualToAnchor:_inspector.topAnchor constant:2],
            [inspectorContent.bottomAnchor constraintEqualToAnchor:_inspector.bottomAnchor constant:-2],
            [_smaller.widthAnchor constraintEqualToConstant:44],
            [_bigger.widthAnchor constraintEqualToConstant:44],
            [_scale.widthAnchor constraintGreaterThanOrEqualToConstant:49],
            [_scale.widthAnchor constraintLessThanOrEqualToConstant:65]
        ]];
        [self registerForTraitChanges:@[UITraitPreferredContentSizeCategory.class] withAction:@selector(setNeedsLayout)];
        [self updateControls];
    }
    return self;
}

- (CGRect)area { return UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets); }

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect area = self.area;
    _toolbar.frame = CGRectMake(CGRectGetMinX(area) + 6, CGRectGetMinY(area) + 6, MAX(0, CGRectGetWidth(area) - 12), 46);
    _inspector.frame = BOTWSheikahEditorInspectorFrame(area);
    BOOL largeType = UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory);
    if (_largeType != largeType) {
        _largeType = largeType;
        (_largeType ? _actionsWidth : _accessibleActionsWidth).active = NO;
        (_largeType ? _accessibleActionsWidth : _actionsWidth).active = YES;
    }
    _title.font = editorFont(UIFontTextStyleHeadline, self.traitCollection, 26);
    _status.font = editorFont(_largeType ? UIFontTextStyleCallout : UIFontTextStyleCaption1, self.traitCollection, 24);
    [self updateControls];
}

- (void)safeAreaInsetsDidChange {
    [super safeAreaInsetsDidChange];
    [self setNeedsLayout];
}

- (double)selectedScale {
    if (_selected >= BOTWSheikahEditableCount) return 1;
    return [_draft[BOTWSheikahEditKey(_selected)][@"scale"] doubleValue] ?: 1;
}

- (void)updateControls {
    BOOL selected = _selected < BOTWSheikahEditableCount;
    CGFloat scale = self.selectedScale;
    _selectedLabel.text = selected ? BOTWSheikahEditLabel(_selected) : @"Выберите кнопку";
    _scale.text = selected ? [NSString stringWithFormat:@"%ld%%", lround(scale * 100)] : @"";
    _smaller.enabled = selected && scale > .5;
    _bigger.enabled = selected && scale < 2;
    BOTWSheikahLayoutIssue issue = BOTWSheikahValidateLayout(self.area, _draft);
    BOOL valid = issue == BOTWSheikahLayoutValid;
    BOOL hasMessage = !valid || _saveFailed;
    _save.enabled = valid;
    _title.hidden = _largeType && hasMessage;
    _status.hidden = _largeType && !hasMessage;
    switch (issue) {
        case BOTWSheikahLayoutValid: _status.text = _saveFailed ? @"Не удалось сохранить" : @"Перетащите кнопку"; break;
        case BOTWSheikahLayoutOverlappingControls: _status.text = @"Кнопки перекрываются"; break;
        case BOTWSheikahLayoutUnderEditorPanel: _status.text = @"Кнопка заходит на панель"; break;
        case BOTWSheikahLayoutRuneFanClipped: _status.text = @"Мало места для рун"; break;
        case BOTWSheikahLayoutRuneFanOverlap: _status.text = @"Веер закрывает кнопку"; break;
    }
    _status.textColor = hasMessage ? [UIColor colorWithRed:1 green:.83 blue:.48 alpha:1]
                                   : [UIColor colorWithRed:.74 green:.86 blue:.89 alpha:1];
    self.accessibilityHint = @"Перетащите кнопку, чтобы переместить её";
    [self setNeedsDisplay];
}

- (void)selectAtPoint:(CGPoint)point {
    _selected = BOTWSheikahEditHit(BOTWSheikahLayoutApply(self.area, _draft), point);
    [self updateControls];
}

- (void)moveSelectionTo:(CGPoint)point {
    if (_selected >= BOTWSheikahEditableCount || CGRectIsEmpty(self.area)) return;
    CGRect area = self.area;
    NSString *key = BOTWSheikahEditKey(_selected);
    NSMutableDictionary *entry = [_draft[key] mutableCopy] ?: [NSMutableDictionary new];
    entry[@"x"] = @(MIN(1, MAX(0, (point.x - CGRectGetMinX(area)) / CGRectGetWidth(area))));
    entry[@"y"] = @(MIN(1, MAX(0, (point.y - CGRectGetMinY(area)) / CGRectGetHeight(area))));
    _draft[key] = entry.copy;
    _saveFailed = NO;
    [self updateControls];
}

- (void)resizeSelectionBy:(NSInteger)step {
    if (_selected >= BOTWSheikahEditableCount) return;
    NSString *key = BOTWSheikahEditKey(_selected);
    NSMutableDictionary *entry = [_draft[key] mutableCopy] ?: [NSMutableDictionary new];
    NSInteger scale = MIN(20, MAX(5, lround(self.selectedScale * 10) + step));
    if (scale == 10) [entry removeObjectForKey:@"scale"];
    else entry[@"scale"] = @(scale / 10.0);
    _draft[key] = entry.count ? entry.copy : nil;
    _saveFailed = NO;
    [self updateControls];
}

- (void)shrink { [self resizeSelectionBy:-1]; }
- (void)grow { [self resizeSelectionBy:1]; }

- (void)reset {
    [_draft removeAllObjects];
    _saveFailed = NO;
    [self updateControls];
}

- (void)save {
    if (BOTWSheikahLayoutCanSave(self.area, _draft) && _completion) _completion(_draft.copy);
}

- (void)showSaveFailure {
    _saveFailed = YES;
    [self updateControls];
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, _status.text);
}

- (void)cancel { if (_completion) _completion(nil); }

- (BOOL)accessibilityPerformEscape {
    [self cancel];
    return YES;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    if (_tracking) return;
    _tracking = touches.anyObject;
    _grabPoint = [_tracking locationInView:self];
    _grabArea = self.area;
    _dragging = NO;
    [self selectAtPoint:_grabPoint];
    if (_selected < BOTWSheikahEditableCount) {
        CGPoint center = BOTWSheikahEditTarget(BOTWSheikahLayoutApply(self.area, _draft), _selected).center;
        _grabOffset = CGPointMake(center.x - _grabPoint.x, center.y - _grabPoint.y);
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    if (!_tracking || ![touches containsObject:_tracking] || !CGRectEqualToRect(self.area, _grabArea)) return;
    CGPoint point = [_tracking locationInView:self];
    if (!_dragging && hypot(point.x - _grabPoint.x, point.y - _grabPoint.y) < 3) return;
    _dragging = YES;
    [self moveSelectionTo:CGPointMake(point.x + _grabOffset.x, point.y + _grabOffset.y)];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    if (_tracking && [touches containsObject:_tracking]) _tracking = nil;
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self touchesEnded:touches withEvent:event];
}

- (NSArray *)accessibilityElements {
    NSMutableArray *elements = [NSMutableArray arrayWithObjects:_toolbar, nil];
    BOTWSheikahLayout layout = BOTWSheikahLayoutApply(self.area, _draft);
    __weak typeof(self) weakSelf = self;
    for (NSUInteger i = 0; i < BOTWSheikahEditableCount; i++) {
        BOTWSheikahEditorElement *element = [[BOTWSheikahEditorElement alloc] initWithAccessibilityContainer:self];
        element.accessibilityLabel = BOTWSheikahEditLabel(i);
        element.accessibilityIdentifier = [@"sheikah.editor.control." stringByAppendingString:BOTWSheikahEditKey(i)];
        element.accessibilityTraits = UIAccessibilityTraitButton | (i == _selected ? UIAccessibilityTraitSelected : 0);
        element.accessibilityFrameInContainerSpace = BOTWSheikahEditTarget(layout, i).hit;
        element.selectControl = ^{
            BOTWSheikahEditor *editor = weakSelf;
            if (!editor) return;
            editor->_selected = i;
            [editor updateControls];
        };
        NSArray *names = @[@"Сдвинуть влево", @"Сдвинуть вправо", @"Сдвинуть вверх", @"Сдвинуть вниз"];
        const CGFloat deltas[4][2] = {{-12, 0}, {12, 0}, {0, -12}, {0, 12}};
        NSMutableArray *actions = [NSMutableArray new];
        for (NSUInteger j = 0; j < names.count; j++) {
            CGPoint delta = CGPointMake(deltas[j][0], deltas[j][1]);
            [actions addObject:[[UIAccessibilityCustomAction alloc] initWithName:names[j]
                actionHandler:^BOOL(UIAccessibilityCustomAction *action) {
                    BOTWSheikahEditor *editor = weakSelf;
                    if (!editor) return NO;
                    editor->_selected = i;
                    BOTWSheikahLayout draft = BOTWSheikahLayoutApply(editor.area, editor->_draft);
                    CGPoint center = BOTWSheikahEditTarget(draft, i).center;
                    [editor moveSelectionTo:CGPointMake(center.x + delta.x, center.y + delta.y)];
                    return YES;
                }]];
        }
        element.accessibilityCustomActions = actions;
        [elements addObject:element];
    }
    [elements addObject:_inspector];
    return elements;
}

- (void)drawRect:(CGRect)rect {
    [[UIColor colorWithWhite:0 alpha:.30] setFill];
    UIRectFillUsingBlendMode(rect, kCGBlendModeNormal);
    CGRect area = self.area;
    if (CGRectIsEmpty(area)) return;
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextSaveGState(context);
    CGContextClipToRect(context, area);
    BOTWSheikahLayout layout = BOTWSheikahLayoutApply(area, _draft);
    for (BOTWSheikahControl i = 0; i < BOTWSheikahControlCount; i++) {
        BOTWSheikahDrawControl(layout.target[i], i, _icon ? _icon(i) : nil, NO);
    }
    BOTWSheikahDrawStick(layout.stick, layout.stick, layout.stickRadius, NO);
    if (_selected < BOTWSheikahEditableCount) {
        BOTWSheikahTarget target = BOTWSheikahEditTarget(layout, _selected);
        CGFloat radius = MAX(target.radius * 1.12, 21);
        UIBezierPath *ring = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(target.center.x - radius,
                                 target.center.y - radius, radius * 2, radius * 2)];
        ring.lineWidth = 2;
        [[UIColor colorWithRed:236/255.0 green:194/255.0 blue:84/255.0 alpha:1] setStroke];
        [ring stroke];
    }
    CGContextRestoreGState(context);
}
@end
