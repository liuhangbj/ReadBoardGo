"""Loopback-only TLS fixture. Never loads ReadBoard credentials or data."""
import argparse
import http.server
import ssl

parser = argparse.ArgumentParser()
parser.add_argument("--certificate", required=True)
parser.add_argument("--key", required=True)
parser.add_argument("--requests", required=True)
parser.add_argument("--port", type=int, default=0)
args = parser.parse_args()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        self.respond()

    def do_POST(self):
        self.respond()

    def respond(self):
        with open(args.requests, "a", encoding="utf-8") as log:
            log.write(self.command + " " + self.path + "\n")
        if self.path == "/drop":
            self.close_connection = True
            return
        body = b'{"ok":true}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()
        self.close_connection = True

    def log_message(self, *_):
        pass


server = http.server.HTTPServer(("127.0.0.1", args.port), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(args.certificate, args.key)
server.socket = context.wrap_socket(server.socket, server_side=True)
print(server.server_port, flush=True)
server.serve_forever()
