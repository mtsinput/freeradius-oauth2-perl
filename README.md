This page describes how to set up [FreeRADIUS](https://freeradius.org/) using [`rlm_perl`](https://freeradius.org/modules/?s=perl&mod=rlm_perl) to communicate with an [OAuth2](https://oauth.net/2/) identity provider backend allowing users to connect to a wireless [802.1X](https://en.wikipedia.org/wiki/IEEE_802.1X) (WPA Enterprise) network without needing on premise systems.

**N.B.** your OAuth2 provider *must* support the [Resource Owner Password Credentials Grant](https://tools.ietf.org/html/rfc6749#section-4.3); this means (for now) only [Microsoft Azure Active Directory](https://docs.microsoft.com/en-us/azure/active-directory/develop/v2-oauth-ropc) is supported.

These instructions assume you are familiar with using FreeRADIUS in an 802.1X environment; if you are not you should start with a deployment utilising static credentials stored in a [local users file](https://wiki.freeradius.org/config/Users).

## Features

Many of these features aim to try to *not* communicate with Azure so to hide both latency and throttling problems.

 * updates user/group information in the background and does not delay authentications
     * due to limitations of `rlm_perl`, the first request against a realm/domain will be slow
     * by default this refresh occurs every 30 seconds
         * smallest value allowed is 10 seconds as it is useful for debugging
         * do not go below 30 in production, as the delay in the cloud makes lower values mostly pointless
         * if you want faster/'instant', then [webhooks, is the answer](https://github.com/jimdigriz/freeradius-oauth2-perl/issues/9)
 * [supports paging](https://docs.microsoft.com/en-us/graph/paging)
     * earlier versions of this code were limited to 999 user accounts
 * [supports delta queries](https://docs.microsoft.com/en-us/graph/delta-query-overview)
     * reduces amount of data needing to be transferred from Azure
     * means faster polling for updates can be used without triggering throttling
 * connection cache to Azure to make requests faster
 * password (using [`{ssha512}`](https://freeradius.org/radiusd/man/rlm_pap.html)) caching for faster re-authentications
     * user list is still checked so the effect of disabling an account will continue to be fast
     * if a user updates their password, the cached entry is ignored
 * group membership is populated via way of the `OAuth2-Group` attribute and optionally checked by using unlang

## Related Links

 * [RFC6749: The OAuth 2.0 Authorization Framework](https://tools.ietf.org/html/rfc6749)
 * [RFC7009: OAuth 2.0 Token Revocation](https://tools.ietf.org/html/rfc7009)
 * [OpenID Specifications](http://openid.net/developers/specs/)
     * [Connect Core](http://openid.net/specs/openid-connect-core-1_0.html)
     * [Connect Discovery](http://openid.net/specs/openid-connect-discovery-1_0.html)
     * [Connect Session Management](http://openid.net/specs/openid-connect-session-1_0.html)

# Preflight

On the target RADIUS server, as `root` fetch a copy of the project, the recommended approach is to use [`git`](https://git-scm.com/book/en/v2/Getting-Started-Installing-Git) with:

    cd /opt
    git clone https://github.com/jimdigriz/freeradius-oauth2-perl.git
    cd freeradius-oauth2-perl

**N.B.** you can alternatively open the URL above in your browser, click on 'Clone or download' and use the 'Download ZIP'

You now need to install FreeRADIUS 3.0.x as your target, and it is *strongly* recommended you use the [packages distributed by Network RADIUS](https://networkradius.com/freeradius-packages/index.html).

How to use Debian is described below, but the instructions should be adaptable with ease to Ubuntu and with not too much work for CentOS. Pull requests are welcomed from those who worked out how to get this working on other OS's (eg. *BSD, another Linux, macOS, ...) and/or a later version of FreeRADIUS.

### Debian

Starting with a fresh empty Debian 'buster' 10.x installation, as root run the following:

    apt-get update
    apt-get -y install --no-install-recommends ca-certificates curl libjson-pp-perl libwww-perl
    curl -f -o /etc/apt/trusted.gpg.d/networkradius.gpg.asc http://packages.networkradius.com/pgp/packages@networkradius.com
    echo 'deb [signed-by=/etc/apt/trusted.gpg.d/networkradius.gpg.asc] http://packages.networkradius.com/releases/debian-buster buster main' > /etc/apt/sources.list.d/networkradius-freeradius.list
    apt-get update
    apt-get -y install --no-install-recommends freeradius freeradius-rest freeradius-utils

You should now have a working 3.0.x FreeRADIUS installation.

**N.B.** these instructions were tested using `docker run -it --rm -v $(pwd):/opt/freeradius-oauth2-perl debian:buster-slim` and with FreeRADIUS 3.0.21

It is *strongly* recommended at this point you create a backup of the original configuration:

    cp -a /etc/freeradius /etc/freeradius.orig

This will let you to track the changes you made using:

    diff -u -N -r /etc/freeradius.orig /etc/freeradius

# Configuration

## Microsoft Azure AD (Office 365)

1. Log into your Microsoft Azure account as an administrator
1. open the 'Azure Active Directory' service
1. under 'Manage' in the left hand panel, go to 'App registrations' and select 'New registration'
1. use the following settings and then click on 'Register':
    * **Name:** `freeradius-oauth2-perl`
    * **Supported account types:** Accounts in this organizational directory only - (Single tenant)
    * **Redirect URI (optional):** [blank]
1. make a note of the 'Client ID' for later
1. for your new application, go to 'Certificates & secrets' and click on 'New client secret'
    * it is recommended for the description you use the server name of your RADIUS server
    * if you set an expiry, remember to set a reminder in your calendar!
1. make a note of the newly created 'Client secret' (you will not be able to retrieve it later!)
1. for your new application, go to 'API permissions'
    1. click on 'Add a permission'
        1. go to the 'Microsoft APIs' tab
        1. select 'Microsoft Graph'
        1. select 'Application permissions'
        1. check `Directory.Read.All`
        1. click on 'Add permissions'
    1. `User.Read` should be an already present 'Delegated' permission type
    1. click on the 'Grant admin consent' button (you will receive an email notification that you have done this)

## FreeRADIUS

After updating the following files as described below (you may need to replace `freeradius` with `raddb`), you should restart FreeRADIUS (`sudo systemctl restart freeradius`) to apply the changes.

Add the following to `/etc/freeradius/proxy.conf`:

    realm example.com {
        oauth2 {
            discovery = "https://login.microsoftonline.com/%{Realm}/v2.0"
            client_id = "..."
            client_secret = "..."
        }
    }

Replacing `example.com` with your domain and `oauth2_client_{id,secret}` with the noted values from earlier.

**N.B.** you can add multiple entries if you maintain multiple domains

Run the following as root:

    printf '\n$INCLUDE /opt/freeradius-oauth2-perl/dictionary\n' >> /etc/freeradius/dictionary
    ln -s /opt/freeradius-oauth2-perl/module /etc/freeradius/mods-enabled/oauth2
    ln -s /opt/freeradius-oauth2-perl/policy /etc/freeradius/policy.d/oauth2

Edit your `/etc/freeradius/sites-enabled/default`:

 * in the `authorize` section add `oauth2` after `ldap` but before the commented `daily` module
     * *must* be before the call to `pap` for the password caching functionality to work
 * at the end of the `authenticate` section add the `Auth-Type oauth2` stanza with `oauth2` inside
 * in the `post-auth` section add `oauth2` after the commented out `ldap` but before the `exec` module

This should look something like:

    authorize {
        ...
    
        -ldap
    
        oauth2
        # uncomment this if you want to enforce the group membership 'network-users'
        #if (updated && !(&OAuth2-Group && &OAuth2-Group[*] == "network-users")) {
        #    reject
        #}
    
        #daily
    
        ...
    }
    
    ...
    
    authenticate {
        ...
    
    #   Auth-Type eap {
    #       ...
    #   }
    
        Auth-Type oauth2 {
            oauth2
        }
    }
    
    post-auth {
        ...
    
        #ldap
    
        oauth2
    
        exec
    
        ...
    }

### 802.1X

You should edit your `/etc/freeradius/sites-enabled/inner-tunnel` file similarly to how you amended `/etc/freeradius/sites-enabled/default` above.

# Troubleshooting

After a restart, you should be able to do an authentication against the server using `radtest`:

    radtest USERNAME@example.com PASSWORD 127.0.0.1 0 testing123

The initial request will be slow as the user/group databases populate, then future requests (even on different accounts) will be fast.

If your authentication does not work, you should stop FreeRADIUS and run it in debugging mode:

    sudo systemctl stop freeradius
    sudo freeradius -X

From another terminal re-run `radtest` and the debugging output from FreeRADIUS should provide clues to the underlying problem.

## 802.1X

You will require a copy of [`eapol_test`](http://deployingradius.com/scripts/eapol_test/) which to build from source on your target RADIUS server you type:

    sudo apt-get -y install --no-install-recommends build-essential git libdbus-1-dev libnl-3-dev libnl-genl-3-dev libnl-route-3-dev libssl-dev pkg-config
    git clone git://w1.fi/hostap.git
    cd hostapd
    sed -e 's/^#CONFIG_EAPOL_TEST=y/CONFIG_EAPOL_TEST=y/' wpa_supplicant/defconfig > wpa_supplicant/.config
    make -C wpa_supplicant -j$(($(getconf _NPROCESSORS_ONLN)+1)) eapol_test

Once built, you will need a configuration file (amending `USERNAME`, `PASSWORD` and `example.com`):

    cat <<'EOF' > eapol_test.conf
    network={
        key_mgmt=IEEE8021X
        eap=TTLS
        anonymous_identity="@example.com"
        identity="USERNAME@example.com"
        password="PASSWORD"
        phase2="auth=PAP"
    }
    EOF

To test it works run:

    $ ./wpa_supplicant/eapol_test -s testing123 -c eapol_test.conf

A successful test will have again an `Access-Accept` towards the end of the output:

    Received RADIUS message
    RADIUS message: code=2 (Access-Accept) identifier=6 length=174
       Attribute 26 (Vendor-Specific) length=58
          Value: 00000137113...df32a90a69
       Attribute 26 (Vendor-Specific) length=58
          Value: 00000137103...59ae28081b
       Attribute 79 (EAP-Message) length=6
          Value: 036a0004
       Attribute 80 (Message-Authenticator) length=18
          Value: 3c4829e4901baac9bb9880acfd69feab
       Attribute 1 (User-Name) length=14
          Value: '@example.com'
    STA 02:00:00:00:00:01: Received RADIUS packet matched with a pending request, round trip time 0.02 sec

**N.B.** in the case of a failure you will *not* get a set of `Reply-Message` attributes in the `Access-Reject` as [EAP does not allow this](https://tools.ietf.org/html/rfc3579#section-2.6.5)
