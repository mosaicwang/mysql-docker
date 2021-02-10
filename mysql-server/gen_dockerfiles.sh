#!/bin/bash
# Copyright (c) 2017, 2021, Oracle and/or its affiliates.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301 USA

set -e

# This script will simply use sed to replace placeholder variables in the
# files in template/ with version-specific variants.

source ./VERSION

REPO=https://repo.mysql.com; [ -n "$1" ] && REPO=$1

# 33060 is the default port for the mysqlx plugin, new to 5.7
declare -A PORTS
PORTS["5.7"]="3306 33060"
PORTS["8.0"]="3306 33060 33061"

declare -A PASSWORDSET
PASSWORDSET["5.7"]="ALTER USER 'root'@'localhost' IDENTIFIED BY '\${MYSQL_ROOT_PASSWORD}';"
PASSWORDSET["8.0"]=${PASSWORDSET["5.7"]}

declare -A DATABASE_INIT
DATABASE_INIT["5.7"]="\"\$@\" --user=\$MYSQLD_USER --initialize-insecure"
DATABASE_INIT["8.0"]="\"\$@\" --user=\$MYSQLD_USER --initialize-insecure"

# 5.7+ has the --daemonize flag, which makes the process fork and then exit when
# the server is ready, removing the need for a fragile wait loop
declare -A INIT_STARTUP
INIT_STARTUP["5.7"]="\"\$@\" --user=\$MYSQLD_USER --daemonize --skip-networking --socket=\"\$SOCKET\""
INIT_STARTUP["8.0"]="\"\$@\" --user=\$MYSQLD_USER --daemonize --skip-networking --socket=\"\$SOCKET\""

declare -A STARTUP
STARTUP["5.7"]="exec \"\$@\" --user=\$MYSQLD_USER"
STARTUP["8.0"]="export MYSQLD_PARENT_PID=\$\$ ; exec \"\$@\" --user=\$MYSQLD_USER"

declare -A STARTUP_WAIT
STARTUP_WAIT["5.7"]="\"\""
STARTUP_WAIT["8.0"]="\"\""

# MySQL 8.0 supports a call to validate the config, while older versions have it as a side
# effect of running --verbose --help
declare -A VALIDATE_CONFIG
VALIDATE_CONFIG["5.7"]="output=\$(\"\$@\" --verbose --help 2>\&1 > /dev/null) || result=\$?"
VALIDATE_CONFIG["8.0"]="output=\$(\"\$@\" --validate-config) || result=\$?"

# Data directories that must be created with special ownership and permissions when the image is built
declare -A PRECREATE_DIRS
PRECREATE_DIRS["5.7"]="/var/lib/mysql /var/lib/mysql-files /var/lib/mysql-keyring /var/run/mysqld"
PRECREATE_DIRS["8.0"]="/var/lib/mysql /var/lib/mysql-files /var/lib/mysql-keyring /var/run/mysqld"

for VERSION in "${!MYSQL_SERVER_VERSIONS[@]}"
do
  # Dockerfiles
  MYSQL_SERVER_REPOPATH=yum/mysql-$VERSION-community/docker/x86_64
  DOCKERFILE_TEMPLATE=template/Dockerfile
  if [ "${VERSION}" != "8.0" ]; then
    DOCKERFILE_TEMPLATE=template/Dockerfile-pre8
  fi
  sed 's#%%MYSQL_SERVER_PACKAGE%%#'"mysql-community-server-minimal-${MYSQL_SERVER_VERSIONS[${VERSION}]}"'#g' $DOCKERFILE_TEMPLATE > tmpfile
  sed -i 's#%%REPO%%#'"${REPO}"'#g' tmpfile
  REPO_VERSION=${VERSION//\./}
  sed -i 's#%%REPO_VERSION%%#'"${REPO_VERSION}"'#g' tmpfile

  if [[ ! -z ${MYSQL_SHELL_VERSIONS[${VERSION}]} ]]; then
    sed -i 's#%%MYSQL_SHELL_PACKAGE%%#'"mysql-shell-${MYSQL_SHELL_VERSIONS[${VERSION}]}"'#g' tmpfile
  else
    sed -i 's#%%MYSQL_SHELL_PACKAGE%%#'""'#g' tmpfile
  fi

  sed -i 's/%%PORTS%%/'"${PORTS[${VERSION}]}"'/g' tmpfile
  mv tmpfile ${VERSION}/Dockerfile

  # Dockerfile_spec.rb
  if [ ! -d "${VERSION}/inspec" ]; then
    mkdir "${VERSION}/inspec"
  fi
  sed 's#%%MYSQL_SERVER_VERSION%%#'"${MYSQL_SERVER_VERSIONS[${VERSION}]}"'#g' template/control.rb > tmpFile
  sed -i 's#%%MYSQL_SHELL_VERSION%%#'"${MYSQL_SHELL_VERSIONS[${VERSION}]}"'#g' tmpFile
  if [ "${VERSION}" == "5.7" ]; then
    sed -i 's#%%PORTS%%#'"3306/tcp, 33060/tcp"'#g' tmpFile
  else
    sed -i 's#%%PORTS%%#'"3306/tcp, 33060-33061/tcp"'#g' tmpFile
  fi
  mv tmpFile "${VERSION}/inspec/control.rb"

  # Entrypoint
  sed 's#%%PASSWORDSET%%#'"${PASSWORDSET[${VERSION}]}"'#g' template/docker-entrypoint.sh > tmpfile
  sed -i 's#%%DATABASE_INIT%%#'"${DATABASE_INIT[${VERSION}]}"'#g' tmpfile
  sed -i 's#%%INIT_STARTUP%%#'"${INIT_STARTUP[${VERSION}]}"'#g' tmpfile
  sed -i 's#%%STARTUP%%#'"${STARTUP[${VERSION}]}"'#g' tmpfile
  sed -i 's#%%STARTUP_WAIT%%#'"${STARTUP_WAIT[${VERSION}]}"'#g' tmpfile
  sed -i 's#%%FULL_SERVER_VERSION%%#'"${FULL_SERVER_VERSIONS[${VERSION}]}"'#g' tmpfile
  sed -i 's#%%VALIDATE_CONFIG%%#'"${VALIDATE_CONFIG[${VERSION}]}"'#g' tmpfile
  mv tmpfile ${VERSION}/docker-entrypoint.sh
  chmod +x ${VERSION}/docker-entrypoint.sh

  # Healthcheck
  cp template/healthcheck.sh ${VERSION}/
  chmod +x ${VERSION}/healthcheck.sh

  # Build-time preparation script
  sed 's#%%PRECREATE_DIRS%%#'"${PRECREATE_DIRS[${VERSION}]}"'#g' template/prepare-image.sh > tmpfile
  mv tmpfile ${VERSION}/prepare-image.sh
  chmod +x ${VERSION}/prepare-image.sh
done
