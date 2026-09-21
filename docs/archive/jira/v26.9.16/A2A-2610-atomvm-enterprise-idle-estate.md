# A2A-2610: turn AtomVM into the admitted enterprise idle-estate substrate

- **Status**: OPEN
- **Severity**: High
- **Standing**: `NOT_FOUND` for the estate controller; AtomVM runtime itself is `ALIVE`
- **Owning repo**: `seanchatmangpt/unrdf`; control-plane integration in `seanchatmangpt/ash_a2a`
- **Reuse**: `@unrdf/atomvm`, AtomVM WASM runtime state machine, Knowledge Hooks AtomVM bridge, OTEL

## Problem

The ecosystem already runs BEAM code through AtomVM in browser/Node and already bridges Knowledge Hooks into the runtime. What does not yet exist is the enterprise-estate controller that turns admitted desktops/laptops into bounded overnight workers and returns them to their primary role safely.

The missing component is scheduling/admission, not a VM.

## Required change

Model every participating host as an admitted resource envelope containing at least:

- stable host/resource identity;
- permitted execution window;
- CPU/memory ceilings;
- thermal/power constraints where observable;
- network capability ceiling;
- local storage ceiling;
- allowed workload classes;
- drain deadline;
- current lease/standing.

Jobs are immutable/content-addressed execution packages. A lease may SELECT a host and run an admitted package; it may not widen package authority.

## State machine

`PRIMARY -> IDLE_CANDIDATE -> ADMITTED -> LEASED -> EXECUTING -> DRAINING -> PRIMARY`

Any uncertainty about host standing, deadline, package identity or resource envelope must fail closed to `PRIMARY` / no new work.

## Chicago falsifiers

1. A host outside its admitted idle window accepts no new job.
2. Memory/CPU envelope overflow refuses before execution.
3. Drain deadline stops new leases and returns the host to PRIMARY.
4. Replayed job identity cannot produce duplicate consequence.
5. A job cannot acquire network/filesystem authority beyond its package/host ceiling.
6. Host loss leaves receipted UNKNOWN/pending work rather than inventing success.

## Definition of done

- resource/lease/job schemas exist;
- one scheduler can lease at least two independent AtomVM hosts using only typed envelopes;
- execution and drain transitions are receipted;
- CMCA can select `UNKNOWN_IDLE_ESTATE` through this interface;
- qualification includes abrupt host-loss and morning-drain falsifiers.
