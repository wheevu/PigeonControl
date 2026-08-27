# PigeonControl: world-level spatial queries.

"""
Return (index, distance) of the nearest food within `radius` of `pos`,
or `nothing` if none.
"""
function nearest_food(world::World, pos::Vec3, radius::Float32)
    best = -1
    best_d2 = radius * radius
    for (i, f) in enumerate(world.foods)
        d = pos - f.pos
        d2 = dot(d, d)
        if d2 <= best_d2
            best_d2 = d2
            best = i
        end
    end
    best == -1 ? nothing : (best, sqrt(best_d2))
end

"""
Return (threat_position, distance) if `world.threat` is set and within `radius`,
or `nothing` otherwise.
"""
function nearest_threat(world::World, pos::Vec3, radius::Float32)
    world.threat === nothing && return nothing
    d = pos - world.threat
    dist = norm(d)
    dist <= radius ? (world.threat, dist) : nothing
end

"""
Return indices of pigeons within `radius` of pigeon `i` (excluding `i`).
"""
function query_neighbors(world::World, i::Int, radius::Float32)
    p = world.pigeons[i]
    out = Int[]
    r2 = radius * radius
    key = cell_key(world.grid, p.pos)
    for dx in -1:1, dy in -1:1, dz in -1:1
        bucket = get(world.grid.buckets,
            (key[1] + dx, key[2] + dy, key[3] + dz), nothing)
        bucket === nothing && continue
        for idx in bucket
            idx == i && continue
            d = p.pos - world.pigeons[idx].pos
            if dot(d, d) <= r2
                push!(out, idx)
            end
        end
    end
    return out
end
