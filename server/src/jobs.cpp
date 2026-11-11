#include "service.hpp"
#include "process.hpp"
#include <curl/curl.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <algorithm>
#include <array>
#include <fstream>
#include <memory>

namespace music {
namespace {
constexpr const char* kAudioFormats = "aac,aiff,ape,asf,caf,dsf,flac,iff,mov,mp3,ogg,tta,wav,wv";
// Resolve once, reject non-public IPv4 addresses, then pin curl to that address.
// IPv6-only sources are not supported by this initial downloader.
std::string public_address(const std::string& host) {
  addrinfo hints{}, *raw = nullptr;
  hints.ai_family = AF_INET; hints.ai_socktype = SOCK_STREAM;
  if (getaddrinfo(host.c_str(), nullptr, &hints, &raw)) throw std::runtime_error("Source DNS failed");
  std::unique_ptr<addrinfo, decltype(&freeaddrinfo)> addresses(raw, freeaddrinfo);
  for (auto* a = raw; a; a = a->ai_next) {
    const auto ip = reinterpret_cast<sockaddr_in*>(a->ai_addr)->sin_addr;
    const uint32_t n = ntohl(ip.s_addr);
    const auto first = n >> 24;
    if (first == 0 || first == 10 || first == 127 || first >= 224 ||
        (n & 0xfff00000U) == 0xac100000U || (n >> 16) == 0xc0a8 || (n >> 16) == 0xa9fe ||
        (n & 0xffc00000U) == 0x64400000U || (n & 0xffffff00U) == 0xc0000000U ||
        (n & 0xffffff00U) == 0xc0000200U || (n & 0xfffe0000U) == 0xc6120000U ||
        (n & 0xffffff00U) == 0xc6336400U || (n & 0xffffff00U) == 0xcb007100U) continue;
    std::array<char, INET_ADDRSTRLEN> result{};
    inet_ntop(AF_INET, &ip, result.data(), result.size());
    return result.data();
  }
  throw std::runtime_error("Source address is not public");
}
void fetch(const std::string& url, const Json& hosts, const std::filesystem::path& output,
           uint64_t limit, const std::function<void()>& checkpoint,
           const std::function<void(uint64_t, uint64_t)>& progress) {
  std::unique_ptr<CURLU, decltype(&curl_url_cleanup)> parsed(curl_url(), curl_url_cleanup);
  if (curl_url_set(parsed.get(), CURLUPART_URL, url.c_str(), 0) != CURLUE_OK) throw std::runtime_error("Invalid source URL");
  auto part = [&](CURLUPart key) {
    char* value = nullptr;
    const auto rc = curl_url_get(parsed.get(), key, &value, 0);
    const std::string result = rc == CURLUE_OK ? value : "";
    curl_free(value); return result;
  };
  const auto host = part(CURLUPART_HOST);
  if (part(CURLUPART_SCHEME) != "https" || !part(CURLUPART_USER).empty() ||
      !part(CURLUPART_PASSWORD).empty() || (!part(CURLUPART_PORT).empty() && part(CURLUPART_PORT) != "443") ||
      std::find(hosts.begin(), hosts.end(), host) == hosts.end()) throw std::runtime_error("Source URL is not allowed");
  const auto resolve = host + ":443:" + public_address(host);
  std::unique_ptr<curl_slist, decltype(&curl_slist_free_all)> pinned(curl_slist_append(nullptr, resolve.c_str()), curl_slist_free_all);
  std::unique_ptr<CURL, decltype(&curl_easy_cleanup)> curl(curl_easy_init(), curl_easy_cleanup);
  if (!curl) throw std::runtime_error("Cannot create HTTP client");
  std::ofstream file(output, std::ios::binary | std::ios::trunc);
  if (!file) throw std::runtime_error("Cannot open staging file");
  struct Sink { std::ofstream& file; uint64_t received, limit; } sink{file, 0, limit};
  struct Progress {
    const std::function<void()>& check;
    const std::function<void(uint64_t, uint64_t)>& update;
    uint64_t limit;
    std::chrono::steady_clock::time_point last{};
  } status{checkpoint, progress, limit};
  curl_easy_setopt(curl.get(), CURLOPT_URL, url.c_str());
  curl_easy_setopt(curl.get(), CURLOPT_PROXY, "");
  curl_easy_setopt(curl.get(), CURLOPT_RESOLVE, pinned.get());
  curl_easy_setopt(curl.get(), CURLOPT_PROTOCOLS, CURLPROTO_HTTPS);
  curl_easy_setopt(curl.get(), CURLOPT_FOLLOWLOCATION, 0L);
  curl_easy_setopt(curl.get(), CURLOPT_CONNECTTIMEOUT, 20L);
  curl_easy_setopt(curl.get(), CURLOPT_TIMEOUT, 900L);
  curl_easy_setopt(curl.get(), CURLOPT_LOW_SPEED_LIMIT, 1024L);
  curl_easy_setopt(curl.get(), CURLOPT_LOW_SPEED_TIME, 60L);
  curl_easy_setopt(curl.get(), CURLOPT_NOSIGNAL, 1L);
  curl_easy_setopt(curl.get(), CURLOPT_FAILONERROR, 1L);
  curl_easy_setopt(curl.get(), CURLOPT_MAXFILESIZE_LARGE, static_cast<curl_off_t>(limit));
  curl_easy_setopt(curl.get(), CURLOPT_WRITEFUNCTION, +[](char* data, size_t size, size_t count, void* ptr) -> size_t {
    auto& s = *static_cast<Sink*>(ptr);
    const auto bytes = size * count;
    if (bytes > s.limit - s.received) return 0;
    s.file.write(data, bytes); s.received += bytes;
    return s.file ? bytes : 0;
  });
  curl_easy_setopt(curl.get(), CURLOPT_WRITEDATA, &sink);
  curl_easy_setopt(curl.get(), CURLOPT_NOPROGRESS, 0L);
  curl_easy_setopt(curl.get(), CURLOPT_XFERINFOFUNCTION,
    +[](void* ptr, curl_off_t total, curl_off_t received, curl_off_t, curl_off_t) -> int {
      auto& p = *static_cast<Progress*>(ptr);
      try {
        p.check();
        if (total > static_cast<curl_off_t>(p.limit)) return 1;
        const auto time = std::chrono::steady_clock::now();
        if (time - p.last > std::chrono::milliseconds(500)) {
          p.update(received, total); p.last = time;
        }
        return 0;
      } catch (...) { return 1; }
    });
  curl_easy_setopt(curl.get(), CURLOPT_XFERINFODATA, &status);
  const auto rc = curl_easy_perform(curl.get());
  long code = 0; curl_easy_getinfo(curl.get(), CURLINFO_RESPONSE_CODE, &code);
  checkpoint();
  file.flush();
  if (rc != CURLE_OK || code != 200 || !file || !sink.received) throw std::runtime_error("Audio download failed");
  progress(sink.received, sink.received);
}
}
void Service::work(std::stop_token stop) {
  std::string previous_user;
  while (!stop.stop_requested()) {
    try {
      Json job;
      {
        std::lock_guard lock(db_.mutex);
        auto rows = db_.query("SELECT j.*,u.name FROM jobs j JOIN users u ON u.id=j.user_id "
          "WHERE state='queued' ORDER BY (user_id=?) ASC,created,id LIMIT 1", {previous_user});
        if (!rows.empty()) {
          job = rows[0]; previous_user = job["user_id"];
          const auto directory = root_ / "staging" / job["id"].get<std::string>();
          std::filesystem::remove_all(directory);
          std::filesystem::create_directories(directory);
          db_.execute("UPDATE jobs SET state='resolving',attempts=attempts+1 WHERE id=?", {job["id"]});
        }
      }
      if (!job.is_null()) {
        try { perform(job, stop); }
        catch (...) {
          db_.execute("UPDATE jobs SET state=?,error=? WHERE id=? AND state!='cancelled' AND state!='ready'",
                      {stop.stop_requested() ? "queued" : "failed", stop.stop_requested() ? "interrupted" : "source_failed", job["id"]});
        }
        std::filesystem::remove_all(root_ / "staging" / job["id"].get<std::string>());
      }
    } catch (...) { /* A temporary storage failure must not terminate the process. */ }
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
  }
}
void Service::perform(const Json& job, std::stop_token stop) {
  const std::string id = job["id"], uid = job["user_id"];
  const auto staging = root_ / "staging" / id;
  const auto request = Json::parse(job["request"].get<std::string>());
  const auto source = request.at("source");
  Json connection;
  for (const auto& s : user_sources(job["name"])) if (s.at("id") == source.at("connection_id")) connection = s;
  if (connection.is_null()) throw std::runtime_error("Source was removed");
  const uint64_t max_bytes = config_.value("max_file_bytes", uint64_t{512 * 1024 * 1024});
  const uint64_t quota = config_.value("quota_bytes_per_user", uint64_t{20ULL * 1024 * 1024 * 1024});
  const auto used = db_.query("SELECT COALESCE(SUM(received),0) AS bytes FROM jobs WHERE user_id=? AND state='ready'", {uid})[0]["bytes"].get<uint64_t>();
  if (used >= quota) throw std::runtime_error("Quota exceeded");
  const auto limit = std::min(max_bytes, quota - used);
  auto check = [&] {
    if (stop.stop_requested()) throw std::runtime_error("Stopping");
    const auto row = db_.query("SELECT state FROM jobs WHERE id=?", {id});
    if (row.empty() || row[0]["state"] == "cancelled") throw std::runtime_error("Cancelled");
  };
  auto progress = [&](uint64_t bytes, uint64_t total) {
    db_.execute("UPDATE jobs SET received=?,total=? WHERE id=?", {bytes, total ? Json(total) : Json(nullptr), id});
  };
  check();
  db_.execute("UPDATE jobs SET state='downloading' WHERE id=? AND state!='cancelled'", {id});
  auto input = staging / "input.audio";
  if (source.at("type") == "url") {
    fetch(source.at("url"), connection.at("allowed_hosts"), input, limit, check, progress);
  } else if (source.at("type") == "storage") {
    const auto path = confined_file(connection.at("root").get<std::string>(), source.at("path"));
    const auto size = std::filesystem::file_size(path);
    if (!size || size > limit) throw std::runtime_error("File exceeds quota");
    std::ifstream from(path, std::ios::binary);
    std::ofstream to(input, std::ios::binary);
    std::array<char, 65536> buffer{};
    uint64_t received = 0;
    while (from) {
      check(); from.read(buffer.data(), buffer.size());
      received += from.gcount();
      if (received > limit) throw std::runtime_error("File exceeds quota");
      to.write(buffer.data(), from.gcount());
      if (!to) throw std::runtime_error("Storage full");
    }
    if (!from.eof() || received != size) throw std::runtime_error("Incomplete source file");
    to.flush(); if (!to) throw std::runtime_error("Storage full");
    progress(received, size);
  } else {
    Json spec = {{"user_root", (root_ / "users" / uid).string()}, {"output_dir", staging.string()},
      {"package", connection.at("package")}, {"provider_id", connection.at("provider_id")},
      {"settings_file", connection.value("settings_file", "")}, {"track_id", source.at("track_id")},
      {"quality", request.at("quality")}, {"title", request.value("title", "")},
      {"artist", request.value("artist", "")}, {"item_id", id}};
    const auto spec_file = staging / "request.json";
    { std::ofstream stream(spec_file); stream << spec; }
    auto last_progress = std::chrono::steady_clock::now();
    auto bounded_check = [&] {
      check(); uint64_t bytes = 0;
      for (const auto& entry : std::filesystem::recursive_directory_iterator(staging))
        if (entry.is_regular_file()) bytes += entry.file_size();
      if (bytes > limit * 2) throw std::runtime_error("Worker exceeds staging quota");
      const auto time = std::chrono::steady_clock::now();
      if (time - last_progress > std::chrono::milliseconds(500)) {
        progress(bytes, 0); last_progress = time;
      }
    };
    const auto result = Json::parse(run_({config_.value("extension_worker", "music-extension-worker"), spec_file.string()}, bounded_check, 900));
    input = confined_file(staging, result.at("file"));
  }
  check();
  db_.execute("UPDATE jobs SET state='processing' WHERE id=? AND state!='cancelled'", {id});
  // Decode the audio into a streaming-friendly FLAC file on the SERVER. This
  // also handles extension output containers consistently across player engines.
  // MP3/AAC/FLAC pass through unchanged when their container is already suitable.
  const auto probe = Json::parse(run_({"ffprobe", "-v", "error", "-protocol_whitelist", "file,pipe",
    "-format_whitelist", kAudioFormats, "-show_entries",
    "stream=codec_type,codec_name:format=format_name,duration", "-of", "json", input.string()}, check, 30));
  std::string codec;
  for (const auto& stream : probe.at("streams"))
    if (stream.value("codec_type", "") == "audio") { codec = stream.value("codec_name", ""); break; }
  if (codec.empty()) throw std::runtime_error("Source has no audio");
  const std::string container = probe.at("format").at("format_name");
  std::string extension, mime;
  if (codec == "mp3" && container == "mp3") { extension = ".mp3"; mime = "audio/mpeg"; }
  else if (codec == "flac" && container == "flac") { extension = ".flac"; mime = "audio/flac"; }
  else if (codec == "aac" && container == "aac") { extension = ".aac"; mime = "audio/aac"; }
  else {
    const auto converted = staging / "converted.flac";
    auto conversion_check = [&] {
      check();
      if (std::filesystem::exists(converted) && std::filesystem::file_size(converted) > limit)
        throw std::runtime_error("Converted file exceeds quota");
    };
    run_({"ffmpeg", "-nostdin", "-v", "error", "-xerror", "-protocol_whitelist", "file,pipe",
      "-format_whitelist", kAudioFormats,
      "-i", input.string(), "-map", "0:a:0", "-vn", "-c:a", "flac", "-y", converted.string()}, conversion_check, 900);
    input = converted; extension = ".flac"; mime = "audio/flac";
  }
  const auto size = std::filesystem::file_size(input);
  if (!size || size > limit) throw std::runtime_error("File exceeds quota");
  check();
  const auto destination = uid + "/" + id + extension;
  std::filesystem::create_directories(root_ / "media" / uid);
  std::lock_guard lock(db_.mutex);
  check();
  // Rename on the same volume publishes a complete file. A restart retries
  // interrupted rows and replaces this deterministic destination safely.
  std::filesystem::rename(input, root_ / "media" / destination);
  db_.execute("UPDATE jobs SET state='ready',file=?,mime=?,received=?,total=?,error='' WHERE id=?",
              {destination, mime, size, size, id});
}
}
