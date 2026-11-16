#pragma once

#include <cstring>
#include <string>
#include <unistd.h>
#include <sys/socket.h>

namespace hish::waypipe_probe {

inline constexpr char tag[] = "HiSH-Waypipe";
inline constexpr char sample[] = "waypipe-shm";

class Fd {
public:
    explicit Fd(int fd = -1) : fd_(fd) {}
    ~Fd() { Reset(); }
    Fd(const Fd&) = delete;
    Fd& operator=(const Fd&) = delete;
    int Get() const { return fd_; }
    void Reset(int fd = -1) { if (fd_ >= 0) close(fd_); fd_ = fd; }
    int Release() { const int fd = fd_; fd_ = -1; return fd; }
private:
    int fd_;
};

inline bool SendBuffer(int socket, int buffer, char marker)
{
    iovec iov{&marker, 1};
    alignas(cmsghdr) char ancillary[CMSG_SPACE(sizeof(int))]{};
    msghdr message{};
    message.msg_iov = &iov;
    message.msg_iovlen = 1;
    message.msg_control = ancillary;
    message.msg_controllen = sizeof(ancillary);
    auto* header = CMSG_FIRSTHDR(&message);
    header->cmsg_level = SOL_SOCKET;
    header->cmsg_type = SCM_RIGHTS;
    header->cmsg_len = CMSG_LEN(sizeof(buffer));
    std::memcpy(CMSG_DATA(header), &buffer, sizeof(buffer));
    return sendmsg(socket, &message, MSG_NOSIGNAL) == 1;
}

inline int ReceiveBuffer(int socket, char& marker)
{
    iovec iov{&marker, 1};
    alignas(cmsghdr) char ancillary[CMSG_SPACE(sizeof(int))]{};
    msghdr message{};
    message.msg_iov = &iov;
    message.msg_iovlen = 1;
    message.msg_control = ancillary;
    message.msg_controllen = sizeof(ancillary);
    if (recvmsg(socket, &message, MSG_CMSG_CLOEXEC) != 1) return -1;
    const auto* header = CMSG_FIRSTHDR(&message);
    if (!header || header->cmsg_level != SOL_SOCKET || header->cmsg_type != SCM_RIGHTS ||
        header->cmsg_len != CMSG_LEN(sizeof(int))) return -1;
    int buffer;
    std::memcpy(&buffer, CMSG_DATA(header), sizeof(buffer));
    return buffer;
}

bool Start(const std::string& directory);
bool StartProxy(const std::string& directory);
void StopProxy();

}
