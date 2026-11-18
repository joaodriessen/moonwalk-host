# Inert keyboard release regression

Run from any directory with an existing C++17 compiler; no platform SDK, input
permissions, host process or build cache is needed:

```sh
python3 tests/probes/input_release/verify.py --output /absolute/new/evidence-directory
```

The probe extracts the actual keyboard packet handler, key bookkeeping helpers,
key remapper, sender, repeat handler and queued reset function from `src/input.cpp`.
It compiles those unmodified bodies with actual protocol structs and production
endian helpers. The platform keyboard emitter only records `(code, release, flags)`;
the task queue is drained explicitly, delayed repeats are invoked explicitly, and
platform initialization/CGEvent/input-device APIs are never linked or called.
Generated source, compile output, run output and exact source/function hashes are
saved to the caller's new output directory. No output path is reused or removed.

Checks cover the supported right-Alt→Windows/Command mapping during disconnect,
duplicate down filtering, normal mapped up/repeat, an unmapped held modifier chord,
extended/high flags, and avoiding a second release for already-released keys.
The pre-fix production bodies fail only the mapped disconnect case; fixed bodies
pass all five checks. This tests actual production input logic at inert boundaries,
not macOS event delivery or real keyboard state.

Host keybindings are loaded by config parsing at process startup. The generic
native setter refuses map values, and there is no live key-map mutation path.
The fix preserves that contract; it does not add a mapping-change-during-hold API.
