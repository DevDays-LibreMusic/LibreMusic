#include "service.hpp"
#include "process.hpp"
#include <fstream>
#include <iostream>
#include <functional>

using namespace music;
void require(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
void rejects(const std::function<void()>& call) {
  try { call(); } catch (const Error&) { return; }
  throw std::runtime_error("Expected rejection");
}
int main() {
  const auto root = std::filesystem::temp_directory_path() / ("music-test-" + random_token());
  try {
    std::filesystem::create_directories(root / "imports");
    const auto config = root / "config.json";
    { std::ofstream file(config); file << Json{{"data_dir", (root / "data").string()}, {"sources", {
      {"alice", Json::array({{{"id", "collection"}, {"type", "storage"}, {"root", (root / "imports").string()}}})},
      {"bob", Json::array({{{"id", "collection"}, {"type", "storage"}, {"root", (root / "imports").string()}}})}
    }}}; }
    require(byte_range("bytes=2-4", 10) == std::pair<uint64_t,uint64_t>{2,3}, "closed range");
    require(byte_range("bytes=-3", 10) == std::pair<uint64_t,uint64_t>{7,3}, "suffix range");
    require(byte_range("bytes=8-", 10) == std::pair<uint64_t,uint64_t>{8,2}, "open range");
    rejects([] { byte_range("bytes=10-", 10); });
    rejects([] { byte_range("bytes=0-1,4-5", 10); });
    rejects([] { byte_range("bytes=18446744073709551616-", 10); });
    rejects([&] { confined_file(root / "imports", "../config.json"); });
    std::filesystem::create_symlink(config, root / "imports" / "escape");
    rejects([&] { confined_file(root / "imports", "escape"); });
    Service service(config);
    service.add_user("alice", "alice-password-example");
    service.add_user("bob", "bob-password-example");
    auto call = [&](std::string method, std::string path, Json body = Json::object(), std::string token = "", std::string range = "") {
      return service.handle({method, path, token.empty() ? "" : "Bearer " + token, body, range, ""});
    };
    auto login = call("POST", "/v1/auth/login", {{"username", "alice"}, {"password", "alice-password-example"}});
    require(login.status == 200, "login");
    const std::string alice = login.body["access_token"], refresh = login.body["refresh_token"];
    const std::string bob = call("POST", "/v1/auth/login", {{"username", "bob"}, {"password", "bob-password-example"}}).body["access_token"];
    require(call("GET", "/v1/tracks").status == 401, "authentication required");
    require(call("POST", "/v1/auth/login", {{"username", "alice"}, {"password", "wrong"}}).status == 401, "bad password");
    run_process({"ffmpeg", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.1", (root / "imports" / "tone.flac").string()}, [] {});
    const Json request = {{"source", {{"connection_id", "collection"}, {"path", "tone.flac"}}}, {"title", "Fixture"}};
    auto prepare = call("POST", "/v1/playback/prepare", request, alice);
    require(prepare.status == 202, "prepare is asynchronous");
    const std::string id = prepare.body["id"];
    require(call("POST", "/v1/playback/prepare", request, alice).body["id"] == id, "deduplication");
    require(call("GET", "/v1/downloads/" + id, {}, bob).status == 404, "private status");
    require(call("POST", "/v1/downloads/" + id + "/cancel", {}, bob).status == 404, "private cancellation");
    require(call("POST", "/v1/assets/" + id + "/playback-ticket", {}, bob).status == 404, "private audio");
    Json job;
    for (int i = 0; i < 200; ++i) {
      job = call("GET", "/v1/downloads/" + id, {}, alice).body;
      if (job["state"] == "ready" || job["state"] == "failed") break;
      std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    require(job["state"] == "ready", "storage ingestion completes");
    auto ticket = call("POST", "/v1/assets/" + id + "/playback-ticket", {}, alice);
    const std::string path = ticket.body["path"];
    auto audio = call("GET", path, {}, "", "bytes=0-15");
    require(audio.status == 206 && audio.length == 16 && !audio.file.empty(), "range playback");
    require(call("HEAD", path).status == 200, "HEAD playback");
    auto invalid_range = call("GET", path, {}, "", "bytes=999999999-");
    require(invalid_range.status == 416 && invalid_range.headers.contains("Content-Range"), "range error");
    auto rotated = call("POST", "/v1/auth/refresh", {{"refresh_token", refresh}});
    require(rotated.status == 200, "refresh");
    require(call("POST", "/v1/auth/refresh", {{"refresh_token", refresh}}).status == 401, "refresh replay rejected");
    require(call("GET", "/v1/tracks", {}, alice).status == 401, "old access invalidated");
    require(call("POST", "/v1/auth/logout", {}, rotated.body["access_token"]).status == 200, "logout");
    require(call("GET", path).status == 404, "logout revokes tickets");
    require(call("GET", "/v1/tracks", {}, bob).body["items"].empty(), "private library");
    const auto recovery_config = root / "recovery.json";
    {
      std::ifstream input(config); Json value; input >> value;
      value["data_dir"] = (root / "recovery").string();
      std::ofstream output(recovery_config); output << value;
    }
    std::string recovery_access, recovery_job;
    {
      Service before_restart(recovery_config, false);
      before_restart.add_user("alice", "alice-password-example");
      recovery_access = before_restart.handle({"POST", "/v1/auth/login", "",
        {{"username", "alice"}, {"password", "alice-password-example"}}, "", ""}).body["access_token"];
      recovery_job = before_restart.handle({"POST", "/v1/playback/prepare", "Bearer " + recovery_access, request, "", ""}).body["id"];
      require(before_restart.handle({"POST", "/v1/downloads/" + recovery_job + "/cancel",
        "Bearer " + recovery_access, Json::object(), "", ""}).body["state"] == "cancelled", "cancel queued job");
      const auto retry = before_restart.handle({"POST", "/v1/playback/prepare",
        "Bearer " + recovery_access, request, "", ""});
      require(retry.body["id"] == recovery_job && retry.body["state"] == "queued", "retry cancelled job");
      Database persisted((root / "recovery/catalog.sqlite3").string());
      persisted.execute("UPDATE jobs SET state='downloading',attempts=1 WHERE id=?", {recovery_job});
    }
    {
      Service after_restart(recovery_config);
      Json recovered;
      for (int i = 0; i < 200; ++i) {
        recovered = after_restart.handle({"GET", "/v1/downloads/" + recovery_job,
          "Bearer " + recovery_access, Json::object(), "", ""}).body;
        if (recovered["state"] == "ready" || recovered["state"] == "failed") break;
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
      }
      require(recovered["state"] == "ready", "interrupted job resumes after restart");
    }
    std::cout << "Authentication, isolation, ingestion, deduplication, ranges and path checks passed\n";
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n'; std::filesystem::remove_all(root); return 1;
  }
  std::filesystem::remove_all(root);
}
