#!/usr/bin/env python3
"""Serves each demo team's intranet page at http://<team>.localhost:<port>/.

Chrome resolves *.localhost to this machine, so the address bar reads like a
real company site instead of a file path. Only the requested team's
intranet.html is ever served.

usage: intranet.py <demo-home> [port]
"""

import http.server
import pathlib
import sys

HOME = pathlib.Path(sys.argv[1]).resolve()
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 4321


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        team = self.headers.get("Host", "").split(".")[0]
        page = HOME / "Projects" / team / "intranet.html"
        if not team.isalnum() or not page.is_file():
            self.send_error(404)
            return
        body = page.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
