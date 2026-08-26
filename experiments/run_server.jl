# PigeonControl: UDP snapshot server (experiments entry point).

using PigeonControl
using Sockets

# Fragmentation transport now lives in src/protocol/transport.jl and is shared
# with the observer (src/observation). It is re-exported by PigeonControl, so the
# server's send path is byte-identical to before (FRAG_MAGIC / CHUNK_SIZE /
# envelope unchanged). See transport.jl.

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

    ctrl = UDPSocket()
    ctrl_ok = false
    try
        bind(ctrl, ip"127.0.0.1", port + 1)
        ctrl_ok = true
    catch e
        println("WARN: control channel bind failed on $(port+1): $e")
    end
    if ctrl_ok
        cmd_channel = Channel{String}(64)
        @async begin
            try
                while true
                    data = recv(ctrl)
                    put!(cmd_channel, String(copy(data)))
                end
            catch
                # socket closed at shutdown; task ends.
            end
        end
        println("(Control channel listening on 127.0.0.1:$(port+1): DROP_BREAD / SPAWN_HUMAN / CLEAR_HUMAN / KILL_THE_SUN)")
    end
    flush(stdout)

    println("PigeonControl server: seed=$(args["seed"]) n=$(args["n"]) -> 127.0.0.1:$port, fps=$fps, duration=$duration")
    println("(Run a renderer/listener on this port; the sim pairs with Godot.)")
    flush(stdout)

    running = true
    start_t = time()
    last = time()
    next_status = time() + 1.0

    try
        while running
            if ctrl_ok
                while isready(cmd_channel)
                    apply_command!(world, take!(cmd_channel))
                end
            end
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
        if ctrl_ok; close(ctrl); end
    end
end

main()
