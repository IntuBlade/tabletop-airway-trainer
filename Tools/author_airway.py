"""Author a private airway appearance with Blender 4.2 (bpy) and Apple USD tools.

Usage: python author_airway.py input.usdz output_directory
The input must be the meter-scale single-mesh airway with vertex displayColor.
A matched region manifest with lift weights adds localized motion channels.
UV seam duplicates retain their source positions and triangle connectivity.
"""
import argparse
import hashlib
import json
import os
import sys
from pathlib import Path
import re
import subprocess

import bpy
import numpy as np


# Linear-light diffuse colors. The glottic margins have lower chroma than the
# adjoining mucosa in both clinical comparison recordings.
REGIONAL_COLORS = {
    "tongue": (0.63, 0.17, 0.12),
    "palate": (0.62, 0.19, 0.14),
    "gums": (0.55, 0.12, 0.09),
    "pharynx": (0.67, 0.19, 0.13),
    "epiglottis": (0.69, 0.25, 0.15),
    "larynx": (0.64, 0.19, 0.13),
    "cords": (0.58, 0.44, 0.28),
}


def color_labeled_tissue(mesh, manifest):
    """Read a mesh's own labels. Require matching topology and vertex colors."""
    meta = json.loads(manifest.read_text())
    landmarks = json.loads(manifest.with_suffix(".landmarks.json").read_text())
    raw = manifest.with_suffix(".bin").read_bytes()
    if hashlib.sha256(raw).hexdigest() != meta["sha256"] or meta["sha256"] != landmarks["mesh_sha256"]:
        raise ValueError("Region and geometry files must describe the same mesh")

    def block(key, dtype):
        field = meta["layout"][key]
        return np.frombuffer(raw, dtype, field["count"], field["offset"]).reshape(-1, field["item_size"])

    indices = np.empty(len(mesh.loops), dtype=np.int32)
    mesh.loops.foreach_get("vertex_index", indices)
    if not np.array_equal(indices, block("index", "<u4").ravel()):
        raise ValueError("Region mesh differs from imported mesh")

    attr = mesh.color_attributes["displayColor"]
    colors = np.empty((len(attr.data), 4), dtype=np.float32)
    attr.data.foreach_get("color", colors.ravel())
    if attr.domain != "POINT" or not np.allclose(colors[:, :3], block("color", "<f4"), atol=1e-5):
        raise ValueError("Expected the matching vertex-color airway source")

    region = block("region", "<f4").ravel()
    # The tongue needs papillary relief while the epiglottis has a smooth
    # wet film. Fade those differences continuously across label boundaries.
    finishes = ("tongue", "epiglottis")
    region_ids = {name: i for i, name in enumerate(landmarks["regions"])}
    surface_masks = np.column_stack([region == region_ids.get(name, -1) for name in finishes])
    pigment = colors[:, :3].copy()
    for index, name in enumerate(landmarks["regions"]):
        selected = region == index
        if name in REGIONAL_COLORS and np.any(selected):
            local = pigment[selected]
            pigment[selected] = np.clip(local / np.median(local, axis=0) * REGIONAL_COLORS[name], 0, 1)

    # Feather across neighboring triangles, including the edges of the cord labels.
    edges = np.empty((len(mesh.edges), 2), dtype=np.int32)
    mesh.edges.foreach_get("vertices", edges.ravel())
    src, dst = np.concatenate((edges, edges[:, ::-1])).T
    count = np.maximum(1, np.bincount(dst, minlength=len(colors)))[:, None]
    pigment = np.column_stack((pigment, surface_masks))
    for _ in range(14):
        total = np.zeros_like(pigment)
        np.add.at(total, dst, pigment[src])
        pigment = 0.5 * (pigment + total / count)
    colors[:, :3] = pigment[:, :3]
    masks = mesh.color_attributes.new("TissueFinish", "FLOAT_COLOR", "POINT")
    packed = np.ones_like(colors)
    packed[:, :2] = pigment[:, 3:]
    masks.data.foreach_set("color", packed.ravel())
    attr.data.foreach_set("color", colors.ravel())


def create_material(mesh, labeled=False):
    material = bpy.data.materials.new("Mucosa")
    material.use_nodes = True
    mesh.materials.clear()
    mesh.materials.append(material)
    nodes = material.node_tree.nodes
    link = material.node_tree.links.new
    surface = nodes.get("Principled BSDF")
    surface.inputs["Coat Weight"].default_value = 0.23
    surface.inputs["Coat Roughness"].default_value = 0.21
    surface.inputs["Subsurface Weight"].default_value = 0.07
    surface.inputs["Subsurface Scale"].default_value = 0.0006
    base = nodes.new("ShaderNodeVertexColor")
    base.layer_name = "displayColor"
    coords = nodes.new("ShaderNodeTexCoord")

    def variation(label, scale, detail, distortion):
        node = nodes.new("ShaderNodeTexNoise")
        node.label = label
        link(coords.outputs["Object"], node.inputs["Vector"])
        for key, value in [("Scale", scale), ("Detail", detail), ("Distortion", distortion)]:
            node.inputs[key].default_value = value
        return node.outputs["Fac"]

    def gradient(label, signal, low, high):
        node = nodes.new("ShaderNodeValToRGB")
        node.label = label
        node.color_ramp.elements[0].position = 0.27
        node.color_ramp.elements[0].color = (*low, 1)
        node.color_ramp.elements[1].position = 0.73
        node.color_ramp.elements[1].color = (*high, 1)
        link(signal, node.inputs[0])
        return node.outputs[0]

    tone = gradient("Warm tissue variation", variation("Tissue tone", 165, 3, 0.45),
                    (0.84, 0.58, 0.62), (1.0, 0.95, 0.94))
    pigment = nodes.new("ShaderNodeMixRGB")
    pigment.blend_type = "MULTIPLY"
    pigment.inputs[0].default_value = 1
    link(base.outputs["Color"], pigment.inputs[1])
    if labeled:
        # A narrow band in distorted surface noise gives irregular streaks at
        # millimeter scale. Their pigment stays on the mesh during withdrawal.
        streak = nodes.new("ShaderNodeValToRGB")
        streak.label = "Subsurface color streaks"
        ramp = streak.color_ramp
        ramp.elements[0].color = (1, 1, 1, 1)
        ramp.elements[1].color = (1, 1, 1, 1)
        for position, rgb in [(0.41, (1, 1, 1)), (0.455, (0.86, 0.60, 0.65)), (0.49, (1, 1, 1))]:
            ramp.elements.new(position).color = (*rgb, 1)
        link(variation("Fine vascular variation", 235, 2, 0.75), streak.inputs[0])
        mix = nodes.new("ShaderNodeMixRGB")
        mix.blend_type = "MULTIPLY"
        mix.inputs[0].default_value = 0.7
        link(tone, mix.inputs[1])
        link(streak.outputs[0], mix.inputs[2])
        tone = mix.outputs[0]
    link(tone, pigment.inputs[2])
    link(pigment.outputs[0], surface.inputs["Base Color"])
    roughness = gradient("Moisture variation", variation("Moisture", 440, 2, 0.25),
                         (0.19,)*3, (0.41,)*3)
    grain = variation("Fine grain", 1750, 2, 0.12)
    if labeled:
        masks = nodes.new("ShaderNodeVertexColor")
        masks.layer_name = "TissueFinish"
        channels = nodes.new("ShaderNodeSeparateColor")
        link(masks.outputs["Color"], channels.inputs["Color"])

        def blend(label, factor, first, second):
            node = nodes.new("ShaderNodeMixRGB")
            node.label = label
            for slot, value in enumerate((factor, first, second)):
                if isinstance(value, tuple):
                    node.inputs[slot].default_value = value
                else:
                    link(value, node.inputs[slot])
            return node.outputs[0]

        # Uneven spacing and rounded peaks break up the tongue's moving highlight.
        papillae = nodes.new("ShaderNodeTexVoronoi")
        papillae.label = "Tongue papillae spacing"
        papillae.inputs["Scale"].default_value = 1550
        link(coords.outputs["Object"], papillae.inputs["Vector"])
        relief = gradient("Rounded papillae", papillae.outputs["Distance"],
                          (0.95,)*3, (0.10,)*3)
        grain = blend("Tongue surface relief", channels.outputs["Red"], grain, relief)
        wet = gradient("Broken wet film", variation("Wet film", 1150, 2, 0.3),
                       (0.11,)*3, (0.28,)*3)
        roughness = blend("Epiglottic film", channels.outputs["Green"], roughness, wet)
    link(roughness, surface.inputs["Roughness"])
    bump = nodes.new("ShaderNodeBump")
    bump.label = "Fine surface relief"
    bump.inputs["Strength"].default_value = 0.48 if labeled else 0.22
    bump.inputs["Distance"].default_value = 0.00019 if labeled else 0.00012
    link(grain, bump.inputs["Height"])
    link(bump.outputs["Normal"], surface.inputs["Normal"])
    return material, pigment.outputs[0], roughness


def bake(material, pigment, roughness, directory):
    nodes = material.node_tree.nodes
    link = material.node_tree.links.new
    surface = nodes.get("Principled BSDF")
    output = nodes.get("Material Output")
    emit = nodes.new("ShaderNodeEmission")
    target = nodes.new("ShaderNodeTexImage")
    nodes.active = target
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.samples = 1
    scene.render.threads_mode = "FIXED"
    scene.render.threads = 6
    # Undersampled UV islands can hit an unbaked texel at close range.
    # Initialize uncovered texels to tissue, neutral roughness and a flat normal.
    background = {"pigment": (0.28, 0.10, 0.10), "roughness": (0.32,)*3, "normal": (0.5, 0.5, 1)}
    for name, signal in [("pigment", pigment), ("roughness", roughness), ("normal", None)]:
        image = bpy.data.images.new(name, 2048, 2048, alpha=False)
        image.colorspace_settings.name = "sRGB" if name == "pigment" else "Non-Color"
        image.generated_color = (*background[name], 1)
        target.image = image
        if signal:
            link(signal, emit.inputs["Color"])
            link(emit.outputs[0], output.inputs["Surface"])
        else:
            link(surface.outputs[0], output.inputs["Surface"])
        bpy.ops.object.bake(type="EMIT" if signal else "NORMAL", margin=8, use_clear=False)
        image.filepath_raw = str(directory / (name + ".png"))
        image.file_format = "PNG"
        image.save()
    nodes.remove(target)
    nodes.remove(emit)


def add_tissue_lift(stage, manifest, indices, matrices=None):
    """Carry the lift field and its shading normals in additional vertex UV channels."""
    meta = json.loads(manifest.read_text())
    landmarks = json.loads(manifest.with_suffix(".landmarks.json").read_text())
    raw = manifest.with_suffix(".bin").read_bytes()
    if "lift" not in meta["layout"]:
        return stage

    def field(name):
        info = meta["layout"][name]
        return np.frombuffer(raw, "<f4", info["count"], info["offset"])

    def triples(values):
        return ",".join("(%.7g,%.7g,%.7g)" % tuple(row) for row in values)

    source = field("position").reshape(-1, 3)
    exported = re.search(r'point3f\[\] points = \[([^\]]+)\]', stage).group(1)
    points = np.fromstring(exported.replace("(", "").replace(")", ""), sep=",").reshape(-1, 3)
    basis, _, _, _ = np.linalg.lstsq(np.column_stack((source, np.ones(len(source)))), points, rcond=None)
    if not np.allclose(source @ basis[:3] + basis[3], points, atol=2e-6):
        raise ValueError("Lift field requires a matching coordinate frame")

    def landmark(name):
        return np.array(landmarks["points"][name]["point"]) @ basis[:3] + basis[3]

    valley = landmark("vallecula")
    axis = np.array(landmarks["lift_direction"]) @ basis[:3]
    axis /= np.linalg.norm(axis)
    # Localize the existing lift field around the tongue base and epiglottis.
    radius = np.linalg.norm(points - landmark("epiglottis_tip"), axis=1)
    t = np.clip((0.038 - radius) / 0.025, 0, 1)
    weight = np.clip(field("lift"), 0, 1) * t*t*(3 - 2*t)
    weight[weight < 0.001] = 0
    triangles = indices.reshape(-1, 3)
    def normals(vertices):
        a, b, c = vertices[triangles].transpose(1, 0, 2)
        face = np.cross(b-a, c-a)
        result = np.zeros_like(vertices)
        for corner in triangles.T:
            np.add.at(result, corner, face)
        return result / np.maximum(np.linalg.norm(result, axis=1, keepdims=True), 1e-12)

    stage = stage.replace('defaultPrim = "Airway"', 'defaultPrim = "Rig"')
    stage = stage.replace('def Mesh "Airway"', 'def Xform "Rig" {\ndef Mesh "Airway"')
    stage = stage.replace('</Airway/', '</Rig/Airway/')
    base_normals = normals(points)
    # Use the same vertex index for the surface texture and the lift field.
    # Split only UV seams and carry each source vertex's deformation to its copies.
    uv_attribute = r'texCoord2f\[\] primvars:st = \[([^\]]+)\] \(interpolation = "faceVarying"\)'
    uv_text = re.search(uv_attribute, stage).group(1)
    uv = np.fromstring(uv_text.replace("(", "").replace(")", ""), sep=",").reshape(-1, 2)
    seams, new_indices = np.unique(np.column_stack((indices, uv)), axis=0, return_inverse=True)
    source_vertex = seams[:, 0].astype(np.int32)
    stage = re.sub(uv_attribute, 'texCoord2f[] primvars:st = [' +
                   ",".join("(%.7f,%.7f)" % tuple(pair) for pair in seams[:, 1:]) +
                   '] (interpolation = "vertex")', stage)
    for attribute in ["points", "normals", "primvars:displayColor"]:
        pattern = rf'({attribute} = )\[([^\]]+)\]'
        match = re.search(pattern, stage)
        values = np.fromstring(match[2].replace("(", "").replace(")", ""), sep=",").reshape(-1, 3)
        stage = stage[:match.start(2)] + triples(values[source_vertex]) + stage[match.end(2):]
    stage = re.sub(r'faceVertexIndices = \[[^\]]+\]', 'faceVertexIndices = [' +
                   ",".join(map(str, new_indices.ravel())) + ']', stage)
    # Channel 1 holds weight and normal change in x; channel 2 holds y and z.
    # Normal deltas correspond to the 9 mm lifted endpoint.
    delta = 0.009 * weight[:, None] * axis
    normal_delta = normals(points + delta) - base_normals
    properties = []
    channels = [np.column_stack((weight, normal_delta[:, 0])), normal_delta[:, 1:]]
    if matrices:
        # Sample the Blender action in the lens basis. Feather each regional
        # corrective across shared edges so the surface stays continuous.
        correction = np.zeros_like(points)
        region = field("region")
        src, dst = np.concatenate((triangles[:, [0, 1]], triangles[:, [1, 2]],
                                   triangles[:, [2, 0]])).T
        src, dst = np.r_[src, dst], np.r_[dst, src]
        count = np.maximum(1, np.bincount(dst, minlength=len(points)))
        for name, bone in [("epiglottis", "Rim roll"), ("tongue", "Tongue compression")]:
            mask = (region == landmarks["regions"].index(name)).astype(float)
            for _ in range(6):
                mask = .5*(mask + np.bincount(dst, weights=mask[src], minlength=len(points))/count)
            displacement = (points - valley) @ (matrices[bone] - np.eye(3)).T
            correction += displacement * (weight * mask)[:, None]
        from airway_studio import bind_review_shapes
        bind_review_shapes(bpy.context.object, points, axis * weight[:, None], correction)
        mid = points + axis * weight[:, None] * .00225
        normal_correction = normals(mid + correction) - (base_normals + .25*normal_delta)
        channels.extend(np.split(np.column_stack((correction, normal_correction)), 3, axis=1))
    for channel, values in enumerate(channels, 1):
        encoded = ",".join("(%.7g,%.7g)" % tuple(row) for row in values[source_vertex])
        properties.append(f' texCoord2f[] primvars:st{channel} = [{encoded}] (interpolation = "vertex")')
    stage = stage.replace(" rel material:binding", "\n".join(properties) + "\n rel material:binding", 1)
    for name, location in [("LiftPocket", valley), ("LiftDirection", valley + 0.01 * axis)]:
        stage += (f'def Xform "{name}" {{\n double3 xformOp:translate = {triples([location])}\n'
                  ' uniform token[] xformOpOrder = ["xformOp:translate"]\n}\n')
    return stage + '}\n'


def package(source, out, mesh, manifest=None, matrices=None):
    # Match UV loops to the source faces before authoring optional motion channels.
    stage = subprocess.check_output(["usdcat", str(source)], text=True)
    data = re.search(r'int\[\] faceVertexIndices = \[([^\]]+)\]', stage)
    indices = np.fromstring(data.group(1), sep=",", dtype=np.int32)
    actual = np.empty(len(mesh.loops), dtype=np.int32)
    mesh.loops.foreach_get("vertex_index", actual)
    if not np.array_equal(actual, indices):
        raise ValueError("Blender loop order differs from the original geometry")
    uv = np.empty(len(mesh.loops)*2, dtype=np.float32)
    mesh.uv_layers.active.data.foreach_get("uv", uv)
    coords = ",".join("(%.7f,%.7f)" % tuple(pair) for pair in uv.reshape(-1, 2))
    pos = stage.index("{", stage.index('def Mesh "Airway"')) + 1
    stage = stage[:pos] + '\n rel material:binding = </Airway/Mucosa>\n texCoord2f[] primvars:st = [' + coords + '] (interpolation = "faceVarying")\n' + stage[pos:]
    stage = stage.replace('def Mesh "Airway"\n', 'def Mesh "Airway" (prepend apiSchemas = ["MaterialBindingAPI"])\n')
    shaders = ['''def Material "Mucosa" {
        token outputs:surface.connect = </Airway/Mucosa/Surface.outputs:surface>
        def Shader "Surface" {
            uniform token info:id = "UsdPreviewSurface"
            color3f inputs:diffuseColor.connect = </Airway/Mucosa/pigment.outputs:rgb>
            float inputs:roughness.connect = </Airway/Mucosa/roughness.outputs:r>
            normal3f inputs:normal.connect = </Airway/Mucosa/normal.outputs:rgb>
            token outputs:surface
        }
        def Shader "UV" {
            uniform token info:id = "UsdPrimvarReader_float2"
            string inputs:varname = "st"
            float2 outputs:result
        }''']
    for name in ["pigment", "roughness", "normal"]:
        color_space = "sRGB" if name == "pigment" else "raw"
        decode = 'float4 inputs:scale = (2,2,2,1)\nfloat4 inputs:bias = (-1,-1,-1,0)' if name == "normal" else ""
        shaders.append(f'''def Shader "{name}" {{
            uniform token info:id = "UsdUVTexture"
            asset inputs:file = @{name}.png@
            token inputs:sourceColorSpace = "{color_space}"
            float2 inputs:st.connect = </Airway/Mucosa/UV.outputs:result>
            {decode}
            float3 outputs:rgb
            float outputs:r
        }}''')
    end = stage.rindex("}")
    stage = stage[:end] + "\n".join(shaders) + "\n}\n" + stage[end:]
    if manifest:
        stage = add_tissue_lift(stage, manifest, indices, matrices)
    (out / "airway.usda").write_text(stage)
    subprocess.run(["usdcat", "airway.usda", "-o", "airway.usdc"], cwd=out, check=True)
    subprocess.run(["usdzip", "PrivateAirway.usdz", "airway.usdc", "pigment.png", "roughness.png", "normal.png"], cwd=out, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--region-manifest", type=Path, help="Matching mesh JSON beside its .bin and .landmarks.json")
    parser.add_argument("--studio", action="store_true", help="Author regional paint, papillae and corrective poses")
    args = parser.parse_args()
    if args.studio and not args.region_manifest:
        parser.error("--studio requires --region-manifest")
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if args.source.resolve() == out / "PrivateAirway.usdz":
        parser.error("Choose an output directory separate from the source asset")
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.wm.usd_import(filepath=str(args.source.resolve()))
    obj, = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.smart_project(angle_limit=1.35, island_margin=0.003)
    bpy.ops.object.mode_set(mode="OBJECT")
    if args.region_manifest:
        color_labeled_tissue(obj.data, args.region_manifest)
    material, pigment, roughness = create_material(obj.data, labeled=bool(args.region_manifest))
    matrices = None
    if args.studio:
        from airway_studio import prepare
        pigment, matrices = prepare(obj, material, pigment, args.region_manifest, out)
    bpy.context.preferences.filepaths.save_version = 0
    bake(material, pigment, roughness, out)
    package(args.source.resolve(), out, obj.data, args.region_manifest, matrices)
    bpy.ops.wm.save_as_mainfile(filepath=str(out / "Airway.blend"))
    if args.studio:
        # The bpy 4.2 wheel can crash in C++ destructors at Python shutdown
        # after these add-ons unregister. Finish this dedicated CLI process
        # only after synchronous writes and independent USD validation succeed.
        subprocess.run(["usdchecker", str(out / "PrivateAirway.usdz")], check=True)
        bpy.ops.wm.read_factory_settings(use_empty=True)
        sys.stdout.flush()
        sys.stderr.flush()
        os._exit(0)


if __name__ == "__main__":
    main()
