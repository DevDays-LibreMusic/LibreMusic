#include "process.hpp"
#include <spawn.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>
#include <array>
#include <chrono>
#include <stdexcept>
#include <thread>

extern char** environ;
namespace music {
std::string run_process(const std::vector<std::string>& args,
                        const std::function<void()>& checkpoint, int timeout_seconds) {
  int fds[2];
  if (pipe2(fds, O_CLOEXEC) != 0) throw std::runtime_error("Cannot open worker pipe");
  posix_spawn_file_actions_t actions;
  posix_spawn_file_actions_init(&actions);
  posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO);
  posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
  posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
  posix_spawnattr_t attr;
  posix_spawnattr_init(&attr);
  posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
  posix_spawnattr_setpgroup(&attr, 0);
  std::vector<char*> argv;
  for (const auto& arg : args) argv.push_back(const_cast<char*>(arg.c_str()));
  argv.push_back(nullptr);
  pid_t pid = -1;
  const auto rc = posix_spawnp(&pid, argv[0], &actions, &attr, argv.data(), environ);
  posix_spawn_file_actions_destroy(&actions);
  posix_spawnattr_destroy(&attr);
  close(fds[1]);
  if (rc) { close(fds[0]); throw std::runtime_error("Cannot start worker"); }
  fcntl(fds[0], F_SETFL, O_NONBLOCK);
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(timeout_seconds);
  std::string output;
  std::array<char, 8192> buffer{};
  auto drain = [&] {
    ssize_t count;
    while ((count = read(fds[0], buffer.data(), buffer.size())) > 0) {
      if (output.size() + count > 1024 * 1024) throw std::runtime_error("Worker output exceeds limit");
      output.append(buffer.data(), count);
    }
  };
  int status = 0;
  bool reaped = false;
  try {
    for (;;) {
      checkpoint(); drain();
      const auto waited = waitpid(pid, &status, WNOHANG);
      if (waited == pid) { reaped = true; break; }
      if (waited == -1 && errno != EINTR) {
        reaped = errno == ECHILD;
        throw std::runtime_error("Cannot wait for worker");
      }
      if (std::chrono::steady_clock::now() > deadline) throw std::runtime_error("Worker timeout");
      std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    drain(); close(fds[0]);
  } catch (...) {
    if (!reaped) {
      kill(-pid, SIGKILL);
      while (waitpid(pid, &status, 0) == -1 && errno == EINTR) {}
    }
    close(fds[0]); throw;
  }
  if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) throw std::runtime_error("Worker failed");
  return output;
}
}
