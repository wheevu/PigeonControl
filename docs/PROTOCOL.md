# PigeonControl UDP Snapshot Protocol (v1)

This document is the canonical wire specification. The Julia serializer (`src/protocol/snapshot.jl`), this document, and the Godot parser (`godot/scripts/SnapshotParser.gd`) must agree byte for byte. Any change to one requires a matching change to all three.

## Transport

- Snapshots travel from the simulation to the renderer over UDP on port 5000 by default.
- Control commands travel from the renderer or an operator to the simulation over UDP on port 5001 as plain text.
- All binary fields are little-endian.
- The simulation runs at the configured fps (default 60). The renderer interpolates between snapshots for visual smoothness.

## Fragmentation

A single UDP datagram is capped (~9216 bytes on macOS, 65507 bytes on IPv4). A snapshot with many pigeons (e.g. 2000 pigeons is roughly 80 KB) cannot fit in one datagram, so large snapshots are split into fragments.

- If the serialized snapshot fits in `CHUNK_SIZE` (8000 bytes), it is sent verbatim as a single `PICE` packet (the layout in the next sections). This is the backward-compatible fast path.
- Otherwise the snapshot bytes are split into `CHUNK_SIZE`-byte chunks and each chunk is wrapped in a `FRAG` envelope:

| Field | Type | Offset |
| --- | --- | --- |
| magic | UInt32 | 0 |
| frame_id | UInt32 | 4 |
| chunk_index | UInt16 | 8 |
| chunk_count | UInt16 | 10 |
| chunk_len | UInt16 | 12 |
| chunk_data | bytes | 14 |

`magic` for fragments is the ASCII bytes `FRAG`, encoded as the UInt32 `0x46524147`.
`frame_id` is the simulation tick at send time, used to group fragments of one snapshot.
Fragments may arrive out of order; the receiver reassembles by `chunk_index` and only parses once every `chunk_index` in `[0, chunk_count)` is present. Once complete, the reassembled bytes are parsed with the layout below. Incomplete frames are discarded if more than 16 frames are buffered.

## Coordinate system

- Units are meters.
- The world is Y-up, matching Godot's convention.
- The plaza is a 50x50m square centered at the origin on the XZ plane.
- Ground is at `y = 0`.
- Pigeons fly up to roughly `y = 15`.

## Layout

### Header (20 bytes)

| Field | Type | Offset |
| --- | --- | --- |
| magic | UInt32 | 0 |
| version | UInt8 | 4 |
| pad | 3 bytes | 5 |
| tick | UInt32 | 8 |
| pigeons | UInt32 | 12 |
| foods | UInt32 | 16 |

`magic` is the ASCII bytes `PICE`, encoded as the UInt32 `0x50494345`.
`version` is `1`.
The 3 pad bytes at offset 5 are reserved and must be zero.

### Pigeon record (40 bytes), repeated `pigeons` times, starting at offset 20

| Field | Type | Offset |
| --- | --- | --- |
| id | UInt32 | 0 |
| pos_x | Float32 | 4 |
| pos_y | Float32 | 8 |
| pos_z | Float32 | 12 |
| yaw | Float32 | 16 |
| pitch | Float32 | 20 |
| roll | Float32 | 24 |
| state | UInt8 | 28 |
| variant | UInt8 | 29 |
| flap_phase | Float32 | 30 |
| speed | Float32 | 34 |
| pad | 2 bytes | 38 |

### Food record (16 bytes), repeated `foods` times, immediately after the pigeon records

| Field | Type | Offset |
| --- | --- | --- |
| id | UInt32 | 0 |
| pos_x | Float32 | 4 |
| pos_y | Float32 | 8 |
| pos_z | Float32 | 12 |

### Total payload length

```
20 + 40 * pigeons + 16 * foods
```

## State enum

| Value | Name |
| --- | --- |
| 0 | FLYING |
| 1 | WALKING |
| 2 | EATING |
| 3 | FLEEING |
| 4 | LANDING |
| 5 | TAKEOFF |
| 6 | FIGHTING |
| 7 | PERCHING |

## Archetypes and derived weapons

The `variant` field (offset 29) selects one of four archetypes.
Weapons are derived, not sent on the wire. The table below is the single source of truth shared between the Julia serializer and the Godot renderer.

| Variant | Archetype | Derived weapon |
| --- | --- | --- |
| 0 | Common | Sword |
| 1 | Crumb Goblin | Hammer |
| 2 | Sky Scout | Wand |
| 3 | Bruiser | Bomb |

The renderer decides the weapon only from `variant`.
Unknown variants remain parseable; the renderer should fall back to Common and hide the weapon.
The weapon is visually shown only while `state == FIGHTING` (6).
The pad bytes (offsets 38-39 on each pigeon record) stay reserved and must remain zero; they are not used for any archetype or weapon data.

When `state == FIGHTING`, the `pitch` and `roll` fields carry Julia's authoritative ragdoll pose for that pigeon.
Julia derives an exaggerated but finite orientation from a per-pigeon `ragdoll_phase` while the pigeon is fighting (or its fight timer is still counting down): `pitch = 0.8 * sin(phase)` and `roll` wrapped into `-pi..pi`.
Godot interpolates these values only; it never computes ragdoll orientation itself.

## Version handling

The parser accepts `version` 1 and 2 and rejects anything else.
A mismatch is a hard error (Julia `parse_snapshot` throws; the Godot `SnapshotParser` returns `ok = false` with an unsupported-version error) and decoding must not continue.
v1 is frozen: header 20B, 40-byte pigeon record, 16-byte food record.
v2 is additive: every v1 offset stays identical, then new fields append.

## v2 additive visuals (version 2)

v2 keeps the 20B header with `version = 2`, then:

- Pigeon 48B: first 40B identical to v1 (roll now carries sim-owned bank for non-fighting birds, ragdoll pose while fighting), then `bank Float32` at offset 40 and `hunger01 Float32` at offset 44. Hunger is `clamp(hunger * 0.2, 0..1)`.
- Food 20B: v1 16B plus `amount Float32` at offset 16 so crumbs shrink as they are eaten.
- Env 20B: `sun Float32, time_of_day Float32, wind_xyz 3x Float32`. Sun is 1.0 midday, 0.22 after `KILL_THE_SUN` latches dusk. Wind is a slow deterministic sway, never RNG.
- Threat 16B: `active UInt8, pad 3B, xyz Float32`. Mirrors the sim threat so SECURITY cam and flee tint follow authority.
- Stats 16B: `n_fighting UInt32, n_fleeing UInt32, n_eating UInt32, food_left Float32` for HUD and heat.
- `fx_count UInt32` then Fx 20B each (cap 64): `type UInt32, xyz Float32, mag Float32`. Types: 1 feather, 2 dust, 3 gobble, 4 gust, 5 burst, 6 dropping. Julia pushes during `step!` and clears each tick; Godot draws each with a TTL and never decides one.

Total v2 length: `20 + 48 * pigeons + 20 * foods + 20 + 16 + 16 + 4 + 20 * fx`.

## Control commands

Text UDP on port `snapshot_port + 1` (default 5001), one command per packet:

- `DROP_BREAD x y z amount` — scatter `amount` (integer count, clamped to 1..200) bread crumbs in a 1.5 m disk centered at `(x, max(y,0.2), z)`. Each crumb is a `Food` with `amount = 50.0`. Pigeons swarm and eat them.
- `SPAWN_HUMAN x y z` — set the world's single threat position to `(x, y, z)`.
  Each pigeon detects the threat within an effective radius of `THREAT_RADIUS` (12 m) multiplied by its own `genome.vision`.
  A non-fighting pigeon that detects the threat enters FLEEING, while the repulsion strength applied to it depends on its `genome.fear` and proximity to the threat.
  An active fight finishes before either pigeon responds to the threat.
- `CLEAR_HUMAN` — clear the threat (`nothing`).
- `KILL_THE_SUN` — latch dusk: sun drops to 0.22 and stays there for the run.

Commands are input events; determinism holds given the same seed, config, and ordered command sequence.

## Note on smoothness

The renderer interpolates between consecutive snapshots. The simulation owns the truth at each tick; interpolation is purely a rendering concern and never feeds back into the sim.
