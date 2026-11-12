#!/usr/bin/env python3
"""build_pdf.py - write M5StackTab5QMX+SharedOverNetwork.pdf, the project PDF.

    python3 tools/nas-kit/doc/build_pdf.py ~/src/QMX-Panadapter-NAS [out.pdf]

Inputs, all read from the folder named on the command line:
  * tools/nas-kit/doc/project.md  - the prose (this script's own folder)
  * .qmx-nas-build                - the upstream release the folder was built on
  * git history since that release - the change history table
  * the current files             - the listings (new files in full, changed
                                    upstream files as diffs against the release)

So the version, the patch table and the listings always describe the folder the
PDF is built from. Needs python3 with reportlab (pip install reportlab) and the
DejaVu fonts (Linux: fonts-dejavu; macOS: reportlab's own Vera is used if
DejaVu is missing).

project.md markup: "# N. Title" section, "## " subsection, "### " heading,
"- " bullet, "-- " sub-bullet, "!small " small print, "|~ w | w" column widths
in inches followed by "| a | b" table rows (first row = header), ``` code,
**bold**, `code`, {BASE} {NAS} {SERIES} {DATE} {PORT_STATUS} {TAB5_STATUS},
and {{TOC}} {{PATCH_TABLE}} {{SOURCES}} {{LISTINGS}} {{PAGEBREAK}}.
"""
import datetime
import os
import re
import subprocess
import sys

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER
from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import inch
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (BaseDocTemplate, Flowable, Frame, PageBreak, PageTemplate,
                                Paragraph, Preformatted, Spacer, Table, TableStyle, KeepTogether)
from reportlab.platypus.tableofcontents import TableOfContents

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "..", ".."))
OUT = sys.argv[2] if len(sys.argv) > 2 else os.path.join(REPO, "M5StackTab5QMX+SharedOverNetwork.pdf")

# ------------------------------------------------------------------ fonts
def _font(name, files):
    for d in ("/usr/share/fonts/truetype/dejavu", "/usr/share/fonts/dejavu", "/Library/Fonts",
              os.path.expanduser("~/Library/Fonts")):
        p = os.path.join(d, files)
        if os.path.exists(p):
            pdfmetrics.registerFont(TTFont(name, p))
            return True
    return False

if all(_font(n, f) for n, f in (("Sans", "DejaVuSans.ttf"), ("Sans-Bold", "DejaVuSans-Bold.ttf"),
                                ("Sans-It", "DejaVuSans-Oblique.ttf"), ("Mono", "DejaVuSansMono.ttf"),
                                ("Mono-Bold", "DejaVuSansMono-Bold.ttf"))):
    from reportlab.pdfbase.pdfmetrics import registerFontFamily
    registerFontFamily("Sans", normal="Sans", bold="Sans-Bold", italic="Sans-It", boldItalic="Sans-Bold")
else:                                     # no DejaVu: reportlab's bundled Vera
    import reportlab
    vd = os.path.join(os.path.dirname(reportlab.__file__), "fonts")
    for n, f in (("Sans", "Vera.ttf"), ("Sans-Bold", "VeraBd.ttf"), ("Sans-It", "VeraIt.ttf"),
                 ("Mono", "VeraMono.ttf") if os.path.exists(os.path.join(vd, "VeraMono.ttf")) else ("Mono", "Vera.ttf"),
                 ("Mono-Bold", "VeraBd.ttf")):
        pdfmetrics.registerFont(TTFont(n, os.path.join(vd, f)))

NAVY = colors.HexColor("#1F3864")
GREY = colors.HexColor("#555555")
ST = {
    "title": ParagraphStyle("title", fontName="Sans-Bold", fontSize=24, leading=30, textColor=NAVY, alignment=TA_CENTER),
    "subtitle": ParagraphStyle("subtitle", fontName="Sans", fontSize=11, leading=15, textColor=GREY, alignment=TA_CENTER),
    "h1": ParagraphStyle("h1", fontName="Sans-Bold", fontSize=16, leading=20, textColor=NAVY, spaceBefore=6, spaceAfter=6),
    "h2": ParagraphStyle("h2", fontName="Sans-Bold", fontSize=11.5, leading=15, textColor=NAVY, spaceBefore=8, spaceAfter=3),
    "h3": ParagraphStyle("h3", fontName="Sans-Bold", fontSize=10, leading=13, spaceBefore=6, spaceAfter=2),
    "body": ParagraphStyle("body", fontName="Sans", fontSize=9.2, leading=12.6, spaceAfter=5),
    "small": ParagraphStyle("small", fontName="Sans", fontSize=7.8, leading=10, textColor=colors.HexColor("#444444"), spaceAfter=5),
    "bullet": ParagraphStyle("bullet", fontName="Sans", fontSize=9.2, leading=12.6, leftIndent=14, bulletIndent=4, spaceAfter=3),
    "bullet2": ParagraphStyle("bullet2", fontName="Sans", fontSize=9.2, leading=12.6, leftIndent=30, bulletIndent=18, spaceAfter=2),
    "cell": ParagraphStyle("cell", fontName="Sans", fontSize=7.8, leading=9.6),
    "cellh": ParagraphStyle("cellh", fontName="Sans-Bold", fontSize=7.8, leading=9.6, textColor=colors.white),
    "code": ParagraphStyle("code", fontName="Mono", fontSize=7.4, leading=9.2, leftIndent=6, spaceAfter=6,
                           backColor=colors.HexColor("#F4F6F8")),
    "toc1": ParagraphStyle("toc1", fontName="Sans", fontSize=9.6, leading=14),
    "lhead": ParagraphStyle("lhead", fontName="Mono-Bold", fontSize=9, leading=12, textColor=NAVY, spaceBefore=8),
    "lsub": ParagraphStyle("lsub", fontName="Sans", fontSize=7.5, leading=10, textColor=GREY, spaceAfter=3),
}

# ------------------------------------------------------------------ repo facts
def git(*a):
    return subprocess.run(["git", "-C", REPO] + list(a), capture_output=True, text=True).stdout

def stamp(key):
    try:
        for line in open(os.path.join(REPO, ".qmx-nas-build")):
            if line.startswith(key + "="):
                return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return ""

BASE = stamp("base") or git("describe", "--tags", "--abbrev=0").strip()
BASEC = BASE + "^{commit}"
NAS = BASE + "-NAS"
EXCL = [":(exclude)tools/nas-kit"]
hist = [l for l in git("log", "--reverse", "--format=%ad|%s", "--date=short", BASEC + "..HEAD",
                       "--", ".", *EXCL).strip().splitlines() if l]
hist = [l for l in hist if not l.split("|", 1)[1].startswith("Version: ")]
NPATCH = len(hist)
SERIES = "0001-%04d" % NPATCH
DATE = datetime.date.today().strftime("%B %-d, %Y")

def tested_text():
    t = ""
    try:
        t = open(os.path.join(REPO, ".qmx-nas-tested")).read().strip()
    except OSError:
        pass
    return t

# How far each patch is tested (by number). Patches after the last entry: "-".
TESTED = {1: "Hardware", 2: "Hardware", 3: "Hardware", 4: "Hardware", 5: "Hardware", 6: "Hardware",
          7: "Kit tests", 8: "Hardware", 9: "Hardware", 10: "Bench only", 11: "Not on a Pi yet", 12: "Build",
          14: "Hardware", 15: "Hardware", 16: "Hardware", 17: "Hardware", 18: "Hardware", 21: "Marked tested",
          27: "Bench (fake radio)", 28: "Bench (fake radio)", 29: "Bench (fake radio)", 38: "Browser",
          39: "Reproduced on radio", 40: "Build; base detected", 42: "Hardware"}

PORT_STATUS = open(os.path.join(HERE, "port-status.txt")).read().strip().replace("{BASE}", BASE).replace("{NAS}", NAS) \
    if os.path.exists(os.path.join(HERE, "port-status.txt")) else ""
TAB5_STATUS = open(os.path.join(HERE, "tab5-status.txt")).read().strip().replace("{BASE}", BASE).replace("{NAS}", NAS) \
    if os.path.exists(os.path.join(HERE, "tab5-status.txt")) else "See the README's port status."

def subst(s):
    return (s.replace("{BASE}", BASE).replace("{NAS}", NAS).replace("{SERIES}", SERIES)
             .replace("{DATE}", DATE).replace("{PORT_STATUS}", PORT_STATUS).replace("{TAB5_STATUS}", TAB5_STATUS))

def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

def inline(s):
    s = esc(subst(s))
    s = re.sub(r"`([^`]+)`", r'<font name="Mono">\1</font>', s)
    s = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", s)
    return s

# ------------------------------------------------------------------ flowables
class Doc(BaseDocTemplate):
    def __init__(self, fn):
        super().__init__(fn, pagesize=letter, leftMargin=0.7 * inch, rightMargin=0.7 * inch,
                         topMargin=0.75 * inch, bottomMargin=0.65 * inch,
                         title="M5Stack Tab5 QMX+ Shared Over Network", author="J P Watters (KC9KKO)")
        f = Frame(self.leftMargin, self.bottomMargin, self.width, self.height, id="f")
        self.addPageTemplates([PageTemplate(id="p", frames=[f], onPage=self.deco)])

    def deco(self, c, d):
        if d.page == 1:
            return
        c.saveState()
        c.setFont("Sans", 7.5)
        c.setFillColor(GREY)
        c.drawString(self.leftMargin, letter[1] - 0.48 * inch, "M5Stack Tab5 QMX+ Shared Over Network")
        c.drawRightString(letter[0] - self.rightMargin, letter[1] - 0.48 * inch,
                          "Upstream %s + NAS patches %s" % (BASE, SERIES))
        c.drawRightString(letter[0] - self.rightMargin, 0.4 * inch, "Page %d" % d.page)
        c.restoreState()

    def afterFlowable(self, fl):
        if getattr(fl, "_toc", None):
            key = "h%d" % id(fl)
            self.canv.bookmarkPage(key)
            self.canv.addOutlineEntry(fl._toc, key, level=0)
            self.notify("TOCEntry", (0, fl._toc, self.page, key))


def H1(text):
    p = Paragraph(esc(text), ST["h1"])
    p._toc = text
    return p


def table(rows, widths, font=7.8, header=True, stripe=True, mark=None):
    cs = ParagraphStyle("c", parent=ST["cell"], fontSize=font, leading=font * 1.23)
    ch = ParagraphStyle("ch", parent=ST["cellh"], fontSize=font, leading=font * 1.23)
    data = [[Paragraph(inline(c) if isinstance(c, str) else c, ch if (header and i == 0) else cs) for c in r]
            for i, r in enumerate(rows)]
    t = Table(data, colWidths=[w * inch for w in widths], repeatRows=1 if header else 0)
    sty = [("GRID", (0, 0), (-1, -1), 0.4, colors.HexColor("#B4BCC8")),
           ("VALIGN", (0, 0), (-1, -1), "TOP"),
           ("LEFTPADDING", (0, 0), (-1, -1), 3), ("RIGHTPADDING", (0, 0), (-1, -1), 3),
           ("TOPPADDING", (0, 0), (-1, -1), 2), ("BOTTOMPADDING", (0, 0), (-1, -1), 2)]
    if header:
        sty.append(("BACKGROUND", (0, 0), (-1, 0), NAVY))
    if stripe:
        for r in range(1 if header else 0, len(rows)):
            if r % 2 == 0:
                sty.append(("BACKGROUND", (0, r), (-1, r), colors.HexColor("#F2F4F8")))
    for r, row in enumerate(rows):
        if mark and any(isinstance(c, str) and c.strip() == mark for c in row):
            sty.append(("BACKGROUND", (0, r), (-1, r), colors.HexColor("#F8CBAD")))
    t.setStyle(TableStyle(sty))
    return t


class Code(Flowable):
    """Monospaced lines, wrapped with a mark, diff lines coloured; splits over pages."""
    LH = 8.0
    FS = 6.6

    def __init__(self, lines, width_chars=128, diff=False):
        super().__init__()
        self.diff = diff
        out = []
        for ln in lines:
            ln = ln.replace("\t", "    ").rstrip("\n")
            first = True
            while True:
                if len(ln) <= width_chars:
                    out.append((ln, first))
                    break
                out.append((ln[:width_chars], first))
                ln = "↪ " + ln[width_chars:]
                first = False
        self.lines = out or [("", True)]

    def wrap(self, aw, ah):
        self.aw = aw
        return aw, len(self.lines) * self.LH + 4

    def split(self, aw, ah):
        n = int((ah - 4) // self.LH)
        if n < 3 or n >= len(self.lines):
            return []
        a = Code([], diff=self.diff); a.lines = self.lines[:n]
        b = Code([], diff=self.diff); b.lines = self.lines[n:]
        return [a, b]

    def draw(self):
        c = self.canv
        h = len(self.lines) * self.LH + 4
        c.setFillColor(colors.HexColor("#F7F8FA"))
        c.rect(0, 0, self.aw, h, stroke=0, fill=1)
        y = h - self.LH
        cur = None
        for text, first in self.lines:
            col = colors.black
            if self.diff:
                if first:
                    cur = text[:1]
                k = cur
                if k == "+":
                    col = colors.HexColor("#1A6B1A")
                elif k == "-":
                    col = colors.HexColor("#A01818")
                elif k == "@":
                    col = colors.HexColor("#1F3864")
            c.setFillColor(col)
            c.setFont("Mono", self.FS)
            c.drawString(3, y + 1.5, text)
            y -= self.LH

# ------------------------------------------------------------------ generated parts
def patch_table():
    rows = [["#", "Date", "Change", "Tested"]]
    for i, l in enumerate(hist, 1):
        d, s = l.split("|", 1)
        s = re.sub(r"^README: v1\.\d+\.\d+-NAS version", "README: version", s)
        rows.append(["%04d" % i, d, s, TESTED.get(i, "-")])
    return [table(rows, [0.45, 0.8, 4.65, 1.2], font=7.4)]


SOURCES = [
    ("Upstream firmware: SteffenLav/qmx-panadapter {BASE}", "https://github.com/SteffenLav/qmx-panadapter (tag {BASE})",
     "Base for the port. cat.c, audio.c, qmx_term.c, ft8_tx.c, webserver.c, ui.c, settings, config_io, main.c, www/index.html, "
     "CMake files and the QMX USB descriptor notes were read and changed. Each release's changes that stopped the patches are in section 9. Verified."),
    ("QMX second and third serial ports", "Upstream main/qmx_term.h and cat.c (cat_probe_extra_cdc_ports)",
     "Second CDC function at interface 5 when USB serial ports = 2; CAT stays on interface 0; terminal entered with a bare CR. "
     "Verified in code (measurements by the upstream authors)."),
    ("QRP Labs QMX / QMX+ operating and CAT manuals", "https://qrp-labs.com/qmx",
     "USB serial ports setting; CAT commands TX;, RX;, TA (tone frequency; a value below 10 Hz keys up), PC; and SW; (power and SWR), "
     "PS0; (power off), Q9 (IQ mode). Referenced via the upstream code and used on the radio."),
    ("FT8 and FT4 protocol", "S. Franke, B. Somerville, J. Taylor, \"The FT4 and FT8 Communication Protocols\", QEX, July/August 2020; "
     "WSJT-X source and user guide, https://wsjt.sourceforge.io",
     "79 symbols of 160 ms (FT8), 105 of 48 ms (FT4), 8-FSK at 6.25 Hz, 77+14 bits, LDPC(174,91), Costas arrays at symbols 0-6, "
     "36-42, 72-78. Background knowledge; burst length confirmed by the relay's transmit log."),
    ("ft8_lib (FT8/FT4 encoder used by the firmware)", "https://github.com/kgoba/ft8_lib (vendored in components/ft8_lib)",
     "Symbol counts and tone spacing constants (FT8_NN, FT4_NN, symbol periods) used for scheduling. Verified in code."),
    ("Espressif ESP-IDF v5.4.4", "https://github.com/espressif/esp-idf (tag v5.4.4)",
     "Toolchain and headers for ESP32-P4; FreeRTOS, esp_timer, heap_caps, lwIP sockets, esp_eth and the W5500 SPI driver, "
     "esp_netif route priorities. Used to build every port. Verified."),
    ("Espressif esp_hosted (ESP-Hosted-MCU) host driver", "https://github.com/espressif/esp-hosted-mcu (host/drivers/transport/sdio)",
     "SDIO receive path the Wi-Fi patches change (bundled frames, per-frame copy, mempool). Verified (read, compiled, tested on the Tab5)."),
    ("lwIP TCP receive window and thread model", "lwIP / ESP-IDF lwipopts.h; ESP-IDF networking guide",
     "TCP_WND sizing for the stream; sockets must not be used from the tcpip thread. Verified on the Tab5."),
    ("Espressif esp-usb, esp-bsp, esp-dsp; LVGL; chmorgan/esp-libhelix-mp3",
     "https://github.com/espressif/esp-usb ; esp-bsp ; esp-dsp ; https://github.com/lvgl/lvgl ; https://github.com/chmorgan/esp-libhelix-mp3",
     "CDC-ACM host API, LVGL port, touch, DSP and MP3 decoder headers needed to compile the firmware. Verified."),
    ("M5Stack Tab5 and W5500 PoE base documentation", "https://docs.m5stack.com/en/core/Tab5 ; https://docs.m5stack.com/en/base/w5500PoE",
     "M5-Bus pin numbers and Tab5 GPIOs for the W5500 (MOSI G18, MISO G19, SCK G5, CS G52, INT G51, RST G48); the M5-Bus 5 V as an "
     "output. Verified against both documents."),
    ("Linux usbfs ioctl interface", "Linux include/uapi/linux/usbdevice_fs.h; Documentation/driver-api/usb/usb.rst",
     "SUBMITURB / REAPURBNDELAY / DISCARDURB, CONTROL, SETINTERFACE, CLAIM/RELEASEINTERFACE, DISCONNECT/CONNECT; struct layouts on "
     "32-bit ARM (verified on the DS416j, kernel 3.10.108) and aarch64 headers (Pi)."),
    ("Linux IP_PKTINFO and policy routing", "ip(7) IP_PKTINFO; ip-rule(8), ip-route(8)",
     "The relay's discovery answers from the interface a query arrived on (ipi_ifindex, SIOCGIFADDR) so DSM's rule \"from 10.0.0.137 "
     "lookup eth0-table\" applies. Verified on the DS416j with its VPN client connected (2026-10-31)."),
    ("USB CDC PSTN and USB Audio Class 1.0", "USB-IF Class Definitions for Communications Devices 1.2; Audio Devices 1.0",
     "SET_LINE_CODING / SET_CONTROL_LINE_STATE on each serial port; Format Type I parsing and the 48 kHz SET_CUR request. Background knowledge."),
    ("libusb-1.0 and python-libusb1", "https://libusb.info ; https://pypi.org/project/libusb1/",
     "Alternative relay backend where libusb exists. Verified against a mock device; not present on the DS416j."),
    ("Synology DSM 7.4: Task Scheduler, File Station, Network", "https://www.synology.com ; DSM Control Panel",
     "Root boot-up task for the relay, the check task, file deployment and log retrieval; the VPN client interface. Verified on the NAS."),
    ("Raspberry Pi OS and systemd", "https://www.raspberrypi.com/documentation ; systemd.service(5), systemd.timer(5), systemd.exec(5)",
     "OnBootSec timer, Restart=on-failure with StartLimitBurst, OnFailure hooks, sandboxing options. Background knowledge."),
    ("udev, ModemManager and PipeWire device rules", "udev(7); ModemManager ID_MM_DEVICE_IGNORE; PipeWire/PulseAudio device properties",
     "Keeping other services away from the QMX on the Pi. Background knowledge."),
    ("Python 3 standard library", "https://docs.python.org/3/ (socket, struct, threading, ctypes, fcntl)",
     "The relay, network test, serial bridge, tx_compare and this document's builder. Verified by running them."),
    ("Git: format-patch, am --3way, rebase", "https://git-scm.com/docs",
     "Exporting the patch series and re-applying it to each new upstream release. Verified by the kit."),
    ("TCI (Transceiver Control Interface), Expert Electronics", "https://eesdr.com (TCI protocol); WSJT-X 3 Transceiver/TCITransceiver.cpp",
     "Text commands (vfo, modulation, trx, audio_start ...) and binary frames as the WSJT-X/WS client uses them. Read; bench-tested."),
    ("RFC 6455, The WebSocket Protocol", "https://www.rfc-editor.org/rfc/rfc6455",
     "Handshake and framing of the TCI server (text, binary, ping/pong, close). Verified by the bench test."),
    ("Project measurements, 2026-10-14", "Relay txlog-2026-10-14.log (NAS) and the Tab5 log from http://qmx.local/api/log",
     "All figures in the FT8 burst timing comparisons. Verified."),
]


def sources():
    out = []
    for i, (t, loc, use) in enumerate(SOURCES, 1):
        out.append(KeepTogether([
            Paragraph("<b>[%d] %s</b>" % (i, inline(t)), ST["body"]),
            Paragraph("<i>Location:</i> " + inline(loc), ST["small"]),
            Paragraph("<i>Used for:</i> " + inline(use), ST["small"]),
        ]))
    return out


DRIVER = ["main/net/radio_relay.h", "main/net/radio_relay.c", "main/cat/cat.h", "main/cat/cat.c",
          "main/audio/audio.h", "main/audio/audio.c", "main/wifi/wifi.h", "main/wifi/wifi.c", "main/qmx_term.c",
          "main/net/eth_w5500.h", "main/net/eth_w5500.c", "sdkconfig.defaults", "sdkconfig",
          "tools/patches/apply_esp_hosted_sdio_split_bundles.ps1", "tools/patches/apply_esp_hosted_sdio_rx_copy_psram.ps1",
          "tools/patches/apply_esp_hosted_sdio_split_psram.ps1", "tools/patches/apply_cdc_acm_close_tolerant.ps1",
          "tools/patches/apply_fatfs_dma_aligned_alloc.ps1", "tools/patches/apply_httpd_ws_dead_socket_close.ps1",
          "tools/check_patches.py", "main/idf_component.yml", "main/CMakeLists.txt", "CMakeLists.txt"]
GROUPS = [("Tab5 firmware application", lambda p: p.startswith("main/")),
          ("Synology relay: code, installation, operation and maintenance scripts", lambda p: p.startswith("tools/nas-relay/")),
          ("Raspberry Pi relay: installation, operation and maintenance scripts", lambda p: p.startswith("tools/pi-relay/")),
          ("Mac tools", lambda p: p.startswith("tools/mac-")),
          ("Timing-test tools", lambda p: p.startswith("tools/tx-test/")),
          ("Other", lambda p: True)]
SKIP = re.compile(r"(\.md|\.pdf|\.png|\.jpg|\.bin|\.gz|\.xlsx|\.wasm)$|^docs/|^\.qmx")


def changed_files():
    out = {}
    for l in git("diff", "--name-status", "--no-renames", BASEC, "HEAD", "--", ".", *EXCL).splitlines():
        st, p = l.split("\t", 1)
        if st != "D" and not SKIP.search(p):
            out[p] = st
    return out


def listing(path, status):
    fl = []
    full = os.path.join(REPO, path)
    if status == "A":
        try:
            lines = open(full, encoding="utf-8", errors="replace").read().splitlines()
        except OSError:
            return fl
        fl.append(Paragraph(esc(path), ST["lhead"]))
        fl.append(Paragraph("new file, %d lines" % len(lines), ST["lsub"]))
        fl.append(Code(lines))
    else:
        d = git("diff", "-U3", BASEC, "HEAD", "--", path).splitlines()
        body = [l for l in d if not l.startswith(("diff --git", "index ", "--- ", "+++ "))]
        if not body:
            return fl
        fl.append(Paragraph(esc(path), ST["lhead"]))
        fl.append(Paragraph("changes against upstream %s (unified diff)" % BASE, ST["lsub"]))
        fl.append(Code(body, diff=True))
    return fl


def listings(story):
    ch = changed_files()
    story.append(H1("13. Driver listings (Tab5 firmware)"))
    story.append(Paragraph("The network-radio driver is listed in full; changes to upstream driver files are unified diffs "
                           "against tag %s. Long lines are wrapped (↪). Identical in ~/src/QMX-Panadapter-NAS and the kit." % BASE,
                           ST["small"]))
    done = set()
    for p in DRIVER:
        if p in ch:
            story += listing(p, ch[p]); done.add(p)
    story.append(PageBreak())
    story.append(H1("14. Application listings"))
    story.append(Paragraph("Tab5 application changes (diffs against %s), then the Synology relay and its scripts, the Raspberry Pi "
                           "scripts, the Mac tools, the timing-test tools and the update kit, in full." % BASE, ST["small"]))
    rest = sorted(p for p in ch if p not in done)
    for title, test in GROUPS:
        ps = [p for p in rest if test(p) and p not in done]
        if not ps:
            continue
        story.append(Paragraph(title, ST["h2"]))
        for p in ps:
            story += listing(p, ch[p]); done.add(p)
    story.append(Paragraph("Update kit", ST["h2"]))
    for p in ("tools/nas-kit/make-qmx-panadapter-nas.sh", "tools/nas-kit/push-to-github.sh", "tools/nas-kit/doc/build_pdf.py"):
        if os.path.exists(os.path.join(REPO, p)):
            story += listing(p, "A")

# ------------------------------------------------------------------ project.md
def render(md):
    story = []
    lines = open(md, encoding="utf-8").read().splitlines()
    i = 0
    para = []
    widths = None
    trows = []

    def flush_para():
        if para:
            story.append(Paragraph(inline(" ".join(para)), ST["body"]))
            para.clear()

    def flush_table():
        nonlocal widths
        if trows:
            ws = widths or [7.0 / len(trows[0])] * len(trows[0])
            ncol = len(ws)
            rows = [(r + [""] * ncol)[:ncol] for r in trows]
            story.append(table(rows, ws, font=7.2 if ncol > 6 else 7.8, mark="STALL"))
            story.append(Spacer(1, 6))
            trows.clear()
        widths = None

    title = subtitle = ""
    while i < len(lines):
        ln = lines[i]
        s = ln.strip()
        if s.startswith("```"):
            flush_para(); flush_table()
            code = []
            i += 1
            while i < len(lines) and not lines[i].strip().startswith("```"):
                code.append(lines[i]); i += 1
            story.append(Preformatted(subst("\n".join(code)), ST["code"]))
            i += 1
            continue
        if s.startswith("|~"):
            flush_para(); flush_table()
            widths = [float(x) for x in s[2:].split("|")]
        elif s.startswith("|"):
            flush_para()
            trows.append([c.strip() for c in s[1:].split("|")])
        else:
            flush_table()
            if not s:
                flush_para()
            elif s.startswith("@title "):
                title = s[7:]
            elif s.startswith("@subtitle "):
                subtitle = s[10:]
                story += [Spacer(1, 1.3 * inch), Paragraph(esc(title), ST["title"]), Spacer(1, 10),
                          Paragraph(esc(subtitle), ST["subtitle"]), Spacer(1, 26)]
            elif s.startswith("@appendix "):
                flush_para(); story.append(H1(s[10:]))
            elif s == "{{TOC}}":
                toc = TableOfContents()
                toc.levelStyles = [ST["toc1"]]
                story += [PageBreak(), Paragraph("Contents", ST["h2"]), toc, PageBreak()]
            elif s == "{{PAGEBREAK}}":
                flush_para(); story.append(PageBreak())
            elif s == "{{PATCH_TABLE}}":
                story += patch_table()
            elif s == "{{SOURCES}}":
                story += sources()
            elif s == "{{LISTINGS}}":
                listings(story)
            elif s.startswith("# "):
                flush_para(); story.append(H1(s[2:]))
            elif s.startswith("## "):
                flush_para(); story.append(Paragraph(inline(s[3:]), ST["h2"]))
            elif s.startswith("### "):
                flush_para(); story.append(Paragraph(inline(s[4:]), ST["h3"]))
            elif s.startswith("-- "):
                flush_para(); story.append(Paragraph(inline(s[3:]), ST["bullet2"], bulletText="–"))
            elif s.startswith("- "):
                flush_para(); story.append(Paragraph(inline(s[2:]), ST["bullet"], bulletText="•"))
            elif s.startswith("!small "):
                flush_para(); story.append(Paragraph(inline(s[7:]), ST["small"]))
            else:
                para.append(s)
        i += 1
    flush_para(); flush_table()
    return story


story = render(os.path.join(HERE, "project.md"))
doc = Doc(OUT)
doc.multiBuild(story)
print("wrote %s: %d pages, %s + NAS patches %s" % (OUT, doc.page, BASE, SERIES))
