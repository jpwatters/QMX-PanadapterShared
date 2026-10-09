<#
.SYNOPSIS
    esp_hosted SDIO RX: frames split out of a multi-frame read go into PSRAM,
    not into the DMA mempool. Marker: QMX_SDIO_SPLIT_PSRAM.

.DESCRIPTION
    apply_esp_hosted_sdio_split_bundles.ps1 copies every frame of a bundled
    SDIO read into its own buffer from the SDIO mempool. That mempool NEVER
    gives memory back to the heap: a freed block goes onto its free list and
    stays there. So the pool grows to the largest number of frames ever in
    flight at once, in DMA-capable internal RAM, for the rest of the session.

    With the NAS radio's full-rate stream (~35 bundles/s, up to 7 frames
    each) that peak is 20-30 blocks of ~1.6 KB. Measured 2026-10-04: DMA free
    fell from 38 KB to 1.2 KB within ~20 s of the stream starting, internal
    free bottomed at 1 KB, the touch controller's I2C reads (and the PI4IO
    expander's) started timing out, SD reads failed - and the touchscreen
    stopped responding while the spectrum kept running.

    These frames are already copies; nothing DMAs into them. The patch takes
    them from PSRAM with heap_caps_malloc() and hands sdio_push_pkt_to_queue()
    heap_caps_free() as their free function, so they are really freed when the
    RX task is done with them. The single-frame path (the DMA read buffer
    itself) still uses the mempool, as before.

    STAGE 2 (marker QMX_SDIO_RXQ_PSRAM, added the same day): moving the split
    frames was not enough. A NORMAL single-frame read also parks its mempool
    block in the RX queue (depth 20) until sdio_process_rx_task gets to it, so
    under the stream the pool still grew to ~20 blocks - measured: DMA free
    691 B, touch still dead. So every received frame is now copied into PSRAM
    the moment it is queued and its mempool block goes straight back; the pool
    only ever holds the one or two blocks the SDIO read itself is using. Cost:
    one extra ~1.5 KB memcpy per frame (~1.5 MB/s at the full radio rate).
    If PSRAM is ever exhausted the frame is queued in its mempool block exactly
    as before. Stage 2 is applied on its own to a file that already has stage 1.

    Requires apply_esp_hosted_sdio_split_bundles.ps1 first - this file name
    sorts after it. Edits managed_components/; re-run like the other
    apply_*.ps1 patches. Idempotent.

.HOW TO USE
    pwsh -File tools/patches/apply_esp_hosted_sdio_split_psram.ps1
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

if ($content.Contains("QMX_SDIO_RXQ_PSRAM")) {
    Write-Host "Already patched (SDIO RX frames queued in PSRAM) - nothing to do." -ForegroundColor Green
    exit 0
}
if (-not $content.Contains("QMX_SDIO_RX_SPLIT")) {
    Write-Host "apply_esp_hosted_sdio_split_bundles.ps1 has not been applied yet - run it first." -ForegroundColor Red
    exit 1
}

$stage1 = @(
@{ Old = @'
	buf_handle.priv_buffer_handle = rxbuff;
	buf_handle.free_buf_handle    = sdio_buffer_free;
	buf_handle.payload_len        = len;
'@; New = @'
	buf_handle.priv_buffer_handle = rxbuff;
	/* QMX_SDIO_SPLIT_PSRAM: a frame split out of a bundle lives in PSRAM
	 * and is released with heap_caps_free, not back into the mempool. */
	buf_handle.free_buf_handle    = qmx_pkt_free ? qmx_pkt_free : sdio_buffer_free;
	buf_handle.payload_len        = len;
'@ },
@{ Old = @'
static esp_err_t sdio_push_pkt_to_queue(uint8_t * rxbuff, uint16_t len, uint16_t offset)
{
'@; New = @'
/* QMX_SDIO_SPLIT_PSRAM: set only around qmx_sdio_push_stream()'s pushes. */
static void (*qmx_pkt_free)(void *);

static esp_err_t sdio_push_pkt_to_queue(uint8_t * rxbuff, uint16_t len, uint16_t offset)
{
'@ },
@{ Old = @'
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
'@; New = @'
		/* QMX_SDIO_SPLIT_PSRAM: PSRAM, not the never-shrinking DMA mempool. */
		p = heap_caps_malloc(psize, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
		if (!p) {
			qmx_split_drops++;
			return;
		}
		memcpy(p, s, psize);
		if (!is_valid_sdio_rx_packet(p, &vlen, &voff)) {
			heap_caps_free(p);
			qmx_split_drops++;
			return;
		}
		qmx_pkt_free = heap_caps_free;
		sdio_push_pkt_to_queue(p, vlen, voff);
		qmx_pkt_free = NULL;
'@ }
)

# Stage 2 - anchors are stage 1's own output, so it always runs after it.
$stage2 = @(
@{ Old = @'
	buf_handle.free_buf_handle    = qmx_pkt_free ? qmx_pkt_free : sdio_buffer_free;
'@; New = @'
	buf_handle.free_buf_handle    = qmx_free ? qmx_free : sdio_buffer_free;
'@ },
@{ Old = @'
	interface_buffer_handle_t buf_handle;

	h = (struct esp_payload_header *)rxbuff;
'@; New = @'
	interface_buffer_handle_t buf_handle;
	/* QMX_SDIO_RXQ_PSRAM: queue a PSRAM copy and give the DMA mempool block
	 * back at once - the pool never returns memory to the heap, so blocks
	 * parked in the RX queue under a sustained stream ate all DMA RAM. */
	void (*qmx_free)(void *) = qmx_pkt_free;
	if (!qmx_free) {
		uint8_t *cp = heap_caps_malloc((size_t)offset + len, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
		if (cp) {
			memcpy(cp, rxbuff, (size_t)offset + len);
			sdio_buffer_free(rxbuff);
			rxbuff = cp;
			qmx_free = heap_caps_free;
		}
	}

	h = (struct esp_payload_header *)rxbuff;
'@ }
)

$pairs = @()
if (-not $content.Contains("QMX_SDIO_SPLIT_PSRAM")) { $pairs += $stage1 }
$pairs += $stage2

foreach ($p in $pairs) {
    $old = $p.Old -replace "`r`n", "`n"
    $new = $p.New -replace "`r`n", "`n"
    $n = ([regex]::Matches($content, [regex]::Escape($old))).Count
    if ($n -ne 1) {
        Write-Host "Anchor found $n times (expected 1) - esp_hosted or the split patch changed; patch by hand and update this script:" -ForegroundColor Red
        Write-Host ($old.Substring(0, [Math]::Min(160, $old.Length)))
        exit 1
    }
    $content = $content.Replace($old, $new)
}

[System.IO.File]::WriteAllText($target, $content, (New-Object System.Text.UTF8Encoding $false))
Write-Host "Patched sdio_drv.c: received SDIO frames are queued in PSRAM, not in the DMA mempool." -ForegroundColor Green
Write-Host "  $target"
