#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Objective-C обёртка над SoundTouch — той самой библиотекой, что была
/// вкомпилирована в оригинальный Talking Bacteria (символы `soundtouch::SoundTouch`,
/// селектор `initWithPitch:bufferSize:`). Питч-шифт без изменения длительности.
@interface SoundTouchProcessor : NSObject

/// Полутона вверх. В оригинале голос задирался примерно на 8–10 полутонов.
@property (nonatomic) double pitchSemitones;

/// Темп (1.0 — исходная скорость). Меняется независимо от высоты тона.
@property (nonatomic) double tempo;

/// Возвращает nil при недопустимых параметрах (частота > 192 кГц, каналов > 16).
- (nullable instancetype)initWithSampleRate:(double)sampleRate channels:(NSUInteger)channels;

/// Обрабатывает весь буфер целиком и возвращает готовые float-сэмплы.
/// Возвращает nil, если вход пустой или обработчик не готов.
- (nullable NSData *)processFloatSamples:(const float *)samples
                              frameCount:(NSUInteger)frameCount;

/// Удобный вариант для массива чисел (медленнее, для отладки).
- (nullable NSData *)processFloatArray:(NSArray<NSNumber *> *)samples;

+ (NSString *)versionString;

@end

NS_ASSUME_NONNULL_END