# PigeonControl visual debug: headless SVG snapshot renderer.
#
# No new dependencies. Reads a live World, serializes v2, parses it back, and
# writes a top-down minimap SVG colored by state. Used in CI to prove the
# visual slice without opening Godot.
#
# Run from the repo root:
#   julia --project=. experiments/visual_debug.jl --out /tmp/pigeon.svg

using PigeonControl

const STATE_COLORS = Dict{UInt8,String}(
    FLYING => "#4a90d9",
    WALKING => "#7ed321",
    EATING => "#f5a623",
    FLEEING => "#d0021b",
    LANDING => "#9013fe",
    TAKEOFF => "#50e3c2",
    FIGHTING => "#ff0080",
    PERCHING => "#8b572a",
)

function parse_cli()
    out = "/tmp/pigeon_visual.svg"
    seed = UInt32(69420)
    n = 500
    steps = 120
    i = 1
    while i <= length(ARGS)
        a = ARGS[i]
        if a == "--out" && i + 1 <= length(ARGS)
            out = ARGS[i+1]; i += 2
        elseif a == "--seed" && i + 1 <= length(ARGS)
            seed = UInt32(parse(Int, ARGS[i+1])); i += 2
        elseif a == "--n" && i + 1 <= length(ARGS)
            n = parse(Int, ARGS[i+1]); i += 2
        elseif a == "--steps" && i + 1 <= length(ARGS)
            steps = parse(Int, ARGS[i+1]); i += 2
        else
            i += 1
        end
    end
    return (; out, seed, n, steps)
end

function world_to_svg(x::Real, z::Real, half::Real, size::Real)
    sx = (Float64(x) + half) / (2half) * size
    sz = (Float64(z) + half) / (2half) * size
    return sx, sz
end

function main()
    opt = parse_cli()
    cfg = SimConfig(seed=opt.seed, n_pigeons=opt.n)
    w = make_world(cfg)
    add_bread!(w, 2.5f0, 0.0f0, 0.0f0, 50.0f0)
    for _ in 1:opt.steps
        step!(w)
    end
    # Round-trip through v2 so the SVG proves the wire, not just memory.
    parsed = parse_snapshot(serialize_snapshot(w; version=PROTOCOL_V2))
    size = 640.0
    half = Float64(w.cfg.arena_half)
    buf = IOBuffer()
    println(buf, """<svg xmlns="http://www.w3.org/2000/svg" width="$(Int(size))" height="$(Int(size))" viewBox="0 0 $(Int(size)) $(Int(size))">""")
    println(buf, """<rect width="100%" height="100%" fill="#1a1d24"/>""")
    # Perches as brown squares.
    for perch in w.perches
        sx, sz = world_to_svg(perch[1], perch[3], half, size)
        println(buf, """<rect x="$(sx-4)" y="$(sz-4)" width="8" height="8" fill="#8b572a" opacity="0.9"/>""")
    end
    # Foods as amber dots scaled by amount.
    for f in parsed.foods
        sx, sz = world_to_svg(f.pos[1], f.pos[3], half, size)
        r = 2.0 + 4.0 * clamp(Float64(f.amount) / 50.0, 0.0, 1.0)
        println(buf, """<circle cx="$sx" cy="$sz" r="$r" fill="#f5a623" opacity="0.9"/>""")
    end
    # Threat as a red ring.
    if parsed.threat !== nothing
        tx, tz = parsed.threat.pos[1], parsed.threat.pos[3]
        sx, sz = world_to_svg(tx, tz, half, size)
        println(buf, """<circle cx="$sx" cy="$sz" r="18" fill="none" stroke="#d0021b" stroke-width="2"/>""")
    end
    # Pigeons colored by state, fighters larger.
    for p in parsed.pigeons
        sx, sz = world_to_svg(p.pos[1], p.pos[3], half, size)
        color = get(STATE_COLORS, p.state, "#ffffff")
        r = p.state == FIGHTING ? 3.4 : 2.0
        println(buf, """<circle cx="$sx" cy="$sz" r="$r" fill="$color" opacity="0.85"/>""")
    end
    # Fx events as white crosses.
    for e in parsed.fx
        sx, sz = world_to_svg(e.pos[1], e.pos[3], half, size)
        println(buf, """<circle cx="$sx" cy="$sz" r="4.5" fill="none" stroke="#ffffff" stroke-width="1" opacity="0.7"/>""")
    end
    st = parsed.stats
    println(buf, """<text x="10" y="20" fill="#ffffff" font-family="monospace" font-size="13">tick $(parsed.tick)  fight $(st.n_fighting)  flee $(st.n_fleeing)  eat $(st.n_eating)</text>""")
    println(buf, "</svg>")
    open(opt.out, "w") do fh
        write(fh, String(take!(buf)))
    end
    println("visual_debug: tick=$(parsed.tick) pigeons=$(length(parsed.pigeons)) foods=$(length(parsed.foods)) fx=$(length(parsed.fx)) -> $(opt.out)")
end

main()
