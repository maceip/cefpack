#!/usr/bin/env python3
"""Read the account of a Limrun key, and print it in one line.

The answer of `GET /v1/whoami` is the only place where the platform tells
who a key belongs to.  The script prints three fields, separated by a
pipe: the name of the organization, its id, and the credit in minutes.

    python3 whoami.py < answer.json

The name of the organization is not always there; the id is, and it is
what the log of the build carries when there is no name.
"""

from __future__ import annotations

import json
import sys


def main() -> int:
    try:
        answer = json.load(sys.stdin)
    except (json.JSONDecodeError, OSError) as error:
        print(f"the answer of the platform is not JSON: {error}", file=sys.stderr)
        return 1

    organization = answer.get("organization") or {}
    name = organization.get("displayName") or organization.get("name") or ""
    identifier = organization.get("id") or ""
    credit = organization.get("creditMinutes")

    if not identifier:
        print("the answer of the platform carries no organization", file=sys.stderr)
        return 1

    print(f"{name}|{identifier}|{0 if credit is None else credit}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
