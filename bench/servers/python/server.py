"""The benchmark API in Python, on its standard library (bench/README.md has
the spec): http.server with HTTP/1.1 keep-alive, a thread per connection, and
one process per core, forked after binding so they share the socket. The GIL
limits each process to one core at a time, which the forking works around.

    python3 bench/servers/python/server.py
"""
import json
import os
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

ITEM = re.compile(r"^/items/([^/]+)$")
INT = re.compile(r"^-?\d+$")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def send_json(self, status, value):
        body = json.dumps(value, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urlsplit(self.path)
        if url.path == "/hello":
            return self.send_json(200, {"message": "Honk!"})
        item = ITEM.match(url.path)
        if item:
            if not INT.match(item.group(1)):
                return self.send_json(422, {"detail": [{"type": "int_parsing", "loc": ["path", "item_id"]}]})
            q = parse_qs(url.query).get("q", [""])[0]
            return self.send_json(200, {"item_id": int(item.group(1)), "q": q})
        self.send_json(404, {"detail": "Not Found"})

    def do_POST(self):
        if urlsplit(self.path).path != "/items":
            return self.send_json(404, {"detail": "Not Found"})
        length = int(self.headers.get("content-length", 0))
        try:
            body = json.loads(self.rfile.read(length))
        except ValueError:
            body = None
        price = body.get("price") if isinstance(body, dict) else None
        if not isinstance(body, dict) or not isinstance(body.get("name"), str) \
                or not isinstance(price, (int, float)) or isinstance(price, bool):
            return self.send_json(422, {"detail": [{"type": "invalid", "msg": "name and price are required"}]})
        self.send_json(201, {"name": body["name"], "price": price, "price_with_tax": price * 1.2})


class Server(ThreadingHTTPServer):
    request_queue_size = 1024       # the listen backlog; socketserver's default is 5


def main():
    server = Server(("127.0.0.1", 8000), Handler)
    server.daemon_threads = True
    for _ in range((os.cpu_count() or 1) - 1):
        if os.fork() == 0:
            break
    server.serve_forever()


if __name__ == "__main__":
    main()
