# PigeonControl - Project AGENTS.md

This file governs the PigeonControl repository. The global `~/.config/opencode/AGENTS.md` still applies and takes precedence on anything not described here.

## Commands

```bash
# Install Julia dependencies
julia --project=. -e 'using Pkg; Pkg.instantiate()'

# Run the Julia test suite
julia --project=. test/runtests.jl

# Run the simulation server
julia --project=. experiments/run_server.jl --seed 69420 --n 2000 --port 5000 --fps 60

# Godot headless self-test
cd godot && godot --headless -s res://scripts/_selftest.gd

# Open / run the Godot renderer
godot --path /Users/nguyenhuyvu/projects/PigeonControl/godot
```

## Architecture summary

Julia owns all simulation state. Godot never decides pigeon behavior; it only renders snapshots it receives over UDP.

- `src/` holds the engine.
  - `pigeon.jl` - `Pigeon` and `Genome`.
  - `world.jl` - `World`, `SimConfig`, `Food`, `step!`.
  - `behavior/` - `flocking.jl`, `feeding.jl`, `fear.jl`, `decision.jl`.
  - `spatial/` - `grid.jl` (`SpatialGrid`), `queries.jl`.
  - `protocol/snapshot.jl` - serialize and parse the binary snapshot.
  - `experiments/run_server.jl` - the UDP server entry point.
- `godot/` holds the renderer.
  - `scripts/Main.gd` - builds the scene.
  - `SnapshotParser.gd` - parses the binary UDP payload.
  - `Swarm.gd` - drives `MultiMeshInstance3D`.
  - `SnapshotReceiver.gd` - receives UDP.
  - `FreeCam.gd` - the camera.

## Invariants

- The simulation is deterministic given the seed, the config, and the ordered input events.
- The world uses a Y-up coordinate convention (meters).
- The wire protocol is little-endian.
- Any protocol change must be mirrored in three places at once: `src/protocol/snapshot.jl`, `docs/PROTOCOL.md`, and `godot/scripts/SnapshotParser.gd`.

## Known limitations

- The server pairs with a listener (Godot). On macOS, sending a UDP datagram to a
  closed port can block indefinitely (ICMP-unreachable quirk); always run Godot
  (or any listener) on the target port. With a listener present, `send` returns
  instantly and the server exits cleanly on `--duration` or Ctrl-C.
- The control channel (`DROP_BREAD`, `SPAWN_HUMAN`, `CLEAR_HUMAN`,
  `KILL_THE_SUN`) is implemented on both sides: `run_server.jl` listens on
  `snapshot_port + 1` (default 5001) and mutates the `World`; Godot's
  `CommandSender.gd` sends commands on keys B/H/C/K (drop bread / spawn human /
  clear human / latch dusk). The snapshot transport and fragmentation are
  fully implemented.
- Protocol v2 is additive and backward compatible: v1 offsets never shift,
  the parser accepts 1 and 2, and the server emits v2 by default (`--v1`
  falls back). New visual state (bank, hunger, food amount, env, threat,
  stats, fx) is sim-owned; Godot only draws it.

## Note

Do not commit or push unless explicitly asked.
