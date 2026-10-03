#pragma once
// OrcaPad adapter shim: route nowide streams to std streams.
#include <iostream>
namespace boost { namespace nowide {
using std::cin;
using std::cout;
using std::cerr;
}} // namespace boost::nowide
