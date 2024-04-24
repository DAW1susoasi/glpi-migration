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