# ADR 0011: Only a frame sink holds the LED matrix

- **Status:** Accepted
- **Date:** 2026-11-21
- **Related Artefacts:**
    - Builds on: ADR 0010 (the LED matrix maps its registers through relaxed /dev/mem)
    - Introduced in: #446
    - Design: corygyarmathy/matrix-display#1, the sink in corygyarmathy/matrix-display#5
    - Implemented in: `modules/services/led-matrix.nix`

## Context

The LED matrix library starts as root and maps the SoC's registers through `/dev/mem`, which ADR 0010 relaxes so that claimed regions map too. It then drops to an unprivileged user, but keeps those mappings: whatever runs in that process after the drop can still write the GPIO, clock and PWM registers, and through `iomem=relaxed` any other claimed device's. Whatever is linked against the library is therefore privileged for its whole life, not only while it starts. rpi01's content - a gradient following the sun, homelab alerts, calendar events - needs the network, parses what comes back, and is the part that will change most often.

## Decision

Only a frame sink holds the panel hardware. It does nothing but take finished frames and put them on the panels, and it reaches nothing but a local socket that systemd creates and hands to it. All content comes from a separate, unprivileged process that writes frames to that socket. The socket's ownership and mode, set by the unit and never by the sink, are the whole of who may draw on the panels.

## Consequences

**Positive**

- The process with register mappings opens no network sockets and keeps its sandbox: no network namespace, the same bounded capabilities. Network-facing, frequently changed code never has the mappings.
- The renderer can be sandboxed, restarted and replaced on its own terms, and needs no capabilities at all.
- With no client, the sink shows nothing, so a dead renderer leaves the panels dark rather than frozen on a stale frame.

**Negative**

- Two processes and a wire protocol between them, versioned across two repositories. They come from the same flake input, so they move together, but a renderer built elsewhere has to match the sink's version.
- The sink still parses input from another process while it holds the mappings. That input is a fixed-size frame from a local, group-restricted peer, a far smaller surface than the network, but not none.
- Anything in the socket's group can draw on the panels. That is a display, not a privilege, but membership is the boundary and has to be granted deliberately.

## Alternatives considered

- **The renderer links the library and runs as the display service.** One process, as the demo runs today. Its privilege drop keeps the mappings, so a compromise through the network-facing code reaches the registers.
- **The renderer drives the panels from a second, privileged thread it spawns and isolates itself.** The same process and the same mappings; isolation inside one address space is not a boundary.
- **A TCP or other network socket on localhost.** Needs the display unit's network namespace lifted, and access is then decided by whatever binds first rather than by file ownership.
- **Shared memory or a file the renderer writes.** No framing, so the sink could read a half-written frame, and no sign that the renderer has gone; a socket gives one message per frame and a disconnect the sink can fade on.
