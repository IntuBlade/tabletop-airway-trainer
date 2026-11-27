"""Author a private airway appearance with Blender 4.2 (bpy) and Apple USD tools.

Usage: python author_airway.py input.usdz output_directory
The input must be the meter-scale single-mesh airway with vertex displayColor.
Only the material and UVs are added to the original USD geometry.
"""
import argparse
from pathlib import Path
import re
import subprocess

import bpy
import numpy as np


def create_material(mesh):
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
    link(tone, pigment.inputs[2])
    link(pigment.outputs[0], surface.inputs["Base Color"])
    roughness = gradient("Moisture variation", variation("Moisture", 440, 2, 0.25),
                         (0.19,)*3, (0.41,)*3)
    link(roughness, surface.inputs["Roughness"])
    bump = nodes.new("ShaderNodeBump")
    bump.label = "Fine surface relief"
    bump.inputs["Strength"].default_value = 0.22
    bump.inputs["Distance"].default_value = 0.00012
    link(variation("Fine grain", 1750, 2, 0.12), bump.inputs["Height"])
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


def package(source, out, mesh):
    # Carry the original vertex order, normals, faces, units and axes through.
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
    (out / "airway.usda").write_text(stage)
    subprocess.run(["usdcat", "airway.usda", "-o", "airway.usdc"], cwd=out, check=True)
    subprocess.run(["usdzip", "PrivateAirway.usdz", "airway.usdc", "pigment.png", "roughness.png", "normal.png"], cwd=out, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
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
    material, pigment, roughness = create_material(obj.data)
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.wm.save_as_mainfile(filepath=str(out / "Airway.blend"))
    bake(material, pigment, roughness, out)
    package(args.source.resolve(), out, obj.data)


if __name__ == "__main__":
    main()
