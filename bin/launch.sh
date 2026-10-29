#!/usr/bin/env bash
# Starts the PrestaShop shop a v0 manifest describes, on top of the closest Flashlight image.
# See README.md for the manifest and for what each step decides.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: launch.sh <manifest.json> [--out DIR] [--port PORT] [--dry-run]

  --out DIR    where the run writes its files (default: ./preview-out)
  --port PORT  host port of the shop (default: 8000)
  --dry-run    resolve, compare and prepare everything, start nothing (no Docker needed)

Writes DIR/launch.json: the commit, the image, what had to be rebuilt, the timings and the URLs.
EOF
  exit 2
}

ROOT=$(cd "$(dirname "$0")/.." && pwd)
MANIFEST=
OUT=$PWD/preview-out
PORT=8000
DRY_RUN=false
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT=$2; shift 2 ;;
    --port) PORT=$2; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage ;;
    -*) usage ;;
    *) MANIFEST=$1; shift ;;
  esac
done
[ -n "$MANIFEST" ] || usage

die() { echo "error: $*" >&2; exit 1; }
log() { echo "* $*" >&2; }
now() { date +%s; }

for tool in git jq curl tar; do
  command -v "$tool" >/dev/null || die "$tool is not on PATH"
done
$DRY_RUN || command -v docker >/dev/null || die "docker is not on PATH (use --dry-run to only prepare)"

[ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"
MANIFEST_DIR=$(cd "$(dirname "$MANIFEST")" && pwd)
jq empty "$MANIFEST" 2>/dev/null || die "$MANIFEST is not valid JSON"
[ "$(jq -r '.version' "$MANIFEST")" = "0" ] || die "only manifest version 0 is supported"

mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
T_START=$(now)

m() { jq -r "$1 // empty" "$MANIFEST"; }
REPO=$(m .prestashop.repository); REPO=${REPO:-PrestaShop/PrestaShop}
REF=$(m .prestashop.ref)
COMMIT=$(m .prestashop.commit)
BASE=$(m .prestashop.base)
PHP_VERSION=$(m .php)
DEBUG=$(jq -r 'if .debug == true then "true" else "false" end' "$MANIFEST")
PROFILE=$(m .profile); PROFILE=${PROFILE:-vanilla}
[ -n "$REF$COMMIT" ] || die "prestashop.ref or prestashop.commit is required"
[ -f "$ROOT/profiles/$PROFILE.json" ] || die "unknown profile '$PROFILE' (see profiles/)"

github_api() {
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    curl -fsSL -H 'Accept: application/vnd.github+json' -H "Authorization: Bearer $GITHUB_TOKEN" "https://api.github.com/$1"
  else
    curl -fsSL -H 'Accept: application/vnd.github+json' "https://api.github.com/$1"
  fi
}

# 1. Resolve the code under test. A ref that does not exist stops the run: no fallback to
#    another branch, a deleted contributor branch must not silently become develop.
T=$(now)
case "$REF" in
  pull/*/head) FETCH_REF="refs/$REF"; PR_NUMBER=${REF#pull/}; PR_NUMBER=${PR_NUMBER%/head} ;;
  "") FETCH_REF=; PR_NUMBER= ;;
  *) FETCH_REF=$REF; PR_NUMBER= ;;
esac
if [ -n "$COMMIT" ] && [ ${#COMMIT} -lt 40 ]; then
  COMMIT=$(github_api "repos/$REPO/commits/$COMMIT" | jq -r .sha) \
    || die "commit '$(m .prestashop.commit)' not found in $REPO"
fi
if [ -z "$BASE" ]; then
  if [ -n "$PR_NUMBER" ]; then
    BASE=$(github_api "repos/$REPO/pulls/$PR_NUMBER" | jq -r .base.ref) || die "pull request #$PR_NUMBER not found in $REPO"
  else
    BASE=$REF
  fi
fi
IMG=$(jq -c --arg base "$BASE" '.[$base] // empty' "$ROOT/base-images.json")
[ -n "$IMG" ] || die "no Flashlight image for base '$BASE'. Set prestashop.base to one of: $(jq -r 'keys | join(", ")' "$ROOT/base-images.json")"
PS_IMAGE_VERSION=$(jq -r .version <<<"$IMG")
SOURCE_REF=$(jq -r '.sourceRef // empty' <<<"$IMG")
NODE_VERSION=$(jq -r .node <<<"$IMG")

SRC=$OUT/src
rm -rf "$SRC"
git init -q "$SRC"
git -C "$SRC" remote add origin "https://github.com/$REPO.git"
WANT=${COMMIT:-$FETCH_REF}
export GIT_TERMINAL_PROMPT=0
git -C "$SRC" fetch -q --depth=1 origin "$WANT" 2>"$OUT/fetch.err" \
  || die "cannot fetch '$WANT' from $REPO: the ref or the repository does not exist, or is private ($(tail -1 "$OUT/fetch.err"))"
SHA=$(git -C "$SRC" rev-parse FETCH_HEAD)
log "code under test: $REPO@${SHA:0:9} (base $BASE)"
T_RESOLVE=$(( $(now) - T ))

# 2. The Flashlight image, and the commit its code was built from.
if [ "$PS_IMAGE_VERSION" = nightly ]; then
  [ -z "$PHP_VERSION" ] || log "php is ignored for develop: Flashlight only publishes nightly-nginx"
  IMAGE_TAG=nightly-nginx
else
  IMAGE_TAG="$PS_IMAGE_VERSION${PHP_VERSION:+-$PHP_VERSION}-nginx"
fi
IMAGE="prestashop/prestashop-flashlight:$IMAGE_TAG"
HUB_TAG=$(curl -fsSL "https://hub.docker.com/v2/repositories/prestashop/prestashop-flashlight/tags/$IMAGE_TAG" 2>/dev/null) \
  || die "image $IMAGE does not exist on Docker Hub (check php: $PHP_VERSION)"
IMAGE_UPDATED=$(jq -r .last_updated <<<"$HUB_TAG")
IMAGE_SIZE_MB=$(jq -r '[.images[]?.size] | max // 0 | . / 1048576 | floor' <<<"$HUB_TAG")
if [ -n "$SOURCE_REF" ]; then
  IMAGE_SOURCE=refs/tags/$SOURCE_REF
else
  # nightly is built from develop: take the last develop commit before the image was published
  IMAGE_SOURCE=$(github_api "repos/$REPO/commits?sha=develop&until=$IMAGE_UPDATED&per_page=1" | jq -r '.[0].sha') \
    || die "cannot find the develop commit behind $IMAGE"
fi
git -C "$SRC" fetch -q --depth=1 --filter=blob:none origin "$IMAGE_SOURCE" 2>"$OUT/fetch.err" \
  || die "cannot fetch $IMAGE_SOURCE, the source of $IMAGE: $(tail -1 "$OUT/fetch.err")"
IMAGE_SHA=$(git -C "$SRC" rev-parse FETCH_HEAD)
log "image: $IMAGE (${IMAGE_SIZE_MB} MB, built from ${IMAGE_SHA:0:9})"

# 3. What differs between the image and the code under test. Git object ids of the folders are
#    compared, so no history and no blob of the image commit is needed.
object_id() { git -C "$SRC" rev-parse -q --verify "$1:$2" 2>/dev/null || echo missing; }
differs() {
  local path
  for path in "$@"; do
    [ "$(object_id "$SHA" "$path")" = "$(object_id "$IMAGE_SHA" "$path")" ] || return 0
  done
  return 1
}
COMPOSER_NEEDED=false
differs composer.lock && COMPOSER_NEEDED=true
ASSETS=()
ASSET_PROJECTS="admin-default:admin-dev/themes/default admin-new-theme:admin-dev/themes/new-theme front-core:themes/_core,themes/package-lock.json,themes/webpack.config.js front-classic:themes/classic/_dev front-hummingbird:themes/hummingbird"
for project in $ASSET_PROJECTS; do
  name=${project%%:*}
  paths=${project#*:}
  first=${paths%%,*}
  [ "$(object_id "$SHA" "$first")" != missing ] || continue
  # shellcheck disable=SC2086
  if differs ${paths//,/ }; then ASSETS+=("$name"); fi
done
DB_DRIFT=false
DB_DRIFT_FILES=
SCHEMA_PATHS="install-dev/data/db_structure.sql install-dev/upgrade/sql src/PrestaShopBundle/Entity"
# shellcheck disable=SC2086
if differs $SCHEMA_PATHS; then
  DB_DRIFT=true
  # shellcheck disable=SC2086
  DB_DRIFT_FILES=$(git -C "$SRC" diff --numstat "$IMAGE_SHA" "$SHA" -- $SCHEMA_PATHS | awk '{print $3 " (+" $1 " -" $2 ")"}')
fi
log "composer install: $COMPOSER_NEEDED, assets to build: ${ASSETS[*]:-none}, database schema differs from the image: $DB_DRIFT"
$DB_DRIFT && log "warning: the image's database was installed from older SQL or entities; pages using the new schema may fail"

# 4. The overlay: the tracked files of the code under test, minus what a shop never serves.
T=$(now)
OVERLAY=$OUT/overlay
rm -rf "$OVERLAY"
mkdir -p "$OVERLAY"
git -C "$SRC" archive "$SHA" -- . ':(exclude)install-dev' ':(exclude)tests' ':(exclude).github' ':(exclude)docker-compose.yml' \
  | tar -x -C "$OVERLAY"
T_OVERLAY=$(( $(now) - T ))

# 5. Assets, built on the host in a node container, only for the projects that differ.
T=$(now)
asset_dir() {
  case "$1" in
    admin-default) echo admin-dev/themes/default ;;
    admin-new-theme) echo admin-dev/themes/new-theme ;;
    front-core) echo themes ;;
    front-classic) echo themes/classic/_dev ;;
    front-hummingbird) echo themes/hummingbird ;;
  esac
}
if [ ${#ASSETS[@]} -gt 0 ] && ! $DRY_RUN; then
  for name in "${ASSETS[@]}"; do
    dir=$(asset_dir "$name")
    log "building $name assets in $dir (node $NODE_VERSION)"
    docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -e npm_config_cache=/tmp/.npm \
      -v "$OVERLAY:/app" -w "/app/$dir" "node:$NODE_VERSION" \
      sh -c 'npm ci --no-audit --no-fund --loglevel=error && npm run build' >"$OUT/assets-$name.log" 2>&1 \
      || die "$name assets failed to build, see $OUT/assets-$name.log"
    rm -rf "$OVERLAY/$dir/node_modules"
  done
fi
T_ASSETS=$(( $(now) - T ))

# 6. What the container applies after the overlay: modules, configuration, SQL.
PREVIEW=$OUT/preview
rm -rf "$PREVIEW"
mkdir -p "$PREVIEW/modules" "$PREVIEW/sql"
$COMPOSER_NEEDED && touch "$PREVIEW/composer-needed"
echo "$DEBUG" > "$PREVIEW/debug"
i=0
while IFS=$'\t' read -r name zip github ref; do
  [ -n "$name" ] || continue
  i=$((i + 1))
  prefix=$(printf '%02d' "$i")
  if [ -n "$zip" ]; then
    curl -fsSL -o "$PREVIEW/modules/$prefix-$name.zip" "$zip" || die "module $name: cannot download $zip"
  else
    curl -fsSL -o "$PREVIEW/modules/$prefix-$name.tar.gz" "https://codeload.github.com/$github/tar.gz/$ref" \
      || die "module $name: cannot download $github@$ref"
  fi
done < <(jq -r '.modules // [] | .[] | [.name, (.zip // ""), (.github // ""), (.ref // "")] | @tsv' "$MANIFEST")

CONFIG_KEYS=$(jq -n --slurpfile profile "$ROOT/profiles/$PROFILE.json" --slurpfile manifest "$MANIFEST" \
  '$profile[0].config + ($manifest[0].config // {})')
jq -r 'keys[] | select(test("^[A-Z0-9_]+$") | not)' <<<"$CONFIG_KEYS" | grep -q . && die "config keys must match ^[A-Z0-9_]+$"
# Keys are checked above, values have their quotes doubled: q is a single quote.
jq -r --arg q "'" 'to_entries[] | (.value | tostring | gsub($q; $q + $q)) as $v |
  "UPDATE PREFIX_configuration SET value = \($q)\($v)\($q), date_upd = NOW() WHERE name = \($q)\(.key)\($q);",
  "INSERT INTO PREFIX_configuration (name, value, date_add, date_upd) SELECT \($q)\(.key)\($q), \($q)\($v)\($q), NOW(), NOW() FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM PREFIX_configuration WHERE name = \($q)\(.key)\($q));"' \
  <<<"$CONFIG_KEYS" > "$PREVIEW/sql/00-config.sql"
i=0
while read -r file; do
  [ -n "$file" ] || continue
  i=$((i + 1))
  [ -f "$MANIFEST_DIR/$file" ] || die "sql file not found: $file (relative to the manifest)"
  cp "$MANIFEST_DIR/$file" "$PREVIEW/sql/$(printf '%02d' "$i")-$(basename "$file")"
done < <(jq -r '.sql // [] | .[]' "$MANIFEST")
for f in "$PREVIEW"/sql/*.sql; do
  sed 's/PREFIX_/ps_/g' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done

cat > "$OUT/compose.yml" <<EOF
name: ps-preview
services:
  mysql:
    image: mariadb:lts
    environment:
      MYSQL_USER: prestashop
      MYSQL_PASSWORD: prestashop
      MYSQL_ROOT_PASSWORD: prestashop
      MYSQL_DATABASE: prestashop
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect"]
      interval: 2s
      timeout: 5s
      retries: 60
  prestashop:
    image: $IMAGE
    user: root
    depends_on:
      mysql:
        condition: service_healthy
    environment:
      PS_DOMAIN: localhost:$PORT
      INIT_SCRIPTS_DIR: /tmp/init-scripts
      DEBUG_MODE: "false"
    volumes:
      - $OVERLAY:/tmp/overlay:ro
      - $PREVIEW:/tmp/preview:ro
      - $ROOT/container/init-scripts:/tmp/init-scripts:ro
    ports:
      - "$PORT:80"
EOF

write_report() {
  jq -n \
    --arg manifest "$MANIFEST" --arg repo "$REPO" --arg ref "$REF" --arg sha "$SHA" --arg base "$BASE" \
    --arg image "$IMAGE" --arg imageSha "$IMAGE_SHA" --argjson imageSizeMb "$IMAGE_SIZE_MB" \
    --argjson composer "$COMPOSER_NEEDED" --arg assets "${ASSETS[*]:-}" --argjson dbDrift "$DB_DRIFT" \
    --arg dbDriftFiles "$DB_DRIFT_FILES" \
    --arg profile "$PROFILE" --argjson dryRun "$DRY_RUN" --arg status "$1" \
    --argjson resolve "$T_RESOLVE" --argjson overlay "$T_OVERLAY" --argjson assetsTime "$T_ASSETS" \
    --argjson pull "${T_PULL:-0}" --argjson boot "${T_BOOT:-0}" --argjson total "$(( $(now) - T_START ))" \
    --arg fo "http://localhost:$PORT/" --arg bo "http://localhost:$PORT/admin-dev/" \
    '{status: $status, dryRun: $dryRun, manifest: $manifest,
      code: {repository: $repo, ref: $ref, commit: $sha, base: $base},
      image: {name: $image, builtFrom: $imageSha, sizeMb: $imageSizeMb},
      rebuilt: {composer: $composer, assets: ($assets | split(" ") | map(select(. != ""))),
        databaseSchemaDiffers: $dbDrift, schemaFilesChanged: ($dbDriftFiles | split("\n") | map(select(. != "")))},
      profile: $profile,
      secondsTaken: {resolve: $resolve, overlay: $overlay, assets: $assetsTime, pull: $pull, boot: $boot, total: $total},
      urls: {frontOffice: $fo, backOffice: $bo},
      backOfficeLogin: {email: "admin@prestashop.com", password: "prestashop"}}' > "$OUT/launch.json"
}

if $DRY_RUN; then
  write_report prepared
  log "dry run: everything is prepared in $OUT, nothing was started"
  cat "$OUT/launch.json"
  exit 0
fi

# 7. Start, and wait until both offices answer.
T=$(now)
docker compose -f "$OUT/compose.yml" pull -q
T_PULL=$(( $(now) - T ))
T=$(now)
docker compose -f "$OUT/compose.yml" up -d
UP=false
for _ in $(seq 1 300); do
  if ! docker compose -f "$OUT/compose.yml" ps --status running --services | grep -qx prestashop; then
    break
  fi
  if [ "$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/")" != 000 ]; then UP=true; break; fi
  sleep 2
done
T_BOOT=$(( $(now) - T ))
docker compose -f "$OUT/compose.yml" logs --no-color prestashop > "$OUT/prestashop.log" 2>&1 || true

# An answer is not a shop: an error page is a 200 too. Each office must answer 200 with a full
# HTML page, the back office after following its redirect to the login page. </body> rather than
# </html>: in debug mode the back office login page ends without the latter.
FO_STATUS=$(curl -s -o "$OUT/front-office.html" -w '%{http_code}' "http://localhost:$PORT/" || echo 000)
BO_STATUS=$(curl -sL -o "$OUT/back-office.html" -w '%{http_code}' "http://localhost:$PORT/admin-dev/index.php" || echo 000)
page_ok() { [ "$1" = 200 ] && [ "$(wc -c < "$2")" -gt 5000 ] && grep -qi '</body>' "$2"; }
FO_OK=false; page_ok "$FO_STATUS" "$OUT/front-office.html" && FO_OK=true
BO_OK=false; page_ok "$BO_STATUS" "$OUT/back-office.html" && BO_OK=true
if ! $UP || ! $FO_OK || ! $BO_OK; then
  docker compose -f "$OUT/compose.yml" exec -T prestashop sh -c \
    'for f in "$PS_FOLDER"/var/logs/*.log; do [ -f "$f" ] && echo "== $f" && tail -n 60 "$f"; done' \
    > "$OUT/php-errors.log" 2>&1 || true
  write_report failed
  $UP || die "the shop never answered on http://localhost:$PORT/, see $OUT/prestashop.log"
  die "front office $FO_STATUS ($(wc -c < "$OUT/front-office.html") bytes), back office $BO_STATUS ($(wc -c < "$OUT/back-office.html") bytes): see $OUT/php-errors.log and the saved pages"
fi
write_report ready
log "ready in $(( $(now) - T_START ))s: http://localhost:$PORT/ and http://localhost:$PORT/admin-dev/"
cat "$OUT/launch.json"
