#include "probe_socket.hpp"
#include <AbilityKit/native_child_process.h>
#include <cerrno>
#include <dlfcn.h>
#include <fcntl.h>
#include <hilog/log.h>
#include <sys/mman.h>
#include <thread>

using namespace hish::waypipe_probe;

namespace {

int Channel(NativeChildProcess_Args args)
{
    for (auto* node = args.fdList.head; node; node = node->next) {
        if (node->fdName && std::strcmp(node->fdName, "probe") == 0) return node->fd;
    }
    return -1;
}

int RunWaypipe(int argc, char** argv)
{
    void* library = dlopen("libhish_waypipe.so", RTLD_NOW | RTLD_LOCAL);
    if (!library) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0, tag, "Waypipe load failed: %{public}s", dlerror());
        return 1;
    }
    using Entry = int (*)(int, char**);
    auto entry = reinterpret_cast<Entry>(dlsym(library, "hish_waypipe_main"));
    const int result = entry ? entry(argc, argv) : 1;
    dlclose(library);
    return result;
}

bool PublishSample(int channel, int fd, char kind)
{
    if (fd < 0 || ftruncate(fd, sizeof(sample)) != 0) return false;
    void* buffer = mmap(nullptr, sizeof(sample), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (buffer == MAP_FAILED) return false;
    std::memcpy(buffer, sample, sizeof(sample));
    munmap(buffer, sizeof(sample));
    return SendBuffer(channel, fd, kind);
}

}

extern "C" __attribute__((visibility("default"))) void Main(NativeChildProcess_Args args)
{
    const Fd socket(Channel(args));
    if (socket.Get() < 0) return;
    char command[] = "waypipe";
    char option[] = "--version";
    char* argv[] = {command, option, nullptr};
    const bool ready = RunWaypipe(2, argv) == 0;
    if (!ready) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0, tag, "Waypipe entry failed");
        return;
    }

    const Fd memory(memfd_create("hish-waypipe-probe", MFD_CLOEXEC));
    if (!PublishSample(socket.Get(), memory.Get(), 'm')) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0, tag, "Waypipe child memfd sample failed");
    }

    if (!args.entryParams || args.entryParams[0] != '/') return;
    std::string path = std::string(args.entryParams) + "/hish-waypipe-XXXXXX";
    const Fd temporary(mkstemp(path.data()));
    if (temporary.Get() < 0 || unlink(path.c_str()) != 0 ||
        !PublishSample(socket.Get(), temporary.Get(), 'f')) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0, tag, "Waypipe child private file sample failed");
    }
}

extern "C" __attribute__((visibility("default"))) void Proxy(NativeChildProcess_Args args)
{
    const int control = Channel(args);
    if (control < 0 || !args.entryParams || args.entryParams[0] != '/') return;
    const std::string dir = args.entryParams;
    std::thread([control] {
        char byte;
        while (read(control, &byte, 1) < 0 && errno == EINTR) {}
        _exit(0);
    }).detach();

    setenv("XDG_RUNTIME_DIR", dir.c_str(), 1);
    setenv("WAYLAND_DISPLAY", "w", 1);
    unsetenv("WAYLAND_SOCKET");
    std::string path = dir + "/p";
    char command[] = "waypipe";
    char gpu[] = "--no-gpu";
    char one[] = "--oneshot";
    char compression[] = "--compress=none";
    char socket[] = "--socket";
    char client[] = "client";
    char* argv[] = {command, gpu, one, compression, socket, path.data(), client, nullptr};

    int diagnostics[2];
    std::thread logger;
    if (pipe2(diagnostics, O_CLOEXEC) == 0) {
        if (dup2(diagnostics[1], STDERR_FILENO) >= 0) {
            logger = std::thread([fd = diagnostics[0]] {
                const Fd reader(fd);
                char data[1024];
                ssize_t count;
                while ((count = read(fd, data, sizeof(data) - 1)) > 0) {
                    data[count] = 0;
                    OH_LOG_Print(LOG_APP, LOG_WARN, 0, tag, "%{public}s", data);
                }
            });
        } else {
            close(diagnostics[0]);
        }
        close(diagnostics[1]);
    }
    const int result = RunWaypipe(sizeof(argv) / sizeof(argv[0]) - 1, argv);
    if (logger.joinable()) {
        close(STDERR_FILENO);
        logger.join();
    }
    OH_LOG_Print(LOG_APP, result ? LOG_ERROR : LOG_WARN, 0, tag, "Waypipe client exit=%{public}d", result);
    _exit(result);
}
