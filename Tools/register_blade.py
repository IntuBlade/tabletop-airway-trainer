"""Embed a mesh-specific blade path in a private studio airway USDZ."""
import argparse
import hashlib
import json
import math
import subprocess
import tempfile
from pathlib import Path
from zipfile import ZipFile


def vector(values, count):
    if len(values) != count or not all(math.isfinite(v) for v in values):
        raise ValueError("Expected a finite coordinate vector")
    return "(" + ", ".join(format(float(v), ".10g") for v in values) + ")"


def station(name, position, orientation=None):
    operations = ['"xformOp:translate"']
    fields = [f"double3 xformOp:translate = {vector(position, 3)}"]
    if orientation is not None:
        if abs(math.hypot(*orientation) - 1) > 1e-5:
            raise ValueError("Expected a unit lens orientation in WXYZ order")
        fields.append(f"quatf xformOp:orient = {vector(orientation, 4)}")
        operations.append('"xformOp:orient"')
    fields.append("uniform token[] xformOpOrder = [" + ", ".join(operations) + "]")
    return f'def Xform "{name}" {{\n' + "\n".join(fields) + "\n}"


def register(source, profile, output):
    if source.resolve() == output.resolve():
        raise ValueError("Keep the original authored airway as a separate file")
    if hashlib.sha256(source.read_bytes()).hexdigest() != profile["airway_sha256"]:
        raise ValueError("The profile was measured on a different airway")
    nodes = [
        station("TipInLens", profile["tip_in_lens_m"]),
        station("EntryLens", profile["entry_lens_m"], profile["entry_wxyz"]),
        station("MiddleTip", profile["middle_tip_m"]),
        station("SeatedTip", profile["seated_tip_m"], profile["seated_wxyz"]),
        station("RaisedTip", profile["raised_tip_m"]),
    ]
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent) as tmp:
        directory = Path(tmp)
        names = ["airway.usdc", "pigment.png", "roughness.png", "normal.png"]
        with ZipFile(source) as archive:
            if set(archive.namelist()) != set(names):
                raise ValueError("Expected the four studio airway package members")
            for name in names:
                archive.extract(name, directory)
        stage = subprocess.check_output(["usdcat", str(directory / names[0])], text=True)
        if 'defaultPrim = "Rig"' not in stage or 'def Xform "BladeGuide"' in stage:
            raise ValueError("Expected an unregistered studio rig")
        body, end, trailing = stage.rpartition("}")
        if not end or trailing.strip():
            raise ValueError("Invalid studio root")
        (directory / "registered.usda").write_text(
            body + 'def Xform "BladeGuide" {\n' + "\n".join(nodes) + "\n}\n}\n"
        )
        subprocess.run(["usdcat", "registered.usda", "-o", names[0]], cwd=directory, check=True)
        subprocess.run(["usdzip", "registered.usdz", *names], cwd=directory, check=True)
        package = directory / "registered.usdz"
        subprocess.run(["usdchecker", str(package)], check=True)
        package.replace(output)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for arg in ["source", "profile", "output"]:
        parser.add_argument(arg, type=Path)
    args = parser.parse_args()
    register(args.source, json.loads(args.profile.read_text()), args.output)
