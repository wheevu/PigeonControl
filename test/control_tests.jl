using Test
using PigeonControl

@testset "T6 control channel" begin
    # DROP_BREAD count + geometry
    w = make_world(SimConfig(seed=2, n_pigeons=5, food_count=0))
    @test apply_command!(w, "DROP_BREAD 0 0 0 5") == :ok
    @test length(w.foods) == 5
    for f in w.foods
        @test sqrt(f.pos[1]^2 + f.pos[3]^2) <= 1.5f0 + 1.0f-3
        @test f.pos[2] >= 0.2f0
        @test f.amount == 50.0f0
    end

    # DROP_BREAD clamp high (9999 -> 200)
    @test apply_command!(w, "DROP_BREAD 1 1 1 9999") == :ok
    @test length(w.foods) == 5 + 200

    # SPAWN_HUMAN sets threat
    @test apply_command!(w, "SPAWN_HUMAN 3 0 4") == :ok
    @test w.threat == PigeonControl.Vec3(3.0f0, 0.0f0, 4.0f0)

    # CLEAR_HUMAN clears threat
    @test apply_command!(w, "CLEAR_HUMAN") == :ok
    @test w.threat === nothing

    # KILL_THE_SUN is a no-op returning :ok, world unchanged
    foods_before = length(w.foods)
    @test apply_command!(w, "KILL_THE_SUN") == :ok
    @test length(w.foods) == foods_before

    # UNKNOWN command returns :unknown and does not mutate
    before = length(w.foods)
    @test apply_command!(w, "NOTACOMMAND 1 2 3") == :unknown
    @test length(w.foods) == before

    # EMPTY command returns :empty
    @test apply_command!(w, "   ") == :empty

    # DETERMINISM: identical inputs -> identical outputs
    function run_seq()
        ww = make_world(SimConfig(seed=2, n_pigeons=5, food_count=0))
        apply_command!(ww, "DROP_BREAD 0 0 0 10")
        apply_command!(ww, "SPAWN_HUMAN 2 0 2")
        return [f.pos for f in ww.foods], ww.threat
    end
    a_foods, a_threat = run_seq()
    b_foods, b_threat = run_seq()
    @test a_foods == b_foods
    @test a_threat == b_threat
end
