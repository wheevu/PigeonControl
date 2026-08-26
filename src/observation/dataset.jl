# PigeonControl: raw run orchestration and CSV/TOML writers.
#
# generate_run is the single entry point. It:
#   1. computes a deterministic run_id = "<scenario>_<seed>" and refuses to
#      overwrite either the final dir or a leftover .partial staging dir;
#   2. writes everything into <output>/<run_id>.partial;
#   3. stages raw_run.toml with complete=false, then on success rewrites it with
#      complete=true and atomically renames .partial -> <run_id>;
#   4. applies ordered interventions, steps the world, records authoritative rows,
#      and (only when frames mode is on and the tick is sampled) performs the
#      capture handshake.

const CAPTURE_MAX_FRAMES = 2000

"Best-effort git commit short hash (empty string if unavailable)."
function _git_commit_short()
    try
        repo = dirname(dirname(@__DIR__))   # .../PigeonControl
        return readchomp(`git -C $repo rev-parse --short HEAD`)
    catch
        return ""
    end
end

function _write_csv_header(io, cols)
    println(io, join(cols, ','))
end

function _write_csv_row(io, values)
    println(io, join((fmt(v) for v in values), ','))
end

"""
`write_manifest(dir, run_id, scenario, seed, n, steps, sample_every, dt, frames,
    snapshot_port, ack_port, session_id, timeout; complete)`

Emit raw_run.toml by hand (no TOML dependency). Records the schema version, the
complete flag, run parameters, capture flags/ports, the simulator identity, and a
documented variable-class dictionary.
"""
function write_manifest(dir, run_id, scenario, seed, n, steps, sample_every, dt,
        frames, snapshot_port, ack_port, session_id, timeout; complete::Bool)
    path = joinpath(dir, "raw_run.toml")
    open(path, "w") do io
        println(io, "schema_version = $(repr(SCHEMA_VERSION))")
        println(io, "complete = $(complete ? "true" : "false")")
        println(io, "status = $(repr(complete ? "completed" : "partial"))")
        println(io, "run_id = $(repr(run_id))")
        println(io, "seed = $seed")
        println(io, "scenario = $(repr(scenario))")
        println(io, "config_name = $(repr(scenario))")
        println(io, "n = $n")
        println(io, "n_pigeons = $n")
        println(io, "steps = $steps")
        println(io, "sample_every = $sample_every")
        println(io, "sample_cadence = $sample_every")
        println(io, "frame_cadence = $(frames ? sample_every : 0)")
        println(io, "frame_format = \"png\"")
        println(io, "tick_start = $sample_every")
        println(io, "tick_end = $(steps - mod(steps, sample_every))")
        println(io, "dt = $(repr(Float64(dt)))")
        println(io, "simulator = \"PigeonControl\"")
        println(io, "simulator_version = $(repr(SIM_VERSION))")
        println(io, "commit = $(repr(_git_commit_short()))")
        println(io, "capture_enabled = $(frames ? "true" : "false")")
        println(io, "capture_max_frames = $CAPTURE_MAX_FRAMES")
        println(io, "snapshot_port = $snapshot_port")
        println(io, "ack_port = $ack_port")
        println(io, "session_id = $(repr(session_id))")
        println(io, "capture_timeout = $(repr(Float64(timeout)))")
        println(io, "")
        println(io, "[variable_classes]")
        println(io, "positions = \"pos/vel in meters, Y-up, world frame (Float32)\"")
        println(io, "states = \"FLYING=0 WALKING=1 EATING=2 FLEEING=3 LANDING=4 TAKEOFF=5 FIGHTING=6 PERCHING=7\"")
        println(io, "genome = \"11 Genome fields; fear and greed are privileged scenario targets\"")
        println(io, "transient_fear = \"per-pigeon runtime fear (Pigeon.fear), recorded not edited\"")
        println(io, "events = \"panic/fight/food-depletion/fragmentation/reconvergence, cumulative + per-tick\"")
        println(io, "fragmentation_proxy = \"fraction of pigeons with zero neighbors within neighbor_radius\"")
    end
end

"""
`generate_run(; output, scenario, seed, n=nothing, steps=100, sample_every=10,
    frames=false, snapshot_port=5000, ack_port=5001, session_id="", timeout=2.0)`

Generate a complete raw run. See module docs for the staging/atomic-rename and
overwrite-refusal guarantees. Returns the final run directory path.
"""
function generate_run(; output::AbstractString, scenario::AbstractString,
        seed::Integer, n::Union{Int,Nothing}=nothing,
        steps::Int=100, sample_every::Int=10,
        frames::Bool=false, snapshot_port::Integer=5000, ack_port::Integer=5001,
        session_id::AbstractString="", timeout::Real=2.0)
    scenario in SCENARIO_NAMES || error("unknown scenario: $scenario")
    steps >= 1 || error("steps must be >= 1")
    sample_every >= 1 || error("sample_every must be >= 1")

    run_id = "$(scenario)_$(seed)"
    mkpath(output)
    final_dir = joinpath(output, run_id)
    staging   = final_dir * ".partial"

    isdir(final_dir) && error("refuse overwrite: $final_dir already exists")
    isdir(staging)   && error("refuse overwrite: staging $staging already exists")
    mkpath(staging)
    frames && mkpath(joinpath(staging, "frames"))

    if frames
        expected = ceil(Int, steps / sample_every)
        expected > CAPTURE_MAX_FRAMES &&
            error("capture rejected: would produce $expected frames (> $CAPTURE_MAX_FRAMES)")
    end

    world, schedule = build_scenario(scenario, UInt32(seed); n_override=n)
    n_pigeons = length(world.pigeons)
    dt = world.cfg.dt

    write_manifest(staging, run_id, scenario, seed, n_pigeons, steps, sample_every, dt,
        frames, snapshot_port, ack_port, session_id, timeout; complete=false)

    tick_io = open(joinpath(staging, "ticks.csv"), "w")
    pig_io  = open(joinpath(staging, "pigeons.csv"), "w")
    food_io = open(joinpath(staging, "foods.csv"), "w")
    int_io  = open(joinpath(staging, "interventions.csv"), "w")
    frm_io  = open(joinpath(staging, "frame_index.csv"), "w")

    _write_csv_header(tick_io, TICK_COLUMNS)
    _write_csv_header(pig_io, PIGEON_COLUMNS)
    _write_csv_header(food_io, FOOD_COLUMNS)
    _write_csv_header(int_io, INTERVENTION_COLUMNS)
    _write_csv_header(frm_io, FRAME_COLUMNS)

    acc = RunCounters(world)
    cap = frames ? CaptureSession(snapshot_port, ack_port, session_id, timeout) : nothing

    try
        for tick in 1:steps
            # Ordered interventions scheduled for this tick (applied before step!).
            for (idx, (tk, cmd)) in enumerate(schedule)
                if tk == tick
                    res = apply_command!(world, cmd)
                    _write_csv_row(int_io, intervention_values(run_id, tick, idx, cmd, res))
                end
            end

            step!(world)

            # Record the per-tick summary every tick.
            tick_values = build_tick_values!(acc, world, run_id, seed, dt, tick)

            # Full pigeon/food state only on sampled ticks; frame snapshots align.
            sampled = (tick % sample_every == 0)
            if sampled
                _write_csv_row(tick_io, tick_values)
                for p in world.pigeons
                    _write_csv_row(pig_io, pigeon_values(p, run_id, tick))
                end
                for f in world.foods
                    _write_csv_row(food_io, food_values(f, run_id, tick))
                end
                if frames
                    capture_tick!(cap, world, tick)
                    frame_path = "frames/tick_$(lpad(tick, 10, '0')).png"
                    _write_csv_row(frm_io, [SCHEMA_VERSION, run_id, tick, "tick_$(lpad(tick, 10, '0')).png", 1280, 720])
                end
            end
        end
    finally
        close(tick_io); close(pig_io); close(food_io); close(int_io)
        close(frm_io)
        cap !== nothing && close(cap)
    end

    # Success: finalize manifest then atomically publish the run.
    write_manifest(staging, run_id, scenario, seed, n_pigeons, steps, sample_every, dt,
        frames, snapshot_port, ack_port, session_id, timeout; complete=true)
    mv(staging, final_dir; force=false)
    return final_dir
end
