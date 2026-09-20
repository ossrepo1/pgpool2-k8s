#!/usr/bin/env bash
set -euo pipefail

PGPOOL_CONF="${PGPOOL_CONF:-/usr/local/etc/pgpool.conf}"
PGPOOL_CONF_DIR="$(dirname "${PGPOOL_CONF}")"
PGPOOL_RUN_DIR="${PGPOOL_RUN_DIR:-/run/pgpool}"

install -d -m 0755 "${PGPOOL_RUN_DIR}" 2>/dev/null || true

append_conf() {
    local pattern="$1" line="$2"
    if [ ! -w "${PGPOOL_CONF}" ]; then
        echo "docker-entrypoint: ${PGPOOL_CONF} is not writable, skipping: ${line}" >&2
        return 0
    fi
    if grep -qE "${pattern}" "${PGPOOL_CONF}"; then
        return 0
    fi
    printf '%s\n' "${line}" >> "${PGPOOL_CONF}"
}

if [ ! -s "${PGPOOL_CONF}" ]; then
    sample="${PGPOOL_CONF_DIR}/pgpool.conf.sample"
    if [ ! -s "${sample}" ]; then
        sample=/usr/local/etc/pgpool.conf.sample
    fi
    cp "${sample}" "${PGPOOL_CONF}"
    sed -i \
        -e "s/^#listen_addresses = .*/listen_addresses = '*'/" \
        -e "s/^#pcp_listen_addresses = .*/pcp_listen_addresses = '*'/" \
        -e "s|^#work_dir = .*|work_dir = '/var/lib/pgpool'|" \
        "${PGPOOL_CONF}"
fi

if [ -n "${PGPOOL_BACKEND_NODES:-}" ]; then
    backends_conf="${PGPOOL_CONF_DIR}/backends.conf"

    app_name_for() {
        local want_id="$1" entry entry_id entry_name
        if [ -n "${PGPOOL_BACKEND_APPLICATION_NAMES:-}" ]; then
            IFS=',' read -r -a entries <<< "${PGPOOL_BACKEND_APPLICATION_NAMES}"
            for entry in "${entries[@]}"; do
                IFS=':' read -r entry_id entry_name <<< "${entry}"
                if [ "${entry_id}" = "${want_id}" ] && [ -n "${entry_name}" ]; then
                    printf '%s' "${entry_name}"
                    return 0
                fi
            done
        fi
        printf '%s' "${PGPOOL_BACKEND_APPLICATION_NAME:-walreceiver}"
    }

    if [ -n "${PGPOOL_BACKEND_APPLICATION_NAMES:-}" ]; then
        IFS=',' read -r -a app_name_entries <<< "${PGPOOL_BACKEND_APPLICATION_NAMES}"
        for entry in "${app_name_entries[@]}"; do
            IFS=':' read -r entry_id entry_name <<< "${entry}"
            if [ -z "${entry_id}" ] || [ -z "${entry_name}" ]; then
                echo "docker-entrypoint: ignoring malformed PGPOOL_BACKEND_APPLICATION_NAMES entry '${entry}', expected id:name" >&2
            fi
        done
    fi

    : > "${backends_conf}"
    IFS=',' read -r -a nodes <<< "${PGPOOL_BACKEND_NODES}"
    for node in "${nodes[@]}"; do
        IFS=':' read -r id host port weight <<< "${node}"
        app_name="$(app_name_for "${id}")"
        {
            printf "backend_hostname%s = '%s'\n" "${id}" "${host}"
            printf "backend_port%s = %s\n" "${id}" "${port}"
            printf "backend_application_name%s = '%s'\n" "${id}" "${app_name}"
            if [ -n "${weight:-}" ]; then
                printf "backend_weight%s = %s\n" "${id}" "${weight}"
            fi
        } >> "${backends_conf}"
    done
    append_conf "^include[[:space:]]+.*$(basename "${backends_conf}")" "include '${backends_conf}'"
fi

if [ -n "${PGPOOL_POSTGRES_PASSWORD:-}" ]; then
    username="${PGPOOL_POSTGRES_USERNAME:-postgres}"
    pool_passwd="${PGPOOL_CONF_DIR}/pool_passwd"
    if [ -w "${PGPOOL_CONF_DIR}" ]; then
        touch "${pool_passwd}"
        chmod 0600 "${pool_passwd}"
        sed -i "\|^${username}:|d" "${pool_passwd}"
        printf '%s:%s\n' "${username}" "${PGPOOL_POSTGRES_PASSWORD}" >> "${pool_passwd}"
    else
        echo "docker-entrypoint: ${PGPOOL_CONF_DIR} is not writable, cannot update pool_passwd" >&2
    fi
    append_conf "^sr_check_user[[:space:]]*=" "sr_check_user = '${username}'"
    append_conf "^health_check_user[[:space:]]*=" "health_check_user = '${username}'"
fi

if [ -n "${PGPOOL_PCP_PASSWORD:-}" ]; then
    pcp_conf="${PGPOOL_CONF_DIR}/pcp.conf"
    if [ -w "${PGPOOL_CONF_DIR}" ]; then
        (
            umask 077
            printf '%s:%s\n' "${PGPOOL_PCP_USERNAME:-pgpool}" \
                "$(printf '%s' "${PGPOOL_PCP_PASSWORD}" | md5sum | cut -d' ' -f1)" > "${pcp_conf}"
        )
    else
        echo "docker-entrypoint: ${PGPOOL_CONF_DIR} is not writable, cannot write pcp.conf" >&2
    fi
fi

if [ "${PGPOOL_ONLY_ACTIVE_NODE:-false}" = "true" ]; then
    username="${PGPOOL_POSTGRES_USERNAME:-postgres}"
    append_conf "^load_balance_mode[[:space:]]*=" "load_balance_mode = off"
    append_conf "^sr_check_period[[:space:]]*=" "sr_check_period = 10"
    append_conf "^sr_check_user[[:space:]]*=" "sr_check_user = '${username}'"
    append_conf "^health_check_period[[:space:]]*=" "health_check_period = 10"
    append_conf "^health_check_max_retries[[:space:]]*=" "health_check_max_retries = 3"
    append_conf "^health_check_retry_delay[[:space:]]*=" "health_check_retry_delay = 1"
    append_conf "^health_check_timeout[[:space:]]*=" "health_check_timeout = ${PGPOOL_HEALTH_CHECK_TIMEOUT:-0}"
    append_conf "^health_check_user[[:space:]]*=" "health_check_user = '${username}'"
    append_conf "^auto_failback[[:space:]]*=" "auto_failback = on"
    if [ "${PGPOOL_DETACH_FALSE_PRIMARY:-false}" = "true" ]; then
        append_conf "^detach_false_primary[[:space:]]*=" "detach_false_primary = on"
    fi
    append_conf "^search_primary_node_timeout[[:space:]]*=" "search_primary_node_timeout = 300"
    append_conf "^failover_command[[:space:]]*=" "failover_command = ''"
    append_conf "^follow_primary_command[[:space:]]*=" "follow_primary_command = ''"
    if [ -z "${PGPOOL_POSTGRES_PASSWORD:-}" ] && [ ! -s "${PGPOOL_CONF_DIR}/pool_passwd" ]; then
        echo "docker-entrypoint: PGPOOL_ONLY_ACTIVE_NODE needs backend credentials for the health/sr checks." >&2
        echo "docker-entrypoint: set PGPOOL_POSTGRES_USERNAME/PGPOOL_POSTGRES_PASSWORD or mount a pool_passwd file." >&2
    fi
fi

if [ "${PGPOOL_ENABLE_POOL_HBA:-false}" = "true" ]; then
    pool_hba="${PGPOOL_CONF_DIR}/pool_hba.conf"
    if [ ! -s "${pool_hba}" ]; then
        printf 'host all all all scram-sha-256\n' > "${pool_hba}"
    fi
    append_conf "^enable_pool_hba[[:space:]]*=" "enable_pool_hba = on"
fi

exec "$@"
