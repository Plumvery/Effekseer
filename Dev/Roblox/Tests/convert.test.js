const assert = require("assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const zlib = require("zlib");
const { main } = require("../src/cli");
const {
	convertProject,
	extractEditXmlFromEfkefc,
	parseXml,
	writeLuauModule,
} = require("../src/converter");

const SIMPLE_NODE = `
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
`;

const SIMPLE_PROJECT = createProject(SIMPLE_NODE);

function createProject(nodesXml) {
	return `<?xml version="1.0" encoding="utf-8"?>
<EffekseerProject>
  <Root>
    <Children>
      ${nodesXml}
    </Children>
  </Root>
</EffekseerProject>
`;
}

function tempDir(prefix = "effekseer-roblox-") {
	return fs.mkdtempSync(path.join(os.tmpdir(), prefix));
}

function writeTempProject(xml, prefix) {
	const dir = tempDir(prefix);
	const projectPath = path.join(dir, "effect.efkproj");
	fs.writeFileSync(projectPath, xml);
	return { dir, projectPath };
}

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

function chunk(name, data) {
	const size = Buffer.alloc(4);
	size.writeUInt32LE(data.length);
	return Buffer.concat([Buffer.from(name), size, data]);
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

function makeEfkefc(xml, extraChunks = []) {
	const compressed = compressEditXml(xml);
	return Buffer.concat([Buffer.from("EFKE"), int32(0), ...extraChunks, chunk("EDIT", compressed)]);
}

function warningCodes(effect) {
	return effect.warnings.map((warning) => warning.code);
}

function countWarnings(effect, code) {
	return warningCodes(effect).filter((candidate) => candidate === code).length;
}

async function withMutedConsole(callback) {
	const originalError = console.error;
	console.error = () => {};
	try {
		await callback();
	} finally {
		console.error = originalError;
	}
}

const tests = [];

function test(name, callback) {
	tests.push({ name, callback });
}

test("converts a sprite project into effect data and generated Luau", () => {
	const { dir, projectPath } = writeTempProject(SIMPLE_PROJECT, "effekseer-roblox-simple-");
	const outputPath = path.join(dir, "Simple.luau");

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
	assert.strictEqual(effect.nodes[0].alphaBlend, 2);
	assert.strictEqual(effect.nodes[0].transform.emissionDirection, "Top");
	assert.strictEqual(effect.nodes[0].transform.speed.min > 0, true);
	assert.deepStrictEqual(effect.warnings, []);
	assert(fs.readFileSync(outputPath, "utf8").includes("Generated by Dev/Roblox/bin/effekseer-for-roblox.js"));
	assert(fs.readFileSync(outputPath, "utf8").includes("rbxassetid://123"));
});

test("resolves textures from a rocs lock-derived asset map", () => {
	const { dir, projectPath } = writeTempProject(SIMPLE_PROJECT, "effekseer-roblox-rocs-");
	fs.mkdirSync(path.join(dir, "Texture"), { recursive: true });

	const sourcePath = path.join(dir, "Texture", "Particle.png").replace(/\\/g, "/");
	const effect = convertProject(projectPath, {
		rocsAssetMap: {
			bySourcePath: { [sourcePath]: "rbxassetid://456" },
			byRelativePath: {},
			groups: {},
		},
	});

	assert.strictEqual(effect.nodes[0].texture, "rbxassetid://456");
	assert.deepStrictEqual(effect.warnings, []);
});

test("extracts EDIT XML from efkefc after earlier chunks", () => {
	const efkefc = makeEfkefc(SIMPLE_PROJECT, [chunk("INFO", Buffer.from([1, 2, 3, 4]))]);
	const xml = extractEditXmlFromEfkefc(efkefc);

	assert(xml.includes("<EffekseerProject>"));
	assert(xml.includes("<Name>spark</Name>"));
});

test("rejects efkefc data without an EDIT chunk", () => {
	const efkefc = Buffer.concat([Buffer.from("EFKE"), int32(0), chunk("INFO", Buffer.from([1, 2, 3, 4]))]);

	assert.throws(() => extractEditXmlFromEfkefc(efkefc), /does not contain an EDIT chunk/);
});

test("parses XML text entities and CDATA used in Effekseer project files", () => {
	const root = parseXml(`<?xml version="1.0"?><EffekseerProject><Root><Name>A &amp; B</Name><Raw><![CDATA[x < y]]></Raw></Root></EffekseerProject>`);
	const rootNode = root.children.find((child) => child.name === "Root");

	assert.strictEqual(rootNode.children.find((child) => child.name === "Name").text, "A & B");
	assert.strictEqual(rootNode.children.find((child) => child.name === "Raw").text, "x < y");
});

test("keeps supported renderer nodes and reports unsupported model renderer nodes", () => {
	const nodes = [
		["sprite", 2],
		["ribbon", 3],
		["ring", 4],
		["model", 5],
		["track", 6],
	]
		.map(
			([name, type]) => `
<Node>
  <CommonValues><MaxGeneration><Value>1</Value></MaxGeneration></CommonValues>
  <DrawingValues><Type>${type}</Type></DrawingValues>
  <Name>${name}</Name>
  <Children />
</Node>`,
		)
		.join("\n");
	const { projectPath } = writeTempProject(createProject(nodes), "effekseer-roblox-renderers-");
	const effect = convertProject(projectPath);

	assert.deepStrictEqual(
		effect.nodes.map((node) => [node.name, node.rendererType, node.rendered]),
		[
			["sprite", "Sprite", true],
			["ribbon", "Ribbon", true],
			["ring", "Ring", true],
			["model", "Model", false],
			["track", "Track", true],
		],
	);
	assert.strictEqual(countWarnings(effect, "renderer_unsupported"), 1);
});

test("preserves node hierarchy and child effect ids", () => {
	const project = createProject(`
<Node>
  <IsRendered>False</IsRendered>
  <Name>parent</Name>
  <Children>
    <Node>
      <RendererCommonValues><ColorTexture>Texture/Child.png</ColorTexture></RendererCommonValues>
      <Name>child</Name>
      <Children />
    </Node>
  </Children>
</Node>`);
	const { projectPath } = writeTempProject(project, "effekseer-roblox-hierarchy-");
	const effect = convertProject(projectPath, {
		textureMap: { "Texture/Child.png": "rbxassetid://789" },
	});

	assert.strictEqual(effect.nodes[0].name, "parent");
	assert.strictEqual(effect.nodes[0].rendered, false);
	assert.strictEqual(effect.nodes[0].children[0].id, "1_1");
	assert.strictEqual(effect.nodes[0].children[0].texture, "rbxassetid://789");
});

test("converts an Effekseer sample effect as an integration regression", () => {
	const samplePath = path.resolve(
		__dirname,
		"..",
		"..",
		"..",
		"Release",
		"Sample",
		"01_Suzuki01",
		"003_snowstorm_effect",
		"snowstorm11.efkproj",
	);
	const effect = convertProject(samplePath, { moduleName: "SnowstormSample" });

	assert.strictEqual(effect.name, "SnowstormSample");
	assert(effect.nodes.length > 0);
	assert.deepStrictEqual(effect.dependencies.textures, [
		"Texture/Burst01_2.png",
		"Texture/Particle01.png",
		"Texture/Particle02.png",
		"Texture/blue_fire.png",
	]);
	assert.strictEqual(countWarnings(effect, "location_fcurve"), 2);
	assert.strictEqual(countWarnings(effect, "texture_unmapped"), 7);
});

test("CLI writes output modules and warnings JSON", async () => {
	const { dir, projectPath } = writeTempProject(SIMPLE_PROJECT, "effekseer-roblox-cli-");
	const outputPath = path.join(dir, "Out.luau");
	const warningsPath = path.join(dir, "warnings.json");

	await withMutedConsole(() =>
		main(["convert", projectPath, "-o", outputPath, "--module-name", "CliEffect", "--warnings-json", warningsPath]),
	);

	const output = fs.readFileSync(outputPath, "utf8");
	const warnings = JSON.parse(fs.readFileSync(warningsPath, "utf8"));
	assert(output.includes('name = "CliEffect"'));
	assert.strictEqual(warnings.length, 1);
	assert.strictEqual(warnings[0].code, "texture_unmapped");
});

(async () => {
	for (const { name, callback } of tests) {
		await callback();
		console.log(`ok - ${name}`);
	}
	console.log(`All ${tests.length} EffekseerForRoblox conversion tests passed.`);
})().catch((error) => {
	console.error(error);
	process.exit(1);
});
