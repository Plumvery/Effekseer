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

const SUPPORTED_RENDERERS = new Set(["Sprite", "Ribbon", "Ring", "Track", "Model"]);
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

function vectorRangeFromVector(vector) {
	return {
		center: { x: vector.x, y: vector.y, z: vector.z },
		min: { x: vector.x, y: vector.y, z: vector.z },
		max: { x: vector.x, y: vector.y, z: vector.z },
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

function subtractVectors(a, b) {
	return {
		x: (a.x || 0) - (b.x || 0),
		y: (a.y || 0) - (b.y || 0),
		z: (a.z || 0) - (b.z || 0),
	};
}

function addVectors(a, b) {
	return {
		x: (a.x || 0) + (b.x || 0),
		y: (a.y || 0) + (b.y || 0),
		z: (a.z || 0) + (b.z || 0),
	};
}

function divideVector(vector, divisor) {
	const safeDivisor = Math.abs(divisor) > 1e-6 ? divisor : 1;
	return {
		x: (vector.x || 0) / safeDivisor,
		y: (vector.y || 0) / safeDivisor,
		z: (vector.z || 0) / safeDivisor,
	};
}

function vectorVelocityFromRanges(start, finish, frames) {
	return {
		center: divideVector(subtractVectors(finish.center, start.center), frames),
		min: divideVector(subtractVectors(finish.min, start.min), frames),
		max: divideVector(subtractVectors(finish.max, start.max), frames),
	};
}

function addVectorRanges(a, b) {
	return {
		center: addVectors(a.center, b.center),
		min: addVectors(a.min, b.min),
		max: addVectors(a.max, b.max),
	};
}

function numberVelocityFromRanges(start, finish, frames) {
	const safeFrames = Math.abs(frames) > 1e-6 ? frames : 1;
	let min = (finish.min - start.min) / safeFrames;
	let max = (finish.max - start.max) / safeFrames;
	if (min > max) {
		[min, max] = [max, min];
	}
	return {
		center: (finish.center - start.center) / safeFrames,
		min,
		max,
	};
}

function averageXY(vector) {
	return (Math.abs(vector.x || 0) + Math.abs(vector.y || 0)) * 0.5;
}

function scaleVector(vector) {
	return {
		x: Math.abs(vector.x || 0),
		y: Math.abs(vector.y || 0),
		z: Math.abs(vector.z || 0),
	};
}

function singleScaleVector(value) {
	const safeValue = Math.abs(value || 0);
	return { x: safeValue, y: safeValue, z: safeValue };
}

function scaleVectorRange(range, factor) {
	const scale = (vector) => ({
		x: (vector.x || 0) * factor,
		y: (vector.y || 0) * factor,
		z: (vector.z || 0) * factor,
	});
	return { center: scale(range.center), min: scale(range.min), max: scale(range.max) };
}

function keyedChildrenSorted(node, prefix) {
	return node.children
		.filter((candidate) => candidate.name.startsWith(prefix))
		.map((candidate) => ({ index: Number(candidate.name.slice(prefix.length)), node: candidate }))
		.filter((entry) => Number.isFinite(entry.index))
		.sort((a, b) => a.index - b.index)
		.map((entry) => entry.node);
}

function parseFCurveKeys(axisNode) {
	if (!axisNode) {
		return [];
	}
	return keyedChildrenSorted(axisNode, "Key")
		.map((keyNode) => ({
			frame: numberAt(keyNode, "Frame", 0),
			value: numberAt(keyNode, "Value", 0),
		}))
		.sort((a, b) => a.frame - b.frame);
}

function evaluateFCurve(keys, frame, defaultValue) {
	if (!keys.length) {
		return defaultValue;
	}
	if (frame <= keys[0].frame) {
		return keys[0].value;
	}
	const last = keys[keys.length - 1];
	if (frame >= last.frame) {
		return last.value;
	}
	for (let index = 1; index < keys.length; index++) {
		if (frame <= keys[index].frame) {
			const previous = keys[index - 1];
			const next = keys[index];
			const span = next.frame - previous.frame;
			const t = span > 1e-9 ? (frame - previous.frame) / span : 0;
			return previous.value + (next.value - previous.value) * t;
		}
	}
	return last.value;
}

const FCURVE_MAX_SAMPLES = 24;

function bakeFCurveVector(container, life, defaults) {
	const keysNode = find(container, "Keys");
	if (!keysNode) {
		return null;
	}

	const axes = {
		x: parseFCurveKeys(child(keysNode, "X")),
		y: parseFCurveKeys(child(keysNode, "Y")),
		z: parseFCurveKeys(child(keysNode, "Z")),
		s: parseFCurveKeys(child(keysNode, "S")),
	};
	if (!axes.x.length && !axes.y.length && !axes.z.length && !axes.s.length) {
		return null;
	}

	const lifeFrames = Math.max(1, life.max || life.center || 1);
	const frameSet = new Set([0, lifeFrames]);
	for (const axisKeys of Object.values(axes)) {
		for (const key of axisKeys) {
			if (key.frame >= 0 && key.frame <= lifeFrames) {
				frameSet.add(key.frame);
			}
		}
	}
	let frames = Array.from(frameSet).sort((a, b) => a - b);
	if (frames.length > FCURVE_MAX_SAMPLES) {
		const sampled = new Set();
		for (let index = 0; index < FCURVE_MAX_SAMPLES; index++) {
			sampled.add(frames[Math.round((index * (frames.length - 1)) / (FCURVE_MAX_SAMPLES - 1))]);
		}
		frames = Array.from(sampled).sort((a, b) => a - b);
	}

	const scalar = axes.s.length > 0;
	const values = frames.map((frame) => {
		if (scalar) {
			const value = evaluateFCurve(axes.s, frame, defaults.x);
			return { x: value, y: value, z: value };
		}
		return {
			x: evaluateFCurve(axes.x, frame, defaults.x),
			y: evaluateFCurve(axes.y, frame, defaults.y),
			z: evaluateFCurve(axes.z, frame, defaults.z),
		};
	});
	return { frames, values };
}

function fcurveContainerAt(node, candidates) {
	for (const candidate of candidates) {
		const found = find(node, candidate);
		if (found && find(found, "Keys")) {
			return found;
		}
	}
	return null;
}

function uvPayload(node, warnings, nodeName) {
	const uvType = intAt(node, "RendererCommonValues/UV", 0);
	if (uvType === 0) {
		return null;
	}
	const base = find(node, "RendererCommonValues");
	if (!base) {
		return null;
	}

	if (uvType === 1) {
		return {
			type: 1,
			start: { x: numberAt(base, "UVFixed/Start/X", 0), y: numberAt(base, "UVFixed/Start/Y", 0) },
			size: { x: numberAt(base, "UVFixed/Size/X", 0), y: numberAt(base, "UVFixed/Size/Y", 0) },
		};
	}

	if (uvType === 2) {
		const animation = find(base, "UVAnimation/AnimationParams") || find(base, "UVAnimation");
		if (!animation) {
			return null;
		}
		// FrameLength is an IntWithInfinite in newer saves (nested Value element) and plain text in older ones.
		const directFrameLength = textAt(animation, "FrameLength");
		const frameLength = directFrameLength != null && Number.isFinite(Number(directFrameLength))
			? Number(directFrameLength)
			: numberAt(animation, "FrameLength/Value", 1);
		return {
			type: 2,
			start: { x: numberAt(animation, "Start/X", 0), y: numberAt(animation, "Start/Y", 0) },
			size: { x: numberAt(animation, "Size/X", 0), y: numberAt(animation, "Size/Y", 0) },
			animation: {
				frameLength: Math.max(1, frameLength),
				countX: Math.max(1, intAt(animation, "FrameCountX", 1)),
				countY: Math.max(1, intAt(animation, "FrameCountY", 1)),
				loopType: intAt(animation, "LoopType", 0),
				startSheet: intAt(animation, "StartSheet", 0),
			},
		};
	}

	if (uvType === 3) {
		return {
			type: 3,
			start: {
				x: randomNumberAt(base, "UVScroll/Start/X", 0).center,
				y: randomNumberAt(base, "UVScroll/Start/Y", 0).center,
			},
			size: {
				x: randomNumberAt(base, "UVScroll/Size/X", 0).center,
				y: randomNumberAt(base, "UVScroll/Size/Y", 0).center,
			},
			scroll: {
				speed: {
					x: randomNumberAt(base, "UVScroll/Speed/X", 0).center,
					y: randomNumberAt(base, "UVScroll/Speed/Y", 0).center,
				},
			},
		};
	}

	warnings.push(warning("uv_unsupported", `UV type ${uvType} (FCurve) is not supported; default UVs are used.`, nodeName));
	return null;
}

function rangeIsZero(range) {
	for (const key of ["center", "min", "max"]) {
		const vector = range[key] || {};
		if (Math.abs(vector.x || 0) > 1e-9 || Math.abs(vector.y || 0) > 1e-9 || Math.abs(vector.z || 0) > 1e-9) {
			return false;
		}
	}
	return true;
}

function spawnPayload(node, warnings, nodeName) {
	const base = find(node, "GenerationLocationValues");
	if (!base) {
		return null;
	}
	const spawnType = intAt(base, "Type", 0);
	const effectsRotation = boolAt(base, "EffectsRotation", false);

	if (spawnType === 0) {
		// Point offsets are merged into transform.positionRange by convertNode, so no payload is needed.
		const location = randomVectorAt(base, "Point/Location", { x: 0, y: 0, z: 0 });
		if (rangeIsZero(location)) {
			return null;
		}
		return { type: 0, effectsRotation, point: { location } };
	}

	if (spawnType === 1) {
		return {
			type: 1,
			effectsRotation,
			sphere: {
				radius: randomNumberAt(base, "Sphere/Radius", 0),
				rotationX: randomNumberAt(base, "Sphere/RotationX", 0),
				rotationY: randomNumberAt(base, "Sphere/RotationY", 0),
			},
		};
	}

	if (spawnType === 3) {
		return {
			type: 3,
			effectsRotation,
			circle: {
				radius: randomNumberAt(base, "Circle/Radius", 0),
				axis: intAt(base, "Circle/AxisDirection", 2),
				division: Math.max(1, intAt(base, "Circle/Division", 8)),
				angleStart: randomNumberAt(base, "Circle/AngleStart", 0),
				angleEnd: randomNumberAt(base, "Circle/AngleEnd", 360),
				angleNoise: randomNumberAt(base, "Circle/AngleNoize", 0),
				order: intAt(base, "Circle/Type", 0),
			},
		};
	}

	if (spawnType === 4) {
		return {
			type: 4,
			effectsRotation,
			line: {
				from: randomVectorAt(base, "Line/PositionStart", { x: 0, y: 0, z: 0 }),
				to: randomVectorAt(base, "Line/PositionEnd", { x: 0, y: 0, z: 0 }),
				division: Math.max(1, intAt(base, "Line/Division", 8)),
				noise: randomNumberAt(base, "Line/PositionNoize", 0),
				order: intAt(base, "Line/Type", 0),
			},
		};
	}

	warnings.push(warning("spawn_unsupported", `Generation location type ${spawnType} is not supported; point emission is used.`, nodeName));
	return null;
}

function soundPayload(node, context, nodeName) {
	const base = find(node, "SoundValues");
	if (!base || intAt(base, "Type", 0) !== 1) {
		return null;
	}
	const wave = textAt(base, "Sound/Wave");
	if (!wave) {
		return null;
	}

	context.dependencies.sounds.add(wave);
	const asset = context.resolveAsset(wave);
	if (!asset) {
		context.warnings.push(warning("sound_unmapped", `No Roblox asset id mapped for sound '${wave}'.`, nodeName));
	}
	return {
		wave,
		asset,
		volume: randomNumberAt(base, "Sound/Volume", 1),
		pitch: randomNumberAt(base, "Sound/Pitch", 0),
		delay: randomNumberAt(base, "Sound/Delay", 0),
	};
}

const LOCAL_FORCE_FIELD_NAMES = {
	1: "Turbulence",
	2: "Force",
	3: "Wind",
	4: "Vortex",
	7: "Drag",
	9: "AttractiveForce",
};

function fieldAcceleration(node, warnings, nodeName) {
	let acceleration = randomVectorAt(node, "__missing__", { x: 0, y: 0, z: 0 });
	const abs = find(node, "LocationAbsValues");
	if (!abs) {
		return acceleration;
	}

	// Legacy (pre-1.6) layout: Type selects None(0)/Gravity(1)/AttractiveForce(2).
	const legacyType = intAt(abs, "Type", find(abs, "Gravity") ? 1 : 0);
	if (legacyType === 1 && find(abs, "Gravity")) {
		acceleration = addVectorRanges(acceleration, randomVectorAt(abs, "Gravity/Gravity", { x: 0, y: 0, z: 0 }));
	} else if (legacyType === 2) {
		warnings.push(warning("force_field_unsupported", "Attractive force is not supported by the Roblox runtime.", nodeName));
	}

	// Modern (1.6+) layout: up to four LocalForceField slots.
	for (let index = 1; index <= 4; index++) {
		const field = find(abs, `LocalForceField${index}`);
		if (!field) {
			continue;
		}
		const fieldType = intAt(field, "Type", 0);
		if (fieldType === 0) {
			continue;
		}
		if (fieldType === 8) {
			const power = numberAt(field, "Power", 1);
			acceleration = addVectorRanges(
				acceleration,
				scaleVectorRange(randomVectorAt(field, "Gravity/Gravity", { x: 0, y: 0, z: 0 }), power),
			);
			continue;
		}
		warnings.push(
			warning(
				"force_field_unsupported",
				`Local force field '${LOCAL_FORCE_FIELD_NAMES[fieldType] || fieldType}' is not supported by the Roblox runtime.`,
				nodeName,
			),
		);
	}
	return acceleration;
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

function colorRangeAt(node, xmlPath, defaultColor) {
	const base = find(node, xmlPath);
	if (!base) {
		return defaultColor;
	}
	return {
		r: Math.round(randomNumberAt(base, "R", defaultColor.r).center),
		g: Math.round(randomNumberAt(base, "G", defaultColor.g).center),
		b: Math.round(randomNumberAt(base, "B", defaultColor.b).center),
		a: Math.round(randomNumberAt(base, "A", defaultColor.a).center),
	};
}

function rendererValueAt(node, propertyName, defaultValue) {
	const rendererNames = ["Sprite", "Ribbon", "Ring", "Track", "Model"];
	for (const rendererName of rendererNames) {
		const value = textAt(node, `DrawingValues/${rendererName}/${propertyName}`);
		if (value != null) {
			const parsed = Number(value);
			return Number.isFinite(parsed) ? parsed : defaultValue;
		}
	}
	return defaultValue;
}

function alphaBlendAt(node) {
	const common = textAt(node, "RendererCommonValues/AlphaBlend");
	if (common != null) {
		const parsed = Number(common);
		return Number.isFinite(parsed) ? Math.round(parsed) : 1;
	}
	return Math.round(rendererValueAt(node, "AlphaBlend", 1));
}

function fadeFrameAt(node, name) {
	const typeValue = intAt(node, `RendererCommonValues/${name}Type`, 1);
	if (typeValue === 0 || find(node, `RendererCommonValues/${name}None`)) {
		return 0;
	}
	return numberAt(node, `RendererCommonValues/${name}/Frame`, 0);
}

function colorPayload(node, warnings, nodeName) {
	// Effekseer 1.5+ saves Sprite/Model colors as a StandardColor at DrawingValues/ColorAll.
	const standard = find(node, "DrawingValues/ColorAll");
	if (standard && standard.children.length) {
		const mode = intAt(standard, "Type", 0);
		const fixed = colorAt(node, ["DrawingValues/ColorAll/Fixed"]);
		if (mode === 2 && find(standard, "Easing")) {
			const start = colorRangeAt(standard, "Easing/Start", fixed);
			const end = colorRangeAt(standard, "Easing/End", start);
			return {
				color: start,
				colorOverLife: { start, finish: end },
			};
		}
		if (mode === 1 && find(standard, "Random")) {
			return {
				color: colorRangeAt(standard, "Random", fixed),
				colorOverLife: null,
			};
		}
		if (mode === 3 || mode === 4) {
			warnings.push(
				warning(
					"color_unsupported",
					`Color mode ${mode === 3 ? "FCurve" : "Gradient"} is approximated with a fixed color.`,
					nodeName,
				),
			);
		}
		return { color: fixed, colorOverLife: null };
	}

	const rendererNames = ["Sprite", "Ribbon", "Ring", "Track", "Model"];
	for (const rendererName of rendererNames) {
		const basePath = `DrawingValues/${rendererName}`;
		if (!find(node, basePath)) {
			continue;
		}

		const mode = intAt(node, `${basePath}/ColorAll`, 0);
		const fixed = colorAt(node, [`${basePath}/ColorAll_Fixed`]);
		if (mode === 2 && find(node, `${basePath}/ColorAll_Easing`)) {
			const start = colorRangeAt(node, `${basePath}/ColorAll_Easing/Start`, fixed);
			const end = colorRangeAt(node, `${basePath}/ColorAll_Easing/End`, start);
			return {
				color: start,
				colorOverLife: { start, finish: end },
			};
		}
		if (mode === 1 && find(node, `${basePath}/ColorAll_Random`)) {
			return {
				color: colorRangeAt(node, `${basePath}/ColorAll_Random`, fixed),
				colorOverLife: null,
			};
		}
		if (find(node, `${basePath}/ColorAll_Fixed`)) {
			return {
				color: fixed,
				colorOverLife: null,
			};
		}
	}

	return {
		color: colorAt(node, [
			"DrawingValues/ColorAll/Fixed",
			"DrawingValues/Sprite/ColorAll_Fixed",
			"DrawingValues/Ribbon/ColorAll_Fixed",
			"DrawingValues/Ring/ColorAll_Fixed",
			"DrawingValues/Track/ColorCenterMiddle_Fixed",
			"DrawingValues/Model/Color_Fixed",
		]),
		colorOverLife: null,
	};
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
	const life = common ? randomNumberAt(common, "Life", 100) : { center: 100, min: 100, max: 100 };
	if (common) {
		// Modern saves nest removal flags under Removal; legacy saves keep flat RemoveWhen* elements.
		const removalNested = boolAt(common, "Removal/WhenLifeIsExtinct", true);
		const removalLegacy = boolAt(common, "RemoveWhenLifeIsExtinct", true);
		if (!removalNested || !removalLegacy) {
			life.infinite = true;
		}
	}
	return life;
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

function locationPayload(node, warnings, nodeName, life) {
	const locationType = intAt(node, "LocationValues/Type", 0);
	let position = { x: 0, y: 0, z: 0 };
	let positionRange = vectorRangeFromVector(position);
	let velocity = randomVectorAt(node, "__missing__", { x: 0, y: 0, z: 0 });
	let acceleration = randomVectorAt(node, "__missing__", { x: 0, y: 0, z: 0 });
	let positionKeys = null;

	if (locationType === 0) {
		position = fixedVectorAt(node, "LocationValues/Fixed/Location", { x: 0, y: 0, z: 0 });
		positionRange = vectorRangeFromVector(position);
	} else if (locationType === 1) {
		positionRange = randomVectorAt(node, "LocationValues/PVA/Location", { x: 0, y: 0, z: 0 });
		position = positionRange.center;
		velocity = randomVectorAt(node, "LocationValues/PVA/Velocity", { x: 0, y: 0, z: 0 });
		acceleration = randomVectorAt(node, "LocationValues/PVA/Acceleration", { x: 0, y: 0, z: 0 });
	} else if (locationType === 2) {
		const start = randomVectorAt(node, "LocationValues/Easing/Start", { x: 0, y: 0, z: 0 });
		const finish = randomVectorAt(node, "LocationValues/Easing/End", start.center);
		position = start.center;
		positionRange = start;
		velocity = vectorVelocityFromRanges(start, finish, Math.max(1, life.center || 1));
	} else if (locationType === 3) {
		const container = fcurveContainerAt(node, [
			"LocationValues/LocationFCurve/FCurve",
			"LocationValues/FCurve/FCurve",
			"LocationValues/LocationFCurve",
			"LocationValues/FCurve",
		]);
		const baked = container ? bakeFCurveVector(container, life, { x: 0, y: 0, z: 0 }) : null;
		if (baked) {
			positionKeys = baked;
			position = baked.values[0];
			positionRange = vectorRangeFromVector(position);
			const last = baked.values[baked.values.length - 1];
			const frames = Math.max(1, baked.frames[baked.frames.length - 1] - baked.frames[0]);
			velocity = vectorRangeFromVector(divideVector(subtractVectors(last, position), frames));
			warnings.push(
				warning("location_fcurve", "Location FCurve is approximated with baked linear samples.", nodeName),
			);
		} else {
			warnings.push(
				warning("location_fcurve", "Location FCurve keys could not be read; the node stays at its origin.", nodeName),
			);
		}
	} else {
		warnings.push(warning("location_unsupported", `Location type ${locationType} is not supported.`, nodeName));
	}

	acceleration = addVectorRanges(acceleration, fieldAcceleration(node, warnings, nodeName));

	return {
		type: locationType,
		position,
		positionRange,
		positionKeys,
		velocity,
		acceleration,
		emissionDirection: dominantDirection(velocity.center),
		spreadAngle: spreadFromRange(velocity),
	};
}

function rotationPayload(node, life, warnings, nodeName) {
	const rotationType = intAt(node, "RotationValues/Type", 0);
	let rotation = { center: 0, min: 0, max: 0 };
	let speed = { center: 0, min: 0, max: 0 };
	let rotation3 = randomVectorAt(node, "__missing__", { x: 0, y: 0, z: 0 });
	let speed3 = randomVectorAt(node, "__missing__", { x: 0, y: 0, z: 0 });
	let rotationKeys = null;

	if (rotationType === 0) {
		const fixed = fixedVectorAt(node, "RotationValues/Fixed/Rotation", { x: 0, y: 0, z: 0 });
		rotation3 = vectorRangeFromVector(fixed);
		rotation = rotation3.center.z == null
			? { center: 0, min: 0, max: 0 }
			: { center: fixed.z, min: fixed.z, max: fixed.z };
	} else if (rotationType === 1) {
		rotation3 = randomVectorAt(node, "RotationValues/PVA/Rotation", { x: 0, y: 0, z: 0 });
		speed3 = randomVectorAt(node, "RotationValues/PVA/Velocity", { x: 0, y: 0, z: 0 });
		rotation = randomNumberAt(node, "RotationValues/PVA/Rotation/Z", 0);
		speed = randomNumberAt(node, "RotationValues/PVA/Velocity/Z", 0);
	} else if (rotationType === 2) {
		const start3 = randomVectorAt(node, "RotationValues/Easing/Start", { x: 0, y: 0, z: 0 });
		const finish3 = randomVectorAt(node, "RotationValues/Easing/End", start3.center);
		const frames = Math.max(1, life.center || 1);
		rotation3 = start3;
		speed3 = vectorVelocityFromRanges(start3, finish3, frames);
		rotation = start3.center.z == null
			? { center: 0, min: 0, max: 0 }
			: { center: start3.center.z, min: start3.min.z, max: start3.max.z };
		speed = numberVelocityFromRanges(
			{ center: start3.center.z, min: start3.min.z, max: start3.max.z },
			{ center: finish3.center.z, min: finish3.min.z, max: finish3.max.z },
			frames,
		);
	} else if (rotationType === 3) {
		rotation = randomNumberAt(node, "RotationValues/AxisPVA/Rotation", 0);
		speed = randomNumberAt(node, "RotationValues/AxisPVA/Velocity", 0);
	} else if (rotationType === 4) {
		rotation = randomNumberAt(node, "RotationValues/AxisEasing/Easing/Start", 0);
		const finish = randomNumberAt(node, "RotationValues/AxisEasing/Easing/End", rotation.center);
		speed = numberVelocityFromRanges(rotation, finish, Math.max(1, life.center || 1));
	} else if (rotationType === 5) {
		const container = fcurveContainerAt(node, [
			"RotationValues/RotationFCurve/FCurve",
			"RotationValues/FCurve/FCurve",
			"RotationValues/RotationFCurve",
		]);
		const baked = container ? bakeFCurveVector(container, life, { x: 0, y: 0, z: 0 }) : null;
		if (baked) {
			rotationKeys = baked;
			const first = baked.values[0];
			const last = baked.values[baked.values.length - 1];
			const frames = Math.max(1, baked.frames[baked.frames.length - 1] - baked.frames[0]);
			const averageSpeed = divideVector(subtractVectors(last, first), frames);
			rotation3 = vectorRangeFromVector(first);
			speed3 = vectorRangeFromVector(averageSpeed);
			rotation = { center: first.z, min: first.z, max: first.z };
			speed = { center: averageSpeed.z, min: averageSpeed.z, max: averageSpeed.z };
			warnings.push(
				warning("rotation_fcurve", "Rotation FCurve is approximated with baked linear samples.", nodeName),
			);
		} else {
			warnings.push(
				warning("rotation_fcurve", "Rotation FCurve keys could not be read; fixed rotation is used.", nodeName),
			);
		}
	} else if (rotationType === 6 || rotationType === 7) {
		warnings.push(
			warning(
				"rotation_unsupported",
				`Rotation type ${rotationType === 6 ? "RotateToViewpoint" : "RotateToVelocity"} is not supported.`,
				nodeName,
			),
		);
	}

	return { type: rotationType, rotation, speed, rotation3, speed3, rotationKeys };
}

function scalePayload(node, life, warnings, nodeName) {
	const scaleType = intAt(node, "ScalingValues/Type", 0);
	let start = 1;
	let finish = 1;
	let envelope = 0;
	let startVector = { x: 1, y: 1, z: 1 };
	let finishVector = { x: 1, y: 1, z: 1 };
	let pva = null;
	let easing = null;
	let singlePva = null;
	let singleEasing = null;
	let scaleKeys = null;

	if (scaleType === 0) {
		const scale = fixedVectorAt(node, "ScalingValues/Fixed/Scale", { x: 1, y: 1, z: 1 });
		start = Math.max(0, averageXY(scale));
		finish = start;
		startVector = scaleVector(scale);
		finishVector = startVector;
	} else if (scaleType === 1) {
		const base = randomVectorAt(node, "ScalingValues/PVA/Scale", { x: 1, y: 1, z: 1 });
		const velocity = randomVectorAt(node, "ScalingValues/PVA/Velocity", { x: 0, y: 0, z: 0 });
		const acceleration = randomVectorAt(node, "ScalingValues/PVA/Acceleration", { x: 0, y: 0, z: 0 });
		const lifeFrames = life.center;
		start = Math.max(0, averageXY(base.center));
		const endX = base.center.x + velocity.center.x * lifeFrames + 0.5 * acceleration.center.x * lifeFrames * lifeFrames;
		const endY = base.center.y + velocity.center.y * lifeFrames + 0.5 * acceleration.center.y * lifeFrames * lifeFrames;
		const endZ = base.center.z + velocity.center.z * lifeFrames + 0.5 * acceleration.center.z * lifeFrames * lifeFrames;
		finish = Math.max(0, (Math.abs(endX) + Math.abs(endY)) * 0.5);
		envelope = Math.max(0, (base.max.x - base.min.x + base.max.y - base.min.y) * 0.25);
		startVector = scaleVector(base.center);
		finishVector = scaleVector({ x: endX, y: endY, z: endZ });
		pva = { scale: base, velocity, acceleration };
	} else if (scaleType === 2) {
		const startRange = randomVectorAt(node, "ScalingValues/Easing/Start", { x: 1, y: 1, z: 1 });
		const finishRange = randomVectorAt(node, "ScalingValues/Easing/End", startRange.center);
		start = Math.max(0, averageXY(startRange.center));
		finish = Math.max(0, averageXY(finishRange.center));
		envelope = Math.max(
			0,
			(startRange.max.x - startRange.min.x + startRange.max.y - startRange.min.y
				+ finishRange.max.x - finishRange.min.x + finishRange.max.y - finishRange.min.y)
				* 0.125,
		);
		startVector = scaleVector(startRange.center);
		finishVector = scaleVector(finishRange.center);
		easing = { start: startRange, finish: finishRange };
	} else if (scaleType === 3) {
		const base = randomNumberAt(node, "ScalingValues/SinglePVA/Scale", 1);
		const velocity = randomNumberAt(node, "ScalingValues/SinglePVA/Velocity", 0);
		const acceleration = randomNumberAt(node, "ScalingValues/SinglePVA/Acceleration", 0);
		const lifeFrames = life.center;
		start = Math.max(0, Math.abs(base.center));
		finish = Math.max(0, Math.abs(base.center + velocity.center * lifeFrames + 0.5 * acceleration.center * lifeFrames * lifeFrames));
		envelope = Math.max(0, (base.max - base.min) * 0.5);
		startVector = singleScaleVector(base.center);
		finishVector = singleScaleVector(base.center + velocity.center * lifeFrames + 0.5 * acceleration.center * lifeFrames * lifeFrames);
		singlePva = { scale: base, velocity, acceleration };
	} else if (scaleType === 4) {
		const startRange = randomNumberAt(node, "ScalingValues/SingleEasing/Start", 1);
		const finishRange = randomNumberAt(node, "ScalingValues/SingleEasing/End", startRange.center);
		start = Math.max(0, Math.abs(startRange.center));
		finish = Math.max(0, Math.abs(finishRange.center));
		envelope = Math.max(0, Math.max(startRange.max - startRange.min, finishRange.max - finishRange.min) * 0.5);
		startVector = singleScaleVector(startRange.center);
		finishVector = singleScaleVector(finishRange.center);
		singleEasing = { start: startRange, finish: finishRange };
	} else if (scaleType === 5 || scaleType === 6) {
		const container = scaleType === 5
			? fcurveContainerAt(node, ["ScalingValues/FCurve/FCurve", "ScalingValues/FCurve"])
			: fcurveContainerAt(node, ["ScalingValues/SingleFCurve/FCurve", "ScalingValues/SingleFCurve"]);
		const baked = container ? bakeFCurveVector(container, life, { x: 1, y: 1, z: 1 }) : null;
		if (baked) {
			scaleKeys = baked;
			const first = baked.values[0];
			const last = baked.values[baked.values.length - 1];
			start = Math.max(0, averageXY(first));
			finish = Math.max(0, averageXY(last));
			startVector = scaleVector(first);
			finishVector = scaleVector(last);
			warnings.push(
				warning("scaling_fcurve", "Scaling FCurve is approximated with baked linear samples.", nodeName),
			);
		} else {
			warnings.push(
				warning("scaling_fcurve", "Scaling FCurve keys could not be read; scale 1 is used.", nodeName),
			);
		}
	}

	if (!Number.isFinite(finish)) {
		finish = Number.isFinite(start) ? start : 1;
	}
	return {
		type: scaleType,
		start,
		finish,
		envelope,
		startVector,
		finishVector,
		pva,
		easing,
		singlePva,
		singleEasing,
		scaleKeys,
	};
}

function texturePathFor(node) {
	return (
		textAt(node, "RendererCommonValues/ColorTexture") ||
		textAt(node, "DrawingValues/Sprite/ColorTexture") ||
		textAt(node, "DrawingValues/Ribbon/ColorTexture") ||
		textAt(node, "DrawingValues/Ring/ColorTexture") ||
		textAt(node, "DrawingValues/Track/ColorTexture") ||
		""
	);
}

function modelPathFor(node) {
	return textAt(node, "DrawingValues/Model/Model") || "";
}

function spritePositionPayload(node) {
	if (intAt(node, "DrawingValues/Sprite/Position", 0) !== 1) {
		return null;
	}

	const points = [
		fixedVectorAt(node, "DrawingValues/Sprite/Position_Fixed_LL", { x: -0.5, y: -0.5, z: 0 }),
		fixedVectorAt(node, "DrawingValues/Sprite/Position_Fixed_LR", { x: 0.5, y: -0.5, z: 0 }),
		fixedVectorAt(node, "DrawingValues/Sprite/Position_Fixed_UL", { x: -0.5, y: 0.5, z: 0 }),
		fixedVectorAt(node, "DrawingValues/Sprite/Position_Fixed_UR", { x: 0.5, y: 0.5, z: 0 }),
	];
	const xs = points.map((point) => point.x || 0);
	const ys = points.map((point) => point.y || 0);
	const minX = Math.min(...xs);
	const maxX = Math.max(...xs);
	const minY = Math.min(...ys);
	const maxY = Math.max(...ys);

	return {
		center: {
			x: (minX + maxX) * 0.5,
			y: (minY + maxY) * 0.5,
		},
		size: {
			x: Math.max(0.01, maxX - minX),
			y: Math.max(0.01, maxY - minY),
		},
	};
}

function ringRadiusPayload(ringNode, name, defaultValue, life) {
	if (!ringNode) {
		return { start: defaultValue, finish: defaultValue };
	}
	const radiusType = intAt(ringNode, name, 0);
	if (radiusType === 1) {
		const location = randomNumberAt(ringNode, `${name}_PVA/Location/X`, defaultValue);
		const velocity = randomNumberAt(ringNode, `${name}_PVA/Velocity/X`, 0);
		const acceleration = randomNumberAt(ringNode, `${name}_PVA/Acceleration/X`, 0);
		const frames = Math.max(1, life.center || 1);
		return {
			start: location.center,
			finish: location.center + velocity.center * frames + 0.5 * acceleration.center * frames * frames,
		};
	}
	if (radiusType === 2) {
		const start = randomNumberAt(ringNode, `${name}_Easing/Start/X`, defaultValue);
		const finish = randomNumberAt(ringNode, `${name}_Easing/End/X`, start.center);
		return { start: start.center, finish: finish.center };
	}
	const fixed = numberAt(ringNode, `${name}_Fixed/Location/X`, defaultValue);
	return { start: fixed, finish: fixed };
}

function visualPayload(node, rendererType, modelPath, modelAsset, life) {
	const size = {};

	if (rendererType === "Sprite") {
		size.sprite = {
			billboard: intAt(node, "DrawingValues/Sprite/Billboard", 0),
			position: spritePositionPayload(node),
		};
	} else if (rendererType === "Ribbon") {
		const left = numberAt(node, "DrawingValues/Ribbon/Position_Fixed_L", -0.5);
		const right = numberAt(node, "DrawingValues/Ribbon/Position_Fixed_R", 0.5);
		size.beam = {
			width: Math.max(0.01, Math.abs(right - left)),
			length: Math.max(0.25, Math.abs(right - left) * 6),
		};
	} else if (rendererType === "Track") {
		const front = numberAt(node, "DrawingValues/Track/TrackSizeFor_Fixed", 0);
		const middle = numberAt(node, "DrawingValues/Track/TrackSizeMiddle_Fixed", 1);
		const back = numberAt(node, "DrawingValues/Track/TrackSizeBack_Fixed", front);
		const width = Math.max(0.01, middle || front || back || 1);
		size.beam = {
			width,
			length: Math.max(0.25, Math.abs(front - back) || width * 8),
		};
	} else if (rendererType === "Ring") {
		const ring = find(node, "DrawingValues/Ring");
		const outer = ringRadiusPayload(ring, "Outer", 1, life);
		const inner = ringRadiusPayload(ring, "Inner", 0, life);
		size.ring = {
			vertexCount: intAt(node, "DrawingValues/Ring/VertexCount", 32),
			outerRadius: Math.max(0.01, Math.abs(outer.start || 1)),
			innerRadius: Math.max(0, Math.abs(inner.start || 0)),
			outerRadiusFinish: Math.max(0.01, Math.abs(outer.finish || outer.start || 1)),
			innerRadiusFinish: Math.max(0, Math.abs(inner.finish || 0)),
			billboard: intAt(node, "DrawingValues/Ring/Billboard", 0),
		};
	} else if (rendererType === "Model") {
		size.model = {
			path: modelPath,
			asset: modelAsset,
		};
	}

	return size;
}

function normalizePath(value) {
	return value.replace(/\\/g, "/");
}

function createTextureResolver(sourcePath, textureMap, rocasAssetMap) {
	const sourceDir = path.dirname(sourcePath);
	return (texturePath) => {
		if (!texturePath) {
			return null;
		}

		const normalizedTexturePath = normalizePath(texturePath);
		if (textureMap[normalizedTexturePath]) {
			return textureMap[normalizedTexturePath];
		}

		if (!rocasAssetMap) {
			return null;
		}

		const absolutePath = normalizePath(path.resolve(sourceDir, normalizedTexturePath));
		const cwdRelativePath = normalizePath(path.relative(process.cwd(), absolutePath));
		return (
			rocasAssetMap.bySourcePath?.[absolutePath] ||
			rocasAssetMap.byRelativePath?.[cwdRelativePath] ||
			rocasAssetMap.byRelativePath?.[normalizedTexturePath] ||
			null
		);
	};
}

function convertNode(node, context, idPrefix) {
	const nodeName = textAt(node, "Name") || `Node${idPrefix}`;
	const rendererType = rendererTypeFor(node);
	let rendered = boolAt(node, "IsRendered", true) && rendererType !== "None";
	const life = nodeLife(node);
	const color = colorPayload(node, context.warnings, nodeName);
	const texturePath = texturePathFor(node);
	const texture = context.resolveTexture(texturePath);
	const modelPath = rendererType === "Model" ? modelPathFor(node) : "";
	const modelAsset = modelPath ? context.resolveAsset(modelPath) : null;

	if (texturePath) {
		context.dependencies.textures.add(texturePath);
	}
	if (modelPath) {
		context.dependencies.models.add(modelPath);
	}

	if (rendered && !SUPPORTED_RENDERERS.has(rendererType)) {
		context.warnings.push(warning("renderer_unsupported", `Renderer ${rendererType} is not supported by the Roblox runtime.`, nodeName));
		rendered = false;
	}

	if (rendered && texturePath && !texture) {
		context.warnings.push(warning("texture_unmapped", `No Roblox asset id mapped for texture '${texturePath}'.`, nodeName));
	}
	if (rendered && rendererType === "Model" && modelPath && !modelAsset) {
		context.warnings.push(warning("model_unmapped", `No Roblox asset id mapped for model '${modelPath}'. A placeholder part will be used.`, nodeName));
	}

	const uv = rendered ? uvPayload(node, context.warnings, nodeName) : null;
	let spawn = spawnPayload(node, context.warnings, nodeName);
	const sound = soundPayload(node, context, nodeName);
	const alphaBlend = alphaBlendAt(node);

	if (rendered) {
		const materialType = intAt(node, "RendererCommonValues/Material", 0);
		if (materialType === 6 || boolAt(node, "RendererCommonValues/Distortion", false)) {
			context.warnings.push(
				warning("distortion_unsupported", "Background distortion is rendered as a plain texture.", nodeName),
			);
		} else if (materialType === 128) {
			context.warnings.push(
				warning("material_unsupported", "Custom material files are not supported; textures may be missing.", nodeName),
			);
		} else if (materialType === 7) {
			context.warnings.push(
				warning("material_unsupported", "Lighting material is approximated with unlit rendering.", nodeName),
			);
		}
		if (alphaBlend === 3 || alphaBlend === 4) {
			context.warnings.push(
				warning(
					"blend_unsupported",
					`${alphaBlend === 3 ? "Subtract" : "Multiply"} blending is approximated with normal blending.`,
					nodeName,
				),
			);
		}
	}

	const location = locationPayload(node, context.warnings, nodeName, life);
	if (spawn && spawn.type === 0 && spawn.point) {
		location.position = addVectors(location.position, spawn.point.location.center);
		location.positionRange = addVectorRanges(location.positionRange, spawn.point.location);
		spawn = null;
	}
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
		alphaBlend,
		zTest: boolAt(node, "RendererCommonValues/ZTest", true),
		fadeIn: fadeFrameAt(node, "FadeIn"),
		fadeOut: fadeFrameAt(node, "FadeOut"),
		color: color.color,
		colorOverLife: color.colorOverLife,
		uv,
		spawn,
		sound,
		visual: visualPayload(node, rendererType, modelPath, modelAsset, life),
		life,
		generation: {
			max: maxGeneration(node),
			time: generationTime(node),
			offset: generationOffset(node),
		},
		transform: {
			position: location.position,
			positionRange: location.positionRange,
			positionKeys: location.positionKeys,
			velocity: location.velocity,
			acceleration: location.acceleration,
			speed: { min: speedMin, max: speedMax },
			emissionDirection: location.emissionDirection,
			spreadAngle: location.spreadAngle,
			rotation: rotationPayload(node, life, context.warnings, nodeName),
			size: scalePayload(node, life, context.warnings, nodeName),
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
			models: new Set(),
			sounds: new Set(),
		},
		resolveTexture: createTextureResolver(
			inputPath,
			options.textureMap || {},
			options.rocasAssetMap || options.rocsAssetMap || null,
		),
		resolveAsset: createTextureResolver(
			inputPath,
			options.assetMap || {},
			options.rocasAssetMap || options.rocsAssetMap || null,
		),
	};

	const childRoot = find(projectRoot, "Root/Children");
	const rootNodes = childRoot ? children(childRoot, "Node") : [];
	const nodes = rootNodes.map((node, index) => convertNode(node, context, String(index + 1)));
	const startFrame = numberAt(projectRoot, "StartFrame", 0);
	const endFrame = numberAt(projectRoot, "EndFrame", 0);

	return {
		format: "EffekseerRobloxEffect",
		formatVersion: 2,
		name: options.moduleName || path.basename(inputPath, path.extname(inputPath)),
		source: normalizePath(path.relative(process.cwd(), inputPath)),
		frameRate: options.frameRate || 60,
		startFrame,
		endFrame,
		durationFrames: Math.max(0, endFrame - startFrame),
		isLoop: boolAt(projectRoot, "IsLoop", false),
		unitScale: options.unitScale ?? 0.2,
		particleSizeScale: options.particleSizeScale ?? 1,
		dependencies: {
			textures: Array.from(context.dependencies.textures).sort(),
			models: Array.from(context.dependencies.models).sort(),
			sounds: Array.from(context.dependencies.sounds).sort(),
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
