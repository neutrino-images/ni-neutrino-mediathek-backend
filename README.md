# NI \o/ - Neutrino-Mediathek-Backend

Tuxbox-Repositories were added with

```
#!bash
for repo in mediathek-db-import mediathek-api-dev; do
	git subtree add --prefix=$repo https://github.com/tuxbox-neutrino/$repo.git master
done
```
