#!/usr/bin/env python3
"""A throw-away HTTP endpoint that answers the CORS handshake in a chosen way.

`scripts/verify-cors-runtime.sh` asserts a header contract. This fixture lets
the suite present that contract both correctly and incorrectly, so the check is
proven to pass the compliant shape and to fail each non-compliant one --
including the shapes a real misconfiguration would produce.

It is a TEST FIXTURE and is never part of the gateway: it stands in for the
running edge so the check can be exercised without the Docker Compose stack.
A green run here does NOT discharge AC-16, which is a statement about the real
gateway; it only establishes that the instrument is working.

Usage: mock-edge.py <mode>
Prints the bound port on stdout, then serves until terminated.

Modes:
  exact        echo the caller's origin only when it is the allowed one,
               with Access-Control-Allow-Credentials: true (the shape FR-11
               produces)
  wildcard     answer '*' to everyone (the pre-change shape)
  split        echo the exact origin on the preflight but '*' on the POST
  no-creds     the exact-origin shape with Access-Control-Allow-Credentials
               omitted
  echo-any     echo whatever origin asks, so both origins are allowed without
               a literal '*' ever appearing
"""

import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

ALLOWED_ORIGIN = "http://localhost:5173"


class Handler(BaseHTTPRequestHandler):
    mode = "exact"

    def log_message(self, *args):  # keep the suite's output clean
        pass

    def _cors_headers(self, preflight):
        origin = self.headers.get("Origin", "")
        mode = Handler.mode

        if mode == "wildcard":
            return [("Access-Control-Allow-Origin", "*")]
        if mode == "echo-any":
            if not origin:
                return []
            return [
                ("Access-Control-Allow-Origin", origin),
                ("Access-Control-Allow-Credentials", "true"),
            ]
        if mode == "split" and not preflight:
            return [("Access-Control-Allow-Origin", "*")]

        if origin != ALLOWED_ORIGIN:
            # A correctly configured edge simply omits the header for an origin
            # it does not allow, which is what makes the response unreadable.
            return []

        headers = [("Access-Control-Allow-Origin", origin)]
        if mode != "no-creds":
            headers.append(("Access-Control-Allow-Credentials", "true"))
        return headers

    def _respond(self, status, preflight):
        self.send_response(status)
        for name, value in self._cors_headers(preflight):
            self.send_header(name, value)
        if preflight:
            self.send_header("Access-Control-Allow-Methods", "POST, PUT, DELETE")
            self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        # The reachability probe the runtime check makes before asserting.
        self._respond(200, preflight=False)

    def do_OPTIONS(self):
        self._respond(204, preflight=True)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        # 400 is the realistic answer to the empty credential pair the check
        # sends; the browser's CORS decision is taken before the status matters.
        self._respond(400, preflight=False)


def main():
    Handler.mode = sys.argv[1] if len(sys.argv) > 1 else "exact"
    server = HTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_address[1], flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
