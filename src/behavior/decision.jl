# PigeonControl: behavioral state machine.

"""
`update_state!(p, w, eating::Bool)`

Decides the discrete `Pigeon.state` for the current tick:
  - threat near            -> FLEEING (3)
  - eating                 -> EATING  (2)
  - airborne (y > 1.5)     -> FLYING  (0)
  - on ground, slow       -> WALKING (1)
  - on ground, moving     -> LANDING (4) / TAKEOFF (5) by vertical motion
"""
function update_state!(p::Pigeon, w::World, eating::Bool)
    # An active fight overrides everything else (including a human threat):
    # existing fights always finish, even if a threat appears mid-fight.
    if p.fight_timer > 0.0f0
        p.state = FIGHTING
        return
    end

    # Threat response overrides normal behavior.
    if w.threat !== nothing
        if nearest_threat(w, p.pos, threat_radius(p)) !== nothing
            p.state = FLEEING
            return
        end
    end

    if eating
        p.state = EATING
        return
    end

    if p.pos[2] > 1.5f0
        p.state = FLYING
        return
    end

    if p.speed < 1.0f0
        p.state = WALKING
        return
    end

    # Near the ground but still moving: classify as landing or takeoff.
    p.state = p.vel[2] < -0.1f0 ? LANDING : TAKEOFF
end
