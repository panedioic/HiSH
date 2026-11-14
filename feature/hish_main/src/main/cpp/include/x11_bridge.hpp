#pragma once

#include <cstdint>
#include <string>

namespace hish {
uint16_t StartX11Bridge(const std::string& endpoint);
void StopX11Bridge();
}
