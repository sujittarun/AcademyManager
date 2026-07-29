#!/usr/bin/env python3
"""POST one SQL payload to the Supabase Management API.

Split out of migrate.sh so failure is decided by the HTTP status line,
not by grepping the body for the word "error" — which is what the
previous script did, and which fails both ways:

  * a successful migration whose result rows happen to contain "error"
    (a column called error_count, say) was reported as a failure;
  * a genuine failure that returned an empty body, a network reset, or an
    error payload not containing that literal string was reported as
    SUCCESS, and the operator moved on believing the change had landed.

Uses curl rather than urllib: the API sits behind Cloudflare, which
answers urllib's user-agent with a 403 (error 1010). The token is passed
through a 0600 config file so it never appears in the process list.

Usage:  _sql.py <file-containing-sql>
Prints the response body on stdout. Exit 0 only on 2xx.
"""
import os
import subprocess
import sys
import tempfile

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

    tmp = tempfile.mkdtemp()
    cfg = os.path.join(tmp, "curl.cfg")
    body_path = os.path.join(tmp, "body")
    payload_path = os.path.join(tmp, "payload.json")

    try:
        import json

        with open(payload_path, "w") as fh:
            json.dump({"query": sql}, fh)

        # Keep the bearer token out of argv — `ps` would otherwise show it.
        fd = os.open(cfg, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as fh:
            fh.write(f'header = "Authorization: Bearer {token}"\n')
            fh.write('header = "Content-Type: application/json"\n')

        proc = subprocess.run(
            [
                "curl", "-sS", "-K", cfg,
                "-X", "POST", ENDPOINT,
                "--data-binary", f"@{payload_path}",
                "-o", body_path,
                "-w", "%{http_code}",
                "--max-time", "180",
            ],
            capture_output=True,
            text=True,
        )

        body = ""
        if os.path.exists(body_path):
            with open(body_path) as fh:
                body = fh.read()

        if proc.returncode != 0:
            # Connection reset, DNS, TLS, timeout — previously
            # indistinguishable from success.
            print(body, file=sys.stderr)
            print(f"curl failed: {proc.stderr.strip()}", file=sys.stderr)
            return 1

        status = (proc.stdout or "").strip()
        if status.isdigit() and 200 <= int(status) < 300:
            print(body)
            return 0

        print(body, file=sys.stderr)
        print(f"HTTP {status or 'unknown'}", file=sys.stderr)
        return 1
    finally:
        for p in (cfg, body_path, payload_path):
            try:
                os.remove(p)
            except OSError:
                pass
        try:
            os.rmdir(tmp)
        except OSError:
            pass


if __name__ == "__main__":
    sys.exit(main())
