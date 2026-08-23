# PigeonControl: fear / threat-avoidance steering force.

const THREAT_RADIUS = 12.0f0   # pigeons flee threats within this distance
const FEAR_GAIN     = 3.0f0    # repulsion strength multiplier

"""
`fear_force(w, i) -> Vec3`

If `world.threat` is set and within `THREAT_RADIUS`, returns a strong repulsion
away from the threat, scaled by `genome.fear` (cowards flee harder) and by how
close the pigeon is. Otherwise returns the zero vector.
"""
function fear_force(w::World, i::Int)
    w.threat === nothing && return @SVector zeros(Float32, 3)
    p = w.pigeons[i]
    d = p.pos - w.threat
    dist = norm(d)
    dist > THREAT_RADIUS && return @SVector zeros(Float32, 3)
    dist < 1.0f-6 && return @SVector zeros(Float32, 3)
    strength = 1.0f0 - dist / THREAT_RADIUS   # 0 at edge, 1 at center
    return p.genome.fear * FEAR_GAIN * strength * (d / dist)
end
