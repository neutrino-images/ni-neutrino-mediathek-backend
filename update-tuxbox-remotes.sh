#!/bin/sh

export GIT_MERGE_AUTOEDIT=no
for repo in mediathek-db-import mediathek-api-dev; do
	git subtree pull --prefix=$repo https://github.com/tuxbox-neutrino/$repo.git master || exit 1
done
