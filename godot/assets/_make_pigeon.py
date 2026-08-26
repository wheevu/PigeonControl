import bpy
import os
import math

# Authored pigeon converter for the PigeonControl Godot renderer.
#
# Source: CC0 low-poly rigged/animated pigeon by mujtaba-io (OpenGameArt).
# See pigeons/ATTRIBUTION.md and pigeons/source/pigeon-mujtaba-io.blend.
#
# For each of the four variants this script:
#   1. reopens the source .blend deterministically,
#   2. poses the `pigeon-armature` rig (authored actions and/or explicit
#      bone rotations sampled from those actions),
#   3. bakes the posed geometry into a standalone static mesh
#      (no armature, no skeleton dependency),
#   4. orients it to the runtime convention (+Z forward / +Y up in Blender,
#      which becomes Y-up in Godot via export_yup), origin near feet/body,
#   5. strips everything else and exports exactly one mesh object per GLB.
#
# The pigeon geometry itself is always the authored 507-vert mesh; variants
# differ only by pose, restrained nonuniform scale, and material color.

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SOURCE_BLEND = os.path.join(SCRIPT_DIR, "pigeons", "source", "pigeon-mujtaba-io.blend")
OUT_DIR = os.path.join(SCRIPT_DIR, "pigeons")
os.makedirs(OUT_DIR, exist_ok=True)

MESH_NAME = "pigeon-model"
ARMATURE_NAME = "pigeon-armature"

# Blender-space orientation fix: authored model is +Y forward / +Z up.
# This euler maps forward -> +Z and up -> +Y (the pre-export convention;
# export_yup turns that into Godot's Y-up with forward matching the sim).
ORIENT_EULER = (math.pi / 2.0, 0.0, math.pi)

TARGET_LENGTH = 0.55  # meters, nose-to-tail baseline


def load_source():
    bpy.ops.wm.open_mainfile(filepath=SOURCE_BLEND)
    return bpy.data.objects[MESH_NAME], bpy.data.objects[ARMATURE_NAME]


def _channelbag(action, slot):
    for layer in action.layers:
        for strip in layer.strips:
            for bag in strip.channelbags:
                if bag.channelbag.slot == slot or bag.channelbag is None:
                    return bag.channelbag if bag.channelbag else bag
    # Fallback: first channelbag anywhere.
    for layer in action.layers:
        for strip in layer.strips:
            for bag in strip.channelbags:
                return bag.channelbag
    return None


def sample_action_pose(armature, action_name, frame):
    """Apply an action's channels directly to pose bones at `frame`.

    Works without assigning the action, so multiple actions can be composed
    (e.g. legs-up + wing spread) as long as they touch different bones.
    """
    action = bpy.data.actions[action_name]
    bag = None
    for layer in action.layers:
        for strip in layer.strips:
            for cb in strip.channelbags:
                bag = cb  # ActionChannelbag
                break

    for fc in bag.fcurves:
        parts = fc.data_path.split('"')
        if len(parts) < 2:
            continue
        bone_name = parts[1]
        bone = armature.pose.bones.get(bone_name)
        if bone is None:
            continue
        value = fc.evaluate(frame)
        prop = fc.data_path.rsplit(".", 1)[-1]
        if prop == "rotation_quaternion":
            bone.rotation_mode = "QUATERNION"
            q = bone.rotation_quaternion
            q[fc.array_index] = value
        elif prop == "rotation_euler":
            e = bone.rotation_euler
            e[fc.array_index] = value
        elif prop == "location":
            loc = bone.location
            loc[fc.array_index] = value
        elif prop == "scale":
            sc = bone.scale
            sc[fc.array_index] = value


def set_wing_spread(armature, angle_deg):
    """Explicitly spread both wings by rotating wing-1 bones around Y."""
    for side in ("left", "right"):
        bone = armature.pose.bones.get("%s-wing-1" % side)
        if bone is None:
            continue
        sign = 1.0 if side == "left" else -1.0
        bone.rotation_mode = "XYZ"
        bone.rotation_euler.rotate_axis("Y", sign * math.radians(angle_deg))


def clear_pose(armature):
    for bone in armature.pose.bones:
        bone.location = (0.0, 0.0, 0.0)
        bone.scale = (1.0, 1.0, 1.0)
        bone.rotation_mode = "QUATERNION"
        bone.rotation_quaternion.identity()
        bone.rotation_euler = (0.0, 0.0, 0.0)


def bake_posed_mesh(mesh_obj, armature):
    """Return a standalone copy of the mesh with the current pose applied."""
    dg = bpy.context.evaluated_depsgraph_get()
    evaluated = mesh_obj.evaluated_get(dg)
    baked = bpy.data.meshes.new_from_object(evaluated)
    copy = bpy.data.objects.new(MESH_NAME + "_baked", baked)
    copy.matrix_world = mesh_obj.matrix_world.copy()
    bpy.context.scene.collection.objects.link(copy)
    return copy


def orient_and_ground(obj):
    """Apply the orientation fix, uniform-scale to target length, ground it."""
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    obj.rotation_euler = ORIENT_EULER
    obj.scale = (1.0, 1.0, 1.0)
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)

    xs = [obj.matrix_world @ v.co for v in obj.data.vertices]
    length = max(p.x for p in xs) - min(p.x for p in xs)
    s = TARGET_LENGTH / length
    obj.scale = (s, s, s)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)

    bpy.ops.object.origin_set(type="ORIGIN_GEOMETRY", center="BOUNDS")
    min_z = min((obj.matrix_world @ v.co).z for v in obj.data.vertices)
    obj.location.z -= min_z  # feet/body rest on z=0, centered on x/y bounds
    bpy.ops.object.transform_apply(location=True, rotation=False, scale=False)


def make_material(name, color):
    mat = bpy.data.materials.new(name=name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (color[0], color[1], color[2], 1.0)
    bsdf.inputs["Roughness"].default_value = 0.7
    return mat


def finalize_and_export(name, color, out_path):
    """Delete every other object, assign the variant material, export."""
    keep = bpy.data.objects[MESH_NAME + "_baked"]
    keep.name = name

    mat = make_material(name + "_mat", color)
    keep.data.materials.clear()
    keep.data.materials.append(mat)

    for obj in list(bpy.data.objects):
        if obj.name != name:
            bpy.data.objects.remove(obj, do_unlink=True)
    for block in (bpy.data.armatures,):
        for a in list(block):
            if a.users == 0:
                block.remove(a)

    keep.select_set(True)
    bpy.context.view_layer.objects.active = keep
    bpy.ops.export_scene.gltf(
        filepath=out_path,
        export_yup=True,
        export_apply=True,
        use_selection=True,
    )
    print("WROTE %s size=%d verts=%d polys=%d dims=%s" % (
        out_path, os.path.getsize(out_path),
        len(keep.data.vertices), len(keep.data.polygons),
        tuple(round(d, 3) for d in keep.dimensions)))


def build_variant(out_name, pose_setup, color, scale=(1.0, 1.0, 1.0)):
    mesh_obj, armature = load_source()

    # Neutralize any scene animation state, then compose the variant pose.
    anim = armature.animation_data
    if anim:
        anim.action = None
    clear_pose(armature)
    pose_setup(armature)

    bpy.context.view_layer.update()

    baked = bake_posed_mesh(mesh_obj, armature)
    baked.scale = scale

    orient_and_ground(baked)
    finalize_and_export(out_name, color, os.path.join(OUT_DIR, out_name + ".glb"))


def pose_common(armature):
    # Neutral idle frame from the authored idle-animation.
    sample_action_pose(armature, "idle-animation", 6)


def pose_crumb_goblin(armature):
    # Legs tucked up (begging goblin posture) from legs-up-animation,
    # wings folded close to the body.
    sample_action_pose(armature, "legs-up-animation", 2)
    set_wing_spread(armature, -20)


def pose_sky_scout(armature):
    # Full wingspread glide from the flap-wings cycle (upstroke peak).
    sample_action_pose(armature, "flap-wings-animation", 6)
    set_wing_spread(armature, 15)


def pose_bruiser(armature):
    # Broad chest-forward stance: half-spread wings plus legs planted wide.
    sample_action_pose(armature, "flap-wings-animation", 12)
    set_wing_spread(armature, -10)
    sample_action_pose(armature, "legs-up-animation", 4)


VARIANTS = [
    ("pigeon_common", pose_common,
     (0.42, 0.45, 0.52), (1.00, 1.00, 1.00)),   # cool slate gray, iridescent-neutral
    ("pigeon_crumb_goblin", pose_crumb_goblin,
     (0.62, 0.38, 0.14), (1.05, 0.95, 0.92)),   # warm brown/gold-ish, squat
    ("pigeon_sky_scout", pose_sky_scout,
     (0.16, 0.42, 0.72), (0.97, 0.97, 1.06)),   # blue/cyan accent, slim
    ("pigeon_bruiser", pose_bruiser,
     (0.13, 0.13, 0.15), (1.08, 1.02, 1.02)),   # charcoal/red-tinged, broad
]


def main():
    for out_name, pose_setup, color, scale in VARIANTS:
        build_variant(out_name, pose_setup, color, scale)


if __name__ == "__main__":
    main()
