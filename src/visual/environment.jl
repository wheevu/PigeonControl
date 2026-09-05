# PigeonControl: sim-owned atmosphere (sun, time, wind).
#
# Deterministic from tick only, no RNG consumption, so existing trajectories
# stay stable relative to each other and the wire stays reproducible.

function default_perches(::SimConfig)
    # Eight fixed perch points at lamp and bench tops around the plaza.
    # Fixed lattice, no RNG, so make_world stays deterministic.
    return Vec3[
        @SVector(Float32[-18.0, 3.6, -18.0]),
        @SVector(Float32[19.0, 3.6, -19.0]),
        @SVector(Float32[-19.0, 3.6, 19.0]),
        @SVector(Float32[19.0, 3.6, 19.0]),
        @SVector(Float32[-11.5, 1.2, -7.0]),
        @SVector(Float32[11.0, 1.2, -4.0]),
        @SVector(Float32[3.0, 1.2, 15.0]),
        @SVector(Float32[-12.0, 1.2, 9.0]),
    ]
end

function step_env!(w::World)
    cfg = w.cfg
    dt = cfg.dt
    # Slow morning drift, loops every ~10 minutes of sim time.
    w.time_of_day = Float32(mod(w.time_of_day + dt * 0.01, 24.0))
    if !w.dusk
        # Midday default 1.0, gentle sine breathing so light feels alive.
        t = Float32(w.tick) * dt
        w.sun_level = clamp(0.92f0 + 0.08f0 * sin(t * 0.05f0), 0.0f0, 1.0f0)
    end
    # Wind as a slow deterministic OU-style sway, no RNG.
    t = Float32(w.tick) * dt
    wx = 0.6f0 * sin(t * 0.11f0) + 0.3f0 * sin(t * 0.043f0 + 1.7f0)
    wz = 0.6f0 * cos(t * 0.09f0) + 0.3f0 * cos(t * 0.051f0 + 0.6f0)
    w.wind = @SVector Float32[wx, 0.0f0, wz]
    return nothing
end

function set_dusk!(w::World)
    w.dusk = true
    w.sun_level = 0.22f0
    return nothing
end
