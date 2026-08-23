using Test
using PigeonControl
using StableRNGs

@testset "T1 stability / bounds" begin
    cfg = SimConfig(seed=UInt32(1), n_pigeons=200)
    w = make_world(cfg)
    for _ in 1:300
        step!(w)
    end
    for p in w.pigeons
        @test all(isfinite, p.pos)
        @test -0.5f0 <= p.pos[2] <= w.cfg.max_height + 0.5f0
        @test p.speed <= w.cfg.max_speed * 1.05f0 + 1.0f-3
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
