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

## Montserrat (embedded fonts and text bitmaps)

`firmware/camera_stream/font_montserrat12.h` and `text_bitmaps.h` are generated
from **Montserrat Medium**, which is licensed under the
[SIL Open Font License 1.1](https://openfontlicense.org). The OFL permits
embedding in software, including for sale, and does not extend its terms to the
rest of this project. It does require that the font not be sold on its own and
that any derivative font not use the reserved name; neither applies here, since
these files are bitmap renderings used only to draw fixed strings.

Source: `Montserrat-Medium.ttf` from
[lvgl/lvgl](https://github.com/lvgl/lvgl/tree/release/v8.3/scripts/built_in_font),
the same file LVGL generates its built-in `lv_font_montserrat_*` fonts from.
That provenance is deliberate: the KeyPath HID fixture's boot screen uses those
LVGL fonts, and matching the source face is what makes the two devices' splash
screens identical rather than merely similar. Montserrat is by Julieta Ulanovsky
and contributors.

Regenerate with `tools/ttf_to_vlw.py` and `tools/prerender_text.py`; neither
generated header should be hand-edited. The TTF itself is not committed.

## Hacker Dojo mark

The splash reconstructs the Hacker Dojo logo from geometry, for a device shown
at Hacker Dojo. It is their mark, used to identify them, and is not covered by
this project's license.
