#!/bin/bash
set -e
logger "Arrancando instalacion y configuracion de MongoDB"
USO="Uso : install.sh [opciones]
Ejemplo:
install.sh -f config.ini
Opciones:
-f archivo de configuración
-a muestra esta ayuda
"

function ayuda() {
    echo "${USO}"
    if [[ ${1} ]]
    then
        echo ${1}
    fi
}

function leer_config() {
    if [[ ! -f "$1" ]]; then
        echo "Error: No se encuentra el archivo de configuracion $1"
        exit 1
    fi
    
    # Leer variables del archivo de configuración
    while IFS='=' read -r key value; do
        # Eliminar espacios en blanco
        key=$(echo "$key" | tr -d ' ')
        value=$(echo "$value" | tr -d ' ')
        case "$key" in
            "user")
                USUARIO=$value
                echo "Parametro USUARIO establecido con '${USUARIO}'";;
            "password")
                PASSWORD=$value
                echo "Parametro PASSWORD establecido";;
            "port")
                PUERTO_MONGOD=$value
                echo "Parametro PUERTO_MONGOD establecido con '${PUERTO_MONGOD}'";;
        esac
    done < "$1"
}

# Gestionar los argumentos
while getopts ":f:a" OPCION
do
    case ${OPCION} in
        f ) CONFIG_FILE=$OPTARG
            leer_config "$CONFIG_FILE";;
        a ) ayuda; exit 0;;
        : ) ayuda "Falta el parametro para -$OPTARG"; exit 1;;
        \?) ayuda "La opcion no existe : $OPTARG"; exit 1;;
    esac
done

if [ -z ${USUARIO} ]
then
    ayuda "El usuario debe ser especificado en el archivo de configuracion"; exit 1
fi

if [ -z ${PASSWORD} ]
then
    ayuda "La password debe ser especificada en el archivo de configuracion"; exit 1
fi

if [ -z ${PUERTO_MONGOD} ]
then
    PUERTO_MONGOD=27017
fi

# Preparar el repositorio (apt-get) de mongodb añadir su clave apt
apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv 4B7C549A058F8B6B
echo "deb [ arch=amd64,arm64 ] https://repo.mongodb.org/apt/ubuntu xenial/mongodb-org/4.2 multiverse" | tee /etc/apt/sources.list.d/mongodb.list

if [[ -z "$(mongo --version 2> /dev/null | grep '4.2.1')" ]]
then
    # Instalar paquetes comunes, servidor, shell, balanceador de shards y herramientas
    apt-get -y update \
    && apt-get install -y \
        mongodb-org=4.2.1 \
        mongodb-org-server=4.2.1 \
        mongodb-org-shell=4.2.1 \
        mongodb-org-mongos=4.2.1 \
        mongodb-org-tools=4.2.1 \
    && rm -rf /var/lib/apt/lists/* \
    && pkill -u mongodb || true \
    && rm -rf /var/lib/mongodb
fi

# Crear las carpetas de logs y datos con sus permisos
[[ -d "/datos/bd" ]] || mkdir -p -m 755 "/datos/bd"
[[ -d "/datos/log" ]] || mkdir -p -m 755 "/datos/log"

# Establecer el dueño y el grupo de las carpetas db y log
chown mongodb /datos/log /datos/bd
chgrp mongodb /datos/log /datos/bd

# Crear el archivo de configuracion de mongodb con el puerto solicitado
mv /etc/mongod.conf /etc/mongod.conf.orig
(
cat <<MONGOD_CONF
# /etc/mongod.conf
systemLog:
   destination: file
   path: /datos/log/mongod.log
   logAppend: true
storage:
   dbPath: /datos/bd
   engine: wiredTiger
   journal:
      enabled: true
net:
   port: ${PUERTO_MONGOD}
security:
   authorization: enabled
MONGOD_CONF
) > /etc/mongod.conf

# Reiniciar el servicio de mongod para aplicar la nueva configuracion
systemctl restart mongod

# Verificar que el servicio de MongoDB haya arrancado correctamente
logger "Esperando a que MongoDB arranque..."
for i in {1..15}; do
    if mongo --eval "db.stats()" &>/dev/null; then
        logger "¡MongoDB esta listo!"
        break
    fi
    if [[ $i -eq 15 ]]; then
        logger "ERROR: MongoDB no respondio despues de $i segundos"
        exit 1
    fi
    sleep 1
done

# Crear usuario con la password proporcionada como parametro
mongo admin << CREACION_DE_USUARIO
db.createUser({
    user: "${USUARIO}",
    pwd: "${PASSWORD}",
    roles:[{
        role: "root",
        db: "admin"
    },{
        role: "restore",
        db: "admin"
}] })
CREACION_DE_USUARIO

logger "El usuario ${USUARIO} ha sido creado con exito!"
exit 0
