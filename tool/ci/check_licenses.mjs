// Checks that the licence of every Dart package Kemlock ships with can be combined with the
// GPL-3.0-or-later (LICENSE): MIT, BSD, Apache-2.0, ISC and the like. It fails on a licence outside the
// list, on a package whose licence file it can't read, and on a licence it can't tell.
//
//   node tool/ci/check_licenses.mjs [--project mobile] [--overrides tool/ci/license-overrides.json]
//   node tool/ci/check_licenses.mjs --classify <licence file>      what the check reads in one file
//
// It runs `dart pub deps --json` in the project (run `flutter pub get` first) for the
// packages the app depends on, finds each one's directory in .dart_tool/package_config.json, and reads
// the licence files there (LICENSE, LICENSE.md, COPYING, UNLICENSE and the like). A package of
// the Flutter SDK is BSD-3-Clause, and a package under packages/ is Kemlock's own.
//
// The text of a licence file is matched against the wording of the licences in the allowlist, which
// is how SPDX's own matching starts, not its whole algorithm: a file that holds several licences
// (common in Flutter packages) must have every one of them in the list. A package the check can't
// settle, or one whose licence is outside the list, is added to the overrides file after a person
// reads its licence, with the SPDX identifier they found and the reason it is fine. Each override
// is a reviewed exception, and is printed every run.
//
// Gradle's dependencies (the Android side) aren't read here: no licence plugin is added to the build,
// and dependency review's licence check (.github/workflows/dependency-review.yml) covers them.

import { execFileSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

// What a GPL-3.0-or-later program may carry. GPL-2.0-only is not here: it can't be combined with GPL-3.0
// code, and AGPL, the Creative Commons licences other than CC0 and every non-commercial or
// "no derivatives" licence need a person's decision.
const ALLOWED = new Set([
  "MIT", "MIT-0", "BSD-2-Clause", "BSD-3-Clause", "0BSD", "Apache-2.0", "ISC", "Zlib", "MPL-2.0",
  "CC0-1.0", "Unlicense", "BSL-1.0", "Python-2.0", "BlueOak-1.0.0",
]);

/** Whether one SPDX identifier is on the list: the exact ones, any LGPL, and the GPL that GPL-3.0 can take. */
function isAllowed(id) {
  if (ALLOWED.has(id)) return true;
  if (/^LGPL-/.test(id)) return true;
  return /^GPL-3\.0(-only|-or-later|\+)?$/.test(id) || /^GPL-2\.0(-or-later|\+)$/.test(id);
}

/**
 * The licences a text contains, as SPDX identifiers. Each rule matches the wording that licence has
 * in every copy of it; a text can match several.
 */
function classify(rawText) {
  const text = rawText.toLowerCase().replace(/[\s*#>]+/g, " ").replace(/[“”]/g, '"').replace(/[‘’]/g, "'");
  const found = new Set();

  if (/permission is hereby granted, free of charge, to any person obtaining a copy of this software/.test(text)) {
    found.add("MIT");
  }
  if (/sil open font license/.test(text)) found.add("OFL-1.1");
  if (/permission to use, copy, modify, and\/or distribute this software for any purpose with or without fee/.test(text)) {
    found.add("ISC");
  }
  if (/redistribution and use in source and binary forms, with or without\s*modification, are permitted/.test(text)) {
    if (/advertising materials mentioning features/.test(text)) found.add("BSD-4-Clause");
    else if (/neither the name of|the names? of [^.]{0,200}may not be used to endorse|may be used to endorse or promote/.test(text)) {
      found.add("BSD-3-Clause");
    } else found.add("BSD-2-Clause");
  }
  if (/apache license,? version 2\.0|licensed under the apache license/.test(text)) found.add("Apache-2.0");
  if (/mozilla public license,? (version |v\.? ?)2\.0/.test(text)) found.add("MPL-2.0");
  if (/boost software license/.test(text)) found.add("BSL-1.0");
  if (/this is free and unencumbered software released into the public domain/.test(text)) found.add("Unlicense");
  if (/cc0 1\.0 universal|creative commons zero|creativecommons\.org\/publicdomain\/zero/.test(text)) found.add("CC0-1.0");
  if (/python software foundation license/.test(text)) found.add("Python-2.0");
  if (/altered source versions must be plainly marked as such/.test(text)) found.add("Zlib");
  // MPL-2.0 names the GPL, LGPL and AGPL as its "Secondary Licenses" in its definitions: that is not
  // a licence of the package.
  if (!found.has("MPL-2.0")) {
    const later = /or \(at your option\) any later version|or any later version|or later/.test(text);
    if (/gnu affero general public license,? (?:version|v) ?\d/.test(text)) found.add("AGPL-3.0-or-later");
    // The titles carry a version ("GNU Lesser General Public License, version 3"); the GPL's own text
    // only mentions the LGPL without one.
    const lgpl = /gnu (?:lesser|library) general public license,? (?:version|v) ?(\d)/.exec(text);
    const gpl = /gnu general public license,? (?:version|v) ?(\d)/.exec(text);
    if (lgpl) found.add(lgpl[1] === "3" ? "LGPL-3.0-or-later" : "LGPL-2.1-or-later");
    if (gpl) {
      found.add(gpl[1] === "3" ? (later ? "GPL-3.0-or-later" : "GPL-3.0-only") : later ? "GPL-2.0-or-later" : "GPL-2.0-only");
    } else if (!lgpl && /gnu (?:lesser |library )?general public license/.test(text)) {
      found.add("GPL-unknown-version");
    }
  }
  if (/creative commons attribution|cc by/.test(text) && !found.has("CC0-1.0")) found.add("CC-BY");
  if (/non-?commercial|noncommercial/.test(text) && /creative commons/.test(text)) found.add("CC-NC");
  return [...found].sort();
}

const LICENCE_FILE = /^(licen[cs]e|copying|unlicen[cs]e)([.-].*)?$/i;

/** The identifiers found in the licence files of a package directory; empty when there is none to read. */
function licencesOfDirectory(dir) {
  const ids = new Set();
  let files = [];
  try {
    files = readdirSync(dir).filter((name) => LICENCE_FILE.test(name) && statSync(join(dir, name)).isFile());
  } catch {
    return { ids: [], files: [] };
  }
  for (const name of files) for (const id of classify(readFileSync(join(dir, name), "utf8"))) ids.add(id);
  return { ids: [...ids].sort(), files };
}

function option(argv, name, fallback) {
  const at = argv.findIndex((a) => a === `--${name}` || a.startsWith(`--${name}=`));
  if (at === -1) return fallback;
  return argv[at].includes("=") ? argv[at].slice(argv[at].indexOf("=") + 1) : argv[at + 1];
}

function loadOverrides(path) {
  if (!existsSync(path)) return {};
  const parsed = JSON.parse(readFileSync(path, "utf8"));
  const overrides = parsed.pub ?? {};
  for (const [name, entry] of Object.entries(overrides)) {
    if (!entry.license || !entry.reason || !entry.reviewed) {
      throw new Error(`${path}: the override of ${name} needs "license" (SPDX), "reason" and "reviewed" (a date)`);
    }
  }
  return overrides;
}

/** Where each package of the project lives, from .dart_tool/package_config.json. */
function packageDirectories(project) {
  const configPath = join(project, ".dart_tool", "package_config.json");
  if (!existsSync(configPath)) throw new Error(`${configPath} is missing: run flutter pub get in ${project} first`);
  const base = pathToFileURL(dirname(configPath) + "/");
  const directories = new Map();
  for (const pkg of JSON.parse(readFileSync(configPath, "utf8")).packages) {
    const root = new URL(pkg.rootUri.endsWith("/") ? pkg.rootUri : pkg.rootUri + "/", base);
    directories.set(pkg.name, fileURLToPath(root));
  }
  return directories;
}

function main(argv) {
  const single = option(argv, "classify");
  if (single) {
    const ids = classify(readFileSync(single, "utf8"));
    console.log(`${single}: ${ids.length ? ids.join(", ") : "no licence recognised"}`);
    for (const id of ids) console.log(`  ${id}: ${isAllowed(id) ? "allowed" : "NOT allowed"}`);
    return 0;
  }

  const project = resolve(option(argv, "project", "mobile"));
  const overrides = loadOverrides(resolve(option(argv, "overrides", "tool/ci/license-overrides.json")));

  let deps;
  try {
    deps = JSON.parse(
      execFileSync("dart", ["pub", "deps", "--json"], { cwd: project, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 }),
    );
  } catch (error) {
    console.error(`dart pub deps failed in ${project}: ${error.message}`);
    return 2;
  }
  const directories = packageDirectories(project);

  // dart pub refuses --json with --no-dev, so the packages the app ships are found here: everything the
  // root depends on, and what those depend on, leaving the dev dependencies and what only they bring out.
  const byName = new Map(deps.packages.map((pkg) => [pkg.name, pkg]));
  const root = deps.packages.find((pkg) => pkg.kind === "root");
  const devOnly = new Set(root?.devDependencies ?? []);
  const shipped = new Set();
  const queue = (root?.dependencies ?? []).filter((name) => !devOnly.has(name));
  while (queue.length > 0) {
    const name = queue.pop();
    if (shipped.has(name) || !byName.has(name)) continue;
    shipped.add(name);
    queue.push(...(byName.get(name).dependencies ?? []));
  }

  const rows = [];
  const problems = [];
  const used = new Set();
  for (const pkg of deps.packages) {
    if (pkg.kind === "root" || !shipped.has(pkg.name)) continue;
    const row = { name: pkg.name, version: pkg.version, source: pkg.source, licences: [], note: "" };
    rows.push(row);

    if (pkg.source === "path") {
      row.licences = ["GPL-3.0-or-later"];
      row.note = "Kemlock's own";
      continue;
    }
    if (pkg.source === "sdk") {
      row.licences = ["BSD-3-Clause"];
      row.note = "the Flutter SDK";
      continue;
    }
    if (overrides[pkg.name]) {
      used.add(pkg.name);
      row.licences = [overrides[pkg.name].license];
      row.note = `override, reviewed ${overrides[pkg.name].reviewed}: ${overrides[pkg.name].reason}`;
      continue;
    }

    const directory = directories.get(pkg.name);
    const { ids, files } = directory ? licencesOfDirectory(directory) : { ids: [], files: [] };
    row.licences = ids;
    row.note = files.join(", ");
    if (ids.length === 0) {
      problems.push(`${pkg.name} ${pkg.version}: ${files.length ? "no licence recognised in " + files.join(", ") : "no licence file"}`);
    } else if (!ids.every(isAllowed)) {
      problems.push(`${pkg.name} ${pkg.version}: ${ids.filter((id) => !isAllowed(id)).join(", ")} is not a licence GPL-3.0-or-later can take`);
    }
  }

  const width = Math.max(...rows.map((r) => r.name.length), 7);
  for (const row of rows) {
    console.log(`${row.name.padEnd(width)}  ${row.version.padEnd(12)}  ${(row.licences.join(" + ") || "?").padEnd(28)}  ${row.note}`);
  }
  console.log(`\n${rows.length} package(s) read in ${project}.`);

  for (const name of Object.keys(overrides)) {
    if (!used.has(name)) console.log(`warning: the override of ${name} is not used by this build.`);
  }
  if (problems.length === 0) {
    console.log("Every licence is one a GPL-3.0-or-later program may carry.");
    return 0;
  }
  console.log("");
  for (const problem of problems) {
    console.log(process.env.GITHUB_ACTIONS ? `::error::${problem}` : `error: ${problem}`);
  }
  console.log(
    `\n${problems.length} package(s) need a person to read their licence. If one is fine, add it to\n` +
      'tool/ci/license-overrides.json: "name": {"license": "<SPDX id>", "reason": "...", "reviewed": "YYYY-MM-DD"}.\n' +
      "If it is not, don't depend on it.",
  );
  return 1;
}

process.exitCode = main(process.argv.slice(2));
