const fs = require("fs");
const path = require("path");
const { convertProject, writeLuauModule } = require("./converter");

const HELP = `
effekseer-for-roblox

Usage:
  effekseer-for-roblox convert <input.efkproj|input.efkefc> -o <output.luau> [options]

Options:
  --module-name <name>             Effect name stored in the generated module
  --texture-map <file.json>        JSON map from Effekseer texture paths to rbxassetid:// values
  --rocas-config <rocas.toml>      Read rocas lock files and resolve textures automatically
  --rocas-sync                     Run rocas sync before resolving textures
  --frame-rate <number>            Effekseer frame rate; default 60
  --unit-scale <number>            Effekseer world unit to Roblox studs; default 0.01
  --particle-size-scale <number>   ParticleEmitter size multiplier; default 1
  --warnings-json <file.json>      Write converter warnings as JSON
`;

function parseArgs(argv) {
	const command = argv[0];
	if (!command || command === "help" || command === "--help" || command === "-h") {
		return { command: "help" };
	}

	if (command !== "convert") {
		throw new Error(`Unknown command: ${command}\n\n${HELP.trim()}`);
	}

	const input = argv[1];
	if (!input) {
		throw new Error(`Missing input file.\n\n${HELP.trim()}`);
	}

	const options = {
		command,
		input,
		frameRate: 60,
		unitScale: 0.2,
		particleSizeScale: 1,
		rocasSync: false,
	};

	for (let index = 2; index < argv.length; index++) {
		const arg = argv[index];
		const next = () => {
			const value = argv[++index];
			if (!value) {
				throw new Error(`Missing value for ${arg}`);
			}
			return value;
		};

		if (arg === "-o" || arg === "--output") {
			options.output = next();
		} else if (arg === "--module-name") {
			options.moduleName = next();
		} else if (arg === "--texture-map") {
			options.textureMap = next();
		} else if (arg === "--rocas-config" || arg === "--rocs-config") {
			options.rocasConfig = next();
		} else if (arg === "--rocas-sync" || arg === "--rocs-sync") {
			options.rocasSync = true;
		} else if (arg === "--frame-rate") {
			options.frameRate = Number(next());
		} else if (arg === "--unit-scale") {
			options.unitScale = Number(next());
		} else if (arg === "--particle-size-scale") {
			options.particleSizeScale = Number(next());
		} else if (arg === "--warnings-json") {
			options.warningsJson = next();
		} else {
			throw new Error(`Unknown option: ${arg}`);
		}
	}

	if (!options.output) {
		throw new Error(`Missing output path. Pass -o <output.luau>.`);
	}

	return options;
}

function loadTextureMap(textureMapPath) {
	if (!textureMapPath) {
		return {};
	}

	const data = JSON.parse(fs.readFileSync(textureMapPath, "utf8"));
	const result = {};
	for (const [key, value] of Object.entries(data)) {
		result[key.replace(/\\/g, "/")] = String(value);
	}
	return result;
}

function fallbackBuildAssetMap(config, cwd) {
	const result = {
		bySourcePath: {},
		byRelativePath: {},
		groups: {},
	};

	for (const syncConfig of config.sync || []) {
		const assetDir = path.resolve(cwd, syncConfig.path);
		const lockPath = path.join(assetDir, `${syncConfig.name}.lock.json`);
		const group = {};

		if (!fs.existsSync(lockPath)) {
			result.groups[syncConfig.name] = group;
			continue;
		}

		const lock = JSON.parse(fs.readFileSync(lockPath, "utf8"));
		for (const [lockKey, entry] of Object.entries(lock)) {
			if (!entry || entry.assetId == null) {
				continue;
			}

			const normalizedKey = lockKey.replace(/\\/g, "/");
			const assetId = String(entry.assetId).startsWith("rbxassetid://")
				? String(entry.assetId)
				: `rbxassetid://${entry.assetId}`;
			const sourcePath = path.resolve(assetDir, normalizedKey).replace(/\\/g, "/");
			const relativePath = path.relative(cwd, sourcePath).replace(/\\/g, "/");

			group[normalizedKey] = assetId;
			result.bySourcePath[sourcePath] = assetId;
			result.byRelativePath[normalizedKey] = result.byRelativePath[normalizedKey] || assetId;
			result.byRelativePath[relativePath] = assetId;
			result.byRelativePath[`${syncConfig.name}/${normalizedKey}`] = assetId;
		}

		result.groups[syncConfig.name] = group;
	}

	return result;
}

async function loadRocasAssetMap(rocasConfigPath, shouldSync) {
	if (!rocasConfigPath) {
		return null;
	}

	let rocas;
	try {
		rocas = require("rocas");
	} catch (error) {
		throw new Error(
			"rocas integration requires the rocas package. Run `npm install` in Dev/Roblox first.",
		);
	}

	const configPath = path.resolve(rocasConfigPath);
	const cwd = path.dirname(configPath);

	if (typeof rocas.loadEnv === "function") {
		rocas.loadEnv(cwd);
	}

	const config = rocas.loadConfig(cwd);

	if (shouldSync) {
		const apiKey = process.env.ROCAS_API_KEY || process.env.ROCS_API_KEY;
		if (!apiKey) {
			throw new Error("ROCAS_API_KEY is required when --rocas-sync is specified.");
		}
		await rocas.syncAll(config, apiKey, cwd);
	}

	if (typeof rocas.buildAssetMap === "function") {
		return rocas.buildAssetMap(config, cwd);
	}

	return fallbackBuildAssetMap(config, cwd);
}

async function main(argv) {
	const options = parseArgs(argv);
	if (options.command === "help") {
		console.log(HELP.trim());
		return;
	}

	const textureMap = loadTextureMap(options.textureMap);
	const rocasAssetMap = await loadRocasAssetMap(options.rocasConfig, options.rocasSync);
	const effect = convertProject(path.resolve(options.input), {
		textureMap,
		rocasAssetMap,
		frameRate: options.frameRate,
		unitScale: options.unitScale,
		particleSizeScale: options.particleSizeScale,
		moduleName: options.moduleName,
	});

	writeLuauModule(effect, path.resolve(options.output));

	if (options.warningsJson) {
		fs.mkdirSync(path.dirname(path.resolve(options.warningsJson)), { recursive: true });
		fs.writeFileSync(path.resolve(options.warningsJson), `${JSON.stringify(effect.warnings, null, 2)}\n`);
	}

	for (const warning of effect.warnings) {
		const node = warning.node ? `[${warning.node}] ` : "";
		console.error(`warning ${warning.code}: ${node}${warning.message}`);
	}
}

module.exports = {
	fallbackBuildAssetMap,
	loadRocasAssetMap,
	loadTextureMap,
	main,
	parseArgs,
};
