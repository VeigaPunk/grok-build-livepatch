# Publish VeigaPunk/grok-build-livepatch (public)

Target: **public** GitHub repository `VeigaPunk/grok-build-livepatch`.

Local `origin` is SSH: `git@github.com:VeigaPunk/grok-build-livepatch.git`.

## Preferred path (already used on this machine)

1. **SSH agent works** (1Password agent or `ssh-add`):
   ```bash
   ssh -T git@github.com
   # expect: Hi VeigaPunk! You've successfully authenticated...
   ```
2. **Create the empty public repo** with GitHub CLI + token (SSH cannot create repos):
   ```bash
   export GH_TOKEN="$(op read 'op://Personal/GitHub CLI/credential')"   # or paste a PAT
   # never commit GH_TOKEN; unset when done
   gh auth status
   gh repo create VeigaPunk/grok-build-livepatch \
     --public \
     --description "Livepatch Grok Build CLI: hard-ban general-purpose/explore; 6h upstream re-apply"
   unset GH_TOKEN
   ```
   Or one-shot without exporting into your shell history:
   ```bash
   op run --env-file=<(printf '%s\n' 'GH_TOKEN=op://Personal/GitHub CLI/credential') -- \
     gh repo create VeigaPunk/grok-build-livepatch --public \
     --description "Livepatch Grok Build CLI: hard-ban general-purpose/explore; 6h upstream re-apply"
   ```
3. **Push with SSH** (no `gh` needed for push):
   ```bash
   git push -u origin main
   ```
4. Verify:
   ```bash
   git ls-remote origin HEAD
   curl -sI https://github.com/VeigaPunk/grok-build-livepatch | head -5
   ```

Helper script (requires `GH_TOKEN`): `./scripts/publish.sh`.

## If `gh auth` fails — exact human PAT steps

GitHub CLI reports: *You are not logged into any GitHub hosts* when `~/.config/gh` is empty. Create a token once, then either inject via env or run `gh auth login`.

### A. Fine-grained personal access token (recommended)

1. Browser: https://github.com/settings/personal-access-tokens/new  
   (or **Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate**).
2. **Token name:** e.g. `grok-build-livepatch-publish`.
3. **Expiration:** short (7–30 days) for a one-time publish, or rotate later.
4. **Resource owner:** your user `VeigaPunk`.
5. **Repository access:**  
   - If the repo **does not exist yet**: choose **All repositories**, or create the empty public repo on the website first (step B below) then **Only select repositories → grok-build-livepatch**.
6. **Permissions:**
   - Repository: **Administration** = Read and write (needed for `gh repo create`), **Contents** = Read and write (push), **Metadata** = Read-only (automatic).
   - Account: none required for this ship.
7. Generate → **copy the token once** (`github_pat_…`). Store in 1Password; do not paste into the repo or chat.
8. Terminal:
   ```bash
   export GH_TOKEN='github_pat_…'   # paste once; do not commit
   gh auth status                   # should show logged in via token
   # create if missing:
   gh repo create VeigaPunk/grok-build-livepatch --public \
     --description "Livepatch Grok Build CLI: hard-ban general-purpose/explore; 6h upstream re-apply"
   unset GH_TOKEN
   git push -u origin main          # SSH origin
   ```

### B. Classic PAT (alternative)

1. Browser: https://github.com/settings/tokens/new  
2. Note: `grok-build-livepatch-publish`  
3. Scopes: check **`repo`** (full control of private repositories — also creates/pushes public).  
4. Generate → copy `ghp_…` into 1Password.  
5. Same terminal block as A step 8 with `export GH_TOKEN='ghp_…'`.

### C. Interactive `gh auth login` (no env token)

```bash
gh auth login
# GitHub.com → HTTPS → Login with a web browser (or paste token)
# Prefer: authenticate git with SSH separately; keep origin as git@github.com:...
```

After login, `gh repo create …` then `git push -u origin main`.

### D. Create repo in the browser only, push with SSH

1. https://github.com/new  
2. Owner **VeigaPunk**, name **grok-build-livepatch**, **Public**, **no** README/license (avoid non-fast-forward).  
3. Create repository.  
4. Locally:
   ```bash
   ssh -T git@github.com
   git remote -v   # origin = git@github.com:VeigaPunk/grok-build-livepatch.git
   git push -u origin main
   ```

## Failure notes

| Symptom | Cause | Fix |
|--------|--------|-----|
| `Repository not found` on `git push` | Repo missing or no access | Create public repo (above), confirm SSH user is VeigaPunk |
| `gh: not logged in` | No `GH_TOKEN` / no `gh auth login` | PAT steps A–C |
| HTTPS 404 after push | Private by mistake | `gh repo edit VeigaPunk/grok-build-livepatch --visibility public` (needs auth) |
| Push rejected non-fast-forward | GitHub init with README | Prefer empty create, or pull --rebase if intentional |

**Never** commit tokens, `.env` with `GH_TOKEN`, or paste PATs into issues/PRs.
