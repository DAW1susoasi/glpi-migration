FROM debian:12.5

LABEL org.opencontainers.image.url="https://github.com/DAW1susoasi/glpi.git"

ENV DEBIAN_FRONTEND noninteractive

RUN apt update \
&& apt install --yes ca-certificates apt-transport-https lsb-release wget curl \
&& curl -sSLo /usr/share/keyrings/deb.sury.org-php.gpg https://packages.sury.org/php/apt.gpg \ 
&& sh -c 'echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list' \
&& apt update \
&& apt install -y bzip2 \
&& apt install --yes --no-install-recommends \
apache2 \
php8.0 \
php8.0-mysql \
php8.0-ldap \
php8.0-xmlrpc \
php8.0-imap \
php8.0-curl \
php8.0-gd \
php8.0-mbstring \
php8.0-xml \
php-cas \
php8.0-intl \
php8.0-zip \
php8.0-bz2 \
php8.0-redis \
cron \
jq \
libldap-2.5-0 \
libldap-common \
libsasl2-2 \
libsasl2-modules \
libsasl2-modules-db \
&& rm -rf /var/lib/apt/lists/*

COPY glpi-start.sh /opt/
RUN chmod +x /opt/glpi-start.sh
ENTRYPOINT ["/opt/glpi-start.sh"]

EXPOSE 80 443
