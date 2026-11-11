#pragma once
#include <cstdint>
#include <filesystem>
#include <stdexcept>
#include <string>
#include <utility>

namespace music {
struct Error : std::runtime_error {
  int status;
  Error(int s, const std::string& message) : std::runtime_error(message), status(s) {}
};
std::string random_token();
std::string digest(const std::string& value);
std::string password_hash(const std::string& password, const std::string& salt);
bool equal_secret(const std::string& a, const std::string& b);
int64_t now();
bool valid_id(const std::string& id);
std::filesystem::path confined_file(const std::filesystem::path& root, const std::string& relative);
std::pair<uint64_t, uint64_t> byte_range(const std::string& header, uint64_t size);
}
