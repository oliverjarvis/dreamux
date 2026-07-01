#!/usr/bin/env python3
"""Dreamux test fixture: an HTTP server that reads its port from
PORTENV_SERVER_PORT (default 4600). Counterpart to fixedport-server,
which hardcodes its port — together they exercise both sides of the
Run pane's port-isolation story.

stdlib only; no third-party deps; no network beyond the local bind.
"""
import json
import os
import signal
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(os.environ.get("PORTENV_SERVER_PORT", "4600"))


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({
            "app": "portenv-server",
            "cwd": os.getcwd(),
            "port": PORT,
        }).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        # Keep stdout limited to the single deterministic startup line.
        pass


def main():
    server = HTTPServer(("127.0.0.1", PORT), Handler)

    def handle_sigterm(signum, frame):
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, handle_sigterm)
    print(f"listening on {PORT}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
