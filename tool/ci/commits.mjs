// The commits of a pull request, for check_dco.mjs and lint_commits.mjs.
//
//   readCommits(base, head)   the non-merge commits reachable from head and not from base
//
// Node only, no packages: the runners have it, and so does a developer's machine.

import { execFileSync } from "node:child_process";

const FIELD = "\x1f";
const RECORD = "\x1e";

/** @returns {{sha: string, authorName: string, authorEmail: string, message: string}[]} */
export function readCommits(base, head) {
  const format = ["%H", "%an", "%ae", "%B"].join(FIELD) + RECORD;
  const out = execFileSync("git", ["log", "--no-merges", "--reverse", `--format=${format}`, `${base}..${head}`], {
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
  return out
    .split(RECORD)
    .map((record) => record.replace(/^\n/, ""))
    .filter((record) => record.trim() !== "")
    .map((record) => {
      const [sha, authorName, authorEmail, ...rest] = record.split(FIELD);
      return { sha, authorName, authorEmail, message: rest.join(FIELD).replace(/\s+$/, "") };
    });
}

/** The value of `--name value` or `--name=value` in argv, else the fallback. */
export function option(argv, name, fallback) {
  const at = argv.findIndex((arg) => arg === `--${name}` || arg.startsWith(`--${name}=`));
  if (at === -1) return fallback;
  const arg = argv[at];
  return arg.includes("=") ? arg.slice(arg.indexOf("=") + 1) : argv[at + 1];
}

/** Writes a GitHub Actions annotation, or a plain line outside Actions. */
export function annotate(level, message) {
  const text = message.replace(/\r?\n/g, " ");
  console.log(process.env.GITHUB_ACTIONS ? `::${level}::${text}` : `${level}: ${text}`);
}
