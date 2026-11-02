#import "CraftTimedInput.h"
#import <UIKit/UIKit.h>
#import <math.h>
#import <dlfcn.h>
#import <XCTest/XCTest.h>

// XCTest's own touch-record API is private. Look up classes and check every
// selector at runtime; unsupported Xcode versions fail rather than skipping or
// falling back to serialized taps. These declarations create no class linkage.
@interface NSObject (CraftTestingTouchRecords)
- (id)initForTouchAtPoint:(CGPoint)point offset:(double)offset;
- (void)moveToPoint:(CGPoint)point atOffset:(double)offset;
- (void)liftUpAtOffset:(double)offset;
- (id)initWithName:(NSString *)name interfaceOrientation:(NSInteger)orientation;
- (void)addPointerEventPath:(id)path;
- (BOOL)synthesizeWithError:(NSError **)error;
+ (id)eventStreamWithEventActions:(void (^)(id))actions;
- (void)advanceTime:(double)seconds;
- (void)touchDown:(CGPoint)point;
- (void)liftUp:(CGPoint)point;
- (id)underlyingPlayer;
- (BOOL)prewarmForEventStream:(id)stream withError:(NSError **)error;
- (void)setNeedsInitialDelay:(BOOL)value;
- (void)setIgnoresCompletionDelay:(BOOL)value;
- (void)playEventStream:(id)stream options:(id)options completion:(void (^)(void))completion;
- (void)tearDown;
@end

@implementation CraftTimedInput
+ (BOOL)fail:(NSString *)message error:(NSError **)error {
    if (error) *error = [NSError errorWithDomain:@"CraftTimedInput" code:1
                                      userInfo:@{NSLocalizedDescriptionKey: message}];
    return NO;
}

// The simulator's XCTest touch-path translator omits idle intervals between
// fingers and rounds stationary moves to its sample interval. Submit stationary,
// non-overlapping taps as one native HID stream with explicit clock advances.
// Moving/overlapping paths retain the existing XCTest gesture implementation.
+ (BOOL)synthesizeStationaryPaths:(NSArray *)paths frame:(CGRect)frame error:(NSError **)error {
    static dispatch_once_t once;
    static void *recap;
    dispatch_once(&once, ^{
        recap = dlopen("/System/Library/PrivateFrameworks/Recap.framework/Recap", RTLD_NOW | RTLD_LOCAL);
    });
    Class streamClass = NSClassFromString(@"RCPSyntheticEventStream");
    Class playerClass = NSClassFromString(@"RCPInlinePlayer");
    if (!recap || ![streamClass respondsToSelector:@selector(eventStreamWithEventActions:)])
        return [self fail:@"Native timed tap streams are unavailable on this runtime" error:error];
    for (NSString *name in @[@"advanceTime:", @"touchDown:", @"liftUp:"])
        if (![streamClass instancesRespondToSelector:NSSelectorFromString(name)])
            return [self fail:@"Native timed tap stream cannot preserve the schedule" error:error];
    for (NSString *name in @[@"underlyingPlayer", @"setNeedsInitialDelay:", @"setIgnoresCompletionDelay:",
                             @"playEventStream:options:completion:", @"tearDown"])
        if (![playerClass instancesRespondToSelector:NSSelectorFromString(name)])
            return [self fail:@"Native timed tap playback is unavailable" error:error];

    id stream = [streamClass eventStreamWithEventActions:^(id builder) {
        double previous = 0;
        for (NSArray *points in paths) {
            NSDictionary *first = points.firstObject, *last = points.lastObject;
            double start = [first[@"at"] doubleValue], end = [last[@"at"] doubleValue];
            CGPoint point = CGPointMake(frame.origin.x + [first[@"x"] doubleValue] * frame.size.width,
                                         frame.origin.y + [first[@"y"] doubleValue] * frame.size.height);
            [builder advanceTime:start - previous];
            [builder touchDown:point];
            [builder advanceTime:end - start];
            [builder liftUp:point];
            previous = end;
        }
    }];
    if (!stream) return [self fail:@"Native timed tap stream could not be constructed" error:error];
    id player = [playerClass new];
    id underlying = [player underlyingPlayer];
    if (![underlying respondsToSelector:@selector(prewarmForEventStream:withError:)]) {
        [player tearDown];
        return [self fail:@"Native timed tap delivery cannot be prepared" error:error];
    }
    // Preparing the HID delivery service emits no touches. Do not add a warm-up
    // touch or an initial/completion sleep to make the receiver appear reliable.
    if (![underlying prewarmForEventStream:stream withError:error]) {
        [player tearDown];
        return NO;
    }
    [player setNeedsInitialDelay:NO];
    [player setIgnoresCompletionDelay:YES];
    XCTestExpectation *done = [[XCTestExpectation alloc] initWithDescription:@"Native timed tap completion"];
    [player playEventStream:stream options:nil completion:^{
        [player tearDown];
        [done fulfill];
    }];
    // Validated streams end within 12s. A timeout is a failure, never a retry.
    if ([XCTWaiter waitForExpectations:@[done] timeout:20] != XCTWaiterResultCompleted)
        return [self fail:@"Native timed tap playback did not complete" error:error];
    return YES;
}

+ (BOOL)synthesizePaths:(NSArray *)paths frame:(CGRect)frame error:(NSError **)error {
    if (![paths isKindOfClass:NSArray.class] || paths.count == 0 || paths.count > 64
        || CGRectIsEmpty(frame) || !isfinite(frame.size.width) || !isfinite(frame.size.height))
        return [self fail:@"Expected 1–64 timed touch paths and a visible app frame" error:error];
    // Validate the entire record before any native event is submitted.
    for (id path in paths) {
        if (![path isKindOfClass:NSArray.class] || [path count] < 2 || [path count] > 64)
            return [self fail:@"Each touch needs 2–64 points" error:error];
        double previous = -1;
        for (id point in path) {
            if (![point isKindOfClass:NSDictionary.class]) return [self fail:@"Invalid touch point" error:error];
            for (NSString *key in @[@"x", @"y", @"at"]) {
                id value = point[key];
                if (![value isKindOfClass:NSNumber.class] || !isfinite([value doubleValue]))
                    return [self fail:@"Touch coordinates and times must be finite numbers" error:error];
            }
            double x = [point[@"x"] doubleValue], y = [point[@"y"] doubleValue], at = [point[@"at"] doubleValue];
            if (x < 0 || x > 1 || y < 0 || y > 1 || at < 0 || at > 12 || at <= previous)
                return [self fail:@"Touch coordinates must be normalized; times must increase within 12 seconds" error:error];
            previous = at;
        }
    }
    NSArray *ordered = [paths sortedArrayUsingComparator:^NSComparisonResult(NSArray *left, NSArray *right) {
        return [left.firstObject[@"at"] compare:right.firstObject[@"at"]];
    }];
    BOOL stationary = [ordered.firstObject[0][@"at"] doubleValue] == 0;
    double previousEnd = 0;
    for (NSArray *points in ordered) {
        NSDictionary *first = points.firstObject;
        if ([first[@"at"] doubleValue] < previousEnd) stationary = NO;
        for (NSDictionary *point in points)
            if ([point[@"x"] doubleValue] != [first[@"x"] doubleValue]
                || [point[@"y"] doubleValue] != [first[@"y"] doubleValue]) stationary = NO;
        previousEnd = [points.lastObject[@"at"] doubleValue];
    }
    if (stationary) return [self synthesizeStationaryPaths:ordered frame:frame error:error];

    Class recordClass = NSClassFromString(@"XCSynthesizedEventRecord");
    Class pathClass = NSClassFromString(@"XCPointerEventPath");
    for (NSString *name in @[@"initWithName:interfaceOrientation:", @"addPointerEventPath:", @"synthesizeWithError:"])
        if (![recordClass instancesRespondToSelector:NSSelectorFromString(name)])
            return [self fail:@"XCTest does not support timed native event records" error:error];
    for (NSString *name in @[@"initForTouchAtPoint:offset:", @"moveToPoint:atOffset:", @"liftUpAtOffset:"])
        if (![pathClass instancesRespondToSelector:NSSelectorFromString(name)])
            return [self fail:@"XCTest does not support timed native touch paths" error:error];
    id record = [[recordClass alloc] initWithName:@"Craft timed native input" interfaceOrientation:UIInterfaceOrientationPortrait];
    if (!record) return [self fail:@"XCTest refused a native event record" error:error];
    for (NSArray *points in paths) {
        NSDictionary *first = points.firstObject;
        CGPoint start = CGPointMake(frame.origin.x + [first[@"x"] doubleValue] * frame.size.width,
                                    frame.origin.y + [first[@"y"] doubleValue] * frame.size.height);
        id path = [[pathClass alloc] initForTouchAtPoint:start offset:[first[@"at"] doubleValue]];
        if (!path) return [self fail:@"XCTest refused a native touch path" error:error];
        for (NSUInteger index = 1; index < points.count; index++) {
            NSDictionary *point = points[index];
            CGPoint location = CGPointMake(frame.origin.x + [point[@"x"] doubleValue] * frame.size.width,
                                           frame.origin.y + [point[@"y"] doubleValue] * frame.size.height);
            [path moveToPoint:location atOffset:[point[@"at"] doubleValue]];
        }
        [path liftUpAtOffset:[points.lastObject[@"at"] doubleValue]];
        [record addPointerEventPath:path];
    }
    // One dispatch preserves the existing moving/overlapping gesture path.
    // Individual XCUICoordinate.tap() calls would wait for app quiescence.
    return [record synthesizeWithError:error];
}
@end
