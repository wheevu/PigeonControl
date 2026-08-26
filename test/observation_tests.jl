# PigeonControl: observation / data-generation tests.
#
# Covers: scenario registry, deterministic worlds, byte-identical dataset rows,
# distinct seeds, algorithmic counters, manifest completion, overwrite refusal,
# capture-disabled path (acceptance #3), and the capture handshake with a stub.

using Test
using PigeonControl
using PigeonControl.Observation: generate_run, build_scenario, list_scenarios,
    SCENARIO_NAMES, SCHEMA_VERSION, RunCounters
using Sockets

const OBSDIR = mktempdir()

"Read a CSV file into (header::Vector{String}, rows::Vector{Vector{String}})."
function read_csv(path)
    lines = readlines(path)
    isempty(lines) && return String[], Vector{String}[]
    header = split(lines[1], ',')
    rows = Vector{String}[]
    for l in lines[2:end]
        isempty(strip(l)) && continue
        push!(rows, split(l, ','))
    end
    return header, rows
end

"Column index in the header (1-based)."
colidx(header, name) = findfirst(==(name), header)

@testset "O1 scenario registry" begin
    names = list_scenarios()
    @test length(names) == 12
    @test Set(names) == Set(SCENARIO_NAMES)
    for n in SCENARIO_NAMES
        @test n in names
    end
end

@testset "O2 every scenario deterministic world" begin
    for name in SCENARIO_NAMES
        function runw(seed)
            w, _ = build_scenario(name, UInt32(seed); n_override=40)
            for _ in 1:15; step!(w); end
            return [p.pos for p in w.pigeons]
        end
        a = runw(11); b = runw(11)
        @test a == b
        @test runw(12) != a
    end
end

@testset "O3 deterministic dataset rows" begin
    for name in ["baseline_flocking", "human_panic"]
        d1 = joinpath(OBSDIR, "r1_$name"); d2 = joinpath(OBSDIR, "r2_$name")
        rm(d1; force=true, recursive=true); rm(d2; force=true, recursive=true)
        generate_run(output=d1, scenario=name, seed=5, n=30, steps=20, sample_every=5)
        generate_run(output=d2, scenario=name, seed=5, n=30, steps=20, sample_every=5)
        rid = "$(name)_5"
        for f in ["raw_run.toml", "ticks.csv", "pigeons.csv", "foods.csv", "interventions.csv"]
            p1 = joinpath(d1, rid, f); p2 = joinpath(d2, rid, f)
            @test isfile(p1) && isfile(p2)
            @test read(p1) == read(p2)
        end
    end
end

@testset "O4 distinct seeds differ" begin
    d3 = joinpath(OBSDIR, "seedA"); d4 = joinpath(OBSDIR, "seedB")
    rm(d3; force=true, recursive=true); rm(d4; force=true, recursive=true)
    generate_run(output=d3, scenario="baseline_flocking", seed=1, n=30, steps=20, sample_every=5)
    generate_run(output=d4, scenario="baseline_flocking", seed=2, n=30, steps=20, sample_every=5)
    @test read(joinpath(d3, "baseline_flocking_1", "ticks.csv")) !=
          read(joinpath(d4, "baseline_flocking_2", "ticks.csv"))
end

@testset "O5 algorithmic counters" begin
    # human_panic must produce panic onsets.
    d = joinpath(OBSDIR, "panic"); rm(d; force=true, recursive=true)
    generate_run(output=d, scenario="human_panic", seed=7, n=50, steps=20, sample_every=5)
    h, rows = read_csv(joinpath(d, "human_panic_7", "ticks.csv"))
    pci = colidx(h, "panic_onset_cum")
    @test pci !== nothing
    panic_found = false
    for r in rows
        if parse(Int, r[pci]) > 0
            panic_found = true; break
        end
    end
    @test panic_found
    # cumulative columns are non-decreasing across ticks.
    for c in ["panic_onset_cum", "fight_onset_cum", "food_depletion_cum",
              "fragmentation_cum", "reconvergence_cum"]
        ci = colidx(h, c)
        vals = [parse(Int, r[ci]) for r in rows]
        @test all(vals[i] <= vals[i+1] for i in 1:length(vals)-1)
    end

    # combat_heavy must produce fight onsets with enough ticks.
    d2 = joinpath(OBSDIR, "combat"); rm(d2; force=true, recursive=true)
    generate_run(output=d2, scenario="combat_heavy_populations", seed=3, n=80, steps=200, sample_every=50)
    h2, rows2 = read_csv(joinpath(d2, "combat_heavy_populations_3", "ticks.csv"))
    fci = colidx(h2, "fight_onset_cum")
    fight_found = false
    for r in rows2
        if parse(Int, r[fci]) > 0
            fight_found = true; break
        end
    end
    @test fight_found

    # schema version present in every ticks row header.
    @test colidx(h, "schema_version") == 1
    @test colidx(h, "run_id") == 2
    @test colidx(h, "tick") == 3
end

@testset "O6 manifest completion" begin
    d = joinpath(OBSDIR, "man"); rm(d; force=true, recursive=true)
    generate_run(output=d, scenario="baseline_flocking", seed=3, n=20, steps=10, sample_every=5)
    toml = read(joinpath(d, "baseline_flocking_3", "raw_run.toml"), String)
    @test occursin("complete = true", toml)
    @test occursin("schema_version = \"$(SCHEMA_VERSION)\"", toml)
    @test occursin("capture_enabled = false", toml)
    @test occursin("[variable_classes]", toml)
end

@testset "O7 refusal to overwrite" begin
    d = joinpath(OBSDIR, "over"); rm(d; force=true, recursive=true)
    generate_run(output=d, scenario="baseline_flocking", seed=9, n=10, steps=5, sample_every=5)
    @test_throws Exception generate_run(output=d, scenario="baseline_flocking",
        seed=9, n=10, steps=5, sample_every=5)
    # Also refuse if a leftover .partial staging dir exists.
    staging = joinpath(d, "baseline_flocking_9.partial")
    mkpath(staging)
    @test_throws Exception generate_run(output=d, scenario="baseline_flocking",
        seed=9, n=10, steps=5, sample_every=5)
    rm(staging; force=true, recursive=true)
end

@testset "O8 capture-disabled path (acceptance #3)" begin
    d = joinpath(OBSDIR, "acc3"); rm(d; force=true, recursive=true)
    generate_run(output=d, scenario="human_panic", seed=7, n=24, steps=12, sample_every=2)
    base = joinpath(d, "human_panic_7")
    for f in ["raw_run.toml", "ticks.csv", "pigeons.csv", "foods.csv", "interventions.csv"]
        @test isfile(joinpath(base, f))
    end
    @test !isdir(joinpath(base, "frames"))   # no frames dir when capture disabled
    h, rows = read_csv(joinpath(base, "ticks.csv"))
    @test length(rows) == 6                   # sampled ticks: 2,4,6,8,10,12
    h2, prows = read_csv(joinpath(base, "pigeons.csv"))
    # sampled ticks: 2,4,6,8,10,12 -> 6 ticks * 24 pigeons
    @test length(prows) == 6 * 24
    @test "pigeon_id" in h2 && "g_fear" in h2
    @test isfile(joinpath(base, "frame_index.csv"))
end

@testset "O9 capture handshake with stub" begin
    port_snap = 5100; port_ack = 5101
    sess = "test-session"
    snap_sock = UDPSocket(); bind(snap_sock, ip"127.0.0.1", port_snap)
    ack_send = UDPSocket()
    # Stub: receive each snapshot, parse its tick from the header, ACK it.
    @async begin
        try
            while true
                data = recv(snap_sock)
                io = IOBuffer(data)
                read(io, UInt32)          # MAGIC
                read(io, UInt8); skip(io, 3)
                tick = read(io, UInt32)
                send(ack_send, ip"127.0.0.1", port_ack, "CAPTURED $sess $tick")
            end
        catch
        end
    end
    d = joinpath(OBSDIR, "cap"); rm(d; force=true, recursive=true)
    generate_run(output=d, scenario="baseline_flocking", seed=1, n=20, steps=10,
        sample_every=5, frames=true, snapshot_port=port_snap, ack_port=port_ack,
        session_id=sess, timeout=2.0)
    base = joinpath(d, "baseline_flocking_1")
    @test isfile(joinpath(base, "frame_index.csv"))
    h, rows = read_csv(joinpath(base, "frame_index.csv"))
    @test length(rows) == 2               # sampled ticks 5 and 10
    @test rows[1][4] == "tick_0000000005.png"
    @test rows[2][4] == "tick_0000000010.png"
    close(snap_sock); close(ack_send)
end

@testset "O10 fragmentation transport byte/envelope" begin
    # Mirror run_server behavior: a payload larger than CHUNK_SIZE fragments with
    # the FRAG_MAGIC envelope; a small payload is sent verbatim.
    using PigeonControl: FRAG_MAGIC, CHUNK_SIZE, send_bytes
    recv_sock = UDPSocket(); bind(recv_sock, ip"127.0.0.1", 5200)
    send_sock = UDPSocket()
    small = rand(UInt8, 100)
    send_bytes(send_sock, ip"127.0.0.1", 5200, small, UInt32(1))
    got = recv(recv_sock)
    @test got == small                  # verbatim (no envelope)
    big = rand(UInt8, CHUNK_SIZE * 2 - 10)  # spans exactly two fragments
    send_bytes(send_sock, ip"127.0.0.1", 5200, big, UInt32(7))
    # Reassemble the two fragments.
    frag1 = recv(recv_sock); frag2 = recv(recv_sock)
    @test length(frag1) > 14 && length(frag2) > 14
    io1 = IOBuffer(frag1)
    @test read(io1, UInt32) == FRAG_MAGIC
    @test read(io1, UInt32) == UInt32(7)
    @test read(io1, UInt16) == 0
    @test read(io1, UInt16) == 2
    close(recv_sock); close(send_sock)
end
