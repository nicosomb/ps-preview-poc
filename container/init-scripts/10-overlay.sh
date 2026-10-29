#!/bin/sh
# Copies the code under test over the code the image was built from.
# Files deleted since the image's version are left in place (v0 limit, see README.md).
set -eu

[ -d /tmp/overlay ] || { echo "no overlay mounted, running the image's own code"; exit 0; }
echo "overlaying the code under test"
(cd /tmp/overlay && tar -cf - .) | (cd "$PS_FOLDER" && tar -xf -)
rm -rf "$PS_FOLDER"/var/cache/*
chown -R www-data:www-data "$PS_FOLDER"
