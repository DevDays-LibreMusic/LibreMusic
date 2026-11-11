#include "service.hpp"
#include <iostream>

int main(int argc, char** argv) {
  try {
    if (argc != 4 || std::string(argv[2]) != "create-user") {
      std::cerr << "Usage: music-admin CONFIG create-user USERNAME < password-file\n";
      return 2;
    }
    std::string password; std::getline(std::cin, password);
    music::Service service(argv[1], false);
    std::cout << service.add_user(argv[3], password) << '\n';
    return 0;
  } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
