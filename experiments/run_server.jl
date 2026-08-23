# PigeonControl: UDP snapshot server (experiments entry point).

using PigeonControl
using Sockets

# ----- fragmentation transport -----
# A single UDP datagram is capped (~9216 B on macOS, 65507 B IPv4 max). Large
# snapshots (e.g. 2000 pigeons ~= 80 KB) cannot fit in one datagram, so we split
# them into CHUNK_SIZE-byte fragments with a small envelope. Snapshots that
# already fit are sent verbatim (single PICE packet) for backward compatibility.
const FRAG_MAGIC = 0x46524147
const CHUNK_SIZE = 8000

# Send raw snapshot bytes over an unconnected UDP socket. Fragmentation is
# best-effort: any send error (e.g. no listener yet) is swallowed so the
# simulation never crashes. `fid` groups the fragments of one snapshot for the
# receiver's reassembly.
function send_bytes(sock, ip, port, bytes::Vector{UInt8}, fid::UInt32)
    if length(bytes) <= CHUNK_SIZE
        try; send(sock, ip, port, bytes); catch; end
        return
    end
    n = ceil(Int, length(bytes) / CHUNK_SIZE)
    for i in 0:n-1
        seg = bytes[i*CHUNK_SIZE+1 : min(end, (i+1)*CHUNK_SIZE)]
        io = IOBuffer()
        write(io, UInt32(FRAG_MAGIC))
        write(io, UInt32(fid))
        write(io, UInt16(i))
        write(io, UInt16(n))
        write(io, UInt16(length(seg)))
        write(io, seg)
        try; send(sock, ip, port, take!(io)); catch; end
    end
end

# ----- argument parsing -----
function parse_args()
    args = Dict{String,Any}("seed"=>69420, "n"=>2000, "port"=>5000, "fps"=>60, "duration"=>Inf)
    i = 1
    while i <= length(ARGS)
        a = ARGS[i]
        if a == "--seed" && i+1 <= length(ARGS);      args["seed"]     = parse(Int, ARGS[i+=1]); i+=1
        elseif a == "--n" && i+1 <= length(ARGS);     args["n"]        = parse(Int, ARGS[i+=1]); i+=1
        elseif a == "--port" && i+1 <= length(ARGS);  args["port"]     = parse(Int, ARGS[i+=1]); i+=1
        elseif a == "--fps" && i+1 <= length(ARGS);    args["fps"]      = parse(Int, ARGS[i+=1]); i+=1
        elseif a == "--duration" && i+1 <= length(ARGS); args["duration"] = parse(Float64, ARGS[i+=1]); i+=1
        else; i += 1
        end
    end
    return args
end

function main()
    args = parse_args()
    cfg = SimConfig(seed=UInt32(args["seed"]), n_pigeons=args["n"])
    world = make_world(cfg)
    port = args["port"]
    fps  = args["fps"]
    duration = args["duration"]

    sock = UDPSocket()

    println("PigeonControl server: seed=$(args["seed"]) n=$(args["n"]) -> 127.0.0.1:$port, fps=$fps, duration=$duration")
    println("(Run a renderer/listener on this port; the sim pairs with Godot.)")
    flush(stdout)

    running = true
    start_t = time()
    last = time()
    next_status = time() + 1.0

    try
        while running
            step!(world)
            send_bytes(sock, ip"127.0.0.1", port, serialize_snapshot(world), world.tick)

            if time() >= next_status
                println("tick=$(world.tick) pigeons=$(length(world.pigeons)) foods=$(length(world.foods))")
                flush(stdout)
                next_status = time() + 1.0
            end

            if duration != Inf && (time() - start_t) >= duration
                running = false
                break
            end

            elapsed = time() - last
            sleep(max(0.0, 1.0 / fps - elapsed))
            last = time()
        end
    catch e
        if e isa InterruptException
            println("\nInterrupted; shutting down.")
        else
            rethrow()
        end
    finally
        close(sock)
    end
end

main()
