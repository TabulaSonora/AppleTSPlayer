#import <AudioToolbox/AudioToolbox.h>
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

/// Bank select MSB, which carries the variation.
@property (nonatomic, readonly) NSInteger bank;

/// Bank select LSB, which on this module names the vintage: 1-4 pick one and 0 keeps the configured
/// default. Shown beside the MSB because the pair is what a patch list is indexed by, and either one
/// alone identifies nothing.
@property (nonatomic, readonly) NSInteger bankLSB;

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

/// The MIDI channel this part listens on, zero-based -- **not** its slot.
///
/// What a mixer row has to be labelled with. Parts are matched by their receive channel rather than
/// indexed by it, since GS can point several parts at one channel or detach one from every channel,
/// so `index % 16` names the right channel only until something moves a part.
///
/// -1 when no engine reported one, and 16 for the module's "off" -- a part detached from every
/// channel. Neither is a channel to label a row with.
@property (nonatomic, readonly) NSInteger rxChannel;
/// The tone map this part resolves against, which under XG is not the engine's configured one.
@property (nonatomic, readonly) TSToneMap map;

/// The bank the melodic lookup is given, which under XG is not the bank the part was sent. Naming
/// only what was sent would misdescribe what is sounding.
@property (nonatomic, readonly) NSInteger lookupBank;
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

/// The module a file asks to be played on, as far as it says so at all.
///
/// `unstated`, `gm` and `gm2` name no tone map on purpose -- a General MIDI file is content to play
/// on any of the vintages, and saying otherwise would invent an intent the file does not have. The
/// rest share their raw values with `TSToneMap`.
///
/// These must track `ts::apple::SongVintage`; the mapping in `TSEngine.mm` is a switch rather than a
/// cast so a divergence is a compiler error rather than a wrong answer.
typedef NS_ENUM(NSInteger, TSSongVintage) {
    TSSongVintageUnstated = 0,
    TSSongVintageGM = 1,
    TSSongVintageGM2 = 2,
    TSSongVintageSC55 = 1 << 8,
    TSSongVintageSC88,
    TSSongVintageSC88Pro,
    TSSongVintageSC8820,
    TSSongVintageXG,
};

/// A marker meta event, and where in the song it falls.
@interface TSSongMarker : NSObject

@property (nonatomic, readonly) NSString *text;
/// Frames at 32 kHz, matching `TSSnapshot.position` -- so this can be handed straight to a seek.
@property (nonatomic, readonly) int64_t position;

@end

/// One track of the file, in the order the file stores them.
@interface TSSongTrack : NSObject

/// 1-based, counting every MTrk including a format-1 tempo track that plays nothing.
@property (nonatomic, readonly) NSInteger number;
/// FF 03, Sequence/Track Name.
@property (nonatomic, readonly) NSString *name;
/// FF 04, Instrument Name. Apart from `name` because a file may carry both, and because FF 04
/// doubles as a port tag in files predating FF 09.
@property (nonatomic, readonly) NSString *instrument;
/// Channels this track sends voice messages on, ascending and zero-based.
@property (nonatomic, readonly) NSArray<NSNumber *> *channels;
/// Note-ons with non-zero velocity. What makes a silent tempo track visibly silent.
@property (nonatomic, readonly) NSInteger notes;

@end

/// Everything the loaded file says about itself, beyond the events the engine plays.
///
/// Read once at load, from a walk of the file's own chunks: the engine's reader consumes and drops
/// every meta event except tempo, the port tags and the loop markers, which is right for a renderer
/// and leaves nothing for a reader.
///
/// A Standard MIDI File declares no text encoding, so the reader guesses one for the whole file and
/// the strings here have already been through it. `-[TSEngine songInfo]` is where that happens.
@interface TSSongInfo : NSObject

/// Whether a file was found and understood at all. Everything below is meaningless when NO.
@property (nonatomic, readonly, getter=isValid) BOOL valid;

/// Whether the bytes on disk were something other than a Standard MIDI File -- an XMI, a MUS, an
/// HMI -- and had to be converted to be read. The converter reports *that* it converted rather than
/// what from, so this is a flag and not a name.
@property (nonatomic, readonly, getter=isConverted) BOOL converted;

/// 0, 1 or 2, as the header declares.
@property (nonatomic, readonly) NSInteger format;
/// MTrk chunks found. Not the header's count, which malformed files get wrong.
@property (nonatomic, readonly) NSInteger trackCount;
/// Ticks per quarter note. Zero when the file uses SMPTE timing, which has no such thing.
@property (nonatomic, readonly) NSInteger division;

/// The *first* tempo the file sets, in bpm, or zero if it sets none. Not an average: a file that
/// ritards to a halt has a meaningful opening tempo and a meaningless mean.
@property (nonatomic, readonly) double initialTempoBPM;
/// How many times the file changes tempo -- whether the number above describes the piece or its
/// first bar.
@property (nonatomic, readonly) NSInteger tempoChanges;

/// FF 58, as "4/4". Empty when the file declares none.
@property (nonatomic, readonly) NSString *timeSignature;
/// FF 59, as "C major". Empty when the file declares none.
@property (nonatomic, readonly) NSString *keySignature;

@property (nonatomic, readonly) NSArray<TSSongTrack *> *tracks;

/// FF 02, Copyright Notice.
@property (nonatomic, readonly) NSString *copyright;
/// FF 01, Text, minus the Soft Karaoke `@` lines. Deduplicated in order of first appearance: a file
/// that repeats its credit once per track is common, and listing it seventeen times is not
/// information.
@property (nonatomic, readonly) NSArray<NSString *> *text;

/// FF 06, Marker, minus the ones that only mark the loop, ordered by position.
///
/// Not deduplicated by text, unlike `text`: a file that marks "Verse 1" twice is marking two
/// places. Only an exact repeat at the same tick is dropped.
@property (nonatomic, readonly) NSArray<TSSongMarker *> *markers;

/// The lyric sheet, as text, with no timing -- assembled from whichever of the three karaoke
/// dialects the file uses.
@property (nonatomic, readonly) NSString *lyrics;
/// Soft Karaoke's own `@T` header lines: conventionally the title, then the author.
@property (nonatomic, readonly) NSArray<NSString *> *karaokeHeadings;

/// Position of the final event, in frames at 32 kHz.
///
/// Here rather than read from a snapshot on purpose: the snapshot refreshes on a display tick,
/// which happens after the song name has already told everything watching that the file changed.
@property (nonatomic, readonly) int64_t length;

@property (nonatomic, readonly) BOOL hasLoop;
@property (nonatomic, readonly) int64_t loopStart;
@property (nonatomic, readonly) int64_t loopEnd;
/// Whether the file marked the end explicitly. A soft loop rewinds cleanly; a hard one has its end
/// inferred and replays controllers the way a seek does.
@property (nonatomic, readonly) BOOL loopSoft;

@property (nonatomic, readonly) TSSongVintage vintage;
/// "SC-88", "General MIDI" -- or empty when the file states nothing.
@property (nonatomic, readonly) NSString *vintageName;
/// The evidence for the verdict, for showing beside it: "GS Reset · bank select LSB 2". Ours rather
/// than the file's, so it is plain ASCII and needs no decoding.
@property (nonatomic, readonly) NSString *vintageEvidence;

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

/// What the loaded file says about itself.
///
/// Read once at load and copied out under the control lock, not sampled on the display tick: it is
/// static for the life of a song. Ask for it when the song name changes.
@property (nonatomic, readonly) TSSongInfo *songInfo;

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

/// Joins the render thread to the audio device's workgroup.
///
/// Pass the output node's `auAudioUnit`. Its `osWorkgroup` is unavailable from Swift on purpose --
/// the API is for real-time threads and the Swift runtime is not safe on one -- so the reading
/// happens here.
///
/// Without this the render thread is merely a high-priority thread, and a device that has decided
/// nothing is urgent (an iPhone with its screen off) stops scheduling it in time to keep the ring
/// fed while the callback goes on running to its deadline. That is heard as dropouts.
///
/// Call after the engine starts, and again after anything restarts it. Pass nil when it stops.
- (void)adoptWorkgroupFromAudioUnit:(nullable AUAudioUnit *)audioUnit;

@end

/// The engine as an instrument, for an Audio Unit to render from its own render block.
///
/// `TSEngine` above is the app's arrangement: a render thread runs ahead of the device and a ring
/// absorbs the difference. A plugin cannot have that. Its host decides when to call it and how much
/// to ask for, and during a bounce it asks far faster than realtime -- which a producer running at
/// wall-clock rate can never satisfy, so the ring would hand back silence for the one operation that
/// has to be exact.
///
/// This renders on the thread that asks, for exactly the frames asked for, and resamples the
/// engine's 32 kHz to whatever rate the host runs at.
///
/// Everything here is for the *control* side -- loading, settings, what the panel draws. The render
/// block uses the C functions below and touches nothing on this object.
@interface TSInstrument : NSObject

/// Opens a `SCCore.dll` and builds a new engine over it, then swaps it in.
///
/// Call off the main thread: the 27 MB is read and parsed here. Rendering continues throughout --
/// silent until this is the first ROM, and uninterrupted when it is not.
- (BOOL)loadROMAtPath:(NSString *)path
          verifyFully:(BOOL)verifyFully
                error:(NSError **)error;

@property (nonatomic, readonly, nullable) NSString *romName;
@property (nonatomic, readonly) BOOL hasROM;

/// What a panel shows, and all of it.
///
/// Published by the render block into atomics rather than captured on demand: a whole
/// `TSSnapshot` walks the voice pool and names every part, which is far too much to hold the
/// engine's lock for while the same lock is what the render block is trying to take. A panel
/// polling ten times a second for it would punch a block of silence into the audio ten times a
/// second. These three cost a load each and take nothing.
@property (nonatomic, readonly) NSInteger activeVoices;
@property (nonatomic, readonly) NSInteger voiceCapacity;
@property (nonatomic, readonly, getter=isXGMode) BOOL XGMode;

/// Rebuilds the generator unless only the gain moved. Costs the sounding voices, as it does in the
/// app, and one block of silence while it happens.
- (void)applySettings:(TSEngineSettings)settings;

/// Sizes the resampler for the host's rate and its largest block, and resets it.
///
/// Call from `allocateRenderResources`, which is where a plugin is allowed to allocate; nothing on
/// the render path allocates afterwards.
- (void)prepareForSampleRate:(double)sampleRate maximumFrames:(uint32_t)maximumFrames;

/// The delay to report to the host: the one input frame the interpolator looks ahead by.
@property (nonatomic, readonly) double latencySeconds;

/// Pass to the C functions below. Valid for this object's lifetime.
@property (nonatomic, readonly) void *handle NS_RETURNS_INNER_POINTER;

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

/// The plugin's render path, and the whole of what an Audio Unit's render block may touch.
///
/// Plain C for the same reason `TSEngineRingRead` is: a render block must reach the engine without
/// an Objective-C message send, a Swift runtime call or a retain. Every one of these takes the
/// `handle` from `TSInstrument`.
///
/// None of them blocks. They take the instrument's lock with `try_lock` and give up rather than
/// wait, so the worst a control change costs is one block of silence and the messages that arrived
/// during it -- and the only control change that can cause one is a rebuild, which was going to
/// take the sounding voices anyway.

/// Fills one block at the rate given to `prepareForSampleRate:maximumFrames:`, resampling from the
/// engine's 32 kHz. Fills silence when there is no ROM.
extern void TSInstrumentRender(void *handle, float *left, float *right, uint32_t frames);

/// One channel voice message. `port` is 0 to 3, addressing the sixteen parts of one port; the
/// engine folds a port past its configured count onto one that exists, so any value is safe.
extern void TSInstrumentSendChannel(void *handle, int32_t port, int32_t status, int32_t data1,
                                    int32_t data2);

/// One complete System Exclusive message, `F0` first and `F7` last. A host delivers these in
/// fragments; putting them back together is the caller's job.
extern void TSInstrumentSendSysEx(void *handle, int32_t port, const uint8_t *bytes, uint32_t length);

/// Linear gain on the finished mix, applied at the top of the next block.
extern void TSInstrumentSetGain(void *handle, double gain);

#ifdef __cplusplus
} // extern "C"
#endif

NS_ASSUME_NONNULL_END
