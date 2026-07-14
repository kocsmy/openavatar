#!/usr/bin/env python3
"""Generates the Sparkle appcast for a release and EdDSA-signs the archive.

Usage: SPARKLE_ED_PRIVATE_KEY=<base64 ed25519 seed> \
       GITHUB_RUN_NUMBER=<build number> \
       make_appcast.py <tag> <zip-path> > appcast.xml

The appcast is attached to every GitHub release; the app's SUFeedURL points at
releases/latest/download/appcast.xml, so the newest release is always the feed.
"""
import base64
import datetime
import os
import sys

from nacl.signing import SigningKey  # pip install pynacl

tag = sys.argv[1]
zip_path = sys.argv[2]
version = tag.lstrip("v")
build = os.environ.get("GITHUB_RUN_NUMBER", "1")
repo = os.environ.get("GITHUB_REPOSITORY", "kocsmy/openavatar")

with open(zip_path, "rb") as f:
    data = f.read()

seed = base64.b64decode(os.environ["SPARKLE_ED_PRIVATE_KEY"])
signature = base64.b64encode(SigningKey(seed).sign(data).signature).decode()

url = f"https://github.com/{repo}/releases/download/{tag}/OpenAvatar.zip"
pub_date = datetime.datetime.now(datetime.timezone.utc).strftime(
    "%a, %d %b %Y %H:%M:%S +0000")

print(f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>OpenAvatar</title>
    <item>
      <title>OpenAvatar {version}</title>
      <pubDate>{pub_date}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.4</sparkle:minimumSystemVersion>
      <link>https://github.com/{repo}/releases/tag/{tag}</link>
      <enclosure url="{url}"
                 length="{len(data)}"
                 type="application/octet-stream"
                 sparkle:edSignature="{signature}"/>
    </item>
  </channel>
</rss>""")
