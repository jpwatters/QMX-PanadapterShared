#!/usr/bin/env python3
"""Fetch python-libusb1 3.4.0 (pure Python) from PyPI into ./lib if it isn't
there yet. The download is checked against its published SHA-256, so the
result is the exact file PyPI lists, even if TLS verification has to fall
back on a NAS without a CA bundle."""
import hashlib, io, os, ssl, sys, urllib.request, zipfile

URL = ("https://files.pythonhosted.org/packages/d4/64/d4b59444e4d3b6979aa5eb58840634465a24b41a9ab03dcf8434c9b89551/"
       "libusb1-3.4.0-py3-none-any.whl")
SHA256 = "e83d034e44c3efe1c4599c6281d34bca50a38c12cab3b7b6217d583161a01ffd"
LIB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib")

if os.path.isfile(os.path.join(LIB, "usb1", "__init__.py")):
    print("libusb1: already present in", LIB)
    sys.exit(0)
try:
    data = urllib.request.urlopen(URL, timeout=60).read()
except ssl.SSLError as e:
    print("libusb1: TLS verification failed (%s); retrying unverified - the SHA-256 check still applies" % e)
    data = urllib.request.urlopen(URL, timeout=60, context=ssl._create_unverified_context()).read()
except Exception as e:
    if "CERTIFICATE_VERIFY_FAILED" not in str(e):
        raise
    print("libusb1: TLS verification failed; retrying unverified - the SHA-256 check still applies")
    data = urllib.request.urlopen(URL, timeout=60, context=ssl._create_unverified_context()).read()
digest = hashlib.sha256(data).hexdigest()
if digest != SHA256:
    sys.exit("libusb1: SHA-256 mismatch (%s) - not installed" % digest)
with zipfile.ZipFile(io.BytesIO(data)) as z:
    for n in z.namelist():
        if n.startswith("usb1/") or n == "libusb1.py" or "/licenses/" in n:
            target = os.path.join(LIB, "usb1", os.path.basename(n)) if "/licenses/" in n else os.path.join(LIB, n)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, "wb") as f:
                f.write(z.read(n))
print("libusb1: installed 3.4.0 into", LIB)
