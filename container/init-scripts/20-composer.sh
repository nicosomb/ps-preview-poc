#!/bin/sh
# Reinstalls the vendor when composer.lock differs from the image's (decided by launch.sh).
set -eu

[ -f /tmp/preview/composer-needed ] || { echo "composer.lock unchanged, keeping the image's vendor"; exit 0; }
echo "composer.lock changed, installing the vendor"
COMPOSER_ALLOW_SUPERUSER=1 composer install --working-dir="$PS_FOLDER" \
  --no-dev --no-interaction --no-progress --prefer-dist --optimize-autoloader
chown -R www-data:www-data "$PS_FOLDER/vendor"
