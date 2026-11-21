# Added by Creality Helper Script (K1C fork).
# The K1C kernel has no IPv6 support. Without this, tornado tries IPv6
# addresses of hosts like raw.githubusercontent.com and logs
# "OSError: [Errno 124] Address family not supported by protocol".
# When IPv6 sockets can't be created, resolve names to IPv4 only.
import socket


def _ipv6_supported():
    try:
        socket.socket(socket.AF_INET6, socket.SOCK_STREAM).close()
        return True
    except OSError:
        return False


if not _ipv6_supported() and not getattr(socket.getaddrinfo, "_ipv4_only", False):
    _getaddrinfo = socket.getaddrinfo

    def _getaddrinfo_ipv4(host, port, family=0, type=0, proto=0, flags=0):
        if family == socket.AF_UNSPEC:
            family = socket.AF_INET
        return _getaddrinfo(host, port, family, type, proto, flags)

    _getaddrinfo_ipv4._ipv4_only = True
    socket.getaddrinfo = _getaddrinfo_ipv4
