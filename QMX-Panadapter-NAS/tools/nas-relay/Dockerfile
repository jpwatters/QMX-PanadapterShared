# QMX network relay for a Synology NAS (Container Manager / Docker).
# Talks to the QMX with libusb in userspace - no DSM kernel drivers needed.
FROM python:3.12-alpine
RUN apk add --no-cache libusb \
 && pip install --no-cache-dir libusb1
COPY qmx_nas_relay.py /app/qmx_nas_relay.py
EXPOSE 7355
ENTRYPOINT ["python", "-u", "/app/qmx_nas_relay.py"]
