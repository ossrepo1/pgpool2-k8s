#!/usr/bin/env bash
#
# Reconciles pgpool's node status with the real cluster state.
#
# Without pg_monitor, auto_failback can never fire (it needs replication_state == "streaming"),
# so a node pgpool detached - e.g. after an HK<->SG network flap - stays detached forever.
# This job attaches such nodes again, but only when it can prove they are live standbys of
# the current primary. It uses only PUBLIC functions, so the probe user needs no privileges:
#   pg_is_in_recovery(), pg_last_wal_replay_lsn(), pg_current_wal_lsn()
#
# It never detaches, never promotes, and never acts while the cluster state is ambiguous.
set -euo pipefail

: "${PGPOOL_BACKEND_NODES:?PGPOOL_BACKEND_NODES is required (id:host:port[:weight],...)}"

PGPOOL_HOST="${PGPOOL_HOST:-127.0.0.1}"
PGPOOL_PCP_PORT="${PGPOOL_PCP_PORT:-9898}"
PCP_USER="${PCP_USER:-pgpool}"
SAMPLE_INTERVAL_SECONDS="${SAMPLE_INTERVAL_SECONDS:-3}"
LAG_TOLERANCE_BYTES="${LAG_TOLERANCE_BYTES:-1073741824}"

export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-5}"
export PGDATABASE="${PGDATABASE:-postgres}"
export PGPASSWORD="${PGPASSWORD:-}"

log() { printf '%s reattach: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

query() {
    psql -w -h "$1" -p "$2" -tAqc "$3"
}

pcp_call() {
    "$1" -h "$PGPOOL_HOST" -p "$PGPOOL_PCP_PORT" -U "$PCP_USER" -w -n "$2"
}

if [ -n "${PCP_PASSWORD:-}" ]; then
    umask 077
    printf '%s:%s:%s:%s\n' "$PGPOOL_HOST" "$PGPOOL_PCP_PORT" "$PCP_USER" "$PCP_PASSWORD" > "${PCPPASSFILE:-/tmp/.pcppass}"
fi

node_ids=()
node_hosts=()
node_ports=()
node_roles=()
node_replay=()

for entry in ${PGPOOL_BACKEND_NODES//,/ }; do
    IFS=':' read -r id host port _weight <<< "${entry}"
    if [ -z "${id}" ] || [ -z "${host}" ] || [ -z "${port}" ]; then
        log "ignoring malformed node entry '${entry}'"
        continue
    fi

    role="$(query "${host}" "${port}" "SELECT pg_is_in_recovery()" 2>/dev/null || true)"
    node_ids+=("${id}")
    node_hosts+=("${host}")
    node_ports+=("${port}")
    node_roles+=("${role}")
    node_replay+=("")

    case "${role}" in
        t) log "node ${id} (${host}): standby" ;;
        f) log "node ${id} (${host}): primary" ;;
        *) log "node ${id} (${host}): unreachable" ;;
    esac
done

if [ "${#node_ids[@]}" -eq 0 ]; then
    log "no usable backend nodes, giving up"
    exit 0
fi

primary_index=-1
primary_count=0
for i in "${!node_ids[@]}"; do
    if [ "${node_roles[$i]}" = "f" ]; then
        primary_index="${i}"
        primary_count=$((primary_count + 1))
    fi
done

if [ "${primary_count}" -ne 1 ]; then
    log "found ${primary_count} node(s) reporting primary and $((${#node_ids[@]} - primary_count)) unreachable; refusing to act"
    exit 0
fi

primary_host="${node_hosts[$primary_index]}"
primary_port="${node_ports[$primary_index]}"
primary_id="${node_ids[$primary_index]}"

lsn_before="$(query "${primary_host}" "${primary_port}" "SELECT pg_current_wal_lsn()" 2>/dev/null || true)"
if [ -z "${lsn_before}" ]; then
    log "node ${primary_id} is primary but not accepting the LSN probe; refusing to act"
    exit 0
fi

for i in "${!node_ids[@]}"; do
    if [ "${node_roles[$i]}" = "t" ]; then
        node_replay[$i]="$(query "${node_hosts[$i]}" "${node_ports[$i]}" \
            "SELECT coalesce(pg_last_wal_replay_lsn()::text, '')" 2>/dev/null || true)"
    fi
done

sleep "${SAMPLE_INTERVAL_SECONDS}"

lsn_after="$(query "${primary_host}" "${primary_port}" "SELECT pg_current_wal_lsn()" 2>/dev/null || true)"
if [ -z "${lsn_after}" ]; then
    log "node ${primary_id} stopped answering the LSN probe; refusing to act"
    exit 0
fi

attached=0

for i in "${!node_ids[@]}"; do
    if [ "${node_roles[$i]}" != "t" ]; then
        continue
    fi

    id="${node_ids[$i]}"
    host="${node_hosts[$i]}"
    port="${node_ports[$i]}"
    replay_before="${node_replay[$i]}"

    if [ -n "${replay_before}" ]; then
        advanced_check="coalesce(pg_last_wal_replay_lsn() > '${replay_before}'::pg_lsn, false)"
    else
        advanced_check="true"
    fi

    checks="$(query "${host}" "${port}" \
        "SELECT pg_is_in_recovery(), ${advanced_check}, coalesce(pg_last_wal_replay_lsn() >= '${lsn_after}'::pg_lsn - ${LAG_TOLERANCE_BYTES}, false), coalesce(pg_last_wal_replay_lsn()::text, '')" \
        2>/dev/null || true)"
    IFS='|' read -r in_recovery advanced within_tolerance replay <<< "${checks}"

    if [ "${in_recovery:-}" != "t" ]; then
        log "node ${id}: not in recovery any more, skipping"
        continue
    fi

    if [ "${within_tolerance:-}" != "t" ]; then
        log "node ${id}: replay position ${replay:-unknown} is more than ${LAG_TOLERANCE_BYTES} bytes behind ${lsn_after}, skipping"
        continue
    fi

    if [ "${advanced:-}" != "t" ] && [ "${lsn_before}" != "${lsn_after}" ]; then
        log "node ${id}: WAL receiver is not advancing while the primary is writing, skipping"
        continue
    fi

    status="$(pcp_call pcp_node_info "${id}" 2>/dev/null | awk '{print $3}' || true)"

    case "${status:-}" in
        1)
            log "node ${id}: live standby, already attached"
            ;;
        2)
            if pcp_call pcp_attach_node "${id}" >/dev/null 2>&1; then
                log "node ${id}: live standby (replay ${replay}), attached"
                attached=$((attached + 1))
            else
                log "node ${id}: live standby but pcp_attach_node failed"
            fi
            ;;
        0|3)
            log "node ${id}: live standby but pgpool has it disabled (status ${status}), leaving it alone"
            ;;
        *)
            log "node ${id}: cannot read node status from pgpool, leaving it alone"
            ;;
    esac
done

log "done, attached ${attached} node(s)"
