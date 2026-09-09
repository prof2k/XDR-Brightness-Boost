MIT-licensed m1ddc by waydabber.
Source: https://github.com/waydabber/m1ddc
Pinned commit: 04d949794102eb8df01ad3681afff6464a3eede2
Local fixes: include host address in Get VCP checksum; read uint16_t using its actual size; validate reply header/result/checksum/feature; use 50 ms DDC wait. Used only for explicitly targeted external luminance reads/writes.

Compatibility: use MACH_PORT_NULL for the default IOKit port so the helper does not require the macOS 12 kIOMainPortDefault symbol.
