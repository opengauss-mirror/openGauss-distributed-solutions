#!/usr/bin/env bash
set -Eeo pipefail 

# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)

export GAUSSHOME=/usr/local/opengauss
export PATH=$GAUSSHOME/bin:$PATH
export LD_LIBRARY_PATH=$GAUSSHOME/lib:$LD_LIBRARY_PATH
export LANG=en_US.UTF-8

file_env() {
        local var="$1"
        local fileVar="${var}_FILE"
        local def="${2:-}"
        if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
                echo >&2 "error: both $var and $fileVar are set (but are exclusive)"
                exit 1
        fi
        local val="$def"
        if [ "${!var:-}" ]; then
                val="${!var}"
        elif [ "${!fileVar:-}" ]; then
                val="$(< "${!fileVar}")"
        fi
        export "$var"="$val"
        unset "$fileVar"
}

# check to see if this file is being run or sourced from another script
_is_sourced() {
        [ "${#FUNCNAME[@]}" -ge 2 ] \
                && [ "${FUNCNAME[0]}" = '_is_sourced' ] \
                && [ "${FUNCNAME[1]}" = 'source' ]
}

# used to create initial opengauss directories and if run as root, ensure ownership belong to the omm user
docker_create_db_directories() {
        local user; user="$(id -u)"

        mkdir -p "$PGDATA"
        chmod 700 "$PGDATA"

        # ignore failure since it will be fine when using the image provided directory;
        mkdir -p /var/run/opengauss || :
        chmod 775 /var/run/opengauss || :

        # Create the transaction log directory before initdb is run so the directory is owned by the correct user
        if [ -n "$POSTGRES_INITDB_XLOGDIR" ]; then
                mkdir -p "$POSTGRES_INITDB_XLOGDIR"
                if [ "$user" = '0' ]; then
                        find "$POSTGRES_INITDB_XLOGDIR" \! -user postgres -exec chown postgres '{}' +
                fi
                chmod 700 "$POSTGRES_INITDB_XLOGDIR"
        fi

        # allow the container to be started with `--user`
        if [ "$user" = '0' ]; then
                find "$PGDATA" \! -user omm -exec chown omm '{}' +
                find /var/run/opengauss \! -user omm -exec chown omm '{}' +
        fi
}

# initialize empty PGDATA directory with new database via 'initdb'
# arguments to `initdb` can be passed via POSTGRES_INITDB_ARGS or as arguments to this function
# `initdb` automatically creates the "postgres", "template0", and "template1" dbnames
# this is also where the database user is created, specified by `GS_USER` env
docker_init_database_dir() {
        # "initdb" is particular about the current user existing in "/etc/passwd", so we use "nss_wrapper" to fake that if necessary
        if ! getent passwd "$(id -u)" &> /dev/null && [ -e /usr/lib/libnss_wrapper.so ]; then
                export LD_PRELOAD='/usr/lib/libnss_wrapper.so'
                export NSS_WRAPPER_PASSWD="$(mktemp)"
                export NSS_WRAPPER_GROUP="$(mktemp)"
                echo "postgres:x:$(id -u):$(id -g):PostgreSQL:$PGDATA:/bin/false" > "$NSS_WRAPPER_PASSWD"
                echo "postgres:x:$(id -g):" > "$NSS_WRAPPER_GROUP"
        fi

        if [ -n "$POSTGRES_INITDB_XLOGDIR" ]; then
                set -- --xlogdir "$POSTGRES_INITDB_XLOGDIR" "$@"
        fi

        gs_initdb -w "$GS_PASSWORD" --nodename=opengauss --encoding=UTF-8 --locale=en_US.UTF-8 --dbcompatibility=PG -D $PGDATA
        # unset/cleanup "nss_wrapper" bits
        if [ "${LD_PRELOAD:-}" = '/usr/lib/libnss_wrapper.so' ]; then
                rm -f "$NSS_WRAPPER_PASSWD" "$NSS_WRAPPER_GROUP"
                unset LD_PRELOAD NSS_WRAPPER_PASSWD NSS_WRAPPER_GROUP
        fi
}

# print large warning if GS_PASSWORD is long
# error if both GS_PASSWORD is empty and GS_HOST_AUTH_METHOD is not 'trust'
# print large warning if GS_HOST_AUTH_METHOD is set to 'trust'
# assumes database is not set up, ie: [ -z "$DATABASE_ALREADY_EXISTS" ]
docker_verify_minimum_env() {
        # check password first so we can output the warning before postgres
        # messes it up
        if [[ "$GS_PASSWORD" =~  ^(.{8,}).*$ ]] &&  [[ "$GS_PASSWORD" =~ ^(.*[a-z]+).*$ ]] && [[ "$GS_PASSWORD" =~ ^(.*[A-Z]).*$ ]] &&  [[ "$GS_PASSWORD" =~ ^(.*[0-9]).*$ ]] && [[ "$GS_PASSWORD" =~ ^(.*[#?!@$%^&*-]).*$ ]]; then
                cat >&2 <<-'EOWARN'

                        Message: The supplied GS_PASSWORD is meet requirements.

EOWARN
        else
                 cat >&2 <<-'EOWARN'

                        Error: The supplied GS_PASSWORD is not meet requirements.
                        Please Check if the password contains uppercase, lowercase, numbers, special characters, and password length(8).
                        At least one uppercase, lowercase, numeric, special character.
                        Example: Enmo@123
EOWARN
        exit 1
        fi
        if [ -z "$GS_PASSWORD" ] && [ 'trust' != "$GS_HOST_AUTH_METHOD" ]; then
                # The - option suppresses leading tabs but *not* spaces. :)
                cat >&2 <<-'EOE'
                        Error: Database is uninitialized and superuser password is not specified.
                               You must specify GS_PASSWORD to a non-empty value for the
                               superuser. For example, "-e GS_PASSWORD=password" on "docker run".

                               You may also use "GS_HOST_AUTH_METHOD=trust" to allow all
                               connections without a password. This is *not* recommended.

EOE
                exit 1
        fi
        if [ 'trust' = "$GS_HOST_AUTH_METHOD" ]; then
                cat >&2 <<-'EOWARN'
                        ********************************************************************************
                        WARNING: GS_HOST_AUTH_METHOD has been set to "trust". This will allow
                                 anyone with access to the opengauss port to access your database without
                                 a password, even if GS_PASSWORD is set.
                                 It is not recommended to use GS_HOST_AUTH_METHOD=trust. Replace
                                 it with "-e GS_PASSWORD=password" instead to set a password in
                                 "docker run".
                        ********************************************************************************
EOWARN
        fi
}

# usage: docker_process_init_files [file [file [...]]]
#    ie: docker_process_init_files /always-initdb.d/*
# process initializer files, based on file extensions and permissions
docker_process_init_files() {
        # gsql here for backwards compatiblilty "${gsql[@]}"
        gsql=( docker_process_sql )

        echo
        local f
        for f; do
                case "$f" in
                        *.sh)
                                if [ -x "$f" ]; then
                                        echo "$0: running $f"
                                        "$f"
                                else
                                        echo "$0: sourcing $f"
                                        . "$f"
                                fi
                                ;;
                        *.sql)    echo "$0: running $f"; docker_process_sql -f "$f"; echo ;;
                        *.sql.gz) echo "$0: running $f"; gunzip -c "$f" | docker_process_sql; echo ;;
                        *.sql.xz) echo "$0: running $f"; xzcat "$f" | docker_process_sql; echo ;;
                        *)        echo "$0: ignoring $f" ;;
                esac
                echo
        done
}

# Execute sql script, passed via stdin (or -f flag of pqsl)
# usage: docker_process_sql [gsql-cli-args]
#    ie: docker_process_sql --dbname=mydb <<<'INSERT ...'
#    ie: docker_process_sql -f my-file.sql
#    ie: docker_process_sql <my-file.sql
docker_process_sql() {
        local query_runner=( gsql -v ON_ERROR_STOP=1 --username "$GS_USER" --password "$GS_PASSWORD")
        if [ -n "$GS_DB" ]; then
                query_runner+=( --dbname "$GS_DB" )
        fi
        
        echo "Execute SQL: ${query_runner[@]} $@"
        "${query_runner[@]}" "$@"
}

# create initial database
# uses environment variables for input: GS_DB
docker_setup_db() {
        echo "GS_DB = $GS_DB"
        if [ "$GS_DB" != 'postgres' ]; then
                GS_DB= docker_process_sql --dbname postgres --set db="$GS_DB" --set passwd="$GS_PASSWORD" <<-'EOSQL'
                        CREATE DATABASE :"db" ;

EOSQL
                echo "created database $GS_DB"
        fi
}

# create a user that can connect database remotely
# uses environment variables for input: GS_USERNAME
docker_setup_user() {
        echo "docker_setup_user"
        if [ ! -n "$GS_USERNAME" ]; then
                GS_USERNAME="admin"
                echo "GS_USERNAME=$GS_USERNAME"
        fi
        gsql -d postgres -p $PORT -c "create user $GS_USERNAME with SYSADMIN password \"$GS_PASSWORD\";"
        echo "created user $GS_USERNAME"
}


# Loads various settings that are used elsewhere in the script
# This should be called before any other functions
docker_setup_env() {
        export GS_USER=omm
        file_env 'GS_PASSWORD'

        # file_env 'GS_USER' 'omm'
        file_env 'GS_DB' "$GS_USER"
        file_env 'POSTGRES_INITDB_ARGS'
        # default authentication method is md5
        : "${GS_HOST_AUTH_METHOD:=md5}"

        declare -g DATABASE_ALREADY_EXISTS
        # look specifically for OG_VERSION, as it is expected in the DB dir
        if [ -s "$PGDATA/PG_VERSION" ]; then
                DATABASE_ALREADY_EXISTS='true'
        fi
}

# append GS_HOST_AUTH_METHOD to pg_hba.conf for "host" connections
opengauss_setup_hba_conf() {
        if [ ! -f "$PGDATA/pg_hba0.conf" ]; then
                cp "$PGDATA/pg_hba.conf" "$PGDATA/pg_hba0.conf"
        fi
        if [ -n "$CLIENT_IP" ]; then
                gs_guc set -D $PGDATA -h "host all all ${CLIENT_IP}/32 sha256"
        fi
        gs_guc set -D $PGDATA -h "host all all ${HOST_IP}/32 trust"
        if [ $PEER_IPS_ARR ]; then
                len=$((${#PEER_IPS_ARR[*]} - 1))
                for i in $(seq 0 $len); do
                        gs_guc set -D $PGDATA -h "host all all ${PEER_IPS_ARR[$i]}/32 trust"
                done
        fi
        if [ ! -n "$GS_USERNAME" ]; then
                GS_USERNAME="admin"
        fi
        if [ "`grep host.*all.*$GS_USERNAME.*md5 $PGDATA/pg_hba.conf`" == "" ]; then
                sed -i "/host.*all.*all.*127.0.0.1\/32.*trust/a host all ${GS_USERNAME} 0.0.0.0/0 md5" $PGDATA/pg_hba.conf
        fi
        echo "host replication ${GS_USERNAME} 0.0.0.0/0 sha256" >> $PGDATA/pg_hba.conf
}

# append parameter to postgres.conf for connections
opengauss_setup_postgresql_conf() {
        if [ -n "$PORT" ]; then
            gs_guc set -D $PGDATA -c "port=$PORT"
        else
            gs_guc set -D $PGDATA -c "PORT=5432"
        fi
        gs_guc set -D $PGDATA -c "password_encryption_type = 1" \
        -c "wal_level=logical" \
        -c "max_wal_senders=16" \
        -c "max_replication_slots=9" \
        -c "wal_sender_timeout=0s" \
        -c "wal_receiver_timeout=0s"
        
        if [ -n "$SERVER_MODE" ]; then
            gs_guc set -D $PGDATA -c  "listen_addresses = '${HOST_IP}'" \
            -c "most_available_sync = on" \
            -c "remote_read_mode = off" \
            -c "pgxc_node_name = '$HOST_NAME'" \
            -c "application_name = '$HOST_NAME'"
            set_REPLCONNINFO
            if [ -n "$SYNCHRONOUS_STANDBY_NAMES" ]; then
                gs_guc set -D $PGDATA -c "synchronous_standby_names=$SYNCHRONOUS_STANDBY_NAMES"
            fi
        else
            gs_guc set -D $PGDATA -c "listen_addresses = '*'"
        fi

        if [ -n "$db_config" ]; then
            OLD_IFS="$IFS"
            IFS="#"
            db_config=($db_config)
            for s in ${db_config[@]}; do
                gs_guc set -D $PGDATA -c "$s"
            done
            IFS="$OLD_IFS"
        fi
        if [ -f "/tmp/db_config.conf" ]; then
            cat /tmp/db_config.conf >> "$PGDATA/postgresql.conf"
        fi
}

opengauss_setup_mot_conf() {
         echo "enable_numa = false" >> "$PGDATA/mot.conf"
}

# start socket-only postgresql server for setting up or running scripts
# all arguments will be passed along as arguments to `postgres` (via pg_ctl)
docker_temp_server_start() {
        if [ "$1" = 'gaussdb' ]; then
                shift
        fi

        # internal start of server in order to allow setup using gsql client
        # does not listen on external TCP/IP and waits until start finishes
        set -- "$@" -c listen_addresses='' -p "${PORT:-5432}"

        PGUSER="${PGUSER:-$GS_USER}" \
        gs_ctl -D "$PGDATA" \
                -o "$(printf '%q ' "$@")" \
                -w start
}

# stop postgresql server after done setting up user and running scripts
docker_temp_server_stop() {
        PGUSER="${PGUSER:-postgres}" \
        gs_ctl -D "$PGDATA" -m fast -w stop
}

docker_slave_full_backup() {
        echo "rebuild standby"
        set +e
        while :
        do
                gs_ctl restart -D "$PGDATA" -M $SERVER_MODE
                gs_ctl build -D "$PGDATA" -M $SERVER_MODE -b full
                if [ $? -eq 0 ]; then
                        break
                else
                        echo "errcode=$?"
                        echo "build failed"
                        sleep 1s
                fi
        done
        set -e
}

_create_config_og() {
        docker_setup_env
        # setup data directories and permissions (when run as root)
        docker_create_db_directories
        if [ "$(id -u)" = '0' ]; then
                # then restart script as postgres user
                exec gosu omm "$BASH_SOURCE" "$@"
        fi

        # only run initialization on an empty data directory
        if [ -z "$DATABASE_ALREADY_EXISTS" ]; then
                docker_verify_minimum_env

                # check dir permissions to reduce likelihood of half-initialized database
                ls /docker-entrypoint-initdb.d/ > /dev/null

                docker_init_database_dir
                opengauss_setup_hba_conf
                opengauss_setup_postgresql_conf
                opengauss_setup_mot_conf

                # PGPASSWORD is required for gsql when authentication is required for 'local' connections via pg_hba.conf and is otherwise harmless
                # e.g. when '--auth=md5' or '--auth-local=md5' is used in POSTGRES_INITDB_ARGS
                export PGPASSWORD="${PGPASSWORD:-$GS_PASSWORD}"
                docker_temp_server_start "$@"
                if [ -z "$SERVER_MODE" ] || [ "$SERVER_MODE" = "primary" ]; then
                        docker_setup_db
                        docker_setup_user
                        docker_process_init_files /docker-entrypoint-initdb.d/*
                fi

                if [ -n "$SERVER_MODE" ] && [ "$SERVER_MODE" != "primary" ]; then
                        docker_slave_full_backup
                fi
                docker_temp_server_stop
                unset PGPASSWORD

                echo
                echo 'openGauss  init process complete; ready for start up.'
                echo
        else
                echo
                echo 'openGauss Database directory appears to contain a database; Skipping initialization'
                echo
        fi
}

# process PEER_IPS, PEER_HOST_NAMES
# uses environment variables for input: PEER_IPS, PEER_HOST_NAMES
process_check_PEERS () {
        # process PEER_IPS and PEER_HOST_NAMES to array
        PEER_IPS_ARR=(${PEER_IPS//,/ })
        PEER_HOST_NAMES_ARR=(${PEER_HOST_NAMES//,/ })
        local len_ips=${#PEER_IPS_ARR[*]}
        local len_names=${#PEER_HOST_NAMES_ARR[*]}
        echo "len_ips=$len_ips"
        echo "len_names=$len_names"
        if [ ${len_ips} -ne ${len_names} ]; then
                cat >&2 <<-'EOE'
                        Error: PEER_IPS are not matched with PEER_HOST_NAMES!

EOE
                exit 1
        fi
        if [ ${len_ips} -gt 8 ]; then
                cat >&2 <<-'EOE'
                        Error: Opengauss support 8 standbies at most!

EOE
                exit 1
        fi
        set +e
        for i in $(seq 0 $(($len_ips - 1))); do
                while :
                do
                        
                        local tempip=`host ${PEER_IPS_ARR[$i]} | grep -Eo "[0-9]+.[0-9]+.[0-9]+.[0-9]+"`
                        if [ -n "$tempip" ]; then
                                PEER_IPS_ARR[$i]="$tempip"
                                break
                        else
                                sleep 1s
                        fi
                done
        done
        set -e
        PEER_NUM=$len_ips
        echo "export STANDBY_NUM=$PEER_NUM" >> /home/omm/.bashrc
}

# get etcd's parameter ETCD_MEMBERS
get_ETCD_MEMBERS () {
        echo "----get_ETCD_MEMBERS-----"
        ETCD_MEMBERS="${HOST_NAME}=http://${HOST_IP}:2380"
        echo "ETCD_MEMBERS=$ETCD_MEMBERS"
        local len=$(($PEER_NUM - 1))
        for i in $(seq 0 ${len}); do
                echo "${i}  ${PEER_HOST_NAMES_ARR[$i]}  ${PEER_IPS_ARR[$i]}"
                ETCD_MEMBERS="${ETCD_MEMBERS},${PEER_HOST_NAMES_ARR[$i]}=http://${PEER_IPS_ARR[$i]}:2380"
        done
        echo "ETCD_MEMBERS=$ETCD_MEMBERS"
}

# get database's parameter replconninfoi
# uses environment variables for input: HOST_IP, PORT
get_replconninfoi () {
    replconninfoi="localhost=${HOST_IP} localport=$((${PORT} + 1)) localheartbeatport=$((${PORT} + 2)) localservice=$((${PORT} + 4)) remotehost=$1 remoteport=$(($2 + 1)) remoteheartbeatport=$(($2 + 2)) remoteservice=$(($2 + 4))"
}

# set database's parameter REPL_CONN_INFO
# uses environment variables for input: PEER_IPS
set_REPLCONNINFO () {
    REPL_CONN_INFO=""
    local len=$(($PEER_NUM - 1))
    for i in $(seq 0 $len); do
        get_replconninfoi "${PEER_IPS_ARR[$i]}" $PORT
        gs_guc set -D $PGDATA -c "replconninfo$((${i} + 1)) = '${replconninfoi}'"
    done
}

# change etcd's config
# uses environment variables for input: HOST_NAME, HOST_IP, INITIAL_CLUSTER_STATE
change_etcd_config() {
        get_ETCD_MEMBERS
        sed -i "s/^name: 'default'/name: '${HOST_NAME}'/" /home/omm/etcd.conf && \
        sed -i "s/^listen-peer-urls: http:\/\/localhost:2380/listen-peer-urls: http:\/\/${HOST_IP}:2380/" /home/omm/etcd.conf && \
        sed -i "s/^initial-advertise-peer-urls: http:\/\/localhost:2380/initial-advertise-peer-urls: http:\/\/${HOST_IP}:2380/" /home/omm/etcd.conf && \
        sed -i "s/^advertise-client-urls: http:\/\/localhost:2379/advertise-client-urls: http:\/\/${HOST_IP}:2379/" /home/omm/etcd.conf && \
        sed -i "s|^initial-cluster: initial-cluster|initial-cluster: ${ETCD_MEMBERS}|" /home/omm/etcd.conf
        if [ -n "${INITIAL_CLUSTER_STATE}" ] && [ "${INITIAL_CLUSTER_STATE}" == "existing" ]; then
                sed -i "s/initial-cluster-state: 'new'/initial-cluster-state: 'existing'/" /home/omm/etcd.conf
        fi
}

# get ETCD_HOSTS
get_ETCD_HOSTS () {
    ETCD_HOSTS="${HOST_IP}:2379"
    for i in $(seq 0 $len); do
        ETCD_HOSTS="${ETCD_HOSTS},${PEER_IPS_ARR[$i]}:2379"
    done
}

# change patroni's config
# uses environment variables for input: HOST_NAME, HOST_IP, PORT, GS_PASSWORD, GS_PASSWORD
change_patroni_config() {
        get_ETCD_HOSTS
        sed -i "s/^name: name/name: ${HOST_NAME}/" /home/omm/patroni.yaml && \
        sed -i "s/^  listen: localhost:8008/  listen: ${HOST_IP}:8008/" /home/omm/patroni.yaml && \
        sed -i "s/^  connect_address: localhost:8008/  connect_address: ${HOST_IP}:8008/" /home/omm/patroni.yaml && \
        sed -i "s/^  host: localhost:2379/  hosts: ${ETCD_HOSTS}/" /home/omm/patroni.yaml && \
        sed -i "s/^  listen: localhost:16000/  listen: ${HOST_IP}:${PORT}/" /home/omm/patroni.yaml && \
        sed -i "s/^  connect_address: localhost:16000/  connect_address: ${HOST_IP}:${PORT}/" /home/omm/patroni.yaml
        if [ -n "$GS_USERNAME" ] && [ "$GS_USERNAME" != "admin" ]; then
                sed -i "s/^      username: admin/      username: $GS_USERNAME/" /home/omm/patroni.yaml
        fi
        sed -i "s/^      password: huawei_123/      password: $GS_PASSWORD/" /home/omm/patroni.yaml
}

# add new members
# uses environment variables for input: 
add_standby () {
        source /home/omm/.bashrc
        echo "STANDBY_NUM=$STANDBY_NUM"
        if [ $STANDBY_NUM -gt 8 ]; then
                cat >&2 <<-'EOE'
                        Error: Opengauss support 8 standbies at most and there are already 8 standbies now!

EOE
                exit 1
        fi
        echo "NEW_MEMBER_IPS=$NEW_MEMBER_IPS"
        echo "NEW_MEMBER_NAMES=$NEW_MEMBER_NAMES"
        NEW_MEMBER_IPS_ARR=(${NEW_MEMBER_IPS//,/ })
        NEW_MEMBER_NAMES_ARR=(${NEW_MEMBER_NAMES//,/ })
        echo "NEW_MEMBER_IPS_ARR=${NEW_MEMBER_IPS_ARR[*]}"
        echo "NEW_MEMBER_NAMES_ARR=${NEW_MEMBER_NAMES_ARR[*]}"
        local len_ips=${#NEW_MEMBER_IPS_ARR[*]}
        local len_names=${#NEW_MEMBER_NAMES_ARR[*]}
        echo "len_ips=$len_ips"
        echo "len_names=$len_names"
        if [ $len_ips -ne $len_names ]; then
                cat >&2 <<-'EOE'
                        Error: NEW_MEMBER_IPS are not matched with NEW_MEMBER_IPS!

EOE
                exit 1
        fi
        if [ $len_ips -eq 0 ]; then
                cat >&2 <<-'EOE'
                        Error: No new members!

EOE
                exit 1
        fi
        if [ $(($STANDBY_NUM + len_ips)) -gt 8 ]; then
                cat >&2 <<-'EOE'
                        Error: The cluster has already $STANDBY_NUM standbies now, so $len_ips standbies can't be added!

EOE
                exit 1
        fi
        local len=$(($len_ips - 1))
        local member_list=`etcdctl member list`
        echo -e "member_list=$member_list"
        for i in $(seq 0 $len); do
                if [[ $member_list =~ " started, ${NEW_MEMBER_NAMES_ARR[$i]}" ]]; then
                        echo "${NEW_MEMBER_IPS[$i]} has already been in the cluster."
                else
                        while :
                        do
                                host ${NEW_MEMBER_IPS_ARR[$i]} && echo "" > /dev/null
                                if [ $? -eq 0 ]; then
                                        NEW_MEMBER_IPS_ARR[$i]=`host ${NEW_MEMBER_IPS_ARR[$i]} | grep -Eo "[0-9]+.[0-9]+.[0-9]+.[0-9]+"`
                                        echo "NEW_MEMBER_IPS: $i ${NEW_MEMBER_IPS_ARR[$i]}"
                                        break
                                fi
                        done
                        if [[ $member_list == *unstarted*${NEW_MEMBER_IPS_ARR[$i]}* ]]; then
                                echo "${NEW_MEMBER_NAMES_ARR[$i]} has already been in the etcd cluster."
                        else
                                etcdctl member add ${NEW_MEMBER_NAMES_ARR[$i]} --peer-urls="http://${NEW_MEMBER_IPS_ARR[$i]}:2380"
                        fi
                        get_replconninfoi "${NEW_MEMBER_IPS_ARR[$i]}" $PORT
                        gs_guc reload -D $PGDATA -c "replconninfo$((${STANDBY_NUM} + ${i} + 1 ))='${replconninfoi}'"
                fi
        done
        sed -i "s|STANDBY_NUM=${STANDBY_NUM}|STANDBY_NUM=$(($STANDBY_NUM + len_ips))|" /home/omm/.bashrc
        echo "Etcd and database is ready to join the new member. Please start the new member."
}

_main() {
        if [ "$(id -u)" = '0' ]; then
                id
                # then restart script as postgres user
                if [ -d "/var/lib/opengauss/data/" ]; then
                        chown omm:omm /var/lib/opengauss/data/ -R
                fi
                exec gosu omm "$BASH_SOURCE" "$@"
        elif [ $# = 1 ] && [ "$1" = "patroni" ]; then
                process_check_PEERS
                # change etcd config file
                echo "-------------------------change etcd config-------------------------"
                change_etcd_config
                # start etcd
                echo "-------------------------start etcd-------------------------"
                etcd --config-file /home/omm/etcd.conf > /var/log/etcd.log 2>&1 &
                echo "-------------------------etcd.log-------------------------"
                sleep 1s
                cat /var/log/etcd.log

                # create and config database
                echo "-------------------------prepare start-------------------------"
                echo "-------------------------create and config opengauss-------------------------"
                if [ "`ls -A $PGDATA`" = "" ]; then
                        _create_config_og
                else
                        echo "database directory has already been exist"
                        cp "$PGDATA/pg_hba0.conf" "$PGDATA/pg_hba.conf" -f
                        opengauss_setup_hba_conf
                        opengauss_setup_postgresql_conf
                        if [ -n "$SERVER_MODE" ] && [ "$SERVER_MODE" != "primary" ]; then
                                docker_slave_full_backup
                                docker_temp_server_stop
                        fi
                fi

                # change patroni config file
                change_patroni_config
                # start patroni
                source /home/omm/.bashrc
                exec patroni /home/omm/patroni.yaml 2>&1 | tee /var/log/patroni.log
        elif [ "$1" = "list" ] || [ "$1" = "switchover" ] || [ "$1" = "failover" ]; then
                patronictl -c /home/omm/patroni.yaml $1
        elif [ "$1" = "add_standby" ]; then
                add_standby "$@"
        else
                exec "$@"
        fi
}

if ! _is_sourced; then
        _main "$@"
fi
