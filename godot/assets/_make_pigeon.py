import bpy
import os

# Low-poly pigeon for the PigeonControl Godot renderer.
# Coordinate convention: +Z is forward (nose), +Y is up. Blender exports with
# export_yup=True so the model matches Godot's Y-up world.

scene = bpy.context.scene
# Wipe any existing objects for a clean, repeatable build.
bpy.ops.object.select_all(action="SELECT")
bpy.ops.object.delete(use_global=False)

meshes = []


def add_mesh(primitive_op, name, **kwargs):
    primitive_op(**kwargs)
    obj = bpy.context.active_object
    obj.name = name
    meshes.append(obj)
    return obj


# Body: a sphere scaled into a fat, forward-elongated chest (~0.7 long).
body = add_mesh(
    bpy.ops.mesh.primitive_uv_sphere_add,
    "body",
    radius=0.22,
    location=(0.0, 0.0, 0.0),
)
body.scale = (0.8, 0.7, 1.6)  # x=width, y=height, z=length
body.location = (0.0, 0.15, 0.0)

# Neck: small sphere bridging body to head.
neck = add_mesh(
    bpy.ops.mesh.primitive_uv_sphere_add,
    "neck",
    radius=0.1,
    location=(0.0, 0.22, 0.32),
)

# Head: sphere r0.12 front (+Z 0.4, y+0.15).
head = add_mesh(
    bpy.ops.mesh.primitive_uv_sphere_add,
    "head",
    radius=0.12,
    location=(0.0, 0.15 + 0.15, 0.4),
)

# Beak: cone pointing forward (+Z).
beak = add_mesh(
    bpy.ops.mesh.primitive_cone_add,
    "beak",
    radius1=0.05,
    depth=0.16,
    location=(0.0, 0.16, 0.54),
)
beak.rotation_euler = (1.5708, 0.0, 0.0)  # point +Z

# Tail: flattened box at the back (-Z).
tail = add_mesh(
    bpy.ops.mesh.primitive_cube_add,
    "tail",
    size=1.0,
    location=(0.0, 0.15, -0.34),
)
tail.scale = (0.18, 0.04, 0.30)

# Wings: two flattened boxes at X +-0.25.
wing_l = add_mesh(
    bpy.ops.mesh.primitive_cube_add,
    "wing_l",
    size=1.0,
    location=(-0.25, 0.18, 0.0),
)
wing_l.scale = (0.05, 0.03, 0.35)

wing_r = add_mesh(
    bpy.ops.mesh.primitive_cube_add,
    "wing_r",
    size=1.0,
    location=(0.25, 0.18, 0.0),
)
wing_r.scale = (0.05, 0.03, 0.35)

# Join every mesh into one object so the GLB carries a single MeshInstance.
bpy.ops.object.select_all(action="DESELECT")
for m in meshes:
    m.select_set(True)
bpy.context.view_layer.objects.active = meshes[0]
bpy.ops.object.join()

# Merge vertices so the joined blob is clean low-poly geometry.
bpy.ops.object.mode_set(mode="EDIT")
bpy.ops.mesh.remove_doubles(threshold=0.01)
bpy.ops.object.mode_set(mode="OBJECT")

out_dir = "/Users/nguyenhuyvu/projects/PigeonControl/godot/assets"
os.makedirs(out_dir, exist_ok=True)
out_path = os.path.join(out_dir, "pigeon.glb")

bpy.ops.export_scene.gltf(
    filepath=out_path,
    export_yup=True,
    export_apply=True,
    use_selection=False,
)

print("WROTE", out_path, "size", os.path.getsize(out_path))
