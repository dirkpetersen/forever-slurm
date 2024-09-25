#! /usr/bin/env python3

import sys, http.server, socketserver, socket

HOST = socket.gethostname()
PORT = 22222
if len(sys.argv) > 1:
    PORT = int(sys.argv[1])

class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-type', 'text/html')
        self.end_headers()
        incoming_url = f'http://{self.client_address[0]}:{PORT}{self.path}'
        self.wfile.write(f'Hello, Python from {HOST}:{PORT} ! '.encode())
        self.wfile.write(f'You accessed: {incoming_url}\n'.encode())        
        
class ReusableTCPServer(socketserver.TCPServer):
    allow_reuse_address = True

with ReusableTCPServer(("", PORT), Handler) as httpd:
    print(f"hello-python serving on port {PORT}", flush=True)
    httpd.serve_forever()
