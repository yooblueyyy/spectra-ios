// Sing and Reverb, done to every buffer Spotify's output unit finishes, before the speaker, under either
// look. Written for Spectra iOS.
//
// Sing turns the song's vocals down the way a karaoke machine does: lead vocals are mixed to the middle
// of the stereo image, so the part both channels share (mid = (L + R) / 2) is taken down, but only in
// the voice's band (about 120 Hz to 7 kHz): the kick and the bass below it and the cymbals above it stay,
// and everything panned to the sides (side = (L - R) / 2) is untouched. At 1 the band of the middle is
// gone; in between it is lowered. Mono sound has no sides to keep and is left alone.
//
// Reverb is a small room built from eight parallel feedback comb filters, each damped by a one-pole low
// pass, into four series all-pass filters, per channel, the right channel's delays a little longer than
// the left's so the tail is wide.
//
// The output unit is found the way the other audio features find it: Spotify's import of
// AudioOutputUnitStart is rebound (Core/SGRebind.h), each rebinding calling the one before, and a render
// notify goes on the RemoteIO unit it starts. The buffers are in the unit's output format, the
// hardware's, read when the unit starts.
//
// Threading: the notify runs on the render thread and touches only atomics and this file's static
// buffers, never allocating, locking or logging. Spotify starts its output on its audio thread. The
// setters are main thread.
#import <AudioToolbox/AudioToolbox.h>
#import <stdatomic.h>
#import "Core/SGCore.h"
#import "Core/SGRebind.h"
#import "Spectra.h"

enum { kChannels = 2, kMaxFrames = 4096, kCombs = 8, kAllpasses = 4, kCombMax = 4096, kAllpassMax = 1536, kSpread = 23 };

// Freeverb's tunings are delays in samples at 44.1 kHz; these are the same idea with lengths of our own,
// mutually prime so the echoes do not line up, scaled to the hardware's rate.
static const int kCombLengths[kCombs] = {1103, 1181, 1277, 1361, 1433, 1499, 1567, 1621};
static const int kAllpassLengths[kAllpasses] = {223, 349, 443, 563};

#pragma mark - parameters, any thread

static atomic_uint sg_singBits, sg_reverbBits, sg_roomBits;
static atomic_uint_fast64_t sg_rateBits;
static atomic_uint sg_formatFlags, sg_formatBytes, sg_formatChannels;
static atomic_uint sg_generation;     // bumped when the format changes, so the render thread starts over
static atomic_bool sg_started;

static float loadFloat(atomic_uint *slot) {
    uint32_t bits = atomic_load_explicit(slot, memory_order_relaxed);
    float value;
    memcpy(&value, &bits, sizeof value);
    return value;
}

static void storeFloat(atomic_uint *slot, float value) {
    uint32_t bits;
    memcpy(&bits, &value, sizeof bits);
    atomic_store(slot, bits);
}

static double loadRate(void) {
    uint64_t bits = atomic_load(&sg_rateBits);
    double rate;
    memcpy(&rate, &bits, sizeof rate);
    return rate;
}

#pragma mark - render thread state

// A second order filter, RBJ's cookbook form, transposed direct form II.
typedef struct { float b0, b1, b2, a1, a2, z1, z2; } Biquad;

static inline float biquad(Biquad *f, float x) {
    float y = f->b0 * x + f->z1;
    f->z1 = f->b1 * x - f->a1 * y + f->z2;
    f->z2 = f->b2 * x - f->a2 * y;
    return y;
}

static void designPass(Biquad *f, double rate, double frequency, BOOL high) {
    double w = 2 * M_PI * frequency / rate, cosw = cos(w), alpha = sin(w) / (2 * M_SQRT1_2);
    double a0 = 1 + alpha;
    double b1 = high ? -(1 + cosw) : 1 - cosw, b0 = high ? (1 + cosw) / 2 : (1 - cosw) / 2;
    f->b0 = (float)(b0 / a0);
    f->b1 = (float)(b1 / a0);
    f->b2 = (float)(b0 / a0);
    f->a1 = (float)(-2 * cosw / a0);
    f->a2 = (float)((1 - alpha) / a0);
    f->z1 = f->z2 = 0;
}

typedef struct {
    float buffer[kCombMax];
    int length, index;
    float store;
} Comb;

typedef struct {
    float buffer[kAllpassMax];
    int length, index;
} Allpass;

static struct {
    unsigned generation;
    BOOL ready;
    Biquad high, low;                         // the voice's band of the middle
    Comb combs[kChannels][kCombs];
    Allpass allpasses[kChannels][kAllpasses];
    float left[kMaxFrames], right[kMaxFrames];
} sg_fx;

// Sizes the filters for `rate` and silences them. Only on the render thread, once per format.
static void prepare(double rate) {
    double scale = rate / 44100.0;
    designPass(&sg_fx.high, rate, 120, YES);
    designPass(&sg_fx.low, rate, 7000, NO);
    for (int c = 0; c < kChannels; c++) {
        for (int i = 0; i < kCombs; i++) {
            Comb *comb = &sg_fx.combs[c][i];
            comb->length = MIN((int)((kCombLengths[i] + c * kSpread) * scale), kCombMax);
            comb->index = 0;
            comb->store = 0;
            memset(comb->buffer, 0, sizeof comb->buffer);
        }
        for (int i = 0; i < kAllpasses; i++) {
            Allpass *pass = &sg_fx.allpasses[c][i];
            pass->length = MIN((int)((kAllpassLengths[i] + c * kSpread) * scale), kAllpassMax);
            pass->index = 0;
            memset(pass->buffer, 0, sizeof pass->buffer);
        }
    }
    sg_fx.ready = rate > 0;
}

static inline float reverbSample(int channel, float input, float feedback, float damp) {
    float out = 0;
    for (int i = 0; i < kCombs; i++) {
        Comb *comb = &sg_fx.combs[channel][i];
        float delayed = comb->buffer[comb->index];
        comb->store = delayed * (1 - damp) + comb->store * damp;
        comb->buffer[comb->index] = input + comb->store * feedback;
        if (++comb->index >= comb->length) comb->index = 0;
        out += delayed;
    }
    for (int i = 0; i < kAllpasses; i++) {
        Allpass *pass = &sg_fx.allpasses[channel][i];
        float delayed = pass->buffer[pass->index];
        float next = -out + delayed;
        pass->buffer[pass->index] = out + delayed * 0.5f;
        if (++pass->index >= pass->length) pass->index = 0;
        out = next;
    }
    return out;
}

static void process(float *left, float *right, UInt32 frames, float sing, float mix, float room) {
    float feedback = 0.70f + 0.27f * room, damp = 0.35f, input = 0.015f, wet = mix * 2.4f, dry = 1 - 0.35f * mix;
    for (UInt32 i = 0; i < frames; i++) {
        float l = left[i], r = right ? right[i] : left[i];
        if (sing > 0 && right) {
            float mid = (l + r) * 0.5f, side = (l - r) * 0.5f;
            float voice = biquad(&sg_fx.low, biquad(&sg_fx.high, mid));
            mid -= voice * sing;
            l = mid + side;
            r = mid - side;
        }
        if (mix > 0) {
            float in = (l + r) * input;
            float wl = reverbSample(0, in, feedback, damp), wr = reverbSample(1, in, feedback, damp);
            l = l * dry + wl * wet;
            r = r * dry + wr * wet;
        }
        left[i] = l;
        if (right) right[i] = r;
    }
}

#pragma mark - render thread: reading and writing the hardware's format

static inline float readSample(const void *data, UInt32 index, UInt32 bytes, BOOL isFloat, UInt32 fraction) {
    if (bytes == 4) {
        if (isFloat) return ((const float *)data)[index];
        int32_t value = ((const int32_t *)data)[index];
        return fraction ? (float)((double)value / (double)(1u << fraction)) : (float)(value / 2147483648.0);
    }
    return ((const int16_t *)data)[index] / 32768.0f;
}

static inline void writeSample(void *data, UInt32 index, float value, UInt32 bytes, BOOL isFloat, UInt32 fraction) {
    if (bytes == 4 && isFloat) {
        ((float *)data)[index] = value;
        return;
    }
    value = fmaxf(-1, fminf(value, 1));
    if (bytes == 4) {
        double scale = fraction ? (double)(1u << fraction) : 2147483647.0;
        ((int32_t *)data)[index] = (int32_t)(value * scale);
    } else {
        ((int16_t *)data)[index] = (int16_t)(value * 32767);
    }
}

static OSStatus rendered(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp, UInt32 bus,
                         UInt32 frames, AudioBufferList *data) {
    if (!(*flags & kAudioUnitRenderAction_PostRender) || bus != 0 || !data || !data->mNumberBuffers || !frames) return noErr;
    float sing = loadFloat(&sg_singBits), mix = loadFloat(&sg_reverbBits);
    if (sing <= 0 && mix <= 0) return noErr;
    if (frames > kMaxFrames) return noErr;

    unsigned generation = atomic_load_explicit(&sg_generation, memory_order_acquire);
    if (!sg_fx.ready || sg_fx.generation != generation) {
        sg_fx.generation = generation;
        prepare(loadRate());
        if (!sg_fx.ready) return noErr;
    }

    UInt32 formatFlags = atomic_load_explicit(&sg_formatFlags, memory_order_relaxed);
    UInt32 bytes = atomic_load_explicit(&sg_formatBytes, memory_order_relaxed);
    UInt32 channels = atomic_load_explicit(&sg_formatChannels, memory_order_relaxed);
    BOOL isFloat = (formatFlags & kAudioFormatFlagIsFloat) != 0;
    BOOL split = (formatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    UInt32 fraction = (formatFlags & kLinearPCMFormatFlagsSampleFractionMask) >> kLinearPCMFormatFlagsSampleFractionShift;
    if ((bytes != 2 && bytes != 4) || channels < 1 || channels > kChannels) return noErr;
    if (split ? data->mNumberBuffers != channels : data->mNumberBuffers != 1 || data->mBuffers[0].mNumberChannels != channels) return noErr;
    for (UInt32 b = 0; b < data->mNumberBuffers; b++) {
        if (!data->mBuffers[b].mData || data->mBuffers[b].mDataByteSize < frames * bytes * (split ? 1 : channels)) return noErr;
    }
    // Silence still goes through the reverb, so its tail rings out instead of stopping dead.
    BOOL silent = (*flags & kAudioUnitRenderAction_OutputIsSilence) != 0;
    if (silent && mix <= 0) return noErr;

    BOOL direct = split && isFloat && bytes == 4 && !silent;
    float *lanes[kChannels] = {sg_fx.left, sg_fx.right};
    for (UInt32 c = 0; c < channels; c++) {
        if (direct) {
            lanes[c] = data->mBuffers[c].mData;
            continue;
        }
        const void *source = data->mBuffers[split ? c : 0].mData;
        for (UInt32 i = 0; i < frames; i++) lanes[c][i] = silent ? 0 : readSample(source, split ? i : i * channels + c, bytes, isFloat, fraction);
    }
    process(lanes[0], channels > 1 ? lanes[1] : NULL, frames, sing, mix, loadFloat(&sg_roomBits));
    if (direct) return noErr;
    for (UInt32 c = 0; c < channels; c++) {
        void *target = data->mBuffers[split ? c : 0].mData;
        for (UInt32 i = 0; i < frames; i++) writeSample(target, split ? i : i * channels + c, lanes[c][i], bytes, isFloat, fraction);
    }
    *flags &= ~kAudioUnitRenderAction_OutputIsSilence;
    return noErr;
}

#pragma mark - Spotify's audio thread

static OSStatus (*sg_startOutput)(AudioUnit unit);

static BOOL isRemoteIO(AudioUnit unit) {
    AudioComponentDescription description = {0};
    if (!unit || AudioComponentGetDescription(AudioComponentInstanceGetComponent(unit), &description) != noErr) return NO;
    return description.componentType == kAudioUnitType_Output && description.componentSubType == kAudioUnitSubType_RemoteIO;
}

static OSStatus startOutput(AudioUnit unit) {
    if (unit && isRemoteIO(unit)) {
        AudioStreamBasicDescription format = {0};
        UInt32 size = sizeof format;
        if (AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, &size) == noErr
            && format.mFormatID == kAudioFormatLinearPCM && format.mSampleRate > 0) {
            uint64_t bits;
            memcpy(&bits, &format.mSampleRate, sizeof bits);
            atomic_store(&sg_rateBits, bits);
            atomic_store(&sg_formatFlags, format.mFormatFlags);
            atomic_store(&sg_formatBytes, format.mBitsPerChannel / 8);
            atomic_store(&sg_formatChannels, format.mChannelsPerFrame);
            atomic_fetch_add(&sg_generation, 1);
            AudioUnitRemoveRenderNotify(unit, rendered, NULL);
            if (AudioUnitAddRenderNotify(unit, rendered, NULL) == noErr) atomic_store(&sg_started, true);
            SGLog(@"spectra fx: on Spotify's output, %.0f Hz, %u channels, %u bits, flags 0x%x", format.mSampleRate,
                  (unsigned)format.mChannelsPerFrame, (unsigned)format.mBitsPerChannel, (unsigned)format.mFormatFlags);
        }
    }
    return sg_startOutput ? sg_startOutput(unit) : kAudioUnitErr_Uninitialized;
}

#pragma mark - the sliders

static float stored(NSString *key, float fallback) {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return [value respondsToSelector:@selector(floatValue)] ? fmaxf(0, fminf([value floatValue], 1)) : fallback;
}

static void store(NSString *key, float value, atomic_uint *slot) {
    value = fmaxf(0, fminf(value, 1));
    [NSUserDefaults.standardUserDefaults setFloat:value forKey:key];
    storeFloat(slot, value);
}

float SPXSing(void) { return loadFloat(&sg_singBits); }
void SPXSetSing(float amount) { store(SPXKeySing, amount, &sg_singBits); }
float SPXReverb(void) { return loadFloat(&sg_reverbBits); }
void SPXSetReverb(float mix) { store(SPXKeyReverb, mix, &sg_reverbBits); }
float SPXReverbRoom(void) { return loadFloat(&sg_roomBits); }
void SPXSetReverbRoom(float room) { store(SPXKeyReverbRoom, room, &sg_roomBits); }
BOOL SPXEffectsReady(void) { return atomic_load(&sg_started); }

%ctor {
    storeFloat(&sg_singBits, stored(SPXKeySing, 0));
    storeFloat(&sg_reverbBits, stored(SPXKeyReverb, 0));
    storeFloat(&sg_roomBits, stored(SPXKeyReverbRoom, 0.5f));
    if (!SGRebindImport("AudioOutputUnitStart", startOutput, (void **)&sg_startOutput) || !sg_startOutput) {
        sg_startOutput = NULL;
        SGLog(@"spectra fx: Spotify does not import AudioOutputUnitStart, Sing and Reverb are off");
    }
}
