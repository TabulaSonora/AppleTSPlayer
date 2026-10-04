#pragma once

#include "tabulasonora/tone_generator.hpp"

#include <cstddef>
#include <cstdint>
#include <span>
#include <vector>

namespace ts::apple {

/// MIDI messages in arrival order, SysEx included, in storage reserved up front.
///
/// Appending never allocates: both vectors are reserved at construction and a message that will
/// not fit is refused rather than grown into. That is the property the render thread needs, since
/// it is the one appending.
class MessageLog {
public:
    struct Entry {
        std::uint8_t port = 0;
        /// The status byte, or 0xF0 for a SysEx whose bytes are `[offset, offset + length)`.
        std::uint8_t status = 0;
        std::uint8_t data1 = 0;
        std::uint8_t data2 = 0;
        std::uint32_t offset = 0;
        std::uint32_t length = 0;

        [[nodiscard]] bool is_sysex() const noexcept { return status == 0xF0; }
    };

    MessageLog(std::size_t entries, std::size_t bytes);

    /// False when the log is full and the message was not kept.
    bool push_channel(int port, int status, int data1, int data2) noexcept;
    bool push_sysex(int port, std::span<const std::uint8_t> bytes) noexcept;

    void clear() noexcept;
    [[nodiscard]] bool empty() const noexcept { return entries_.empty(); }
    [[nodiscard]] std::size_t size() const noexcept { return entries_.size(); }

    [[nodiscard]] std::vector<Entry>& entries() noexcept { return entries_; }
    [[nodiscard]] const std::vector<Entry>& entries() const noexcept { return entries_; }

    [[nodiscard]] std::span<const std::uint8_t> sysex(const Entry& entry) const noexcept
    {
        return std::span<const std::uint8_t>{bytes_}.subspan(entry.offset, entry.length);
    }

private:
    std::vector<Entry> entries_;
    std::vector<std::uint8_t> bytes_;
};

/// Everything a live MIDI stream has told the module since it was last reset, kept so that a new
/// tone generator can be told it again.
///
/// A generator is rebuilt whenever a construction option moves -- vintage, polyphony, ports, a
/// host's sample rate -- and a plugin's first one does not exist at all until its ROM has finished
/// loading in the background. Either way the parts start at power-on, and whatever the stream had
/// set up is gone: a host that opened with a GS Reset and a use-for-rhythm SysEx goes on sending
/// notes to a part that is no longer a drum part, and a file's second drum channel plays its kit
/// number as a melodic program. Carrying six controllers and a program per part across a rebuild
/// was not enough for exactly that reason -- the routing, the drum maps and every other SysEx-set
/// parameter live nowhere a part's controllers can reach.
///
/// So the stream itself is kept, less what carries no state: notes, poly pressure, All Sound Off
/// and All Notes Off. A reset message (GM System On, GS Reset, XG System On or All Parameter Reset)
/// empties the log before being recorded, since nothing before it can matter afterwards.
///
/// A controller, program, channel pressure or pitch bend replaces the previous message of its kind
/// on its channel, which is what keeps a long session's automation from filling the log. The
/// replacement is moved to the end rather than overwritten in place, so it still lands after every
/// message that preceded it -- a Reset All Controllers sent between the two included. It never
/// reaches back past a SysEx, because a SysEx may have moved which part the channel reaches, and
/// the older message is then the only record of what the *other* part was told. Data entry and the
/// parameter numbers it applies to are kept verbatim, since their meaning is their order.
///
/// Bounded. A stream that outgrows it stops being recorded, and a rebuild after that restores what
/// was recorded before it.
class StateLog {
public:
    StateLog();

    void record_channel(int port, int status, int data1, int data2) noexcept;
    void record_sysex(int port, std::span<const std::uint8_t> bytes) noexcept;

    void clear() noexcept { log_.clear(); }
    [[nodiscard]] bool empty() const noexcept { return log_.empty(); }
    [[nodiscard]] std::size_t size() const noexcept { return log_.size(); }

    /// Sends everything recorded to `engine`, as a reconstruction rather than a stream: see
    /// `ToneGenerator::StateReplay`.
    void replay(ToneGenerator& engine) const;

private:
    MessageLog log_;
};

} // namespace ts::apple
