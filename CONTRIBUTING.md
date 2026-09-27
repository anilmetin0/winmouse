# Contributing

Contributions are welcome. WinMouse is experimental; physical-mouse behavior and restoration have
not yet been verified.

## Before changing behavior

- Read the relevant source and research in `docs/research`.
- Keep changes compatible with macOS 14 and use only the Apple frameworks already used by the app.
- Keep HID changes scoped to external mouse services. Do not change system preferences or touch
  trackpads.
- Every behavior constant must have evidence in `docs/research`. Update that evidence with the
  code when a constant changes.

## Build and self-test

Use macOS with Xcode or the Xcode Command Line Tools:

```sh
./build.sh selftest
./build.sh
```

The first command compiles and runs the pointer and scroll reference-vector checks. The second also
builds a universal `build/WinMouse.app` for Apple Silicon and Intel. For changes to the math, add or
update a focused test in `Sources/SelfTest`.

## Pull requests

Explain the user-visible change, relevant evidence, and checks you ran. Mark hardware-dependent
results as unverified unless you tested them with a physical mouse. Do not claim a release or
hardware validation that has not happened.
