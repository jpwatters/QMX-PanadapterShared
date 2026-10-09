# Shared settings for the QMX relay scripts (sourced, not run).
DIR="$(cd "$(dirname "$0")" && pwd)"
export PYTHONPATH="$DIR/lib"
PY=""
for c in python3 /usr/bin/python3 /bin/python3 /usr/local/bin/python3 \
         /var/packages/Python3.9/target/usr/bin/python3.9 /var/packages/Python3/target/usr/bin/python3; do
  if command -v "$c" >/dev/null 2>&1; then PY="$(command -v "$c")"; break; fi
done
# If libusb is not found automatically, set its full path here (or put
# libusb-1.0.so.0 into this folder):
if [ -z "$QMX_LIBUSB" ] && [ -f "$DIR/libusb-1.0.so.0" ]; then export QMX_LIBUSB="$DIR/libusb-1.0.so.0"; fi
