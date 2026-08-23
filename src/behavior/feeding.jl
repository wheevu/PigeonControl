# PigeonControl: food-seeking steering force.

"""
`food_force(w, i) -> Vec3`

Steers pigeon `i` toward the nearest food within `genome.vision *
neighbor_radius`. The steering strength is scaled by `genome.greed`.
Returns the zero vector when no food is in range.
"""
function food_force(w::World, i::Int)
    p = w.pigeons[i]
    radius = p.genome.vision * w.cfg.neighbor_radius
    fi = nearest_food(w, p.pos, radius)
    fi === nothing && return @SVector zeros(Float32, 3)
    idx, _ = fi
    dir = w.foods[idx].pos - p.pos
    dist = norm(dir)
    dist < 1.0f-6 && return @SVector zeros(Float32, 3)
    return p.genome.greed * (dir / dist)
end
