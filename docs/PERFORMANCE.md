# Julia performance baseline

`benchmarks/benchmark.jl` warms the simulation, then measures 120 authoritative `step!` calls for four population sizes.

The current development-machine run used Julia 1.12.6 on `arm64-apple-darwin25.4.0` with one Julia thread.

| pigeons | steps/s |
| ---: | ---: |
| 100 | 17,357.76 |
| 500 | 842.10 |
| 1,000 | 501.57 |
| 2,000 | 145.87 |

These are simulation-only numbers after warm-up.
They exclude Godot rendering, UDP transport, and dataset writing.
They are a local baseline, not a cross-machine benchmark.

The first optimization pass removed a per-query hash set and used the concrete `StableRNGs.LehmerRNG` field type.
The first optimized run improved from the previous 59.29 steps/s baseline to 185.47 steps/s.
The latest sweep measured 145.87 steps/s, which shows why repeated runs and machine metadata matter for this small benchmark.

The current `World` remains an array of mutable pigeon structs.
Structure-of-arrays storage and threaded stepping are deliberately not enabled yet because both can change update ordering and therefore the existing deterministic trajectory contract.
They need an explicit equivalence design and regression corpus before implementation.
