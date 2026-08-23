# Pigeon Control

Pigeon Control - computational ornithological warfare. Julia simulates; Godot renders.

## What is this

A 3D pigeon swarm simulation where Julia owns reality and Godot 4.x merely witnesses it.
The seed started as dots-doing-math and graduated into a full pigeon engine: thousands of birds flock, land, eat, flee, and fight over bread in a 50x50m plaza.
Two processes talk over a custom UDP binary protocol. Julia never renders. Godot never decides.

## Stack

| Concern | Tool |
| --- | --- |
| Simulation | Julia |
| Math | StaticArrays / LinearAlgebra |
| RNG | StableRNGs |
| Renderer | Godot 4.x |
| Pigeon rendering | MultiMeshInstance3D |
| Chaos FX | GPUParticles3D (later) |
| Sim <-> Render | Custom UDP binary protocol |
| Models | Blender -> glTF |

No Python is used anywhere in this project.

## Quick start

Terminal 1 (Julia sim server):

```bash
cd projects/PigeonControl && julia --project=. experiments/run_server.jl --seed 69420 --n 2000 --port 5000 --fps 60
```

Terminal 2 (Godot renderer):

```bash
godot --path /Users/nguyenhuyvu/projects/PigeonControl/godot
```

You can also open the project in the Godot editor and press Play.

The seed `69420` reproduces "The Great Bread Massacre" deterministically. Same seed, same config, same inputs: same massacre.

## Control commands

Text UDP on port 5001, one command per packet:

- `DROP_BREAD x y z amount` - scatter bread at a location.
- `SPAWN_HUMAN x y z` - drop a human threat into the plaza.
- `CLEAR_HUMAN` - remove all humans.
- `KILL_THE_SUN` - undocumented and currently a no-op.

## Status

M0 (the vertical spine) is complete: Julia steps the sim, serializes snapshots, ships them over UDP, and Godot renders the flock.
Later milestones remain open: evolution via genome reproduction, the pigeon social graph and inferred factions, particle chaos, cinematic cameras, and debug visualization.
