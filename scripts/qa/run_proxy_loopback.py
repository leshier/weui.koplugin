#!/usr/bin/env python3
"""Real SOCKS5, RFC1929, TLS and HTTP using loopback only."""
import json
import os
from pathlib import Path
import socket
import socketserver
import ssl
import subprocess
import tempfile
import threading
from urllib.parse import urlsplit

REPO = Path(__file__).resolve().parents[2]


def receive(sock, count):
    data = b""
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            raise EOFError("short SOCKS5 frame")
        data += chunk
    return data


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        conn = self.request
        conn.settimeout(5)
        auth = False
        try:
            version, length = receive(conn, 2)
            assert version == 5
            methods = receive(conn, length)
            auth = 2 in methods
            conn.sendall(bytes((5, 2 if auth else 0)))
            if auth:
                assert receive(conn, 1) == b"\x01"
                username = receive(conn, receive(conn, 1)[0])
                password = receive(conn, receive(conn, 1)[0])
                valid = username == b"qa-user" and password == b"qa-secret"
                conn.sendall(bytes((1, 0 if valid else 1)))
                if not valid:
                    self.server.record({"auth_failure": True})
                    return
            version, command, reserved, atyp = receive(conn, 4)
            assert (version, command, reserved, atyp) == (5, 1, 0, 3)
            host = receive(conn, receive(conn, 1)[0]).decode()
            port = int.from_bytes(receive(conn, 2), "big")
            self.server.record({"connect": host, "port": port, "atyp": atyp, "auth": auth})
            refused = host == "refused.invalid"
            conn.sendall(bytes((5, 5 if refused else 0, 0, 1, 127, 0, 0, 1, 0, 0)))
            if refused:
                return
            if port == 443:
                conn = self.server.tls.wrap_socket(conn, server_side=True)
            stream = conn.makefile("rb")
            request_line = stream.readline().decode().strip()
            method, path, _ = request_line.split(" ", 2)
            headers = {}
            while True:
                line = stream.readline()
                if line in (b"\r\n", b"\n", b""):
                    break
                key, value = line.decode().split(":", 1)
                headers[key.lower()] = value.strip()
            body = stream.read(int(headers.get("content-length", "0")))
            self.server.record({"host": host, "path": path, "method": method,
                                "body_bytes": len(body), "cookie": "cookie" in headers,
                                "proxy_auth_at_origin": "proxy-authorization" in headers})
            path_only = urlsplit(path).path
            status, extra, content_type = 200, "", "application/json"
            if path_only == "/redirect":
                status, extra, payload = 302, "Location: https://cdn.invalid/book\r\n", b"REDIRECT-BODY"
            elif path_only == "/downgrade":
                status, extra, payload = 302, "Location: http://plain.invalid/downgrade-target\r\n", b"REDIRECT-BODY"
            elif path_only == "/book":
                payload, content_type = b"BOOK-CONTENT", "application/epub+zip"
            elif path_only == "/cover":
                payload, content_type = b"COVER-CONTENT", "image/jpeg"
            else:
                book = {"id": "1", "hash": "hash", "title": "纸页", "author": "测试", "extension": "epub"}
                payload = json.dumps({
                    "success": 1, "user": {"id": "qa", "remix_userkey": "key", "downloads_today": 1, "downloads_limit": 10},
                    "books": [book], "book": book, "file": {"downloadLink": "https://download.invalid/redirect"},
                    "pagination": {"current": 1, "total_pages": 1, "total_items": 1},
                    "domains": [{"domain": "api.invalid"}], "comments": [],
                }).encode()
            conn.sendall(f"HTTP/1.1 {status} OK\r\n{extra}Content-Type: {content_type}\r\nContent-Length: {len(payload)}\r\nConnection: close\r\n\r\n".encode() + payload)
            stream.close()
        except (EOFError, ConnectionError, ssl.SSLError):
            pass
        finally:
            conn.close()


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True

    def record(self, row):
        with self.lock:
            self.rows.append(row)


def main():
    root = Path(tempfile.mkdtemp(prefix="weui-proxy-loopback."))
    for name in ("cache", "data", "settings/weui"):
        (root / name).mkdir(parents=True)
    (root / "settings.reader.lua").write_text('return {language="zh_CN"}\n')
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                    "-keyout", str(root / "key.pem"), "-out", str(root / "cert.pem"),
                    "-days", "1", "-subj", "/CN=api.invalid"], check=True, capture_output=True)
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(root / "cert.pem", root / "key.pem")
    server = Server(("127.0.0.1", 0), Handler)
    server.tls, server.rows, server.lock = tls, [], threading.Lock()
    # Reserve a port with no listener for deterministic connection refusal.
    closed = socket.socket()
    closed.bind(("127.0.0.1", 0))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    env = dict(os.environ, KO_HOME=str(root), WEUI_PROXY_REPO=str(REPO), WEUI_PROXY_ROOT=str(root),
               WEUI_PROXY_PORT=str(server.server_address[1]), WEUI_PROXY_CLOSED_PORT=str(closed.getsockname()[1]))
    runtime = Path(os.environ.get("KOREADER_DIR", "/Applications/KOReader.app/Contents/koreader"))
    print(f"Proxy loopback QA root: {root}", flush=True)
    try:
        run = subprocess.run([str(runtime / "luajit"), str(REPO / "scripts/qa/proxy_loopback_client.lua")],
                             cwd=runtime, env=env, capture_output=True, text=True, timeout=180)
        (root / "native.log").write_text(run.stdout + run.stderr)
        (root / "traffic.jsonl").write_text("".join(json.dumps(row) + "\n" for row in server.rows))
        if run.returncode:
            print((run.stdout + run.stderr)[-6000:])
            return 1
        connections = [row for row in server.rows if "connect" in row]
        origins = [row for row in server.rows if "path" in row]
        assert connections and all(row["atyp"] == 3 for row in connections)
        assert {row["auth"] for row in connections} == {True, False}
        assert {"api.invalid", "cover.invalid", "download.invalid", "cdn.invalid", "plain.invalid"} <= {row["connect"] for row in connections}
        assert all(not row["proxy_auth_at_origin"] for row in origins)
        assert not any(row["path"] == "/downgrade-target" for row in origins)
        assert any(row["path"] == "/eapi/user/login" and row["method"] == "POST" and row["body_bytes"] > 0 for row in origins)
        print((root / "results.tsv").read_text(), end="")
        print(f"PASS: {len(connections)} SOCKS5 CONNECT frames, {len(origins)} origin requests, all target DNS remote.")
        return 0
    finally:
        server.shutdown()
        server.server_close()
        closed.close()


if __name__ == "__main__":
    raise SystemExit(main())
