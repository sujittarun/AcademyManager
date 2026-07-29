#!/usr/bin/env python3
"""POST one SQL payload to the Supabase Management API.

Split out of migrate.sh so failure is decided by the HTTP status line and
the response shape, not by grepping the body for the word "error" — which
is what the previous script did, and which fails both ways:

  * a successful migration whose result rows happen to contain "error"
    (a column called error_count, say) was reported as a failure;
  * a genuine failure that returned an empty body, a network reset, or an
    error payload not containing that literal string was reported as
    SUCCESS, and the operator moved on believing the change had landed.

Usage:  _sql.py <file-containing-sql>
Prints the response body on stdout. Exit 0 only on 2xx.
"""
import json
import os
import sys
import urllib.error
import urllib.request

PROJECT_REF = os.environ.get("SUPABASE_PROJECT_REF", "ugsklcipzyiogxynshnh")
TOKEN_FILE = os.path.expanduser(
    os.environ.get("SUPABASE_TOKEN_FILE", "~/.supabase/access-token")
)
ENDPOINT = f"https://api.supabase.com/v1/projects/{PROJECT_REF}/database/query"


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: _sql.py <file-containing-sql>", file=sys.stderr)
        return 2

    try:
        with open(TOKEN_FILE) as fh:
            token = fh.read().strip()
    except OSError as exc:
        print(f"cannot read {TOKEN_FILE}: {exc}", file=sys.stderr)
        return 2
    if not token:
        print(f"{TOKEN_FILE} is empty", file=sys.stderr)
        return 2

    with open(sys.argv[1]) as fh:
        sql = fh.read()

    req = urllib.request.Request(
        ENDPOINT,
        data=json.dumps({"query": sql}).encode(),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=180) as resp:
            body = resp.read().decode()
            print(body)
            # 2xx only. Anything else is a failure regardless of body text.
            return 0 if 200 <= resp.status < 300 else 1
    except urllib.error.HTTPError as exc:
        # Postgres errors arrive here as 4xx/5xx with a JSON body.
        print(exc.read().decode(), file=sys.stderr)
        print(f"HTTP {exc.code}", file=sys.stderr)
        return 1
    except Exception as exc:
        # Timeout, DNS, TLS, connection reset — previously indistinguishable
        # from success. Now it is a failure, loudly.
        print(f"request failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
