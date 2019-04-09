#!/bin/bash
apt-get update -y -qq > /dev/null
apt-get install nginx curl zsh htop wget vim git python-certbot-nginx php php-fpm php-mysql php-mbstring php-json -y -qq > /dev/null
curl -sSO https://repo.percona.com/apt/percona-release_latest.$(lsb_release -sc)_all.deb > /dev/null
dpkg --install percona-release_latest.$(lsb_release -sc)_all.deb > /dev/null
percona-release setup ps80 > /dev/null
export DEBIAN_FRONTEND=noninteractive
echo "percona-server-server percona-server-server/root_password password" | sudo debconf-set-selections
echo "percona-server-server percona-server-server/root_password_again password" | sudo debconf-set-selections
apt-get install percona-server-server -y -qq > /dev/null
update-rc.d mysql enable
update-rc.d nginx enable
update-rc.d php7.2-fpm enable
service apache2 stop
update-rc.d apache2 disable

curl -sSO https://repo.zabbix.com/zabbix/4.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_4.0-2+$(lsb_release -sc)_all.deb > /dev/null
dpkg --install zabbix-release_4.0-2+$(lsb_release -sc)_all.deb > /dev/null
apt-get update -y -qq > /dev/null
apt-get install -y -qq zabbix-server-mysql zabbix-frontend-php zabbix-agent > /dev/null

mv /etc/mysql/my.cnf /etc/mysql/my.cnf-old

cat > /etc/mysql/my.cnf <<EOF
[mysqld]
default-authentication-plugin = mysql_native_password
pid-file        = /var/run/mysqld/mysqld.pid
socket          = /var/run/mysqld/mysqld.sock
datadir         = /var/lib/mysql
log-error       = /var/log/mysql/error.log
innodb_file_per_table=1
innodb_buffer_pool_size = 768M # attention to the parameter! set about 2 times less than the amount of server RAM
innodb_buffer_pool_instances=1 # increase by 1 each GB innodb_buffer_pool_size
innodb_flush_log_at_trx_commit = 0
innodb_log_file_size = 512M
innodb_log_files_in_group = 3
EOF

mkdir /root/details
echo "S`openssl rand -base64 12`0a" > /root/details/zabbix-pass
mysql -e "CREATE USER 'zabbix_magehost'@'localhost' IDENTIFIED WITH mysql_native_password BY '`cat /root/details/zabbix-pass`'";
mysql -e "CREATE DATABASE zabbixdb_magehost";
mysql -e "GRANT ALL PRIVILEGES ON zabbixdb_magehost.* TO 'zabbix_magehost'@'localhost'";
mysql -e "CREATE FUNCTION fnv1a_64 RETURNS INTEGER SONAME 'libfnv1a_udf.so'";
mysql -e "CREATE FUNCTION fnv_64 RETURNS INTEGER SONAME 'libfnv_udf.so'";
mysql -e "CREATE FUNCTION murmur_hash RETURNS INTEGER SONAME 'libmurmur_udf.so'";
mysql -e "FLUSH PRIVILEGES";

service mysql restart


 zcat /usr/share/doc/zabbix-server-mysql*/create.sql.gz | mysql -uzabbix_magehost -p`cat /root/details/zabbix-pass` zabbixdb_magehost



sed -i.backup 's,DBName=zabbix,DBName=zabbixdb_magehost,g' /etc/zabbix/zabbix_server.conf
sed -i 's,DBUser=zabbix,DBUser=zabbix_magehost,g' /etc/zabbix/zabbix_server.conf
echo "DBPassword=`cat /root/details/zabbix-pass`" >> /etc/zabbix/zabbix_server.conf



export Zabbix_domain=noc.magehost.cloud

rm -rvf /etc/nginx/conf.d/default*

cat > /etc/nginx/conf.d/zabbix.conf <<EOF
server {
    listen       80;
    #listen 443 ssl http2;
    server_name  $Zabbix_domain;
    #ssl_certificate /etc/letsencrypt/live/$Zabbix_domain/fullchain.pem;
    #ssl_certificate_key /etc/letsencrypt/live/$Zabbix_domain/privkey.pem;
    root /usr/share/zabbix;
   # if ( \$scheme = http) {
    #return 301 https://\$server_name\$request_uri;
    # }
    location / {
    index index.php index.html index.htm;
    }

    location ~ \.php$ {
    fastcgi_pass 127.0.0.1:9000;
    fastcgi_index index.php;
    fastcgi_param SCRIPT_FILENAME  \$document_root\$fastcgi_script_name;
    include fastcgi_params;
    fastcgi_param PHP_VALUE "
    max_execution_time = 300
    memory_limit = 128M
    post_max_size = 16M
    upload_max_filesize = 2M
    max_input_time = 300
    date.timezone = Asia/Kolkata
    always_populate_raw_post_data = -1
        ";
    fastcgi_buffers 8 256k;
    fastcgi_buffer_size 128k;
    fastcgi_intercept_errors on;
    fastcgi_busy_buffers_size 256k;
    fastcgi_temp_file_write_size 256k;
        }
    }
EOF

service nginx restart
mkdir -p /var/log/php-fpm/

rm -rvf /etc/php/7.2/fpm/pool.d/www.conf
cat > /etc/php/7.2/fpm/pool.d/www.conf <<EOF
[magehostzabbix]
listen = 127.0.0.1:9000
listen.owner = www-data
listen.group = www-data
listen.mode = 0666
user = www-data
group = www-data
request_slowlog_timeout = 5s
slowlog = /var/log/php-fpm/slow-magehostzabbix.log
listen.allowed_clients = 127.0.0.1
pm = ondemand
pm.process_idle_timeout = 10s
pm.max_children = 20
pm.start_servers = 5
pm.min_spare_servers = 2
pm.max_spare_servers = 4
pm.max_requests = 500
pm.status_path = /status_magehostzabbix
request_terminate_timeout = 3600s
rlimit_files = 131072
rlimit_core = unlimited
catch_workers_output = yes

php_value[error_log] = /var/log/php.log

env[HOSTNAME] = \$HOSTNAME
env[TMP] = /tmp
env[TMPDIR] = /tmp
env[TEMP] = /tmp
EOF

service php7.2-fpm restart
chown -R www-data: /usr/share/zabbix
