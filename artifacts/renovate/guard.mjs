// Runs before Renovate, with Renovate's own token: exits 1 when the token's user is a site admin, administers a
// repository, or can push to or merge into the default branch of one it can write to (README.md). Node's built-ins only.

const api = process.env.FORGEJO_API;
const token = process.env.RENOVATE_TOKEN;

if (!api || !token) {
  console.error('guard: FORGEJO_API and RENOVATE_TOKEN must be set');
  process.exit(1);
}

async function get(path) {
  const res = await fetch(`${api}${path}`, {
    headers: { Authorization: `token ${token}`, Accept: 'application/json' },
    signal: AbortSignal.timeout(30000),
  });
  if (res.status === 404) return null;
  if (!res.ok) throw new Error(`GET ${path}: ${res.status}`);
  return res.json();
}

const user = await get('/user');
if (!user) throw new Error('GET /user: 404');
const problems = [];
if (user.is_admin) problems.push(`${user.login} is a site admin, which no branch rule holds back`);

let checked = 0;
for (let page = 1; ; page++) {
  const repos = await get(`/user/repos?limit=50&page=${page}`);
  if (!repos || repos.length === 0) break;
  for (const repo of repos) {
    if (!repo.permissions?.push || repo.archived || repo.mirror) continue;
    checked++;
    // An admin of a repository, which an owner of its organization is, can remove the branch rule itself.
    if (repo.permissions.admin) {
      problems.push(`${repo.full_name}: ${user.login} administers the repository and can remove its branch rule`);
      continue;
    }
    if (repo.empty) {
      problems.push(`${repo.full_name} is empty, so its first commit would be ${user.login}'s`);
      continue;
    }
    const name = encodeURIComponent(repo.default_branch);
    const branch = await get(`/repos/${repo.full_name}/branches/${name}`);
    const where = `${repo.full_name}@${repo.default_branch}`;
    if (!branch) problems.push(`${where} does not exist`);
    else if (!branch.protected) problems.push(`${where} has no branch protection`);
    else if (branch.user_can_push) problems.push(`${where}: ${user.login} can push`);
    else if (branch.user_can_merge) problems.push(`${where}: ${user.login} can merge`);
  }
}

if (problems.length > 0) {
  console.error(`guard: Renovate does not run. ${problems.length} found:`);
  for (const problem of problems) console.error(`  ${problem}`);
  process.exit(1);
}
console.log(`guard: ${user.login} can write to ${checked} repositories and reaches the default branch of none`);
