# PigeonControl: authoritative observation / data-generation slice.
#
# Julia remains the sole simulation authority. The observer only generates data
# by applying the existing intervention helpers (apply_command!) and then calling
# step!(world). It never reproduces behavior in another language.
#
# This module is a submodule of PigeonControl so it can reuse every engine
# primitive (make_world, step!, serialize_snapshot, send_bytes, queries, ...)
# without re-implementing simulation behavior.

module Observation

using ..PigeonControl
using ..PigeonControl: Vec3, Genome, Pigeon, World, SimConfig, Food,
    make_world, step!, apply_command!, serialize_snapshot,
    send_bytes, FRAG_MAGIC, CHUNK_SIZE,
    PIGEON_COMMON, PIGEON_CRUMB_GOBLIN, PIGEON_SKY_SCOUT, PIGEON_BRUISER,
    FLYING, WALKING, EATING, FLEEING, LANDING, TAKEOFF, FIGHTING, PERCHING
using StaticArrays
using Sockets
using LinearAlgebra
using StableRNGs
using Random

# Observation schema version. Bump only when the raw file layout changes.
const SCHEMA_VERSION = "pigeon-observer-raw-v1"

# Simulator identity recorded in the run manifest (no TOML dependency needed).
const SIM_VERSION = "0.1.0"

include("scenarios.jl")
include("metrics.jl")
include("capture.jl")
include("dataset.jl")

export SCHEMA_VERSION, SCENARIO_NAMES, list_scenarios, default_n,
    build_scenario, with_genome, generate_run, RunCounters,
    build_tick_values!, capture_tick!, CaptureSession

end # module Observation
