#include "security.hpp"
#include <openssl/crypto.h>
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <algorithm>
#include <array>
#include <charconv>
#include <chrono>

namespace music {
namespace {
std::string hex(const unsigned char* data, size_t length) {
  constexpr char digits[] = "0123456789abcdef";
  std::string result;
  for (size_t i = 0; i < length; ++i) {
    result += digits[data[i] >> 4]; result += digits[data[i] & 15];
  }
  return result;
}
uint64_t integer(std::string_view value) {
  uint64_t n = 0;
  auto [end, ec] = std::from_chars(value.data(), value.data() + value.size(), n);
  if (ec != std::errc{} || end != value.data() + value.size()) throw Error(416, "invalid_range");
  return n;
}
}
std::string random_token() {
  std::array<unsigned char, 32> value{};
  if (RAND_bytes(value.data(), value.size()) != 1) throw std::runtime_error("Random generator failed");
  return hex(value.data(), value.size());
}
std::string digest(const std::string& value) {
  std::array<unsigned char, EVP_MAX_MD_SIZE> result{};
  unsigned int length = 0;
  if (EVP_Digest(value.data(), value.size(), result.data(), &length, EVP_sha256(), nullptr) != 1)
    throw std::runtime_error("Digest failed");
  return hex(result.data(), length);
}
std::string password_hash(const std::string& password, const std::string& salt) {
  std::array<unsigned char, 32> result{};
  if (PKCS5_PBKDF2_HMAC(password.data(), password.size(),
      reinterpret_cast<const unsigned char*>(salt.data()), salt.size(), 600000,
      EVP_sha256(), result.size(), result.data()) != 1) throw std::runtime_error("Password hashing failed");
  return hex(result.data(), result.size());
}
bool equal_secret(const std::string& a, const std::string& b) {
  return a.size() == b.size() && CRYPTO_memcmp(a.data(), b.data(), a.size()) == 0;
}
int64_t now() {
  return std::chrono::duration_cast<std::chrono::seconds>(
      std::chrono::system_clock::now().time_since_epoch()).count();
}
bool valid_id(const std::string& id) {
  return id.size() == 64 && id.find_first_not_of("0123456789abcdef") == std::string::npos;
}
std::filesystem::path confined_file(const std::filesystem::path& root, const std::string& relative) {
  const std::filesystem::path part(relative);
  if (part.empty() || part.is_absolute()) throw Error(400, "invalid_storage_path");
  for (const auto& segment : part) if (segment == "..") throw Error(400, "invalid_storage_path");
  const auto base = std::filesystem::canonical(root);
  const auto target = std::filesystem::canonical(base / part);
  const auto inside = target.lexically_relative(base);
  if (inside.empty() || *inside.begin() == ".." || !std::filesystem::is_regular_file(target))
    throw Error(400, "invalid_storage_path");
  return target;
}
std::pair<uint64_t, uint64_t> byte_range(const std::string& header, uint64_t size) {
  if (!size) throw Error(416, "invalid_range");
  if (header.empty()) return {0, size};
  if (!header.starts_with("bytes=") || header.find(',') != std::string::npos) throw Error(416, "invalid_range");
  const std::string_view value(header.data() + 6, header.size() - 6);
  const auto dash = value.find('-');
  if (dash == std::string_view::npos) throw Error(416, "invalid_range");
  const auto left = value.substr(0, dash), right = value.substr(dash + 1);
  if (left.empty()) {
    const auto count = std::min(integer(right), size);
    if (!count) throw Error(416, "invalid_range");
    return {size - count, count};
  }
  const auto start = integer(left);
  const auto end = right.empty() ? size - 1 : std::min(integer(right), size - 1);
  if (start >= size || end < start) throw Error(416, "invalid_range");
  return {start, end - start + 1};
}
}
