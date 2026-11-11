#include "service.hpp"
#include <curl/curl.h>
#include <fstream>
#include <regex>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>

namespace music {
namespace {
Json read_config(const std::filesystem::path& file) {
  std::ifstream stream(file);
  Json config; stream >> config;
  const auto path = std::filesystem::path(config.at("data_dir").get<std::string>());
  if (!path.is_absolute()) throw std::runtime_error("data_dir must be absolute");
  std::filesystem::create_directories(path / "media");
  std::filesystem::create_directories(path / "staging");
  return config;
}
std::string field(const Json& json, const std::string& key, size_t limit = 2048) {
  if (!json.contains(key) || !json[key].is_string()) throw Error(400, "missing_" + key);
  const auto value = json[key].get<std::string>();
  if (value.empty() || value.size() > limit) throw Error(400, "invalid_" + key);
  return value;
}
}
Service::Service(const std::filesystem::path& config_file, bool start_worker, ProcessRunner runner)
    : config_(read_config(config_file)), root_(config_.at("data_dir").get<std::string>()),
      db_((root_ / "catalog.sqlite3").string()), run_(std::move(runner)) {
  if (curl_global_init(CURL_GLOBAL_DEFAULT) != CURLE_OK) throw std::runtime_error("HTTP initialization failed");
  if (start_worker) {
    lock_fd_ = open((root_ / "server.lock").c_str(), O_CREAT | O_RDWR | O_CLOEXEC, 0600);
    if (lock_fd_ < 0 || flock(lock_fd_, LOCK_EX | LOCK_NB)) {
      if (lock_fd_ >= 0) close(lock_fd_);
      throw std::runtime_error("Another server owns this data directory");
    }
    // Only the service owner performs recovery; the admin CLI may run concurrently.
    db_.execute("UPDATE jobs SET state=CASE WHEN attempts<3 THEN 'queued' ELSE 'failed' END, "
                "error='interrupted' WHERE state IN ('resolving','downloading','processing')");
    worker_ = std::jthread([this](std::stop_token stop) { work(stop); });
  }
}
Service::~Service() {
  if (worker_.joinable()) { worker_.request_stop(); worker_.join(); }
  if (lock_fd_ >= 0) close(lock_fd_);
  // libcurl may also be used by another service instance in tests.
}
std::string Service::add_user(const std::string& name, const std::string& password) {
  if (!std::regex_match(name, std::regex("[a-zA-Z0-9_.-]{1,64}")) || password.size() < 12 || password.size() > 1024)
    throw Error(400, "Use a simple username and a password of 12 to 1024 characters");
  const auto id = random_token(), salt = random_token();
  db_.execute("INSERT INTO users VALUES (?,?,?,?)", {id, name, salt, password_hash(password, salt)});
  return id;
}
Json Service::session(const std::string& user_id, const std::string& session_id) {
  const auto access = random_token(), refresh = random_token();
  const auto id = session_id.empty() ? random_token() : session_id;
  db_.execute("INSERT INTO sessions VALUES (?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET "
              "access=excluded.access,refresh=excluded.refresh,access_until=excluded.access_until,refresh_until=excluded.refresh_until",
              {id, user_id, digest(access), digest(refresh), now() + 1800, now() + 30 * 86400});
  return {{"access_token", access}, {"refresh_token", refresh}, {"expires_in", 1800}, {"user_id", user_id}};
}
Json Service::authenticate(const std::string& authorization) {
  if (!authorization.starts_with("Bearer ") || authorization.size() != 71) throw Error(401, "unauthorized");
  auto rows = db_.query("SELECT s.id,s.user_id,u.name FROM sessions s JOIN users u ON u.id=s.user_id "
                        "WHERE access=? AND access_until>? AND refresh_until>?",
                        {digest(authorization.substr(7)), now(), now()});
  if (rows.empty()) throw Error(401, "unauthorized");
  return rows[0];
}
Json Service::user_sources(const std::string& user) {
  return config_.value("sources", Json::object()).value(user, Json::array());
}
Json Service::public_job(const Json& job) {
  const auto request = Json::parse(job.at("request").get<std::string>());
  return {{"id", job.at("id")}, {"state", job.at("state")}, {"received_bytes", job.at("received")},
          {"total_bytes", job.at("total")}, {"error", job.at("error")},
          {"title", request.value("title", "")}, {"artist", request.value("artist", "")},
          {"mime", job.at("mime")}};
}
Response Service::handle(const Request& r) {
  Response out;
  out.headers["Cache-Control"] = "no-store";
  try {
    if (r.method == "GET" && r.path == "/health") { out.body = {{"status", "ok"}}; return out; }
    if (r.method == "POST" && r.path == "/v1/auth/login") {
      const auto name = field(r.body, "username", 64), password = field(r.body, "password", 1024);
      auto rows = db_.query("SELECT * FROM users WHERE name=?", {name});
      const std::string salt = rows.empty() ? std::string(64, '0') : rows[0]["salt"].get<std::string>();
      const auto hash = password_hash(password, salt);
      if (rows.empty() || !equal_secret(hash, rows[0]["password"])) throw Error(401, "invalid_credentials");
      std::lock_guard lock(db_.mutex);
      db_.execute("DELETE FROM sessions WHERE refresh_until<=?", {now()});
      if (db_.query("SELECT id FROM sessions WHERE user_id=?", {rows[0]["id"]}).size() >= 32)
        throw Error(429, "session_limit");
      out.body = session(rows[0]["id"]); return out;
    }
    if (r.method == "POST" && r.path == "/v1/auth/refresh") {
      std::lock_guard lock(db_.mutex);
      auto rows = db_.query("SELECT * FROM sessions WHERE refresh=? AND refresh_until>?",
                            {digest(field(r.body, "refresh_token", 64)), now()});
      if (rows.empty()) throw Error(401, "unauthorized");
      out.body = session(rows[0]["user_id"], rows[0]["id"]); return out;
    }
    if ((r.method == "GET" || r.method == "HEAD") && r.path.starts_with("/v1/media/")) {
      const auto ticket = r.path.substr(10);
      auto rows = db_.query("SELECT j.* FROM tickets t JOIN jobs j ON j.id=t.job_id "
                            "JOIN sessions s ON s.id=t.session_id WHERE t.token=? AND t.expires>? "
                            "AND s.refresh_until>? AND s.user_id=j.user_id AND j.state='ready'",
                            {digest(ticket), now(), now()});
      if (rows.empty()) throw Error(404, "media_unavailable");
      out.file = confined_file(root_ / "media", rows[0]["file"]);
      const auto size = std::filesystem::file_size(out.file);
      out.headers["Accept-Ranges"] = "bytes";
      try {
        const auto [start, count] = byte_range(r.range, size);
        out.offset = start; out.length = count;
      } catch (const Error&) {
        out.headers["Content-Range"] = "bytes */" + std::to_string(size);
        out.file.clear(); throw;
      }
      out.headers["Content-Type"] = rows[0]["mime"];
      out.headers["Content-Length"] = std::to_string(out.length);
      if (!r.range.empty()) {
        out.status = 206;
        out.headers["Content-Range"] = "bytes " + std::to_string(out.offset) + "-" +
            std::to_string(out.offset + out.length - 1) + "/" + std::to_string(size);
      }
      return out;
    }
    const auto auth = authenticate(r.authorization);
    const std::string uid = auth["user_id"], sid = auth["id"], username = auth["name"];
    if (r.method == "POST" && r.path == "/v1/auth/logout") {
      db_.execute("DELETE FROM sessions WHERE id=?", {sid}); out.body = {{"ok", true}}; return out;
    }
    if (r.method == "GET" && r.path == "/v1/sources") {
      out.body["sources"] = Json::array();
      for (const auto& s : user_sources(username)) {
        out.body["sources"].push_back({{"id", s.at("id")}, {"type", s.at("type")},
          {"provider_id", s.value("provider_id", "")},
          {"name", s.value("name", s.at("id").get<std::string>())}, {"qualities", s.value("qualities", Json::array({"original"}))}});
      }
      return out;
    }
    if (r.method == "POST" && r.path == "/v1/playback/prepare") {
      const auto& source = r.body.at("source");
      const auto connection = field(source, "connection_id", 100);
      Json selected;
      for (const auto& s : user_sources(username)) if (s.at("id") == connection) selected = s;
      if (selected.is_null()) throw Error(400, "unknown_source");
      const std::string type = selected.at("type");
      Json normalized = {{"connection_id", connection}, {"type", type}};
      if (type == "url") normalized["url"] = field(source, "url", 8192);
      else if (type == "storage") normalized["path"] = field(source, "path");
      else if (type == "extension") normalized["track_id"] = field(source, "track_id");
      else throw Error(400, "unsupported_source");
      const std::string quality = r.body.value("quality", "original");
      const auto qualities = selected.value("qualities", Json::array({"original"}));
      if (std::find(qualities.begin(), qualities.end(), quality) == qualities.end()) throw Error(400, "unsupported_quality");
      Json request = {{"source", normalized}, {"quality", quality},
        {"title", r.body.value("title", "")}, {"artist", r.body.value("artist", "")}};
      const auto key = digest(Json{{"source", normalized}, {"quality", quality}}.dump());
      std::lock_guard lock(db_.mutex);
      auto existing = db_.query("SELECT * FROM jobs WHERE user_id=? AND source_key=?", {uid, key});
      if (!existing.empty() && existing[0]["state"] == "ready" &&
          !std::filesystem::is_regular_file(root_ / "media" / existing[0]["file"].get<std::string>())) {
        db_.execute("UPDATE jobs SET state='failed',error='media_missing' WHERE id=?", {existing[0]["id"]});
        existing[0]["state"] = "failed";
      }
      if (existing.empty() || existing[0]["state"] == "failed" || existing[0]["state"] == "cancelled") {
        auto counts = db_.query("SELECT COUNT(*) AS count FROM jobs WHERE user_id=? AND state IN "
                                "('queued','resolving','downloading','processing')", {uid});
        if (counts[0]["count"].get<int>() >= config_.value("max_queued_per_user", 20)) throw Error(429, "queue_limit");
        const auto id = existing.empty() ? random_token() : existing[0]["id"].get<std::string>();
        // A cancelling worker must finish cleanup before the same ID can be reused.
        if (!existing.empty() && std::filesystem::exists(root_ / "staging" / id)) throw Error(409, "cleanup_in_progress");
        db_.execute("INSERT INTO jobs(id,user_id,source_key,request,state,created) VALUES (?,?,?,?,'queued',?) "
                    "ON CONFLICT(user_id,source_key) DO UPDATE SET state='queued',request=excluded.request,"
                    "received=0,total=NULL,error='',attempts=0,created=excluded.created", {id, uid, key, request.dump(), now()});
        existing = db_.query("SELECT * FROM jobs WHERE id=?", {id});
      }
      out.status = existing[0]["state"] == "ready" ? 200 : 202;
      out.body = public_job(existing[0]); return out;
    }
    if (r.method == "GET" && (r.path == "/v1/tracks" || r.path == "/v1/downloads")) {
      int offset = 0;
      if (!r.offset.empty()) {
        if (!std::regex_match(r.offset, std::regex("[0-9]{1,8}"))) throw Error(400, "invalid_offset");
        offset = std::stoi(r.offset);
      }
      auto rows = db_.query("SELECT * FROM jobs WHERE user_id=? " +
          std::string(r.path == "/v1/tracks" ? "AND state='ready' " : "") +
          "ORDER BY created DESC,id LIMIT 100 OFFSET ?", {uid, offset});
      out.body["items"] = Json::array();
      for (const auto& row : rows) out.body["items"].push_back(public_job(row));
      out.body["next_offset"] = rows.size() == 100 ? Json(offset + 100) : Json(nullptr);
      return out;
    }
    const std::regex job_path("/v1/(downloads|tracks|assets)/([a-f0-9]{64})(/cancel|/playback-ticket)?");
    std::smatch match;
    if (std::regex_match(r.path, match, job_path)) {
      std::lock_guard lock(db_.mutex);
      auto rows = db_.query("SELECT * FROM jobs WHERE id=? AND user_id=?", {match[2].str(), uid});
      if (rows.empty()) throw Error(404, "not_found");
      const auto& job = rows[0];
      if (r.method == "GET" && match[3].str().empty() && match[1] != "assets") { out.body = public_job(job); return out; }
      if (r.method == "POST" && match[1] == "downloads" && match[3] == "/cancel") {
        db_.execute("UPDATE jobs SET state='cancelled' WHERE id=? AND state IN "
                    "('queued','resolving','downloading','processing')", {job["id"]});
        out.body = public_job(db_.query("SELECT * FROM jobs WHERE id=?", {job["id"]})[0]); return out;
      }
      if (r.method == "POST" && match[1] == "assets" && match[3] == "/playback-ticket") {
        if (job["state"] != "ready") throw Error(409, "not_ready");
        db_.execute("DELETE FROM tickets WHERE expires<=?", {now()});
        // Limit persistent ticket rows when clients repeatedly request the same asset.
        if (db_.query("SELECT token FROM tickets WHERE session_id=?", {sid}).size() >= 256) throw Error(429, "ticket_limit");
        const auto ticket = random_token();
        db_.execute("INSERT INTO tickets VALUES (?,?,?,?)", {digest(ticket), sid, job["id"], now() + 3600});
        out.body = {{"path", "/v1/media/" + ticket}, {"expires_in", 3600}, {"mime", job["mime"]}}; return out;
      }
    }
    throw Error(404, "not_found");
  } catch (const Error& error) { out.status = error.status; out.body = {{"error", error.what()}}; }
    catch (const Json::exception&) { out.status = 400; out.body = {{"error", "invalid_request"}}; }
    catch (const std::filesystem::filesystem_error&) { out.status = 404; out.body = {{"error", "media_unavailable"}}; }
  out.file.clear();
  return out;
}
}
