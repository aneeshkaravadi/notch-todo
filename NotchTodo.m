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

// The notch outline grown by `gap` on every side: down the left side, along the bottom and up
// the right side, with the ends flaring outward into the top edge of the screen. The sides sit
// outside the notch's full width, since the camera housing covers everything inside it.
static CGPathRef CreateRingPath(CGRect notch, CGFloat gap) {
    const CGFloat flare = 6, radius = 10 + gap; // close to the physical notch's own corners
    CGFloat top = CGRectGetMaxY(notch), bottom = CGRectGetMinY(notch) - gap;
    CGFloat left = CGRectGetMinX(notch) - gap, right = CGRectGetMaxX(notch) + gap;
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, left - flare - 2, top + 1);
    CGPathAddQuadCurveToPoint(p, NULL, left, top, left, top - flare);
    CGPathAddArcToPoint(p, NULL, left, bottom, left + radius, bottom, radius);
    CGPathAddArcToPoint(p, NULL, right, bottom, right, bottom + radius, radius);
    CGPathAddLineToPoint(p, NULL, right, top - flare);
    CGPathAddQuadCurveToPoint(p, NULL, right, top, right + flare + 2, top + 1);
    return p;
}

// A border just inside the screen's edges. Along the top it dips around the notch the same way
// the notch ring does. Pass CGRectNull when there's no notch.
static CGPathRef CreateScreenBorderPath(CGRect bounds, CGRect notch, CGFloat inset) {
    const CGFloat corner = 12, gap = 4, flare = 6, radius = 10 + gap;
    CGFloat x0 = CGRectGetMinX(bounds) + inset, x1 = CGRectGetMaxX(bounds) - inset;
    CGFloat y0 = CGRectGetMinY(bounds) + inset, y1 = CGRectGetMaxY(bounds) - inset;
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, x0 + corner, y1);
    if (!CGRectIsNull(notch)) {
        CGFloat left = CGRectGetMinX(notch) - gap, right = CGRectGetMaxX(notch) + gap, bottom = CGRectGetMinY(notch) - gap;
        CGPathAddLineToPoint(p, NULL, left - flare, y1);
        CGPathAddQuadCurveToPoint(p, NULL, left, y1, left, y1 - flare);
        CGPathAddArcToPoint(p, NULL, left, bottom, left + radius, bottom, radius);
        CGPathAddArcToPoint(p, NULL, right, bottom, right, bottom + radius, radius);
        CGPathAddLineToPoint(p, NULL, right, y1 - flare);
        CGPathAddQuadCurveToPoint(p, NULL, right, y1, right + flare, y1);
    }
    CGPathAddArcToPoint(p, NULL, x1, y1, x1, y1 - corner, corner);
    CGPathAddArcToPoint(p, NULL, x1, y0, x1 - corner, y0, corner);
    CGPathAddArcToPoint(p, NULL, x0, y0, x0, y0 + corner, corner);
    CGPathAddArcToPoint(p, NULL, x0, y1, x0 + corner, y1, corner);
    CGPathCloseSubpath(p);
    return p;
}

#pragma mark - Ring settings

static const NSTimeInterval kPauseLength = 30 * 60;

static NSArray<NSString *> *PaletteNames(void) {
    return @[@"Rainbow", @"Sunset", @"Ocean", @"Aurora", @"Candy", @"Custom"];
}

static NSArray<NSString *> *PaletteHexes(NSString *name) {
    static NSDictionary *palettes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        palettes = @{
            @"Rainbow": @[@"FF3B30", @"FF9500", @"FFCC00", @"34C759", @"00C7BE", @"007AFF", @"AF52DE", @"FF2D55"],
            @"Sunset": @[@"FF2D55", @"FF5E3A", @"FF9500", @"FFCC00", @"AF52DE"],
            @"Ocean": @[@"00C7BE", @"32ADE6", @"007AFF", @"5856D6", @"30D158"],
            @"Aurora": @[@"30D158", @"00C7BE", @"5E5CE6", @"BF5AF2"],
            @"Candy": @[@"FF2D55", @"FF6FD8", @"BF5AF2", @"64D2FF"],
        };
    });
    return palettes[name] ?: palettes[@"Rainbow"];
}

static NSColor *ColorFromHex(NSString *hex) {
    unsigned int value = 0;
    if (![[NSScanner scannerWithString:hex] scanHexInt:&value]) return NSColor.whiteColor;
    return [NSColor colorWithSRGBRed:((value >> 16) & 0xFF) / 255.0 green:((value >> 8) & 0xFF) / 255.0
                                blue:(value & 0xFF) / 255.0 alpha:1];
}

static NSString *HexFromColor(NSColor *color) {
    NSColor *c = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace] ?: NSColor.whiteColor;
    return [NSString stringWithFormat:@"%02X%02X%02X", (int)lround(c.redComponent * 255),
                                      (int)lround(c.greenComponent * 255), (int)lround(c.blueComponent * 255)];
}

// The ring around the notch: which colors, how fast they move, and the 30-minute pause.
// There is deliberately no off switch; a pause always ends on its own.
@interface RingSettings : NSObject
@property (nonatomic, copy) NSString *palette;
@property (nonatomic, copy) NSArray<NSColor *> *customColors;
@property (nonatomic) double speed;              // 0 = slow, 1 = fast
@property (nonatomic) double saturation;         // 0 = gray, 1 = most vivid
@property (nonatomic) double brightness;         // 0 = dim, 1 = brightest
@property (nonatomic) BOOL wholeScreen;          // border the whole screen instead of just the notch
@property (nonatomic) BOOL flash;                // flash at random times instead of staying on
@property (nonatomic) double flashMin, flashMax; // seconds between flashes
@property (nonatomic, readonly) NSTimeInterval nextFlashDelay; // random, between flashMin and flashMax
@property (nonatomic) NSTimeInterval pausedUntil; // seconds since 1970; 0 when running
@property (nonatomic, copy) void (^onChange)(void);
@property (nonatomic, readonly) NSArray<NSColor *> *colors;
@property (nonatomic, readonly) NSTimeInterval period; // seconds per full turn
@property (nonatomic, readonly) BOOL isPaused;
- (void)pause;
- (void)resume;
- (void)save;
@end

@implementation RingSettings

- (instancetype)init {
    if ((self = [super init])) {
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        NSString *palette = [d stringForKey:@"RingPalette"];
        _palette = [PaletteNames() containsObject:palette] ? palette : @"Rainbow";
        NSArray *hexes = [d arrayForKey:@"RingCustomColors"];
        if (hexes.count != 3) hexes = @[@"FF2D55", @"FFD60A", @"0A84FF"];
        NSMutableArray *custom = [NSMutableArray array];
        for (id hex in hexes) [custom addObject:ColorFromHex([hex isKindOfClass:NSString.class] ? hex : @"FFFFFF")];
        _customColors = custom;
        _speed = [d objectForKey:@"RingSpeed"] ? MAX(0, MIN(1, [d doubleForKey:@"RingSpeed"])) : 0.5;
        _saturation = [d objectForKey:@"RingSaturation"] ? MAX(0, MIN(1, [d doubleForKey:@"RingSaturation"])) : 0.8;
        _brightness = [d objectForKey:@"RingBrightness"] ? MAX(0, MIN(1, [d doubleForKey:@"RingBrightness"])) : 0.85;
        _wholeScreen = [d boolForKey:@"RingWholeScreen"];
        _flash = [d boolForKey:@"RingFlash"];
        _flashMin = [d objectForKey:@"RingFlashMin"] ? [d doubleForKey:@"RingFlashMin"] : 20;
        _flashMax = [d objectForKey:@"RingFlashMax"] ? [d doubleForKey:@"RingFlashMax"] : 60;
        [self clampFlash];
        // Never honor a pause longer than 30 minutes, even if the saved value says otherwise.
        _pausedUntil = MIN([d doubleForKey:@"RingPausedUntil"], NSDate.date.timeIntervalSince1970 + kPauseLength);
    }
    return self;
}

- (NSArray<NSColor *> *)baseColors {
    if ([_palette isEqual:@"Custom"]) return _customColors;
    NSMutableArray *colors = [NSMutableArray array];
    for (NSString *hex in PaletteHexes(_palette)) [colors addObject:ColorFromHex(hex)];
    return colors;
}

// The palette with saturation and brightness applied. The work happens in Display P3, so on a
// MacBook screen the top of the saturation slider reaches colors more vivid than plain sRGB.
- (NSArray<NSColor *> *)colors {
    NSColorSpace *p3 = NSColorSpace.displayP3ColorSpace;
    double satFactor = 1.6 * _saturation;          // 0.625 leaves the palette as designed
    double brightFactor = 0.35 + 0.9 * _brightness; // ~0.72 leaves it as designed
    NSMutableArray *colors = [NSMutableArray array];
    for (NSColor *base in [self baseColors]) {
        NSColor *wide = [base colorUsingColorSpace:p3] ?: base;
        CGFloat h = 0, sat = 0, b = 0, a = 1;
        [wide getHue:&h saturation:&sat brightness:&b alpha:&a];
        [colors addObject:[NSColor colorWithColorSpace:p3 hue:h saturation:MIN(1, sat * satFactor)
                                            brightness:MIN(1, b * brightFactor) alpha:1]];
    }
    return colors;
}

- (NSTimeInterval)period { return 14.0 * pow(1.2 / 14.0, _speed); }

// 2 seconds to an hour, and the longest gap never shorter than the shortest.
- (void)clampFlash {
    _flashMin = round(MAX(2, MIN(3600, _flashMin)));
    _flashMax = round(MAX(_flashMin, MIN(3600, _flashMax)));
}

- (NSTimeInterval)nextFlashDelay {
    return _flashMin + (_flashMax - _flashMin) * (arc4random_uniform(10001) / 10000.0);
}

- (BOOL)isPaused { return _pausedUntil > NSDate.date.timeIntervalSince1970; }

- (void)pause {
    _pausedUntil = NSDate.date.timeIntervalSince1970 + kPauseLength;
    [self save];
}

- (void)resume {
    _pausedUntil = 0;
    [self save];
}

- (void)save {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setObject:_palette forKey:@"RingPalette"];
    NSMutableArray *hexes = [NSMutableArray array];
    for (NSColor *c in _customColors) [hexes addObject:HexFromColor(c)];
    [d setObject:hexes forKey:@"RingCustomColors"];
    [d setDouble:_speed forKey:@"RingSpeed"];
    [d setDouble:_saturation forKey:@"RingSaturation"];
    [d setDouble:_brightness forKey:@"RingBrightness"];
    [d setBool:_wholeScreen forKey:@"RingWholeScreen"];
    [self clampFlash];
    [d setBool:_flash forKey:@"RingFlash"];
    [d setDouble:_flashMin forKey:@"RingFlashMin"];
    [d setDouble:_flashMax forKey:@"RingFlashMax"];
    [d setDouble:_pausedUntil forKey:@"RingPausedUntil"];
    if (self.onChange) self.onChange();
}

@end

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

// A glowing line in the ring's colors. A conic gradient spins behind a line-shaped mask, so the
// colors travel along the line without redrawing anything. Draws both the ring around the notch
// and the border around the whole screen.
@interface RingView : NSView
@property (nonatomic) float maxFrameRate;            // 0 = the display's own rate
@property (nonatomic, copy) void (^onHidden)(void);  // runs once a fade-out finishes
@property (nonatomic) NSTimeInterval fadeInDuration;
- (instancetype)initWithFrame:(NSRect)frame coreWidth:(CGFloat)core glowWidth:(CGFloat)glow;
- (void)setPath:(CGPathRef)path spinCenter:(CGPoint)center spinRadius:(CGFloat)radius
         colors:(NSArray<NSColor *> *)colors period:(NSTimeInterval)period intensity:(double)intensity;
- (void)setShown:(BOOL)shown animated:(BOOL)animated;
@end

@implementation RingView {
    CALayer *_host;
    CAGradientLayer *_gradient;
    CALayer *_mask;
    CAShapeLayer *_glow, *_core;
    NSTimeInterval _period;
    BOOL _shown;
}

- (instancetype)initWithFrame:(NSRect)frame coreWidth:(CGFloat)core glowWidth:(CGFloat)glow {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        _fadeInDuration = 0.4;
        _host = [CALayer layer];
        _host.opacity = 0;

        _gradient = [CAGradientLayer layer];
        _gradient.type = kCAGradientLayerConic;
        _gradient.startPoint = CGPointMake(0.5, 0.5);
        _gradient.endPoint = CGPointMake(0.5, 0);
        [_host addSublayer:_gradient];

        _mask = [CALayer layer];
        _glow = [CAShapeLayer layer];
        _glow.fillColor = nil;
        _glow.lineWidth = glow;
        _glow.lineJoin = kCALineJoinRound;
        _glow.shadowColor = NSColor.whiteColor.CGColor;
        _glow.shadowRadius = glow / 2;
        _glow.shadowOffset = CGSizeZero;
        _core = [CAShapeLayer layer];
        _core.fillColor = nil;
        _core.lineWidth = core;
        _core.lineJoin = kCALineJoinRound;
        [_mask addSublayer:_glow];
        [_mask addSublayer:_core];
        _host.mask = _mask;
        [self.layer addSublayer:_host];
    }
    return self;
}

- (NSView *)hitTest:(NSPoint)point { return nil; }

- (void)setPath:(CGPathRef)path spinCenter:(CGPoint)center spinRadius:(CGFloat)radius
         colors:(NSArray<NSColor *> *)colors period:(NSTimeInterval)period intensity:(double)intensity {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _host.frame = self.bounds;
    _mask.frame = _host.bounds;
    _glow.frame = _mask.bounds;
    _core.frame = _mask.bounds;
    // Brighter also means a stronger halo around the core line.
    _glow.strokeColor = [NSColor colorWithWhite:1 alpha:0.15 + 0.5 * intensity].CGColor;
    _glow.shadowOpacity = 0.4 + 0.6 * intensity;
    _core.strokeColor = [NSColor colorWithWhite:1 alpha:0.6 + 0.4 * intensity].CGColor;
    _glow.path = path;
    _core.path = path;

    _gradient.bounds = CGRectMake(0, 0, 2 * radius, 2 * radius);
    _gradient.position = center;
    NSMutableArray *cgColors = [NSMutableArray array];
    for (int lap = 0; lap < 2; lap++) // twice around, so the whole palette shows at once
        for (NSColor *c in colors) [cgColors addObject:(__bridge id)c.CGColor];
    if (colors.count) [cgColors addObject:(__bridge id)colors.firstObject.CGColor];
    _gradient.colors = cgColors;
    [CATransaction commit];

    if (fabs(period - _period) > 0.001) {
        _period = period;
        if (_shown) [self spin];
    }
}

- (void)spin {
    NSNumber *angle = [_gradient.presentationLayer valueForKeyPath:@"transform.rotation.z"];
    double from = angle.doubleValue;
    CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    spin.fromValue = @(from);
    spin.toValue = @(from - 2 * M_PI);
    spin.duration = MAX(_period, 0.5);
    spin.repeatCount = HUGE_VALF;
    if (_maxFrameRate > 0) spin.preferredFrameRateRange = CAFrameRateRangeMake(_maxFrameRate / 2, _maxFrameRate, _maxFrameRate);
    [_gradient addAnimation:spin forKey:@"spin"];
}

- (void)setShown:(BOOL)shown animated:(BOOL)animated {
    if (shown == _shown) return;
    _shown = shown;
    if (shown) [self spin];
    float target = shown ? 1 : 0;
    if (animated) {
        CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
        fade.fromValue = @(((CALayer *)_host.presentationLayer ?: _host).opacity);
        fade.toValue = @(target);
        fade.duration = shown ? _fadeInDuration : 0.15;
        [_host addAnimation:fade forKey:@"fade"];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _host.opacity = target;
    [CATransaction commit];
    if (!shown) { // stop spinning once it has faded, so a hidden ring costs nothing
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self->_shown) return;
            [self->_gradient removeAnimationForKey:@"spin"];
            if (self.onHidden) self.onHidden();
        });
    }
}

@end

// A click-through window covering the whole screen, for the border around its edges.
@interface OverlayPanel : NSPanel
@end

@implementation OverlayPanel

- (instancetype)init {
    self = [super initWithContentRect:NSZeroRect
                            styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                              backing:NSBackingStoreBuffered
                                defer:NO];
    if (self) {
        self.opaque = NO;
        self.backgroundColor = NSColor.clearColor;
        self.hasShadow = NO;
        self.ignoresMouseEvents = YES;
        self.hidesOnDeactivate = NO;
        self.releasedWhenClosed = NO;
        self.level = NSMainMenuWindowLevel + 2; // over the menu bar, under the todo panel and menus
        self.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary
            | NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorIgnoresCycle;
    }
    return self;
}

- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
- (NSRect)constrainFrameRect:(NSRect)frameRect toScreen:(NSScreen *)screen { return frameRect; }

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

#pragma mark - Settings window

@interface SettingsWindowController : NSObject <NSWindowDelegate>
@property (readonly) NSWindow *window;
- (instancetype)initWithSettings:(RingSettings *)settings;
- (void)show;
- (void)refresh;
@end

@implementation SettingsWindowController {
    RingSettings *_settings;
    NSPopUpButton *_palettePopup, *_placePopup, *_stylePopup;
    NSTextField *_flashMinField, *_flashMaxField;
    NSArray<NSColorWell *> *_wells;
    NSSlider *_speedSlider, *_saturationSlider, *_brightnessSlider;
    NSTextField *_pauseStatus;
    NSButton *_pauseButton, *_resumeButton;
}

- (instancetype)initWithSettings:(RingSettings *)settings {
    if ((self = [super init])) _settings = settings;
    return self;
}

static NSTextField *SettingsLabel(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color, NSRect frame) {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.frame = frame;
    return label;
}

- (void)build {
    const CGFloat W = 444, H = 592;
    _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, W, H)
                                          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    _window.title = @"NotchTodo Settings";
    _window.releasedWhenClosed = NO;
    _window.delegate = self;
    FlippedView *view = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, W, H)];
    view.wantsLayer = YES;
    _window.contentView = view;
    const CGFloat left = 24, field = 128, width = W - 2 * left;

    [view addSubview:SettingsLabel(@"Color ring", 13, NSFontWeightSemibold, NSColor.labelColor, NSMakeRect(left, 18, width, 18))];
    [view addSubview:SettingsLabel(@"While any task is unchecked, moving colors surround the notch, or the whole screen, so you can't forget about it.",
                                   12, NSFontWeightRegular, NSColor.secondaryLabelColor, NSMakeRect(left, 40, width, 32))];

    CGFloat y = 84;
    [view addSubview:SettingsLabel(@"Show around", 13, NSFontWeightRegular, NSColor.labelColor, NSMakeRect(left, y + 5, 100, 18))];
    _placePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(field, y, 170, 26) pullsDown:NO];
    [_placePopup addItemsWithTitles:@[@"The notch", @"The whole screen"]];
    _placePopup.target = self;
    _placePopup.action = @selector(placeChanged:);
    [view addSubview:_placePopup];
    y += 38;

    [view addSubview:SettingsLabel(@"Style", 13, NSFontWeightRegular, NSColor.labelColor, NSMakeRect(left, y + 5, 100, 18))];
    _stylePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(field, y, 200, 26) pullsDown:NO];
    [_stylePopup addItemsWithTitles:@[@"Always on", @"Flash at random times"]];
    _stylePopup.target = self;
    _stylePopup.action = @selector(styleChanged:);
    [view addSubview:_stylePopup];
    y += 38;

    [view addSubview:SettingsLabel(@"Flash every", 13, NSFontWeightRegular, NSColor.labelColor, NSMakeRect(left, y + 4, 100, 18))];
    _flashMinField = [self secondsField:NSMakeRect(field + 2, y, 56, 24) in:view];
    [view addSubview:SettingsLabel(@"to", 13, NSFontWeightRegular, NSColor.labelColor, NSMakeRect(field + 66, y + 4, 20, 18))];
    _flashMaxField = [self secondsField:NSMakeRect(field + 88, y, 56, 24) in:view];
    [view addSubview:SettingsLabel(@"seconds, at random", 13, NSFontWeightRegular, NSColor.secondaryLabelColor,
                                   NSMakeRect(field + 152, y + 4, 140, 18))];
    y += 38;

    [view addSubview:SettingsLabel(@"Colors", 13, NSFontWeightRegular, NSColor.labelColor, NSMakeRect(left, y + 5, 100, 18))];
    _palettePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(field, y, 170, 26) pullsDown:NO];
    [_palettePopup addItemsWithTitles:PaletteNames()];
    _palettePopup.target = self;
    _palettePopup.action = @selector(paletteChanged:);
    [view addSubview:_palettePopup];
    y += 38;

    [view addSubview:SettingsLabel(@"Custom", 13, NSFontWeightRegular, NSColor.labelColor, NSMakeRect(left, y + 5, 100, 18))];
    NSMutableArray *wells = [NSMutableArray array];
    for (int i = 0; i < 3; i++) {
        NSColorWell *well = [[NSColorWell alloc] initWithFrame:NSMakeRect(field + 2 + i * 52, y, 44, 26)];
        well.colorWellStyle = NSColorWellStyleMinimal;
        well.target = self;
        well.action = @selector(customColorChanged:);
        [view addSubview:well];
        [wells addObject:well];
    }
    _wells = wells;
    [view addSubview:SettingsLabel(@"Pick any color to switch to Custom.", 11, NSFontWeightRegular, NSColor.tertiaryLabelColor,
                                   NSMakeRect(field + 2, y + 30, width - field, 15))];
    y += 62;

    _speedSlider = [self sliderRow:@"Speed" low:@"Slow" high:@"Fast" y:y action:@selector(speedChanged:) in:view];
    y += 56;
    _saturationSlider = [self sliderRow:@"Saturation" low:@"Muted" high:@"Vivid" y:y action:@selector(saturationChanged:) in:view];
    y += 56;
    _brightnessSlider = [self sliderRow:@"Brightness" low:@"Dim" high:@"Bright" y:y action:@selector(brightnessChanged:) in:view];
    y += 52;

    NSBox *line = [[NSBox alloc] initWithFrame:NSMakeRect(left, y, width, 1)];
    line.boxType = NSBoxSeparator;
    [view addSubview:line];
    y += 18;

    [view addSubview:SettingsLabel(@"Pause", 13, NSFontWeightRegular, NSColor.labelColor, NSMakeRect(left, y, 100, 18))];
    _pauseStatus = SettingsLabel(@"", 13, NSFontWeightRegular, NSColor.secondaryLabelColor, NSMakeRect(field + 2, y, width - field, 18));
    [view addSubview:_pauseStatus];
    _pauseButton = [NSButton buttonWithTitle:@"Pause for 30 Minutes" target:self action:@selector(pauseClicked:)];
    _pauseButton.frame = NSMakeRect(field - 6, y + 22, 176, 30);
    [view addSubview:_pauseButton];
    _resumeButton = [NSButton buttonWithTitle:@"Resume Now" target:self action:@selector(resumeClicked:)];
    _resumeButton.frame = NSMakeRect(field + 172, y + 22, 116, 30);
    [view addSubview:_resumeButton];
    [view addSubview:SettingsLabel(@"There's no off switch. A pause always ends after 30 minutes.", 11, NSFontWeightRegular,
                                   NSColor.tertiaryLabelColor, NSMakeRect(field + 2, y + 58, W - left - field - 2, 30))];
}

- (NSTextField *)secondsField:(NSRect)frame in:(NSView *)view {
    NSTextField *field = [NSTextField textFieldWithString:@""];
    field.frame = frame;
    field.alignment = NSTextAlignmentRight;
    NSNumberFormatter *formatter = [NSNumberFormatter new];
    formatter.numberStyle = NSNumberFormatterNoStyle;
    formatter.allowsFloats = NO;
    field.formatter = formatter;
    field.target = self;
    field.action = @selector(flashIntervalChanged:);
    field.cell.sendsActionOnEndEditing = YES;
    [view addSubview:field];
    return field;
}

- (NSSlider *)sliderRow:(NSString *)title low:(NSString *)low high:(NSString *)high y:(CGFloat)y action:(SEL)action in:(NSView *)view {
    const CGFloat W = NSWidth(view.bounds), left = 24, field = 128, width = W - 2 * left;
    [view addSubview:SettingsLabel(title, 13, NSFontWeightRegular, NSColor.labelColor, NSMakeRect(left, y + 3, 100, 18))];
    NSSlider *slider = [NSSlider sliderWithValue:0.5 minValue:0 maxValue:1 target:self action:action];
    slider.frame = NSMakeRect(field, y, width - field + left - 4, 24);
    slider.continuous = YES;
    [view addSubview:slider];
    [view addSubview:SettingsLabel(low, 11, NSFontWeightRegular, NSColor.tertiaryLabelColor, NSMakeRect(field + 2, y + 24, 80, 15))];
    NSTextField *highLabel = SettingsLabel(high, 11, NSFontWeightRegular, NSColor.tertiaryLabelColor, NSMakeRect(W - left - 80, y + 24, 80, 15));
    highLabel.alignment = NSTextAlignmentRight;
    [view addSubview:highLabel];
    return slider;
}

- (void)show {
    if (!_window) [self build];
    [self refresh];
    [_window center];
    [NSApp activate];
    [_window makeKeyAndOrderFront:nil];
    [_window orderFrontRegardless];
    [_window makeFirstResponder:nil]; // don't start with a cursor in the first number field
}

- (void)refresh {
    if (!_window) return;
    [_placePopup selectItemAtIndex:_settings.wholeScreen ? 1 : 0];
    [_stylePopup selectItemAtIndex:_settings.flash ? 1 : 0];
    // Don't overwrite a number while you're typing it.
    if (!_flashMinField.currentEditor) _flashMinField.integerValue = (NSInteger)_settings.flashMin;
    if (!_flashMaxField.currentEditor) _flashMaxField.integerValue = (NSInteger)_settings.flashMax;
    _flashMinField.enabled = _flashMaxField.enabled = _settings.flash;
    [_palettePopup selectItemWithTitle:_settings.palette];
    for (NSUInteger i = 0; i < _wells.count && i < _settings.customColors.count; i++) _wells[i].color = _settings.customColors[i];
    _speedSlider.doubleValue = _settings.speed;
    _saturationSlider.doubleValue = _settings.saturation;
    _brightnessSlider.doubleValue = _settings.brightness;
    if (_settings.isPaused) {
        NSString *until = [NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:_settings.pausedUntil]
                                                         dateStyle:NSDateFormatterNoStyle
                                                         timeStyle:NSDateFormatterShortStyle];
        _pauseStatus.stringValue = [NSString stringWithFormat:@"Paused until %@", until];
        _pauseButton.title = @"Restart 30 Minutes";
    } else {
        _pauseStatus.stringValue = @"The ring is on";
        _pauseButton.title = @"Pause for 30 Minutes";
    }
    _resumeButton.enabled = _settings.isPaused;
}

- (void)placeChanged:(NSPopUpButton *)sender {
    _settings.wholeScreen = sender.indexOfSelectedItem == 1;
    [_settings save];
}

- (void)styleChanged:(NSPopUpButton *)sender {
    _settings.flash = sender.indexOfSelectedItem == 1;
    [_settings save];
}

- (void)flashIntervalChanged:(id)sender {
    _settings.flashMin = _flashMinField.doubleValue;
    _settings.flashMax = _flashMaxField.doubleValue;
    [_settings save]; // clamps to 2-3600 s and keeps the longest gap at least the shortest
    if (!_flashMinField.currentEditor) _flashMinField.integerValue = (NSInteger)_settings.flashMin;
    if (!_flashMaxField.currentEditor) _flashMaxField.integerValue = (NSInteger)_settings.flashMax;
}

- (void)paletteChanged:(NSPopUpButton *)sender {
    _settings.palette = sender.titleOfSelectedItem;
    [_settings save];
}

- (void)customColorChanged:(NSColorWell *)sender {
    NSMutableArray *colors = [NSMutableArray array];
    for (NSColorWell *well in _wells) [colors addObject:well.color];
    _settings.customColors = colors;
    _settings.palette = @"Custom";
    [_settings save];
}

- (void)speedChanged:(NSSlider *)sender {
    _settings.speed = sender.doubleValue;
    [_settings save];
}

- (void)saturationChanged:(NSSlider *)sender {
    _settings.saturation = sender.doubleValue;
    [_settings save];
}

- (void)brightnessChanged:(NSSlider *)sender {
    _settings.brightness = sender.doubleValue;
    [_settings save];
}

- (void)pauseClicked:(id)sender { [_settings pause]; }
- (void)resumeClicked:(id)sender { [_settings resume]; }

- (void)windowWillClose:(NSNotification *)notification {
    for (NSColorWell *well in _wells) [well deactivate];
    [NSColorPanel.sharedColorPanel orderOut:nil];
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
    NSString *_settingsSnapshotPath; // `--snapshot-settings <png>` does the same for the Settings window.
    RingSettings *_ring;
    RingView *_ringView;
    SettingsWindowController *_settingsWindow;
    NSTimer *_ringTimer;
    OverlayPanel *_overlay;  // click-through window for the whole-screen border
    RingView *_screenRing;
    NSString *_screenSnapshotPath; // `--snapshot-screen <png>` pictures the whole-screen border.
    // Flash style: the colors stay hidden and blink at random times.
    NSUInteger _flashGeneration; // bumping it cancels any scheduled or running flash
    BOOL _flashScheduled, _flashOn, _logFlashes;
    NSString *_flashKey;         // the flash settings last applied, to notice changes
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
    NSUInteger snapshotIndex = [args indexOfObject:@"--snapshot"];
    if (snapshotIndex != NSNotFound && snapshotIndex + 1 < args.count) _snapshotPath = args[snapshotIndex + 1];
    // `--snapshot <png> --closed` pictures the closed notch (with its ring) instead of the open panel.
    _pinned = (_snapshotPath && ![args containsObject:@"--closed"]) || [args containsObject:@"--pin-open"];
    _logFlashes = [args containsObject:@"--log-flashes"]; // `--log-flashes` logs when each flash happens
    NSUInteger screenIndex = [args indexOfObject:@"--snapshot-screen"];
    if (screenIndex != NSNotFound && screenIndex + 1 < args.count) _screenSnapshotPath = args[screenIndex + 1];
    NSUInteger settingsIndex = [args indexOfObject:@"--snapshot-settings"];
    if (settingsIndex != NSNotFound && settingsIndex + 1 < args.count) _settingsSnapshotPath = args[settingsIndex + 1];
    _store = [TodoStore new];
    __weak NotchController *weakSelf = self;
    _store.onChange = ^{ [weakSelf storeChanged]; };
    _ring = [RingSettings new];
    _ring.onChange = ^{ [weakSelf ringSettingsChanged]; };

    [self buildViews];
    [self rebuildList];
    [self layoutForScreen];
    [_panel orderFrontRegardless];
    [self ringSettingsChanged];
    // Catches the end of a pause even if the Mac slept through it.
    _ringTimer = [NSTimer scheduledTimerWithTimeInterval:15 target:self selector:@selector(ringTick) userInfo:nil repeats:YES];

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
    if (_screenSnapshotPath) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self writeScreenSnapshot];
            [NSApp terminate:nil];
        });
    }
    if (_settingsSnapshotPath) {
        [self showSettings:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self writeSettingsSnapshot];
            [NSApp terminate:nil];
        });
    }
}

// Half resolution is plenty to judge the border; a gray fill and a black notch stand in for the screen.
- (void)writeScreenSnapshot {
    NSView *view = _overlay.contentView;
    NSRect bounds = view.bounds;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:(NSInteger)NSWidth(bounds) pixelsHigh:(NSInteger)NSHeight(bounds)
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
        bytesPerRow:0 bitsPerPixel:0];
    CGContextRef context = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep].CGContext;
    CGContextSetRGBFillColor(context, 0.45, 0.5, 0.58, 1);
    CGContextFillRect(context, bounds);
    if (_hasNotch) {
        NSRect notch = NSOffsetRect(_notchRect, -NSMinX(_screenFrame), -NSMinY(_screenFrame));
        CGPathRef housing = CGPathCreateWithRoundedRect(CGRectMake(NSMinX(notch), NSMinY(notch), NSWidth(notch), NSHeight(notch) + 12), 9, 9, NULL);
        CGContextSetRGBFillColor(context, 0, 0, 0, 1);
        CGContextAddPath(context, housing);
        CGContextFillPath(context);
        CGPathRelease(housing);
    }
    [view displayIfNeeded];
    [view.layer renderInContext:context];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:_screenSnapshotPath atomically:YES];
    NSLog(@"overlay=%@ visible=%d", NSStringFromRect(_overlay.frame), _overlay.visible);
}

- (void)writeSettingsSnapshot {
    NSView *view = _settingsWindow.window.contentView;
    NSRect bounds = view.bounds;
    CGFloat scale = _settingsWindow.window.backingScaleFactor;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:(NSInteger)(NSWidth(bounds) * scale) pixelsHigh:(NSInteger)(NSHeight(bounds) * scale)
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
        bytesPerRow:0 bitsPerPixel:0];
    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    CGContextScaleCTM(context.CGContext, scale, scale);
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = context;
    [view.effectiveAppearance performAsCurrentDrawingAppearance:^{
        [NSColor.windowBackgroundColor setFill];
        NSRectFill(bounds);
    }];
    [NSGraphicsContext restoreGraphicsState];
    // Flipped content view: flip the context so the layer tree draws upright.
    CGContextTranslateCTM(context.CGContext, 0, NSHeight(bounds));
    CGContextScaleCTM(context.CGContext, 1, -1);
    [view displayIfNeeded];
    [view.layer renderInContext:context.CGContext];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:_settingsSnapshotPath atomically:YES];
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
    if (_hasNotch) { // stand-in for the camera housing: the full notch rect with rounded bottom corners
        CGFloat w = NSWidth(_notchRect), h = NSHeight(_notchRect);
        CGRect hardware = CGRectMake([self notchCenterInPanel] - w / 2, NSHeight(bounds) - h, w, h + 12);
        CGPathRef housing = CGPathCreateWithRoundedRect(hardware, 9, 9, NULL);
        CGContextSetRGBFillColor(context, 0, 0, 0, 1);
        CGContextAddPath(context, housing);
        CGContextFillPath(context);
        CGPathRelease(housing);
    }
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

    _ringView = [[RingView alloc] initWithFrame:_container.bounds coreWidth:3 glowWidth:8];
    _ringView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [_container addSubview:_ringView];

    _overlay = [OverlayPanel new];
    _screenRing = [[RingView alloc] initWithFrame:NSZeroRect coreWidth:4 glowWidth:16];
    _screenRing.maxFrameRate = 30; // a full-screen animation; 30 fps keeps the battery cost down
    __weak OverlayPanel *overlay = _overlay;
    _screenRing.onHidden = ^{ [overlay orderOut:nil]; };
    _overlay.contentView = _screenRing;

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
    [self updateRingAnimated:!_snapshotPath];
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
    [self updateRingAnimated:YES];
}

#pragma mark Ring

// Shown while any task is unchecked, the panel is closed and the ring isn't paused.
- (void)updateRingAnimated:(BOOL)animated {
    if (!_ringView || !_ring) return;
    BOOL wanted = _store.openCount > 0 && !_ring.isPaused;
    [self keepFlashScheduled:wanted];
    BOOL lit = wanted && (!_ring.flash || _flashOn); // in flash style, only during a flash
    NSArray<NSColor *> *colors = _ring.colors;
    _ringView.fadeInDuration = _screenRing.fadeInDuration = _ring.flash ? 0.08 : 0.4;

    // Around the notch only, hidden while the panel is open (the panel covers the notch anyway).
    CGFloat w = NSWidth(_notchRect), h = NSHeight(_notchRect);
    NSRect notch = NSMakeRect([self notchCenterInPanel] - w / 2, NSHeight(_container.bounds) - h, w, h);
    CGPathRef notchPath = CreateRingPath(notch, 4);
    [_ringView setPath:notchPath spinCenter:CGPointMake(NSMidX(notch), NSMaxY(notch)) spinRadius:hypot(w / 2 + 24, h + 24)
                colors:colors period:_ring.period intensity:_ring.brightness];
    CGPathRelease(notchPath);
    [_ringView setShown:lit && !_ring.wholeScreen && _hasNotch && !_isOpen animated:animated];

    // Around the whole screen; its top edge dips around the notch too.
    BOOL screenShown = lit && _ring.wholeScreen;
    if (screenShown) {
        if (!NSEqualRects(_overlay.frame, _screenFrame)) [_overlay setFrame:_screenFrame display:NO];
        NSRect bounds = NSMakeRect(0, 0, NSWidth(_screenFrame), NSHeight(_screenFrame));
        CGRect notchHere = _hasNotch ? NSOffsetRect(_notchRect, -NSMinX(_screenFrame), -NSMinY(_screenFrame)) : CGRectNull;
        CGPathRef border = CreateScreenBorderPath(bounds, notchHere, 2);
        [_screenRing setPath:border spinCenter:CGPointMake(NSMidX(bounds), NSMidY(bounds))
                  spinRadius:hypot(NSWidth(bounds), NSHeight(bounds)) / 2 + 20
                      colors:colors period:_ring.period intensity:_ring.brightness];
        CGPathRelease(border);
        [_overlay orderFrontRegardless];
    }
    [_screenRing setShown:screenShown animated:animated];
}

- (void)ringSettingsChanged {
    NSString *flashKey = [NSString stringWithFormat:@"%d-%.0f-%.0f", _ring.flash, _ring.flashMin, _ring.flashMax];
    if (![flashKey isEqual:_flashKey]) {
        BOOL justTurnedOn = _ring.flash && _flashKey && ![_flashKey hasPrefix:@"1-"];
        _flashKey = flashKey;
        _flashGeneration++; // start over with the new timing
        _flashScheduled = NO;
        _flashOn = NO;
        if (justTurnedOn && _store.openCount > 0 && !_ring.isPaused) {
            _flashScheduled = YES; // show one flash right away so you can see what it looks like
            [self flashStep:0 generation:_flashGeneration];
        }
    }
    [self updateRingAnimated:!_snapshotPath];
    [_settingsWindow refresh];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(ringTick) object:nil];
    if (_ring.isPaused) {
        NSTimeInterval left = _ring.pausedUntil - NSDate.date.timeIntervalSince1970;
        [self performSelector:@selector(ringTick) withObject:nil afterDelay:left + 0.5];
    }
}

// In flash style, keep exactly one flash scheduled while there's something to remind you of.
- (void)keepFlashScheduled:(BOOL)wanted {
    if (!_ring.flash || !wanted) {
        if (_flashScheduled || _flashOn) {
            _flashGeneration++;
            _flashScheduled = NO;
            _flashOn = NO;
        }
        return;
    }
    if (_flashScheduled) return;
    _flashScheduled = YES;
    NSUInteger generation = ++_flashGeneration;
    NSTimeInterval delay = _ring.nextFlashDelay;
    if (_logFlashes) NSLog(@"next flash in %.1fs", delay);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self flashStep:0 generation:generation];
    });
}

// A flash is two quick blinks: on 0.6 s, off 0.25 s, on 1 s. Then it waits for the next random time.
- (void)flashStep:(int)step generation:(NSUInteger)generation {
    if (generation != _flashGeneration) return;
    static const double kStepLengths[] = {0.6, 0.25, 1.0};
    if (step < 3) {
        if (step == 0 && _logFlashes) NSLog(@"flash");
        _flashOn = step % 2 == 0;
        [self updateRingAnimated:YES];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kStepLengths[step] * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self flashStep:step + 1 generation:generation];
        });
    } else {
        _flashOn = NO;
        _flashScheduled = NO; // lets the update below schedule the next flash
        [self updateRingAnimated:YES];
    }
}

- (void)ringTick {
    [self updateRingAnimated:YES];
    [_settingsWindow refresh];
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
    [self updateRingAnimated:YES];

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
    [self updateRingAnimated:YES];

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
    NSMenuItem *pause = [menu addItemWithTitle:(_ring.isPaused ? @"Resume Ring Now" : @"Pause Ring for 30 Minutes")
                                        action:@selector(togglePause:) keyEquivalent:@""];
    pause.target = self;
    NSMenuItem *settings = [menu addItemWithTitle:@"Settings…" action:@selector(showSettings:) keyEquivalent:@""];
    settings.target = self;
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

- (void)togglePause:(id)sender {
    if (_ring.isPaused) [_ring resume];
    else [_ring pause];
}

- (void)showSettings:(id)sender {
    // Menu actions fire while the menu is still tracking, so wait a beat before closing the panel.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self closeForce:YES];
        if (!self->_settingsWindow) self->_settingsWindow = [[SettingsWindowController alloc] initWithSettings:self->_ring];
        [self->_settingsWindow show];
    });
}

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
