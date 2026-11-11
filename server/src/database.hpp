#pragma once
#include <nlohmann/json.hpp>
#include <sqlite3.h>
#include <mutex>
#include <string>
#include <vector>

namespace music {
using Json = nlohmann::json;
class Database {
 public:
  explicit Database(const std::string& path);
  ~Database();
  Database(const Database&) = delete;
  Database& operator=(const Database&) = delete;
  // Callers hold mutex across compound read/modify operations.
  std::recursive_mutex mutex;
  Json query(const std::string& sql, const std::vector<Json>& args = {});
  void execute(const std::string& sql, const std::vector<Json>& args = {});
 private:
  sqlite3* db_ = nullptr;
};
}
