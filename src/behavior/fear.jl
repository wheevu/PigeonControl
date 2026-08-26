# PigeonControl: fear / threat-avoidance steering force.

const THREAT_RADIUS = 12.0f0   # base pigeon threat detection radius
const FEAR_GAIN     = 3.0f0    # repulsion strength multiplier

"""
`threat_radius(p) -> Float32`

Effective threat detection / fear-response radius for a pigeon, scaled by its
`genome.vision`. A sharper-eyed bird senses and reacts to threats from farther
away.
"""
threat_radius(p::Pigeon) = THREAT_RADIUS * p.genome.vision

"""
`fear_force(w, i) -> Vec3`

If `world.threat` is set and within `threat_radius(p)`, returns a strong
repulsion away from the threat, scaled by `genome.fear` (cowards flee harder)
and by how close the pigeon is. Otherwise returns the zero vector.
"""
function fear_force(w::World, i::Int)
    w.threat === nothing && return @SVector zeros(Float32, 3)
    p = w.pigeons[i]
    r = threat_radius(p)
    d = p.pos - w.threat
    dist = norm(d)
    dist > r && return @SVector zeros(Float32, 3)
    dist < 1.0f-6 && return @SVector zeros(Float32, 3)
    strength = 1.0f0 - dist / r   # 0 at edge, 1 at center
    return p.genome.fear * FEAR_GAIN * strength * (d / dist)
end
