#!/bin/sh
set -e

config_file="/etc/raddb/clients.conf"

# We start config file creation

IFS=","
addr_idx=0
secr_idx=0
for ADDR in $RADIUS_CLIENT_IP_ADDRESS; do
    for SECRET in $RADIUS_SECRET; do
	if [ "$addr_idx" -eq "$secr_idx" ]; then
  		cat <<EOF >> $config_file
client office$addr_idx {
        ipaddr = $ADDR
        secret = $SECRET
        limit {
                max_connections = 50
                lifetime = 0
                idle_timeout = 30
        }
}
EOF
	fi
	secr_idx=$(($secr_idx+1))
    done
    addr_idx=$(($addr_idx+1))
    secr_idx=0
done

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

if [ ! -z "$RADIUS_LOG_DESTINATION" ]; then
    sed -i 's/destination = files/destination = '"$RADIUS_LOG_DESTINATION"'/g' /etc/freeradius/radiusd.conf
fi

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
