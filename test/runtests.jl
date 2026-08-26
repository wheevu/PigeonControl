using Test
using PigeonControl
using StableRNGs
using LinearAlgebra

include("control_tests.jl")

@testset "T1 stability / bounds" begin
    cfg = SimConfig(seed=UInt32(1), n_pigeons=200)
    w = make_world(cfg)
    for _ in 1:300
        step!(w)
    end
    for p in w.pigeons
        @test all(isfinite, p.pos)
        @test -0.5f0 <= p.pos[2] <= w.cfg.max_height + 0.5f0
        # Account for the archetype speed cap (max_speed * 3.0); still tight
        # enough to catch a runaway integrator.
        @test p.speed <= w.cfg.max_speed * 3.0f0 * 1.05f0 + 1.0f-3
    end
end

@testset "T2 determinism" begin
    function run_seq(seed, n, steps)
        w = make_world(SimConfig(seed=UInt32(seed), n_pigeons=n))
        for _ in 1:steps
            step!(w)
        end
        return [p.pos for p in w.pigeons]
    end
    a = run_seq(42, 100, 50)
    b = run_seq(42, 100, 50)
    @test a == b
end

@testset "T3 serialization contract" begin
    n = 150
    f = 10
    cfg = SimConfig(seed=UInt32(7), n_pigeons=n, food_count=f)
    w = make_world(cfg)
    bytes = serialize_snapshot(w)
    @test length(bytes) == 20 + 40*n + 16*f
    parsed = parse_snapshot(bytes)
    @test parsed.magic == MAGIC
    @test parsed.tick == w.tick
    @test length(parsed.pigeons) == n
    @test length(parsed.foods) == f
    @test parsed.pigeons[1].id == w.pigeons[1].id
    @test Float32(parsed.pigeons[1].pos[1]) == w.pigeons[1].pos[1]
    @test Float32(parsed.pigeons[1].pos[2]) == w.pigeons[1].pos[2]
    @test Float32(parsed.foods[1].pos[2])   == w.foods[1].pos[2]
end

@testset "T4 food eating" begin
    cfg = SimConfig(seed=UInt32(3), n_pigeons=1, food_count=0)
    w = make_world(cfg)
    push!(w.foods, Food(UInt32(1), w.pigeons[1].pos, 50.0f0))
    before = w.foods[1].amount
    h_before = w.pigeons[1].hunger
    step!(w)
    @test (w.foods[1].amount < before) || (w.pigeons[1].hunger < h_before)
end

@testset "T5 threat fear" begin
    cfg = SimConfig(seed=UInt32(5), n_pigeons=1, food_count=0)
    w = make_world(cfg)
    p = w.pigeons[1]
    w.threat = p.pos + PigeonControl.Vec3(3.0f0, 0.0f0, 0.0f0)
    step!(w)
    @test w.pigeons[1].state == FLEEING
end

@testset "T6 archetype distribution + immutability" begin
    n = 120
    w = make_world(SimConfig(seed=UInt32(1), n_pigeons=n, food_count=0))
    counts = Dict{UInt8,Int}()
    for p in w.pigeons
        counts[p.variant] = get(counts, p.variant, 0) + 1
    end
    @test counts[PIGEON_COMMON]       == n ÷ 4
    @test counts[PIGEON_CRUMB_GOBLIN] == n ÷ 4
    @test counts[PIGEON_SKY_SCOUT]    == n ÷ 4
    @test counts[PIGEON_BRUISER]      == n ÷ 4

    before = [p.variant for p in w.pigeons]
    for _ in 1:50
        step!(w)
    end
    after = [p.variant for p in w.pigeons]
    @test before == after
end

@testset "T7 genome behavior relationships" begin
    g = Genome(1.0f0, 1.0f0, 1.0f0, 1.0f0, 1.0f0, 1.0f0, 1.0f0, 1.0f0, 1.0f0, 1.0f0, 1.0f0)
    gb  = PigeonControl.apply_variant_bias(g, PIGEON_CRUMB_GOBLIN)
    @test gb.greed      ≈ 1.75f0
    @test gb.metabolism ≈ 1.50f0
    @test gb.speed      ≈ 0.78f0
    gs  = PigeonControl.apply_variant_bias(g, PIGEON_SKY_SCOUT)
    @test gs.fear   ≈ 1.60f0
    @test gs.vision ≈ 1.50f0
    @test gs.speed  ≈ 1.25f0
    gbr = PigeonControl.apply_variant_bias(g, PIGEON_BRUISER)
    @test gbr.aggression ≈ 1.80f0
    @test gbr.size       ≈ 1.35f0
    @test gbr.fear       ≈ 0.55f0
    gc  = PigeonControl.apply_variant_bias(g, PIGEON_COMMON)
    @test gc.greed == g.greed && gc.speed == g.speed

    # per-pigeon speed cap scales with genome.speed and is hard-bounded.
    cfg = SimConfig()
    pfast = Pigeon(1, StableRNG(1), cfg); pfast.genome = Genome(1,1,1,1,1,1,1,2.0,1,1,1)
    pslow = Pigeon(1, StableRNG(1), cfg); pslow.genome = Genome(1,1,1,1,1,1,1,0.5,1,1,1)
    @test PigeonControl.per_pigeon_max_speed(pfast, cfg) ≈
          4.0f0 * PigeonControl.per_pigeon_max_speed(pslow, cfg)
    @test PigeonControl.per_pigeon_max_speed(pfast, cfg) <= cfg.max_speed * 3.0f0 + 1.0f-3

    # threat detection radius scales with vision.
    pv = Pigeon(1, StableRNG(1), cfg); pv.genome = Genome(1,1,1,1,1,1,1,1,1.5,1,1)
    @test PigeonControl.threat_radius(pv) ≈ PigeonControl.THREAT_RADIUS * 1.5f0

    # fight chance scales with aggression and is clamped.
    pa = Pigeon(1, StableRNG(1), cfg); pa.genome = Genome(1,1,1,1,1,2.0,1,1,1,1,1)
    @test PigeonControl.fight_chance(pa) ≈ clamp(0.008f0 * 2.0f0, 0.0f0, 0.05f0)

    # hunger growth scales with metabolism (exact 2x).
    w1 = make_world(SimConfig(seed=UInt32(1), n_pigeons=1, food_count=0))
    w2 = make_world(SimConfig(seed=UInt32(1), n_pigeons=1, food_count=0))
    w1.pigeons[1].genome = Genome(1,1,1,1,1,1,1,1,1,1,1.0)
    w2.pigeons[1].genome = Genome(1,1,1,1,1,1,1,1,1,1,2.0)
    h1 = w1.pigeons[1].hunger; h2 = w2.pigeons[1].hunger
    step!(w1); step!(w2)
    @test (w2.pigeons[1].hunger - h2) ≈ 2.0f0 * (w1.pigeons[1].hunger - h1)
end

@testset "T8 start_fight! direct" begin
    function build_pair(target_size::Float32)
        w = make_world(SimConfig(seed=UInt32(1), n_pigeons=20, food_count=0))
        w.pigeons[1].pos = PigeonControl.Vec3(0, 1, 0)
        w.pigeons[2].pos = PigeonControl.Vec3(1, 1, 0)
        w.pigeons[1].vel = PigeonControl.Vec3(0, 0, 0)
        w.pigeons[2].vel = PigeonControl.Vec3(0, 0, 0)
        w.pigeons[1].variant = PIGEON_COMMON; w.pigeons[2].variant = PIGEON_COMMON
        w.pigeons[1].genome = Genome(1,1,1,1,1,1,1,1,1,1,1)
        w.pigeons[2].genome = Genome(1,1,1,1,1,1,1,1,1,target_size,1)
        return w
    end
    w_small = build_pair(1.0f0)
    w_big   = build_pair(1.35f0)
    ok1 = start_fight!(w_small, 1, 2)
    ok2 = start_fight!(w_big, 1, 2)
    @test ok1 && ok2
    @test w_small.pigeons[2].state == FIGHTING && w_big.pigeons[2].state == FIGHTING
    @test w_small.pigeons[2].fight_timer > 0 && w_big.pigeons[2].fight_timer > 0
    @test w_small.pigeons[2].ragdoll_phase > 0 && w_big.pigeons[2].ragdoll_phase > 0
    @test w_small.pigeons[2].vel[2] > 0               # upward lift applied
    @test norm(w_small.pigeons[2].vel) > 0
    # Larger (Bruiser-type) target shrugs off more of the hit.
    @test norm(w_big.pigeons[2].vel) < norm(w_small.pigeons[2].vel)

    # Invalid: same index, or not ready.
    @test start_fight!(w_small, 1, 1) == false
    @test start_fight!(w_small, 1, 2) == false   # already fighting
end

@testset "T8b start_fight! respects attacker reach" begin
    w = make_world(SimConfig(seed=UInt32(1), n_pigeons=20, food_count=0))
    # Common reach is 1.6 m; place the target just beyond it.
    w.pigeons[1].variant = PIGEON_COMMON; w.pigeons[2].variant = PIGEON_COMMON
    w.pigeons[1].genome = Genome(1,1,1,1,1,1,1,1,1,1,1)
    w.pigeons[2].genome = Genome(1,1,1,1,1,1,1,1,1,1,1)
    w.pigeons[1].pos = PigeonControl.Vec3(0, 1, 0)
    w.pigeons[2].pos = PigeonControl.Vec3(1.7f0, 1, 0)
    w.pigeons[1].vel = PigeonControl.Vec3(0, 0, 0)
    w.pigeons[2].vel = PigeonControl.Vec3(0, 0, 0)

    @test start_fight!(w, 1, 2) == false
    @test w.pigeons[1].state != FIGHTING && w.pigeons[2].state != FIGHTING
    @test w.pigeons[1].fight_timer == 0.0f0 && w.pigeons[2].fight_timer == 0.0f0

    # Vertically out of reach is also rejected (full 3D separation).
    w.pigeons[2].pos = PigeonControl.Vec3(0, 5, 0)
    @test start_fight!(w, 1, 2) == false
    @test w.pigeons[1].state != FIGHTING && w.pigeons[2].state != FIGHTING

    # Exact same position is always in reach.
    w.pigeons[2].pos = w.pigeons[1].pos
    @test start_fight!(w, 1, 2) == true
    @test w.pigeons[2].state == FIGHTING && w.pigeons[2].fight_timer > 0
end

@testset "T9 ragdoll integration" begin
    w = make_world(SimConfig(seed=UInt32(1), n_pigeons=20, food_count=0))
    w.pigeons[1].pos = PigeonControl.Vec3(0, 1, 0)
    w.pigeons[2].pos = PigeonControl.Vec3(1, 1, 0)
    w.pigeons[1].vel = PigeonControl.Vec3(0, 0, 0)
    w.pigeons[2].vel = PigeonControl.Vec3(0, 0, 0)
    w.pigeons[1].variant = PIGEON_COMMON; w.pigeons[2].variant = PIGEON_COMMON
    w.pigeons[1].genome = Genome(1,1,1,1,1,1,1,1,1,1,1)
    w.pigeons[2].genome = Genome(1,1,1,1,1,1,1,1,1,1,1)
    start_fight!(w, 1, 2)

    ph0 = w.pigeons[2].ragdoll_phase
    for _ in 1:10
        step!(w)
    end
    @test w.pigeons[2].ragdoll_phase != ph0
    @test w.pigeons[2].state == FIGHTING

    steps = 0
    while w.pigeons[2].fight_timer > 0.0f0 && steps < 500
        step!(w); steps += 1
    end
    @test w.pigeons[2].fight_timer == 0.0f0
    @test w.pigeons[2].fight_cooldown > 0.0f0
    @test all(isfinite, w.pigeons[2].pos)
    @test w.pigeons[2].pos[2] >= 0.0f0
    @test w.pigeons[2].pos[2] <= w.cfg.max_height + 1.0f-3
    @test abs(w.pigeons[2].pos[1]) <= w.cfg.arena_half + 1.0f-3
    @test abs(w.pigeons[2].pos[3]) <= w.cfg.arena_half + 1.0f-3
end

@testset "T10 spontaneous combat (dense, fixed seed)" begin
    function cluster!(w)
        n = length(w.pigeons)
        for k in 1:n
            ang = k * 2.399963f0
            r = 1.5f0 * sqrt(k / n)
            w.pigeons[k].pos = PigeonControl.Vec3(cos(ang) * r, 1.0f0, sin(ang) * r)
            w.pigeons[k].vel = PigeonControl.Vec3(0, 0, 0)
        end
    end
    w = make_world(SimConfig(seed=UInt32(12345), n_pigeons=100, food_count=0))
    cluster!(w)
    found = false
    for _ in 1:900
        step!(w)
        if any(p -> p.fight_timer > 0.0f0 || p.state == FIGHTING, w.pigeons)
            found = true
            break
        end
    end
    @test found
end

@testset "T10b active-fighter cap (n=30 -> cap 3)" begin
    function cluster!(w)
        n = length(w.pigeons)
        for k in 1:n
            ang = k * 2.399963f0
            r = 1.0f0 * sqrt(k / n)
            w.pigeons[k].pos = PigeonControl.Vec3(cos(ang) * r, 1.0f0, sin(ang) * r)
            w.pigeons[k].vel = PigeonControl.Vec3(0, 0, 0)
        end
    end
    # n=30 gives cap floor(Int, 0.1*30)=3. Dense cluster so fights are frequent;
    # prior behavior could overshoot the cap to 4 via paired starts.
    w = make_world(SimConfig(seed=UInt32(424242), n_pigeons=30, food_count=0))
    cluster!(w)
    max_active = 0
    fights_seen = 0
    for _ in 1:2000
        step!(w)
        act = count(p -> p.fight_timer > 0.0f0 || p.state == FIGHTING, w.pigeons)
        max_active = max(max_active, act)
        fights_seen += act
    end
    @test fights_seen > 0                 # scenario actually exercises combat
    @test max_active <= 3                 # never above cap (so at most 3 fighters)
end

@testset "T10c strict cap: no fights at n=10" begin
    # n=10 gives floor(Int, 0.1*10)=1 < 2, so no pair may ever start, neither
    # directly nor spontaneously.
    function cluster!(w)
        n = length(w.pigeons)
        for k in 1:n
            ang = k * 2.399963f0
            r = 1.0f0 * sqrt(k / n)
            w.pigeons[k].pos = PigeonControl.Vec3(cos(ang) * r, 1.0f0, sin(ang) * r)
            w.pigeons[k].vel = PigeonControl.Vec3(0, 0, 0)
        end
    end
    w = make_world(SimConfig(seed=UInt32(424242), n_pigeons=10, food_count=0))
    cluster!(w)
    @test start_fight!(w, 1, 2) == false
    @test w.pigeons[1].state != FIGHTING && w.pigeons[2].state != FIGHTING
    for _ in 1:2000
        step!(w)
        @test !any(p -> p.fight_timer > 0.0f0 || p.state == FIGHTING, w.pigeons)
    end
end

@testset "T10d strict cap on repeated direct starts (n=30 -> cap 3)" begin
    w = make_world(SimConfig(seed=UInt32(9), n_pigeons=30, food_count=0))
    for p in w.pigeons
        p.pos = PigeonControl.Vec3(0, 1, 0)
        p.vel = PigeonControl.Vec3(0, 0, 0)
    end
    # One pair uses two of the three slots; the odd remainder cannot fit another pair.
    ok1 = start_fight!(w, 1, 2)
    @test ok1
    act = count(p -> p.fight_timer > 0.0f0, w.pigeons)
    @test act == 2
    # Second pair must be refused: 2 active + 2 > cap 3.
    ok2 = start_fight!(w, 3, 4)
    @test ok2 == false
    @test w.pigeons[3].state != FIGHTING && w.pigeons[4].state != FIGHTING
    @test count(p -> p.fight_timer > 0.0f0, w.pigeons) == 2
end

@testset "T11 threat suppresses new fights" begin
    function cluster!(w)
        n = length(w.pigeons)
        for k in 1:n
            ang = k * 2.399963f0
            r = 1.5f0 * sqrt(k / n)
            w.pigeons[k].pos = PigeonControl.Vec3(cos(ang) * r, 1.0f0, sin(ang) * r)
            w.pigeons[k].vel = PigeonControl.Vec3(0, 0, 0)
        end
    end
    w = make_world(SimConfig(seed=UInt32(777), n_pigeons=80, food_count=0))
    cluster!(w)
    w.threat = PigeonControl.Vec3(0, 1, 0)
    any_fight = false
    for _ in 1:300
        step!(w)
        if any(p -> p.fight_timer > 0.0f0 || p.state == FIGHTING, w.pigeons)
            any_fight = true
            break
        end
    end
    @test !any_fight
end

@testset "T12 determinism with states/variants/timers" begin
    function snap(seed)
        w = make_world(SimConfig(seed=UInt32(seed), n_pigeons=50, food_count=0))
        for _ in 1:120
            step!(w)
        end
        return [(p.id, p.variant, p.state, p.fight_timer,
                 (p.pos[1], p.pos[2], p.pos[3])) for p in w.pigeons]
    end
    @test snap(99) == snap(99)
end
