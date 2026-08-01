#!/usr/bin/env python3
"""Refuse a migration that manages its own transaction.

migrate.sh wraps every file: `begin;`, the file, then either the ledger
row and `commit;`, or `rollback;` for a dry run. A top-level `commit;`
inside the file ends the RUNNER's transaction, so:

  * --dry-run applies for real and still prints "nothing was kept"; and
  * the change lands with no ledger row, because the insert meant to
    ride in the same transaction never runs inside it.

That is the one state the ledger exists to make impossible, and it is
silent — the runner reports success either way. It happened to 0037.

WHY THIS IS NOT A GREP

The first version of the guard matched `^\\s*(begin|commit|rollback)\\s*;`
— a keyword alone on a line. That catches the shape that caused the
incident and misses everything else: `start transaction;`, `commit
work;`, `select 1; commit;`, or a `commit;` sitting in a comment (a
false alarm rather than a miss, but still wrong).

It also could not look at `end`, which in Postgres is a synonym for
COMMIT. Bare `end;` is how a nested PL/pgSQL block closes — ten times
in schema.sql alone — so a line-based check had to skip it entirely and
would sail past a real top-level `end;`.

So this strips what cannot contain a statement — comments, string
literals, dollar-quoted bodies — and then asks whether any remaining
STATEMENT is transaction control. After stripping, a bare `end;` can
only mean COMMIT, and `select case … end;` is not a match because the
test is against the whole statement, not a substring.
"""
import re
import sys

# A statement that is nothing but transaction control. Matching the
# WHOLE statement, not a substring, is what makes `end` safe to include:
# `select case when x then 1 else 2 end` is a select, not a commit.
TX = re.compile(
    r"""(?ix)
    ^\s*(?:
        (?: begin | commit | rollback | end ) \s* (?: work | transaction )?
      | start \s+ transaction
      | abort \s* (?: work | transaction )?
    )\s*$
    """
)

DOLLAR_TAG = re.compile(r"\$[A-Za-z_][A-Za-z_0-9]*\$|\$\$")


def blank_noncode(sql: str) -> str:
    """Replace comments, strings and dollar-quoted bodies with spaces.

    Length and newlines are preserved so offsets still map to the
    original line numbers — the operator needs to be told WHERE.
    """
    out = []
    i, n = 0, len(sql)

    def blank(upto: int) -> None:
        for j in range(i, upto):
            out.append("\n" if sql[j] == "\n" else " ")

    while i < n:
        c = sql[i]

        # -- line comment
        if c == "-" and sql.startswith("--", i):
            j = sql.find("\n", i)
            j = n if j == -1 else j
            blank(j)
            i = j
            continue

        # /* block comment */ — nests in Postgres
        if c == "/" and sql.startswith("/*", i):
            depth, j = 0, i
            while j < n:
                if sql.startswith("/*", j):
                    depth += 1
                    j += 2
                elif sql.startswith("*/", j):
                    depth -= 1
                    j += 2
                    if depth == 0:
                        break
                else:
                    j += 1
            blank(j)
            i = j
            continue

        # 'string literal', with '' as the escape
        if c == "'":
            j = i + 1
            while j < n:
                if sql[j] == "'":
                    if sql.startswith("''", j):
                        j += 2
                        continue
                    j += 1
                    break
                j += 1
            blank(j)
            i = j
            continue

        # "quoted identifier" — cannot contain a statement either
        if c == '"':
            j = sql.find('"', i + 1)
            j = n if j == -1 else j + 1
            blank(j)
            i = j
            continue

        # $$ … $$ or $tag$ … $tag$
        if c == "$":
            m = DOLLAR_TAG.match(sql, i)
            if m:
                tag = m.group(0)
                close = sql.find(tag, m.end())
                j = n if close == -1 else close + len(tag)
                blank(j)
                i = j
                continue

        out.append(c)
        i += 1

    return "".join(out)


def offences(sql: str):
    """(line number, original text) for each transaction-control statement."""
    code = blank_noncode(sql)
    found, start = [], 0
    for m in re.finditer(r";", code):
        stmt = code[start : m.start()]
        if TX.match(stmt):
            line = code.count("\n", 0, start + len(stmt) - len(stmt.lstrip())) + 1
            found.append((line, sql.splitlines()[line - 1].strip()))
        start = m.end()
    return found


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: _txcheck.py <file.sql>", file=sys.stderr)
        return 2
    with open(sys.argv[1], encoding="utf-8", errors="replace") as fh:
        sql = fh.read()
    hits = offences(sql)
    if not hits:
        return 0
    for line, text in hits:
        print(f"{line}:{text}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
