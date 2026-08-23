# PigeonControl Architecture

Two layers, one contract. Julia is the brain that owns reality. Godot 4.x is the eye that witnesses it. They meet only on the wire.

## System diagram

```
+--------------------------------------------------+
|                  Julia core                      |
|                                                  |
|   step!(world)  ->  simulate pigeon behavior     |
|        |                                         |
|        v                                         |
|   serialize_snapshot(world)  ->  Pigeon + Food   |
|        |                                         |
+--------|-----------------------------------------+
         |  UDP / binary (port 5000)  <-- snapshots
         |
         v
+--------------------------------------------------+
|                  Godot 4.x                       |
|                                                  |
|   SnapshotReceiver.gd  ->  UDP socket            |
|        |                                         |
|        v                                         |
|   SnapshotParser.gd  ->  parse bytes             |
|        |                                         |
|        v                                         |
|   Swarm.gd  ->  MultiMeshInstance3D transforms    |
|        |                                         |
|   +--------+  +--------+  +----------+  +------+  |
|   | plaza  |  | meshes |  | particles|  | cams |  |
|   | (50x50)|  |(glTF)  |  |(GPU later)| |/UI/  |  |
|   |        |  |        |  |          |  | audio|  |
|   +--------+  +--------+  +----------+  +------+  |
+--------------------------------------------------+

   Control flows back on port 5001 (text commands):
   DROP_BREAD / SPAWN_HUMAN / CLEAR_HUMAN / KILL_THE_SUN
```

## Julia module map (`src/`)

- `PigeonControl.jl` - package glue.
- `pigeon.jl` - `Pigeon` and `Genome`.
- `world.jl` - `World`, `SimConfig`, `Food`, `step!`.
- `spatial/grid.jl` - `SpatialGrid`.
- `spatial/queries.jl` - neighbor queries.
- `behavior/flocking.jl` - flocking forces.
- `behavior/feeding.jl` - bread seeking and eating.
- `behavior/fear.jl` - human/flee response.
- `behavior/decision.jl` - per-pigeon state machine.
- `protocol/snapshot.jl` - serialize and parse snapshots.
- `experiments/run_server.jl` - UDP server entry point.

## Godot module map (`godot/`)

- `project.godot` - project configuration.
- `main.tscn` - the scene.
- `scripts/Main.gd` - scene builder.
- `scripts/SnapshotParser.gd` - binary parse.
- `scripts/Swarm.gd` - `MultiMeshInstance3D` driver.
- `scripts/SnapshotReceiver.gd` - UDP receiver.
- `scripts/FreeCam.gd` - camera.
- `scripts/_selftest.gd` - headless self-test.

## Data flow

- `step!(world)` advances the simulation one tick.
- `serialize_snapshot(world)` packs the header, pigeon records, and food records into bytes.
- The bytes go out over UDP on port 5000.
- `SnapshotReceiver.gd` reads the packet.
- `SnapshotParser.gd` decodes the bytes into structures.
- `Swarm.gd` writes transforms onto the `MultiMeshInstance3D`.
- Control commands flow the other way on port 5001 and feed back into the next `step!`.

## Roadmap

- Evolution: genome reproduction and selection across generations.
- Social graph: pigeon relationships that infer factions.
- GPUParticles3D: crumbs, feathers, dust, and shit.
- Wing vertex-shader animation for flapping.
- Four camera modes: FREECAM, FOLLOW, CINEMATIC, SECURITY.
- GLMakie debug visualization of the sim state.
