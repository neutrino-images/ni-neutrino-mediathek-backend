# Neutrino Mediathek API -> lokale lighttpd-Instanz (127.0.0.1:@API_PORT@)
# In den HTTPS-VirtualHost einbinden:
#   Include /etc/apache2/mediathek-api.inc
# Freigegeben wird genau das, was das Plugin benutzt
# (Basis-URL im Plugin: https://<domain>/mt-api):
#   GET  /mt-api/api/info, /mt-api/api/listChannels, /mt-api/api/listLivestream
#   POST /mt-api/api.html (Suchanfragen)
# Das Plugin schickt nie URL-Parameter. Alles andere wird abgewiesen, darunter
# die HTML-Start- und Fehlerseiten der API.
# Dazu die WebTV-Liste für Neutrino als statische Datei:
#   GET  /mt-api/livestreams.xml
ProxyPassMatch "^/mt-api/(api/(info|listChannels|listLivestream)|api\.html)$" "http://127.0.0.1:@API_PORT@/mt-api/$1" timeout=60 retry=5
# Zusätzlich ins Log der Subdomain, damit die Statistik beide Adressen zählt
CustomLog ${APACHE_LOG_DIR}/mediathek-api-access.log combined "expr=%{REQUEST_URI} =~ m#^/mt-api/#"
Alias "/mt-api/livestreams.xml" "@WEBTV_DIR@/livestreams.xml"
<Directory "@WEBTV_DIR@">
	Options None
	AllowOverride None
	Require all granted
</Directory>

<LocationMatch "^/mt-api/">
	<If "%{QUERY_STRING} != '' || (%{REQUEST_URI} == '/mt-api/api.html' && %{REQUEST_METHOD} != 'POST') || (%{REQUEST_URI} =~ m#^/mt-api/api/# && ! %{REQUEST_METHOD} -in {'GET','HEAD'})">
		Require all denied
	</If>
	<IfModule headers_module>
		# Antworten sind JSON: nie als HTML deuten, keine Scripte, nicht einbetten
		Header always set X-Content-Type-Options "nosniff"
		Header always set Content-Security-Policy "default-src 'none'; frame-ancestors 'none'"
		Header always set Referrer-Policy "no-referrer"
	</IfModule>
</LocationMatch>
