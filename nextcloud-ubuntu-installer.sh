#!/bin/bash
set -e

# -------------------- DETECTAR IP DEL SERVIDOR --------------------
SERVER_IP=$(hostname -I | awk '{print $1}')  # Obtiene la primera IP del equipo

# -------------------- CONFIGURACIÓN --------------------
NEXTCLOUD_PATH="/var/www/nextcloud"


# Configuración de la base de datos MySQL para Nextcloud
MYSQL_DATABASE=""                        # Nombre de la base de datos a usar en Nextcloud
MYSQL_USER=""                            # Usuario de la base de datos con permisos sobre MYSQL_DATABASE
MYSQL_PASSWORD=""                        # Contraseña del usuario de MySQL
MYSQL_HOST=""                            # Dirección del servidor MySQL 

# Credenciales del usuario administrador de Nextcloud
NEXTCLOUD_ADMIN_USER=""                  # Nombre del usuario administrador de Nextcloud
NEXTCLOUD_ADMIN_PASSWORD=""              # Contraseña del usuario administrador

# Configuración de almacenamiento en STORJ (similar a S3)
STORJ_BUCKET="  "                        # Nombre del bucket donde se almacenarán los datos en STORJ
STORJ_KEY=""                             # Clave de acceso al bucket 
STORJ_SECRET=""                          # Clave secreta asociada a la clave de acceso 
STORJ_ENDPOINT="gateway.storjshare.io"   # URL del punto de acceso a STORJ
STORJ_PORT=443                           # Puerto de conexión (443 es el estándar para conexiones HTTPS)
STORJ_USE_SSL=true                       # Si se usa SSL para la conexión (true para activar, false para desactivar)
STORJ_REGION="us-east-1"                 # Región del bucket en STORJ (por defecto, us-east-1)
STORJ_USE_PATH_STYLE=true                # Define si se usa estilo de ruta (true) o subdominios (false)


# -------------------- INSTALACIÓN --------------------
echo "Instalando dependencias..."
sudo apt-get update 
sudo apt-get install -y apache2 mariadb-server redis-server php-redis \
                        libapache2-mod-php php php-mysql php-curl php-gd php-json \
                        php-xml php-mbstring php-zip php-bz2 php-intl php-gmp \
                        php-imagick php-fpm wget unzip

echo "Dependencias instaladas."

# -------------------- CONFIGURAR REDIS --------------------
echo "Configurando Redis..."
sudo sed -i "s/^# unixsocket /unixsocket /" /etc/redis/redis.conf
sudo sed -i "s/^# unixsocketperm 700/unixsocketperm 770/" /etc/redis/redis.conf
sudo systemctl enable --now redis-server


sudo usermod -aG redis www-data
echo "Redis configurado."


sudo systemctl restart redis-server
sudo systemctl restart apache2

# -------------------- CONFIGURAR BASE DE DATOS --------------------
echo "Configurando base de datos para Nextcloud..."
sudo mysql -e "CREATE DATABASE IF NOT EXISTS ${MYSQL_DATABASE};"
sudo mysql -e "CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'localhost' IDENTIFIED BY '${MYSQL_PASSWORD}';"
sudo mysql -e "GRANT ALL PRIVILEGES ON ${MYSQL_DATABASE}.* TO '${MYSQL_USER}'@'localhost';"
sudo mysql -e "FLUSH PRIVILEGES;"
echo "Base de datos configurada."

# -------------------- DESCARGA E INSTALACIÓN DE NEXTCLOUD --------------------
if [ ! -d "$NEXTCLOUD_PATH" ]; then
    echo "⬇️ Descargando Nextcloud..."
    cd /tmp
    rm -f latest.zip
    wget https://download.nextcloud.com/server/releases/latest.zip
    unzip latest.zip
    sudo mv nextcloud /var/www/
    echo "Nextcloud descargado en $NEXTCLOUD_PATH."
else
    echo "Nextcloud ya está descargado en $NEXTCLOUD_PATH. Omitiendo descarga."
fi


sudo chown -R www-data:www-data $NEXTCLOUD_PATH
sudo chmod -R 755 $NEXTCLOUD_PATH

# -------------------- CONFIGURAR APACHE --------------------

echo "Configurando Apache para la IP $SERVER_IP..."
cat <<EOF | sudo tee /etc/apache2/sites-available/nextcloud.conf
<VirtualHost *:80>
    ServerName $SERVER_IP
    DocumentRoot /var/www/nextcloud

    <Directory /var/www/nextcloud/>
        Require all granted
        AllowOverride All
        Options FollowSymLinks MultiViews
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/nextcloud_error.log
    CustomLog \${APACHE_LOG_DIR}/nextcloud_access.log combined
</VirtualHost>
EOF


sudo a2ensite nextcloud.conf
sudo a2enmod rewrite headers env dir mime
sudo systemctl reload apache2
sudo systemctl restart apache2

echo "Apache configurado y reiniciado."

# -------------------- INSTALAR NEXTCLOUD --------------------
echo "Esperando 10 segundos para que la base de datos esté lista..."
sleep 10

if [ ! -f "$NEXTCLOUD_PATH/config/config.php" ]; then
    echo "Instalando Nextcloud automáticamente..."
    sudo -u www-data php $NEXTCLOUD_PATH/occ maintenance:install \
      --database "mysql" \
      --database-name "$MYSQL_DATABASE" \
      --database-user "$MYSQL_USER" \
      --database-pass "$MYSQL_PASSWORD" \
      --database-host "$MYSQL_HOST" \
      --admin-user "$NEXTCLOUD_ADMIN_USER" \
      --admin-pass "$NEXTCLOUD_ADMIN_PASSWORD"
    
    echo "Nextcloud instalado correctamente."
else
    echo "Nextcloud ya está instalado."
fi

# -------------------- CONFIGURAR REDIS EN NEXTCLOUD --------------------
echo "Configurando Redis en Nextcloud..."
sudo -u www-data php $NEXTCLOUD_PATH/occ config:system:set redis host --value='/var/run/redis/redis-server.sock'
sudo -u www-data php $NEXTCLOUD_PATH/occ config:system:set redis port --value=0
sudo -u www-data php $NEXTCLOUD_PATH/occ config:system:set memcache.local --value='\OC\Memcache\Redis'
sudo -u www-data php $NEXTCLOUD_PATH/occ config:system:set memcache.locking --value='\OC\Memcache\Redis'
echo "Redis configurado en Nextcloud."

# -------------------- CONFIGURAR STORJ EN NEXTCLOUD --------------------
echo "Configurando almacenamiento en Storj en config.php..."

sudo sed -i "/);/i\
  'objectstore' => [\
    'class' => 'OC\\\\Files\\\\ObjectStore\\\\S3',\
    'arguments' => [\
        'bucket' => '$STORJ_BUCKET',\
        'autocreate' => false,\
        'key' => '$STORJ_KEY',\
        'secret' => '$STORJ_SECRET',\
        'hostname' => '$STORJ_ENDPOINT',\
        'port' => $STORJ_PORT,\
        'use_ssl' => $STORJ_USE_SSL,\
        'region' => '$STORJ_REGION',\
        'use_path_style' => $STORJ_USE_PATH_STYLE\
    ],\
  ]," $NEXTCLOUD_PATH/config/config.php

echo "Almacenamiento en Storj configurado correctamente."


# -------------------- AÑADIR LA IP A TRUSTED_DOMAINS --------------------

CONFIG_FILE="$NEXTCLOUD_PATH/config/config.php"

echo "Añadiendo la IP $SERVER_IP a los dominios de confianza de Nextcloud..."


if ! grep -q "'$SERVER_IP'" "$CONFIG_FILE"; then

    sudo sed -i "/'trusted_domains' =>/!b;n;/array (/!b;a\    $(grep -c "'trusted_domains'" "$CONFIG_FILE") => '$SERVER_IP'," "$CONFIG_FILE"

    echo "IP $SERVER_IP añadida correctamente a trusted_domains en $CONFIG_FILE."
else
    echo "La IP $SERVER_IP ya está en trusted_domains. No se realizaron cambios."
fi

# -------------------- CONFIGURAR LÍMITES DE SUBIDA --------------------

echo "Configurando límites de tamaño de subida..."


sudo sed -i "s/^upload_max_filesize.*/upload_max_filesize = 16G/" /etc/php/8.1/apache2/php.ini
sudo sed -i "s/^post_max_size.*/post_max_size = 16G/" /etc/php/8.1/apache2/php.ini
sudo sed -i "s/^memory_limit.*/memory_limit = 512M/" /etc/php/8.1/apache2/php.ini
sudo sed -i "s/^max_execution_time.*/max_execution_time = 3600/" /etc/php/8.1/apache2/php.ini
sudo sed -i "s/^max_input_time.*/max_input_time = 3600/" /etc/php/8.1/apache2/php.ini


sudo sed -i "/php_value upload_max_filesize/c\php_value upload_max_filesize 16G" $NEXTCLOUD_PATH/.htaccess
sudo sed -i "/php_value post_max_size/c\php_value post_max_size 16G" $NEXTCLOUD_PATH/.htaccess
sudo sed -i "/php_value memory_limit/c\php_value memory_limit 512M" $NEXTCLOUD_PATH/.htaccess
sudo sed -i "/php_value max_execution_time/c\php_value max_execution_time 3600" $NEXTCLOUD_PATH/.htaccess
sudo sed -i "/php_value max_input_time/c\php_value max_input_time 3600" $NEXTCLOUD_PATH/.htaccess


sudo -u www-data php $NEXTCLOUD_PATH/occ maintenance:update:htaccess


sudo -u www-data php $NEXTCLOUD_PATH/occ config:system:set max_filesize --value="16G"


sudo systemctl restart apache2

echo "Límites de subida configurados correctamente."
# -------------------- AJUSTAR PERMISOS --------------------
echo "Ajustando permisos en $NEXTCLOUD_PATH..."
sudo chown -R www-data:www-data "$NEXTCLOUD_PATH"
sudo chmod -R 755 "$NEXTCLOUD_PATH"
echo "Permisos corregidos."

# -------------------- FINALIZACIÓN --------------------
echo "Instalación y configuración completadas."
echo "Accede a Nextcloud en: http://$SERVER_IP"
