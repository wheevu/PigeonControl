# PigeonControl: pigeon genome, struct, and spawner.

"""
Genome holds first-class behavioral multipliers (centered on 1.0) for a pigeon.
All fields are Float32 and represent a relative weight applied to the
corresponding steering behavior.
"""
struct Genome
    cohesion::Float32
    separation::Float32
    alignment::Float32
    greed::Float32      # attraction to food
    fear::Float32       # cowardice (high = coward, low = bold)
    aggression::Float32
    curiosity::Float32
    speed::Float32
    vision::Float32
    size::Float32
    metabolism::Float32
end

function Genome(rng::AbstractRNG)
    # Each multiplier is sampled around 1.0 with mild spread, clamped to a sane
    # range. Fear is sampled more broadly so the flock mixes bold (low) and
    # cowardly (high) birds.
    clamp1(x) = Float32(clamp(x, 0.1, 3.0))
    Genome(
        clamp1(1.0 + 0.5 * randn(rng)),  # cohesion
        clamp1(1.0 + 0.5 * randn(rng)),  # separation
        clamp1(1.0 + 0.5 * randn(rng)),  # alignment
        clamp1(1.0 + 0.5 * randn(rng)),  # greed
        Float32(clamp(1.0 + 0.9 * randn(rng), 0.05, 3.0)),  # fear: broad spread
        clamp1(1.0 + 0.5 * randn(rng)),  # aggression
        clamp1(1.0 + 0.5 * randn(rng)),  # curiosity
        clamp1(1.0 + 0.4 * randn(rng)),  # speed
        clamp1(1.0 + 0.4 * randn(rng)),  # vision
        clamp1(1.0 + 0.3 * randn(rng)),  # size
        clamp1(1.0 + 0.4 * randn(rng)),  # metabolism
    )
end

"""
A single pigeon agent.

NOTE: declared `mutable` because `step!` updates fields in place
(`p.vel = ...`, `p.flap_phase += ...`, `p.state = ...`, ...). The brief's
`struct Pigeon` wording is incompatible with the required in-place updates, so
this is a `mutable struct`.
"""
mutable struct Pigeon
    id::UInt32
    pos::Vec3
    vel::Vec3
    heading::Vec3
    hunger::Float32       # 0 = full, grows over time
    fear::Float32         # transient fear level (set by fear_force, decays each tick)
    energy::Float32
    state::UInt8
    variant::UInt8
    target_food::Int
    genome::Genome
    flap_phase::Float32
    speed::Float32
    age::Float32
end

function Pigeon(id::Integer, rng::AbstractRNG, cfg)
    g = Genome(rng)
    # Spawn inside the arena, at low altitude (y in 0.5..3) per the brief.
    x = Float32((rand(rng) * 2 - 1) * cfg.arena_half * 0.9)
    z = Float32((rand(rng) * 2 - 1) * cfg.arena_half * 0.9)
    y = Float32(rand(rng) * 2.5 + 0.5)   # 0.5 .. 3.0
    pos = @SVector Float32[x, y, z]

    # Small random velocity.
    vx = Float32(rand(rng) * 2 - 1)
    vy = Float32(rand(rng) * 0.5)
    vz = Float32(rand(rng) * 2 - 1)
    vel = @SVector Float32[vx, vy, vz]
    heading = norm(vel) > 1.0f-5 ? vel / norm(vel) : @SVector Float32[1.0f0, 0.0f0, 0.0f0]

    Pigeon(
        UInt32(id),
        pos,
        vel,
        heading,
        Float32(rand(rng) * 0.5),     # hunger
        0.0f0,                         # fear (transient)
        Float32(rand(rng) * 50 + 50), # energy
        0x00,                          # state (FLYING default; FLYING defined in protocol)
        UInt8(rand(rng, 0:2)),         # variant 0..2
        -1,                            # target_food
        g,
        Float32(rand(rng) * 2 * π),    # flap_phase
        0.0f0,                         # speed
        0.0f0,                         # age
    )
end
