#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
NS_ASSUME_NONNULL_BEGIN
@interface FixtureReader : NSObject
- (nullable instancetype)initWithMap:(NSURL *)url;
- (NSDictionary *)readImage:(CGImageRef)image horizontalField:(double)degrees;
@end
NS_ASSUME_NONNULL_END
