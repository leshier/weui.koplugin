#!/usr/bin/env python3
"""
Verify WeRead progress sync APIs (get and set).
Script-first validation per CLAUDE.md before Lua implementation.

Usage:
  export WR_COOKIE="wr_skey=xxx; wr_gid=xxx"
  python verify_progress_sync.py <book_id>
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36"
)

def md5_hex(s: str) -> str:
    return hashlib.md5(s.encode("utf-8")).hexdigest()

def weread_e(s: str) -> str:
    """WeRead Web API e_* parameter encoder (identical to Lua weread.lua)."""
    h = md5_hex(s)
    result = h[:3]
    if re.fullmatch(r"\d+", s):
        chunks = [format(int(s[i:i+9]), "x") for i in range(0, len(s), 9)]
        type_flag = "3"
    else:
        chunks = ["".join(format(ord(ch), "x") for ch in s)]
        type_flag = "4"
    for chunk in chunks:
        result += chunk.rjust(2, "0")
    result += type_flag + h[3:6]
    return result

class WeReadClient:
    def __init__(self, cookie: str):
        self.cookie = cookie
        self.opener = urllib.request.build_opener()
        self.opener.addheaders = [
            ("Cookie", cookie),
            ("User-Agent", USER_AGENT),
            ("Referer", "https://weread.qq.com/"),
        ]

    def get(self, url: str) -> dict:
        req = urllib.request.Request(url, headers={"Cookie": self.cookie, "User-Agent": USER_AGENT, "Referer": "https://weread.qq.com/"})
        with self.opener.open(req, timeout=15) as r:
            return json.loads(r.read().decode("utf-8"))

    def post(self, url: str, data: dict) -> dict:
        body = urllib.parse.urlencode(data).encode("utf-8")
        req = urllib.request.Request(url, data=body, headers={
            "Cookie": self.cookie,
            "User-Agent": USER_AGENT,
            "Referer": "https://weread.qq.com/",
            "Content-Type": "application/x-www-form-urlencoded",
        }, method="POST")
        with self.opener.open(req, timeout=15) as r:
            return json.loads(r.read().decode("utf-8"))

    # === Gateway API (official, Bearer-like with appid/secret) ===
    # Note: We have cookie-based Web API; gateway needs API key.
    # Let's try the Web API for progress first.

    def web_get_progress(self, book_id: str) -> dict:
        """Try Web API progress endpoint (reader page context)."""
        book_key = weread_e(book_id)
        # Known endpoint from research
        url = f"https://weread.qq.com/web/book/{book_key}/progress"
        try:
            return self.get(url)
        except urllib.error.HTTPError as e:
            return {"_http_error": e.code, "_msg": str(e)}

    def web_reader_page(self, book_id: str) -> str:
        """Fetch reader page to get __INITIAL_STATE__ (for progress fields)."""
        book_key = weread_e(book_id)
        url = f"https://weread.qq.com/web/reader/{book_key}"
        try:
            req = urllib.request.Request(url, headers={"Cookie": self.cookie, "User-Agent": USER_AGENT})
            with urllib.request.urlopen(req, timeout=15) as r:
                return r.read().decode("utf-8")
        except urllib.error.HTTPError as e:
            return f"HTTP {e.code}"

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("book_id", nargs="?", default="", help="WeRead bookId (e.g. 3784483)")
    parser.add_argument("--cookie", default=os.environ.get("WR_COOKIE", ""))
    args = parser.parse_args()

    if not args.cookie:
        print("ERROR: set WR_COOKIE env var or pass --cookie", file=sys.stderr)
        sys.exit(1)

    client = WeReadClient(args.cookie)

    if args.book_id:
        print(f"=== Book ID: {args.book_id} ===")
        book_key = weread_e(args.book_id)
        print(f"  e_encoded: {book_key}")

        # Test 1: reader page (to find progress fields + set-progress endpoints)
        print("\n--- reader page ---")
        html = client.web_reader_page(args.book_id)
        if isinstance(html, str) and html.startswith("HTTP"):
            print(f"  {html}")
        else:
            print(f"  length: {len(html)}")
            # Extract progress-related fields from __INITIAL_STATE__
            m = re.search(r'window\.__INITIAL_STATE__\s*=\s*(.+?)\s*;\s*\(function', html, re.DOTALL)
            if m:
                try:
                    state = json.loads(m.group(1))
                    reader = state.get("reader", {})
                    prog = reader.get("progress", {})
                    print(f"  reader.progress keys: {list(prog.keys()) if isinstance(prog, dict) else type(prog)}")
                    if isinstance(prog, dict):
                        for k, v in prog.items():
                            print(f"    {k}: {v}")
                    print(f"  reader keys: {list(reader.keys())[:20]}")
                except Exception as e:
                    print(f"  parse INITIAL_STATE error: {e}")
            else:
                print("  no __INITIAL_STATE__ found")

            # Look for set-progress / update-progress / report endpoints in JS
            set_prog_matches = re.findall(r'["\'](/web/[^"\']*progress[^"\']*)["\']', html)
            if set_prog_matches:
                print(f"\n  progress-related URLs found in page:")
                for u in set(set_prog_matches):
                    print(f"    {u}")
            else:
                print(f"\n  no progress URLs found in page JS")

    else:
        print("No book_id provided. Pass a bookId to test.")

if __name__ == "__main__":
    main()
