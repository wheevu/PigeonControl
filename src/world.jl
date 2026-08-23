# PigeonControl: world state, config, and the simulation step.

"""
A piece of food dropped in the plaza.

NOTE: declared `mutable` because `step!` decrements `amount` in place
(`food.amount -= eat`). The brief's `struct Food` wording is incompatible with
the required in-place mutation, so this is a `mutable struct`.
"""
mutable struct Food
    id::UInt32
    pos::Vec3
    amount::Float32
end

"""
Tunable simulation configuration.
"""
Base.@kwdef struct SimConfig
    arena_half::Float32   = 25.0f0
    max_height::Float32   = 15.0f0
    dt::Float32           = 1.0f0 / 60.0f0
    seed::UInt32          = 69420
    n_pigeons::Int        = 2000
    food_count::Int       = 12
    neighbor_radius::Float32 = 6.0f0
    sep_radius::Float32      = 2.0f0
    max_speed::Float32       = 8.0f0
    max_force::Float32       = 20.0f0
    w_cohesion::Float32      = 1.0f0
    w_alignment::Float32     = 1.0f0
    w_separation::Float32    = 1.5f0
    w_food::Float32          = 2.0f0
    w_fear::Float32          = 4.0f0
    hunger_rate::Float32     = 0.02f0
    eat_radius::Float32      = 1.2f0
end

"""
The full simulation world.
"""
mutable struct World
    cfg::SimConfig
    rng::Any                      # StableRNGs.LehmerRNG (typed Any for safety)
    pigeons::Vector{Pigeon}
    foods::Vector{Food}
    tick::UInt32
    grid::SpatialGrid
    threat::Union{Nothing, Vec3}
end

"""
Construct a fresh, reproducible world from a config.
"""
function make_world(cfg::SimConfig = SimConfig())
    rng = StableRNGs.StableRNG(Int(cfg.seed))
    pigeons = Pigeon[ Pigeon(i, rng, cfg) for i in 1:cfg.n_pigeons ]

    foods = Food[]
    for i in 1:cfg.food_count
        x = Float32((rand(rng) * 2 - 1) * cfg.arena_half * 0.8)
        z = Float32((rand(rng) * 2 - 1) * cfg.arena_half * 0.8)
        amount = Float32(rand(rng) * 100 + 50)
        push!(foods, Food(UInt32(i), @SVector(Float32[x, 0.2f0, z]), amount))
    end

    grid = SpatialGrid(cfg)
    World(cfg, rng, pigeons, foods, UInt32(0), grid, nothing)
end

# ----- force helpers -----
@inline function clamp_force(f::Vec3, max::Float32)
    n = norm(f)
    n > max ? f * (max / n) : f
end

@inline function clamp_speed(v::Vec3, max::Float32)
    n = norm(v)
    n > max ? v * (max / n) : v
end

@inline function clamp_pos(pos::Vec3, cfg::SimConfig)
    x = clamp(pos[1], -cfg.arena_half, cfg.arena_half)
    y = clamp(pos[2], 0.0f0, cfg.max_height)
    z = clamp(pos[3], -cfg.arena_half, cfg.arena_half)
    return @SVector(Float32[x, y, z])
end

"""
Soft-wall steering: nudge pigeons back toward the arena volume.
"""
function boundary_steer(w::World, p::Pigeon)
    cfg = w.cfg
    f = @SVector(zeros(Float32, 3))
    margin = 3.0f0
    k = 4.0f0

    if p.pos[1] >  cfg.arena_half - margin
        f += @SVector(Float32[-1.0f0, 0.0f0, 0.0f0]) * ((p.pos[1] - (cfg.arena_half - margin)) * k)
    elseif p.pos[1] < -cfg.arena_half + margin
        f += @SVector(Float32[ 1.0f0, 0.0f0, 0.0f0]) * (((-cfg.arena_half + margin) - p.pos[1]) * k)
    end

    if p.pos[3] >  cfg.arena_half - margin
        f += @SVector(Float32[0.0f0, 0.0f0, -1.0f0]) * ((p.pos[3] - (cfg.arena_half - margin)) * k)
    elseif p.pos[3] < -cfg.arena_half + margin
        f += @SVector(Float32[0.0f0, 0.0f0,  1.0f0]) * (((-cfg.arena_half + margin) - p.pos[3]) * k)
    end

    if p.pos[2] > cfg.max_height - 1.0f0
        f += @SVector(Float32[0.0f0, -1.0f0, 0.0f0]) * ((p.pos[2] - (cfg.max_height - 1.0f0)) * k)
    elseif p.pos[2] < 0.5f0
        f += @SVector(Float32[0.0f0, 1.0f0, 0.0f0]) * ((0.5f0 - p.pos[2]) * k)
    end

    return f
end

# Combined global weight for the (cohesion+alignment+separation) boids force.
# The three sub-behaviors are genome-scaled inside `boids_force`; the three
# global weights are blended into a single scalar so every SimConfig weight is
# honored without changing the boids_force -> Vec3 signature required by the brief.
@inline boids_global_weight(cfg::SimConfig) =
    (cfg.w_cohesion + cfg.w_alignment + cfg.w_separation) / 3.0f0

"""
Advance the world by one tick.
"""
function step!(w::World)
    cfg = w.cfg
    n = length(w.pigeons)

    # (a) rebuild spatial grid
    build!(w.grid, w.pigeons)

    # (b)(c) compute forces and integrate motion
    for i in 1:n
        p = w.pigeons[i]

        force  = boids_global_weight(cfg) * boids_force(w, i)
        force += cfg.w_food  * food_force(w, i)
        force += cfg.w_fear  * fear_force(w, i)
        force += boundary_steer(w, p)
        force  = clamp_force(force, cfg.max_force)

        vel = clamp_speed(p.vel + force * cfg.dt, cfg.max_speed)
        pos = clamp_pos(p.pos + vel * cfg.dt, cfg)

        p.vel   = vel
        p.pos   = pos
        p.speed = Float32(norm(vel))
        if norm(vel) > 1.0f-5
            p.heading = vel / norm(vel)
        end

        p.hunger += cfg.hunger_rate * cfg.dt
        p.age    += cfg.dt
        p.energy -= cfg.dt * p.genome.metabolism * 0.1f0
    end

    # (d)(e) feeding + state update + flap bookkeeping
    for i in 1:n
        p = w.pigeons[i]

        ate = false
        fi = nearest_food(w, p.pos, cfg.eat_radius)
        if fi !== nothing
            idx, _ = fi
            food = w.foods[idx]
            if food.amount > 0
                eat = min(food.amount, 5.0f0 * cfg.dt)
                food.amount -= eat
                p.hunger = max(0.0f0, p.hunger - eat)
                p.energy += eat * 2.0f0
                ate = true
            end
        end

        update_state!(p, w, ate)

        # (f) flap animation phase
        p.flap_phase = Float32(mod(p.flap_phase + p.speed * cfg.dt * 8.0f0, 2 * π))

        # transient fear decays toward zero
        p.fear = max(0.0f0, p.fear - 0.02f0)
    end

    # (g)
    w.tick += UInt32(1)
    return w
end
