# PigeonControl: text control-command parser/executor.
# Commands (one per UDP packet, on the control port = snapshot port + 1):
#   DROP_BREAD x y z amount
#   SPAWN_HUMAN x y z
#   CLEAR_HUMAN
#   KILL_THE_SUN
# apply_command! mutates the World and returns a Symbol: :ok, :empty, :unknown.

function apply_command!(w::World, str::AbstractString)
    s = strip(String(str))
    isempty(s) && return :empty
    parts = split(s)
    cmd = uppercase(parts[1])
    if cmd == "DROP_BREAD" && length(parts) >= 5
        x = parse(Float64, parts[2]); y = parse(Float64, parts[3])
        z = parse(Float64, parts[4]); amt = parse(Float64, parts[5])
        add_bread!(w, x, y, z, amt)
        return :ok
    elseif cmd == "SPAWN_HUMAN" && length(parts) >= 4
        x = parse(Float64, parts[2]); y = parse(Float64, parts[3]); z = parse(Float64, parts[4])
        spawn_human!(w, x, y, z)
        return :ok
    elseif cmd == "CLEAR_HUMAN"
        clear_human!(w)
        return :ok
    elseif cmd == "KILL_THE_SUN"
        kill_the_sun!(w)
        return :ok
    else
        return :unknown
    end
end
