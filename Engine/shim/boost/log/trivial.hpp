#pragma once
// OrcaPad adapter shim: the Linux/iOS cross-build has no libboost_log.
// BOOST_LOG_TRIVIAL becomes a null sink (message discarded — os_log covers
// app-side logging). Handles stream manipulators (std::endl etc.).
#include <ostream>
namespace orcabad_log {
struct Sink {
    template <typename T> Sink &operator<<(const T &) { return *this; }
    Sink &operator<<(std::ostream &(*)(std::ostream &)) { return *this; }
};
} // namespace orcabad_log
#define BOOST_LOG_TRIVIAL(lvl) ::orcabad_log::Sink()
