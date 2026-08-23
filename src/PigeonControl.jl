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
include("spatial/grid.jl")       # SpatialGrid
include("world.jl")              # Food, SimConfig, World, make_world, step!, boundary_steer
include("spatial/queries.jl")    # nearest_food, nearest_threat, query_neighbors
include("behavior/flocking.jl")  # boids_force
include("behavior/feeding.jl")   # food_force
include("behavior/fear.jl")      # fear_force
include("behavior/decision.jl")  # update_state!
include("protocol/snapshot.jl")  # MAGIC, PROTOCOL_VERSION, state consts, serialize/parse
include("protocol/control.jl")    # apply_command! and control-channel helpers

# ----- required exports -----
export World, Pigeon, Food, Genome, SimConfig
export make_world, step!, serialize_snapshot, parse_snapshot
export MAGIC, PROTOCOL_VERSION
export FLYING, WALKING, EATING, FLEEING, LANDING, TAKEOFF, FIGHTING, PERCHING
export SpatialGrid, build!, neighbors
export nearest_food, nearest_threat, query_neighbors
export boids_force, food_force, fear_force, update_state!, boundary_steer
export apply_command!, add_bread!, spawn_human!, clear_human!, kill_the_sun!

end # module
