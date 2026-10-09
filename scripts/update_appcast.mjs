#!/usr/bin/env node
// Announcements use --informational --url <release-page>, with no enclosure.
// Parse/update policy uses XML namespace identities, including alternate prefixes.
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { spawnSync } from "node:child_process";

export function updateAppcast(xml, options) {
    const result = spawnSync("python3", [new URL("appcast_policy.py", import.meta.url).pathname, "--update"], {
        input: JSON.stringify({ xml, options: { pubDate: new Date().toUTCString(), ...options } }),
        encoding: "utf8", maxBuffer: 2 * 1024 * 1024, timeout: 5000
    });
    if (result.status !== 0) throw new Error(result.stderr?.trim() || "invalid appcast policy");
    return result.stdout;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
    try {
        const args = process.argv.slice(2);
        const options = {};
        for (let i = 0; i < args.length; i++) {
            const name = args[i];
            if (name === "--informational") { options.informational = true; continue; }
            if (!["--version", "--url", "--signature", "--length", "--appcast"].includes(name) || !args[i + 1] || args[i + 1].startsWith("--")) {
                throw new Error(`invalid argument ${name}`);
            }
            options[name.slice(2)] = args[++i];
        }
        if (!options.version || !options.url) throw new Error("missing --version or --url");
        const path = options.appcast ?? "landing/appcast.xml";
        writeFileSync(path, updateAppcast(readFileSync(path, "utf8"), options));
        console.log(`appcast: added ${options.version} (${options.informational ? "information only" : `${options.length} bytes`})`);
    } catch (error) { console.error(error.message); process.exitCode = 1; }
}
