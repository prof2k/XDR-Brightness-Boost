# Display-based XDR eligibility

Starting with 0.7.20, built-in boost eligibility does not inspect the Mac model, OS build number, or fixed panel dimensions. AppKit's `NSScreen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1` determines whether a built-in display advertises an extended range. Current headroom is deliberately not used: it can report 1 while HDR content is inactive, even on an XDR display.

The color engine no longer requires an AppleCLCD2 registry service. If exactly one suitable service exists, its registry identity remains compatible with existing recovery records. Otherwise, the engine uses the display UUID and boot identity. Registry metrics remain optional and isolated to the legacy driver tools; ambiguous registry services cannot receive driver writes.

Native brightness getter/setter availability and readback determine whether native brightness control is available. Optional private preset metadata can identify a current preset as SDR-limited or unable to accept user adjustments. The active HDR preset is no longer required to have index zero. Its original index is retained in a new color session so changing presets during boost releases that session. Older recovery records without this field still decode.

The helper reports native brightness availability separately from XDR capability. The main slider, brightness-key range, toggle, markers, and popup use that capability. Non-XDR built-in displays retain native 0–100% control. Without an internal panel, the helper stays alive for external software dimming and periodically retries native discovery. Capability is retained through temporarily unavailable readback during sleep. The external-display backend remains SDR-only.

This removes the artificial restrictions on eligible Liquid Retina XDR displays in M1 Pro/Max and later MacBook Pro models. It does not claim physical testing on every such model.

## Validation

- Full automated suite passed, including 17 capability/preset scenarios covering SDR, EDR, unavailable/invalid capabilities, absent optional metadata, future luminance values, and fixed reference presets.
- The independent external-display lifecycle test skipped because no independent external display was available.
- A read-only native probe identified the local XDR display as capable with an eligible preset.
- A live helper test verified 106.25% activation, an upward key command to 112.5%, reduction to 95% with boost intent retained, explicit disable, and restoration of native brightness and the original gamma table.
- No Mac model, OS build, or physical resolution literal remains in the active source eligibility checks.

AppKit reference: https://developer.apple.com/documentation/appkit/nsscreen/maximumpotentialextendeddynamicrangecolorcomponentvalue
