# PigeonControl: frame-mode capture handshake.
#
# Contract (separate UDP ack port, does NOT alter the snapshot wire protocol):
#   - Julia binds `ack_port` and listens for "CAPTURED <session_id> <tick>".
#   - For each sampled tick Julia sends the EXISTING snapshot bytes (via the shared
#     fragmentation transport) to `snapshot_port` and waits for the matching ACK.
#   - Godot may also send "READY <session_id>" once at startup; any message that is
#     not a correctly-addressed CAPTURED is ignored (stale / wrong-session / wrong-tick).
#   - On timeout Julia retries the SAME snapshot up to 3 times, then fails the run.
#   - Capture waiting never calls step! or consumes RNG, so the world is untouched.
#
# Julia does NOT start Godot; it only speaks the documented protocol.

mutable struct CaptureSession
    sock::UDPSocket          # bound to ack_port, receives CAPTURED/READY
    snap_sock::UDPSocket     # sends snapshots to snapshot_port
    snapshot_ip::IPv4
    snapshot_port::Int
    ack_port::Int
    session_id::String
    timeout::Float64
end

function CaptureSession(snapshot_port::Integer, ack_port::Integer,
        session_id::AbstractString, timeout::Real)
    sock = UDPSocket()
    bind(sock, ip"127.0.0.1", ack_port) || error("capture: cannot bind ack_port $ack_port")
    snap_sock = UDPSocket()
    CaptureSession(sock, snap_sock, ip"127.0.0.1", snapshot_port, ack_port,
        String(session_id), Float64(timeout))
end

function Base.close(cap::CaptureSession)
    try; close(cap.sock); catch; end
    try; close(cap.snap_sock); catch; end
end

"Receive one datagram with a wall-clock timeout. Returns bytes or nothing."
function _recv_with_timeout(sock, timeout::Float64)
    ch = Channel{Union{Nothing,Vector{UInt8}}}(1)
    @async begin
        try
            put!(ch, recv(sock))
        catch
            put!(ch, nothing)
        end
    end
    timedwait(() -> isready(ch), timeout)
    isready(ch) ? take!(ch) : nothing
end

"Wait for a CAPTURED message matching session_id and tick. Ignores everything else."
function _recv_capture_ack(cap::CaptureSession, tick::Integer)
    deadline = time() + cap.timeout
    while time() < deadline
        remaining = max(0.01, deadline - time())
        msg = _recv_with_timeout(cap.sock, remaining)
        msg === nothing && return false   # timed out for this attempt
        s = strip(String(msg))
        parts = split(s)
        if length(parts) >= 3 && uppercase(parts[1]) == "CAPTURED"
            sess = parts[2]
            tk = tryparse(Int, parts[3])
            if sess == cap.session_id && tk == tick
                return true
            end
        end
        # READY / wrong session / wrong tick / stale -> keep waiting until deadline
    end
    return false
end

"""
`capture_tick!(cap, world, tick; max_retry=3) -> Bool`

Send the existing snapshot for `tick` and wait for the matching CAPTURED ACK.
Retries the same snapshot up to `max_retry` times, then throws (which aborts the
run). Returns true on success. Does not mutate `world` or the RNG.
"""
function capture_tick!(cap::CaptureSession, world::World, tick::Integer; max_retry::Int=3)
    bytes = serialize_snapshot(world)
    for attempt in 1:max_retry
        send_bytes(cap.snap_sock, cap.snapshot_ip, cap.snapshot_port, bytes, UInt32(tick))
        if _recv_capture_ack(cap, tick)
            return true
        end
    end
    error("capture failed for tick $tick after $max_retry attempts (session=$(cap.session_id))")
end
