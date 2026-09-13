# Licensing

Stanbot's firmware is licensed under the GNU Affero General Public License,
version 3 or later (AGPL-3.0-or-later).

The animated-eye integration is a StackChan/M5GFX port companion based on
[playfultechnology/esp32-eyes](https://github.com/playfultechnology/esp32-eyes),
whose source is included as the `firmware/third_party/esp32-eyes` submodule.
The upstream repository's individual source notices credit Alastair Aitchison
and Luis Llamas and state AGPL-3.0-or-later; those notices govern the ported
work. The upstream root license file says GPL-3.0, so the more restrictive
per-file AGPL notices are used here.

The upstream source is retained for attribution and review; Stanbot's renderer
uses M5GFX rather than the upstream project's U8g2 OLED target.
