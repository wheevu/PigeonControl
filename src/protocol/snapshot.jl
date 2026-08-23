# PigeonControl: canonical UDP binary snapshot (little-endian, Y-up).

const MAGIC = 0x50494345          # "PICE"
const PROTOCOL_VERSION = 0x01

# State enum (matches the wire contract shared with Godot).
const FLYING    = 0x00
const WALKING   = 0x01
const EATING    = 0x02
const FLEEING   = 0x03
const LANDING   = 0x04
const TAKEOFF   = 0x05
const FIGHTING  = 0x06
const PERCHING  = 0x07

"""
`serialize_snapshot(w) -> Vector{UInt8}`

Layout (little-endian):
  Header (20B): magic UInt32, version UInt8, pad 3B, tick UInt32,
                n_pigeons UInt32, n_foods UInt32.
  Pigeon (40B) x N: id UInt32; pos_x/y/z Float32; yaw/pitch/roll Float32;
                     state UInt8; variant UInt8; flap_phase Float32;
                     speed Float32; pad 2B.
  Food (16B) x M: id UInt32; pos_x/y/z Float32.
"""
function serialize_snapshot(w::World)
    io = IOBuffer()
    write(io, MAGIC)
    write(io, UInt8(PROTOCOL_VERSION))
    write(io, 0x00); write(io, 0x00); write(io, 0x00)   # 3 pad bytes
    write(io, UInt32(w.tick))
    write(io, UInt32(length(w.pigeons)))
    write(io, UInt32(length(w.foods)))

    for p in w.pigeons
        write(io, UInt32(p.id))
        write(io, Float32(p.pos[1])); write(io, Float32(p.pos[2])); write(io, Float32(p.pos[3]))

        sp = norm(p.vel)
        v  = sp > 1.0f-4 ? p.vel : p.heading
        nn = norm(v) + 1.0f-6
        yaw   = atan(v[1], v[3])
        pitch = asin(clamp(v[2] / nn, -1.0f0, 1.0f0))
        roll  = 0.0f0
        write(io, Float32(yaw)); write(io, Float32(pitch)); write(io, Float32(roll))

        write(io, UInt8(p.state)); write(io, UInt8(p.variant))
        write(io, Float32(p.flap_phase)); write(io, Float32(p.speed))
        write(io, 0x00); write(io, 0x00)               # 2 pad bytes
    end

    for f in w.foods
        write(io, UInt32(f.id))
        write(io, Float32(f.pos[1])); write(io, Float32(f.pos[2])); write(io, Float32(f.pos[3]))
    end

    return take!(io)
end

"""
`parse_snapshot(bytes) -> NamedTuple`

Reverse of `serialize_snapshot`; used by tests and debugging clients.
Returns `(magic, version, tick, pigeons, foods)` where each pigeon/food is a
NamedTuple of the decoded fields.
"""
function parse_snapshot(bytes::Vector{UInt8})
    io = IOBuffer(bytes)
    magic   = read(io, UInt32)
    magic == MAGIC || error("parse_snapshot: bad magic 0x$(string(magic, base=16))")
    version = read(io, UInt8)
    skip(io, 3)
    tick = read(io, UInt32)
    np   = read(io, UInt32)
    nf   = read(io, UInt32)

    pigeons = Vector{NamedTuple{(:id,:pos,:yaw,:pitch,:roll,:state,:variant,:flap_phase,:speed),
                                Tuple{UInt32,Tuple{Float32,Float32,Float32},Float32,Float32,Float32,UInt8,UInt8,Float32,Float32}}}()
    for _ in 1:np
        id     = read(io, UInt32)
        x      = read(io, Float32); y = read(io, Float32); z = read(io, Float32)
        yaw    = read(io, Float32); pitch = read(io, Float32); roll = read(io, Float32)
        state  = read(io, UInt8);   variant = read(io, UInt8)
        flap   = read(io, Float32); speed   = read(io, Float32)
        skip(io, 2)
        push!(pigeons, (id=id, pos=(x, y, z), yaw=yaw, pitch=pitch, roll=roll,
                        state=state, variant=variant, flap_phase=flap, speed=speed))
    end

    foods = Vector{NamedTuple{(:id,:pos),Tuple{UInt32,Tuple{Float32,Float32,Float32}}}}()
    for _ in 1:nf
        id = read(io, UInt32)
        x  = read(io, Float32); y = read(io, Float32); z = read(io, Float32)
        push!(foods, (id=id, pos=(x, y, z)))
    end

    return (magic=magic, version=version, tick=tick, pigeons=pigeons, foods=foods)
end
