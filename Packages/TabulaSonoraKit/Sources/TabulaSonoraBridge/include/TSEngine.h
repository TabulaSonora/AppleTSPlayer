#import <Foundation/Foundation.h>

#import "TSTypes.h"

NS_ASSUME_NONNULL_BEGIN

/// Errors raised by the engine. `NSLocalizedDescriptionKey` carries the library's own message,
/// which names what it found and what it wanted.
extern NSErrorDomain const TSEngineErrorDomain;

typedef NS_ERROR_ENUM(TSEngineErrorDomain, TSEngineError) {
    /// The file is not the `SCCore.dll` build the engine is pinned to.
    TSEngineErrorROMIdentity = 1,
    /// The file could not be read, or could not be parsed as anything the engine understands.
    TSEngineErrorUnreadable = 2,
    /// The operation needs a ROM, a song, or both, and one is missing.
    TSEngineErrorNotReady = 3,
};

/// The DLL build the engine is pinned to.
///
/// The engine reads its wave ROM and synth tables out of a `SCCore.dll` the user supplies from a
/// licensed SOUND Canvas VA install, and it refuses any other build. These are the values it checks
/// against, surfaced so the import UI can name the file it wants and so a build can be
/// sanity-checked without a ROM present.
@interface TSROMIdentity : NSObject

@property (nonatomic, readonly) NSString *fileName;
@property (nonatomic, readonly) NSString *product;
@property (nonatomic, readonly) NSString *version;
/// Exact file size in bytes -- 27,347,456.
@property (nonatomic, readonly) int64_t length;
/// Lower-case hex SHA-256 of the whole file.
@property (nonatomic, readonly) NSString *sha256;

/// The identity compiled into the embedded table manifest. Needs no ROM.
@property (class, nonatomic, readonly) TSROMIdentity *pinned;

@end

/// One part's state, as of the last block the render thread produced.
@interface TSPartState : NSObject

/// `port * 16 + channel`.
@property (nonatomic, readonly) NSInteger index;
@property (nonatomic, readonly) NSInteger program;
@property (nonatomic, readonly) NSInteger bank;
@property (nonatomic, readonly) NSInteger volume;
@property (nonatomic, readonly) NSInteger expression;
@property (nonatomic, readonly) NSInteger pan;
/// Voices this part is sounding, including any fading after being stolen.
@property (nonatomic, readonly) NSInteger voices;
@property (nonatomic, readonly) BOOL muted;
@property (nonatomic, readonly) BOOL soloed;
/// Whether the loaded song addresses this part at all.
@property (nonatomic, readonly) BOOL present;

/// Whether this part is sounding drums *now* -- not whether it is the drum channel. GS can route
/// any part to the drum path over SysEx and XG does it from bank select alone.
@property (nonatomic, readonly) BOOL drums;
/// The kit sounding on a drum part, or -1.
@property (nonatomic, readonly) NSInteger kit;
/// The tone map this part resolves against, which under XG is not the engine's configured one.
@property (nonatomic, readonly) TSToneMap map;
/// The sounding instrument's name -- the tone's, or the kit's on a drum part.
@property (nonatomic, readonly) NSString *name;

@end

/// Everything a redraw needs, taken on the render thread and copied out.
@interface TSSnapshot : NSObject

@property (nonatomic, readonly) BOOL hasROM;
@property (nonatomic, readonly) BOOL hasSong;
@property (nonatomic, readonly) BOOL paused;
@property (nonatomic, readonly) BOOL looping;
/// Whether the song has been rendered past its end plus the tail. Never true while looping.
@property (nonatomic, readonly) BOOL complete;

/// Frames at 32 kHz. This is what is *audible*, which lags what has been rendered by the ring.
@property (nonatomic, readonly) int64_t position;
@property (nonatomic, readonly) int64_t length;

@property (nonatomic, readonly) NSInteger activeVoices;
@property (nonatomic, readonly) NSInteger voiceCapacity;
@property (nonatomic, readonly) NSInteger noteCount;
@property (nonatomic, readonly) NSInteger drumKit;
/// Whether the engine is in XG mode right now -- a file switches this mid-song.
@property (nonatomic, readonly) BOOL xgMode;

/// How many times the audio callback came up short. Never hide this.
@property (nonatomic, readonly) int64_t underruns;
@property (nonatomic, readonly) float peakLeft;
@property (nonatomic, readonly) float peakRight;

/// As many parts as the engine has ports for -- 16, 32 or 64.
@property (nonatomic, readonly) NSArray<TSPartState *> *parts;

@end

/// The engine, its render thread and its ring.
///
/// Every method here is safe to call from one controlling thread while playback runs. The engine
/// itself is single-threaded by contract; this class is what keeps that true.
@interface TSEngine : NSObject

/// The engine's frame rate. Always 32 kHz -- resampling to the device is the host's job.
@property (class, nonatomic, readonly) double sampleRate;

/// Opens a `SCCore.dll` and builds the engine over it.
///
/// `verifyFully` hashes all 27 MB, which takes a moment; pass NO for a file already verified once,
/// which then checks only size and PE timestamp.
- (BOOL)loadROMAtPath:(NSString *)path
          verifyFully:(BOOL)verifyFully
                error:(NSError **)error;

/// Loads a MIDI file. Reads far more than SMF -- RIFF-MIDI, MIDS, MUS, XMI, GMF, HMI, Mobile XMF
/// and LDS are all converted on the way in.
- (BOOL)loadSongAtPath:(NSString *)path error:(NSError **)error;

- (void)unloadSong;

@property (nonatomic, readonly, nullable) NSString *romName;
@property (nonatomic, readonly, nullable) NSString *songName;

@property (nonatomic, getter=isPaused) BOOL paused;

/// How far ahead of the device to render, in milliseconds.
///
/// Lower means a live keyboard answers sooner and a seek is heard sooner; higher leaves more room
/// for the render thread to be descheduled without the callback coming up short. Takes effect at
/// the next block and never reallocates, so it is safe to drag a slider against.
@property (nonatomic) NSInteger latencyMilliseconds;

/// The range `latencyMilliseconds` is clamped to.
@property (class, nonatomic, readonly) NSInteger minimumLatencyMilliseconds;
@property (class, nonatomic, readonly) NSInteger maximumLatencyMilliseconds;
@property (nonatomic, getter=isLooping) BOOL looping;

/// Jumps the song to a frame, replaying the controllers up to it.
- (void)seekToFrame:(int64_t)frame;

/// Silences everything and returns every part to its power-on state.
- (void)panic;

/// Rebuilds the generator if anything structural changed; applies gain live if not.
- (void)applySettings:(TSEngineSettings)settings;

- (void)setMuted:(BOOL)muted forPart:(NSInteger)part;
- (void)setSoloed:(BOOL)soloed forPart:(NSInteger)part;
- (void)resetChannels;

/// One channel voice message -- live MIDI and the on-screen keyboard. Never blocks on a render.
- (void)sendChannelOnPort:(NSInteger)port
                   status:(NSInteger)status
                    data1:(NSInteger)data1
                    data2:(NSInteger)data2;

- (TSSnapshot *)snapshot;

/// Renders the loaded song to a WAV at `path`, on the calling thread, while playback continues.
///
/// `progress` is called with a fraction in [0, 1]; return NO from it to abort. It is called from
/// the calling thread.
- (BOOL)exportWAVToPath:(NSString *)path
               progress:(BOOL (^_Nullable)(double))progress
                  error:(NSError **)error;

/// The ring the audio callback reads. Pass to `TSEngineRingRead`; valid for this engine's lifetime.
@property (nonatomic, readonly) void *ringHandle NS_RETURNS_INNER_POINTER;

@end

#ifdef __cplusplus
extern "C" {
#endif

/// Fills one block from the ring, zero-padding whatever it could not supply. Returns the frames
/// actually supplied.
///
/// Real-time safe by construction: no Objective-C dispatch, no lock, no allocation, no engine code.
/// This is the only part of the bridge an audio callback may touch.
///
/// The linkage is spelled out because the definition lives in Objective-C++: without it the
/// definition would be mangled as C++ and Swift, which reads this header as Objective-C, would look
/// for a symbol nobody defined.
extern uint32_t TSEngineRingRead(void *ringHandle, float *left, float *right, uint32_t frames);

#ifdef __cplusplus
} // extern "C"
#endif

NS_ASSUME_NONNULL_END
