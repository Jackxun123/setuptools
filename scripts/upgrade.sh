#!/usr/bin/env bash
#

BASE_DIR=$(dirname "$0")
PROJECT_DIR=$(dirname $(cd $(dirname "$0");pwd))
source ${PROJECT_DIR}/config.conf

Upgrade_Version=$(curl -s -L http://demo.jumpserver.org/download/latest)

if [ $Version == $Upgrade_Version ]; then
    echo -e "\033[31m $Version 已是最新版本 \033[0m"
    exit 0
fi

echo -e "\033[31m 准备从 $Version 升级到 $Upgrade_Version ... \033[0m"
jumpserver_backup=${PROJECT_DIR}/backup/$Version
if [ ! -d "$jumpserver_backup" ]; then
    mkdir -p $jumpserver_backup
fi

if [ ! -d "$install_dir/jumpserver" ]; then
    if [ ! -d "$jumpserver_backup/jumpserver" ]; then
        echo -e "\033[31m jumpserver 未安装或者目录不正确 \033[0m"
        exit 1
    fi
fi

if [ ! -d "$PROJECT_DIR/$Upgrade_Version" ]; then
    mkdir -p $PROJECT_DIR/$Upgrade_Version
fi

if [ ! -f "$PROJECT_DIR/$Upgrade_Version/jumpserver-v$Upgrade_Version.tar.gz" ]; then
    wget -qO $PROJECT_DIR/$Upgrade_Version/jumpserver-v$Upgrade_Version.tar.gz http://demo.jumpserver.org/download/jumpserver/$Upgrade_Version/jumpserver-v$Upgrade_Version.tar.gz || {
        rm -rf $PROJECT_DIR/$Upgrade_Version/jumpserver-v$Upgrade_Version.tar.gz
        echo -e "\033[31m 下载 jumpserver 失败, 请检查网络是否正常或尝试重新执行升级脚本 \033[0m"
        exit 1
    }
fi

rm -rf $install_dir/lina*
if [ ! -f "$PROJECT_DIR/$Upgrade_Version/lina-v$Upgrade_Version.tar.gz" ]; then
  wget -qO $PROJECT_DIR/$Upgrade_Version/lina-v$Upgrade_Version.tar.gz http://demo.jumpserver.org/download/lina/$Upgrade_Version/lina-v$Upgrade_Version.tar.gz|| {
      rm -rf $PROJECT_DIR/$Upgrade_Version/lina-v$Upgrade_Version.tar.gz
      echo -e "\033[31m 下载 lina 失败, 请检查网络是否正常或尝试重新执行升级脚本 \033[0m"
      exit 1
  }
fi
tar -xf $PROJECT_DIR/$Upgrade_Version/lina-v$Upgrade_Version.tar.gz -C $install_dir

rm -rf $install_dir/luna*
if [ ! -f "$PROJECT_DIR/$Upgrade_Version/luna-v$Upgrade_Version.tar.gz" ]; then
    wget -qO $PROJECT_DIR/$Upgrade_Version/luna-v$Upgrade_Version.tar.gz http://demo.jumpserver.org/download/luna/$Upgrade_Version/luna-v$Upgrade_Version.tar.gz|| {
        rm -rf $PROJECT_DIR/$Upgrade_Version/luna-v$Upgrade_Version.tar.gz
        echo -e "\033[31m 下载 luna 失败, 请检查网络是否正常或尝试重新执行升级脚本 \033[0m"
        exit 1
    }
fi
tar -xf $PROJECT_DIR/$Upgrade_Version/luna-v$Upgrade_Version.tar.gz -C $install_dir

docker stop jms_koko jms_guacamole
docker rm jms_koko jms_guacamole
systemctl stop jms_core

if [ ! -d "$jumpserver_backup/jumpserver" ]; then
    mv $install_dir/jumpserver $jumpserver_backup/
    echo -e "\033[31m >>> 已备份文件到 $jumpserver_backup <<< \033[0m"
fi

if [ ! -f "$jumpserver_backup/$DB_NAME.sql" ]; then
    mysqldump -h$DB_HOST -P$DB_PORT -u$DB_USER -p$DB_PASSWORD $DB_NAME > $jumpserver_backup/$DB_NAME.sql
    echo -e "\033[31m >>> 已备份数据库到 $jumpserver_backup <<< \033[0m"
fi

if [ ! -d "$install_dir/jumpserver" ]; then
    tar -xf $PROJECT_DIR/$Upgrade_Version/jumpserver-v$Upgrade_Version.tar.gz -C $install_dir
    mv $install_dir/jumpserver-$Upgrade_Version $install_dir/jumpserver
fi

if [ ! -f "$install_dir/jumpserver/config.yml" ]; then
    cp $jumpserver_backup/jumpserver/config.yml $install_dir/jumpserver/
    \cp -rf $jumpserver_backup/jumpserver/data/* $install_dir/jumpserver/data/*
fi

source $install_dir/py3/bin/activate
pip install --upgrade pip setuptools
pip install -r $install_dir/jumpserver/requirements/requirements.txt || {
    echo "\033[31m 升级 python 依赖失败, 请检查网络是否正常或者更换 pypi 源 \033[0m"
    exit 1
}
if [ ! "$(systemctl status jms_core | grep Active | grep running)" ]; then
    systemctl start jms_core
fi

if [ "${Version:0:1}" == "1" ]; then
    rm -rf /etc/nginx/conf.d/jumpserver.conf
    if [ ! -f "$PROJECT_DIR/$Upgrade_Version/jumpserver.conf" ]; then
        wget -qO $PROJECT_DIR/$Upgrade_Version/jumpserver.conf http://demo.jumpserver.org/download/nginx/conf.d/$Upgrade_Version/jumpserver.conf || {
            rm -rf $PROJECT_DIR/$Upgrade_Version/jumpserver.conf
            echo "[ERROR] 下载 nginx 配置文件失败"
        }
    fi
    cp $PROJECT_DIR/$Upgrade_Version/jumpserver.conf /etc/nginx/conf.d/jumpserver.conf
    if [ "$http_port" != "80" ]; then
        sed -i "s@listen 80;@listen $http_port;@g" /etc/nginx/conf.d/jumpserver.conf
    fi
    if [ $install_dir != "/opt" ]; then
        sed -i "s@/opt@$install_dir@g" /etc/nginx/conf.d/jumpserver.conf
    fi
    sed -i "s@worker_processes  1;@worker_processes  auto;@g" /etc/nginx/nginx.conf
    if [ "$(getenforce)" != "Disabled" ]; then
      if [ ! "$(semanage fcontext -l | grep $install_dir/lina)" ]; then
          semanage fcontext -a -t httpd_sys_content_t "$install_dir/lina(/.*)?"
          restorecon -R $install_dir/lina/
      fi
    fi
    nginx -s reload
    systemctl restart nginx
fi

if [ -f "$PROJECT_DIR/$Upgrade_Version/koko.tar" ]; then
    docker load < $PROJECT_DIR/$Upgrade_Version/koko.tar
fi

if [ -f "$PROJECT_DIR/$Upgrade_Version/guacamole.tar" ]; then
    docker load < $PROJECT_DIR/$Upgrade_Version/guacamole.tar
fi

docker run --name jms_koko -d -p $ssh_port:2222 -p 127.0.0.1:5000:5000 -e CORE_HOST=http://$Server_IP:8080 -e BOOTSTRAP_TOKEN=$BOOTSTRAP_TOKEN --restart=always jumpserver/jms_koko:$Upgrade_Version || {
    echo "\033[31m jms_koko 镜像下载失败, 请检查网络是否正常或者手动 pull 镜像 \033[0m"
    exit 1
}

docker run --name jms_guacamole -d -p 127.0.0.1:8081:8080 -e JUMPSERVER_SERVER=http://$Server_IP:8080 -e BOOTSTRAP_TOKEN=$BOOTSTRAP_TOKEN --restart=always jumpserver/jms_guacamole:$Upgrade_Version || {
    echo "\033[31m jms_guacamole 镜像下载失败, 请检查网络是否正常或者手动 pull 镜像 \033[0m"
    exit 1
}

docker rmi jumpserver/jms_koko:$Version jumpserver/jms_guacamole:$Version

sed -i "s/Version=$Version/Version=$Upgrade_Version/g" ${PROJECT_DIR}/config.conf
echo -e "\033[31m >>> 已升级版本至 $Upgrade_Version <<< \033[0m"
