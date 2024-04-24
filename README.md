# glpi-migration
***
Partiendo de un equipo con glpi 9.5.3 y mysql 5.7.23 basados en alguna de las versiones de [diouxx/glpi](https://hub.docker.com/r/diouxx/glpi), vamos a migrar todo, incluida la configuración de glpidb a otro equipo.  
Los pasos a realizar serían los siguientes:  
1. Backup de las bases de datos del contenedor mysql  
    ```
    docker exec mysql sh -c 'mysqldump -u root -pdiouxx --all-databases | gzip > /tmp/backup.sql.gz'
    mkdir -p dump && docker cp mysql:/tmp/backup.sql.gz ./dump/
    docker exec mysql rm /tmp/backup.sql.gz
    ```
    Lo hemos puesto en la carpeta dump para después mediante un volumen hacer referencia a la carpeta /docker-entrypoint-initdb.d del contenedor mysql, o sea, la base de datos se inicializará con el backup; despendiendo del tamaño del archivo, la base de datos puede tardar bastante en estar lista la primera vez que arranquemos el contenedor mysql.  
2.  Vamos a crear el contenedor glpi no a partir de una imagen, sino a partir de un Dockerfile, el cual tendrá como ENTRYPOINT el script glpi-start.sh, y levantaremos todo mediante un docker-compose.yml  
    - Dockerfile que instalará el servidor web Apache + php 8.0 a partir de la imagen de Debian 12.5   
        ```
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
        ```
    - Script glpi-start.sh, que descargará glpi 9.5.3, fusioninventory 9.5.0+1.0 y configurará glpidb; este último paso sólo podrá hacerse una vez la base de datos esté lista (como comenté anteriormente la primera vez puede tardar bastante en cargar el ENTRYPOINT), por lo que nos las ingeniaremos mediante un healthcheck - service_healthy en el docker-compose.yml  
        ```
        #!/bin/bash

        #Si no le pasamos versión de glpi debe de obtener cuál es la última
        [[ ! "$VERSION_GLPI" ]] \
            && VERSION_GLPI=$(curl -s https://api.github.com/repos/glpi-project/glpi/releases/latest | grep tag_name | cut -d '"' -f 4)

        # Controlar si la variable de entorno GLPI_VERSION está definida
        if [[ -z "$VERSION_GLPI" ]]; then
            echo "Error: no se ha podido recuperar la versión de GLPI."
            exit 1
        fi

        if [[ -z "${TIMEZONE}" ]]; then
            echo "TIMEZONE is unset"; 
        else 
            echo "date.timezone = \"$TIMEZONE\"" > /etc/php/8.0/apache2/conf.d/timezone.ini;
            echo "date.timezone = \"$TIMEZONE\"" > /etc/php/8.0/cli/conf.d/timezone.ini;
        fi

        #Habilitar session.cookie_httponly
        sed -i 's,session.cookie_httponly = *\(on\|off\|true\|false\|0\|1\)\?,session.cookie_httponly = on,gi' /etc/php/8.0/apache2/php.ini

        FOLDER_GLPI=glpi/
        FOLDER_WEB=/var/www/html/

        #check if TLS_REQCERT
        if !(grep -q "TLS_REQCERT" /etc/ldap/ldap.conf)
        then
            echo "TLS_REQCERT isn't present"
            echo -e "TLS_REQCERT\tnever" >> /etc/ldap/ldap.conf
        fi

        #Descarga y extracción de GLPI
        if [ "$(ls ${FOLDER_WEB}${FOLDER_GLPI}bin)" ]; then
            echo "GLPI is already installed"
        else
            SRC_GLPI=$(curl -s https://api.github.com/repos/glpi-project/glpi/releases/tags/${VERSION_GLPI} | jq .assets[0].browser_download_url | tr -d \")

            if [[ -z "$SRC_GLPI" ]]; then
                echo "Error: no se ha podido recuperar el código fuente de GLPI para la versión ${VERSION_GLPI}."
                exit 1
            fi
            TAR_GLPI=$(basename ${SRC_GLPI})
            wget -P ${FOLDER_WEB} ${SRC_GLPI}
            tar -xzf ${FOLDER_WEB}${TAR_GLPI} -C ${FOLDER_WEB}
            rm -Rf ${FOLDER_WEB}${TAR_GLPI}
            chown -R www-data:www-data ${FOLDER_WEB}${FOLDER_GLPI}
        fi

        echo -e "<VirtualHost *:80>\n\tDocumentRoot /var/www/html/glpi\n\n\t<Directory /var/www/html/glpi>\n\t\tAllowOverride All\n\t\tOrder Allow,Deny\n\t\tAllow from all\n\t</Directory>\n\n\tErrorLog /var/log/apache2/error-glpi.log\n\tLogLevel warn\n\tCustomLog /var/log/apache2/access-glpi.log combined\n</VirtualHost>" > /etc/apache2/sites-available/000-default.conf

        #Descarga y extracción de fusioninventory 9.5.0+1.0
        if [ ! -d "/var/www/html/glpi/plugins/fusioninventory" ]; then
            echo "*********************"
            echo "* Instalando fusion *"
            echo "*********************"
            wget -O /tmp/fusioninventory.tar.bz2 https://github.com/fusioninventory/fusioninventory-for-glpi/releases/download/glpi9.5.0%2B1.0/fusioninventory-9.5.0+1.0.tar.bz2
            tar -xjf /tmp/fusioninventory.tar.bz2 -C /var/www/html/glpi/plugins
            rm /tmp/fusioninventory.tar.bz2
        fi

        #Programar la ejecución de cron.php cada 2 minutos
        echo "*/2 * * * * www-data /usr/bin/php /var/www/html/glpi/front/cron.php &>/dev/null" > /etc/cron.d/glpi
        #Start cron service
        service cron start

        #Activación del módulo rewrite de Apache
        a2enmod rewrite && service apache2 restart && service apache2 stop
        pkill -9 apache

        #sleep 15m;

        #Configuración de glpidb
        echo "***********************"
        echo "* Configurando glpidb *"
        echo "***********************"
        php /var/www/html/glpi/bin/console glpi:database:configure -H mysql -d glpidb -u glpi_user -p glpi -n --reconfigure
        chown www-data:www-data -R ${FOLDER_WEB}${FOLDER_GLPI}

        #Arrancar Apache en primer plano
        echo "********************************"
        echo "* glpidb OK, arrancando apache *"
        echo "********************************"
        /usr/sbin/apache2ctl -D FOREGROUND

        exit 0
        ```
    - docker-compose.yml
        ```
        version: "3.8"

        services:
          mysql:
            image: mysql:5.7.23
            container_name: mysql
            hostname: mysqldb
            volumes:
              - ./dump:/docker-entrypoint-initdb.d
              - /glpi/mysql:/var/lib/mysql
            environment:
              - MYSQL_ROOT_PASSWORD=diouxx
              - MYSQL_DATABASE=glpidb
              - MYSQL_USER=glpi_user
              - MYSQL_PASSWORD=glpi
            healthcheck:
              test: ["CMD", "mysqladmin", "-h", "127.0.0.1", "-u", "loquesea", "-ploquesea", "ping"]
              interval: 2m
              retries: 10
            restart: unless-stopped

          glpi:
            # La imagen se contruirá con el Dockerfile cuyo ENTRYPOINT es un script
            build: .
            container_name: glpi
            hostname: glpi
            ports:
              - 8080:80
            volumes:
              - /etc/timezone:/etc/timezone:ro
              - /etc/localtime:/etc/localtime:ro
              - /glpi/apache:/var/www/html/glpi
              - ./glpi-start.sh:/opt/glpi-start.sh
            environment:
              # Si no le pasamos versión te instala la última, a 15/4/2024 la 10.0.14
              - VERSION_GLPI=9.5.3
              - TIMEZONE=Europe/Madrid
            depends_on:
              mysql:
                condition: service_healthy
            restart: unless-stopped
        ```
        Una vez se ha migrado todo, si paramos los contenedores y los volvemos a poner en marcha veremos que tarda mucho, ya que tiene que volver a crear la imagen glpi-glpi  
        ¿Para que volver a crearla si lo que deberíamos hacer es usarla?  
        Es por ello que una vez hemos comprobado que todo está funcionando, lo que deberíamos hacer es emplear el siguiente docker-compose.yml  
        ```
        version: "3.8"

        services:
          mysql:
            image: mysql:5.7.23
            container_name: mysql
            hostname: mysqldb
            volumes:
              - ./dump:/docker-entrypoint-initdb.d
              - /glpi/mysql:/var/lib/mysql
            environment:
              - MYSQL_ROOT_PASSWORD=diouxx
              - MYSQL_DATABASE=glpidb
              - MYSQL_USER=glpi_user
              - MYSQL_PASSWORD=glpi
            restart: unless-stopped

          glpi:
            image: glpi-glpi:latest
            container_name: glpi
            hostname: glpi
            ports:
              - 8080:80
            volumes:
              - /etc/timezone:/etc/timezone:ro
              - /etc/localtime:/etc/localtime:ro
              - /glpi/apache:/var/www/html/glpi
              - ./glpi-start.sh:/opt/glpi-start.sh
            environment:
              - VERSION_GLPI=9.5.3
              - TIMEZONE=Europe/Madrid
            depends_on:
              - mysql
            restart: unless-stopped
        ```
Para el que no se sienta cómodo con el healthcheck - service_healthy, puede introducir una pausa de entre 15-30 minutos (dependiendo del volumen del backup de la base de datos) ```sleep 15m;``` antes de la configuración de glpid en el archivo glpi-start.sh, para después quitarla tras la importación.