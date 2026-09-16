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


def chained_pac(proxy_port: int, fallback: str) -> str:
    """PAC for browser proxy extensions that already own Chrome proxy state.

    GBF static assets are intercepted by this project's local HTTP proxy while
    every other request keeps using the user's existing proxy route.  This is
    intentionally a separate endpoint from /proxy.pac so system-PAC users keep
    the original DIRECT behavior.
    """
    fallback = fallback.strip() or "DIRECT"
    # PAC return strings are quoted below, so reject values that would turn the
    # configured fallback into executable PAC source.
    if any(ch in fallback for ch in ('"', "'", "\n", "\r", "\\")):
        raise ValueError("PAC fallback contains an unsupported character")
    return f'''function FindProxyForURL(url, host) {{
    host = (host || "").toLowerCase();
    if (/^prd-game-a[0-9]*-(gbf|granbluefantasy)\\.akamaized\\.net$/.test(host)) {{
        return "PROXY 127.0.0.1:{proxy_port}; {fallback}";
    }}
    return "{fallback}";
}}
'''


class Handler(BaseHTTPRequestHandler):
    proxy_port = 18123
    browser_fallback = "DIRECT"
    root_browser_pac = False

    def do_GET(self) -> None:  # noqa: N802
        if self.path not in {"/proxy.pac", "/", "/browser-proxy.pac"}:
            self.send_error(404)
            return
        if self.path == "/browser-proxy.pac" or (
            self.path in {"/proxy.pac", "/"} and self.root_browser_pac
        ):
            body = chained_pac(self.proxy_port, self.browser_fallback).encode("utf-8")
        else:
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
    parser.add_argument(
        "--browser-fallback",
        default="DIRECT",
        help=(
            "PAC result used for non-GBF traffic at /browser-proxy.pac, "
            "for example 'SOCKS5 127.0.0.1:1080; DIRECT'"
        ),
    )
    parser.add_argument(
        "--root-browser-pac",
        action="store_true",
        help="serve the chained browser PAC at /proxy.pac as well as /browser-proxy.pac",
    )
    args = parser.parse_args()
    Handler.proxy_port = args.proxy_port
    Handler.browser_fallback = args.browser_fallback
    Handler.root_browser_pac = args.root_browser_pac
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"PAC server listening on {args.host}:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
