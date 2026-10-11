import socket, threading, sys

lport, oport = int(sys.argv[1]), int(sys.argv[2])

def handle(c):
    up = None
    try:
        req = b""
        while b"\r\n\r\n" not in req:
            d = c.recv(4096)
            if not d:
                return
            req += d
        line = req.split(b"\r\n", 1)[0].decode("latin-1")
        parts = line.split()
        if len(parts) < 2 or parts[0] != "CONNECT":
            try:
                c.sendall(b"HTTP/1.1 405 Method Not Allowed\r\ncontent-length: 0\r\n\r\n")
            except OSError:
                pass
            return
        up = socket.create_connection(("127.0.0.1", oport), timeout=60)
        up.settimeout(None)
        c.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        def pump(a, b):
            try:
                while True:
                    d = a.recv(65536)
                    if not d:
                        break
                    b.sendall(d)
            except OSError:
                pass
            finally:
                for s in (a, b):
                    try:
                        s.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass
        threading.Thread(target=pump, args=(c, up), daemon=True).start()
        pump(up, c)
    except OSError:
        pass
    finally:
        try:
            c.close()
        except OSError:
            pass
        if up:
            try:
                up.close()
            except OSError:
                pass

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", lport))
srv.listen(128)
print("proxy-listening", lport, "->", oport, flush=True)
while True:
    conn, _ = srv.accept()
    threading.Thread(target=handle, args=(conn,), daemon=True).start()
