#!/usr/bin/env python3
"""探测 SOCKS5 服务器的 UDP 中继端口。

SOCKS5 的 UDP 不走代理端口：客户端发起 UDP ASSOCIATE 后，服务器会回一个
地址和端口，之后客户端把 UDP 包发到那里。这个端口能不能被外部访问，决定了
UDP 到底通不通。本脚本只做这一件事：把服务器返回的端口打印出来。

用法：
    python3 probe-udp.py --port 1080
    python3 probe-udp.py --port 1080 --user socksabc --pass xxxxxxxx
    python3 probe-udp.py --host 1.2.3.4 --port 1080 --user u --pass p

退出码：
    0  协商成功并拿到 BND 端口
    1  连接失败
    2  服务器拒绝（认证失败或不允许 UDP ASSOCIATE）
"""

import argparse
import socket
import struct
import sys

METHOD_NO_AUTH = 0x00
METHOD_USERPASS = 0x02

REP_TEXT = {
    0x00: "succeeded",
    0x01: "general SOCKS server failure",
    0x02: "connection not allowed by ruleset",
    0x03: "network unreachable",
    0x04: "host unreachable",
    0x05: "connection refused",
    0x06: "TTL expired",
    0x07: "command not supported",
    0x08: "address type not supported",
}


def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise EOFError("对端关闭了连接")
        buf += chunk
    return buf


def negotiate(sock, user, password):
    methods = [METHOD_NO_AUTH]
    if user is not None:
        methods.append(METHOD_USERPASS)

    sock.sendall(bytes([0x05, len(methods)]) + bytes(methods))
    ver, method = recv_exact(sock, 2)
    if ver != 0x05:
        print(f"不是 SOCKS5 服务：版本字节为 {ver:#04x}")
        return 1, False
    print(f"协商：服务器选择认证方式 {method:#04x}"
          + ("（用户名密码）" if method == METHOD_USERPASS else "（免认证）"))

    if method == METHOD_USERPASS:
        if user is None:
            print("服务器要求用户名密码，但没有提供 --user / --pass")
            return 2, False
        u = user.encode()
        p = password.encode()
        sock.sendall(b"\x01" + bytes([len(u)]) + u + bytes([len(p)]) + p)
        _, status = recv_exact(sock, 2)
        if status != 0x00:
            print(f"认证失败（status={status:#04x}），用户名或密码不对")
            return 2, False
        print("认证：通过")
    elif method == 0xFF:
        print("服务器不接受任何可用的认证方式")
        return 2, False

    return 0, True


def do_associate(sock):
    sock.sendall(b"\x05\x03\x00\x01" + b"\x00\x00\x00\x00" + struct.pack("!H", 0))
    ver, rep, _, atyp = recv_exact(sock, 4)

    if atyp == 0x01:
        addr = socket.inet_ntoa(recv_exact(sock, 4))
    elif atyp == 0x04:
        addr = socket.inet_ntop(socket.AF_INET6, recv_exact(sock, 16))
    elif atyp == 0x03:
        n = recv_exact(sock, 1)[0]
        addr = recv_exact(sock, n).decode(errors="replace")
    else:
        print(f"未识别的地址类型 {atyp:#04x}")
        return None, None, rep

    port = struct.unpack("!H", recv_exact(sock, 2))[0]
    return addr, port, rep


def main():
    ap = argparse.ArgumentParser(description="探测 SOCKS5 服务器的 UDP 中继端口")
    ap.add_argument("--host", default="127.0.0.1", help="代理地址，默认 127.0.0.1")
    ap.add_argument("--port", type=int, required=True, help="代理的 TCP 端口")
    ap.add_argument("--user", help="用户名（免认证服务器可省略）")
    ap.add_argument("--pass", dest="password", default="", help="密码")
    ap.add_argument("--timeout", type=float, default=8.0, help="超时秒数，默认 8")
    args = ap.parse_args()

    try:
        sock = socket.create_connection((args.host, args.port), timeout=args.timeout)
    except OSError as exc:
        print(f"连不上 {args.host}:{args.port} —— {exc}")
        return 1

    try:
        code, ok = negotiate(sock, args.user, args.password)
        if not ok:
            return code

        addr, port, rep = do_associate(sock)
        if addr is None:
            print(f"UDP ASSOCIATE 被拒绝：{REP_TEXT.get(rep, hex(rep))}")
            return 2
        if rep != 0x00:
            print(f"UDP ASSOCIATE 失败：{REP_TEXT.get(rep, hex(rep))}")
            return 2

        print()
        print(f"代理端口        : {args.port}")
        print(f"UDP 中继地址    : {addr}:{port}")

        if port == args.port:
            print("结论            : 中继端口与代理端口相同，只要放行这一个端口即可")
        else:
            print("结论            : 中继端口与代理端口不同")
            print(f"                  客户端会被要求把 UDP 包发到 {port}/udp")
            print("                  这个端口是否可达，决定了 UDP 能不能通")
        return 0
    finally:
        sock.close()


if __name__ == "__main__":
    sys.exit(main())
