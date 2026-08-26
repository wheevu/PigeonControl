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
- `behavior/combat.jl` - fight initiation, `fight_timer`, and `ragdoll_phase` updates.
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
- `behavior/combat.jl` runs inside the step: it sets `state = FIGHTING`, drives a per-pigeon `fight_timer` down, and advances `ragdoll_phase` for the ragdoll pose. Julia owns this batched fight state; Godot never decides who is fighting or how a body tumbles.
- `serialize_snapshot(world)` packs the header, pigeon records, and food records into bytes. For fighting pigeons it derives the exaggerated-but-finite `pitch`/`roll` ragdoll orientation from `ragdoll_phase`; the archetype weapon is never sent, only `variant` is.
- The bytes go out over UDP on port 5000.
- `SnapshotReceiver.gd` reads the packet.
- `SnapshotParser.gd` decodes the bytes into structures.
- `Swarm.gd` writes transforms onto the `MultiMeshInstance3D` and derives the weapon from `variant`, showing it only while `state == FIGHTING`. Rendering is instanced: Godot interpolates between snapshots for smoothness but never feeds state back into the sim.
- Control commands flow the other way on port 5001 and feed back into the next `step!`.

## Roadmap

- Evolution: genome reproduction and selection across generations.
- Social graph: pigeon relationships that infer factions.
- GPUParticles3D: crumbs, feathers, dust, and shit.
- Wing vertex-shader animation for flapping.
- Four camera modes: FREECAM, FOLLOW, CINEMATIC, SECURITY.
- GLMakie debug visualization of the sim state.

## Offline observer lane

The observer package lives under `observer/` and is an offline analysis lane.
It consumes datasets produced by the simulation after the fact and never participates in the live UDP runtime protocol.
The binary UDP protocol (port 5000 snapshots, port 5001 commands) is unchanged and remains the single contract between Julia and Godot.
Godot is used by the observer only for optional frame capture through `observer_capture.tscn`, and only when the `generate --frames` flag is set.
The observer never sends commands to the running simulation and never feeds state back into Julia.

### Experiment-only acknowledgment

During dataset generation with frame capture, Godot may emit an experiment-only acknowledgment that capture has completed for a run.
This acknowledgment is scoped to the experiment pipeline and is distinct from the production runtime protocol.
It is never required by the live renderer and never alters the wire format described in `docs/PROTOCOL.md`.
The runtime protocol and the experiment-only acknowledgment are kept strictly separate so the observer cannot change simulation behavior.

See `docs/OBSERVER_EXPERIMENT.md` for the research plan and evidence policy of the observer lane.
