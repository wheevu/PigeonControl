# PigeonControl: per-tick visual stats for HUD, heat, and cameras.
#
# Computed from authoritative state, no RNG. Small fixed layout for the wire.

struct VisualStats
    n_fighting::UInt32
    n_fleeing::UInt32
    n_eating::UInt32
    food_left::Float32
end

function compute_stats(w::World)
    nf = UInt32(0)
    nl = UInt32(0)
    ne = UInt32(0)
    for p in w.pigeons
        s = p.state
        s == FIGHTING && (nf += UInt32(1))
        s == FLEEING && (nl += UInt32(1))
        s == EATING && (ne += UInt32(1))
    end
    left = 0.0f0
    for f in w.foods
        left += f.amount
    end
    return VisualStats(nf, nl, ne, Float32(left))
end
