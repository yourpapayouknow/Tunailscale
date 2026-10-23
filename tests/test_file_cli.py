"""用官方 CLI 和独立 Unix HTTP 端点验证收发，不连接或改变已有服务。"""
import http.server
import json
import pathlib
import socketserver
import subprocess
import sys
import tempfile
import threading
import urllib.parse


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


class Handler(http.server.BaseHTTPRequestHandler):
    # 返回有明确长度的原生 LocalAPI 响应
    def reply(self, code, body=b"", truncated=False):
        self.send_response(code)
        self.send_header("Content-Length", str(len(body) + (20 if truncated else 0)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    # 不输出测试文件正文或临时授权信息
    def log_message(self, *_):
        pass

    # 模拟原生收件箱及发送所需的真实状态结构
    def do_GET(self):
        path = urllib.parse.unquote(urllib.parse.urlsplit(self.path).path)
        if path == "/localapi/v0/files/":
            self.reply(200, json.dumps([{"Name": name, "Size": len(data)} for name, data in self.server.inbox.items()]).encode())
        elif path.startswith("/localapi/v0/files/"):
            name = path.removeprefix("/localapi/v0/files/")
            self.reply(200, self.server.inbox[name], name == self.server.truncated)
        elif path == "/localapi/v0/status":
            self.reply(200, json.dumps({
                "BackendState": "Running", "Self": {"ID": "self"},
                "Peer": {"nodekey:" + "01" * 32: {
                    "ID": "peer-one", "TailscaleIPs": ["100.64.0.2", "fd7a:115c:a1e0::2"],
                    "Online": True, "TaildropTarget": self.server.target,
                }},
            }).encode())
        elif path == "/localapi/v0/watch-ipn-bus":
            self.reply(200, b"{}\n")
        else:
            self.reply(404, path.encode())

    # 只有 CLI 确认写入完成后才允许从原生收件箱删除
    def do_DELETE(self):
        name = urllib.parse.unquote(urllib.parse.urlsplit(self.path).path).removeprefix("/localapi/v0/files/")
        self.server.deleted.append(name)
        del self.server.inbox[name]
        self.reply(204)

    # 记录原生文件发送 API 的目标、原始名称和正文
    def do_PUT(self):
        self.server.sent.append((urllib.parse.unquote(self.path), self.rfile.read(int(self.headers["Content-Length"]))))
        self.reply(200)


# 所有文件和 socket 都限制在本次独立临时目录
def main(cli):
    with tempfile.TemporaryDirectory(prefix="tscli-", dir="/tmp") as temporary:
        root = pathlib.Path(temporary)
        server = Server(str(root / "api.sock"), Handler)
        server.inbox = {"中文.txt": b"complete", "empty": b""}
        server.truncated = None
        server.target = 1
        server.deleted = []
        server.sent = []
        threading.Thread(target=server.serve_forever, daemon=True).start()

        # 固定 socket，超时即失败，绝不回退到系统 Tailscale
        def run(*args):
            return subprocess.run([cli, f"--socket={root / 'api.sock'}", "file", *args], capture_output=True, timeout=10)

        try:
            destination = root / "received"
            destination.mkdir()
            (destination / "中文.txt").write_bytes(b"original")
            result = run("get", "--conflict=rename", str(destination))
            assert result.returncode == 0, result.stderr.decode()
            assert (destination / "中文.txt").read_bytes() == b"original"
            assert (destination / "中文 (1).txt").read_bytes() == b"complete"
            assert (destination / "empty").read_bytes() == b""
            assert not server.inbox and set(server.deleted) == {"中文.txt", "empty"}

            # 空收件箱也返回成功，但没有新的文件或删除操作。
            previous = set(destination.iterdir())
            result = run("get", "--conflict=rename", str(destination))
            assert result.returncode == 0, result.stderr.decode()
            assert set(destination.iterdir()) == previous and len(server.deleted) == 2

            server.inbox = {"broken": b"partial", "good": b"good"}
            server.truncated = "broken"
            result = run("get", "--conflict=rename", str(destination))
            assert result.returncode != 0
            assert server.inbox == {"broken": b"partial"}, "Failed copy was deleted from inbox"
            assert (destination / "broken").read_bytes() == b"partial"
            assert (destination / "good").read_bytes() == b"good"

            for ip in ["100.64.0.2:", "[fd7a:115c:a1e0::2]:"]:
                result = run("cp", str(destination / "中文.txt"), ip)
                assert result.returncode == 0, result.stderr.decode()
                assert server.sent[-1] == ("/localapi/v0/file-put/peer-one/中文.txt", b"original")
            server.target = 9
            result = run("cp", str(destination / "empty"), "100.64.0.2:")
            assert result.returncode != 0 and len(server.sent) == 2, "Sent to a different user's node"
            print("PASS: real official CLI send/receive, pinned socket, IPv4/IPv6, Unicode, zero-byte, rename, truncated body, inbox retention and native target rejection")
        finally:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    main(sys.argv[1])
