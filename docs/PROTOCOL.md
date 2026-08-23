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

## Control commands

Text UDP on port 5001, one command per packet:

- `DROP_BREAD x y z amount`
- `SPAWN_HUMAN x y z`
- `CLEAR_HUMAN`
- `KILL_THE_SUN` (no-op)

## Note on smoothness

The renderer interpolates between consecutive snapshots. The simulation owns the truth at each tick; interpolation is purely a rendering concern and never feeds back into the sim.
