#pragma once
#include "database.hpp"
#include "security.hpp"
#include "process.hpp"
#include <filesystem>
#include <map>
#include <thread>

namespace music {
struct Response {
  int status = 200;
  Json body = Json::object();
  std::map<std::string, std::string> headers;
  std::filesystem::path file;
  uint64_t offset = 0, length = 0;
};
struct Request {
  std::string method, path, authorization;
  Json body = Json::object();
  std::string range, offset;
};
class Service {
 public:
  explicit Service(const std::filesystem::path& config_file, bool start_worker = true,
                   ProcessRunner runner = run_process);
  ~Service();
  Response handle(const Request& request);
  std::string add_user(const std::string& name, const std::string& password);
 private:
  Json config_;
  std::filesystem::path root_;
  Database db_;
  ProcessRunner run_;
  std::jthread worker_;
  int lock_fd_ = -1;
  Json authenticate(const std::string& authorization);
  Json session(const std::string& user_id, const std::string& session_id = "");
  Json public_job(const Json& job);
  Json user_sources(const std::string& user);
  void work(std::stop_token stop);
  void perform(const Json& job, std::stop_token stop);
};
}
