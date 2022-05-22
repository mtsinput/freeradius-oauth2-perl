#!/bin/sh
set -e

config_file="/etc/raddb/clients.conf"

# We start config file creation

cat <<EOF >> $config_file
client office {
	ipaddr = $RADIUS_CLIENT_IP_ADDRESS
	secret = $RADIUS_SECRET
	limit {
		max_connections = 50
		lifetime = 0
		idle_timeout = 30
	}
}
EOF

realm_proxy_file="/etc/freeradius/proxy.conf"

cat <<EOF >> $realm_proxy_file
realm $OAUTH_REALM_DOMAIN {
    oauth2 {
	discovery = "$OAUTH_DISCOVERY_URI"
	users_uri = "$OAUTH_USERS_URI"
	groups_uri = "$OAUTH_GROUPS_URI"
	client_id = "$OAUTH_CLIENT_ID"
	client_secret = "$OAUTH_CLIENT_SECRET"
	cache_password = $RADIUS_CACHE_PASSWORD
    }
}
EOF

# this if will check if the first argument is a flag
# but only works if all arguments require a hyphenated flag
# -v; -SL; -f arg; etc will work, but not arg1 arg2
if [ "$#" -eq 0 ] || [ "${1#-}" != "$1" ]; then
    set -- freeradius "$@"
fi

# check for the expected command
if [ "$1" = 'freeradius' ]; then
    shift
    exec freeradius -f "$@"
fi

# many people are likely to call "radiusd" as well, so allow that
if [ "$1" = 'radiusd' ]; then
    shift
    exec freeradius -f "$@"
fi

# else default to run whatever the user wanted like "bash" or "sh"
exec "$@"
