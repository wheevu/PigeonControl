using Test
using PigeonControl
using LinearAlgebra

@testset "T13 v2 round trip" begin
    w = make_world(SimConfig(seed=UInt32(11), n_pigeons=30, food_count=4))
    for _ in 1:20
        step!(w)
    end
    b2 = serialize_snapshot(w; version=2)
    # v2 grows by 8B per pigeon, 4B per food, plus env/threat/stats/fx trailer.
    @test length(b2) >= 20 + 48 * 30 + 20 * length(w.foods) + 20 + 16 + 16 + 4
    p2 = parse_snapshot(b2)
    @test p2.version == PROTOCOL_V2
    @test length(p2.pigeons) == 30
    @test length(p2.foods) == length(w.foods)
    @test p2.env !== nothing
    @test p2.stats !== nothing
    @test p2.pigeons[1].bank == w.pigeons[1].bank
    @test p2.foods[1].amount == w.foods[1].amount
    # v1 still decodes with neutral visual defaults.
    b1 = serialize_snapshot(w)
    @test length(b1) == 20 + 40 * 30 + 16 * length(w.foods)
    p1 = parse_snapshot(b1)
    @test p1.version == PROTOCOL_VERSION
    @test p1.env === nothing
    @test isempty(p1.fx)
end

@testset "T14 env and fx determinism" begin
    function run_seq()
        ww = make_world(SimConfig(seed=UInt32(21), n_pigeons=40, food_count=2))
        for _ in 1:60
            step!(ww)
        end
        b = serialize_snapshot(ww; version=2)
        return parse_snapshot(b)
    end
    a = run_seq()
    b = run_seq()
    @test a.tick == b.tick
    @test [p.pos for p in a.pigeons] == [p.pos for p in b.pigeons]
    @test [(e.type, e.pos) for e in a.fx] == [(e.type, e.pos) for e in b.fx]
    @test a.env == b.env
    @test a.stats == b.stats
    # KILL_THE_SUN latches dusk deterministically.
    w = make_world(SimConfig(seed=UInt32(21), n_pigeons=5, food_count=0))
    @test w.dusk == false
    apply_command!(w, "KILL_THE_SUN")
    @test w.dusk == true
    @test w.sun_level < 0.3f0
end

@testset "T15 perching and banking bounds" begin
    w = make_world(SimConfig(seed=UInt32(31), n_pigeons=50, food_count=0))
    @test length(w.perches) == 8
    for _ in 1:400
        step!(w)
    end
    for p in w.pigeons
        @test isfinite(p.bank)
        @test -0.61f0 <= p.bank <= 0.61f0
    end
    # A slow bird placed on a perch settles into PERCHING.
    q = w.pigeons[1]
    q.pos = w.perches[1] + PigeonControl.Vec3(0.2f0, 0.0f0, 0.0f0)
    q.vel = PigeonControl.Vec3(0, 0, 0)
    q.speed = 0.0f0
    q.fight_timer = 0.0f0
    w.threat = nothing
    update_state!(q, w, false)
    @test q.state == PERCHING
end
