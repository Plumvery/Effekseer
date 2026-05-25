#!/usr/bin/env python3
"""Convert Effekseer projects into Roblox Luau effect modules.

The converter reads .efkproj XML directly and can also extract the EDIT XML
chunk from .efkefc files. It intentionally targets a Roblox-friendly runtime
representation instead of the native Effekseer binary runtime.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import struct
import sys
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable
import xml.etree.ElementTree as ET


DEFAULT_FRAME_RATE = 60.0
DEFAULT_UNIT_SCALE = 0.01
DEFAULT_PARTICLE_SIZE_SCALE = 1.0

RENDERER_TYPES = {
    0: "None",
    2: "Sprite",
    3: "Ribbon",
    4: "Ring",
    5: "Model",
    6: "Track",
}

SUPPORTED_RENDERERS = {"Sprite", "Ribbon", "Ring", "Track"}

LUA_RESERVED = {
    "and",
    "break",
    "do",
    "else",
    "elseif",
    "end",
    "false",
    "for",
    "function",
    "if",
    "in",
    "local",
    "nil",
    "not",
    "or",
    "repeat",
    "return",
    "then",
    "true",
    "until",
    "while",
}


@dataclass
class WarningRecord:
    code: str
    message: str
    node: str | None = None

    def as_dict(self) -> dict[str, str]:
        result = {"code": self.code, "message": self.message}
        if self.node:
            result["node"] = self.node
        return result


class BinaryCursor:
    def __init__(self, data: bytes) -> None:
        self.data = data
        self.offset = 0

    def read(self, size: int) -> bytes:
        if self.offset + size > len(self.data):
            raise ValueError("Unexpected end of Effekseer binary data")
        value = self.data[self.offset : self.offset + size]
        self.offset += size
        return value

    def int16(self) -> int:
        return struct.unpack_from("<h", self.read(2))[0]

    def uint16(self) -> int:
        return struct.unpack_from("<H", self.read(2))[0]

    def int32(self) -> int:
        return struct.unpack_from("<i", self.read(4))[0]

    def bool32(self) -> bool:
        return self.int32() > 0

    def utf8_len16(self) -> str:
        size = self.uint16()
        return self.read(size).decode("utf-8")


def load_project_xml(path: Path) -> ET.Element:
    suffix = path.suffix.lower()
    if suffix == ".efkefc":
        return ET.fromstring(extract_edit_xml_from_efkefc(path.read_bytes()))
    return ET.parse(path).getroot()


def extract_edit_xml_from_efkefc(data: bytes) -> bytes:
    if len(data) < 16 or data[:4] != b"EFKE":
        raise ValueError("Not an Effekseer .efkefc file")

    offset = 8
    while offset + 8 <= len(data):
        chunk_name = data[offset : offset + 4].decode("utf-8", errors="replace")
        offset += 4
        chunk_size = struct.unpack_from("<I", data, offset)[0]
        offset += 4
        chunk_data = data[offset : offset + chunk_size]
        offset += chunk_size

        if chunk_name == "EDIT":
            return decompress_edit_xml(chunk_data)

    raise ValueError("The .efkefc file does not contain an EDIT chunk")


def decompress_edit_xml(data: bytes) -> bytes:
    payload = zlib.decompress(data)
    reader = BinaryCursor(payload)

    key_count = reader.int16()
    keys: dict[int, str] = {}
    for _ in range(key_count):
        name = reader.utf8_len16()
        index = reader.int16()
        keys[index] = name

    value_count = reader.int16()
    values: dict[int, str] = {}
    for _ in range(value_count):
        value = reader.utf8_len16()
        index = reader.int16()
        values[index] = value

    root = ET.Element("__root__")

    def read_elements(parent: ET.Element) -> None:
        element_count = reader.int16()
        for _ in range(element_count):
            name_index = reader.int16()
            element = ET.SubElement(parent, keys[name_index])
            if reader.bool32():
                value_index = reader.int16()
                element.text = values[value_index]
            if reader.bool32():
                read_elements(element)

    read_elements(root)

    if len(root) != 1:
        raise ValueError("EDIT chunk did not contain exactly one XML root")

    return ET.tostring(root[0], encoding="utf-8", xml_declaration=True)


def text_at(element: ET.Element, path: str) -> str | None:
    found = element.find(path)
    if found is None or found.text is None:
        return None
    value = found.text.strip()
    return value if value != "" else None


def number_at(element: ET.Element, path: str, default: float) -> float:
    value = text_at(element, path)
    if value is None:
        return default
    try:
        return float(value)
    except ValueError:
        return default


def int_at(element: ET.Element, path: str, default: int) -> int:
    return int(round(number_at(element, path, float(default))))


def bool_at(element: ET.Element, path: str, default: bool) -> bool:
    value = text_at(element, path)
    if value is None:
        return default
    return value.lower() in {"1", "true", "yes"}


def random_number_at(element: ET.Element, path: str, default: float) -> dict[str, float]:
    base = element.find(path)
    if base is None:
        return {"center": default, "min": default, "max": default}

    direct = None
    if base.text and base.text.strip():
        try:
            direct = float(base.text.strip())
        except ValueError:
            direct = None

    min_text = text_at(base, "Min")
    max_text = text_at(base, "Max")
    center_text = text_at(base, "Center")

    def parse(value: str | None) -> float | None:
        if value is None:
            return None
        try:
            return float(value)
        except ValueError:
            return None

    min_value = parse(min_text)
    max_value = parse(max_text)
    center_value = parse(center_text)

    if center_value is None and min_value is not None and max_value is not None:
        center_value = (min_value + max_value) * 0.5
    if center_value is None:
        center_value = direct if direct is not None else default
    if min_value is None:
        min_value = center_value
    if max_value is None:
        max_value = center_value

    if min_value > max_value:
        min_value, max_value = max_value, min_value

    return {"center": center_value, "min": min_value, "max": max_value}


def fixed_vector_at(element: ET.Element, path: str, default: tuple[float, float, float]) -> dict[str, float]:
    return {
        "x": number_at(element, f"{path}/X", default[0]),
        "y": number_at(element, f"{path}/Y", default[1]),
        "z": number_at(element, f"{path}/Z", default[2]),
    }


def random_vector_at(element: ET.Element, path: str, default: tuple[float, float, float]) -> dict[str, Any]:
    axes = {
        "x": random_number_at(element, f"{path}/X", default[0]),
        "y": random_number_at(element, f"{path}/Y", default[1]),
        "z": random_number_at(element, f"{path}/Z", default[2]),
    }
    return {
        "center": {axis: axes[axis]["center"] for axis in axes},
        "min": {axis: axes[axis]["min"] for axis in axes},
        "max": {axis: axes[axis]["max"] for axis in axes},
    }


def vector_magnitude(vector: dict[str, float]) -> float:
    return math.sqrt(vector["x"] * vector["x"] + vector["y"] * vector["y"] + vector["z"] * vector["z"])


def dominant_direction(vector: dict[str, float]) -> str:
    values = [
        ("Right", vector["x"]),
        ("Top", vector["y"]),
        ("Back", vector["z"]),
    ]
    axis, value = max(values, key=lambda item: abs(item[1]))
    if abs(value) < 1e-6:
        return "Top"
    if axis == "Right" and value < 0:
        return "Left"
    if axis == "Top" and value < 0:
        return "Bottom"
    if axis == "Back" and value < 0:
        return "Front"
    return axis


def spread_from_range(velocity: dict[str, Any]) -> float:
    center = velocity["center"]
    max_delta = 0.0
    for axis in ("x", "y", "z"):
        max_delta = max(max_delta, abs(velocity["max"][axis] - center[axis]), abs(center[axis] - velocity["min"][axis]))
    speed = max(vector_magnitude(center), 1e-6)
    return max(0.0, min(180.0, math.degrees(math.atan2(max_delta, speed)) * 2.0))


def color_at(element: ET.Element, candidates: Iterable[str]) -> dict[str, int]:
    for path in candidates:
        base = element.find(path)
        if base is None:
            continue
        return {
            "r": int_at(base, "R", 255),
            "g": int_at(base, "G", 255),
            "b": int_at(base, "B", 255),
            "a": int_at(base, "A", 255),
        }
    return {"r": 255, "g": 255, "b": 255, "a": 255}


def renderer_type_for(node: ET.Element) -> str:
    renderer_id = int_at(node, "DrawingValues/Type", 2)
    return RENDERER_TYPES.get(renderer_id, f"Unknown{renderer_id}")


def generation_time(node: ET.Element) -> dict[str, float]:
    common = node.find("CommonValues")
    if common is None:
        return {"center": 1.0, "min": 1.0, "max": 1.0}
    nested = random_number_at(common, "Generation/GenerationTime", 1.0)
    legacy = random_number_at(common, "GenerationTime", nested["center"])
    if common.find("Generation/GenerationTime") is None and common.find("GenerationTime") is not None:
        return legacy
    return nested


def generation_offset(node: ET.Element) -> dict[str, float]:
    common = node.find("CommonValues")
    if common is None:
        return {"center": 0.0, "min": 0.0, "max": 0.0}
    nested = random_number_at(common, "Generation/GenerationTimeOffset", 0.0)
    legacy = random_number_at(common, "GenerationTimeOffset", nested["center"])
    if common.find("Generation/GenerationTimeOffset") is None and common.find("GenerationTimeOffset") is not None:
        return legacy
    return nested


def node_life(node: ET.Element) -> dict[str, float]:
    common = node.find("CommonValues")
    if common is None:
        return {"center": 100.0, "min": 100.0, "max": 100.0}
    return random_number_at(common, "Life", 100.0)


def max_generation(node: ET.Element) -> int:
    common = node.find("CommonValues")
    if common is None:
        return 1
    if bool_at(common, "MaxGeneration/Infinite", False):
        return 0
    return max(0, int_at(common, "MaxGeneration/Value", 1))


def location_payload(node: ET.Element, warnings: list[WarningRecord], node_name: str) -> dict[str, Any]:
    location_type = int_at(node, "LocationValues/Type", 0)
    position = {"x": 0.0, "y": 0.0, "z": 0.0}
    velocity = {
        "center": {"x": 0.0, "y": 0.0, "z": 0.0},
        "min": {"x": 0.0, "y": 0.0, "z": 0.0},
        "max": {"x": 0.0, "y": 0.0, "z": 0.0},
    }
    acceleration = dict(velocity)

    if location_type == 0:
        position = fixed_vector_at(node, "LocationValues/Fixed/Location", (0.0, 0.0, 0.0))
    elif location_type == 1:
        pva = "LocationValues/PVA"
        position = random_vector_at(node, f"{pva}/Location", (0.0, 0.0, 0.0))["center"]
        velocity = random_vector_at(node, f"{pva}/Velocity", (0.0, 0.0, 0.0))
        acceleration = random_vector_at(node, f"{pva}/Acceleration", (0.0, 0.0, 0.0))
    elif location_type == 2:
        position = random_vector_at(node, "LocationValues/Easing/Start", (0.0, 0.0, 0.0))["center"]
        warnings.append(WarningRecord("location_easing", "Location easing is approximated as the start position.", node_name))
    elif location_type == 3:
        warnings.append(WarningRecord("location_fcurve", "Location FCurve is not evaluated by the Roblox runtime yet.", node_name))
    else:
        warnings.append(WarningRecord("location_unsupported", f"Location type {location_type} is not supported.", node_name))

    return {
        "type": location_type,
        "position": position,
        "velocity": velocity,
        "acceleration": acceleration,
        "emissionDirection": dominant_direction(velocity["center"]),
        "spreadAngle": spread_from_range(velocity),
    }


def rotation_payload(node: ET.Element) -> dict[str, Any]:
    rotation_type = int_at(node, "RotationValues/Type", 0)
    rotation = {"center": 0.0, "min": 0.0, "max": 0.0}
    speed = {"center": 0.0, "min": 0.0, "max": 0.0}
    if rotation_type == 0:
        z = number_at(node, "RotationValues/Fixed/Rotation/Z", 0.0)
        rotation = {"center": z, "min": z, "max": z}
    elif rotation_type == 1:
        rotation = random_number_at(node, "RotationValues/PVA/Rotation/Z", 0.0)
        speed = random_number_at(node, "RotationValues/PVA/Velocity/Z", 0.0)
    elif rotation_type == 3:
        rotation = random_number_at(node, "RotationValues/AxisPVA/Rotation", 0.0)
        speed = random_number_at(node, "RotationValues/AxisPVA/Velocity", 0.0)
    return {"type": rotation_type, "rotation": rotation, "speed": speed}


def scale_payload(node: ET.Element, life: dict[str, float]) -> dict[str, float]:
    scale_type = int_at(node, "ScalingValues/Type", 0)
    start = 1.0
    finish = 1.0
    envelope = 0.0

    if scale_type == 0:
        scale = fixed_vector_at(node, "ScalingValues/Fixed/Scale", (1.0, 1.0, 1.0))
        start = max(0.0, (abs(scale["x"]) + abs(scale["y"])) * 0.5)
        finish = start
    elif scale_type == 1:
        base = random_vector_at(node, "ScalingValues/PVA/Scale", (1.0, 1.0, 1.0))
        velocity = random_vector_at(node, "ScalingValues/PVA/Velocity", (0.0, 0.0, 0.0))
        acceleration = random_vector_at(node, "ScalingValues/PVA/Acceleration", (0.0, 0.0, 0.0))
        start = max(0.0, (abs(base["center"]["x"]) + abs(base["center"]["y"])) * 0.5)
        life_frames = life["center"]
        end_x = base["center"]["x"] + velocity["center"]["x"] * life_frames + 0.5 * acceleration["center"]["x"] * life_frames * life_frames
        end_y = base["center"]["y"] + velocity["center"]["y"] * life_frames + 0.5 * acceleration["center"]["y"] * life_frames * life_frames
        finish = max(0.0, (abs(end_x) + abs(end_y)) * 0.5)
        envelope = max(0.0, (base["max"]["x"] - base["min"]["x"] + base["max"]["y"] - base["min"]["y"]) * 0.25)
    elif scale_type == 3:
        base = random_number_at(node, "ScalingValues/SinglePVA/Scale", 1.0)
        velocity = random_number_at(node, "ScalingValues/SinglePVA/Velocity", 0.0)
        acceleration = random_number_at(node, "ScalingValues/SinglePVA/Acceleration", 0.0)
        start = max(0.0, abs(base["center"]))
        life_frames = life["center"]
        finish = max(0.0, abs(base["center"] + velocity["center"] * life_frames + 0.5 * acceleration["center"] * life_frames * life_frames))
        envelope = max(0.0, (base["max"] - base["min"]) * 0.5)

    if finish == 0.0:
        finish = start
    return {"type": scale_type, "start": start, "finish": finish, "envelope": envelope}


def texture_path_for(node: ET.Element) -> str:
    return (
        text_at(node, "RendererCommonValues/ColorTexture")
        or text_at(node, "DrawingValues/Sprite/ColorTexture")
        or text_at(node, "DrawingValues/Ribbon/ColorTexture")
        or text_at(node, "DrawingValues/Ring/ColorTexture")
        or ""
    )


def convert_node(
    node: ET.Element,
    texture_map: dict[str, str],
    warnings: list[WarningRecord],
    dependencies: set[str],
    id_prefix: str,
) -> dict[str, Any]:
    node_name = text_at(node, "Name") or f"Node{id_prefix}"
    renderer_type = renderer_type_for(node)
    rendered = bool_at(node, "IsRendered", True) and renderer_type != "None"
    life = node_life(node)
    texture_path = texture_path_for(node)
    if texture_path:
        dependencies.add(texture_path)

    if rendered and renderer_type not in SUPPORTED_RENDERERS:
        warnings.append(WarningRecord("renderer_unsupported", f"Renderer {renderer_type} is not supported by the Roblox runtime.", node_name))
        rendered = False

    if rendered and texture_path and texture_path not in texture_map:
        warnings.append(WarningRecord("texture_unmapped", f"No Roblox asset id mapped for texture '{texture_path}'.", node_name))

    velocity = location_payload(node, warnings, node_name)
    speed_min = vector_magnitude(velocity["velocity"]["min"])
    speed_max = vector_magnitude(velocity["velocity"]["max"])
    if speed_min > speed_max:
        speed_min, speed_max = speed_max, speed_min

    color = color_at(
        node,
        [
            "DrawingValues/ColorAll/Fixed",
            "DrawingValues/Sprite/ColorAll_Fixed",
            "DrawingValues/Ribbon/ColorAll_Fixed",
            "DrawingValues/Ring/ColorAll_Fixed",
            "DrawingValues/Track/ColorCenterMiddle_Fixed",
        ],
    )

    children = []
    children_root = node.find("Children")
    if children_root is not None:
        for index, child in enumerate(children_root.findall("Node"), start=1):
            children.append(convert_node(child, texture_map, warnings, dependencies, f"{id_prefix}_{index}"))

    return {
        "id": id_prefix,
        "name": node_name,
        "rendererType": renderer_type,
        "rendered": rendered,
        "texturePath": texture_path,
        "texture": texture_map.get(texture_path),
        "alphaBlend": int_at(node, "RendererCommonValues/AlphaBlend", 1),
        "zTest": bool_at(node, "RendererCommonValues/ZTest", True),
        "fadeIn": number_at(node, "RendererCommonValues/FadeIn/Frame", 0.0),
        "fadeOut": number_at(node, "RendererCommonValues/FadeOut/Frame", 0.0),
        "color": color,
        "life": life,
        "generation": {
            "max": max_generation(node),
            "time": generation_time(node),
            "offset": generation_offset(node),
        },
        "transform": {
            "position": velocity["position"],
            "velocity": velocity["velocity"],
            "acceleration": velocity["acceleration"],
            "speed": {"min": speed_min, "max": speed_max},
            "emissionDirection": velocity["emissionDirection"],
            "spreadAngle": velocity["spreadAngle"],
            "rotation": rotation_payload(node),
            "size": scale_payload(node, life),
        },
        "children": children,
    }


def convert_project(
    source: Path,
    texture_map: dict[str, str],
    frame_rate: float,
    unit_scale: float,
    particle_size_scale: float,
    module_name: str | None = None,
) -> dict[str, Any]:
    root = load_project_xml(source)
    if root.tag != "EffekseerProject":
        raise ValueError(f"Expected EffekseerProject XML root, got {root.tag!r}")

    warnings: list[WarningRecord] = []
    dependencies: set[str] = set()
    nodes: list[dict[str, Any]] = []
    children_root = root.find("Root/Children")
    if children_root is not None:
        for index, child in enumerate(children_root.findall("Node"), start=1):
            nodes.append(convert_node(child, texture_map, warnings, dependencies, str(index)))

    return {
        "format": "EffekseerRobloxEffect",
        "formatVersion": 1,
        "name": module_name or source.stem,
        "source": str(source).replace("\\", "/"),
        "frameRate": frame_rate,
        "unitScale": unit_scale,
        "particleSizeScale": particle_size_scale,
        "dependencies": {
            "textures": sorted(dependencies),
        },
        "warnings": [warning.as_dict() for warning in warnings],
        "nodes": nodes,
    }


def lua_key(key: str) -> str:
    if re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", key) and key not in LUA_RESERVED:
        return key
    return f"[{json.dumps(key)}]"


def lua_number(value: float | int) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if math.isfinite(value) and value.is_integer():
        return str(int(value))
    return format(value, ".9g")


def to_luau(value: Any, indent: int = 0) -> str:
    pad = "\t" * indent
    child_pad = "\t" * (indent + 1)

    if value is None:
        return "nil"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return lua_number(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, list):
        if not value:
            return "{}"
        lines = ["{"]
        for item in value:
            lines.append(f"{child_pad}{to_luau(item, indent + 1)},")
        lines.append(f"{pad}}}")
        return "\n".join(lines)
    if isinstance(value, dict):
        if not value:
            return "{}"
        lines = ["{"]
        for key, item in value.items():
            if item is None:
                continue
            lines.append(f"{child_pad}{lua_key(str(key))} = {to_luau(item, indent + 1)},")
        lines.append(f"{pad}}}")
        return "\n".join(lines)
    raise TypeError(f"Cannot serialize {type(value)!r} to Luau")


def write_luau_module(effect: dict[str, Any], output: Path) -> None:
    body = to_luau(effect)
    contents = "\n".join(
        [
            "-- Generated by Tool/EffekseerForRoblox/effekseer_to_roblox.py.",
            "-- Regenerate this file from the source Effekseer project instead of editing by hand.",
            f"-- Source: {effect['source']}",
            "",
            f"return {body}",
            "",
        ]
    )
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(contents, encoding="utf-8", newline="\n")


def load_texture_map(path: Path | None) -> dict[str, str]:
    if path is None:
        return {}
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError("Texture map must be a JSON object")
    return {str(key).replace("\\", "/"): str(value) for key, value in data.items()}


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Convert .efkproj/.efkefc files into Roblox Luau effect modules.")
    parser.add_argument("input", type=Path, help="Effekseer .efkproj or .efkefc file")
    parser.add_argument("-o", "--output", type=Path, required=True, help="Output .luau ModuleScript path")
    parser.add_argument("--texture-map", type=Path, help="JSON mapping from Effekseer texture paths to rbxassetid:// values")
    parser.add_argument("--module-name", help="Effect name stored in the generated module")
    parser.add_argument("--frame-rate", type=float, default=DEFAULT_FRAME_RATE, help="Effekseer frame rate used for seconds conversion")
    parser.add_argument("--unit-scale", type=float, default=DEFAULT_UNIT_SCALE, help="Effekseer world unit to Roblox stud scale")
    parser.add_argument("--particle-size-scale", type=float, default=DEFAULT_PARTICLE_SIZE_SCALE, help="Multiplier for ParticleEmitter.Size")
    parser.add_argument("--warnings-json", type=Path, help="Optional path to write converter warnings as JSON")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    texture_map = load_texture_map(args.texture_map)
    effect = convert_project(
        args.input,
        texture_map=texture_map,
        frame_rate=args.frame_rate,
        unit_scale=args.unit_scale,
        particle_size_scale=args.particle_size_scale,
        module_name=args.module_name,
    )
    write_luau_module(effect, args.output)

    warnings = effect["warnings"]
    if args.warnings_json:
        args.warnings_json.parent.mkdir(parents=True, exist_ok=True)
        args.warnings_json.write_text(json.dumps(warnings, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    for warning in warnings:
        node = f"[{warning['node']}] " if "node" in warning else ""
        print(f"warning {warning['code']}: {node}{warning['message']}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
