# NI \o/ - Neutrino-Mediathek-Backend

Tuxbox-Repositories were added with

```
#!bash
for repo in mediathek-db-import mediathek-api-dev; do
	git subtree add --prefix=$repo https://github.com/tuxbox-neutrino/$repo.git master
done
```

## Installation on a server (without Docker)

`install-mediathek-backend.sh` builds the importer (`mv2mariadb`) and the API
(`mt-api`) from this repository and installs them on Debian 12/13 or
Ubuntu 22.04/24.04:

- importer in `/opt/mediathek/importer`, run hourly by a systemd timer
- API in `/opt/mediathek/api`, served by a local lighttpd on `127.0.0.1:18080`
- MariaDB with two users: the importer may write `mediathek_*`, the API may only
  read `mediathek_1`
- `/etc/apache2/mediathek-api.inc` for the existing Apache (HTTPS) virtual host;
  only the requests the plugin needs are passed through

Run the script as root from a checkout of this repository. Without `REF` it
builds exactly the commit that is checked out, so script and code always match.
The commit must already be pushed: the script builds from GitHub, not from your
working tree.

```
git checkout NI-2026.11
sudo ./install-mediathek-backend.sh
```

Then, once:

1. Add `Include /etc/apache2/mediathek-api.inc` inside the `<VirtualHost *:443>`
   of the site.
2. `apache2ctl configtest && systemctl reload apache2`
3. Check: `curl https://neutrino-images.de/mt-api/api/info`
4. Base URL in the plugin: `https://neutrino-images.de/mt-api`

The first full import runs in the background:
`journalctl -fu mediathek-importer-full`

### Updates

```
sudo ./install-mediathek-backend.sh --check      # what is new compared to the installed version
git checkout NI-2026.12
sudo ./install-mediathek-backend.sh              # backs up the running version first
sudo ./install-mediathek-backend.sh --rollback   # back to the previous version (again = forward)
```

`REF=<tag|commit>` builds a specific state regardless of the checkout, e.g.
`sudo REF=NI-2026.11 ./install-mediathek-backend.sh`. Started from anywhere
else (not from a checkout), the script builds the latest state of `master`.

Before running a new version of the script as root, have a look at what changed:
`git log -p -- install-mediathek-backend.sh`

`./install-mediathek-backend.sh --help` lists all options (ports, rate limits,
external database, ...).

## Versioning

Versions are `NI-YYYY.MM` tags, set by the pre-push hook in `.git-hooks`
(`git config core.hooksPath .git-hooks`). The installed programs report this
version, e.g. `v2026.11` in `/api/info`, or `2026.11-2-g<commit>` for commits
after a tag.
