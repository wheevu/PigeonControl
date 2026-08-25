# Headless PigeonControl: run the flock with no Godot renderer attached.
#
# The Julia core owns all simulation state and steps every pigeon through
# flocking, feeding, and fear. This script drives the same `World` that the UDP
# renderer receives as snapshots, so it is a faithful headless run.
#
# Run from the repo root:
#   julia --project=. examples/headless.jl
#
# Determinism note: the default seed 69420 reproduces "The Great Bread Massacre".
# Same seed, same config, same inputs => same stampede. This script also verifies
# that claim by running twice and comparing final positions.

using PigeonControl
using LinearAlgebra: norm
using Statistics: mean

# Ordered to match the protocol state constants (FLYING = 0x00 ... PERCHING = 0x07).
const STATE_NAMES = ("FLYING", "WALKING", "EATING", "FLEEING",
                     "LANDING", "TAKEOFF", "FIGHTING", "PERCHING")

function simulate(; seed::UInt32 = UInt32(69420), n_pigeons::Int = 2000, steps::Int = 600)
    cfg = SimConfig(seed = seed, n_pigeons = n_pigeons, food_count = 12)
    world = make_world(cfg)
    # Drop a loaf of bread near the plaza center so feeding behavior engages.
    add_bread!(world, 2.5f0, 0.0f0, 0.0f0, 50.0f0)
    for _ in 1:steps
        step!(world)
    end
    return world
end

function summarize(world::World)
    counts = Dict{String,Int}()
    speeds = Float32[]
    hungers = Float32[]
    for p in world.pigeons
        label = STATE_NAMES[p.state + 1]
        counts[label] = get(counts, label, 0) + 1
        push!(speeds, norm(p.vel))
        push!(hungers, p.hunger)
    end
    food_left = sum(f.amount for f in world.foods; init = 0.0f0)
    println("tick:        ", world.tick)
    println("pigeons:     ", length(world.pigeons))
    println("food left:   ", round(food_left, digits = 1))
    println("mean speed:  ", round(mean(speeds), digits = 2))
    println("mean hunger: ", round(mean(hungers), digits = 2))
    println("state mix:   ", sort!(counts))
    return counts
end

# Run twice with the same seed and confirm the flock is identical at the end.
function check_determinism(; seed = UInt32(69420), steps = 300)
    a = simulate(seed = seed, n_pigeons = 500, steps = steps)
    b = simulate(seed = seed, n_pigeons = 500, steps = steps)
    same = all(a.pigeons[i].pos == b.pigeons[i].pos for i in eachindex(a.pigeons))
    println("deterministic: ", same)
    return same
end

world = simulate()
summarize(world)
check_determinism()
