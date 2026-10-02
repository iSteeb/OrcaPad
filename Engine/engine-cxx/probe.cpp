#include "probe.h"

const char *cxx_probe_version() {
    return "cxx-engine 0.1 (arm64 static, built on Linux)";
}

int cxx_probe_stl_test(int n) {
    std::vector<std::string> words;
    words.reserve((size_t)n);
    for (int i = 0; i < n; ++i) words.push_back(std::string("word") + std::to_string(i));
    int total = 0;
    for (const auto &w : words) total += (int)w.size();
    return total;
}
