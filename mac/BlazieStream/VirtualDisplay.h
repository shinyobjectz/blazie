// CoreGraphics' virtual display SPI (macOS 11+), as used by DeskPad, BetterDisplay and others.
// Not in the public SDK headers; the classes ship in CoreGraphics.framework.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) dispatch_queue_t queue;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) uint32_t maxPixelsWide;
@property (nonatomic) uint32_t maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) uint32_t productID;
@property (nonatomic) uint32_t vendorID;
@property (nonatomic) uint32_t serialNum;
@property (copy, nonatomic) void (^terminationHandler)(id, id);
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)refreshRate;
@property (readonly, nonatomic) NSUInteger width;
@property (readonly, nonatomic) NSUInteger height;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@property (nonatomic) uint32_t hiDPI;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (readonly, nonatomic) CGDirectDisplayID displayID;
@end
