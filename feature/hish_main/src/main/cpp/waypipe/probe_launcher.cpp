#include "probe_socket.hpp"
#include <cerrno>
#include <AbilityKit/native_child_process.h>
#include <hilog/log.h>
#include <poll.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <thread>

namespace hish::waypipe_probe {
namespace {

bool CheckSharedBuffer(int socket, char& kind)
{
    pollfd wait{socket, POLLIN, 0};
    if (poll(&wait, 1, 3000) <= 0 || !(wait.revents & POLLIN)) return false;
    Fd buffer(ReceiveBuffer(socket, kind));
    if (buffer.Get() < 0) return false;
    struct stat info{};
    const bool statOk = fstat(buffer.Get(), &info) == 0;
    if (!statOk) {
        OH_LOG_Print(LOG_APP, LOG_WARN, 0, tag,
            "Waypipe sample %{public}c fstat denied: errno=%{public}d", kind, errno);
    } else if (info.st_size != sizeof(sample)) {
        return false;
    }

    // The child created this sample at a fixed size. Check mmap separately
    // even if the sandbox denied metadata access to the memfd.
    void* data = mmap(nullptr, sizeof(sample), PROT_READ | PROT_WRITE, MAP_SHARED, buffer.Get(), 0);
    if (data == MAP_FAILED) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0, tag,
            "Waypipe sample %{public}c parent mmap failed: errno=%{public}d", kind, errno);
        return false;
    }
    const bool matches = std::memcmp(data, sample, sizeof(sample)) == 0;
    munmap(data, sizeof(sample));
    return matches;
}

int Spawn(const char* entry, const std::string& directory, int32_t& pid)
{
    if (directory.empty() || directory.front() != '/') return -1;
    int sockets[2];
    if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sockets) != 0) return -1;
    Fd parent(sockets[0]);
    Fd child(sockets[1]);
    struct stat identity{};
    if (fstat(child.Get(), &identity) != 0) return -1;

    char name[] = "probe";
    NativeChildProcess_Fd node{};
    node.fdName = name;
    node.fd = child.Get();
    std::string parameters = directory;
    NativeChildProcess_Args args{};
    args.entryParams = parameters.data();
    args.fdList.head = &node;
    NativeChildProcess_Options options{};
    options.isolationMode = NCP_ISOLATION_MODE_NORMAL;
    const auto status = OH_Ability_StartNativeChildProcess(entry, args, options, &pid);

    // Some NCP implementations consume the passed descriptor.
    struct stat current{};
    if (fstat(child.Get(), &current) != 0 || current.st_dev != identity.st_dev ||
        current.st_ino != identity.st_ino) child.Release();
    if (status != 0) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0, tag, "Waypipe child launch failed: %{public}d", static_cast<int>(status));
        return -1;
    }

    return parent.Release();
}

Fd proxy;

}

bool Start(const std::string& directory)
{
    int32_t pid = -1;
    const int fd = Spawn("libhish_waypipe_probe.so:Main", directory, pid);
    if (fd < 0) return false;
    try {
        std::thread([fd, pid] {
            const Fd channel(fd);
            for (unsigned i = 0; i < 2; ++i) {
                char kind = 0;
                const bool passed = CheckSharedBuffer(fd, kind);
                const char* source = kind == 'm' ? "memfd" : (kind == 'f' ? "private file" : "missing sample");
                OH_LOG_Print(LOG_APP, passed ? LOG_WARN : LOG_ERROR, 0, tag,
                    "Waypipe NCP %{public}d %{public}s SCM_RIGHTS and mmap: %{public}s",
                    pid, source, passed ? "PASS" : "FAIL");
                if (kind == 0) break;
            }
        }).detach();
    } catch (...) {
        close(fd);
        return false;
    }
    return true;
}

bool StartProxy(const std::string& directory)
{
    StopProxy();
    int32_t pid = -1;
    const int fd = Spawn("libhish_waypipe_probe.so:Proxy", directory, pid);
    if (fd < 0) return false;
    proxy.Reset(fd);
    return true;
}

void StopProxy()
{
    if (proxy.Get() >= 0) shutdown(proxy.Get(), SHUT_RDWR);
    proxy.Reset();
}

}
