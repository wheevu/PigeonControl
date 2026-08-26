# PigeonControl: fragmentation transport for large UDP snapshots.
#
# Shared by the live server (run_server.jl) and the observer capture handshake so
# both emit byte-identical envelopes (backward compatible with the Godot client).
# A single UDP datagram is capped (~9216 B on macOS, 65507 B IPv4 max). Large
# snapshots (e.g. dense flocks) cannot fit in one datagram, so they are split into
# CHUNK_SIZE-byte fragments with a small envelope. Snapshots that already fit are
# sent verbatim (single PICE packet) for backward compatibility.

const FRAG_MAGIC = 0x46524147
const CHUNK_SIZE = 8000

"""
`send_bytes(sock, ip, port, bytes::Vector{UInt8}, fid::UInt32)`

Send raw snapshot bytes over an unconnected UDP socket. Snapshots that fit in a
single datagram are sent verbatim. Larger snapshots are split into CHUNK_SIZE-byte
fragments wrapped in this envelope:

    FRAG_MAGIC UInt32 | fid UInt32 | idx UInt16 | total UInt16 | len UInt16 | payload

Best-effort: any send error (e.g. no listener yet) is swallowed so the
simulation never blocks or crashes. `fid` groups the fragments of one snapshot
for the receiver's reassembly.
"""
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
