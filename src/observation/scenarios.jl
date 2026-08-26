# PigeonControl: deterministic scenario construction.
#
# Every scenario configures ONLY initial state / genomes / population / an ordered
# intervention schedule. None of them replace step! behavior. The schedule entries
# are (tick, command_string) pairs; the command string is fed verbatim to the
# existing apply_command! dispatcher, so the simulation authority is unchanged.
#
# All construction is a pure function of (scenario name, seed, n_override) and
# therefore deterministic and seed-addressable.

const SCENARIO_NAMES = String[
    "baseline_flocking",
    "bread_competition",
    "sparse_bread",
    "bread_abundance",
    "human_panic",
    "repeated_human_interventions",
    "mixed_archetype_populations",
    "high_fear_populations",
    "low_fear_populations",
    "combat_heavy_populations",
    "dense_populations",
    "sparse_populations",
]

"Return a fresh copy of the scenario registry (the 12 required names)."
list_scenarios() = copy(SCENARIO_NAMES)

"Default population for a scenario when `--n` is not supplied on the CLI."
function default_n(name::AbstractString)
    name == "dense_populations"   && return 1000
    name == "sparse_populations"  && return 40
    return 300
end

"""
`with_genome(g; field=value, ...) -> Genome`

Reconstruct a Genome from an existing one, preserving every field except the
ones explicitly overridden. `fear` and `greed` are the privileged targets used by
the behavioral scenarios, but any gene may be overridden; unrelated fields are
never disturbed. `Pigeon.transient_fear` is a runtime quantity and is never a
target of genome edits.
"""
function with_genome(g::Genome;
        cohesion=nothing, separation=nothing, alignment=nothing,
        greed=nothing, fear=nothing, aggression=nothing,
        curiosity=nothing, speed=nothing, vision=nothing,
        size=nothing, metabolism=nothing)
    Genome(
        cohesion   === nothing ? g.cohesion   : Float32(cohesion),
        separation === nothing ? g.separation : Float32(separation),
        alignment  === nothing ? g.alignment  : Float32(alignment),
        greed      === nothing ? g.greed      : Float32(greed),
        fear       === nothing ? g.fear       : Float32(fear),
        aggression === nothing ? g.aggression : Float32(aggression),
        curiosity  === nothing ? g.curiosity  : Float32(curiosity),
        speed      === nothing ? g.speed      : Float32(speed),
        vision     === nothing ? g.vision     : Float32(vision),
        size       === nothing ? g.size       : Float32(size),
        metabolism === nothing ? g.metabolism : Float32(metabolism),
    )
end

# Deterministic archetype mix used by mixed_archetype_populations: a skewed
# distribution (40% Bruiser, 20% each of the others) so the flock is genuinely
# "mixed" rather than the default balanced id%4 spread.
function _mixed_variant(i::Int)
    r = i % 5
    r == 1 ? PIGEON_COMMON :
    r == 2 ? PIGEON_CRUMB_GOBLIN :
    r == 3 ? PIGEON_SKY_SCOUT :
             PIGEON_BRUISER
end

"""
`build_scenario(name, seed; n_override=nothing, base_cfg=SimConfig())`
  -> (World, Vector{Tuple{Int,String}})

Construct a fresh, reproducible world for `name` and return it together with the
ordered intervention schedule (tick, command). `n_override` (the explicit `--n`)
replaces the scenario's default population when provided.
"""
function build_scenario(name::AbstractString, seed::UInt32;
        n_override::Union{Int,Nothing}=nothing,
        base_cfg::SimConfig=SimConfig())
    name in SCENARIO_NAMES || error("unknown scenario: $name")
    n = n_override === nothing ? default_n(name) : n_override
    cfg = SimConfig(seed=seed, n_pigeons=n)
    w = make_world(cfg)
    schedule = Tuple{Int,String}[]

    if name == "baseline_flocking"
        # Pure flocking: no genome edits, no interventions.

    elseif name == "bread_competition"
        # Limited initial food + periodic bread bursts => crowding/competition.
        empty!(w.foods)
        for i in 1:3
            x = Float32((rand(w.rng) * 2 - 1) * cfg.arena_half * 0.3)
            z = Float32((rand(w.rng) * 2 - 1) * cfg.arena_half * 0.3)
            push!(w.foods, Food(UInt32(i), @SVector(Float32[x, 0.2f0, z]), 40.0f0))
        end
        push!(schedule, (3,  "DROP_BREAD 0.0 0.2 0.0 30"))
        push!(schedule, (6,  "DROP_BREAD 3.0 0.2 -2.0 30"))
        push!(schedule, (9,  "DROP_BREAD -3.0 0.2 2.0 30"))

    elseif name == "sparse_bread"
        # Few, small food sources scattered widely.
        empty!(w.foods)
        for i in 1:2
            x = Float32((rand(w.rng) * 2 - 1) * cfg.arena_half * 0.9)
            z = Float32((rand(w.rng) * 2 - 1) * cfg.arena_half * 0.9)
            push!(w.foods, Food(UInt32(i), @SVector(Float32[x, 0.2f0, z]), 30.0f0))
        end

    elseif name == "bread_abundance"
        # Many food sources plus periodic resupplies: a well-fed flock.
        empty!(w.foods)
        for i in 1:30
            x = Float32((rand(w.rng) * 2 - 1) * cfg.arena_half * 0.9)
            z = Float32((rand(w.rng) * 2 - 1) * cfg.arena_half * 0.9)
            push!(w.foods, Food(UInt32(i), @SVector(Float32[x, 0.2f0, z]), 80.0f0))
        end
        push!(schedule, (4,  "DROP_BREAD 0.0 0.2 0.0 40"))
        push!(schedule, (8,  "DROP_BREAD 5.0 0.2 5.0 40"))
        push!(schedule, (12, "DROP_BREAD -5.0 0.2 -5.0 40"))

    elseif name == "human_panic"
        # A human appears, then leaves: the flock should panic then settle.
        push!(schedule, (2, "SPAWN_HUMAN 0.0 1.0 0.0"))
        push!(schedule, (8, "CLEAR_HUMAN"))

    elseif name == "repeated_human_interventions"
        # Several appearance/clear cycles.
        push!(schedule, (2,  "SPAWN_HUMAN 0.0 1.0 0.0"))
        push!(schedule, (5,  "CLEAR_HUMAN"))
        push!(schedule, (7,  "SPAWN_HUMAN 6.0 1.0 4.0"))
        push!(schedule, (10, "CLEAR_HUMAN"))
        push!(schedule, (12, "SPAWN_HUMAN -6.0 1.0 -4.0"))

    elseif name == "mixed_archetype_populations"
        # Reassign archetypes to a skewed mix and rebuild a variant-consistent
        # genome for each pigeon from a deterministic per-id RNG.
        for (i, p) in enumerate(w.pigeons)
            v = _mixed_variant(i)
            p.variant = v
            r = StableRNG(UInt(seed) + UInt(i) * 0x9e3779b1)
            p.genome = Genome(r, UInt8(v))
        end

    elseif name == "high_fear_populations"
        for p in w.pigeons
            p.genome = with_genome(p.genome; fear=2.8f0)
        end

    elseif name == "low_fear_populations"
        for p in w.pigeons
            p.genome = with_genome(p.genome; fear=0.15f0)
        end

    elseif name == "combat_heavy_populations"
        # Bold, aggressive birds packed into a tight ball so fights erupt.
        m = length(w.pigeons)
        for (i, p) in enumerate(w.pigeons)
            ang = Float32(i) * 2.399963f0
            rad = 1.2f0 * sqrt(Float32(i) / Float32(max(1, m)))
            p.pos = Vec3(cos(ang) * rad, 1.0f0, sin(ang) * rad)
            p.vel = Vec3(0.0f0, 0.0f0, 0.0f0)
            p.genome = with_genome(p.genome; aggression=2.8f0, fear=0.2f0)
        end

    elseif name == "dense_populations"
        # Default large population already set via default_n.

    elseif name == "sparse_populations"
        # Default small population already set via default_n.
    end

    return w, schedule
end
