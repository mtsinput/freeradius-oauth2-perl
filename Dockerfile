FROM freeradius/freeradius-server:3.2.0

RUN mkdir -p /opt/freeradius-oauth2-perl
COPY policy /opt/freeradius-oauth2-perl/
COPY module /opt/freeradius-oauth2-perl/
COPY dictionary /opt/freeradius-oauth2-perl/
COPY main.pm /opt/freeradius-oauth2-perl/
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod 755 /docker-entrypoint.sh

RUN printf '\n$INCLUDE /opt/freeradius-oauth2-perl/dictionary\n' >> /etc/freeradius/dictionary && \
    ln -s /opt/freeradius-oauth2-perl/module /etc/freeradius/mods-enabled/oauth2 && \
    ln -s /opt/freeradius-oauth2-perl/policy /etc/freeradius/policy.d/oauth2

RUN sed -i 's/-ldap/-ldap\n        oauth2/g' /etc/freeradius/sites-enabled/default && \
    sed -zE -i 's/(authenticate \{.*)(eap.*)(\}.*)(preacct \{)/\1\2\n  Auth-Type oauth2 \{\n    oauth2\n  \}\n\3\4/g' /etc/freeradius/sites-enabled/default && \
    sed -zE -i 's/(post-auth \{.*)exec/\1\n    oauth2\n    exec/g' /etc/freeradius/sites-enabled/default && \
    sed -i 's/-ldap/-ldap\n        oauth2/g' /etc/freeradius/sites-enabled/inner-tunnel && \
    sed -zE -i 's/(authenticate \{.*)(eap.*)(\}.*)(preacct \{)/\1\2\n  Auth-Type oauth2 \{\n    oauth2\n  \}\n\3\4/g' /etc/freeradius/sites-enabled/inner-tunnel && \
    sed -zE -i 's/(post-auth \{.*)(\tldap)/\1\2\n    oauth2\n/g' /etc/freeradius/sites-enabled/inner-tunnel

RUN apt-get update && apt-get install -y tzdata bash jq ca-certificates curl libjson-pp-perl libwww-perl

ENV TZ=Europe/Kiev

EXPOSE 1812/udp 1813/udp

ENTRYPOINT ["/docker-entrypoint.sh"]

CMD ["freeradius"]
