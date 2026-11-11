#include "database.hpp"
#include <memory>
#include <stdexcept>

namespace music {
Database::Database(const std::string& path) {
  if (sqlite3_open_v2(path.c_str(), &db_, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE |
      SQLITE_OPEN_FULLMUTEX, nullptr) != SQLITE_OK) {
    if (db_) sqlite3_close(db_);
    throw std::runtime_error("Cannot open database");
  }
  sqlite3_busy_timeout(db_, 5000);
  execute("PRAGMA foreign_keys=ON");
  execute("PRAGMA journal_mode=WAL");
  execute("PRAGMA synchronous=FULL");
  auto version = query("PRAGMA user_version")[0]["user_version"].get<int>();
  if (version > 1) throw std::runtime_error("Database is newer than this server");
  execute("BEGIN IMMEDIATE");
  try {
    execute("CREATE TABLE IF NOT EXISTS users (id TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE, "
            "salt TEXT NOT NULL, password TEXT NOT NULL)");
    execute("CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), "
            "access TEXT NOT NULL UNIQUE, refresh TEXT NOT NULL UNIQUE, access_until INTEGER NOT NULL, "
            "refresh_until INTEGER NOT NULL)");
    execute("CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), "
            "source_key TEXT NOT NULL, request TEXT NOT NULL, state TEXT NOT NULL, received INTEGER NOT NULL DEFAULT 0, "
            "total INTEGER, error TEXT NOT NULL DEFAULT '', file TEXT NOT NULL DEFAULT '', mime TEXT NOT NULL DEFAULT '', "
            "created INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, UNIQUE(user_id,source_key))");
    execute("CREATE INDEX IF NOT EXISTS jobs_queue ON jobs(state,created)");
    execute("CREATE TABLE IF NOT EXISTS tickets (token TEXT PRIMARY KEY, session_id TEXT NOT NULL "
            "REFERENCES sessions(id) ON DELETE CASCADE, job_id TEXT NOT NULL REFERENCES jobs(id), expires INTEGER NOT NULL)");
    execute("PRAGMA user_version=1");
    execute("COMMIT");
  } catch (...) { execute("ROLLBACK"); throw; }
}
Database::~Database() { sqlite3_close(db_); }
Json Database::query(const std::string& sql, const std::vector<Json>& args) {
  std::lock_guard lock(mutex);
  sqlite3_stmt* raw = nullptr;
  if (sqlite3_prepare_v2(db_, sql.c_str(), -1, &raw, nullptr) != SQLITE_OK)
    throw std::runtime_error("Database statement failed");
  std::unique_ptr<sqlite3_stmt, decltype(&sqlite3_finalize)> stmt(raw, sqlite3_finalize);
  for (size_t i = 0; i < args.size(); ++i) {
    const auto& a = args[i];
    int rc;
    if (a.is_null()) rc = sqlite3_bind_null(raw, i + 1);
    else if (a.is_number_integer()) rc = sqlite3_bind_int64(raw, i + 1, a.get<int64_t>());
    else {
      const auto text = a.get<std::string>();
      rc = sqlite3_bind_text(raw, i + 1, text.c_str(), text.size(), SQLITE_TRANSIENT);
    }
    if (rc != SQLITE_OK) throw std::runtime_error("Database binding failed");
  }
  Json rows = Json::array();
  int rc;
  while ((rc = sqlite3_step(raw)) == SQLITE_ROW) {
    Json row = Json::object();
    for (int i = 0; i < sqlite3_column_count(raw); ++i) {
      const auto* name = sqlite3_column_name(raw, i);
      switch (sqlite3_column_type(raw, i)) {
        case SQLITE_NULL: row[name] = nullptr; break;
        case SQLITE_INTEGER: row[name] = sqlite3_column_int64(raw, i); break;
        default: row[name] = reinterpret_cast<const char*>(sqlite3_column_text(raw, i));
      }
    }
    rows.push_back(std::move(row));
  }
  if (rc != SQLITE_DONE) throw std::runtime_error("Database operation failed");
  return rows;
}
void Database::execute(const std::string& sql, const std::vector<Json>& args) { query(sql, args); }
}
