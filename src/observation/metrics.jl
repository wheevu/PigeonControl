# PigeonControl: per-tick aggregate metrics and CSV row builders.
#
# All metrics are computed from the authoritative World state after step! and are
# therefore deterministic. Labels are algorithmic and documented inline. Thresholds
# are reasonable V0 values (clearly marked) and may be tightened later.

# Fraction of pigeons with zero neighbors that counts as a "fragmented" flock.
const FRAG_THRESHOLD = 0.5

# ----- CSV column order (headers are emitted from these, rows must match) -----

const TICK_COLUMNS = String[
    "schema_version", "run_id", "tick", "seed", "sim_time", "n_pigeons", "n_foods", "total_food",
    "threat_active", "threat_x", "threat_y", "threat_z",
    "frac_flying", "frac_walking", "frac_eating", "frac_fleeing",
    "frac_landing", "frac_takeoff", "frac_fighting", "frac_perching",
    "mean_speed", "mean_hunger", "mean_transient_fear",
    "mean_g_fear", "mean_g_greed", "mean_g_cohesion", "mean_g_separation",
    "mean_g_alignment", "mean_g_aggression",
    "mean_local_density", "centroid_x", "centroid_y", "centroid_z", "dispersion",
    "fragmentation_proxy",
    "panic_onset_cum", "panic_onset_tick",
    "fight_onset_cum", "fight_onset_tick",
    "food_depletion_cum", "food_depletion_tick",
    "fragmentation_cum", "fragmentation_tick",
    "reconvergence_cum", "reconvergence_tick",
]

const PIGEON_COLUMNS = String[
    "schema_version", "run_id", "tick", "pigeon_id",
    "pos_x", "pos_y", "pos_z", "vel_x", "vel_y", "vel_z", "speed",
    "state", "archetype", "hunger", "transient_fear", "energy",
    "g_cohesion", "g_separation", "g_alignment", "g_greed", "g_fear", "g_aggression",
    "g_curiosity", "g_speed", "g_vision", "g_size", "g_metabolism",
    "target_food", "age", "fight_timer", "fight_cooldown",
]

const FOOD_COLUMNS = String[
    "schema_version", "run_id", "tick", "food_id",
    "pos_x", "pos_y", "pos_z", "amount",
]

const INTERVENTION_COLUMNS = String[
    "schema_version", "run_id", "tick", "order_index", "command", "result",
]

const FRAME_COLUMNS = String["schema_version", "run_id", "tick", "frame_file", "width", "height"]

# ----- formatting (deterministic, locale-independent) -----

"Format a value for CSV. Julia's number printing is always '.'-decimal and
deterministic across platforms, so this is locale-independent by construction."
fmt(x::Integer)     = string(x)
fmt(x::AbstractFloat) = string(x)
fmt(x::Bool)        = x ? "true" : "false"
fmt(x::AbstractString) = x
fmt(::Nothing)      = ""
fmt(x::Vec3)        = string(x[1])   # unused fallback
fmt(v::Tuple)       = join(fmt.(v), " ")

# ----- cumulative event accumulator -----

mutable struct RunCounters
    panic_cum::Int
    fight_cum::Int
    food_dep_cum::Int
    frag_cum::Int
    reconv_cum::Int
    prev_states::Vector{UInt8}
    prev_proxy::Float64
    depleted::Set{UInt32}
end

"Seed the accumulator from the world's initial (pre-step) states."
RunCounters(w::World) =
    RunCounters(0, 0, 0, 0, 0, UInt8[p.state for p in w.pigeons], 0.0, Set{UInt32}())

"""
`build_tick_values!(acc, w, run_id, seed, dt, tick) -> Vector{Any}`

Compute the full per-tick metrics row (in TICK_COLUMNS order) and update the
cumulative event counters in `acc`. Must be called once per tick, after step!.

Event definitions (all algorithmic, all cumulative + per-tick variants):
  - panic_onset   : a pigeon newly enters FLEEING this tick.
  - fight_onset   : a pigeon newly enters FIGHTING this tick.
  - food_depletion: a food's amount reaches <= 0 for the first time.
  - fragmentation : isolated fraction crosses ABOVE FRAG_THRESHOLD.
  - reconvergence : isolated fraction crosses BACK BELOW FRAG_THRESHOLD.

`fragmentation_proxy` = fraction of pigeons with zero neighbors (fully isolated)
within the neighbor radius. `mean_local_density` = mean neighbor count.
`centroid`/`dispersion` = mean position and mean distance to centroid (spread).
"""
function build_tick_values!(acc::RunCounters, w::World, run_id::AbstractString,
        seed::Integer, dt::AbstractFloat, tick::Integer)
    n = length(w.pigeons)
    cfg = w.cfg
    states = UInt8[p.state for p in w.pigeons]

    counts = zeros(Int, 8)
    for s in states
        si = Int(s)
        if 0 <= si <= 7
            counts[si + 1] += 1
        end
    end
    frac = n > 0 ? counts ./ n : zeros(8)

    # Per-pigeon local density (grid was rebuilt during this tick's step!).
    densities = Int[length(query_neighbors(w, i, cfg.neighbor_radius)) for i in 1:n]

    speed = 0.0; hunger = 0.0; tfear = 0.0
    gfear = 0.0; ggreed = 0.0; gcoh = 0.0; gsep = 0.0; gali = 0.0; gagg = 0.0
    cx = 0.0; cy = 0.0; cz = 0.0
    for (i, p) in enumerate(w.pigeons)
        speed  += p.speed
        hunger += p.hunger
        tfear  += p.fear
        gfear  += p.genome.fear
        ggreed += p.genome.greed
        gcoh   += p.genome.cohesion
        gsep   += p.genome.separation
        gali   += p.genome.alignment
        gagg   += p.genome.aggression
        cx += p.pos[1]; cy += p.pos[2]; cz += p.pos[3]
    end
    inv = n > 0 ? 1.0 / n : 0.0
    mean_speed = speed * inv
    mean_hunger = hunger * inv
    mean_tfear = tfear * inv
    mean_gfear = gfear * inv
    mean_ggreed = ggreed * inv
    mean_gcoh = gcoh * inv
    mean_gsep = gsep * inv
    mean_gali = gali * inv
    mean_gagg = gagg * inv
    mean_dens = sum(densities) * inv

    centroid = n > 0 ? Vec3(cx, cy, cz) * Float32(inv) : Vec3(0, 0, 0)
    dispersion = 0.0
    for p in w.pigeons
        dispersion += norm(p.pos - centroid)
    end
    dispersion *= inv

    proxy = n > 0 ? count(==(0), densities) / n : 0.0

    # ----- event onsets vs previous tick -----
    panic_tick = 0; fight_tick = 0
    for i in 1:n
        if states[i] == FLEEING && acc.prev_states[i] != FLEEING
            panic_tick += 1
        end
        if states[i] == FIGHTING && acc.prev_states[i] != FIGHTING
            fight_tick += 1
        end
    end
    acc.panic_cum += panic_tick
    acc.fight_cum += fight_tick

    food_dep_tick = 0
    for f in w.foods
        if f.amount <= 0 && !(f.id in acc.depleted)
            food_dep_tick += 1
            push!(acc.depleted, f.id)
        end
    end
    acc.food_dep_cum += food_dep_tick

    frag_tick = 0; reconv_tick = 0
    if proxy > FRAG_THRESHOLD && acc.prev_proxy <= FRAG_THRESHOLD
        frag_tick = 1; acc.frag_cum += 1
    elseif acc.prev_proxy > FRAG_THRESHOLD && proxy <= FRAG_THRESHOLD
        reconv_tick = 1; acc.reconv_cum += 1
    end
    acc.prev_proxy = proxy
    acc.prev_states = states

    threat = w.threat
    total_food = Float64(sum(f -> max(0.0, f.amount), w.foods))

    vals = Any[
        SCHEMA_VERSION, run_id, tick, seed, Float32(dt * tick), n, length(w.foods), total_food,
        threat !== nothing,
        threat === nothing ? "" : threat[1],
        threat === nothing ? "" : threat[2],
        threat === nothing ? "" : threat[3],
        frac[1], frac[2], frac[3], frac[4], frac[5], frac[6], frac[7], frac[8],
        mean_speed, mean_hunger, mean_tfear,
        mean_gfear, mean_ggreed, mean_gcoh, mean_gsep, mean_gali, mean_gagg,
        mean_dens, centroid[1], centroid[2], centroid[3], dispersion, proxy,
        acc.panic_cum, panic_tick,
        acc.fight_cum, fight_tick,
        acc.food_dep_cum, food_dep_tick,
        acc.frag_cum, frag_tick,
        acc.reconv_cum, reconv_tick,
    ]
    @assert length(vals) == length(TICK_COLUMNS) "tick row width mismatch"
    return vals
end

"Per-pigeon authoritative row (in PIGEON_COLUMNS order)."
function pigeon_values(p::Pigeon, run_id::AbstractString, tick::Integer)
    g = p.genome
    Any[
        SCHEMA_VERSION, run_id, tick, p.id,
        p.pos[1], p.pos[2], p.pos[3], p.vel[1], p.vel[2], p.vel[3],
        p.speed, Int(p.state), Int(p.variant), p.hunger, p.fear, p.energy,
        g.cohesion, g.separation, g.alignment, g.greed, g.fear, g.aggression,
        g.curiosity, g.speed, g.vision, g.size, g.metabolism,
        p.target_food, p.age, p.fight_timer, p.fight_cooldown,
    ]
end

"Per-food row (in FOOD_COLUMNS order)."
function food_values(f::Food, run_id::AbstractString, tick::Integer)
    Any[
        SCHEMA_VERSION, run_id, tick, f.id,
        f.pos[1], f.pos[2], f.pos[3], f.amount,
    ]
end

"Intervention application row (in INTERVENTION_COLUMNS order)."
function intervention_values(run_id::AbstractString, tick::Integer, order::Integer,
        cmd::AbstractString, result)
    Any[SCHEMA_VERSION, run_id, tick, order, cmd, string(result)]
end
