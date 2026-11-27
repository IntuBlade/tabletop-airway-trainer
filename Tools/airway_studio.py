"""Editable Blender studio layers and pose controls for the private research airway."""

import json

import addon_utils
import bpy
import numpy as np
from mathutils.bvhtree import BVHTree


def activate(obj):
    bpy.ops.object.select_all(action="DESELECT")
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)


def mesh_object(name, vertices, faces):
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    return obj


def papillary_tile():
    """Tessellate an asymmetric papilla over a jittered, periodically bordered grid."""
    size = 8
    rng = np.random.default_rng(724)
    vertices = [
        (
            i + (rng.uniform(-0.36, 0.36) if 0 < i < size else 0),
            j + (rng.uniform(-0.36, 0.36) if 0 < j < size else 0),
            0,
        )
        for j in range(size + 1)
        for i in range(size + 1)
    ]
    faces = [
        (a, a + 1, a + size + 2, a + size + 1)
        for j in range(size)
        for i in range(size)
        for a in [i + j * (size + 1)]
    ]
    grid = mesh_object("Papilla patch layout", vertices, faces)
    # The square perimeter fits the generator quad. Interior rings lean back
    # toward the tongue root and taper into a rounded apex.
    n = 16
    theta = np.arange(n) * 2 * np.pi / n
    circle = np.column_stack((np.cos(theta), np.sin(theta)))
    rings = []
    for radius, height, lean in [
        (None, 0, 0),
        (0.43, 0.018, 0),
        (0.30, 0.12, 0.025),
        (0.13, 0.25, 0.09),
        (0.035, 0.28, 0.11),
    ]:
        xy = (
            circle * radius
            if radius
            else 0.5 * circle / np.max(abs(circle), axis=1)[:, None]
        )
        rings.extend((x + 0.5, y + 0.5 + lean, height) for x, y in xy)
    faces = [
        (j * n + i, j * n + (i + 1) % n, (j + 1) * n + (i + 1) % n, (j + 1) * n + i)
        for j in range(4)
        for i in range(n)
    ]
    faces.append(tuple(range(4 * n, 5 * n)))
    component = mesh_object("Papilla master", rings, faces)
    activate(grid)
    result = bpy.ops.object.tissue_tessellate(
        generator=grid.name,
        component=component.name,
        mode="LOCAL",
        scale_mode="CONSTANT",
        offset=1,
    )
    if result != {"FINISHED"}:
        raise ValueError("Tissue tessellation failed")
    patch = bpy.context.object
    patch.name = "Tissue papillary relief"
    data = patch.data
    tree = BVHTree.FromPolygons(
        [v.co for v in data.vertices], [p.vertices[:] for p in data.polygons]
    )
    width = 192
    heights = np.zeros((width, width), dtype=np.float32)
    for iy, ix in np.ndindex(heights.shape):
        hit, _, _, _ = tree.ray_cast(
            ((ix + 0.5) * size / width, (iy + 0.5) * size / width, 2), (0, 0, -1)
        )
        if hit is None:
            raise ValueError("Hole in Tissue tile")
        heights[iy, ix] = hit.z
    amplitude = np.ptp(heights)
    if amplitude < 0.1:
        raise ValueError("Tissue evaluation produced a flat tile")
    image = bpy.data.images.new(
        "Papillary microrelief", width, width, float_buffer=True
    )
    image.colorspace_settings.name = "Non-Color"
    rgba = np.ones((width, width, 4), dtype=np.float32)
    rgba[:, :, :3] = ((heights - heights.min()) / amplitude)[:, :, None]
    image.pixels.foreach_set(rgba.ravel())
    image.pack()
    for obj in [grid, component, patch]:
        obj.hide_render = True
        obj.hide_set(True)
    return image, len(data.polygons)


def apply_relief(material, image):
    nodes = material.node_tree.nodes
    link = material.node_tree.links.new
    coords = next(n for n in nodes if n.type == "TEX_COORD")
    mapping = nodes.new("ShaderNodeVectorMath")
    mapping.operation = "SCALE"
    mapping.inputs["Scale"].default_value = 1 / 0.0048
    link(coords.outputs["Object"], mapping.inputs[0])
    tex = nodes.new("ShaderNodeTexImage")
    tex.image = image
    tex.projection = "BOX"
    tex.projection_blend = 0.25
    link(mapping.outputs[0], tex.inputs["Vector"])
    blend = next(n for n in nodes if n.label == "Tongue surface relief")
    # Retain irregular fine grain between papillae. A pure repeating height
    # tile reads as a stamped grid at the near edge of the blade view.
    mixed = nodes.new("ShaderNodeMixRGB")
    mixed.label = "Papillae over tongue grain"
    mixed.inputs[0].default_value = 0.48
    link(blend.inputs[2].links[0].from_socket, mixed.inputs[1])
    link(tex.outputs["Color"], mixed.inputs[2])
    link(mixed.outputs[0], blend.inputs[2])


def regional_atlas(obj, regions, ids):
    mesh = obj.data
    triangles = np.array([p.vertices[:] for p in mesh.polygons])
    vertices = np.array([v.co[:] for v in mesh.vertices])
    a, b, c = vertices[triangles].transpose(1, 0, 2)
    area = np.linalg.norm(np.cross(b - a, c - a), axis=1) / 2
    # A triangle with two labeled corners belongs to the landmark island.
    groups = np.zeros(len(triangles), dtype=int)
    for i, name in enumerate(("epiglottis", "cords"), 1):
        groups[np.sum(regions[triangles] == ids.index(name), axis=1) >= 2] = i
    uv_layer = mesh.uv_layers.active.name

    def uv():
        values = np.empty((len(mesh.loops), 2), dtype=np.float32)
        mesh.uv_layers[uv_layer].data.foreach_get("uv", values.ravel())
        return values.reshape(-1, 3, 2)

    def density(values, selected):
        a, b, c = values[selected].transpose(1, 0, 2)
        ab, ac = b - a, c - a
        uv_area = np.abs(ab[:, 0] * ac[:, 1] - ab[:, 1] * ac[:, 0]).sum() / 2
        return round(float(2048 * np.sqrt(uv_area / area[selected].sum()) / 1000), 2)

    result = uv()
    evidence = {}
    for group, (name, x, y, side) in enumerate(
        [
            ("remaining", 0, 0, 0.765),
            ("epiglottis", 0.77, 0, 0.23),
            ("cords", 0.77, 0.24, 0.23),
        ]
    ):
        selected = groups == group
        before = density(result, selected)
        if group == 0:
            result[selected] *= (0.765, 1.0)
            evidence[name] = [before, density(result, selected)]
            continue
        bpy.ops.object.mode_set(mode="EDIT")
        bpy.ops.mesh.select_mode(type="FACE")
        bpy.ops.mesh.select_all(action="DESELECT")
        bpy.ops.object.mode_set(mode="OBJECT")
        mesh.polygons.foreach_set("select", selected)
        bpy.ops.object.mode_set(mode="EDIT")
        bpy.ops.uv.smart_project(angle_limit=1.35, island_margin=0.007)
        bpy.ops.object.mode_set(mode="OBJECT")
        result[selected] = uv()[selected] * side + (x, y)
        evidence[name] = [before, density(result, selected)]
    mesh.uv_layers[uv_layer].data.foreach_set("uv", result.ravel())
    return evidence


def paint(obj, regions, ids, material, pigment):
    mesh = obj.data
    nodes = material.node_tree.nodes
    link = material.node_tree.links.new
    bpy.ops.wm.y_quick_ypaint_node_setup(type="BSDF_PRINCIPLED")
    group = next(
        n for n in nodes if n.type == "GROUP" and n.node_tree.yp.is_ypaint_node
    )
    # Quick Setup adds a second surface and material output in a headless scene.
    # Keep the original tissue shader active for both baking and review.
    output = nodes.get("Material Output")
    for node in list(nodes):
        if node.type == "OUTPUT_MATERIAL" and node != output:
            nodes.remove(node)
        elif node.type == "BSDF_PRINCIPLED" and node != nodes.get("Principled BSDF"):
            nodes.remove(node)
    output.is_active_output = True
    nodes.active = group
    link(pigment, group.inputs["Color"])
    coords = np.array([v.co[:] for v in mesh.vertices])
    edges = np.array([e.vertices[:] for e in mesh.edges])
    src, dst = np.concatenate((edges, edges[:, ::-1])).T
    count = np.maximum(1, np.bincount(dst, minlength=len(coords)))
    for region, label, color, strength in [
        ("epiglottis", "Epiglottic rim", (0.77, 0.32, 0.21), 0.45),
        ("cords", "Vocal fold margins", (0.78, 0.61, 0.43), 0.46),
        ("tongue", "Tongue mottling", (0.50, 0.115, 0.108), 0.27),
    ]:
        inside = regions == ids.index(region)
        mask = inside.astype(float)
        for _ in range(10):
            mask = 0.5 * (
                mask
                + np.bincount(dst, weights=mask[src], minlength=len(coords)) / count
            )
        if region == "epiglottis":
            mask = 4 * mask * (1 - mask)
        else:
            mask *= 0.68 + 0.32 * np.sin(520 * coords[:, 0] + 270 * coords[:, 2])
        layer = mesh.color_attributes.new(label, "FLOAT_COLOR", "POINT")
        rgba = np.empty((len(coords), 4), np.float32)
        rgba[:, :3] = color
        rgba[:, 3] = mask * strength
        layer.data.foreach_set("color", rgba.ravel())
        bpy.ops.wm.y_open_existing_data_as_layer(
            type="VCOL",
            vcol_name=label,
            channel_idx="0",
            uv_map=mesh.uv_layers.active.name,
        )
    if len(group.node_tree.yp.layers) != 3:
        raise ValueError("Ucupaint layer creation failed")
    link(group.outputs["Color"], nodes.get("Principled BSDF").inputs["Base Color"])
    return group.outputs["Color"]


def pose_controls():
    arm = bpy.data.armatures.new("Contact poses")
    rig = bpy.data.objects.new("Vallecular lift controls", arm)
    bpy.context.collection.objects.link(rig)
    activate(rig)
    bpy.ops.object.mode_set(mode="EDIT")
    for i, name in enumerate(("Lift", "Rim roll", "Tongue compression")):
        bone = arm.edit_bones.new(name)
        bone.head = (i * 0.01, 0, 0)
        bone.tail = (i * 0.01, 0.01, 0)
    bpy.ops.object.mode_set(mode="POSE")
    action = bpy.data.actions.new("Rest - partial lift - full exposure")
    for name, prop, index, values in [
        ("Rim roll", "rotation_euler", 0, (0, 0.35, 0)),
        ("Tongue compression", "scale", 1, (1, 0.76, 1)),
    ]:
        bone = rig.pose.bones[name]
        bone.rotation_mode = "XYZ"
        curve = action.fcurves.new(
            bone.path_from_id(prop), index=index, action_group=name
        )
        for frame, value in zip((0, 5, 10), values):
            curve.keyframe_points.insert(frame, value)
    action.id_root = "OBJECT"
    bpy.ops.armature.ap_pose_add(name="Blade lift")
    pose = arm.ap_poses[-1]
    pose.target = rig
    pose.target_type = "BONE"
    pose.bone = "Lift"
    pose.channel = "LOC_X"
    pose.transform_max = 0.01
    pose.action = action
    for name in ("Rim roll", "Tongue compression"):
        pose.bones.add().bone = name
    bpy.ops.armature.ap_execute()
    target = bpy.data.objects.new("Action reference", None)
    bpy.context.collection.objects.link(target)
    for name in ("Rim roll", "Tongue compression"):
        rig.pose.bones[name].constraints[0].target = target
        rig.pose.bones[name].constraints[0].action = action
    # ActionPoser 1.0 generates min(x) for a single bone driver. Use its
    # configured transform variable in Blender's simple expression evaluator.
    for owner in (rig, arm):
        if owner.animation_data:
            for curve in owner.animation_data.drivers:
                curve.driver.expression = "min(max(var0 / 0.01, 0.0), 1.0)"
    middle = {}
    for phase in (0, 0.5, 1):
        rig.pose.bones["Lift"].location.x = phase * 0.01
        bpy.context.view_layer.update()
        for name in ("Rim roll", "Tongue compression"):
            bone = rig.evaluated_get(bpy.context.evaluated_depsgraph_get()).pose.bones[
                name
            ]
            matrix = np.array(bone.matrix @ bone.bone.matrix_local.inverted())[:3, :3]
            if phase == 0.5:
                middle[name] = matrix
                if np.allclose(matrix, np.eye(3), atol=0.01):
                    raise ValueError(
                        "ActionPoser partial pose did not evaluate: " + name
                    )
            elif not np.allclose(matrix, np.eye(3), atol=0.001):
                raise ValueError("ActionPoser endpoint does not release")
    rig.pose.bones["Lift"].location.x = 0
    bpy.ops.object.mode_set(mode="OBJECT")
    return middle


def prepare(obj, material, pigment, manifest, out):
    for name in ("tissue", "ucupaint", "ActionPoser"):
        if addon_utils.enable(name, default_set=True) is None:
            raise RuntimeError("Install the Blender authoring add-on " + name)
    meta = json.loads(manifest.read_text())
    ids = json.loads(manifest.with_suffix(".landmarks.json").read_text())["regions"]
    if "lift" not in meta["layout"] or not {"tongue", "epiglottis", "cords"}.issubset(ids):
        raise ValueError("Studio export requires lift weights and labeled tongue, epiglottis and cords")
    field = meta["layout"]["region"]
    regions = np.frombuffer(
        manifest.with_suffix(".bin").read_bytes(),
        "<f4",
        field["count"],
        field["offset"],
    )
    density = regional_atlas(obj, regions, ids)
    image, faces = papillary_tile()
    matrices = pose_controls()
    activate(obj)
    apply_relief(material, image)
    pigment = paint(obj, regions, ids, material, pigment)
    (out / "authoring.json").write_text(
        json.dumps(
            {
                "regional_texels_per_mm_before_after": density,
                "tissue_patch_faces": faces,
                "partial_pose_matrices": {k: v.tolist() for k, v in matrices.items()},
            },
            indent=2,
        )
    )
    return pigment, matrices


def bind_review_shapes(obj, points, weighted_axis, corrective):
    """Show the exported GPU deformation on the editable mesh in Blender."""
    local = np.array([v.co[:] for v in obj.data.vertices])
    basis, *_ = np.linalg.lstsq(
        np.column_stack((points, np.ones(len(points)))), local, rcond=None
    )
    if not np.allclose(points @ basis[:3] + basis[3], local, atol=2e-6):
        raise ValueError(
            "Review mesh and exported points are in different vertex order"
        )
    obj.shape_key_add(name="Basis")
    for name, delta, expression in [
        ("Resting cover", -0.0045 * weighted_axis, "1-w"),
        ("Full exposure", 0.009 * weighted_axis, "w"),
        ("Partial rim roll and tongue compression", corrective, "4*w*(1-w)"),
    ]:
        key = obj.shape_key_add(name=name)
        key.data.foreach_set(
            "co",
            np.ascontiguousarray(local + delta @ basis[:3], dtype=np.float32).ravel(),
        )
        driver = key.driver_add("value").driver
        variable = driver.variables.new()
        variable.name = "x"
        variable.type = "TRANSFORMS"
        target = variable.targets[0]
        target.id = bpy.data.objects["Vallecular lift controls"]
        target.bone_target = "Lift"
        target.transform_type = "LOC_X"
        target.transform_space = "LOCAL_SPACE"
        driver.expression = expression.replace("w", "min(max(x/0.01,0),1)")
