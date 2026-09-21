#!/usr/bin/env python3
"""Renders ${VAR} placeholders in a template from the environment.

Deliberately stricter than envsubst: an unset variable is an error rather
than an empty string, so a half-configured service never reaches Cloud Run.
${VAR:-default} is supported for the genuinely optional ones.
"""
import os
import re
import sys

PATTERN = re.compile(r"\$\{([A-Z_][A-Z0-9_]*)(?::-([^}]*))?\}")


def main() -> None:
    template = open(sys.argv[1]).read()
    missing: list[str] = []

    def sub(m: re.Match) -> str:
        name, default = m.group(1), m.group(2)
        value = os.environ.get(name)
        if value:
            return value
        if default is not None:
            return default
        missing.append(name)
        return ""

    out = PATTERN.sub(sub, template)
    if missing:
        sys.exit(f"render: unset variable(s): {', '.join(sorted(set(missing)))}")
    sys.stdout.write(out)


if __name__ == "__main__":
    main()
