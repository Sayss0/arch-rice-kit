#!/usr/bin/env python3
"""VM test server: GET serves the built kit (../out) and the test driver (www/);
PUT saves uploaded logs/results into results/.  Listens on 0.0.0.0:8080 (the VM
reaches it as http://10.0.2.2:8080 through QEMU user networking)."""
import http.server, os, shutil

BASE = os.path.dirname(os.path.abspath(__file__))
ROOTS = [os.path.join(BASE, "..", "out"), os.path.join(BASE, "www")]
RESULTS = os.path.join(BASE, "results")
os.makedirs(RESULTS, exist_ok=True)


class H(http.server.SimpleHTTPRequestHandler):
    def translate_path(self, path):
        name = os.path.basename(path.split("?")[0])
        for r in ROOTS:
            p = os.path.join(r, name)
            if os.path.exists(p):
                return p
        return os.path.join(ROOTS[0], name)

    def do_PUT(self):
        name = os.path.basename(self.path)
        n = int(self.headers.get("Content-Length", 0))
        with open(os.path.join(RESULTS, name), "wb") as f:
            remaining = n
            while remaining > 0:
                chunk = self.rfile.read(min(remaining, 1 << 20))
                if not chunk:
                    break
                f.write(chunk); remaining -= len(chunk)
        self.send_response(201); self.end_headers()

    def log_message(self, fmt, *args):
        with open(os.path.join(RESULTS, "server.log"), "a") as f:
            f.write("%s %s\n" % (self.log_date_time_string(), fmt % args))


http.server.ThreadingHTTPServer(("0.0.0.0", 8080), H).serve_forever()
