# PrestaShop preview, launch PoC (OS-42)

Starts a PrestaShop shop on any commit of a maintained branch, from a small JSON manifest, so an agent (the `prestashop-pr-qa` skill) or a human can act on it. Jira: [OS-42](https://prestashop-jira.atlassian.net/browse/OS-42).

Target from the ticket: a shop ready in under 5 minutes on a CI runner, on 8.2.x, 9.x and develop.

## How it works

Installing PrestaShop from scratch takes minutes: `composer install`, the asset builds, then the installer. [Flashlight](https://github.com/PrestaShop/prestashop-flashlight) images already contain all three for each released version, with the database as a dump restored in seconds. So the launcher does not install anything it can reuse:

1. **Resolve** the code under test to a commit. A ref that does not exist stops the run. There is no fallback to another branch, so a deleted contributor branch can never silently become develop.
2. **Pick the image** of the closest released version for the base branch (`base-images.json`): `8.2.8` for 8.2.x, `9.2.0` for 9.2.x, `nightly` for develop.
3. **Compare** the code under test with the commit the image was built from, using git object ids of folders, so no history is downloaded:
   - `composer.lock` differs: the vendor is reinstalled in the container
   - an asset project's sources differ: only that project is built, on the host, in a `node` container
   - the SQL structure, the upgrade scripts or the Doctrine entities differ: a warning, with the files, in the report
4. **Overlay** the tracked files of the commit on the image's code, then apply the manifest: modules, profile, configuration, SQL.
5. **Wait** until the front office answers, and check the back office.
6. **Check the code** the shop holds: up to five files, the pull request's own first, then files that differ from the image, are hashed inside the container the way git does and compared with the commit. The container is new, so no opcache can serve an older copy. A file that does not match fails the launch.

Everything the run decided and how long each step took is written to `launch.json`.

## The manifest, v0

Schema: [manifest.schema.json](manifest.schema.json). The smallest one:

```json
{ "version": 0, "prestashop": { "ref": "8.2.x" } }
```

A pull request replayed on a given commit, with a fixture:

```json
{
  "version": 0,
  "prestashop": { "ref": "pull/42938/head", "commit": "fea11050b" },
  "php": "8.1",
  "sql": ["../fixtures/second-customer-with-order.sql"]
}
```

| Field | What it does |
| --- | --- |
| `prestashop.ref` | branch, tag or `pull/N/head` |
| `prestashop.commit` | pins the commit, takes precedence over `ref` |
| `prestashop.base` | 8.2.x, 9.1.x, 9.2.x or develop. Read from the pull request or the branch when omitted |
| `php` | picks the image variant, `9.2.0-8.1-nginx` for example |
| `debug` | `_PS_MODE_DEV_`, off by default |
| `profile` | `vanilla` (default seed) or `b2b` |
| `modules` | `{name, zip}` for a release zip, `{name, github, ref}` to build from source |
| `config` | `ps_configuration` values |
| `sql` | SQL files relative to the manifest, `PREFIX_` replaced by `ps_` |

## Running it

Needs `docker`, `git`, `jq` and `curl`. `GITHUB_TOKEN` is optional, it only raises the API rate limit.

```bash
bin/launch.sh examples/branch-8.2.x.json --out preview-out
docker compose -f preview-out/compose.yml down -v
```

`--dry-run` resolves, compares and prepares everything without Docker: it is how the decisions above can be checked on a laptop.

On GitHub Actions, [.github/workflows/preview.yml](.github/workflows/preview.yml) launches a list of manifests in parallel and puts each `launch.json` in the run summary.

## Results on GitHub Actions, 2026-10-29

`ubuntu-latest` runners, the three manifests in parallel ([run 40915932321](https://github.com/nicosomb/ps-preview-poc/actions/runs/40915932321)). Seconds, as written in `launch.json`. "Job" is the whole GitHub job, checkout included.

| Manifest | Image | Rebuilt | Resolve | Assets | Pull | Boot | **Ready in** | Job |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `branch-8.2.x` | `8.2.8-nginx` | composer | 3 | 0 | 11 | 29 | **49** | 56 |
| `develop-b2b` | `nightly-nginx` | nothing | 4 | 0 | 11 | 25 | **51** | 58 |
| `pr-42938-qa-ko` | `9.2.0-8.1-nginx` | composer, admin-new-theme | 5 | 67 | 13 | 48 | **141** | 147 |

All three under the 5-minute target. "Ready" means both offices answer 200 with a full page (front office home, back office login page), not only that the server answers.

Code check, [run 40917081921](https://github.com/nicosomb/ps-preview-poc/actions/runs/40917081921): every file matched its commit. For the pull request, the three files it changes (`CustomerThreadQueryBuilder`, `OrderQueryBuilder`, `OutstandingQueryBuilder`) are served exactly as in `fea11050b`; 3 files for 8.2.x, 2 for develop.

What the runs taught, and what was fixed on the way:

- **An answer is not a shop.** The first run declared the PR shop ready on a 982-byte fatal error page. The check now requires a full HTML page from both offices, saves both pages, and collects `var/logs` when it fails.
- **composer reinstalls the native modules and themes as root.** PHP then could not write to `themes/hummingbird/assets/cache` (front office fatal) nor update `modules/productcomments` (back office 500). The whole folder is now handed back to `www-data` at the end of the init.
- **The asset build is the cost.** 67 to 83 s for `admin-new-theme` alone, half of the PR's launch. A PR that only touches PHP skips it.
- **The image choice matters more than expected.** develop on `nightly` rebuilds nothing; 9.2.x on `9.2.0` rebuilds composer and the admin theme, because the branch has moved since the release. A nightly image per maintained branch would bring every launch close to 50 s.

## The QA agent on top

[.github/workflows/qa.yml](.github/workflows/qa.yml) starts two shops side by side, the code before the fix on port 8000 and the pull request's code on port 8001, from the same image and the same data. It then runs the `prestashop-pr-qa` skill (PrestaShop/skills `main` with #6 merged) through Claude Code, unattended. The two shops replace the skill's two gates, where a developer would switch the code by hand. The prompt is written by [bin/qa-prompt.sh](bin/qa-prompt.sh): no question gets an answer, so what the agent could not verify goes in the report rather than being guessed. It reads only what a QA would read, never the pull request's comments, and posts nothing.

The report, the video, the comment to paste, the agent's cost and turn count are uploaded as the `qa-pr-<number>` artifact.

Needs a repository secret `ANTHROPIC_API_KEY`. Open security points before this runs on pull requests from forks:

- The agent has a shell and the API key in its environment, and it reads text written by the pull request's author. A prompt injection in a pull request could try to make it leak the key. The shops never see the key: it is not passed to the containers.
- The artifacts of a public repository are readable by any GitHub user. The video shows the back office login with Flashlight's public default credentials, nothing else secret, but a shop seeded with real data must never run here.

## Known limits of v0

- Files deleted since the image's version stay in place.
- The database is the image's: a PR that changes the schema needs its migration applied by hand (or a `sql` entry). The report says when the schema files differ.
- No `multistore` profile yet.
- The asset build uses node 16 for 8.2.x and 20 otherwise, an assumption to confirm per branch.
- Each run is a fresh pair of containers: nothing is shared between runs, and no secret is passed to the shop.
- Not verified yet: the data the manifest applies (its SQL ran without error, the rows were not read back). It belongs to the agent step, which reads the shop anyway.
- The shop only lives as long as the job: an agent has to run in the same job, or the shop needs a tunnel to be reached from outside.
