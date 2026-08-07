#import "TSEngine.h"

#include "TSPlayer.hpp"

#include "tabulasonora/rom_image.hpp"
#include "tabulasonora/table_manifest.hpp"

#include <memory>
#include <stdexcept>
#include <string>

NSErrorDomain const TSEngineErrorDomain = @"co.losno.TabulaSonora.EngineError";

namespace {

NSString *to_ns(const std::string &value)
{
    return [[NSString alloc] initWithBytes:value.data()
                                    length:static_cast<NSUInteger>(value.size())
                                  encoding:NSUTF8StringEncoding]
        ?: @"";
}

std::string to_std(NSString *value)
{
    return value.UTF8String ? std::string{value.UTF8String} : std::string{};
}

void fill_error(NSError **error, TSEngineError code, const std::string &message)
{
    if (error == nullptr) {
        return;
    }
    *error = [NSError errorWithDomain:TSEngineErrorDomain
                                 code:code
                             userInfo:@{NSLocalizedDescriptionKey: to_ns(message)}];
}

} // namespace

#pragma mark - TSROMIdentity

@implementation TSROMIdentity

- (instancetype)initWithIdentity:(const ts::DllIdentity &)identity
{
    self = [super init];
    if (self) {
        _fileName = to_ns(identity.file_name);
        _product = to_ns(identity.product);
        _version = to_ns(identity.version);
        _length = identity.size;
        _sha256 = to_ns(identity.sha256);
    }
    return self;
}

+ (TSROMIdentity *)pinned
{
    // The manifest is embedded (see manifest_json.generated.cpp), so this parses a compiled-in byte
    // span on first use and touches no file. That is what makes it usable as a build check.
    static TSROMIdentity *pinned;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pinned = [[TSROMIdentity alloc] initWithIdentity:ts::TableManifest::defaults().dll()];
    });
    return pinned;
}

@end

#pragma mark - TSPartState

@implementation TSPartState

- (instancetype)initWithState:(const ts::apple::PartState &)state index:(NSInteger)index
{
    self = [super init];
    if (self) {
        _index = index;
        _program = state.program;
        _bank = state.bank;
        _volume = state.volume;
        _expression = state.expression;
        _pan = state.pan;
        _voices = state.voices;
        _muted = state.muted;
        _soloed = state.soloed;
        _present = state.present;
        _drums = state.drums;
        _kit = state.kit;
        _map = static_cast<TSToneMap>(state.map);
        _name = to_ns(state.name);
    }
    return self;
}

@end

#pragma mark - TSSnapshot

@implementation TSSnapshot

- (instancetype)initWithSnapshot:(const ts::apple::SessionSnapshot &)snapshot
{
    self = [super init];
    if (self) {
        _hasROM = snapshot.hasROM;
        _hasSong = snapshot.hasSong;
        _paused = snapshot.paused;
        _looping = snapshot.looping;
        _complete = snapshot.complete;
        _position = snapshot.position;
        _length = snapshot.length;
        _activeVoices = snapshot.activeVoices;
        _voiceCapacity = snapshot.voiceCapacity;
        _noteCount = snapshot.noteCount;
        _drumKit = snapshot.drumKit;
        _xgMode = snapshot.xgMode;
        _underruns = snapshot.underruns;
        _peakLeft = snapshot.peakLeft;
        _peakRight = snapshot.peakRight;

        NSMutableArray<TSPartState *> *parts =
            [NSMutableArray arrayWithCapacity:static_cast<NSUInteger>(snapshot.partCount)];
        for (int index = 0; index < snapshot.partCount && index < TS_MAX_PARTS; ++index) {
            [parts addObject:[[TSPartState alloc]
                                 initWithState:snapshot.parts[static_cast<std::size_t>(index)]
                                         index:index]];
        }
        _parts = parts;
    }
    return self;
}

@end

#pragma mark - TSEngine

@implementation TSEngine {
    std::unique_ptr<ts::apple::Player> _player;
}

+ (double)sampleRate
{
    return static_cast<double>(ts::apple::Session::sample_rate);
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _player = std::make_unique<ts::apple::Player>();
    }
    return self;
}

- (BOOL)loadROMAtPath:(NSString *)path verifyFully:(BOOL)verifyFully error:(NSError **)error
{
    try {
        _player->load_rom(to_std(path), verifyFully);
        return YES;
    } catch (const ts::RomIdentityError &failure) {
        fill_error(error, TSEngineErrorROMIdentity, failure.what());
    } catch (const std::exception &failure) {
        fill_error(error, TSEngineErrorUnreadable, failure.what());
    }
    return NO;
}

- (BOOL)loadSongAtPath:(NSString *)path error:(NSError **)error
{
    try {
        _player->load_song(to_std(path));
        return YES;
    } catch (const std::exception &failure) {
        fill_error(error, TSEngineErrorUnreadable, failure.what());
    }
    return NO;
}

- (void)unloadSong
{
    _player->unload_song();
}

- (nullable NSString *)romName
{
    const std::string name = _player->rom_name();
    return name.empty() ? nil : to_ns(name);
}

- (nullable NSString *)songName
{
    const std::string name = _player->song_name();
    return name.empty() ? nil : to_ns(name);
}

- (BOOL)isPaused
{
    return _player->paused();
}

- (void)setPaused:(BOOL)paused
{
    _player->set_paused(paused);
}

- (BOOL)isLooping
{
    return _player->snapshot().looping;
}

- (void)setLooping:(BOOL)looping
{
    _player->set_looping(looping);
}

- (NSInteger)latencyMilliseconds
{
    return _player->latency_ms();
}

- (void)setLatencyMilliseconds:(NSInteger)milliseconds
{
    _player->set_latency_ms(static_cast<int>(milliseconds));
}

+ (NSInteger)minimumLatencyMilliseconds
{
    return ts::apple::Player::min_latency_ms;
}

+ (NSInteger)maximumLatencyMilliseconds
{
    return ts::apple::Player::max_latency_ms;
}

- (void)seekToFrame:(int64_t)frame
{
    _player->seek(frame);
}

- (void)panic
{
    _player->panic();
}

- (void)applySettings:(TSEngineSettings)settings
{
    _player->set_settings(settings);
}

- (void)setMuted:(BOOL)muted forPart:(NSInteger)part
{
    _player->set_muted(static_cast<int>(part), muted);
}

- (void)setSoloed:(BOOL)soloed forPart:(NSInteger)part
{
    _player->set_soloed(static_cast<int>(part), soloed);
}

- (void)resetChannels
{
    _player->reset_channels();
}

- (void)sendChannelOnPort:(NSInteger)port
                   status:(NSInteger)status
                    data1:(NSInteger)data1
                    data2:(NSInteger)data2
{
    _player->send_channel(static_cast<int>(port), static_cast<int>(status), static_cast<int>(data1),
                          static_cast<int>(data2));
}

- (TSSnapshot *)snapshot
{
    return [[TSSnapshot alloc] initWithSnapshot:_player->snapshot()];
}

- (BOOL)exportWAVToPath:(NSString *)path
               progress:(BOOL (^)(double))progress
                  error:(NSError **)error
{
    try {
        _player->export_wav(to_std(path), [progress](double fraction) {
            return progress ? static_cast<bool>(progress(fraction)) : true;
        });
        return YES;
    } catch (const std::exception &failure) {
        fill_error(error, TSEngineErrorNotReady, failure.what());
    }
    return NO;
}

- (void *)ringHandle
{
    return &_player->ring();
}

@end

uint32_t TSEngineRingRead(void *ringHandle, float *left, float *right, uint32_t frames)
{
    auto *ring = static_cast<ts::FrameRing *>(ringHandle);

    // Interleaved in the ring, planar out: `AVAudioSourceNode` is connected in the engine's own
    // standard (non-interleaved) format, so the split happens here rather than costing a converter.
    // Stack-allocated, so this still allocates nothing -- one block at the sizes CoreAudio asks for.
    constexpr uint32_t max_frames = 4096;
    if (frames > max_frames) {
        frames = max_frames;
    }

    float interleaved[max_frames * 2];
    const std::size_t supplied =
        ring->read(std::span<float>{interleaved, static_cast<std::size_t>(frames) * 2});

    for (uint32_t frame = 0; frame < frames; ++frame) {
        left[frame] = interleaved[frame * 2];
        right[frame] = interleaved[frame * 2 + 1];
    }

    // `read` counts frames, not the floats it was handed.
    return static_cast<uint32_t>(supplied);
}
