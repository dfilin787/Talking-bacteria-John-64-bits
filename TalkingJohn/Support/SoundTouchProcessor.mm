#import "SoundTouchProcessor.h"
#include "SoundTouch.h"

#include <vector>

@implementation SoundTouchProcessor {
    soundtouch::SoundTouch _engine;
    double _sampleRate;
    NSUInteger _channels;
    BOOL _ready;
}

- (instancetype)initWithSampleRate:(double)sampleRate channels:(NSUInteger)channels {
    self = [super init];
    if (self) {
        _sampleRate = sampleRate > 0 ? sampleRate : 44100.0;
        _channels = channels > 0 ? channels : 1;
        _pitchSemitones = 9.0;
        _tempo = 1.0;

        if (_sampleRate > 192000.0 || _channels > 16) { return nil; }

        _engine.setSampleRate((uint)_sampleRate);
        _engine.setChannels((uint)_channels);

        _engine.setSetting(SETTING_USE_QUICKSEEK, 0);
        _engine.setSetting(SETTING_USE_AA_FILTER, 1);
        _engine.setSetting(SETTING_AA_FILTER_LENGTH, 64);
        _engine.setPitchSemiTones(_pitchSemitones);
        _engine.setTempo(_tempo);
        _ready = YES;
    }
    return self;
}

- (void)setPitchSemitones:(double)pitchSemitones {
    _pitchSemitones = pitchSemitones;
    if (_ready) { _engine.setPitchSemiTones(pitchSemitones); }
}

- (void)setTempo:(double)tempo {
    _tempo = tempo;
    if (_ready) { _engine.setTempo(tempo); }
}

- (nullable NSData *)processFloatSamples:(const float *)samples
                              frameCount:(NSUInteger)frameCount {
    if (!_ready || samples == NULL || frameCount == 0) { return nil; }

    _engine.clear();
    _engine.setSampleRate((uint)_sampleRate);
    _engine.setChannels((uint)_channels);
    _engine.setPitchSemiTones(_pitchSemitones);
    _engine.setTempo(_tempo);

    _engine.putSamples(samples, (uint)frameCount);

    _engine.flush();

    const NSUInteger chunkFrames = 4096;
    std::vector<float> chunk(chunkFrames * _channels);
    NSMutableData *result = [NSMutableData dataWithCapacity:frameCount * sizeof(float) * _channels];

    uint received = 0;
    do {
        received = _engine.receiveSamples(chunk.data(), (uint)chunkFrames);
        if (received > 0) {
            [result appendBytes:chunk.data() length:received * _channels * sizeof(float)];
        }
    } while (received > 0);

    _engine.clear();
    return result.length > 0 ? result : nil;
}

- (nullable NSData *)processFloatArray:(NSArray<NSNumber *> *)samples {
    if (samples.count == 0) { return nil; }
    std::vector<float> raw(samples.count);
    for (NSUInteger i = 0; i < samples.count; i++) {
        raw[i] = samples[i].floatValue;
    }
    return [self processFloatSamples:raw.data() frameCount:raw.size()];
}

+ (NSString *)versionString {
    const char *version = soundtouch::SoundTouch::getVersionString();
    return version ? [NSString stringWithUTF8String:version] : @"unknown";
}

@end
