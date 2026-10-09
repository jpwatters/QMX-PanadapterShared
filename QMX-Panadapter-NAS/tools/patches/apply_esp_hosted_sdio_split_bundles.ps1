<#
.SYNOPSIS
    esp_hosted SDIO RX: deliver every frame of a multi-frame read instead of
    keeping only the first (normal reads) or discarding all of them (oversize
    bursts). Marker: QMX_SDIO_RX_SPLIT.

.DESCRIPTION
    The Tab5's ESP32-C6 runs its SDIO send path in STREAMING mode: when several
    frames are waiting it exposes them back to back, each with its own
    esp_payload_header, and the pending-length register covers all of them.
    This host is built for PACKET mode (RX_NONE + 1536-byte mempool buffers,
    v0.18.2), so the stock read path only ever looked at the first frame:

      - a normal read holding two small frames lost the second one;
      - a burst larger than 1536 bytes was drained and DISCARDED by the
        oversize recovery (apply_esp_hosted_sdio_recovery.ps1) - every frame
        in it lost.

    Invisible under light traffic, fatal for a sustained inbound stream:
    measured 2026-10-04 with the NAS radio relay (1.5 Mbit/s of I/Q) the
    oversize drain fired several times a second, TCP retransmitted the lost
    frames, the stream collapsed to 10-20k of 48k pairs/s and the Tab5 was
    too busy to take touch input until rebooted.

    The patch walks such a read, copies each frame into its own mempool buffer
    (no DMA allocation - the v0.18.2 rule stands) and queues it exactly like a
    single-frame read. The oversize drain keeps its chunked reads and its
    exact byte accounting unchanged; the drained bytes are also copied into a
    96 KB PSRAM buffer and split after the bus is released. A header that
    does not parse, or an empty mempool, ends the walk: frames already
    delivered stay delivered, the rest is dropped, nothing aborts. The
    "SDIO RX oversize" warning (the recovery patch's check_patches marker) is
    kept, rate-limited to one line per 5 s with the split counters.

    Requires apply_esp_hosted_sdio_recovery.ps1 first (its drain code is an
    anchor here) - this file name sorts after it.

    Edits managed_components/ - wiped by fullclean or a dependency refresh;
    re-run like the other apply_*.ps1 patches. Idempotent.

.HOW TO USE
    powershell -ExecutionPolicy Bypass -File tools/patches/apply_esp_hosted_sdio_split_bundles.ps1
#>

$ErrorActionPreference = "Stop"

$repo   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$target = Join-Path $repo "managed_components/espressif__esp_hosted/host/drivers/transport/sdio/sdio_drv.c"

if (-not (Test-Path $target)) {
    Write-Host "sdio_drv.c not found at:" -ForegroundColor Red
    Write-Host "  $target"
    Write-Host "Build once so the component is fetched, then re-run."
    exit 1
}

$content = (Get-Content -Raw -Path $target) -replace "`r`n", "`n"

if ($content.Contains("QMX_SDIO_RX_SPLIT")) {
    Write-Host "Already patched (SDIO RX split of multi-frame reads) - nothing to do." -ForegroundColor Green
    exit 0
}
if (-not $content.Contains("SDIO RX oversize")) {
    Write-Host "apply_esp_hosted_sdio_recovery.ps1 has not been applied yet - run it first." -ForegroundColor Red
    exit 1
}

$pairs = @(
    @{ Old = @'
	g_h.funcs->_h_queue_item(from_slave_queue[pkt_prio], &buf_handle, HOSTED_BLOCK_MAX);
	g_h.funcs->_h_post_semaphore(sem_from_slave_queue);

	return ESP_OK;
}

'@; New = @'
	g_h.funcs->_h_queue_item(from_slave_queue[pkt_prio], &buf_handle, HOSTED_BLOCK_MAX);
	g_h.funcs->_h_post_semaphore(sem_from_slave_queue);

	return ESP_OK;
}

/* QMX_SDIO_RX_SPLIT (qmx-panadapter network-radio, 2026-10-04).
 *
 * The C6 slave runs its SDIO send path in STREAMING mode: when several frames
 * are waiting it exposes them back to back, each starting with its own
 * esp_payload_header, and the pending-length register covers all of them.
 * This host is built for PACKET mode (RX_NONE, fixed 1536-byte mempool
 * buffers - chosen in v0.18.2 because streaming mode re-allocates DMA memory
 * per burst), so stock code only ever looked at the FIRST frame of a read:
 *
 *   - a read <= 1536 bytes holding two small frames (two TCP ACKs, an ACK
 *     plus a CAT reply) silently lost the second one;
 *   - a read > 1536 bytes (a burst of full-size frames) was drained and
 *     DISCARDED by the oversize recovery - every frame in it lost.
 *
 * Harmless for light traffic, fatal for a sustained inbound stream: measured
 * 2026-10-04 with the NAS radio relay (1.5 Mbit/s of I/Q) - "SDIO RX oversize
 * ... draining" several times a second, TCP retransmitting the lost frames and
 * the stream collapsing to 10-20 k of the 48 k pairs/s.
 *
 * This walks such a byte stream, copies each frame into its own mempool
 * buffer (no DMA allocation, the v0.18.2 rule stands) and queues it exactly
 * as a single-frame read would be. A header that does not parse, or an empty
 * mempool, ends the walk: what was already delivered stays delivered, the
 * rest is dropped, and nothing aborts. */
static uint32_t qmx_split_bundles, qmx_split_frames, qmx_split_drops;

static void qmx_sdio_push_stream(const uint8_t *s, uint32_t s_len)
{
	while (s_len >= sizeof(struct esp_payload_header)) {
		const struct esp_payload_header *h = (const struct esp_payload_header *)s;
		uint16_t len = le16toh(h->len);
		uint16_t offset = le16toh(h->offset);
		uint32_t psize = (uint32_t)len + offset;
		uint16_t vlen = 0, voff = 0;
		uint8_t *p;

		if (!len && !offset)
			return;                       /* block padding after the last frame */
		if (!len || len > MAX_PAYLOAD_SIZE ||
		    offset != sizeof(struct esp_payload_header) ||
		    psize > s_len || psize > MAX_SDIO_BUFFER_SIZE) {
			qmx_split_drops++;
			return;
		}
		p = sdio_buffer_alloc(MEMSET_REQUIRED);
		if (!p) {
			qmx_split_drops++;
			return;
		}
		memcpy(p, s, psize);
		if (!is_valid_sdio_rx_packet(p, &vlen, &voff)) {
			sdio_buffer_free(p);
			qmx_split_drops++;
			return;
		}
		sdio_push_pkt_to_queue(p, vlen, voff);
		qmx_split_frames++;
		s += psize;
		s_len -= psize;
	}
}

'@ }
    ,@{ Old = @'
	uint16_t len = 0;
	uint16_t offset = 0;

	/* Drop packet if no processing needed */
	if (!is_valid_sdio_rx_packet(buf, &len, &offset)) {
'@; New = @'
	uint16_t len = 0;
	uint16_t offset = 0;

	/* QMX_SDIO_RX_SPLIT: a read can hold more than one frame (see
	 * qmx_sdio_push_stream). Peek at the first header WITHOUT validating it
	 * (validation may rewrite it): if another frame follows, copy every frame
	 * out in order and release this buffer. */
	{
		const struct esp_payload_header *h0 = (const struct esp_payload_header *)buf;
		uint32_t first = (uint32_t)le16toh(h0->len) + le16toh(h0->offset);
		if (le16toh(h0->offset) == sizeof(struct esp_payload_header) &&
		    le16toh(h0->len) && first <= buf_len &&
		    buf_len - first >= sizeof(struct esp_payload_header)) {
			const struct esp_payload_header *h1 =
				(const struct esp_payload_header *)(buf + first);
			if (le16toh(h1->len) && le16toh(h1->offset) == sizeof(struct esp_payload_header)) {
				qmx_split_bundles++;
				qmx_sdio_push_stream(buf, buf_len);
				sdio_buffer_free(buf);
				return ESP_OK;
			}
		}
	}

	/* Drop packet if no processing needed */
	if (!is_valid_sdio_rx_packet(buf, &len, &offset)) {
'@ }
    ,@{ Old = @'
				if (sdio_oversize_drain_buf) {
					uint32_t d_left = len_from_slave;
'@; New = @'
				/* QMX_SDIO_RX_SPLIT: keep what is drained, in PSRAM (never DMA). */
				if (!qmx_split_stream)
					qmx_split_stream = (uint8_t *)heap_caps_malloc(
						64u * (uint32_t)ESP_RX_BUFFER_SIZE,
						MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
				if (sdio_oversize_drain_buf) {
					uint32_t d_left = len_from_slave;
'@ }
    ,@{ Old = @'
						d_left -= chunk;
						drained += chunk;
'@; New = @'
						if (qmx_split_stream)
							memcpy(qmx_split_stream + drained, sdio_oversize_drain_buf, chunk);
						d_left -= chunk;
						drained += chunk;
'@ }
    ,@{ Old = @'
			sdio_rx_byte_count = (sdio_rx_byte_count + drained) % ESP_RX_BYTE_MAX;
			SDIO_DRV_UNLOCK();
			if (!drained)
				g_h.funcs->_h_msleep(1);
			continue;
'@; New = @'
			sdio_rx_byte_count = (sdio_rx_byte_count + drained) % ESP_RX_BYTE_MAX;
			SDIO_DRV_UNLOCK();
			/* QMX_SDIO_RX_SPLIT: a complete drain is a burst of whole frames -
			 * deliver them instead of throwing them away. A partial drain (a
			 * read failed part-way) is still discarded: its tail is unknown. */
			if (qmx_split_stream && drained && drained == len_from_slave) {
				qmx_split_bundles++;
				qmx_sdio_push_stream(qmx_split_stream, drained);
			} else if (drained) {
				qmx_split_drops++;
			}
			if (!drained)
				g_h.funcs->_h_msleep(1);
			continue;
'@ }
    ,@{ Old = @'
			ESP_LOGW(TAG, "SDIO RX oversize: len=%lu host_cnt=%lu slave_reg=%lu - draining to recover",
					(unsigned long)len_from_slave, (unsigned long)sdio_rx_byte_count,
					(unsigned long)slave_reg);
'@; New = @'
			/* QMX_SDIO_RX_SPLIT: with the burst now delivered this is routine
			 * under a sustained stream, so report it at most every 5 s with
			 * running totals rather than per event (it was flooding the log
			 * several times a second). */
			{
				static int64_t qmx_last_oversize_log_us;
				static uint32_t qmx_oversize_since_log;
				int64_t now_us = esp_timer_get_time();
				qmx_oversize_since_log++;
				if (now_us - qmx_last_oversize_log_us >= 5000000LL) {
					ESP_LOGW(TAG, "SDIO RX oversize: len=%lu host_cnt=%lu slave_reg=%lu - "
							"draining (x%lu in 5 s); split: %lu bundles, %lu frames delivered, %lu dropped",
							(unsigned long)len_from_slave, (unsigned long)sdio_rx_byte_count,
							(unsigned long)slave_reg, (unsigned long)qmx_oversize_since_log,
							(unsigned long)qmx_split_bundles, (unsigned long)qmx_split_frames,
							(unsigned long)qmx_split_drops);
					qmx_last_oversize_log_us = now_us;
					qmx_oversize_since_log = 0;
				}
			}
'@ }
    ,@{ Old = @'
static uint8_t *sdio_oversize_drain_buf = NULL;

'@; New = @'
static uint8_t *sdio_oversize_drain_buf = NULL;
/* QMX_SDIO_RX_SPLIT: PSRAM copy of a drained burst, split into frames afterwards. */
static uint8_t *qmx_split_stream = NULL;

'@ }
)

foreach ($p in $pairs) {
    $old = $p.Old -replace "`r`n", "`n"
    $new = $p.New -replace "`r`n", "`n"
    $n = ([regex]::Matches($content, [regex]::Escape($old))).Count
    if ($n -ne 1) {
        Write-Host "Anchor found $n times (expected 1) - esp_hosted or the recovery patch changed; patch by hand and update this script:" -ForegroundColor Red
        Write-Host ($old.Substring(0, [Math]::Min(160, $old.Length)))
        exit 1
    }
    $content = $content.Replace($old, $new)
}

[System.IO.File]::WriteAllText($target, $content, (New-Object System.Text.UTF8Encoding $false))
Write-Host "Patched sdio_drv.c: multi-frame SDIO reads are split and delivered, not dropped." -ForegroundColor Green
Write-Host "  $target"
