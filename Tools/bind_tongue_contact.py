"""Bind a labeled tongue and nominal dorsal blade profile to a registered research USDZ."""
import argparse
import json
import re
import subprocess
import tempfile
from pathlib import Path
from zipfile import ZipFile

import numpy as np
from scipy.spatial import cKDTree


def points(stage):
    value = re.search(r'point3f\[\] points = \[([^\]]+)\]', stage)[1]
    return np.fromstring(value.replace("(", "").replace(")", ""), sep=",").reshape(-1, 3)


def bind(asset, original, manifest, section, output):
    meta = json.loads(manifest.read_text())
    region = meta["layout"]["region"]
    raw = manifest.with_suffix(".bin").read_bytes()
    regions = np.frombuffer(raw, "<f4", region["count"], region["offset"])
    names = json.loads(manifest.with_suffix(".landmarks.json").read_text())["regions"]
    original_points = points(original.read_text())
    if len(original_points) != len(regions):
        raise ValueError("Region labels and original geometry differ")
    data = np.load(section)
    forward = data["forward"]
    right = np.cross(forward, [0, 1, 0])
    right /= np.linalg.norm(right)
    basis = np.column_stack((right, np.cross(right, forward), -forward))
    contour = (data["profile"] - data["lens"]) @ basis
    tip = (data["tip"] - data["lens"]) @ basis
    samples = []
    for fraction in (0.08, 0.5, 0.90):
        band = contour[np.abs(contour[:, 2] - tip[2] * fraction) < 1.0]
        samples.append(band[band[:, 1].argmax()] / 1000)
    samples.append(tip / 1000)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent) as tmp:
        base = Path(tmp)
        with ZipFile(asset) as z:
            members = z.namelist()
            for name in members:
                if Path(name).name != name:
                    raise ValueError("Expected flat research package")
                z.extract(name, base)
        stage = subprocess.check_output(["usdcat", str(base / "airway.usdc")], text=True)
        distance, idx = cKDTree(original_points).query(points(stage))
        if distance.max() > 0.000003 or "primvars:st6 " in stage:
            raise ValueError("Expected original registered mesh before tongue binding")
        mask = regions[idx] == names.index("tongue")
        if not mask.any():
            raise ValueError("Empty tongue")
        attr = 'texCoord2f[] primvars:st6 = [' + ','.join('(1,0)' if m else '(0,0)' for m in mask)
        attr += '] (interpolation = "vertex")'
        at = stage.index('texCoord2f[] primvars:st1')
        stage = stage[:at] + attr + '\n' + stage[at:]
        at = stage.index('{', stage.index('def Xform "BladeGuide"')) + 1
        nodes = []
        for i, p in enumerate(samples):
            xyz = ",".join(format(v, ".9g") for v in p)
            nodes.append(f'def Xform "Dorsal{i}" {{\n double3 xformOp:translate = ({xyz})\n'
                         ' uniform token[] xformOpOrder = ["xformOp:translate"]\n}')
        stage = stage[:at] + '\n' + '\n'.join(nodes) + stage[at:]
        (base / "contact.usda").write_text(stage)
        subprocess.run(["usdcat", "contact.usda", "-o", "airway.usdc"], cwd=base, check=True)
        subprocess.run(["usdzip", "contact.usdz", *members], cwd=base, check=True)
        subprocess.run(["usdchecker", "contact.usdz"], cwd=base, check=True)
        (base / "contact.usdz").replace(output)
        print("Labeled tongue vertices:", mask.sum(), "of", len(mask))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for arg in ("asset", "original", "manifest", "section", "output"):
        parser.add_argument(arg, type=Path)
    bind(**vars(parser.parse_args()))
