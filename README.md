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

## Dry-run results, 2026-10-29

| Manifest | Commit | Image | composer | Assets to build | Schema |
| --- | --- | --- | --- | --- | --- |
| `branch-8.2.x` | `d99c905` | `8.2.8-nginx` | yes | none | same |
| `pr-42938-qa-ko` | `fea1105` | `9.2.0-8.1-nginx` | yes | admin-new-theme | `db_structure.sql` +1 -1 (a column default) |
| `develop-b2b` | `3e420b5` | `nightly-nginx` | no | none | same |

Not measured yet: the timings of the real launch (image pull, composer, asset build, boot), which need a Docker host.

## Known limits of v0

- Files deleted since the image's version stay in place.
- The database is the image's: a PR that changes the schema needs its migration applied by hand (or a `sql` entry). The report says when the schema files differ.
- No `multistore` profile yet.
- The asset build uses node 16 for 8.2.x and 20 otherwise, an assumption to confirm per branch.
- Each run is a fresh pair of containers: nothing is shared between runs, and no secret is passed to the shop.
