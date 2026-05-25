const assert = require("assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const zlib = require("zlib");
const {
	convertProject,
	extractEditXmlFromEfkefc,
	parseXml,
	writeLuauModule,
} = require("../src/converter");

const SIMPLE_PROJECT = `<?xml version="1.0" encoding="utf-8"?>
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
`;

function packUtf8(value) {
	const raw = Buffer.from(value, "utf8");
	const result = Buffer.alloc(2 + raw.length);
	result.writeUInt16LE(raw.length, 0);
	raw.copy(result, 2);
	return result;
}

function collectXml(node, keys, values) {
	if (!keys.has(node.name)) {
		keys.set(node.name, keys.size);
	}
	const text = node.text.trim();
	if (text && !values.has(text)) {
		values.set(text, values.size);
	}
	for (const child of node.children) {
		collectXml(child, keys, values);
	}
}

function int16(value) {
	const buffer = Buffer.alloc(2);
	buffer.writeInt16LE(value);
	return buffer;
}

function int32(value) {
	const buffer = Buffer.alloc(4);
	buffer.writeInt32LE(value);
	return buffer;
}

function writeElementList(nodes, keys, values) {
	const parts = [int16(nodes.length)];
	for (const node of nodes) {
		const text = node.text.trim();
		parts.push(int16(keys.get(node.name)));
		parts.push(int32(text ? 1 : 0));
		if (text) {
			parts.push(int16(values.get(text)));
		}
		parts.push(int32(node.children.length ? 1 : 0));
		if (node.children.length) {
			parts.push(writeElementList(node.children, keys, values));
		}
	}
	return Buffer.concat(parts);
}

function compressEditXml(xml) {
	const root = parseXml(xml);
	const keys = new Map();
	const values = new Map();
	collectXml(root, keys, values);

	const parts = [int16(keys.size)];
	for (const [key, index] of keys.entries()) {
		parts.push(packUtf8(key), int16(index));
	}
	parts.push(int16(values.size));
	for (const [value, index] of values.entries()) {
		parts.push(packUtf8(value), int16(index));
	}
	parts.push(writeElementList([root], keys, values));
	return zlib.deflateSync(Buffer.concat(parts));
}

function testProjectConversion() {
	const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "effekseer-roblox-"));
	const projectPath = path.join(tempDir, "simple.efkproj");
	const outputPath = path.join(tempDir, "Simple.luau");
	fs.writeFileSync(projectPath, SIMPLE_PROJECT);

	const effect = convertProject(projectPath, {
		textureMap: { "Texture/Particle.png": "rbxassetid://123" },
		frameRate: 60,
		unitScale: 0.01,
		particleSizeScale: 1,
		moduleName: "Simple",
	});
	writeLuauModule(effect, outputPath);

	assert.strictEqual(effect.nodes[0].name, "spark");
	assert.strictEqual(effect.nodes[0].texture, "rbxassetid://123");
	assert.strictEqual(effect.nodes[0].transform.emissionDirection, "Top");
	assert.deepStrictEqual(effect.warnings, []);
	assert(fs.readFileSync(outputPath, "utf8").includes("rbxassetid://123"));
}

function testRocsAssetMapResolution() {
	const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "effekseer-roblox-rocs-"));
	const projectPath = path.join(tempDir, "simple.efkproj");
	fs.mkdirSync(path.join(tempDir, "Texture"), { recursive: true });
	fs.writeFileSync(projectPath, SIMPLE_PROJECT);

	const sourcePath = path.join(tempDir, "Texture", "Particle.png").replace(/\\/g, "/");
	const effect = convertProject(projectPath, {
		rocsAssetMap: {
			bySourcePath: { [sourcePath]: "rbxassetid://456" },
			byRelativePath: {},
			groups: {},
		},
	});

	assert.strictEqual(effect.nodes[0].texture, "rbxassetid://456");
	assert.deepStrictEqual(effect.warnings, []);
}

function testEfkefcEditExtraction() {
	const compressed = compressEditXml(SIMPLE_PROJECT);
	const header = Buffer.concat([Buffer.from("EFKE"), int32(0), Buffer.from("EDIT")]);
	const size = Buffer.alloc(4);
	size.writeUInt32LE(compressed.length);
	const efkefc = Buffer.concat([header, size, compressed]);

	const xml = extractEditXmlFromEfkefc(efkefc);
	assert(xml.includes("<EffekseerProject>"));
	assert(xml.includes("<Name>spark</Name>"));
}

testProjectConversion();
testRocsAssetMapResolution();
testEfkefcEditExtraction();

console.log("All EffekseerForRoblox conversion tests passed.");
