#!/bin/sh
# Pairs Lab A with its reference lab, Lab B.
#
# Lab A addresses a referral Task to the reference lab's FHIR id, and Lab B
# picks up the Tasks addressed to its own facility. This script reads Lab B's
# facility FHIR id ("This laboratory" at the top of Admin > Locations &
# Organizations > Organizations on Lab B) and records it on Lab A's
# reference lab (Admin > Locations on Lab A, "FHIR id at the reference lab"),
# creating that reference lab when it does not exist yet. It is safe to run
# again: a reference lab that already carries the id is left alone.
set -eu

LAB_A_URL=${LAB_A_URL:-https://oe-a:8443/api/OpenELIS-Global}
LAB_B_URL=${LAB_B_URL:-https://oe-b:8443/api/OpenELIS-Global}
OE_USER=${OE_USER:-admin}
OE_PASSWORD=${OE_PASSWORD:-$(cat /run/secrets/initial-admin-password 2>/dev/null || echo 'adminADMIN!')}
REFERENCE_LAB_NAME=${REFERENCE_LAB_NAME:-Uganda National Reference Laboratory}
REFERENCE_LAB_SHORT_NAME=${REFERENCE_LAB_SHORT_NAME:-UNRL}
WAIT_SECONDS=${WAIT_SECONDS:-900}
WORK=$(mktemp -d)

log() { echo "pair: $*"; }

login() {
    jar="$WORK/$1.jar"
    rm -f "$jar"
    code=$(curl -sk -o /dev/null -w '%{http_code}' -c "$jar" -b "$jar" \
        --data-urlencode "loginName=$OE_USER" --data-urlencode "password=$OE_PASSWORD" \
        "$2/ValidateLogin?apiCall=true") || code=000
    [ "$code" = 200 ] || return 1
    csrf=$(curl -sk -b "$jar" "$2/session" | sed -n 's/.*"csrf":"\([^"]*\)".*/\1/p')
    [ -n "$csrf" ] || return 1
    echo "$csrf" >"$WORK/$1.csrf"
}

wait_and_login() {
    waited=0
    until login "$1" "$2"; do
        if [ "$waited" -ge "$WAIT_SECONDS" ]; then
            log "$2 did not accept a login within ${WAIT_SECONDS}s"
            exit 1
        fi
        [ "$waited" = 0 ] && log "waiting for $2"
        sleep 10
        waited=$((waited + 10))
    done
    log "signed in to $2"
}

call() {
    lab=$1 base=$2 method=$3 path=$4
    shift 4
    curl -sk -b "$WORK/$lab.jar" -X "$method" -H "X-CSRF-Token: $(cat "$WORK/$lab.csrf")" \
        -H 'Content-Type: application/json' -H 'Accept: application/json' "$@" "$base$path"
}

urlencode() { printf '%s' "$1" | sed 's/ /%20/g'; }

field() { sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p"; }

row_id() {
    tr '{' '\n' | grep "\"shortName\":\"$1\"" | sed -n 's/^"id":"\([^"]*\)".*/\1/p' | head -n 1
}

wait_and_login b "$LAB_B_URL"
wait_and_login a "$LAB_A_URL"

this_lab=$(call b "$LAB_B_URL" GET /rest/locations/this-laboratory)
lab_b_name=$(printf '%s' "$this_lab" | field name)
lab_b_fhir_id=$(printf '%s' "$this_lab" | field fhirId)
[ -n "$lab_b_fhir_id" ] || { log "Lab B has no facility record yet"; exit 1; }
log "Lab B ${lab_b_name:+($lab_b_name) }facility FHIR id: $lab_b_fhir_id"

type_id=$(call a "$LAB_A_URL" GET /rest/locations/lists | tr '{' '\n' | grep '"referralLab"' |
    sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -n 1)
[ -n "$type_id" ] || { log "Lab A has no referralLab organization type"; exit 1; }

q=$(urlencode "$REFERENCE_LAB_NAME")
ref_id=$(call a "$LAB_A_URL" GET "/rest/locations/organizations?q=$q&status=all&pageSize=100" |
    row_id "$REFERENCE_LAB_SHORT_NAME")

body() {
    printf '{"kind":"facility","name":"%s","shortName":"%s","typeIds":["%s"],"identifiers":[],' \
        "$REFERENCE_LAB_NAME" "$REFERENCE_LAB_SHORT_NAME" "$type_id"
    printf '"referral":{"approvalStatus":"Approved","fhirId":"%s"}%s}' "$lab_b_fhir_id" "$1"
}

if [ -z "$ref_id" ]; then
    response=$(call a "$LAB_A_URL" POST /rest/locations/organizations -w '\n%{http_code}' -d "$(body '')")
else
    detail=$(call a "$LAB_A_URL" GET "/rest/locations/organizations/$ref_id")
    current=$(printf '%s' "$detail" | sed -n 's/.*"referral":{[^}]*"fhirId":"\([^"]*\)".*/\1/p')
    if [ "$current" = "$lab_b_fhir_id" ]; then
        log "Lab A's reference lab \"$REFERENCE_LAB_NAME\" already points at Lab B ($lab_b_fhir_id)"
        exit 0
    fi
    lastupdated=$(printf '%s' "$detail" | sed -n 's/.*"lastupdated":\([0-9]*\).*/\1/p')
    response=$(call a "$LAB_A_URL" PUT "/rest/locations/organizations/$ref_id" -w '\n%{http_code}' \
        -d "$(body ",\"id\":\"$ref_id\",\"lastupdated\":${lastupdated:-null}")")
fi

status=$(printf '%s' "$response" | tail -n 1)
case "$status" in
    200 | 201)
        log "Lab A's reference lab \"$REFERENCE_LAB_NAME\" now points at Lab B ($lab_b_fhir_id)"
        ;;
    *)
        log "saving the reference lab on Lab A answered $status:"
        printf '%s\n' "$response" | sed '$d'
        exit 1
        ;;
esac
