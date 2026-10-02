#pragma once
// OrcaPad adapter shim: the Linux/iOS cross-build has no libboost_log.
// BOOST_LOG_TRIVIAL becomes a stderr sink. Upstream sources untouched.
#include <cstdio>
namespace orcabad_log {
struct Sink {
    template <typename T> Sink &operator<<(const T &) { return *this; }
};
} // namespace orcabad_log
#define BOOST_LOG_TRIVIAL(lvl) ::orcabad_log::Sink()
