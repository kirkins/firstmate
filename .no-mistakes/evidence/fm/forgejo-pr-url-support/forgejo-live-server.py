#!/usr/bin/env python3
"""Disposable local Forgejo-REST stand-in for live firstmate validation.

Serves the real API surface bin/fm-pr-check.sh / fm-pr-poll.sh /
fm-pr-merge.sh consume, over real HTTPS on 127.0.0.1:443 (host
"localhost"), with PR and status state read from FM_LIVE_INST on every
request so scenarios can flip live state between phases. Every request is
appended to FM_LIVE_REQLOG with its Authorization header shape and body.
Requires a bearer token matching FM_LIVE_TOKEN; anything else is 401.
"""
import http.server
import json
import os
import re
import ssl
import time
import threading

WORK = os.environ["FM_LIVE_WORK"]
INST = os.path.join(WORK, "instance")
REQLOG = os.path.join(INST, "request.log")
with open(os.path.join(INST, "token"), "r", encoding="utf-8") as f:
    TOKEN = f.read().strip()

PULL_RE = re.compile(r"^/api/v1/repos/owner/repo/pulls/([1-9][0-9]*)$")
STATUS_RE = re.compile(r"^/api/v1/repos/owner/repo/commits/([0-9a-f]{40})/status$")
MERGE_RE = re.compile(r"^/api/v1/repos/owner/repo/pulls/([1-9][0-9]*)/merge$")


def logline(rec):
    with open(REQLOG, "a", encoding="utf-8") as f:
        f.write(json.dumps(rec) + "\n")


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def authed(self):
        got = self.headers.get("Authorization", "")
        if got == "token " + TOKEN:
            return "bearer-ok"
        return None

    def send_json(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        # Hold the connection open briefly so an argv sampler can observe the
        # live curl process while it runs.
        time.sleep(0.4)
        auth = self.authed()
        m = PULL_RE.match(self.path)
        if m:
            logline({"method": "GET", "path": self.path, "auth": auth or "MISSING"})
            if auth is None:
                return self.send_json(401, {"message": "unauthorized"})
            try:
                with open(f"{INST}/prs/{m.group(1)}.json", encoding="utf-8") as f:
                    return self.send_json(200, json.load(f))
            except FileNotFoundError:
                return self.send_json(404, {"message": "not found"})
        m = STATUS_RE.match(self.path)
        if m:
            logline({"method": "GET", "path": self.path, "auth": auth or "MISSING"})
            if auth is None:
                return self.send_json(401, {"message": "unauthorized"})
            try:
                with open(f"{INST}/statuses/{m.group(1)}.json", encoding="utf-8") as f:
                    return self.send_json(200, json.load(f))
            except FileNotFoundError:
                return self.send_json(200, {"state": "", "total_count": 0, "statuses": []})
        logline({"method": "GET", "path": self.path, "auth": auth or "MISSING"})
        return self.send_json(404, {"message": "not found"})

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(n)
        auth = self.authed()
        logline({"method": "POST", "path": self.path, "auth": auth or "MISSING",
                 "body": body.decode("utf-8", "replace")})
        m = MERGE_RE.match(self.path)
        if not m:
            return self.send_json(404, {"message": "not found"})
        if auth is None:
            return self.send_json(401, {"message": "unauthorized"})
        try:
            req = json.loads(body)
        except Exception:
            return self.send_json(400, {"message": "bad body"})
        if req.get("Do") not in ("squash", "merge", "rebase"):
            return self.send_json(422, {"message": "invalid style"})
        prfile = f"{INST}/prs/{m.group(1)}.json"
        with open(prfile, encoding="utf-8") as f:
            pr = json.load(f)
        pr["merged"] = True
        pr["state"] = "closed"
        with open(prfile, "w", encoding="utf-8") as f:
            json.dump(pr, f)
        with open(f"{INST}/merge-events.log", "a", encoding="utf-8") as f:
            f.write(json.dumps({"pr": m.group(1), "style": req["Do"]}) + "\n")
        return self.send_json(200, {"message": ""})


def main():
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 443), Handler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(os.path.join(WORK, "certs", "cert.pem"),
                        os.path.join(WORK, "certs", "key.pem"))
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    with open(os.path.join(INST, "ready"), "w", encoding="utf-8") as f:
        f.write("ready")
    srv.serve_forever()


if __name__ == "__main__":
    main()
