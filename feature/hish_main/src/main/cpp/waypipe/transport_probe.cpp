#include "probe_socket.hpp"
#include <AbilityKit/native_child_process.h>
#include <dlfcn.h>
#include <hilog/log.h>
#include <sys/mman.h>

using namespace hish::waypipe_probe;

namespace {

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
    const auto* channel = args.fdList.head;
    while (channel && (!channel->fdName || std::strcmp(channel->fdName, "probe") != 0)) channel = channel->next;
    if (!channel || channel->fd < 0) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0, tag, "Waypipe child did not inherit the probe socket");
        return;
    }
    const Fd socket(channel->fd);
    void* library = dlopen("libhish_waypipe.so", RTLD_NOW | RTLD_LOCAL);
    if (!library) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0, tag, "Waypipe load failed: %{public}s", dlerror());
        return;
    }

    using Entry = int (*)(int, char**);
    auto entry = reinterpret_cast<Entry>(dlsym(library, "hish_waypipe_main"));
    char command[] = "waypipe";
    char option[] = "--version";
    char* argv[] = {command, option, nullptr};
    const bool ready = entry && entry(2, argv) == 0;
    dlclose(library);
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
