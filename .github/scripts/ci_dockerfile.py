"""Write a CI copy of build/Dockerfile without the NREL root certificate downloads.

build/Dockerfile downloads the NREL root certificates from raw.github.nrel.gov, which only resolves
on the NREL network. GitHub runners are outside it, so this replaces each download:
- with --cert-dir, by a copy of the matching PEM file (e.g. nrel_root.pem) from that directory,
  which is copied into the image just before the RUN instruction that needs it;
- otherwise, by `true`, so the image is built without the NREL certificates.
build/Dockerfile itself is not changed.
"""

import argparse
import re
from pathlib import Path

DOWNLOAD = re.compile(r"curl\s+-fsSLk\s+-o\s+(?P<dest>\S+)\s+https://raw\.github\.nrel\.gov/\S+/(?P<name>[^/\s]+\.pem)")
STAGED_DIR = "/tmp/ci-nrel-certs"


def instructions(lines):
    """Group Dockerfile lines into instructions, joining backslash continuation lines."""
    block = []
    for line in lines:
        block.append(line)
        if not line.rstrip("\r\n").endswith("\\"):
            yield block
            block = []
    if block:
        yield block


def patch(text: str, cert_dir: str | None) -> tuple[str, list[str]]:
    output, names = [], []
    for block in instructions(text.splitlines(keepends=True)):
        joined = "".join(block)
        found = [match["name"] for match in DOWNLOAD.finditer(joined)]
        if found and cert_dir:
            newline = "\r\n" if block[0].endswith("\r\n") else "\n"
            output.append(f"COPY {cert_dir.rstrip('/')}/ {STAGED_DIR}/{newline}")
            joined = DOWNLOAD.sub(lambda match: f"cp {STAGED_DIR}/{match['name']} {match['dest']}", joined)
        elif found:
            joined = DOWNLOAD.sub("true", joined)
        names.extend(found)
        output.append(joined)
    return "".join(output), names


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--cert-dir", help="PEM directory, relative to the Docker build context")
    args = parser.parse_args()

    with args.source.open(encoding="utf-8", newline="") as stream:
        text, names = patch(stream.read(), args.cert_dir)
    if not names:
        parser.error(f"No NREL certificate downloads found in {args.source}; update {Path(__file__).name}")
    if args.cert_dir:
        missing = sorted({name for name in names if not (Path(args.cert_dir) / name).is_file()})
        if missing:
            parser.error(f"Missing certificate files in {args.cert_dir}: {', '.join(missing)}")
    with args.destination.open("w", encoding="utf-8", newline="") as stream:
        stream.write(text)
    action = f"copied from {args.cert_dir}" if args.cert_dir else "skipped"
    print(f"Wrote {args.destination}: {len(names)} NREL certificate downloads {action}")


if __name__ == "__main__":
    main()
