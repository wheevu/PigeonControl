# PigeonControl: deterministic visual FX events.
#
# Julia owns when and where every transient visual happens. Godot only draws
# each event with a TTL. The queue is a bounded ring cleared at the start of
# every step! so the wire stays small and deterministic.

const FX_FEATHER  = UInt32(1)   # feather puff on fight start
const FX_DUST     = UInt32(2)   # dust on landing / ground bounce
const FX_GOBBLE   = UInt32(3)   # crumb gobble spark
const FX_GUST     = UInt32(4)   # takeoff gust
const FX_BURST    = UInt32(5)   # fight impact burst
const FX_DROPPING = UInt32(6)   # dropping while airborne

const FX_CAP = 64

struct FxEvent
    type::UInt32
    pos::Vec3
    mag::Float32
end

@inline hunger01(p::Pigeon) = clamp(p.hunger * 0.2f0, 0.0f0, 1.0f0)
