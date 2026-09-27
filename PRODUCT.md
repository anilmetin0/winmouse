# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos

## Users

People who are used to a mouse on Windows and plug an external mouse into a Mac. They want the
pointer and the wheel to behave the way their hands expect, without learning a new feel.

## Product Purpose

WinMouse aims to make an external mouse on macOS feel like the same mouse on Windows: the
"Enhance pointer precision" acceleration curve with the Windows pointer speed slider, and
Chrome/Edge-style wheel scrolling (a fixed distance per notch, a short ease-in-out, no
acceleration). Success means the user stops noticing the mouse.

## Positioning

Other Mac mouse utilities keep Apple's acceleration curve and scroll like a trackpad. WinMouse
uses Windows-derived numbers for the curve, slider, lines per notch and animation timing,
taken from Windows' registry defaults, Chromium's source and measured data in `docs/research`.

## Operating Context

A menu-bar utility that runs all day and is opened rarely: once to grant Accessibility and pick
settings, then only to pause it. Settings mirror the Windows controls by name and default.

## Capabilities and Constraints

- Open source, MIT license. UI in English and Turkish, following the system language.
- Touches only external mice; built-in and Magic trackpads keep macOS behaviour.
- Never writes system preferences. Per-device HID settings are restored on quit and on pause.
- Zero idle cost: no polling while the mouse is still.
- Needs Accessibility access for scrolling; the pointer curve needs no permission.

## Product Principles

1. Faithful to Windows numbers over taste: every constant has evidence behind it.
2. Keep changes per device and restore its saved values when WinMouse stops.
3. Invisible when working: no notifications, no chrome beyond a menu bar icon.
