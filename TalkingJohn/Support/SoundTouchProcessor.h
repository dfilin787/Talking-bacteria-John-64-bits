#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SoundTouchProcessor : NSObject

@property (nonatomic) double pitchSemitones;

@property (nonatomic) double tempo;

- (nullable instancetype)initWithSampleRate:(double)sampleRate channels:(NSUInteger)channels;

- (nullable NSData *)processFloatSamples:(const float *)samples
                              frameCount:(NSUInteger)frameCount;

- (nullable NSData *)processFloatArray:(NSArray<NSNumber *> *)samples;

+ (NSString *)versionString;

@end

NS_ASSUME_NONNULL_END
