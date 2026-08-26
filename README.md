# Pigeon Control
![Julia](https://img.shields.io/badge/Julia-1.12-9558B2?logo=julia&logoColor=white) ![Godot](https://img.shields.io/badge/Godot-4.7-478CBF?logo=godot&logoColor=white)

*Simulating thousands of pigeons brawling over bread in a city plaza.*

<p align="center"><img src="docs/flock.gif" width="70%" alt="A thousand pigeons swarm through the low-poly city plaza"></p>

<table align="center">
    <tr>
      <td align="center" width="33%">
        <img src="docs/crumb-goblin.gif" width="200" alt="Crumb Goblin tumbles through a fight with its hammer"><br>
        <sub><b>Crumb Goblin</b> &middot; hammer</sub>
      </td>
      <td align="center" width="33%">
        <img src="docs/sky-scout.gif" width="200" alt="Sky Scout spins through a fight with its wand"><br>
        <sub><b>Sky Scout</b> &middot; wand</sub>
      </td>
      <td align="center" width="33%">
        <img src="docs/bruiser.gif" width="200" alt="Bruiser ragdolls through a fight with its bomb"><br>
        <sub><b>Bruiser</b> &middot; bomb</sub>
      </td>
    </tr>
  </table>

## What this is

A 3D pigeon swarm simulation split across two processes.
Julia owns all simulation state and steps thousands of birds through flocking, feeding, fear, and autonomous goofy combat.
Godot receives binary snapshots over UDP and draws them.
Neither side can do the other's job, so there is no shared mutable state and no argument about who moved a pigeon.
Julia alone owns the fights and the ragdoll physics.
Godot only renders snapshots and never chooses who brawls or how a body tumbles.

This is the successor to [dots-sim](https://github.com/wheevu/dots-sim).
The dots became pigeons, the arena became a 50 by 50 meter plaza, and the behaviors became actual simulation work: hunger drives pigeons toward food, threats scatter them, and **every** bird carries a genome that weights those urges differently.

The default seed `69420` reproduces "The Great Bread Massacre".
Same seed, same config, same inputs, same stampede.
That determinism is what makes the behavior tunable instead of guessable.

## Features

- Thousands of boids, each with a genome that scales cohesion, alignment, separation, greed, and cowardice individually.
- Four deterministic pigeon archetypes: Common, Crumb Goblin, Sky Scout, and Bruiser. Each has a distinct silhouette and genome bias, and fights with a derived weapon (sword, hammer, wand, bomb).
- Eight behavior states: flying, walking, eating, fleeing, landing, takeoff, fighting, perching.
- Bread drops create real food competition; pigeons within eating radius drain a crumb until it is gone.
- Humans are threats: outside an active fight, each pigeon flees when a human enters its own vision radius (`12m * genome.vision`), with fear force scaled by `genome.fear` and proximity.
- A custom binary UDP protocol that ships snapshots in one packet when small and fragments them past 8000 bytes.
- A renderer with no authority. Godot poses meshes; it never decides a pigeon's next move.
- Live control while the sim runs: drop bread, spawn a human, clear the plaza.
- A low-poly city plaza built from authored CC0 park and neighborhood models, with roads, crossings, houses, trees, benches, lamps, and a fountain framing the open square.

## Architecture

![Julia simulates and streams snapshots over UDP 5000, Godot renders, and commands flow back over UDP 5001](docs/architecture.svg)

Julia steps the world, packs it into bytes, and sends those bytes to Godot.
Godot parses them and poses the `MultiMeshInstance3D`.
Commands travel the other way on a second port and apply before the next step.

The wire format is the contract, and it lives in three places that must stay in sync: `src/protocol/snapshot.jl`, `docs/PROTOCOL.md`, and `godot/scripts/SnapshotParser.gd`.
The byte layout and fragmentation rules are in [docs/PROTOCOL.md](docs/PROTOCOL.md).
The module map and data flow are in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Quickstart

From the repository root, terminal 1 runs the simulation server:

```bash
julia --project=. experiments/run_server.jl --seed 69420 --n 2000 --port 5000 --fps 60
```

Terminal 2 runs the renderer:

```bash
godot --path godot
```

You can also open the project in the Godot editor and press Play.

## Control commands

Commands are plain text over UDP, one per packet, on port `snapshot_port + 1` (5001 by default).

| Command | Effect |
| --- | --- |
| `DROP_BREAD x y z amount` | Scatters up to 200 crumbs in a 1.5 m disk; pigeons eat them |
| `SPAWN_HUMAN x y z` | Sets the threat position; nearby pigeons flee |
| `CLEAR_HUMAN` | Removes the threat |
| `KILL_THE_SUN` | Currently a no-op |

In Godot: **B** drops bread under the crosshair, **H** spawns a human, **C** clears it, **K** sends the no-op.

## Development

Install Julia dependencies once:

```bash
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

Run the test suite (T1-T12 plus control-channel coverage, determinism, serialization contract, behavior):

```bash
julia --project=. test/runtests.jl
```

The Godot side has headless self tests:

```bash
cd godot && godot --headless -s res://scripts/_selftest.gd
cd godot && godot --headless -s res://scripts/_fragtest.gd
```

## Documentation

- [docs/PROTOCOL.md](docs/PROTOCOL.md): the canonical wire specification.
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): module map and data flow.

## Third-party assets

All bundled art is CC0/public domain. Per-pack creator, source, and license records live in the `ATTRIBUTION.md` files under `godot/assets/`.

## Limitations

The server pairs with a listener.
On macOS, sending a UDP datagram to a closed port can block indefinitely, so run Godot, or any listener, on the snapshot port.
With a listener present, sends return instantly and the server exits cleanly on duration or Ctrl-C.

Throughput drops fast with population: roughly 39 steps/s at n=100 and 5 steps/s at n=2000, against a 60 fps target.
Structure-of-arrays storage and threading are the planned fixes.

## License

No license file yet.
