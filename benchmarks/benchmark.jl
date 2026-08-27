using PigeonControl

function benchmark(; n=2000, steps=120, seed=UInt32(69420))
    cfg = SimConfig(n_pigeons=n, seed=seed)
    world = make_world(cfg)
    # Compile before timing so the reported loop measures simulation work.
    step!(world)
    world = make_world(cfg)
    elapsed = @elapsed for _ in 1:steps
        step!(world)
    end
    rate = steps / elapsed
    println("n=$n steps=$steps seconds=$(round(elapsed; digits=4)) steps_per_second=$(round(rate; digits=2))")
    return rate
end

if abspath(PROGRAM_FILE) == @__FILE__
    benchmark()
end
