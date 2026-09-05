# PigeonControl: banking from lateral steering.
#
# Bank is sim state, not a render guess. Derived from the lateral component
# of the steering force against the pigeon's right axis.

@inline function update_bank!(p::Pigeon, force::Vec3)
    up = @SVector Float32[0.0f0, 1.0f0, 0.0f0]
    h = p.heading
    # Right axis, guarded when heading is vertical.
    r = cross(h, up)
    n = norm(r)
    n < 1.0f-4 && return 0.0f0
    r = r / n
    lateral = dot(force, r)
    bank = clamp(-lateral * 0.03f0, -0.6f0, 0.6f0)
    # Ease toward target so turns lean instead of snapping.
    p.bank = p.bank * 0.85f0 + bank * 0.15f0
    return p.bank
end
