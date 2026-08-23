# PigeonControl: boids (flocking) steering force.

"""
`boids_force(w, i) -> Vec3`

Computes the combined flocking steering vector for pigeon `i`:
  - separation: average of normalized away-vectors from near neighbors
    (within `sep_radius`), weighted by 1/dist.
  - alignment: steer toward the average neighbor velocity.
  - cohesion: steer toward the average neighbor position.

Each component is scaled by the pigeon's genome multiplier. Returns the zero
vector when the pigeon has no neighbors.
"""
function boids_force(w::World, i::Int)
    p = w.pigeons[i]
    ns = query_neighbors(w, i, w.cfg.neighbor_radius)
    isempty(ns) && return @SVector zeros(Float32, 3)

    sep = @SVector zeros(Float32, 3)
    ali = @SVector zeros(Float32, 3)
    coh = @SVector zeros(Float32, 3)
    n = 0
    for j in ns
        q = w.pigeons[j]
        d = p.pos - q.pos
        dist = norm(d)
        if dist < w.cfg.sep_radius && dist > 1.0f-6
            sep += (d / dist) / dist   # normalized away-vector, weighted 1/dist
        end
        ali += q.vel
        coh += q.pos
        n += 1
    end
    ali = ali / n
    ali = ali - p.vel            # steer toward average neighbor velocity
    coh = coh / n
    coh = coh - p.pos            # steer toward average neighbor position

    g = p.genome
    return g.separation * sep + g.alignment * ali + g.cohesion * coh
end
