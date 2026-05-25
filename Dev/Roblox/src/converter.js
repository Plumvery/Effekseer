const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

const RENDERER_TYPES = {
	0: "None",
	2: "Sprite",
	3: "Ribbon",
	4: "Ring",
	5: "Model",
	6: "Track",
};

const SUPPORTED_RENDERERS = new Set(["Sprite", "Ribbon", "Ring", "Track"]);
const LUA_RESERVED = new Set([
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
]);

class BinaryCursor {
	constructor(buffer) {
		this.buffer = buffer;
		this.offset = 0;
	}

	read(size) {
		if (this.offset + size > this.buffer.length) {
			throw new Error("Unexpected end of Effekseer binary data");
		}
		const value = this.buffer.subarray(this.offset, this.offset + size);
		this.offset += size;
		return value;
	}

	int16() {
		const value = this.buffer.readInt16LE(this.offset);
		this.offset += 2;
		return value;
	}

	uint16() {
		const value = this.buffer.readUInt16LE(this.offset);
		this.offset += 2;
		return value;
	}

	uint32() {
		const value = this.buffer.readUInt32LE(this.offset);
		this.offset += 4;
		return value;
	}

	bool32() {
		const value = this.buffer.readInt32LE(this.offset) > 0;
		this.offset += 4;
		return value;
	}

	utf8Len16() {
		const size = this.uint16();
		return this.read(size).toString("utf8");
	}
}

function decodeXmlEntities(value) {
	return value
		.replace(/&lt;/g, "<")
		.replace(/&gt;/g, ">")
		.replace(/&quot;/g, '"')
		.replace(/&apos;/g, "'")
		.replace(/&amp;/g, "&");
}

function parseXml(xml) {
	const root = { name: "__root__", text: "", children: [] };
	const stack = [root];
	const tokenPattern = /<!--[\s\S]*?-->|<\?[\s\S]*?\?>|<!\[CDATA\[[\s\S]*?\]\]>|<[^>]+>|[^<]+/g;
	let match;

	while ((match = tokenPattern.exec(xml)) !== null) {
		const token = match[0];
		if (token.startsWith("<!--") || token.startsWith("<?")) {
			continue;
		}

		if (token.startsWith("<![CDATA[")) {
			stack[stack.length - 1].text += token.slice(9, -3);
			continue;
		}

		if (token.startsWith("</")) {
			const name = token.slice(2, -1).trim();
			const current = stack.pop();
			if (!current || current.name !== name) {
				throw new Error(`Malformed XML: expected </${current ? current.name : "?"}>, got </${name}>`);
			}
			continue;
		}

		if (token.startsWith("<")) {
			if (token.startsWith("<!")) {
				continue;
			}

			const selfClosing = /\/\s*>$/.test(token);
			const inner = token.slice(1, selfClosing ? token.lastIndexOf("/") : -1).trim();
			const name = inner.split(/\s+/)[0];
			const node = { name, text: "", children: [] };
			stack[stack.length - 1].children.push(node);
			if (!selfClosing) {
				stack.push(node);
			}
			continue;
		}

		stack[stack.length - 1].text += decodeXmlEntities(token);
	}

	if (stack.length !== 1) {
		throw new Error(`Malformed XML: unclosed <${stack[stack.length - 1].name}>`);
	}

	if (root.children.length !== 1) {
		throw new Error("XML document must have exactly one root element");
	}

	return root.children[0];
}

function child(node, name) {
	return node.children.find((candidate) => candidate.name === name) || null;
}

function children(node, name) {
	return node.children.filter((candidate) => candidate.name === name);
}

function find(node, xmlPath) {
	let current = node;
	for (const segment of xmlPath.split("/")) {
		if (!current) {
			return null;
		}
		current = child(current, segment);
	}
	return current;
}

function textAt(node, xmlPath) {
	const found = find(node, xmlPath);
	if (!found) {
		return null;
	}
	const value = found.text.trim();
	return value === "" ? null : value;
}

function numberAt(node, xmlPath, defaultValue) {
	const value = textAt(node, xmlPath);
	if (value == null) {
		return defaultValue;
	}
	const parsed = Number(value);
	return Number.isFinite(parsed) ? parsed : defaultValue;
}

function intAt(node, xmlPath, defaultValue) {
	return Math.round(numberAt(node, xmlPath, defaultValue));
}

function boolAt(node, xmlPath, defaultValue) {
	const value = textAt(node, xmlPath);
	if (value == null) {
		return defaultValue;
	}
	return value === "1" || value.toLowerCase() === "true" || value.toLowerCase() === "yes";
}

function randomNumberAt(node, xmlPath, defaultValue) {
	const base = find(node, xmlPath);
	if (!base) {
		return { center: defaultValue, min: defaultValue, max: defaultValue };
	}

	const directText = base.text.trim();
	const direct = directText === "" ? null : Number(directText);
	const min = textAt(base, "Min");
	const max = textAt(base, "Max");
	const center = textAt(base, "Center");
	const parse = (value) => {
		if (value == null) {
			return null;
		}
		const parsed = Number(value);
		return Number.isFinite(parsed) ? parsed : null;
	};

	let minValue = parse(min);
	let maxValue = parse(max);
	let centerValue = parse(center);

	if (centerValue == null && minValue != null && maxValue != null) {
		centerValue = (minValue + maxValue) * 0.5;
	}
	if (centerValue == null) {
		centerValue = Number.isFinite(direct) ? direct : defaultValue;
	}
	if (minValue == null) {
		minValue = centerValue;
	}
	if (maxValue == null) {
		maxValue = centerValue;
	}
	if (minValue > maxValue) {
		[minValue, maxValue] = [maxValue, minValue];
	}

	return { center: centerValue, min: minValue, max: maxValue };
}

function fixedVectorAt(node, xmlPath, defaultValue) {
	return {
		x: numberAt(node, `${xmlPath}/X`, defaultValue.x),
		y: numberAt(node, `${xmlPath}/Y`, defaultValue.y),
		z: numberAt(node, `${xmlPath}/Z`, defaultValue.z),
	};
}

function randomVectorAt(node, xmlPath, defaultValue) {
	const axes = {
		x: randomNumberAt(node, `${xmlPath}/X`, defaultValue.x),
		y: randomNumberAt(node, `${xmlPath}/Y`, defaultValue.y),
		z: randomNumberAt(node, `${xmlPath}/Z`, defaultValue.z),
	};
	return {
		center: Object.fromEntries(Object.entries(axes).map(([axis, range]) => [axis, range.center])),
		min: Object.fromEntries(Object.entries(axes).map(([axis, range]) => [axis, range.min])),
		max: Object.fromEntries(Object.entries(axes).map(([axis, range]) => [axis, range.max])),
	};
}

function vectorMagnitude(vector) {
	return Math.sqrt(vector.x * vector.x + vector.y * vector.y + vector.z * vector.z);
}

function dominantDirection(vector) {
	const candidates = [
		["Right", vector.x],
		["Top", vector.y],
		["Back", vector.z],
	];
	const [axis, value] = candidates.reduce((best, candidate) =>
		Math.abs(candidate[1]) > Math.abs(best[1]) ? candidate : best,
	);
	if (Math.abs(value) < 1e-6) {
		return "Top";
	}
	if (axis === "Right" && value < 0) {
		return "Left";
	}
	if (axis === "Top" && value < 0) {
		return "Bottom";
	}
	if (axis === "Back" && value < 0) {
		return "Front";
	}
	return axis;
}

function spreadFromRange(velocity) {
	const center = velocity.center;
	let maxDelta = 0;
	for (const axis of ["x", "y", "z"]) {
		maxDelta = Math.max(maxDelta, Math.abs(velocity.max[axis] - center[axis]), Math.abs(center[axis] - velocity.min[axis]));
	}
	const speed = Math.max(vectorMagnitude(center), 1e-6);
	return Math.max(0, Math.min(180, (Math.atan2(maxDelta, speed) * 180 * 2) / Math.PI));
}

function colorAt(node, candidates) {
	for (const xmlPath of candidates) {
		const base = find(node, xmlPath);
		if (!base) {
			continue;
		}
		return {
			r: intAt(base, "R", 255),
			g: intAt(base, "G", 255),
			b: intAt(base, "B", 255),
			a: intAt(base, "A", 255),
		};
	}

	return { r: 255, g: 255, b: 255, a: 255 };
}

function extractEditXmlFromEfkefc(buffer) {
	if (buffer.length < 16 || buffer.subarray(0, 4).toString("utf8") !== "EFKE") {
		throw new Error("Not an Effekseer .efkefc file");
	}

	let offset = 8;
	while (offset + 8 <= buffer.length) {
		const chunkName = buffer.subarray(offset, offset + 4).toString("utf8");
		offset += 4;
		const chunkSize = buffer.readUInt32LE(offset);
		offset += 4;
		const chunkData = buffer.subarray(offset, offset + chunkSize);
		offset += chunkSize;

		if (chunkName === "EDIT") {
			return decompressEditXml(chunkData);
		}
	}

	throw new Error("The .efkefc file does not contain an EDIT chunk");
}

function xmlEscape(value) {
	return String(value)
		.replace(/&/g, "&amp;")
		.replace(/</g, "&lt;")
		.replace(/>/g, "&gt;")
		.replace(/"/g, "&quot;");
}

function renderXmlNode(node) {
	if (!node.children.length) {
		return `<${node.name}>${xmlEscape(node.text || "")}</${node.name}>`;
	}
	return `<${node.name}>${node.children.map(renderXmlNode).join("")}</${node.name}>`;
}

function decompressEditXml(data) {
	const payload = zlib.inflateSync(data);
	const reader = new BinaryCursor(payload);

	const keyCount = reader.int16();
	const keys = new Map();
	for (let i = 0; i < keyCount; i++) {
		const name = reader.utf8Len16();
		const index = reader.int16();
		keys.set(index, name);
	}

	const valueCount = reader.int16();
	const values = new Map();
	for (let i = 0; i < valueCount; i++) {
		const value = reader.utf8Len16();
		const index = reader.int16();
		values.set(index, value);
	}

	function readElements() {
		const count = reader.int16();
		const result = [];
		for (let i = 0; i < count; i++) {
			const name = keys.get(reader.int16());
			const node = { name, text: "", children: [] };
			if (reader.bool32()) {
				node.text = values.get(reader.int16()) || "";
			}
			if (reader.bool32()) {
				node.children = readElements();
			}
			result.push(node);
		}
		return result;
	}

	const roots = readElements();
	if (roots.length !== 1) {
		throw new Error("EDIT chunk did not contain exactly one XML root");
	}

	return `<?xml version="1.0" encoding="utf-8"?>${renderXmlNode(roots[0])}`;
}

function loadProjectXml(inputPath) {
	const buffer = fs.readFileSync(inputPath);
	if (path.extname(inputPath).toLowerCase() === ".efkefc") {
		return parseXml(extractEditXmlFromEfkefc(buffer));
	}
	return parseXml(buffer.toString("utf8"));
}

function warning(code, message, node) {
	const value = { code, message };
	if (node) {
		value.node = node;
	}
	return value;
}

function rendererTypeFor(node) {
	const rendererId = intAt(node, "DrawingValues/Type", 2);
	return RENDERER_TYPES[rendererId] || `Unknown${rendererId}`;
}

function generationTime(node) {
	const common = find(node, "CommonValues");
	if (!common) {
		return { center: 1, min: 1, max: 1 };
	}
	const nested = randomNumberAt(common, "Generation/GenerationTime", 1);
	const legacy = randomNumberAt(common, "GenerationTime", nested.center);
	return find(common, "Generation/GenerationTime") || !find(common, "GenerationTime") ? nested : legacy;
}

function generationOffset(node) {
	const common = find(node, "CommonValues");
	if (!common) {
		return { center: 0, min: 0, max: 0 };
	}
	const nested = randomNumberAt(common, "Generation/GenerationTimeOffset", 0);
	const legacy = randomNumberAt(common, "GenerationTimeOffset", nested.center);
	return find(common, "Generation/GenerationTimeOffset") || !find(common, "GenerationTimeOffset") ? nested : legacy;
}

function nodeLife(node) {
	const common = find(node, "CommonValues");
	return common ? randomNumberAt(common, "Life", 100) : { center: 100, min: 100, max: 100 };
}

function maxGeneration(node) {
	const common = find(node, "CommonValues");
	if (!common) {
		return 1;
	}
	if (boolAt(common, "MaxGeneration/Infinite", false)) {
		return 0;
	}
	return Math.max(0, intAt(common, "MaxGeneration/Value", 1));
}

function locationPayload(node, warnings, nodeName) {
	const locationType = intAt(node, "LocationValues/Type", 0);
	let position = { x: 0, y: 0, z: 0 };
	let velocity = randomVectorAt(node, "__missing__", { x: 0, y: 0, z: 0 });
	let acceleration = randomVectorAt(node, "__missing__", { x: 0, y: 0, z: 0 });

	if (locationType === 0) {
		position = fixedVectorAt(node, "LocationValues/Fixed/Location", { x: 0, y: 0, z: 0 });
	} else if (locationType === 1) {
		position = randomVectorAt(node, "LocationValues/PVA/Location", { x: 0, y: 0, z: 0 }).center;
		velocity = randomVectorAt(node, "LocationValues/PVA/Velocity", { x: 0, y: 0, z: 0 });
		acceleration = randomVectorAt(node, "LocationValues/PVA/Acceleration", { x: 0, y: 0, z: 0 });
	} else if (locationType === 2) {
		position = randomVectorAt(node, "LocationValues/Easing/Start", { x: 0, y: 0, z: 0 }).center;
		warnings.push(warning("location_easing", "Location easing is approximated as the start position.", nodeName));
	} else if (locationType === 3) {
		warnings.push(warning("location_fcurve", "Location FCurve is not evaluated by the Roblox runtime yet.", nodeName));
	} else {
		warnings.push(warning("location_unsupported", `Location type ${locationType} is not supported.`, nodeName));
	}

	return {
		type: locationType,
		position,
		velocity,
		acceleration,
		emissionDirection: dominantDirection(velocity.center),
		spreadAngle: spreadFromRange(velocity),
	};
}

function rotationPayload(node) {
	const rotationType = intAt(node, "RotationValues/Type", 0);
	let rotation = { center: 0, min: 0, max: 0 };
	let speed = { center: 0, min: 0, max: 0 };

	if (rotationType === 0) {
		const z = numberAt(node, "RotationValues/Fixed/Rotation/Z", 0);
		rotation = { center: z, min: z, max: z };
	} else if (rotationType === 1) {
		rotation = randomNumberAt(node, "RotationValues/PVA/Rotation/Z", 0);
		speed = randomNumberAt(node, "RotationValues/PVA/Velocity/Z", 0);
	} else if (rotationType === 3) {
		rotation = randomNumberAt(node, "RotationValues/AxisPVA/Rotation", 0);
		speed = randomNumberAt(node, "RotationValues/AxisPVA/Velocity", 0);
	}

	return { type: rotationType, rotation, speed };
}

function scalePayload(node, life) {
	const scaleType = intAt(node, "ScalingValues/Type", 0);
	let start = 1;
	let finish = 1;
	let envelope = 0;

	if (scaleType === 0) {
		const scale = fixedVectorAt(node, "ScalingValues/Fixed/Scale", { x: 1, y: 1, z: 1 });
		start = Math.max(0, (Math.abs(scale.x) + Math.abs(scale.y)) * 0.5);
		finish = start;
	} else if (scaleType === 1) {
		const base = randomVectorAt(node, "ScalingValues/PVA/Scale", { x: 1, y: 1, z: 1 });
		const velocity = randomVectorAt(node, "ScalingValues/PVA/Velocity", { x: 0, y: 0, z: 0 });
		const acceleration = randomVectorAt(node, "ScalingValues/PVA/Acceleration", { x: 0, y: 0, z: 0 });
		const lifeFrames = life.center;
		start = Math.max(0, (Math.abs(base.center.x) + Math.abs(base.center.y)) * 0.5);
		const endX = base.center.x + velocity.center.x * lifeFrames + 0.5 * acceleration.center.x * lifeFrames * lifeFrames;
		const endY = base.center.y + velocity.center.y * lifeFrames + 0.5 * acceleration.center.y * lifeFrames * lifeFrames;
		finish = Math.max(0, (Math.abs(endX) + Math.abs(endY)) * 0.5);
		envelope = Math.max(0, (base.max.x - base.min.x + base.max.y - base.min.y) * 0.25);
	} else if (scaleType === 3) {
		const base = randomNumberAt(node, "ScalingValues/SinglePVA/Scale", 1);
		const velocity = randomNumberAt(node, "ScalingValues/SinglePVA/Velocity", 0);
		const acceleration = randomNumberAt(node, "ScalingValues/SinglePVA/Acceleration", 0);
		const lifeFrames = life.center;
		start = Math.max(0, Math.abs(base.center));
		finish = Math.max(0, Math.abs(base.center + velocity.center * lifeFrames + 0.5 * acceleration.center * lifeFrames * lifeFrames));
		envelope = Math.max(0, (base.max - base.min) * 0.5);
	}

	if (finish === 0) {
		finish = start;
	}
	return { type: scaleType, start, finish, envelope };
}

function texturePathFor(node) {
	return (
		textAt(node, "RendererCommonValues/ColorTexture") ||
		textAt(node, "DrawingValues/Sprite/ColorTexture") ||
		textAt(node, "DrawingValues/Ribbon/ColorTexture") ||
		textAt(node, "DrawingValues/Ring/ColorTexture") ||
		""
	);
}

function normalizePath(value) {
	return value.replace(/\\/g, "/");
}

function createTextureResolver(sourcePath, textureMap, rocsAssetMap) {
	const sourceDir = path.dirname(sourcePath);
	return (texturePath) => {
		if (!texturePath) {
			return null;
		}

		const normalizedTexturePath = normalizePath(texturePath);
		if (textureMap[normalizedTexturePath]) {
			return textureMap[normalizedTexturePath];
		}

		if (!rocsAssetMap) {
			return null;
		}

		const absolutePath = normalizePath(path.resolve(sourceDir, normalizedTexturePath));
		const cwdRelativePath = normalizePath(path.relative(process.cwd(), absolutePath));
		return (
			rocsAssetMap.bySourcePath?.[absolutePath] ||
			rocsAssetMap.byRelativePath?.[cwdRelativePath] ||
			rocsAssetMap.byRelativePath?.[normalizedTexturePath] ||
			null
		);
	};
}

function convertNode(node, context, idPrefix) {
	const nodeName = textAt(node, "Name") || `Node${idPrefix}`;
	const rendererType = rendererTypeFor(node);
	let rendered = boolAt(node, "IsRendered", true) && rendererType !== "None";
	const life = nodeLife(node);
	const texturePath = texturePathFor(node);
	const texture = context.resolveTexture(texturePath);

	if (texturePath) {
		context.dependencies.textures.add(texturePath);
	}

	if (rendered && !SUPPORTED_RENDERERS.has(rendererType)) {
		context.warnings.push(warning("renderer_unsupported", `Renderer ${rendererType} is not supported by the Roblox runtime.`, nodeName));
		rendered = false;
	}

	if (rendered && texturePath && !texture) {
		context.warnings.push(warning("texture_unmapped", `No Roblox asset id mapped for texture '${texturePath}'.`, nodeName));
	}

	const location = locationPayload(node, context.warnings, nodeName);
	let speedMin = vectorMagnitude(location.velocity.min);
	let speedMax = vectorMagnitude(location.velocity.max);
	if (speedMin > speedMax) {
		[speedMin, speedMax] = [speedMax, speedMin];
	}

	const childRoot = find(node, "Children");
	const childNodes = childRoot ? children(childRoot, "Node") : [];

	return {
		id: idPrefix,
		name: nodeName,
		rendererType,
		rendered,
		texturePath,
		texture,
		alphaBlend: intAt(node, "RendererCommonValues/AlphaBlend", 1),
		zTest: boolAt(node, "RendererCommonValues/ZTest", true),
		fadeIn: numberAt(node, "RendererCommonValues/FadeIn/Frame", 0),
		fadeOut: numberAt(node, "RendererCommonValues/FadeOut/Frame", 0),
		color: colorAt(node, [
			"DrawingValues/ColorAll/Fixed",
			"DrawingValues/Sprite/ColorAll_Fixed",
			"DrawingValues/Ribbon/ColorAll_Fixed",
			"DrawingValues/Ring/ColorAll_Fixed",
			"DrawingValues/Track/ColorCenterMiddle_Fixed",
		]),
		life,
		generation: {
			max: maxGeneration(node),
			time: generationTime(node),
			offset: generationOffset(node),
		},
		transform: {
			position: location.position,
			velocity: location.velocity,
			acceleration: location.acceleration,
			speed: { min: speedMin, max: speedMax },
			emissionDirection: location.emissionDirection,
			spreadAngle: location.spreadAngle,
			rotation: rotationPayload(node),
			size: scalePayload(node, life),
		},
		children: childNodes.map((childNode, index) => convertNode(childNode, context, `${idPrefix}_${index + 1}`)),
	};
}

function convertProject(inputPath, options = {}) {
	const projectRoot = loadProjectXml(inputPath);
	if (projectRoot.name !== "EffekseerProject") {
		throw new Error(`Expected EffekseerProject XML root, got ${projectRoot.name}`);
	}

	const context = {
		warnings: [],
		dependencies: {
			textures: new Set(),
		},
		resolveTexture: createTextureResolver(inputPath, options.textureMap || {}, options.rocsAssetMap || null),
	};

	const childRoot = find(projectRoot, "Root/Children");
	const rootNodes = childRoot ? children(childRoot, "Node") : [];
	const nodes = rootNodes.map((node, index) => convertNode(node, context, String(index + 1)));

	return {
		format: "EffekseerRobloxEffect",
		formatVersion: 1,
		name: options.moduleName || path.basename(inputPath, path.extname(inputPath)),
		source: normalizePath(path.relative(process.cwd(), inputPath)),
		frameRate: options.frameRate || 60,
		unitScale: options.unitScale ?? 0.01,
		particleSizeScale: options.particleSizeScale ?? 1,
		dependencies: {
			textures: Array.from(context.dependencies.textures).sort(),
		},
		warnings: context.warnings,
		nodes,
	};
}

function luaKey(key) {
	return /^[A-Za-z_][A-Za-z0-9_]*$/.test(key) && !LUA_RESERVED.has(key) ? key : `[${JSON.stringify(key)}]`;
}

function luaNumber(value) {
	if (Number.isInteger(value)) {
		return String(value);
	}
	return Number(value).toPrecision(9).replace(/\.?0+$/, "");
}

function toLuau(value, depth = 0) {
	const pad = "\t".repeat(depth);
	const childPad = "\t".repeat(depth + 1);

	if (value == null) {
		return "nil";
	}
	if (typeof value === "boolean") {
		return value ? "true" : "false";
	}
	if (typeof value === "number") {
		return luaNumber(value);
	}
	if (typeof value === "string") {
		return JSON.stringify(value);
	}
	if (Array.isArray(value)) {
		if (value.length === 0) {
			return "{}";
		}
		return `{\n${value.map((item) => `${childPad}${toLuau(item, depth + 1)},`).join("\n")}\n${pad}}`;
	}
	if (typeof value === "object") {
		const entries = Object.entries(value).filter(([, item]) => item != null);
		if (entries.length === 0) {
			return "{}";
		}
		return `{\n${entries.map(([key, item]) => `${childPad}${luaKey(key)} = ${toLuau(item, depth + 1)},`).join("\n")}\n${pad}}`;
	}
	throw new Error(`Cannot serialize ${typeof value} to Luau`);
}

function writeLuauModule(effect, outputPath) {
	const contents = [
		"-- Generated by Dev/Roblox/bin/effekseer-for-roblox.js.",
		"-- Regenerate this file from the source Effekseer project instead of editing by hand.",
		`-- Source: ${effect.source}`,
		"",
		`return ${toLuau(effect)}`,
		"",
	].join("\n");
	fs.mkdirSync(path.dirname(outputPath), { recursive: true });
	fs.writeFileSync(outputPath, contents);
}

module.exports = {
	convertProject,
	extractEditXmlFromEfkefc,
	loadProjectXml,
	parseXml,
	toLuau,
	writeLuauModule,
};
