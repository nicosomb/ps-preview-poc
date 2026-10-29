#!/bin/sh
# Debug mode, then a cache rebuilt by the web server's user. The overlay replaced
# config/defines.inc.php, so the image's own DEBUG_MODE edit is lost and done here instead.
set -eu

if [ "$(cat /tmp/preview/debug 2>/dev/null)" = "true" ]; then
  sed -i "s~define('_PS_MODE_DEV_', false);~define('_PS_MODE_DEV_', true);~" "$PS_FOLDER/config/defines.inc.php"
  echo "debug mode on"
fi
rm -rf "$PS_FOLDER"/var/cache/*
chown -R www-data:www-data "$PS_FOLDER/var"
