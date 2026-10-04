#include "TSStateLog.hpp"

#include "tabulasonora/control_decode.hpp"

#include <iterator>

namespace ts::apple {

namespace {

/// Room for a long session's worth of distinct controllers and a generous opening dump. The
/// controllers coalesce, so what actually fills this is SysEx, and 32,768 entries over a megabyte
/// of SysEx is well past any bulk dump a GS or XG file carries.
constexpr std::size_t state_entries = 32768;
constexpr std::size_t state_bytes = 1 << 20;

/// Whether a message resets the module, using the same tests the engine applies before acting on
/// one -- a reset the engine would ignore must not empty the log either.
bool is_reset(std::span<const std::uint8_t> bytes) noexcept
{
    // GM System On, and the GM2 form. GM System Off is not a reset: the engine leaves XG mode on
    // it and does nothing else unless it was in XG mode.
    if (bytes.size() >= 6 && bytes[1] == 0x7E && bytes[3] == 0x09) {
        return bytes[4] == 0x01 || bytes[4] == 0x03;
    }

    // XG System On and All Parameter Reset.
    if (bytes.size() >= 8 && bytes[1] == 0x43) {
        const XgMessage kind = decode_xg_sysex(bytes).kind;
        return kind == XgMessage::system_on || kind == XgMessage::all_parameter_reset;
    }

    // GS: a DT1 with a good checksum to `40 00 7F` (GS Reset, or its exit form) or `00 00 7F`
    // (System Mode Set). Both arrive at the engine as a full reset.
    if (bytes.size() < 11 || bytes[1] != 0x41 || bytes[3] != 0x42 || bytes[4] != 0x12) {
        return false;
    }
    unsigned int sum = 0;
    for (std::size_t i = 5; i + 1 < bytes.size(); ++i) {
        sum += bytes[i];
    }
    if (sum % 0x80 != 0) {
        return false;
    }
    return (bytes[5] == 0x40 || bytes[5] == 0x00) && bytes[6] == 0x00 && bytes[7] == 0x7F;
}

/// Whether a controller sets a value outright, so that a later one on the same channel makes an
/// earlier one redundant. Data entry, increment and decrement, and the parameter numbers they act
/// on, mean something only in sequence and are kept as sent.
bool controller_coalesces(int controller) noexcept
{
    switch (controller) {
    case 6:  // Data entry MSB
    case 38: // Data entry LSB
    case 96: // Data increment
    case 97: // Data decrement
    case 98: // NRPN LSB
    case 99: // NRPN MSB
    case 100: // RPN LSB
    case 101: // RPN MSB
        return false;
    default:
        return true;
    }
}

} // namespace

MessageLog::MessageLog(std::size_t entries, std::size_t bytes)
{
    entries_.reserve(entries);
    bytes_.reserve(bytes);
}

bool MessageLog::push_channel(int port, int status, int data1, int data2) noexcept
{
    if (entries_.size() == entries_.capacity()) {
        return false;
    }
    entries_.push_back(Entry{static_cast<std::uint8_t>(port),
                             static_cast<std::uint8_t>(status),
                             static_cast<std::uint8_t>(data1),
                             static_cast<std::uint8_t>(data2),
                             0,
                             0});
    return true;
}

bool MessageLog::push_sysex(int port, std::span<const std::uint8_t> bytes) noexcept
{
    if (entries_.size() == entries_.capacity()
        || bytes.size() > bytes_.capacity() - bytes_.size()) {
        return false;
    }
    const auto offset = static_cast<std::uint32_t>(bytes_.size());
    bytes_.insert(bytes_.end(), bytes.begin(), bytes.end());
    entries_.push_back(Entry{static_cast<std::uint8_t>(port),
                             0xF0,
                             0,
                             0,
                             offset,
                             static_cast<std::uint32_t>(bytes.size())});
    return true;
}

void MessageLog::clear() noexcept
{
    entries_.clear();
    bytes_.clear();
}

StateLog::StateLog() : log_{state_entries, state_bytes} {}

void StateLog::record_channel(int port, int status, int data1, int data2) noexcept
{
    const int type = status & 0xF0;
    if (type < 0xB0 || type > 0xE0) {
        // Notes and poly pressure, and anything that is not a channel message at all.
        return;
    }
    if (type == 0xB0 && (data1 == 120 || data1 == 123)) {
        // All Sound Off and All Notes Off act on voices, and a new generator has none.
        return;
    }

    const bool coalesces = type != 0xB0 || controller_coalesces(data1);
    if (coalesces) {
        auto& entries = log_.entries();
        for (auto it = entries.rbegin(); it != entries.rend(); ++it) {
            if (it->is_sysex()) {
                break;
            }
            if (it->port == port && it->status == status && (type != 0xB0 || it->data1 == data1)) {
                entries.erase(std::next(it).base());
                break;
            }
        }
    }

    log_.push_channel(port, status, data1, data2);
}

void StateLog::record_sysex(int port, std::span<const std::uint8_t> bytes) noexcept
{
    if (bytes.size() < 2 || bytes[0] != 0xF0) {
        return;
    }
    if (is_reset(bytes)) {
        log_.clear();
    }
    log_.push_sysex(port, bytes);
}

void StateLog::replay(ToneGenerator& engine) const
{
    // Handed over all at once, so the input queue's 2,048-packet bound -- what the module drops
    // from a stream that outruns a control tick -- would otherwise cut off the end of a log that
    // took the stream minutes to build up.
    const ToneGenerator::StateReplay replaying{engine};

    for (const auto& entry : log_.entries()) {
        if (entry.is_sysex()) {
            engine.send_sysex(entry.port, log_.sysex(entry));
        } else {
            engine.send_channel(entry.port, entry.status, entry.data1, entry.data2);
        }
    }
}

} // namespace ts::apple
