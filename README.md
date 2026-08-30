# Pigeon Control

Thousands of pigeons fight over bread in a low-poly city plaza.

<p align="center">
  <img src="docs/flock.gif" width="82%" alt="A large pigeon flock swarming through the plaza">
</p>

<table>
  <tr>
    <td><img src="docs/crumb-goblin.gif" alt="Crumb Goblin fighting with a hammer"></td>
    <td><img src="docs/sky-scout.gif" alt="Sky Scout fighting with a wand"></td>
    <td><img src="docs/bruiser.gif" alt="Bruiser fighting with a bomb"></td>
  </tr>
</table>

Julia owns the deterministic simulation.
Godot receives binary snapshots over UDP and renders the flock.
The same seed, configuration, and inputs reproduce the same stampede.

## Inside the plaza

- Thousands of individually weighted boids
- Hunger, food competition, fear, flight, perching, and combat
- Four pigeon archetypes with different silhouettes and behavior biases
- Live bread drops and human threats
- A renderer that never decides simulation behavior

![Julia simulation, UDP snapshots, Godot renderer, and the control channel](docs/architecture.svg)

## Explore

- [Run, control, test, and study the project](GUIDE.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Wire protocol](docs/PROTOCOL.md)
- [Observer experiment](docs/OBSERVER_EXPERIMENT.md)
