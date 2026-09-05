module PigeonControl

using StaticArrays
using Random
using LinearAlgebra
using StableRNGs
using Sockets

# ----- type alias -----
const Vec3 = SVector{3,Float32}

# ----- include order (dependency order) -----
# NOTE: spatial/grid.jl is loaded before world.jl because `World` carries a
# `grid::SpatialGrid` field, and Julia evaluates struct field types at
# definition time (no forward references). All other cross-file names are
# resolved lazily at call time, so the rest follows the brief's order.
include("pigeon.jl")             # Vec3, Genome, Pigeon
include("visual/fx.jl")          # FxEvent, FX_* consts, hunger01
include("spatial/grid.jl")       # SpatialGrid
include("world.jl")              # Food, SimConfig, World, make_world, step!, boundary_steer
include("spatial/queries.jl")    # nearest_food, nearest_threat, query_neighbors
include("behavior/flocking.jl")  # boids_force
include("behavior/feeding.jl")   # food_force
include("behavior/fear.jl")      # fear_force, threat_radius
include("behavior/combat.jl")     # weapon_spec, start_fight!, trigger_fights!, ragdoll_step!
include("behavior/decision.jl")  # update_state!
include("visual/banking.jl")     # update_bank!
include("visual/environment.jl") # step_env!, default_perches, set_dusk!
include("visual/stats.jl")       # VisualStats, compute_stats
include("protocol/snapshot.jl")  # MAGIC, PROTOCOL_VERSION, state consts, serialize/parse
include("protocol/control.jl")    # apply_command! and control-channel helpers
include("protocol/transport.jl")  # fragmentation send (shared with observer)

# ----- observation / data-generation slice (submodule) -----
include("observation/Observation.jl")

# ----- required exports -----
export World, Pigeon, Food, Genome, SimConfig
export make_world, step!, serialize_snapshot, parse_snapshot
export MAGIC, PROTOCOL_VERSION, PROTOCOL_V2
export FLYING, WALKING, EATING, FLEEING, LANDING, TAKEOFF, FIGHTING, PERCHING
export SpatialGrid, build!, neighbors
export nearest_food, nearest_threat, query_neighbors
export boids_force, food_force, fear_force, update_state!, boundary_steer
export apply_command!, add_bread!, spawn_human!, clear_human!, kill_the_sun!
export PIGEON_COMMON, PIGEON_CRUMB_GOBLIN, PIGEON_SKY_SCOUT, PIGEON_BRUISER
export weapon_spec, start_fight!, trigger_fights!, ragdoll_step!
export fight_chance, per_pigeon_max_speed, threat_radius, apply_variant_bias
export Observation
export send_bytes, FRAG_MAGIC, CHUNK_SIZE
export FxEvent, VisualStats, compute_stats, hunger01, push_fx!
export FX_FEATHER, FX_DUST, FX_GOBBLE, FX_GUST, FX_BURST, FX_DROPPING, FX_CAP
export update_bank!, step_env!, set_dusk!, default_perches
export PIGEON_V1_BYTES, PIGEON_V2_BYTES, FOOD_V1_BYTES, FOOD_V2_BYTES

end # module
