# Popup appearance reference

Version 0.7.19 (99) changes the brightness HUD only. The main NSPopover and native brightness slider retain their existing appearance.

## Close control

The supplied system sound HUD is approximately 2x: its close circle spans 36 pixels, with its center 14 pixels inward from the card's left and top edges. At logical size this is an 18 pt circle with a 7 pt inset. Its frame therefore starts 2 pt outside the left edge and ends 2 pt above the top edge. The previous center was 9 pt right and 5 pt down; the update moves it 2 pt left and 2 pt down. Coordinates are relative to the fitted card, so its height remains content driven.

The close control is an image-only borderless NSButton inside an 18 x 18 pt glass view with a 9 pt corner radius. A shared factory constructs both the card and the close surface with the exact same native glass style, tint, and inherited appearance. There is no separate button bezel color or forced dark appearance. Older systems share the same rounded NSVisualEffectView fallback. The X is an SF Symbol; the button retains native click and accessibility behavior.

The 0.7.18 glass-button bezel was rejected after visual review: it was too dark and did not remain circular at this size. The glass surface now owns the geometry, independently of NSButton bezel metrics.

## Glass

The old clear-glass popup placed a flat 30% black CALayer over the glass. Over the supplied white background, its interior sampled around RGB 179,179,179; the system sound HUD was lighter and retained background colors. The update removes the content-layer fill and applies a 22% neutral black tint through NSGlassEffectView.tintColor. Native tint compositing differs from a foreground layer; this value is a visual adjustment, not an exact derivation of Apple's private material.

Public API references:
- https://developer.apple.com/documentation/appkit/nsglasseffectview
- https://developer.apple.com/documentation/appkit/nsglasseffectview/tintcolor

## Validation

The release build and existing automated checks pass. The independent external-display lifecycle check skipped because no independent external display was available. Installation verifies both executable hashes and the previous signing requirement. Live visual confirmation requires an actual brightness-key press: the computer-use tool rejects XF86MonBrightnessUp.
