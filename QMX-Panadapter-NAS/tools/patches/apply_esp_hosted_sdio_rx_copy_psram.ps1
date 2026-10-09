<#
.SYNOPSIS
    esp_hosted SDIO RX: copy each received WiFi frame into PSRAM instead of
    internal RAM, and drop a frame instead of asserting when no memory is
    left. Marker: QMX_SDIO_RX_COPY_PSRAM.

.DESCRIPTION
    sdio_process_rx_task() copies every received frame into a fresh buffer
    that lwIP then holds (zero-copy, L2_TO_L3_COPY off) until TCP has handed
    the data to the application. Stock code used _h_malloc -> malloc, and with
    CONFIG_SPIRAM_MALLOC_ALWAYSINTERNAL=16384 every frame-sized malloc lands in
    INTERNAL RAM, so internal RAM in use grows with the data in flight.

    Measured 2026-10-04 with the NAS radio relay's sustained 1.5 Mbit/s stream:
    TCP window 11520 -> internal low-water 3 KB and DMA-capable free 4 KB;
    touch input (I2C) stopped and the web server stopped answering until a
    reboot. Window 5760 -> the same. Window 2880 -> usable, but only 66% of
    the stream arrives.

    The copy now goes to PSRAM (it is released with free(), which handles
    either heap), falling back to the stock allocation only if PSRAM is
    exhausted. Stock also assert()ed when the allocation failed; the frame is
    now dropped (TCP retransmits) instead of rebooting the device.

    Edits managed_components/ - wiped by fullclean or a dependency refresh;
    re-run like the other apply_*.ps1 patches. Idempotent.

.HOW TO USE
    powershell -ExecutionPolicy Bypass -File tools/patches/apply_esp_hosted_sdio_rx_copy_psram.ps1
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

if ($content.Contains("QMX_SDIO_RX_COPY_PSRAM")) {
    Write-Host "Already patched (SDIO RX copy in PSRAM) - nothing to do." -ForegroundColor Green
    exit 0
}

$old = @'
				/* TODO : Need to abstract heap_caps_malloc */
				uint8_t * copy_payload = (uint8_t *)g_h.funcs->_h_malloc(buf_handle->payload_len);
				assert(copy_payload);
				assert(buf_handle->payload_len);
				assert(buf_handle->payload);
				memcpy(copy_payload, buf_handle->payload, buf_handle->payload_len);
'@
$new = @'
				/* QMX_SDIO_RX_COPY_PSRAM (qmx-panadapter network-radio, 2026-10-04).
				 *
				 * Every received WiFi frame is copied into a fresh buffer that
				 * lwIP holds (zero-copy, L2_TO_L3_COPY off) until TCP has
				 * delivered it to the application. Stock code used _h_malloc ->
				 * malloc, and with CONFIG_SPIRAM_MALLOC_ALWAYSINTERNAL=16384 every
				 * frame-sized malloc lands in INTERNAL RAM - so internal RAM in
				 * use grows with the data in flight. Measured with the NAS radio
				 * relay's 1.5 Mbit/s stream: TCP window 11520 -> internal low-water
				 * 3 KB, DMA free 4 KB, touch input (I2C) dead and the web server
				 * unresponsive until reboot; window 2880 -> usable but only 66% of
				 * the stream. The copy goes to PSRAM instead (freed with free(),
				 * which handles either heap); internal RAM only if PSRAM is full.
				 * Stock also assert()ed on allocation failure - now the frame is
				 * dropped (TCP retransmits) instead of rebooting the device. */
				uint8_t * copy_payload = (uint8_t *)heap_caps_malloc(buf_handle->payload_len,
						MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
				if (!copy_payload)
					copy_payload = (uint8_t *)g_h.funcs->_h_malloc(buf_handle->payload_len);
				if (!copy_payload || !buf_handle->payload_len || !buf_handle->payload) {
					if (copy_payload)
						HOSTED_FREE(copy_payload);
					H_FREE_PTR_WITH_FUNC(buf_handle->free_buf_handle, buf_handle->priv_buffer_handle);
					continue;
				}
				memcpy(copy_payload, buf_handle->payload, buf_handle->payload_len);
'@
$old = $old -replace "`r`n", "`n"
$new = $new -replace "`r`n", "`n"
$n = ([regex]::Matches($content, [regex]::Escape($old))).Count
if ($n -ne 1) {
    Write-Host "Anchor found $n times (expected 1) - esp_hosted changed; patch by hand and update this script." -ForegroundColor Red
    exit 1
}
$content = $content.Replace($old, $new)

[System.IO.File]::WriteAllText($target, $content, (New-Object System.Text.UTF8Encoding $false))
Write-Host "Patched sdio_drv.c: received WiFi frames are copied into PSRAM, not internal RAM." -ForegroundColor Green
Write-Host "  $target"
