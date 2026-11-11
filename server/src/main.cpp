#include "service.hpp"
#include <userver/components/component.hpp>
#include <userver/components/component_context.hpp>
#include <userver/components/minimal_server_component_list.hpp>
#include <userver/components/process_starter.hpp>
#include <userver/engine/async.hpp>
#include <userver/engine/deadline.hpp>
#include <userver/server/handlers/http_handler_base.hpp>
#include <userver/utils/daemon_run.hpp>
#include <cstdlib>
#include <fstream>
#include <signal.h>
#include <fcntl.h>
#include <unistd.h>

namespace music {
namespace uv = USERVER_NAMESPACE;
class ServiceComponent final : public uv::components::LoggableComponentBase {
 public:
  static constexpr std::string_view kName = "music-service";
  ServiceComponent(const uv::components::ComponentConfig& config, const uv::components::ComponentContext& context)
      : LoggableComponentBase(config, context), service(ConfigPath(), true, Runner(context)) {}
  Service service;
 private:
  static ProcessRunner Runner(const uv::components::ComponentContext& context) {
    auto& starter = context.FindComponent<uv::components::ProcessStarter>().Get();
    auto& processor = context.GetTaskProcessor("fs-task-processor");
    return [&starter, &processor](const std::vector<std::string>& args,
                                 const std::function<void()>& checkpoint, int timeout) {
      // userver owns SIGCHLD. Its ProcessStarter must also own child reaping;
      // ordinary waitpid from the native downloader races that handler.
      auto task = uv::engine::AsyncNoTracing(processor, [&] {
        const auto output = std::filesystem::temp_directory_path() / ("music-worker-" + random_token());
        struct Cleanup { std::filesystem::path path; ~Cleanup() { std::error_code ec; std::filesystem::remove(path, ec); } } cleanup{output};
        const int fd = open(output.c_str(), O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0600);
        if (fd < 0) throw std::runtime_error("Cannot create worker output");
        close(fd);
        uv::engine::subprocess::ExecOptions options;
        options.stdout_file = output.string(); options.stderr_file = "/dev/null";
        options.use_path = true;
        std::vector<std::string> command{"--wait"};
        command.insert(command.end(), args.begin(), args.end());
        auto child = starter.Exec("setsid", command, std::move(options));
        const auto end = std::chrono::steady_clock::now() + std::chrono::seconds(timeout);
        try {
          while (!child.WaitFor(std::chrono::milliseconds(100))) {
            checkpoint();
            if (std::chrono::steady_clock::now() > end || std::filesystem::file_size(output) > 1024 * 1024)
              throw std::runtime_error("Worker limit exceeded");
          }
        } catch (...) {
          kill(-child.GetPid(), SIGKILL);
          child.SendSignal(SIGKILL); child.Wait(); throw;
        }
        checkpoint();
        const auto status = child.Get();
        if (!status.IsExited() || status.GetExitCode() != 0 || std::filesystem::file_size(output) > 1024 * 1024)
          throw std::runtime_error("Worker failed");
        std::ifstream file(output);
        return std::string(std::istreambuf_iterator<char>(file), {});
      });
      task.BlockingWait();
      return task.Get();
    };
  }
  static std::string ConfigPath() {
    const char* value = std::getenv("MUSIC_CONFIG");
    if (!value) throw std::runtime_error("MUSIC_CONFIG is required");
    return value;
  }
};
class Api final : public uv::server::handlers::HttpHandlerBase {
 public:
  static constexpr std::string_view kName = "music-api";
  Api(const uv::components::ComponentConfig& config, const uv::components::ComponentContext& context)
      : HttpHandlerBase(config, context), service_(context.FindComponent<ServiceComponent>().service) {}
 private:
  Service& service_;
  // Tokens, credentials, source URLs and signed media paths must not reach logs.
  std::string GetRequestBodyForLogging(const uv::server::http::HttpRequest&, uv::server::request::RequestContext&, const std::string&) const override { return {}; }
  std::string GetResponseDataForLogging(const uv::server::http::HttpRequest&, uv::server::request::RequestContext&, const std::string&) const override { return {}; }
  std::string GetUrlForLogging(const uv::server::http::HttpRequest&, uv::server::request::RequestContext&) const override { return HandlerName(); }
  std::string HandleRequestThrow(const uv::server::http::HttpRequest& req,
                                 uv::server::request::RequestContext&) const override {
    Response result;
    try {
      const auto body = req.RequestBody().empty() ? Json::object() : Json::parse(req.RequestBody());
      result = service_.handle({req.GetMethodStr(), req.GetRequestPath(), req.GetHeader("Authorization"),
                                body, req.GetHeader("Range"), req.GetArg("offset")});
    } catch (const Json::exception&) { result.status = 400; result.body = {{"error", "invalid_json"}}; }
      catch (...) { result.status = 500; result.body = {{"error", "internal_error"}}; }
    auto& response = req.GetHttpResponse();
    response.SetHeader(std::string_view("Cache-Control"), "no-store");
    response.SetHeader(std::string_view("X-Content-Type-Options"), "nosniff");
    if (!result.file.empty()) {
      // Only Nginx can access this internal location. Authorization and ticket
      // expiry are checked above on every GET/HEAD, including range requests.
      response.SetStatus(uv::server::http::HttpStatus::kOk);
      response.SetHeader(std::string_view("X-Accel-Redirect"), "/_protected_media/" +
          result.file.parent_path().filename().string() + "/" + result.file.filename().string());
      return {};
    }
    response.SetStatus(static_cast<uv::server::http::HttpStatus>(result.status));
    for (const auto& [key, value] : result.headers) response.SetHeader(key, value);
    response.SetHeader(std::string_view("Content-Type"), "application/json");
    return result.body.dump();
  }
};
}
int main(int argc, char** argv) {
  auto components = USERVER_NAMESPACE::components::MinimalServerComponentList()
      .Append<USERVER_NAMESPACE::components::ProcessStarter>().Append<music::ServiceComponent>();
  for (const auto* name : {"health", "login", "refresh", "logout", "sources", "prepare", "downloads",
                           "download", "cancel", "tracks", "track", "ticket", "media"})
    components.Append<music::Api>(std::string("music-") + name);
  return USERVER_NAMESPACE::utils::DaemonMain(argc, argv, components);
}
