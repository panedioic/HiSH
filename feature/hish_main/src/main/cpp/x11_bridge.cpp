#include "include/x11_bridge.hpp"

#include <array>
#include <cerrno>
#include <cstddef>
#include <cstring>
#include <mutex>
#include <netinet/in.h>
#include <poll.h>
#include <sys/eventfd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <thread>
#include <unistd.h>

namespace hish {
namespace {
constexpr unsigned MAX_CLIENTS = 16;
constexpr int SOCKET_FLAGS = SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC;
constexpr int MIN_DISPLAY_PORT = 6001;

class Fd {
public:
    explicit Fd(int fd = -1) : fd_(fd) {}
    ~Fd() { Reset(); }
    Fd(const Fd&) = delete;
    Fd& operator=(const Fd&) = delete;
    int Get() const { return fd_; }
    void Reset(int fd = -1)
    {
        if (fd_ >= 0) close(fd_);
        fd_ = fd;
    }
private:
    int fd_;
};

struct Direction {
    std::array<char, 16384> data;
    size_t begin = 0;
    size_t end = 0;
    bool eof = false;

    bool Empty() const { return begin == end; }

    bool Read(int fd)
    {
        const ssize_t count = recv(fd, data.data(), data.size(), 0);
        if (count < 0) return errno == EAGAIN || errno == EINTR;
        begin = 0;
        end = static_cast<size_t>(count);
        eof = count == 0;
        return true;
    }

    bool Write(int fd)
    {
        const ssize_t count = send(fd, data.data() + begin, end - begin, MSG_NOSIGNAL);
        if (count < 0) return errno == EAGAIN || errno == EINTR;
        begin += static_cast<size_t>(count);
        return true;
    }
};

struct Connection {
    Fd guest;
    Fd server;
    Direction toServer;
    Direction toGuest;
    bool connecting = false;

    void Close()
    {
        guest.Reset();
        server.Reset();
    }

    void Open(int fd, const sockaddr_un& address, socklen_t addressSize)
    {
        guest.Reset(fd);
        server.Reset(socket(AF_UNIX, SOCKET_FLAGS, 0));
        if (server.Get() < 0) {
            Close();
            return;
        }
        const int result = connect(server.Get(), reinterpret_cast<const sockaddr*>(&address), addressSize);
        connecting = result < 0 && errno == EINPROGRESS;
        if (result < 0 && !connecting) {
            Close();
            return;
        }
        toServer.begin = toServer.end = toGuest.begin = toGuest.end = 0;
        toServer.eof = toGuest.eof = false;
    }

    static pollfd Watch(int fd, const Direction& incoming, const Direction& outgoing)
    {
        short events = 0;
        if (!incoming.eof && incoming.Empty()) events |= POLLIN;
        if (!outgoing.Empty()) events |= POLLOUT;
        return {events ? fd : -1, events, 0};
    }

    bool PumpOne(const pollfd& source, short targetEvents, int targetFd, Direction& direction) const
    {
        if (!direction.Empty()) {
            if (targetEvents & POLLHUP) return false;
            if (targetEvents & POLLOUT && !direction.Write(targetFd)) return false;
        }
        if (source.revents & (POLLIN | POLLHUP) && direction.Empty() && !direction.eof) {
            if (!direction.Read(source.fd)) return false;
            if (direction.eof) shutdown(targetFd, SHUT_WR);
        }
        return true;
    }

    void Pump(const pollfd& fromGuest, const pollfd& fromServer)
    {
        if ((fromGuest.revents | fromServer.revents) & (POLLERR | POLLNVAL)) {
            Close();
            return;
        }
        if (connecting) {
            if (!(fromServer.revents & (POLLOUT | POLLHUP))) return;
            int error = 0;
            socklen_t len = sizeof(error);
            if (getsockopt(server.Get(), SOL_SOCKET, SO_ERROR, &error, &len) != 0 || error) {
                Close();
                return;
            }
            connecting = false;
        }
        if (!PumpOne(fromGuest, fromServer.revents, server.Get(), toServer) ||
            !PumpOne(fromServer, fromGuest.revents, guest.Get(), toGuest) ||
            (toServer.eof && toGuest.eof)) Close();
    }
};

class Bridge {
public:
    ~Bridge() { Stop(); }

    uint16_t Start(const std::string& endpoint)
    {
        std::lock_guard<std::mutex> lock(mutex_);
        StopLocked();
        sockaddr_un destination{};
        constexpr char prefix[] = "@/tmp/.X11-unix/X";
        if (endpoint.compare(0, sizeof(prefix) - 1, prefix) != 0 ||
            endpoint.size() >= sizeof(destination.sun_path) ||
            endpoint.size() < sizeof(prefix) ||
            endpoint.find_first_not_of("0123456789", sizeof(prefix) - 1) != std::string::npos) return 0;

        destination.sun_family = AF_UNIX;
        std::memcpy(destination.sun_path + 1, endpoint.data() + 1, endpoint.size() - 1);
        const auto length = static_cast<socklen_t>(offsetof(sockaddr_un, sun_path) + endpoint.size());

        listener_.Reset(socket(AF_INET, SOCKET_FLAGS, 0));
        wake_.Reset(eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK));
        sockaddr_in local{};
        local.sin_family = AF_INET;
        local.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        socklen_t size = sizeof(local);
        if (listener_.Get() < 0 || wake_.Get() < 0 ||
            bind(listener_.Get(), reinterpret_cast<sockaddr*>(&local), size) != 0 ||
            getsockname(listener_.Get(), reinterpret_cast<sockaddr*>(&local), &size) != 0 ||
            ntohs(local.sin_port) < MIN_DISPLAY_PORT || listen(listener_.Get(), MAX_CLIENTS) != 0) {
            StopLocked();
            return 0;
        }
        try {
            worker_ = std::thread([this, destination, length] { Run(destination, length); });
        } catch (...) {
            StopLocked();
            return 0;
        }
        return ntohs(local.sin_port);
    }

    void Stop()
    {
        std::lock_guard<std::mutex> lock(mutex_);
        StopLocked();
    }

private:
    void StopLocked()
    {
        if (worker_.joinable()) {
            const uint64_t one = 1;
            while (write(wake_.Get(), &one, sizeof(one)) < 0 && errno == EINTR) {}
            worker_.join();
        }
        listener_.Reset();
        wake_.Reset();
    }

    void Run(const sockaddr_un& destination, socklen_t length)
    {
        std::array<Connection, MAX_CLIENTS> clients;
        std::array<pollfd, 2 + 2 * MAX_CLIENTS> events{};
        events[0] = {wake_.Get(), POLLIN, 0};
        events[1] = {listener_.Get(), POLLIN, 0};
        for (;;) {
            for (unsigned i = 0; i < MAX_CLIENTS; ++i) {
                auto& client = clients[i];
                events[2 + i * 2] = client.connecting ? pollfd{-1, 0, 0} :
                    Connection::Watch(client.guest.Get(), client.toServer, client.toGuest);
                events[3 + i * 2] = client.connecting ? pollfd{client.server.Get(), POLLOUT, 0} :
                    Connection::Watch(client.server.Get(), client.toGuest, client.toServer);
            }
            const int count = poll(events.data(), events.size(), -1);
            if (count < 0 && errno == EINTR) continue;
            if (count < 0 || events[0].revents || (events[1].revents & (POLLERR | POLLHUP | POLLNVAL))) return;
            for (unsigned i = 0; i < MAX_CLIENTS; ++i) {
                auto& client = clients[i];
                if (client.guest.Get() >= 0) client.Pump(events[2 + i * 2], events[3 + i * 2]);
            }
            if (!(events[1].revents & POLLIN)) continue;
            const int fd = accept4(listener_.Get(), nullptr, nullptr, SOCK_NONBLOCK | SOCK_CLOEXEC);
            if (fd < 0) continue;
            bool accepted = false;
            for (auto& client : clients) {
                if (client.guest.Get() >= 0) continue;
                client.Open(fd, destination, length);
                accepted = true;
                break;
            }
            if (!accepted) close(fd);
        }
    }

    std::mutex mutex_;
    Fd listener_;
    Fd wake_;
    std::thread worker_;
};

Bridge bridge;
}

uint16_t StartX11Bridge(const std::string& endpoint) { return bridge.Start(endpoint); }
void StopX11Bridge() { bridge.Stop(); }
}
