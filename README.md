This page describes how to set up [FreeRADIUS](https://freeradius.org/) using [`rlm_perl`](https://freeradius.org/modules/?s=perl&mod=rlm_perl) to communicate with an [OAuth2](https://oauth.net/2/) identity provider backend allowing users to connect to a wireless [802.1X](https://en.wikipedia.org/wiki/IEEE_802.1X) (WPA Enterprise) network without needing on premise systems.

Your OAuth2 provider *must* support the [Resource Owner Password Credentials Grant](https://tools.ietf.org/html/rfc6749#section-4.3); this means (for now) only [Microsoft Azure Active Directory](https://docs.microsoft.com/en-us/azure/active-directory/develop/v2-oauth-ropc) is supported. The [Password Grant](https://oauth.net/2/grant-types/password/) is necessary as it is the only grant flows that does not require user interaction with a web browser (think "log in via Google/Facebook/LinkedIn/...") which is impossible during an 802.1X authentication as the user's workstation does not have an IP address.

For 802.1X (wired and WPA Enterprise wireless) authentication, you *must* use [EAP-TTLS/PAP](https://en.wikipedia.org/wiki/Extensible_Authentication_Protocol#EAP_Tunneled_Transport_Layer_Security_(EAP-TTLS)) so that the cleartext password is securely transported to your RADIUS server and usable with the password grant flow. Fortunately client support is widespread and so Linux, Android, BB10, macOS/iOS (via a [`.mobileconfig`](https://support.apple.com/apple-configurator)) and [Microsoft Windows 8](https://adamsync.wordpress.com/2012/05/08/eap-ttls-on-windows-2012-build-8250/) or later (use a supplicant extension such as [SecureW2 Enterprise Client](https://www.securew2.com/products/enterpriseclient/) for earlier versions) users will have have no problems. Ignore the [FUD](https://en.wikipedia.org/wiki/Fear,_uncertainty,_and_doubt) around EAP-TTLS/PAP which in practice works *identically* to how web browsers transmit credentials over HTTPS ([PEAP/MSCHAPv2 is similarly vulnerable](https://github.com/tehrhart/challenger)); like HTTPS though you *must* use a [valid certificate *and* configure your clients to verify the server name](https://wiki.geant.org/display/H2eduroam/How+to+support+to+end+users#Howtosupporttoendusers-ParametersforSecureDeviceConfiguration) for it to be safe.

**N.B.** this will not work with [MFA enabled accounts](https://docs.microsoft.com/en-us/azure/active-directory/authentication/concept-mfa-howitworks) but you can workaround this with a [conditional access policy](https://github.com/jimdigriz/freeradius-oauth2-perl/issues/12)

## Features

Many of these features aim to try to *not* communicate with Azure so to hide both latency and throttling problems.

 * updates user/group information in the background and does not delay authentications
     * by default this refresh occurs every 30 seconds (using the `ttl` configuration parameter in [`module`](module))
         * do not go below 30 in production, as delays in the cloud make lower values mostly pointless
         * smallest value allowed is 10 but going below the default should only be used if you are debugging the database replication code
         * if you require 'instant' replication then [webhooks is the answer](https://github.com/jimdigriz/freeradius-oauth2-perl/issues/9)
 * [supports paging](https://docs.microsoft.com/en-us/graph/paging)
     * earlier versions of this code were limited to 999 user accounts
 * [supports delta queries](https://docs.microsoft.com/en-us/graph/delta-query-overview)
     * reduces amount of data needing to be transferred from Azure
     * means faster polling for updates can be used without triggering throttling
 * connection cache to Azure to make requests faster
 * password caching (protected with a [`{ssha512}`](https://freeradius.org/radiusd/man/rlm_pap.html) salted hash)
     * user list is still checked so the effect of disabling an account will continue to be fast
     * if a user updates their password, the cached entry is ignored
 * group membership is populated by way of the `OAuth2-Group` attribute and optionally checked by using [unlang](https://freeradius.org/radiusd/man/unlang.html)

## Support

These instructions assume you are familiar with using FreeRADIUS in an 802.1X environment and if you are not you should [start with a EAP-TTLS/PAP 802.1X deployment using static credentials](https://openschoolsolutions.org/freeradius-secure-wifi-network/) stored in a [local `users` file](https://wiki.freeradius.org/config/Users).

If you run into problems getting a `users` file environment to run, then please seek support from the [FreeRADIUS community](https://freeradius.org/support/) but do *not* ask there for help on how to use this module.

Once you are more familiar with using FreeRADIUS and have the above working, then you should try to follow these instructions. If you run into problems then do seek non-guaranteed 'best effort' help from me through a GitHub issue including the output of `freeradius -X` with both client secrets and `User-Password` obscured.

If you do open a GitHub issue you *must* be either using the [packaging from Network RADIUS (process described below)](https://networkradius.com/freeradius-packages/index.html) or have compiled from source the [`v3.0.x` branch](https://github.com/FreeRADIUS/freeradius-server/tree/v3.0.x). If you do not do this, for example instead use your distribution's (Redhat, Ubuntu, ...) packaging, your issue is likely to be closed as I am unable to provide Pro Bono consultancy for your organisation.

This project is a volunteer backed effort and the volunteer (ie. me) requests when asking for *free* assistance you use a supported environment. This is a reasonable request.

Consultancy services are available through [coreMem Limited](https://coremem.com/).

# Preflight

On the target RADIUS server, as `root` fetch a copy of the project, the recommended approach is to use [`git`](https://git-scm.com/book/en/v2/Getting-Started-Installing-Git) with:

    cd /opt
    git clone https://github.com/jimdigriz/freeradius-oauth2-perl.git
    cd freeradius-oauth2-perl

**N.B.** alternatively open the URL above in your browser, click on 'Clone or download' and use the 'Download ZIP'

You now need to install FreeRADIUS 3.0.x as your target, and it is *strongly* recommended you use the [packages distributed by Network RADIUS](https://networkradius.com/freeradius-packages/index.html).

How to use Debian is described below, but the instructions should be adaptable with ease to Ubuntu and with not too much work for CentOS. Pull requests are welcomed from those who worked out how to get this working on other OS's (eg. *BSD, another Linux, macOS, ...) and/or a later version of FreeRADIUS.

**N.B.** due to a [bug in FreeRADIUS 3.0.21](https://github.com/FreeRADIUS/freeradius-server/issues/3602), *non-English* users either need to compile FreeRADIUS from source or [workaround the problem by running FreeRADIUS with the environment variable `LC_ALL=C`](https://github.com/jimdigriz/freeradius-oauth2-perl/issues/13#issuecomment-728279207); this can be done by adding [`Environment=LC_ALL=C` to the `[Service]` section](https://www.freedesktop.org/software/systemd/man/systemd.exec.html#Environment) of `/lib/systemd/system/freeradius.service` and running `sudo systemctl daemon-reload && sudo systemctl restart freeradius`

**N.B.** currently there are no Network RADIUS provided packaging for Ubuntu 'focal' 20.04, it is recommended you use Ubuntu 'bionic' 18.04 or Debian 'buster' 10; or alternatively compile from source

### Debian/Ubuntu

Starting with a fresh empty Debian 'buster' 10.x (or Ubuntu 'bionic' 18.04) installation, as root run the following:

    apt-get update
    apt-get -y install --no-install-recommends ca-certificates curl libjson-pp-perl libwww-perl
    curl -f -o /etc/apt/trusted.gpg.d/networkradius.gpg.asc http://packages.networkradius.com/pgp/packages@networkradius.com
    ( . /etc/os-release && echo "deb [signed-by=/etc/apt/trusted.gpg.d/networkradius.gpg.asc] http://packages.networkradius.com/releases/$ID-$VERSION_CODENAME $VERSION_CODENAME main" > /etc/apt/sources.list.d/networkradius-freeradius.list )
    apt-get update
    apt-get -y install --no-install-recommends freeradius freeradius-utils

You should now have a working FreeRADIUS 3.0.x installation.

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
            cache_password = yes
        }
    }

Replacing `example.com` with your domain and `oauth2_client_{id,secret}` with the noted values from earlier and if you maintain multiple domains you should add multiple blocks here too.

**N.B.** do *not* use regular expression to capture your `realm`, you *must* create an entry for each and every (sub-)domain you intend to use

If local policy requires you to disable password caching then you can set `cache_password = no` (default: `yes`, *anything* else is treated as `no`) but it is strongly recommended this is enabled as it improves user-experience and provides protection from potential service outages if Azure decides to throttle you.

Run the following as root:

    printf '\n$INCLUDE /opt/freeradius-oauth2-perl/dictionary\n' >> /etc/freeradius/dictionary
    ln -s /opt/freeradius-oauth2-perl/module /etc/freeradius/mods-enabled/oauth2
    ln -s /opt/freeradius-oauth2-perl/policy /etc/freeradius/policy.d/oauth2

Edit your `/etc/freeradius/sites-enabled/default`:

 * in the `authorize` section add `oauth2` after `ldap` but before the commented `daily` module
     * *must* be before the call to `pap` for the password caching functionality to work
 * at the end of the `authenticate` section add the `Auth-Type oauth2` stanza with `oauth2` inside
 * in the `post-auth` section add `oauth2` after the commented out `ldap` but before the `exec` module

**N.B.** start with the stock/upstream packaged [`default`](https://github.com/FreeRADIUS/freeradius-server/blob/v3.0.x/raddb/sites-available/default) and *add* to it, do *not* strip or change anything until you have a working configuration. Once you have a working configuration then do explore customising it to fit your needs but if you break something this module will return `invalid` (ie. dependency on the [`suffix` module setting the `Realm` attribute](https://freeradius.org/modules/?s=realm&mod=rlm_realm))

This should look something like:

    authorize {
        ...
    
        -ldap
    
        oauth2
        #if (updated) {
        #
        #    # uncomment to enforce the group membership 'network-users'
        #    if (!(&OAuth2-Group && &OAuth2-Group[*] == "network-users")) {
        #        reject
        #    }
        #
        #    # uncomment to use group membership for VLAN assignment
        #    update {
        #        Tunnel-Type := VLAN
        #        Tunnel-Medium-Type := IEEE-802
        #        Tunnel-Private-Group-ID := 11
        #    }
        #    if (&OAuth2-Group) {
        #        if (&OAuth2-Group[*] == "staff") {
        #            update {
        #                Tunnel-Private-Group-ID := 13
        #            }
        #        } elsif (&OAuth2-Group[*] == "students") {
        #            update {
        #                Tunnel-Private-Group-ID := 15
        #            }
        #        } else {
        #            update {
        #                Tunnel-Private-Group-ID := 17
        #            }
        #        }
        #    }
        #
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


**N.B.** start with the stock/upstream packaged [`inner-tunnel`](https://github.com/FreeRADIUS/freeradius-server/blob/v3.0.x/raddb/sites-available/inner-tunnel) and *add* to it, do *not* strip or change anything until you have a working configuration. Once you have a working configuration then do explore customising it to fit your needs but if you break something this module will return `invalid` (ie. dependency on the [`suffix` module setting the `Realm` attribute](https://freeradius.org/modules/?s=realm&mod=rlm_realm))

# Troubleshooting

After a restart, you should be able to do an authentication against the server using `radtest`:

    radtest USERNAME@example.com PASSWORD 127.0.0.1 0 testing123

Please note that due to limitations in FreeRADIUS and around `rlm_perl`:

 * the first request against a realm/domain will be *very* slow
 * it may be so slow that the request will fail due to timing out
     * please retry as depending on how large your realm/domain it may only start to work on the second or third try
     * it takes time to download a list of all your users and their group memberships
     * after this initial synchronisation, further updates are handled in the background and will not impact future requests
 * it is *strongly* recommended as part of the process of restarting FreeRADIUS is to afterwards loop using `radtest` (or `eapol_test` described below) until authentication succeeds to preload and warmup the user and group replication:
         
         while ! radtest ...; do sleep 0.1; done

If your authentication fails, then you may see some `Reply-Message` attributes from Azure if there is a problem with the account. If there is no `Reply-Message` then your next step is to stop FreeRADIUS and run it in debugging mode:

    sudo systemctl stop freeradius
    sudo freeradius -X

Now from another terminal re-run `radtest` and in the debugging output from FreeRADIUS should be clues to the underlying problem.

Whilst FreeRADIUS is in debugging mode, you can monitor the database replication by looking for (this may be interleaved with other debug output so do use `grep 'oauth2 worker'`):

    rlm_perl: oauth2 worker (example.com): sync                   <-- process starts
    rlm_perl: oauth2 worker (example.com): sync users             <-- starting fetch of users
    rlm_perl: oauth2 worker (example.com): users page             <-- page of user results (initial sync has lots of these!)
    rlm_perl: oauth2 worker (example.com): sync groups            <-- starting fetch of group memberships
    rlm_perl: oauth2 worker (example.com): groups page            <-- page of group results (initial sync has lots of these!)
    rlm_perl: oauth2 worker (example.com): apply                  <-- process complete new data made live
    rlm_perl: oauth2 worker (example.com): syncing in 32 seconds  <-- next sync ('ttl' scheduled with 33% fuzz)

## HTTPS Requests

If you edit [`module`](./module) and set `debug = yes` for the configuration for the Perl `oauth2_perl` section, the debugging output will also include the plaintext HTTP requests and responses between the module and Azure; the output includes passwords and credential tokens used.

**N.B.** do not leave this enabled in production!

## 802.1X

**N.B.** do not try to debug an 802.1X authentication until *after* you have managed to get the much simpler `radtest` to work for you

You will require a copy of [`eapol_test`](http://deployingradius.com/scripts/eapol_test/) which to build from source on your target RADIUS server you type:

    sudo apt-get -y install --no-install-recommends build-essential git libdbus-1-dev libnl-3-dev libnl-genl-3-dev libnl-route-3-dev libssl-dev pkg-config
    git clone git://w1.fi/hostap.git
    cd hostap
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

**N.B.** do not use this configuration on your clients without adding [certificate validation options such as `ca_path` and `domain_match`](https://w1.fi/cgit/hostap/plain/wpa_supplicant/wpa_supplicant.conf)

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
