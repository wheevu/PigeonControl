# PigeonControl: canonical UDP binary snapshot (little-endian, Y-up).

const MAGIC = 0x50494345          # "PICE"
const PROTOCOL_VERSION = 0x01
const PROTOCOL_V2 = 0x02

const PIGEON_V1_BYTES = 40
const PIGEON_V2_BYTES = 48
const FOOD_V1_BYTES = 16
const FOOD_V2_BYTES = 20
const ENV_BYTES = 20
const THREAT_BYTES = 16
const STATS_BYTES = 16
const FX_RECORD_BYTES = 20

# State enum (matches the wire contract shared with Godot).
const FLYING    = 0x00
const WALKING   = 0x01
const EATING    = 0x02
const FLEEING   = 0x03
const LANDING   = 0x04
const TAKEOFF   = 0x05
const FIGHTING  = 0x06
const PERCHING  = 0x07

@inline function _pigeon_orientation(p::Pigeon)
    sp = norm(p.vel)
    v  = sp > 1.0f-4 ? p.vel : p.heading
    nn = norm(v) + 1.0f-6
    yaw   = atan(v[1], v[3])
    pitch = asin(clamp(v[2] / nn, -1.0f0, 1.0f0))
    # Sim-owned bank leans turns; fighting uses the ragdoll pose instead.
    roll = hasfield(typeof(p), :bank) ? p.bank : 0.0f0
    fight_active = p.state == FIGHTING || p.fight_timer > 0
    if fight_active
        phase = p.ragdoll_phase
        pitch = 0.8f0 * sin(phase)
        roll  = mod(phase + π, 2π) - π
    end
    return Float32(yaw), Float32(pitch), Float32(roll)
end

"""
`serialize_snapshot(w; version=PROTOCOL_VERSION) -> Vector{UInt8}`

v1 layout (little-endian, default for backward compat):
  Header (20B): magic UInt32, version UInt8, pad 3B, tick UInt32,
                n_pigeons UInt32, n_foods UInt32.
  Pigeon (40B) x N: id UInt32; pos_x/y/z Float32; yaw/pitch/roll Float32;
                     state UInt8; variant UInt8; flap_phase Float32;
                     speed Float32; pad 2B.
  Food (16B) x M: id UInt32; pos_x/y/z Float32.

v2 layout (additive, version=2):
  Header (20B, version 2) + Pigeon (48B) x N: first 40B identical to v1,
  then bank Float32, hunger01 Float32 + Food (20B) x M: v1 plus amount
  Float32 + Env (20B): sun, time_of_day, wind xyz + Threat (16B):
  active UInt8, pad 3B, xyz + Stats (16B): n_fighting, n_fleeing, n_eating
  UInt32, food_left Float32 + fx_count UInt32 + Fx (20B) x K:
  type UInt32, xyz Float32, mag Float32.
"""
function serialize_snapshot(w::World; version::Integer=PROTOCOL_VERSION)
    v = Int(version)
    v == PROTOCOL_VERSION || v == PROTOCOL_V2 ||
        error("serialize_snapshot: unsupported protocol version $version")
    io = IOBuffer()
    write(io, MAGIC)
    write(io, UInt8(v))
    write(io, 0x00); write(io, 0x00); write(io, 0x00)   # 3 pad bytes
    write(io, UInt32(w.tick))
    write(io, UInt32(length(w.pigeons)))
    write(io, UInt32(length(w.foods)))

    for p in w.pigeons
        write(io, UInt32(p.id))
        write(io, Float32(p.pos[1])); write(io, Float32(p.pos[2])); write(io, Float32(p.pos[3]))

        yaw, pitch, roll = _pigeon_orientation(p)
        write(io, Float32(yaw)); write(io, Float32(pitch)); write(io, Float32(roll))

        write(io, UInt8(p.state)); write(io, UInt8(p.variant))
        write(io, Float32(p.flap_phase)); write(io, Float32(p.speed))
        write(io, 0x00); write(io, 0x00)               # 2 pad bytes (reserved, zero)
        if v == PROTOCOL_V2
            bank = hasfield(typeof(p), :bank) ? Float32(p.bank) : Float32(roll)
            write(io, Float32(bank)); write(io, Float32(hunger01(p)))
        end
    end

    for f in w.foods
        write(io, UInt32(f.id))
        write(io, Float32(f.pos[1])); write(io, Float32(f.pos[2])); write(io, Float32(f.pos[3]))
        if v == PROTOCOL_V2
            write(io, Float32(f.amount))
        end
    end

    if v == PROTOCOL_V2
        # Env: sun, time, wind xyz.
        write(io, Float32(w.sun_level)); write(io, Float32(w.time_of_day))
        write(io, Float32(w.wind[1])); write(io, Float32(w.wind[2])); write(io, Float32(w.wind[3]))
        # Threat: active flag plus position.
        if w.threat === nothing
            write(io, UInt8(0x00)); write(io, 0x00); write(io, 0x00); write(io, 0x00)
            write(io, Float32(0)); write(io, Float32(0)); write(io, Float32(0))
        else
            write(io, UInt8(0x01)); write(io, 0x00); write(io, 0x00); write(io, 0x00)
            write(io, Float32(w.threat[1])); write(io, Float32(w.threat[2])); write(io, Float32(w.threat[3]))
        end
        # Stats: fighting, fleeing, eating counts plus food left.
        st = compute_stats(w)
        write(io, UInt32(st.n_fighting)); write(io, UInt32(st.n_fleeing))
        write(io, UInt32(st.n_eating)); write(io, Float32(st.food_left))
        # Fx events, already bounded by FX_CAP.
        nfx = min(length(w.fx), FX_CAP)
        write(io, UInt32(nfx))
        for k in 1:nfx
            e = w.fx[k]
            write(io, UInt32(e.type))
            write(io, Float32(e.pos[1])); write(io, Float32(e.pos[2])); write(io, Float32(e.pos[3]))
            write(io, Float32(e.mag))
        end
    end

    return take!(io)
end

"""
`parse_snapshot(bytes) -> NamedTuple`

Reverse of `serialize_snapshot`; used by tests and debugging clients.
Accepts v1 and v2. Returns `(magic, version, tick, pigeons, foods, env,
threat, stats, fx)` where v1 fills the extended slots with neutral defaults
(bank 0, hunger 0, amount 50, env/threat/stats nothing, fx empty).
"""
function parse_snapshot(bytes::Vector{UInt8})
    io = IOBuffer(bytes)
    magic   = read(io, UInt32)
    magic == MAGIC || error("parse_snapshot: bad magic 0x$(string(magic, base=16))")
    version = read(io, UInt8)
    (version == PROTOCOL_VERSION || version == PROTOCOL_V2) ||
        error("parse_snapshot: unsupported protocol version $version (expected 1 or 2)")
    skip(io, 3)
    tick = read(io, UInt32)
    np   = read(io, UInt32)
    nf   = read(io, UInt32)

    pigeons = Vector{NamedTuple{(:id,:pos,:yaw,:pitch,:roll,:state,:variant,:flap_phase,:speed,:bank,:hunger),
                                Tuple{UInt32,Tuple{Float32,Float32,Float32},Float32,Float32,Float32,UInt8,UInt8,Float32,Float32,Float32,Float32}}}()
    for _ in 1:np
        id     = read(io, UInt32)
        x      = read(io, Float32); y = read(io, Float32); z = read(io, Float32)
        yaw    = read(io, Float32); pitch = read(io, Float32); roll = read(io, Float32)
        state  = read(io, UInt8);   variant = read(io, UInt8)
        flap   = read(io, Float32); speed   = read(io, Float32)
        skip(io, 2)
        bank = 0.0f0
        hunger = 0.0f0
        if version == PROTOCOL_V2
            bank = read(io, Float32); hunger = read(io, Float32)
        end
        push!(pigeons, (id=id, pos=(x, y, z), yaw=yaw, pitch=pitch, roll=roll,
                        state=state, variant=variant, flap_phase=flap, speed=speed,
                        bank=bank, hunger=hunger))
    end

    foods = Vector{NamedTuple{(:id,:pos,:amount),Tuple{UInt32,Tuple{Float32,Float32,Float32},Float32}}}()
    for _ in 1:nf
        id = read(io, UInt32)
        x  = read(io, Float32); y = read(io, Float32); z = read(io, Float32)
        amount = 50.0f0
        if version == PROTOCOL_V2
            amount = read(io, Float32)
        end
        push!(foods, (id=id, pos=(x, y, z), amount=amount))
    end

    env = nothing
    threat = nothing
    stats = nothing
    fx = Vector{NamedTuple{(:type,:pos,:mag),Tuple{UInt32,Tuple{Float32,Float32,Float32},Float32}}}()
    if version == PROTOCOL_V2
        sun = read(io, Float32); tod = read(io, Float32)
        wx = read(io, Float32); wy = read(io, Float32); wz = read(io, Float32)
        env = (sun=sun, time_of_day=tod, wind=(wx, wy, wz))
        tact = read(io, UInt8); skip(io, 3)
        tx = read(io, Float32); ty = read(io, Float32); tz = read(io, Float32)
        threat = tact == 0x01 ? (active=true, pos=(tx, ty, tz)) : nothing
        nf1 = read(io, UInt32); nf2 = read(io, UInt32); nf3 = read(io, UInt32)
        fl = read(io, Float32)
        stats = (n_fighting=nf1, n_fleeing=nf2, n_eating=nf3, food_left=fl)
        nfx = read(io, UInt32)
        for _ in 1:nfx
            ty2 = read(io, UInt32)
            ex = read(io, Float32); ey = read(io, Float32); ez = read(io, Float32)
            mg = read(io, Float32)
            push!(fx, (type=ty2, pos=(ex, ey, ez), mag=mg))
        end
    end

    return (magic=magic, version=version, tick=tick, pigeons=pigeons, foods=foods,
        env=env, threat=threat, stats=stats, fx=fx)
end
