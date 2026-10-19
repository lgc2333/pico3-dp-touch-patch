"""Fetch three.js r169 into `web/three.module.js` and verify its SHA-256.

Usage:
  uv run python get_three.py

The download goes through the proxy from `HTTP(S)_PROXY` when that variable is
set.  The page imports the file directly, so it must sit next to `app.js`.
"""

import hashlib
import os
import sys
import urllib.request

URL = "https://unpkg.com/three@0.169.0/build/three.module.js"
SHA256 = "0a3368c165eea773490aec7b77c22de70e3eac288503409256fdbf4d12578416"
HERE = os.path.dirname(os.path.abspath(__file__))
DEST = os.path.join(HERE, "web", "three.module.js")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    if os.path.exists(DEST):
        with open(DEST, "rb") as f:
            if digest(f.read()) == SHA256:
                print("[=] web/three.module.js already present")
                return 0
            print("[!] web/three.module.js hash mismatch, downloading again")
    print(" [i] downloading three.js r169 (about 1.3 MB)")
    try:
        with urllib.request.urlopen(URL, timeout=60) as r:
            data = r.read()
    except OSError as e:
        print(f"[X] download failed: {e}")
        return 1
    if digest(data) != SHA256:
        print("[X] SHA-256 mismatch, nothing written")
        return 1
    os.makedirs(os.path.dirname(DEST), exist_ok=True)
    with open(DEST, "wb") as f:
        f.write(data)
    print("[+] web/three.module.js ready")
    return 0


if __name__ == "__main__":
    sys.exit(main())
