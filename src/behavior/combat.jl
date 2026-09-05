# PigeonControl: deterministic autonomous combat + ragdoll physics.

# ----- weapon specs (derived from attacker archetype) -----
# The renderer derives the visual weapon from `variant`; these constants drive
# the authoritative Julia ragdoll-style physics only.
#   reach    : nominal engagement distance (meters)
#   horizontal: horizontal knockback impulse magnitude
#   lift     : upward knockback impulse magnitude
#   duration : fight (ragdoll) duration in seconds
#   spin     : ragdoll rotation rate (rad/s)
struct WeaponSpec
    reach::Float32
    horizontal::Float32
    lift::Float32
    duration::Float32
    spin::Float32
end

function weapon_spec(variant::UInt8)
    if variant == PIGEON_COMMON
        return WeaponSpec(1.6f0, 5.0f0, 2.0f0, 0.65f0, 10.0f0)   # sword
    elseif variant == PIGEON_CRUMB_GOBLIN
        return WeaponSpec(1.4f0, 7.0f0, 3.5f0, 0.90f0, 7.0f0)    # hammer
    elseif variant == PIGEON_SKY_SCOUT
        return WeaponSpec(2.5f0, 4.0f0, 5.0f0, 0.75f0, 12.0f0)   # wand
    else
        return WeaponSpec(3.0f0, 9.0f0, 5.0f0, 1.10f0, 14.0f0)   # bomb (Bruiser)
    end
end

# Probability a scheduled ready bird initiates a fight on a given check. Scales
# with aggression and stays low so fights punctuate rather than dominate.
fight_chance(p::Pigeon) = clamp(0.008f0 * p.genome.aggression, 0.0f0, 0.05f0)

# Per-pigeon speed cap: the archetype's speed gene scales the global max, but is
# clamped to a hard bound so no pigeon (or ragdoll) can run away.
per_pigeon_max_speed(p::Pigeon, cfg::SimConfig) =
    min(cfg.max_speed * p.genome.speed, cfg.max_speed * 3.0f0)

# Strict active-fighter cap: 10% of the population, no minimum. When
# floor(10%) < 2 no pair can ever start.
active_fighter_cap(n::Int) = floor(Int, 0.1 * n)
count_active_fighters(w::World) =
    count(p -> p.fight_timer > 0.0f0, w.pigeons)

"""
`start_fight!(w, attacker_index, target_index) -> Bool`

Validate two distinct, ready pigeons (not fighting, not cooling down) whose
squared full separation is within the attacker's `WeaponSpec.reach`
(exact same-position pairs are always valid), apply a
target impulse (horizontal knockback away from the attacker plus lift) divided by
the target's size, a restrained opposite recoil on the attacker, mark both
FIGHTING with matching nonzero fight timers and ragdoll phases, and return true.
Returns false when the pair is invalid, not ready, or when starting the pair
would exceed the active-fighter cap (`floor(Int, 0.1n)`).
"""
function start_fight!(w::World, a::Int, t::Int)
    n = length(w.pigeons)
    (1 <= a <= n) && (1 <= t <= n) && a != t || return false
    pa = w.pigeons[a]
    pt = w.pigeons[t]
    (pa.fight_timer <= 0.0f0 && pt.fight_timer <= 0.0f0 &&
     pa.fight_cooldown <= 0.0f0 && pt.fight_cooldown <= 0.0f0) || return false

    # Strict active-fighter cap, shared with `trigger_fights!`: both birds must
    # fit under floor(10% of n), so populations with cap < 2 never fight.
    count_active_fighters(w) + 2 > active_fighter_cap(n) && return false

    spec = weapon_spec(pa.variant)

    # Reach precondition (public API): the attacker can only engage inside its
    # weapon's reach, measured as full 3D separation. Same position counts as
    # reachable. Squared distances only.
    dx = pt.pos[1] - pa.pos[1]
    dy = pt.pos[2] - pa.pos[2]
    dz = pt.pos[3] - pa.pos[3]
    d2 = dx * dx + dy * dy + dz * dz
    d2 <= spec.reach * spec.reach || return false

    h = @SVector Float32[dx, 0.0f0, dz]
    hn = norm(h)
    hdir = hn > 1.0f-6 ? h / hn : @SVector Float32[1.0f0, 0.0f0, 0.0f0]

    # Incoming impulse is reduced by the target's size: bigger birds (Bruiser)
    # shrug off more of the hit.
    impulse = (hdir * spec.horizontal + @SVector Float32[0.0f0, spec.lift, 0.0f0]) / pt.genome.size

    pt.vel += impulse
    # Restrained opposite recoil on the attacker.
    pa.vel -= impulse * 0.3f0 / pa.genome.size

    pa.fight_timer = spec.duration
    pt.fight_timer = spec.duration
    pa.ragdoll_phase = 0.01f0
    pt.ragdoll_phase = 0.02f0
    pa.state = FIGHTING
    pt.state = FIGHTING
    pa.bank = 0.0f0
    pt.bank = 0.0f0
    # Sim-owned fight garnish: feather puff plus impact burst at the midpoint.
    mid = (pa.pos + pt.pos) * 0.5f0
    push_fx!(w, FX_FEATHER, mid, 1.0f0)
    push_fx!(w, FX_BURST, mid, spec.horizontal * 0.12f0)
    return true
end

"""
`trigger_fights!(w)`

Bounded, deterministic fight initiation. No new fights start while a human
threat is present. At most the birds satisfying
`(Int(tick) + Int(id)) % 32 == 0` inspect neighbors per tick; ready birds (not
active, not cooling down) roll once against `fight_chance`. Candidates are chosen
by squared distance then id, and the pair is locked immediately on success so it
cannot be double-paired. Candidates outside the attacker's `WeaponSpec.reach`
are filtered out (squared distances) before sorting. Active fighters are capped
strictly at `floor(Int, 0.1n)` (no minimum); a new pair starts only when
there is room for both, so odd caps leave one slot unused.
"""
function trigger_fights!(w::World)
    w.threat !== nothing && return
    cfg = w.cfg
    n = length(w.pigeons)
    n < 2 && return

    cap = active_fighter_cap(n)
    active = count_active_fighters(w)

    for i in 1:n
        # A fight always involves two birds; require room for both so the cap
        # is never exceeded (odd caps simply leave one unused slot).
        active + 2 > cap && break
        p = w.pigeons[i]
        (Int(w.tick) + Int(p.id)) % 32 != 0 && continue
        (p.fight_timer > 0.0f0 || p.fight_cooldown > 0.0f0) && continue

        spec = weapon_spec(p.variant)
        reach2 = spec.reach * spec.reach
        pp = p.pos

        ns = query_neighbors(w, i, cfg.neighbor_radius)
        cands = Int[]
        for j in ns
            q = w.pigeons[j]
            (q.fight_timer > 0.0f0 || q.fight_cooldown > 0.0f0) && continue
            dx = pp[1] - q.pos[1]
            dy = pp[2] - q.pos[2]
            dz = pp[3] - q.pos[3]
            dx * dx + dy * dy + dz * dz <= reach2 || continue
            push!(cands, j)
        end
        isempty(cands) && continue

        # Deterministic candidate selection: nearest squared distance, then id.
        d2(j) = let dp = p.pos - w.pigeons[j].pos; dot(dp, dp); end
        sort!(cands, by = j -> (d2(j), j))
        target = cands[1]

        if rand(w.rng) < fight_chance(p)
            if start_fight!(w, i, target)
                active += 2
            end
        end
    end
    return nothing
end

"""
`ragdoll_step!(w, p, cfg)`

Deterministic ragdoll integration used while `p.fight_timer > 0`. Skip
boids/food/fear; apply gravity, drag, integrate, bounce at the ground (y=0.15,
restitution ~0.45), reflect/damp at the arena X/Z walls, clamp the max height
and speed, advance and wrap the ragdoll phase with the archetype spin, update
heading/speed, and preserve FIGHTING. On expiry, set a ~3s cooldown and let the
next tick resume normal behavior.
"""
function ragdoll_step!(w::World, p::Pigeon, cfg::SimConfig)
    dt = cfg.dt
    g = -9.81f0

    v = p.vel + @SVector Float32[0.0f0, g * dt, 0.0f0]
    drag = 0.4f0
    v = v * max(0.0f0, 1.0f0 - drag * dt)

    pos = p.pos + v * dt

    # Bounce off the ground.
    if pos[2] < 0.15f0
        pos = @SVector Float32[pos[1], 0.15f0, pos[3]]
        if v[2] < 0.0f0
            v = @SVector Float32[v[1], -v[2] * 0.45f0, v[3]]
            v = @SVector Float32[v[1] * 0.8f0, v[2], v[3] * 0.8f0]  # ground friction
            if abs(v[2]) > 1.0f0
                push_fx!(w, FX_DUST, pos, 0.7f0)
            end
        end
    end

    # Clamp max height.
    if pos[2] > cfg.max_height
        pos = @SVector Float32[pos[1], cfg.max_height, pos[3]]
        v = @SVector Float32[v[1], min(v[2], 0.0f0), v[3]]
    end

    # Reflect / damp at the X and Z arena walls.
    for ax in (1, 3)
        if pos[ax] > cfg.arena_half
            pos = setindex(pos, cfg.arena_half, ax)
            v = setindex(v, -v[ax] * 0.5f0, ax)
        elseif pos[ax] < -cfg.arena_half
            pos = setindex(pos, -cfg.arena_half, ax)
            v = setindex(v, -v[ax] * 0.5f0, ax)
        end
    end

    # Hard speed bound.
    smax = cfg.max_speed * 3.0f0
    nv = norm(v)
    if nv > smax
        v = v * (smax / nv)
    end

    p.vel   = v
    p.pos   = pos
    p.speed = Float32(norm(v))
    if nv > 1.0f-5
        p.heading = v / nv
    end

    spec = weapon_spec(p.variant)
    p.ragdoll_phase = Float32(mod(p.ragdoll_phase + spec.spin * dt, 2 * π))
    p.state = FIGHTING

    p.fight_timer -= dt
    if p.fight_timer <= 0.0f0
        p.fight_timer = 0.0f0
        p.fight_cooldown = 3.0f0
    end
    return nothing
end
