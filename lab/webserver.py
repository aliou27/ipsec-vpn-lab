#!/usr/bin/env python3
"""Tiny web server run on every host of the lab.

  port 80    HTTP   allowed between sites (through the VPN)
  port 443   HTTPS  allowed between sites (through the VPN)
  port 8080  HTTP   "internal admin app": NOT allowed between sites

Usage: webserver.py <ip> <www-dir> <admin-dir> <cert.pem> <key.pem>
"""
import functools
import http.server
import ssl
import sys
import threading


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def serve(ip, port, directory, tls=None):
    handler = functools.partial(QuietHandler, directory=directory)
    server = http.server.ThreadingHTTPServer((ip, port), handler)
    if tls:
        server.socket = tls.wrap_socket(server.socket, server_side=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()


def main():
    ip, www, admin, cert, key = sys.argv[1:6]
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(cert, key)
    serve(ip, 80, www)
    serve(ip, 443, www, tls)
    serve(ip, 8080, admin)
    threading.Event().wait()


if __name__ == "__main__":
    main()
