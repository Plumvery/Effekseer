from __future__ import annotations

import struct
import sys
import tempfile
import unittest
import zlib
from pathlib import Path
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from effekseer_to_roblox import convert_project, extract_edit_xml_from_efkefc, write_luau_module


SIMPLE_PROJECT = """<?xml version="1.0" encoding="utf-8"?>
<EffekseerProject>
  <Root>
    <Children>
      <Node>
        <CommonValues>
          <MaxGeneration><Value>4</Value></MaxGeneration>
          <Life><Center>30</Center><Min>20</Min><Max>40</Max></Life>
          <GenerationTime><Center>2</Center><Min>2</Min><Max>2</Max></GenerationTime>
        </CommonValues>
        <LocationValues>
          <Type>1</Type>
          <PVA>
            <Velocity>
              <Y><Center>0.2</Center><Min>0.1</Min><Max>0.3</Max></Y>
            </Velocity>
          </PVA>
        </LocationValues>
        <ScalingValues>
          <Type>3</Type>
          <SinglePVA>
            <Scale><Center>0.5</Center><Min>0.25</Min><Max>0.75</Max></Scale>
          </SinglePVA>
        </ScalingValues>
        <RendererCommonValues>
          <ColorTexture>Texture/Particle.png</ColorTexture>
          <AlphaBlend>2</AlphaBlend>
        </RendererCommonValues>
        <DrawingValues>
          <Sprite>
            <ColorAll_Fixed><R>128</R><G>64</G><B>255</B><A>200</A></ColorAll_Fixed>
          </Sprite>
        </DrawingValues>
        <Name>spark</Name>
        <Children />
      </Node>
    </Children>
  </Root>
</EffekseerProject>
"""


def _pack_utf8(value: str) -> bytes:
    raw = value.encode("utf-8")
    return struct.pack("<H", len(raw)) + raw


def _compress_edit_xml(xml: str) -> bytes:
    root = ET.fromstring(xml)
    key_to_index: dict[str, int] = {}
    value_to_index: dict[str, int] = {}

    def register(element: ET.Element) -> None:
        key_to_index.setdefault(element.tag, len(key_to_index))
        text = (element.text or "").strip()
        if text:
            value_to_index.setdefault(text, len(value_to_index))
        for child in list(element):
            register(child)

    register(root)

    def write_element_list(elements: list[ET.Element]) -> bytes:
        data = bytearray(struct.pack("<h", len(elements)))
        for element in elements:
            text = (element.text or "").strip()
            children = list(element)
            data += struct.pack("<h", key_to_index[element.tag])
            data += struct.pack("<i", 1 if text else 0)
            if text:
                data += struct.pack("<h", value_to_index[text])
            data += struct.pack("<i", 1 if children else 0)
            if children:
                data += write_element_list(children)
        return bytes(data)

    payload = bytearray()
    payload += struct.pack("<h", len(key_to_index))
    for key, index in key_to_index.items():
        payload += _pack_utf8(key)
        payload += struct.pack("<h", index)
    payload += struct.pack("<h", len(value_to_index))
    for value, index in value_to_index.items():
        payload += _pack_utf8(value)
        payload += struct.pack("<h", index)
    payload += write_element_list([root])
    return zlib.compress(bytes(payload))


class EffekseerToRobloxTests(unittest.TestCase):
    def test_converts_project_to_effect_data_and_luau(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            project_path = Path(tmp) / "simple.efkproj"
            output_path = Path(tmp) / "Simple.luau"
            project_path.write_text(SIMPLE_PROJECT, encoding="utf-8")

            effect = convert_project(
                project_path,
                texture_map={"Texture/Particle.png": "rbxassetid://123"},
                frame_rate=60,
                unit_scale=0.01,
                particle_size_scale=1,
                module_name="Simple",
            )
            write_luau_module(effect, output_path)

            self.assertEqual(effect["nodes"][0]["name"], "spark")
            self.assertEqual(effect["nodes"][0]["texture"], "rbxassetid://123")
            self.assertEqual(effect["nodes"][0]["transform"]["emissionDirection"], "Top")
            self.assertEqual(effect["warnings"], [])
            self.assertIn("rbxassetid://123", output_path.read_text(encoding="utf-8"))

    def test_extracts_edit_xml_from_efkefc(self) -> None:
        compressed = _compress_edit_xml(SIMPLE_PROJECT)
        efkefc = b"EFKE" + struct.pack("<i", 0) + b"EDIT" + struct.pack("<I", len(compressed)) + compressed

        xml_bytes = extract_edit_xml_from_efkefc(efkefc)
        root = ET.fromstring(xml_bytes)

        self.assertEqual(root.tag, "EffekseerProject")
        self.assertEqual(root.findtext("Root/Children/Node/Name"), "spark")


if __name__ == "__main__":
    unittest.main()
