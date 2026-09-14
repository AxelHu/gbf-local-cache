from __future__ import annotations

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def pac(proxy_port: int) -> str:
    return f'''function FindProxyForURL(url, host) {{
    host = (host || "").toLowerCase();
    // Deliberately only GBF static Akamai asset hosts. Login, game API,
    // WebSocket and every unrelated website remain DIRECT.
    if (/^prd-game-a[0-9]*-(gbf|granbluefantasy)\\.akamaized\\.net$/.test(host)) {{
        // Fail open: if the local cache is stopped, fetch the asset directly.
        return "PROXY 127.0.0.1:{proxy_port}; DIRECT";
    }}
    return "DIRECT";
}}
'''


class Handler(BaseHTTPRequestHandler):
    proxy_port = 18123

    def do_GET(self) -> None:  # noqa: N802
        if self.path not in {"/proxy.pac", "/"}:
            self.send_error(404)
            return
        body = pac(self.proxy_port).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ns-proxy-autoconfig")
        self.send_header("Cache-Control", "no-store, max-age=0")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt: str, *args: object) -> None:
        return


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=18124)
    parser.add_argument("--proxy-port", type=int, default=18123)
    args = parser.parse_args()
    Handler.proxy_port = args.proxy_port
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"PAC server listening on {args.host}:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
