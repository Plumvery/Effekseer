#!/usr/bin/env node

const { main } = require("../src/generate-sample-pack");

main(process.argv.slice(2)).catch((error) => {
	console.error(error.stack || error.message);
	process.exit(1);
});
