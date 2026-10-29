#!/bin/sh
# Installs the manifest's modules, in order, against the overlaid code.
# A release zip ships its vendor; a GitHub archive gets a composer install first.
set -eu

for archive in /tmp/preview/modules/*; do
  [ -f "$archive" ] || continue
  base=$(basename "$archive")
  name=${base#*-}
  name=${name%.zip}
  name=${name%.tar.gz}
  echo "installing module $name"
  rm -rf "$PS_FOLDER/modules/$name"
  case "$archive" in
    *.zip)
      unzip -qq "$archive" -d "$PS_FOLDER/modules"
      ;;
    *.tar.gz)
      mkdir -p "$PS_FOLDER/modules/$name"
      tar -xzf "$archive" -C "$PS_FOLDER/modules/$name" --strip-components=1
      if [ -f "$PS_FOLDER/modules/$name/composer.json" ] && [ ! -d "$PS_FOLDER/modules/$name/vendor" ]; then
        COMPOSER_ALLOW_SUPERUSER=1 composer install --working-dir="$PS_FOLDER/modules/$name" \
          --no-dev --no-interaction --no-progress --prefer-dist --optimize-autoloader
      fi
      ;;
  esac
  chown -R www-data:www-data "$PS_FOLDER/modules/$name"
  php -d memory_limit=-1 "$PS_FOLDER/bin/console" prestashop:module --no-interaction install "$name"
done
