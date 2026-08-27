# PigeonControl: spatial hash grid over the arena volume.

"""
Uniform spatial hash grid for neighbor queries.
"""
mutable struct SpatialGrid
    cell::Float32
    min::Vec3
    max::Vec3
    buckets::Dict{NTuple{3,Int}, Vector{Int}}
end

# Single external constructor. It accepts either a SimConfig or a World and
# builds from the config fields. Types are not annotated because this file is
# loaded before `world.jl`; the `World` check is resolved at runtime.
function SpatialGrid(x)
    cfg = x isa World ? x.cfg : x
    min = @SVector Float32[-cfg.arena_half, 0.0f0, -cfg.arena_half]
    max = @SVector Float32[ cfg.arena_half, cfg.max_height, cfg.arena_half]
    cell = cfg.neighbor_radius
    return SpatialGrid(cell, min, max, Dict{NTuple{3,Int}, Vector{Int}}())
end

@inline function cell_key(g::SpatialGrid, pos::Vec3)
    cx = Int(floor((pos[1] - g.min[1]) / g.cell))
    cy = Int(floor((pos[2] - g.min[2]) / g.cell))
    cz = Int(floor((pos[3] - g.min[3]) / g.cell))
    return (cx, cy, cz)
end

"""
Rebuild the buckets from the current pigeon positions.
"""
function build!(g::SpatialGrid, pigeons::Vector{Pigeon})
    empty!(g.buckets)
    for i in 1:length(pigeons)
        key = cell_key(g, pigeons[i].pos)
        bucket = get!(g.buckets, key, Int[])
        push!(bucket, i)
    end
    return g
end

"""
Return the set of candidate pigeon indices in the 3x3x3 block of cells around
`pos`. Precise radius filtering is performed by the caller (which has access to
positions); the grid only knows indices.
"""
function neighbors(g::SpatialGrid, pos::Vec3, radius::Float32)
    key = cell_key(g, pos)
    # Cells are disjoint, so concatenating bucket contents cannot duplicate an
    # index. Avoiding a Set here removes a hash allocation from every neighbor
    # query while preserving deterministic bucket order.
    out = Int[]
    for dx in -1:1, dy in -1:1, dz in -1:1
        k = (key[1] + dx, key[2] + dy, key[3] + dz)
        bucket = get(g.buckets, k, nothing)
        bucket === nothing && continue
        for idx in bucket
            push!(out, idx)
        end
    end
    return out
end
