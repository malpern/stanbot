# EspNewJpeg

Espressif's `esp_new_jpeg` 1.0.2, vendored unmodified so the Arduino build can
link it. Only the ESP32-S3 static library and the encoder headers are kept; the
decoder header, other chips' libraries and the test app were dropped.

- Source: https://components-file.espressif.com/components/espressif/esp_new_jpeg/1.0.2/espressif__esp_new_jpeg-v1.0.2.zip
- Archive SHA-256: `8e2e3b728db2b21bdeb1d406a3e9eb8c63a23b2ea412c170f5ee765f5e03cacb`
- Every extracted file matched the registry's `CHECKSUMS.json` (2026-09-16).
- `src/esp32s3/libesp_new_jpeg.a` SHA-256: `2d08f7ed9e0e265173e2a651bf889190db8cc172fa2dff6ef63ffa8c73d24cd8`
- License: ESPRESSIF MIT (`LICENSE`), free for use on Espressif products.

To update, download the new version from the registry, verify it against its
`CHECKSUMS.json`, and replace these files together.
