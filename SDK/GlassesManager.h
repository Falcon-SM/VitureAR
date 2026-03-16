#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

@interface GlassesManager : NSObject

+ (instancetype)sharedManager;

- (BOOL)setupAndConnect;

- (void)startStreamingWithHandler:(void (^)(CVPixelBufferRef leftBuffer, CVPixelBufferRef rightBuffer))handler;

@end
