// NotchTodo: a todo list that lives in the MacBook notch.
// Hover the notch to open it; move the mouse away, press Esc, or click elsewhere to close it.
// Plain Objective-C + AppKit so it builds with clang alone (no Xcode or Swift toolchain needed).

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <ServiceManagement/ServiceManagement.h>

static const CGFloat kOpenWidth = 420;
static const CGFloat kTopRadius = 12;
static const CGFloat kBottomRadius = 24;
static const CGFloat kInset = 14;
static const CGFloat kGap = 8;
static const CGFloat kInputHeight = 34;
static const CGFloat kRowHeight = 30;
static const CGFloat kBottomPadding = 12;
static const NSInteger kMaxVisibleRows = 9;
static const CGFloat kShadowPad = 24;

static NSTextField *MakeLabel(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    label.maximumNumberOfLines = 1;
    [label sizeToFit];
    return label;
}

static NSImage *Symbol(NSString *name, CGFloat size, NSFontWeight weight) {
    NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration configurationWithPointSize:size weight:weight];
    return [[NSImage imageWithSystemSymbolName:name accessibilityDescription:nil] imageWithSymbolConfiguration:config];
}

// Flush with the top of the screen, flared top corners, rounded bottom corners (y-up coordinates).
static CGPathRef CreateNotchPath(CGRect bounds, CGFloat centerX, CGFloat width, CGFloat height, CGFloat t, CGFloat b) {
    CGFloat top = CGRectGetMaxY(bounds), bottom = top - height;
    CGFloat left = centerX - width / 2, right = left + width;
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, left, top);
    CGPathAddQuadCurveToPoint(p, NULL, left + t, top, left + t, top - t);
    CGPathAddLineToPoint(p, NULL, left + t, bottom + b);
    CGPathAddQuadCurveToPoint(p, NULL, left + t, bottom, left + t + b, bottom);
    CGPathAddLineToPoint(p, NULL, right - t - b, bottom);
    CGPathAddQuadCurveToPoint(p, NULL, right - t, bottom, right - t, bottom + b);
    CGPathAddLineToPoint(p, NULL, right - t, top - t);
    CGPathAddQuadCurveToPoint(p, NULL, right - t, top, right, top);
    CGPathCloseSubpath(p);
    return p;
}

#pragma mark - Storage

@interface Todo : NSObject
@property (copy) NSString *identifier;
@property (copy) NSString *title;
@property BOOL done;
@end

@implementation Todo
@end

@interface TodoStore : NSObject
@property (copy) void (^onChange)(void);
@property (readonly) NSArray<Todo *> *sorted;
@property (readonly) NSInteger count;
@property (readonly) NSInteger openCount;
@property (readonly) BOOL hasDone;
- (void)add:(NSString *)title;
- (void)toggle:(Todo *)todo;
- (void)remove:(Todo *)todo;
- (void)clearDone;
@end

@implementation TodoStore {
    NSMutableArray<Todo *> *_items;
    NSURL *_url;
}

- (instancetype)init {
    if ((self = [super init])) {
        NSString *override = NSProcessInfo.processInfo.environment[@"NOTCHTODO_FILE"];
        if (override.length) {
            _url = [NSURL fileURLWithPath:override.stringByExpandingTildeInPath];
        } else {
            NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
            _url = [[support URLByAppendingPathComponent:@"NotchTodo" isDirectory:YES] URLByAppendingPathComponent:@"todos.json"];
        }
        _items = [NSMutableArray array];
        NSData *data = [NSData dataWithContentsOfURL:_url];
        NSArray *saved = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if ([saved isKindOfClass:NSArray.class]) {
            for (NSDictionary *entry in saved) {
                if (![entry isKindOfClass:NSDictionary.class] || ![entry[@"title"] isKindOfClass:NSString.class]) continue;
                Todo *todo = [Todo new];
                todo.identifier = [entry[@"id"] isKindOfClass:NSString.class] ? entry[@"id"] : NSUUID.UUID.UUIDString;
                todo.title = entry[@"title"];
                todo.done = [entry[@"done"] boolValue];
                [_items addObject:todo];
            }
        }
    }
    return self;
}

// Open tasks first (newest on top), finished ones sink to the bottom.
- (NSArray<Todo *> *)sorted {
    NSMutableArray *open = [NSMutableArray array], *done = [NSMutableArray array];
    for (Todo *todo in _items) [(todo.done ? done : open) addObject:todo];
    return [open arrayByAddingObjectsFromArray:done];
}

- (NSInteger)count { return _items.count; }

- (NSInteger)openCount {
    NSInteger n = 0;
    for (Todo *todo in _items) if (!todo.done) n++;
    return n;
}

- (BOOL)hasDone { return self.openCount < self.count; }

- (void)add:(NSString *)title {
    NSString *trimmed = [title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length) return;
    Todo *todo = [Todo new];
    todo.identifier = NSUUID.UUID.UUIDString;
    todo.title = trimmed;
    [_items insertObject:todo atIndex:0];
    [self save];
}

- (void)toggle:(Todo *)todo {
    todo.done = !todo.done;
    [self save];
}

- (void)remove:(Todo *)todo {
    [_items removeObject:todo];
    [self save];
}

- (void)clearDone {
    [_items filterUsingPredicate:[NSPredicate predicateWithFormat:@"done == NO"]];
    [self save];
}

- (void)save {
    NSMutableArray *out = [NSMutableArray array];
    for (Todo *todo in _items) [out addObject:@{@"id": todo.identifier, @"title": todo.title, @"done": @(todo.done)}];
    [NSFileManager.defaultManager createDirectoryAtURL:_url.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingPrettyPrinted error:nil] writeToURL:_url atomically:YES];
    if (self.onChange) self.onChange();
}

@end

#pragma mark - Views

@interface NotchPanel : NSPanel
@end

@implementation NotchPanel

- (instancetype)init {
    self = [super initWithContentRect:NSZeroRect
                            styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                              backing:NSBackingStoreBuffered
                                defer:NO];
    if (self) {
        self.opaque = NO;
        self.backgroundColor = NSColor.clearColor;
        self.hasShadow = NO;
        self.movable = NO;
        self.releasedWhenClosed = NO;
        self.hidesOnDeactivate = NO;
        self.acceptsMouseMovedEvents = YES;
        self.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        self.level = NSMainMenuWindowLevel + 3;
        self.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary
            | NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorIgnoresCycle;
    }
    return self;
}

- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return NO; }

// Borderless windows still get pushed below the menu bar unless we opt out.
- (NSRect)constrainFrameRect:(NSRect)frameRect toScreen:(NSScreen *)screen { return frameRect; }

@end

@interface FlippedView : NSView
@end

@implementation FlippedView
- (BOOL)isFlipped { return YES; }
@end

@interface ContainerView : NSView
@property (copy) void (^onMouseDown)(void);
@end

@implementation ContainerView
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (void)mouseDown:(NSEvent *)event { if (self.onMouseDown) self.onMouseDown(); }
@end

// The black notch body, backed directly by a CAShapeLayer so its path can spring open and closed.
@interface ShapeView : NSView
@property (readonly) CAShapeLayer *shape;
@end

@implementation ShapeView

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) self.wantsLayer = YES;
    return self;
}

- (CALayer *)makeBackingLayer {
    CAShapeLayer *layer = [CAShapeLayer layer];
    layer.fillColor = NSColor.blackColor.CGColor;
    layer.shadowColor = NSColor.blackColor.CGColor;
    layer.shadowOffset = CGSizeMake(0, -6);
    layer.shadowRadius = 14;
    layer.shadowOpacity = 0;
    return layer;
}

- (CAShapeLayer *)shape { return (CAShapeLayer *)self.layer; }
- (NSView *)hitTest:(NSPoint)point { return nil; }

@end

@interface TodoRowView : FlippedView
- (instancetype)initWithTodo:(Todo *)todo width:(CGFloat)width toggle:(void (^)(void))toggle remove:(void (^)(void))remove;
@end

@implementation TodoRowView {
    void (^_toggle)(void);
    void (^_remove)(void);
    NSButton *_deleteButton;
}

- (instancetype)initWithTodo:(Todo *)todo width:(CGFloat)width toggle:(void (^)(void))toggle remove:(void (^)(void))remove {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, width, kRowHeight)])) return nil;
    _toggle = [toggle copy];
    _remove = [remove copy];
    self.wantsLayer = YES;
    self.layer.cornerRadius = 7;
    self.toolTip = todo.title;

    NSImageView *check = [NSImageView imageViewWithImage:Symbol(todo.done ? @"checkmark.circle.fill" : @"circle", 15, NSFontWeightRegular)];
    check.contentTintColor = todo.done ? NSColor.systemGreenColor : [NSColor colorWithWhite:1 alpha:0.55];
    check.frame = NSMakeRect(10, (kRowHeight - 18) / 2, 18, 18);
    [self addSubview:check];

    NSMutableParagraphStyle *para = [NSMutableParagraphStyle new];
    para.lineBreakMode = NSLineBreakByTruncatingTail;
    NSTextField *title = MakeLabel(@"", 13, NSFontWeightRegular, NSColor.labelColor);
    title.attributedStringValue = [[NSAttributedString alloc] initWithString:todo.title attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:13],
        NSForegroundColorAttributeName: todo.done ? NSColor.secondaryLabelColor : NSColor.labelColor,
        NSStrikethroughStyleAttributeName: @(todo.done ? NSUnderlineStyleSingle : NSUnderlineStyleNone),
        NSParagraphStyleAttributeName: para,
    }];
    CGFloat titleHeight = ceil(title.intrinsicContentSize.height);
    title.frame = NSMakeRect(36, (kRowHeight - titleHeight) / 2, width - 36 - 34, titleHeight);
    [self addSubview:title];

    _deleteButton = [NSButton buttonWithImage:Symbol(@"xmark", 10, NSFontWeightBold) target:self action:@selector(removeClicked:)];
    _deleteButton.bordered = NO;
    _deleteButton.contentTintColor = NSColor.secondaryLabelColor;
    _deleteButton.alphaValue = 0.3;
    _deleteButton.frame = NSMakeRect(width - 28, (kRowHeight - 18) / 2, 18, 18);
    [self addSubview:_deleteButton];

    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                       options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                                         owner:self
                                                      userInfo:nil]];
    return self;
}

// Clicking anywhere on the row except the x toggles it.
- (NSView *)hitTest:(NSPoint)point {
    NSView *hit = [super hitTest:point];
    if (!hit) return nil;
    return [hit isDescendantOf:_deleteButton] ? hit : self;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (void)mouseDown:(NSEvent *)event { _toggle(); }
- (void)removeClicked:(id)sender { _remove(); }

- (void)mouseEntered:(NSEvent *)event {
    self.layer.backgroundColor = [NSColor colorWithWhite:1 alpha:0.07].CGColor;
    _deleteButton.alphaValue = 1;
}

- (void)mouseExited:(NSEvent *)event {
    self.layer.backgroundColor = nil;
    _deleteButton.alphaValue = 0.3;
}

@end

#pragma mark - Controller

@interface NotchController : NSObject <NSApplicationDelegate>
@end

@implementation NotchController {
    TodoStore *_store;
    NotchPanel *_panel;
    ContainerView *_container;
    ShapeView *_shapeView;
    FlippedView *_content;
    NSTextField *_titleLabel;
    NSTextField *_countLabel;
    NSButton *_menuButton;
    NSView *_inputBox;
    NSImageView *_plusIcon;
    NSTextField *_input;
    NSScrollView *_scroll;
    FlippedView *_list;
    NSTextField *_emptyLabel;
    NSRect _screenFrame;
    NSRect _notchRect;
    BOOL _hasNotch;
    BOOL _isOpen;
    BOOL _menuTracking;
    BOOL _openScheduled;
    BOOL _closeScheduled;
    BOOL _pinned; // `--pin-open` keeps the panel open, for checking the layout without hovering.
    NSString *_snapshotPath; // `--snapshot <png>` opens the panel, saves a picture of it and quits.
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
    NSUInteger snapshotIndex = [args indexOfObject:@"--snapshot"];
    if (snapshotIndex != NSNotFound && snapshotIndex + 1 < args.count) _snapshotPath = args[snapshotIndex + 1];
    _pinned = _snapshotPath || [args containsObject:@"--pin-open"];
    _store = [TodoStore new];
    __weak NotchController *weakSelf = self;
    _store.onChange = ^{ [weakSelf storeChanged]; };

    [self buildViews];
    [self rebuildList];
    [self layoutForScreen];
    [_panel orderFrontRegardless];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(layoutForScreen)
                                               name:NSApplicationDidChangeScreenParametersNotification object:nil];

    [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskMouseMoved | NSEventMaskLeftMouseDragged handler:^(NSEvent *event) {
        [weakSelf mouseMoved];
    }];
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskMouseMoved | NSEventMaskLeftMouseDragged handler:^NSEvent *(NSEvent *event) {
        [weakSelf mouseMoved];
        return event;
    }];
    // Clicks that reach a global monitor landed in another app, so they're outside the panel.
    [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown handler:^(NSEvent *event) {
        [weakSelf closeForce:NO];
    }];
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        NotchController *strongSelf = weakSelf;
        if (event.keyCode != 53 || !strongSelf || !strongSelf->_isOpen) return event; // 53 = Esc
        [strongSelf closeForce:YES];
        return nil;
    }];

    if (_pinned) [self open];
    if (_snapshotPath) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self writeSnapshot];
            [NSApp terminate:nil];
        });
    }
}

- (void)writeSnapshot {
    NSRect bounds = _container.bounds;
    CGFloat scale = _panel.backingScaleFactor;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:(NSInteger)(NSWidth(bounds) * scale) pixelsHigh:(NSInteger)(NSHeight(bounds) * scale)
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
        bytesPerRow:0 bitsPerPixel:0];
    CGContextRef context = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep].CGContext;
    CGContextScaleCTM(context, scale, scale);
    CGContextSetRGBFillColor(context, 0.45, 0.5, 0.58, 1); // stand-in for a wallpaper
    CGContextFillRect(context, bounds);
    [_container displayIfNeeded];
    [_container.layer renderInContext:context];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:_snapshotPath atomically:YES];
    NSLog(@"panel=%@ notch=%@ open=%@", NSStringFromRect(_panel.frame), NSStringFromRect(_notchRect), NSStringFromRect([self openRect]));
}

- (void)buildViews {
    _panel = [NotchPanel new];
    _panel.ignoresMouseEvents = YES;

    _container = [[ContainerView alloc] initWithFrame:NSZeroRect];
    __weak NotchController *weakSelf = self;
    _container.onMouseDown = ^{
        NotchController *strongSelf = weakSelf;
        if (strongSelf && !NSPointInRect(NSEvent.mouseLocation, [strongSelf openRect])) [strongSelf closeForce:NO];
    };
    _panel.contentView = _container;

    _shapeView = [[ShapeView alloc] initWithFrame:_container.bounds];
    _shapeView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [_container addSubview:_shapeView];

    _content = [[FlippedView alloc] initWithFrame:NSZeroRect];
    _content.alphaValue = 0;
    _content.hidden = YES;
    [_container addSubview:_content];

    _titleLabel = MakeLabel(@"Todo", 13, NSFontWeightSemibold, NSColor.labelColor);
    [_content addSubview:_titleLabel];

    _countLabel = MakeLabel(@"", 12, NSFontWeightRegular, NSColor.secondaryLabelColor);
    _countLabel.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
    [_content addSubview:_countLabel];

    _menuButton = [NSButton buttonWithImage:Symbol(@"ellipsis", 12, NSFontWeightSemibold) target:self action:@selector(showMenu:)];
    _menuButton.bordered = NO;
    _menuButton.contentTintColor = NSColor.secondaryLabelColor;
    [_content addSubview:_menuButton];

    _inputBox = [[FlippedView alloc] initWithFrame:NSZeroRect];
    _inputBox.wantsLayer = YES;
    _inputBox.layer.cornerRadius = 9;
    _inputBox.layer.backgroundColor = [NSColor colorWithWhite:1 alpha:0.09].CGColor;
    [_content addSubview:_inputBox];

    _plusIcon = [NSImageView imageViewWithImage:Symbol(@"plus", 12, NSFontWeightSemibold)];
    _plusIcon.contentTintColor = NSColor.secondaryLabelColor;
    [_inputBox addSubview:_plusIcon];

    _input = [NSTextField textFieldWithString:@""];
    _input.placeholderString = @"Add a task";
    _input.font = [NSFont systemFontOfSize:13];
    _input.bezeled = NO;
    _input.bordered = NO;
    _input.drawsBackground = NO;
    _input.focusRingType = NSFocusRingTypeNone;
    _input.cell.scrollable = YES;
    _input.cell.usesSingleLineMode = YES;
    _input.cell.sendsActionOnEndEditing = NO;
    _input.target = self;
    _input.action = @selector(addTask:);
    [_inputBox addSubview:_input];

    _list = [[FlippedView alloc] initWithFrame:NSZeroRect];
    _scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scroll.drawsBackground = NO;
    _scroll.hasVerticalScroller = YES;
    _scroll.autohidesScrollers = YES;
    _scroll.scrollerStyle = NSScrollerStyleOverlay;
    _scroll.borderType = NSNoBorder;
    _scroll.documentView = _list;
    [_content addSubview:_scroll];

    _emptyLabel = MakeLabel(@"Nothing to do", 13, NSFontWeightRegular, NSColor.secondaryLabelColor);
    _emptyLabel.alignment = NSTextAlignmentCenter;
    [_content addSubview:_emptyLabel];
}

#pragma mark Geometry

- (CGFloat)openHeight {
    NSInteger rows = MAX(1, MIN(_store.count, kMaxVisibleRows));
    return NSHeight(_notchRect) + kGap + kInputHeight + kGap + rows * kRowHeight + kBottomPadding;
}

- (NSRect)openRect {
    CGFloat height = [self openHeight];
    return NSMakeRect(NSMidX(_notchRect) - kOpenWidth / 2, NSMaxY(_screenFrame) - height, kOpenWidth, height);
}

- (void)layoutForScreen {
    NSScreen *screen = nil;
    for (NSScreen *candidate in NSScreen.screens) {
        if (candidate.safeAreaInsets.top > 0 && NSWidth(candidate.auxiliaryTopLeftArea) > 0) {
            screen = candidate;
            break;
        }
    }
    _hasNotch = screen != nil;
    if (!screen) screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;

    NSRect frame = screen.frame;
    _screenFrame = frame;
    if (_hasNotch) {
        CGFloat left = NSWidth(screen.auxiliaryTopLeftArea), right = NSWidth(screen.auxiliaryTopRightArea);
        CGFloat height = screen.safeAreaInsets.top;
        _notchRect = NSMakeRect(NSMinX(frame) + left, NSMaxY(frame) - height, NSWidth(frame) - left - right, height);
    } else {
        // No notch (lid closed, external display): use a hot zone in the middle of the menu bar.
        CGFloat height = MAX(24, NSMaxY(frame) - NSMaxY(screen.visibleFrame));
        _notchRect = NSMakeRect(NSMidX(frame) - 100, NSMaxY(frame) - height, 200, height);
    }
    [self updatePanelFrame];
    [self layoutContent];
    [self setShapeOpen:_isOpen animated:NO];
}

// The panel is sized to the open panel plus room for its shadow, pinned to the top of the screen.
- (BOOL)updatePanelFrame {
    NSRect open = [self openRect];
    NSRect frame = NSMakeRect(NSMinX(open) - kShadowPad, NSMinY(open) - kShadowPad,
                              NSWidth(open) + 2 * kShadowPad, NSHeight(open) + kShadowPad);
    if (NSEqualRects(frame, _panel.frame)) return NO;
    [_panel setFrame:frame display:YES];
    return YES;
}

// The window snaps to whole points, so center everything on the notch rather than on the window.
- (CGFloat)notchCenterInPanel {
    return NSMidX(_notchRect) - NSMinX(_panel.frame);
}

- (void)layoutContent {
    CGFloat openHeight = [self openHeight], notchHeight = NSHeight(_notchRect);
    CGFloat x = kTopRadius + kInset, width = kOpenWidth - 2 * x;
    _content.frame = NSMakeRect([self notchCenterInPanel] - kOpenWidth / 2, NSHeight(_container.bounds) - openHeight,
                                kOpenWidth, openHeight);

    // Header sits beside the physical notch: title on the left, count and menu on the right.
    [_titleLabel sizeToFit];
    NSSize titleSize = _titleLabel.frame.size;
    _titleLabel.frame = NSMakeRect(x + 10, (notchHeight - titleSize.height) / 2, ceil(titleSize.width) + 2, titleSize.height);
    _menuButton.frame = NSMakeRect(x + width - 10 - 20, (notchHeight - 20) / 2, 20, 20);
    [_countLabel sizeToFit];
    NSSize countSize = _countLabel.frame.size;
    _countLabel.frame = NSMakeRect(NSMinX(_menuButton.frame) - 6 - ceil(countSize.width) - 2, (notchHeight - countSize.height) / 2,
                                   ceil(countSize.width) + 2, countSize.height);

    _inputBox.frame = NSMakeRect(x, notchHeight + kGap, width, kInputHeight);
    _plusIcon.frame = NSMakeRect(10, (kInputHeight - 14) / 2, 14, 14);
    CGFloat fieldHeight = ceil(_input.intrinsicContentSize.height);
    _input.frame = NSMakeRect(30, (kInputHeight - fieldHeight) / 2, width - 40, fieldHeight);

    CGFloat listY = notchHeight + kGap + kInputHeight + kGap;
    NSInteger count = _store.count;
    _emptyLabel.hidden = count > 0;
    _scroll.hidden = count == 0;
    CGFloat emptyHeight = NSHeight(_emptyLabel.frame);
    _emptyLabel.frame = NSMakeRect(x, listY + (kRowHeight - emptyHeight) / 2, width, emptyHeight);
    _scroll.frame = NSMakeRect(x, listY, width, MIN(count, kMaxVisibleRows) * kRowHeight);
    _list.frame = NSMakeRect(0, 0, width, count * kRowHeight);
}

- (void)rebuildList {
    for (NSView *row in [_list.subviews copy]) [row removeFromSuperview];
    CGFloat width = kOpenWidth - 2 * (kTopRadius + kInset);
    __weak TodoStore *store = _store;
    NSArray<Todo *> *todos = _store.sorted;
    for (NSUInteger i = 0; i < todos.count; i++) {
        Todo *todo = todos[i];
        TodoRowView *row = [[TodoRowView alloc] initWithTodo:todo width:width
                                                      toggle:^{ [store toggle:todo]; }
                                                      remove:^{ [store remove:todo]; }];
        [row setFrameOrigin:NSMakePoint(0, i * kRowHeight)];
        [_list addSubview:row];
    }
    NSInteger open = _store.openCount;
    _countLabel.stringValue = _store.count == 0 ? @"" : open == 0 ? @"All done" : [NSString stringWithFormat:@"%ld left", (long)open];
}

- (void)storeChanged {
    [self rebuildList];
    [self updatePanelFrame];
    [self layoutContent];
    if (_isOpen) [self setShapeOpen:YES animated:NO];
}

#pragma mark Open / close

- (void)setShapeOpen:(BOOL)open animated:(BOOL)animated {
    CAShapeLayer *shape = _shapeView.shape;
    CGFloat centerX = [self notchCenterInPanel];
    CGPathRef path = open
        ? CreateNotchPath(_shapeView.bounds, centerX, kOpenWidth, [self openHeight], kTopRadius, kBottomRadius)
        // Closed, the shape shrinks to just inside the notch, where the hardware hides it.
        : CreateNotchPath(_shapeView.bounds, centerX, NSWidth(_notchRect) - 2, NSHeight(_notchRect), 6, 10);
    float shadow = open ? 0.4f : 0;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (animated) {
        CAShapeLayer *current = shape.presentationLayer ?: shape;
        CASpringAnimation *spring = [CASpringAnimation animationWithKeyPath:@"path"];
        spring.fromValue = (__bridge id)current.path;
        spring.toValue = (__bridge id)path;
        spring.mass = 1;
        spring.stiffness = open ? 320 : 420;
        spring.damping = open ? 24 : 36;
        spring.duration = spring.settlingDuration;
        [shape addAnimation:spring forKey:@"path"];

        CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"shadowOpacity"];
        fade.fromValue = @(current.shadowOpacity);
        fade.toValue = @(shadow);
        fade.duration = 0.25;
        [shape addAnimation:fade forKey:@"shadowOpacity"];
    } else {
        [shape removeAllAnimations];
    }
    shape.path = path;
    shape.shadowPath = path;
    shape.shadowOpacity = shadow;
    shape.opacity = (open || _hasNotch) ? 1 : 0;
    [CATransaction commit];
    CGPathRelease(path);
}

- (void)open {
    _openScheduled = NO;
    [self cancelClose];
    if (_isOpen) return;
    _isOpen = YES;
    _panel.ignoresMouseEvents = NO;
    [self setShapeOpen:YES animated:YES];

    _content.hidden = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!self->_isOpen) return;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.18;
            self->_content.animator.alphaValue = 1;
        }];
    });
}

- (void)closeFromHover { [self closeForce:NO]; }

- (void)closeForce:(BOOL)force {
    [self cancelClose];
    if (!_isOpen || (_pinned && !force) || _menuTracking) return;
    _isOpen = NO;
    _panel.ignoresMouseEvents = YES;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.08;
        self->_content.animator.alphaValue = 0;
    } completionHandler:^{
        if (!self->_isOpen) self->_content.hidden = YES;
    }];
    [self setShapeOpen:NO animated:YES];

    // If you were typing in the panel, hand the keyboard back to the app you were using.
    if (_panel.isKeyWindow) {
        [_panel orderOut:nil];
        [_panel orderFrontRegardless];
    }
}

- (void)cancelClose {
    _closeScheduled = NO;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(closeFromHover) object:nil];
}

- (void)mouseMoved {
    NSPoint point = NSEvent.mouseLocation;
    if (_isOpen) {
        if (NSPointInRect(point, NSInsetRect([self openRect], -8, -8)) || _menuTracking) {
            [self cancelClose];
        } else if (!_closeScheduled) {
            _closeScheduled = YES;
            [self performSelector:@selector(closeFromHover) withObject:nil afterDelay:0.3];
        }
    } else {
        // Taller than the notch at the top so the very top pixel row counts as inside.
        NSRect hotZone = NSMakeRect(NSMinX(_notchRect) - 4, NSMinY(_notchRect), NSWidth(_notchRect) + 8, NSHeight(_notchRect) + 4);
        if (NSPointInRect(point, hotZone)) {
            if (!_openScheduled) {
                _openScheduled = YES;
                [self performSelector:@selector(open) withObject:nil afterDelay:0.1];
            }
        } else if (_openScheduled) {
            _openScheduled = NO;
            [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(open) object:nil];
        }
    }
}

#pragma mark Actions

- (void)addTask:(NSTextField *)sender {
    NSString *text = sender.stringValue;
    sender.stringValue = @"";
    [_store add:text];
}

- (void)showMenu:(NSButton *)sender {
    NSMenu *menu = [NSMenu new];
    menu.autoenablesItems = NO;
    NSMenuItem *clear = [menu addItemWithTitle:@"Clear Completed" action:@selector(clearCompleted:) keyEquivalent:@""];
    clear.target = self;
    clear.enabled = _store.hasDone;
    NSMenuItem *login = [menu addItemWithTitle:@"Open at Login" action:@selector(toggleLogin:) keyEquivalent:@""];
    login.target = self;
    login.state = SMAppService.mainAppService.status == SMAppServiceStatusEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *quit = [menu addItemWithTitle:@"Quit NotchTodo" action:@selector(terminate:) keyEquivalent:@""];
    quit.target = NSApp;

    _menuTracking = YES;
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(sender.bounds) + 4) inView:sender];
    _menuTracking = NO;
    [self mouseMoved];
}

- (void)clearCompleted:(id)sender { [_store clearDone]; }

- (void)toggleLogin:(id)sender {
    SMAppService *service = SMAppService.mainAppService;
    NSError *error = nil;
    BOOL ok = service.status == SMAppServiceStatusEnabled ? [service unregisterAndReturnError:&error]
                                                          : [service registerAndReturnError:&error];
    if (!ok) NSLog(@"Open at Login failed: %@", error);
}

@end

int main(void) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        NotchController *controller = [NotchController new];
        app.delegate = controller;
        app.activationPolicy = NSApplicationActivationPolicyAccessory;
        [app run];
    }
    return 0;
}
