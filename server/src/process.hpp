#pragma once
#include <functional>
#include <string>
#include <vector>

namespace music {
using ProcessRunner = std::function<std::string(const std::vector<std::string>&,
                                               const std::function<void()>&, int)>;
// No shell interpolation. Child and its descendants are terminated on cancellation.
std::string run_process(const std::vector<std::string>& args,
                        const std::function<void()>& checkpoint, int timeout_seconds = 900);
}
