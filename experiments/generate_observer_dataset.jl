# PigeonControl: observer dataset generator (CLI entry point).
#
# Generates an authoritative raw run by driving the Julia simulation only. The
# existing UDP snapshot protocol is unchanged; capture (frame mode) is an optional
# experiment that hands snapshots to a separate Godot ack port.

using PigeonControl
using PigeonControl.Observation: generate_run, SCENARIO_NAMES, SCHEMA_VERSION

function print_help()
    println("""
    generate_observer_dataset.jl - authoritative PigeonControl raw data generator

    USAGE:
      julia --project=. experiments/generate_observer_dataset.jl \\
          --output <dir> --scenario <name> [options]

    REQUIRED:
      --output <dir>        output directory (parent of the run directory)
      --scenario <name>     one of: $(join(SCENARIO_NAMES, ", "))

    OPTIONS (defaults suit a small local run):
      --seed <int>          simulation seed (default 1)
      --n <int>             override scenario default population
      --steps <int>         ticks to simulate (default 100)
      --sample-every <int>  record full pigeon/food state + send a frame every
                            N ticks (default 10)
      --frames              enable Godot capture handshake on separate ack port
      --snapshot-port <int> UDP port Godot listens on for snapshots (default 5000)
      --ack-port <int>      UDP port Julia listens on for CAPTURED (default 5001)
      --session-id <str>    session id echoed in CAPTURED (default "")
      --timeout <float>     capture ACK timeout seconds (default 2.0)
      -h, --help            show this help

    EXAMPLES:
      julia --project=. experiments/generate_observer_dataset.jl \\
          --output /tmp/runs --scenario human_panic --seed 7 --n 24 --steps 12 --sample-every 2

      julia --project=. experiments/generate_observer_dataset.jl \\
          --output /tmp/runs --scenario baseline_flocking --seed 1 --frames \\
          --snapshot-port 5100 --ack-port 5101 --session-id ses1 --steps 30 --sample-every 5

    NOTES:
      - The run directory is <output>/<scenario>_<seed> and is created only after
        a successful run (staged in a .partial dir first). Overwrites are refused.
      - Without --frames, no UDP sockets are opened and Godot is not required.
    """)
end

const KNOWN = Set(["--output", "--scenario", "--seed", "--n", "--steps",
    "--sample-every", "--frames", "--snapshot-port", "--ack-port",
    "--session-id", "--timeout", "--help", "-h"])

function parse_args(args)
    opts = Dict{String,Any}(
        "output" => nothing, "scenario" => nothing, "seed" => 1, "n" => nothing,
        "steps" => 100, "sample-every" => 10, "frames" => false,
        "snapshot-port" => 5000, "ack-port" => 5001, "session-id" => "",
        "timeout" => 2.0,
    )
    i = 1
    while i <= length(args)
        a = args[i]
        if a in ("--help", "-h")
            print_help(); exit(0)
        elseif !(a in KNOWN)
            error("unknown flag: $a")
        end
        needval(name) = begin
            i + 1 <= length(args) || error("flag $name requires a value")
            v = args[i+1]; i += 2; return v
        end
        if a == "--frames"
            opts["frames"] = true; i += 1
        elseif a == "--output";   opts["output"] = needval("--output")
        elseif a == "--scenario"; opts["scenario"] = needval("--scenario")
        elseif a == "--seed";      opts["seed"] = parse(Int, needval("--seed"))
        elseif a == "--n";         opts["n"] = parse(Int, needval("--n"))
        elseif a == "--steps";     opts["steps"] = parse(Int, needval("--steps"))
        elseif a == "--sample-every"; opts["sample-every"] = parse(Int, needval("--sample-every"))
        elseif a == "--snapshot-port"; opts["snapshot-port"] = parse(Int, needval("--snapshot-port"))
        elseif a == "--ack-port";  opts["ack-port"] = parse(Int, needval("--ack-port"))
        elseif a == "--session-id"; opts["session-id"] = needval("--session-id")
        elseif a == "--timeout";   opts["timeout"] = parse(Float64, needval("--timeout"))
        else
            error("unknown flag: $a")
        end
    end
    return opts
end

function main()
    opts = parse_args(ARGS)
    opts["output"] === nothing && (print_help(); error("missing --output"))
    opts["scenario"] === nothing && (print_help(); error("missing --scenario"))

    dir = generate_run(
        output = opts["output"],
        scenario = opts["scenario"],
        seed = opts["seed"],
        n = opts["n"],
        steps = opts["steps"],
        sample_every = opts["sample-every"],
        frames = opts["frames"],
        snapshot_port = opts["snapshot-port"],
        ack_port = opts["ack-port"],
        session_id = opts["session-id"],
        timeout = opts["timeout"],
    )
    println("Wrote raw run: $dir")
end

main()
