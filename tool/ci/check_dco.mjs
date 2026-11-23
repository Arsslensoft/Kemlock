// Checks that every commit of a pull request carries a Developer Certificate of Origin sign-off
// (https://developercertificate.org) by its author: a `Signed-off-by: Name <email>` line whose
// email is the email the commit's author used. `git commit -s` adds it.
//
//   node tool/ci/check_dco.mjs --base <sha> --head <sha>
//
// Merge commits are not looked at. DCO_EXEMPT=true, which the workflow sets only for a pull request
// from a branch of this repository that Dependabot or release-please opened, passes every commit:
// those commits are made by a bot, which can't certify anything, and the people who merge the
// pull request review what is in it.

import { annotate, option, readCommits } from "./commits.mjs";

const SIGNOFF = /^Signed-off-by:[ \t]*(.*?)[ \t]*<([^<>\s]+)>[ \t]*$/gim;

/** The sign-offs in a commit message, as {name, email}. */
function signOffs(message) {
  return [...message.matchAll(SIGNOFF)].map((m) => ({ name: m[1].trim(), email: m[2].trim() }));
}

/** Whether one of the message's sign-offs is the author's. */
function signedByAuthor(commit) {
  return signOffs(commit.message).some(
    (s) => s.name !== "" && s.email.toLowerCase() === commit.authorEmail.trim().toLowerCase(),
  );
}

function main(argv) {
  if (process.env.DCO_EXEMPT === "true") {
    console.log("This pull request is exempt: a bot's branch of this repository. Nothing to check.");
    return 0;
  }
  const base = option(argv, "base");
  const head = option(argv, "head", "HEAD");
  if (!base) {
    console.error("usage: check_dco.mjs --base <sha> [--head <sha>]");
    return 2;
  }
  const commits = readCommits(base, head);
  if (commits.length === 0) {
    console.log("No commits to check.");
    return 0;
  }
  const missing = commits.filter((commit) => !signedByAuthor(commit));
  for (const commit of commits) {
    const subject = commit.message.split("\n")[0];
    console.log(`${missing.includes(commit) ? "MISSING" : "ok     "} ${commit.sha.slice(0, 10)} ${subject}`);
  }
  if (missing.length === 0) {
    console.log(`\nAll ${commits.length} commit(s) are signed off by their author.`);
    return 0;
  }
  for (const commit of missing) {
    annotate(
      "error",
      `${commit.sha.slice(0, 10)} has no "Signed-off-by: ${commit.authorName} <${commit.authorEmail}>" line, ` +
        "the author's name and email as the commit has them.",
    );
  }
  console.log(`
${missing.length} of ${commits.length} commit(s) lack a sign-off by their author. By signing off you
certify the Developer Certificate of Origin (https://developercertificate.org): that you wrote the
change or have the right to submit it under the project's licence. See CONTRIBUTING.md.

To sign off the last N commits of your branch, and push them again:

    git rebase --signoff HEAD~N
    git push --force-with-lease

and to sign off every commit from now on, commit with \`git commit -s\`.`);
  return 1;
}

process.exitCode = main(process.argv.slice(2));
