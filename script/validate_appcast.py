#!/usr/bin/env python3
"""Validate the public feed, optionally matching a candidate to a local DMG."""
import base64
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def validate(path, version=None, artifact=None):
    root = ET.parse(path).getroot()
    if root.tag != "rss" or root.find("channel") is None:
        raise ValueError("Expected an RSS channel")
    seen = set()
    match = None
    for item in root.findall("./channel/item"):
        release = item.findtext(SPARKLE + "shortVersionString", "")
        build = item.findtext(SPARKLE + "version", "")
        if not re.fullmatch(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?", release):
            raise ValueError("Invalid release version")
        if not re.fullmatch(r"[0-9]+", build) or build in seen:
            raise ValueError("Invalid or repeated build")
        seen.add(build)
        enclosure = item.find("enclosure")
        if enclosure is None:
            raise ValueError("Missing enclosure")
        expected = f"https://github.com/nomdelasociete/git-island/releases/download/v{release}/Git-Island-{release}.dmg"
        if enclosure.get("url") != expected:
            raise ValueError("Unexpected download URL")
        signature = base64.b64decode(enclosure.get(SPARKLE + "edSignature", ""), validate=True)
        if len(signature) != 64 or int(enclosure.get("length", "0")) <= 0:
            raise ValueError("Missing archive signature or length")
        if not item.findtext(SPARKLE + "minimumSystemVersion"):
            raise ValueError("Missing minimum macOS version")
        if release == version:
            if match is not None:
                raise ValueError("Multiple candidates for requested version")
            match = enclosure
    if version is not None:
        if match is None or int(match.get("length")) != Path(artifact).stat().st_size:
            raise ValueError("Candidate missing or archive length differs")


if __name__ == "__main__":
    validate(*sys.argv[1:])
    print("Appcast structure validated (cryptographic verification is separate).")
