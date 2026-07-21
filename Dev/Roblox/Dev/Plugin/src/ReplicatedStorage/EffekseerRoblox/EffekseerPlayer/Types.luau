--!nonstrict
-- Shared type definitions for the generated effect data plus the small constant
-- tables used across the runtime modules.

local Types = {}

export type VectorPayload = {
	x: number,
	y: number,
	z: number,
}

export type RangePayload = {
	min: number,
	max: number,
	center: number?,
	infinite: boolean?,
}

export type BakedKeys = {
	frames: { number },
	values: { VectorPayload },
}

export type UVPayload = {
	type: number,
	start: { x: number, y: number },
	size: { x: number, y: number },
	animation: {
		frameLength: number,
		countX: number,
		countY: number,
		loopType: number,
		startSheet: number,
	}?,
	scroll: {
		speed: { x: number, y: number },
	}?,
}

export type SpawnPayload = {
	type: number,
	effectsRotation: boolean?,
	sphere: {
		radius: RangePayload,
		rotationX: RangePayload,
		rotationY: RangePayload,
	}?,
	circle: {
		radius: RangePayload,
		axis: number,
		division: number,
		angleStart: RangePayload,
		angleEnd: RangePayload,
		angleNoise: RangePayload?,
		order: number,
	}?,
	line: {
		from: { center: VectorPayload, min: VectorPayload, max: VectorPayload },
		to: { center: VectorPayload, min: VectorPayload, max: VectorPayload },
		division: number,
		noise: RangePayload?,
		order: number,
	}?,
}

export type SoundPayload = {
	wave: string,
	asset: string?,
	volume: RangePayload,
	pitch: RangePayload,
	delay: RangePayload,
}

export type EffectNode = {
	id: string,
	name: string,
	rendererType: string,
	rendered: boolean,
	texturePath: string?,
	texture: string?,
	alphaBlend: number,
	fadeIn: number,
	fadeOut: number,
	color: { r: number, g: number, b: number, a: number },
	colorOverLife: {
		start: { r: number, g: number, b: number, a: number },
		finish: { r: number, g: number, b: number, a: number },
	}?,
	uv: UVPayload?,
	spawn: SpawnPayload?,
	sound: SoundPayload?,
	visual: {
		sprite: {
			billboard: number?,
			position: {
				center: { x: number, y: number },
				size: { x: number, y: number },
			}?,
		}?,
		beam: {
			width: number,
			length: number,
		}?,
		ring: {
			vertexCount: number,
			outerRadius: number,
			innerRadius: number,
			outerRadiusFinish: number?,
			innerRadiusFinish: number?,
			billboard: number?,
		}?,
		model: {
			path: string?,
			asset: string?,
		}?,
	}?,
	life: RangePayload,
	generation: {
		max: number,
		time: RangePayload,
		offset: RangePayload,
	},
	transform: {
		position: VectorPayload,
		positionRange: {
			center: VectorPayload,
			min: VectorPayload,
			max: VectorPayload,
		}?,
		positionKeys: BakedKeys?,
		velocity: {
			center: VectorPayload,
			min: VectorPayload,
			max: VectorPayload,
		},
		acceleration: {
			center: VectorPayload,
			min: VectorPayload?,
			max: VectorPayload?,
		},
		speed: { min: number, max: number },
		emissionDirection: string,
		spreadAngle: number,
		rotation: {
			rotation: RangePayload,
			speed: RangePayload,
			rotation3: {
				center: VectorPayload,
				min: VectorPayload,
				max: VectorPayload,
			}?,
			speed3: {
				center: VectorPayload,
				min: VectorPayload,
				max: VectorPayload,
			}?,
			rotationKeys: BakedKeys?,
		},
		size: {
			start: number,
			finish: number,
			envelope: number,
			startVector: VectorPayload?,
			finishVector: VectorPayload?,
			pva: {
				scale: { center: VectorPayload, min: VectorPayload, max: VectorPayload },
				velocity: { center: VectorPayload, min: VectorPayload, max: VectorPayload },
				acceleration: { center: VectorPayload, min: VectorPayload, max: VectorPayload },
			}?,
			easing: {
				start: { center: VectorPayload, min: VectorPayload, max: VectorPayload },
				finish: { center: VectorPayload, min: VectorPayload, max: VectorPayload },
			}?,
			singlePva: {
				scale: RangePayload,
				velocity: RangePayload,
				acceleration: RangePayload,
			}?,
			singleEasing: {
				start: RangePayload,
				finish: RangePayload,
			}?,
			scaleKeys: BakedKeys?,
		},
	},
	children: { EffectNode },
}

export type EffectData = {
	name: string,
	frameRate: number?,
	startFrame: number?,
	endFrame: number?,
	durationFrames: number?,
	isLoop: boolean?,
	unitScale: number?,
	particleSizeScale: number?,
	nodes: { EffectNode },
}

export type PlayOptions = {
	loop: boolean?,
	unitScale: number?,
	particleSizeScale: number?,
	speedScale: number?,
	assetMap: { [string]: any }?,
	autoDestroy: boolean?,
	burstTaskLimit: number?,
	hideTarget: boolean?,
	useAdditiveSpriteParts: boolean?,
	useAdditivePreviewTexture: boolean?,
	name: string?,
}

Types.NORMAL_IDS = {
	Top = Enum.NormalId.Top,
	Bottom = Enum.NormalId.Bottom,
	Left = Enum.NormalId.Left,
	Right = Enum.NormalId.Right,
	Front = Enum.NormalId.Front,
	Back = Enum.NormalId.Back,
} :: { [string]: Enum.NormalId }

Types.RING_FALLBACK_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"

Types.BILLBOARD = {
	Billboard = 0,
	YAxisFixed = 1,
	Fixed = 2,
	RotatedBillboard = 3,
	DirectionalBillboard = 4,
}

return Types
