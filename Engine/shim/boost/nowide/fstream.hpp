#pragma once
// OrcaPad adapter shim: nowide streams over std streams.
#include <fstream>
namespace boost { namespace nowide {
using std::fstream;
using std::ifstream;
using std::ofstream;
}} // namespace boost::nowide
