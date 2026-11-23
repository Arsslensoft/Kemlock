// Checks that the commits of a pull request, and its title, follow the commit rules of CLAUDE.md and
// CONTRIBUTING.md: Conventional Commits (https://www.conventionalcommits.org/en/v1.0.0/#specification),
// `type(scope): what the change does`, in plain words, lowercase after the colon, no trailing period.
//
//   node tool/ci/lint_commits.mjs --base <sha> [--head <sha>] [--title "<pull request title>"]
//
// The pull request's title is checked too, because a squash merge makes it the commit's subject.
// The types and scopes are the ones CLAUDE.md lists; keep the two in step.

import { annotate, option, readCommits } from "./commits.mjs";

const TYPES = ["feat", "fix", "test", "chore", "docs", "refactor", "revert"];

const SCOPES = [
  // CLAUDE.md: the area touched.
  "accounts", "backup", "breaches", "sync", "vault", "keys", "notes", "settings", "lock", "setup",
  "export", "import", "qr", "crypto", "storage", "clipboard", "autofill", "passkeys", "passwords",
  "subscription", "paywall", "i18n", "theme", "ui", "android", "ios", "pwa", "deps", "lint", "mobile",
  // The repository around the app: workflows and tooling, files at the root, releases, security policy.
  "ci", "repo", "release", "security",
];

const MAX_HEADER = 100;
const HEADER = new RegExp(`^(${TYPES.join("|")})(?:\\(([a-z0-9-]+)\\))?(!)?: (\\S.*)$`);

/** Problems with one header line (a commit's subject or a pull request's title); none if it is fine. */
function headerProblems(header) {
  if (/^(fixup|squash|amend)! /.test(header)) return ["a fixup, squash or amend commit: fold it into the commit it fixes"];
  if (/^Revert "/.test(header)) return []; // what GitHub's Revert button writes
  const match = HEADER.exec(header);
  if (!match) {
    return [`not "type(scope): description" with a type of ${TYPES.join(", ")}`];
  }
  const problems = [];
  const [, , scope, , description] = match;
  if (scope !== undefined && !SCOPES.includes(scope)) {
    problems.push(`the scope "${scope}" is not one of CLAUDE.md's (${SCOPES.join(", ")})`);
  }
  if (/^[A-Z]/.test(description)) problems.push("the description starts with a capital: lowercase after the colon");
  if (/[.]$/.test(description)) problems.push("the description ends with a period");
  if (header.length > MAX_HEADER) problems.push(`the subject is ${header.length} characters, over ${MAX_HEADER}`);
  return problems;
}

/** Problems with a whole commit message. */
function messageProblems(message) {
  const lines = message.split("\n");
  const problems = headerProblems(lines[0]);
  if (lines.length > 1 && lines[1].trim() !== "") problems.push("no blank line between the subject and the body");
  // AI agents write an Assisted-by footer, never a Co-Authored-By line (CLAUDE.md).
  if (/^Co-authored-by:.*(claude|anthropic|copilot|openai|gpt|gemini|codex|\bAI\b)/im.test(message)) {
    problems.push("a Co-Authored-By line names an AI tool: use `Assisted-by: <model> via <tool>` instead");
  }
  for (const line of lines.filter((l) => /^Assisted-by:/i.test(l))) {
    if (!/^Assisted-by: \S.* via \S.*$/.test(line)) problems.push(`"${line}" is not "Assisted-by: <model> via <tool>"`);
  }
  return problems;
}

function main(argv) {
  const base = option(argv, "base");
  const head = option(argv, "head", "HEAD");
  const title = option(argv, "title", process.env.PR_TITLE ?? "");
  if (!base) {
    console.error('usage: lint_commits.mjs --base <sha> [--head <sha>] [--title "<title>"]');
    return 2;
  }

  let failed = 0;
  const report = (what, problems) => {
    if (problems.length === 0) {
      console.log(`ok      ${what}`);
      return;
    }
    failed += 1;
    console.log(`FAILED  ${what}`);
    for (const problem of problems) {
      console.log(`          - ${problem}`);
      annotate("error", `${what}: ${problem}`);
    }
  };

  if (title !== "") report(`pull request title: ${title}`, headerProblems(title));
  const commits = readCommits(base, head);
  for (const commit of commits) {
    report(`${commit.sha.slice(0, 10)} ${commit.message.split("\n")[0]}`, messageProblems(commit.message));
  }
  if (title === "" && commits.length === 0) console.log("No commits to check.");

  if (failed === 0) return 0;
  console.log(`
${failed} message(s) break the commit rules. They are in CONTRIBUTING.md, from CLAUDE.md:

    type(scope): what the change does

with a type of ${TYPES.join(", ")}; lowercase after the colon, no trailing period, one change per
commit. To reword the last N commits of your branch: git rebase -i HEAD~N (reword), then
git push --force-with-lease. To fix a pull request's title, edit it on GitHub.`);
  return 1;
}

process.exitCode = main(process.argv.slice(2));
