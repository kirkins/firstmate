#!/usr/bin/env python3
"""Disposable local stand-in for the Forgejo REST API subset the forge-mail
plane uses. Serves real HTTPS on 127.0.0.1:<port> with a self-signed cert for
mailbox.test.forge; enforces the drain-token Authorization header; persists
server-side effects (comments, closes) to forge-state.json; logs every request
to requests.log. Scenario shaping happens through files in ctl/."""
import http.server, ssl, json, os, sys, time, threading, re

RIG = os.path.dirname(os.path.abspath(__file__))
CTL = os.path.join(RIG, "ctl")
TOKEN = "faketoken0123456789abcdef"
PORT = int(sys.argv[1])

REQ_SEQ = 0
LOG_LOCK = threading.Lock()
STATE_LOCK = threading.Lock()


def ctl(name, default=None):
    try:
        with open(os.path.join(CTL, name)) as f:
            v = f.read().strip()
        return v if v != "" else default
    except OSError:
        return default


def load_issues():
    try:
        with open(os.path.join(CTL, "issues.json")) as f:
            return json.load(f)
    except (OSError, ValueError):
        return []


def load_state():
    try:
        with open(os.path.join(RIG, "forge-state.json")) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {"comments": [], "closed": [], "seq": 0}


def save_state(st):
    tmp = os.path.join(RIG, "forge-state.json.tmp")
    with open(tmp, "w") as f:
        json.dump(st, f, indent=1)
    os.replace(tmp, os.path.join(RIG, "forge-state.json"))


def log(line):
    global REQ_SEQ
    with LOG_LOCK:
        REQ_SEQ += 1
        with open(os.path.join(RIG, "requests.log"), "a") as f:
            f.write("%04d %s\n" % (REQ_SEQ, line))


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _refused(self):
        # ctl/refuse present: kill the connection with no reply, like an
        # unreachable server.
        try:
            self.connection.close()
        except OSError:
            pass
        self.close_connection = True

    def _sleep(self):
        s = ctl("sleep", "0")
        try:
            time.sleep(float(s))
        except (TypeError, ValueError):
            pass

    def _auth(self):
        got = self.headers.get("Authorization", "")
        return got == "token " + TOKEN, got

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self):
        n = int(self.headers.get("Content-Length", "0") or 0)
        raw = self.rfile.read(n) if n else b""
        try:
            return json.loads(raw.decode())
        except ValueError:
            return {"_raw": raw.decode("latin-1")}

    def _route(self):
        if (ctl("refuse") or "") != "":
            self._refused()
            return
        self._sleep()
        path, _, query = self.path.partition("?")
        ok, _hdr = self._auth()
        auth = "auth=ok" if ok else "auth=FAIL"
        if not ok:
            log("%s %s %s 401" % (self.command, path, auth))
            self._send(401, {"message": "Unauthorized"})
            return
        m = re.fullmatch(r"/api/v1/repos/([^/]+)/([^/]+)", path)
        if self.command == "GET" and m:
            repo_id = ctl("repo-id", "70001")
            log("GET %s %s 200 repo-id=%s" % (path, auth, repo_id))
            self._send(200, {"id": int(repo_id), "full_name": m.group(1) + "/" + m.group(2)})
            return
        m = re.fullmatch(r"/api/v1/repos/([^/]+)/([^/]+)/issues", path)
        if self.command == "GET" and m and query:
            with STATE_LOCK:
                closed = set(load_state()["closed"])
            issues = [i for i in load_issues() if int(i["number"]) not in closed]
            log("GET %s?%s %s 200 open=%d" % (path, query, auth, len(issues)))
            self._send(200, issues)
            return
        m = re.fullmatch(r"/api/v1/repos/([^/]+)/([^/]+)/issues/([0-9]+)", path)
        if m:
            n = int(m.group(3))
            if self.command == "GET":
                for i in load_issues():
                    if int(i["number"]) == n:
                        log("GET %s %s 200 open" % (path, auth))
                        self._send(200, i)
                        return
                with STATE_LOCK:
                    st = load_state()
                    if n in st["closed"]:
                        log("GET %s %s 200 closed" % (path, auth))
                        self._send(200, {"number": n, "state": "closed",
                                         "title": "(closed)", "body": "",
                                         "user": {"login": "unknown"}})
                        return
                log("GET %s %s 404" % (path, auth))
                self._send(404, {"message": "Not Found"})
                return
            if self.command == "PATCH":
                body = self._read_body()
                ret_state = ctl("close-state", "closed")
                with STATE_LOCK:
                    st = load_state()
                    st["seq"] += 1
                    st["closed"] = sorted(set(st["closed"]) | {n})
                    save_state(st)
                log("PATCH %s %s 200 body=%s ret-state=%s"
                    % (path, auth, json.dumps(body), ret_state))
                self._send(200, {"number": n, "state": ret_state,
                                 "title": "x", "body": "b",
                                 "user": {"login": "bot"}})
                return
            self._send(405, {"message": "Method Not Allowed"})
            return
        m = re.fullmatch(r"/api/v1/repos/([^/]+)/([^/]+)/issues/([0-9]+)/comments", path)
        if self.command == "POST" and m:
            body = self._read_body()
            code = int(ctl("comment-code", "201"))
            with STATE_LOCK:
                st = load_state()
                st["seq"] += 1
                cid = st["seq"]
                if code == 201:
                    st["comments"].append({"id": cid, "issue": int(m.group(3)),
                                           "body": body.get("body", "")})
                    save_state(st)
            log("POST %s %s %d body=%s" % (path, auth, code, json.dumps(body)))
            self._send(code, {"id": cid})
            return
        log("%s %s %s 404" % (self.command, path, auth))
        self._send(404, {"message": "Not Found"})

    def do_GET(self):
        self._route()

    def do_POST(self):
        self._route()

    def do_PATCH(self):
        self._route()


httpd = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(os.path.join(RIG, "srv-cert.pem"), os.path.join(RIG, "srv-key.pem"))
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
print("forge-listening", PORT, flush=True)
httpd.serve_forever()
