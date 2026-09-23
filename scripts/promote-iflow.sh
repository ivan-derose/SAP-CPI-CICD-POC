#!/usr/bin/env bash
set -Eeuo pipefail

# promote-iflow.sh
#
# Promuove un SAP CPI Integration Flow da un artifact sorgente a uno target
# sullo stesso tenant/API endpoint, gestendo:
# - OAuth Client Credentials
# - download ZIP sorgente
# - cambio Technical ID nei metadati interni
# - CREATE o UPDATE dell'artifact target
# - configurazioni externalized via API
# - deploy
# - polling BuildAndDeployStatus
# - verifica Runtime STARTED
#
# Variabili ambiente richieste:
#   CPI_API_URL
#   CPI_TOKEN_URL
#   CPI_CLIENT_ID
#   CPI_CLIENT_SECRET
#
# Uso:
#   ./promote-iflow.sh \
#     <SOURCE_ID> \
#     <SOURCE_PACKAGE> \
#     <TARGET_ID> \
#     <TARGET_PACKAGE> \
#     <TARGET_NAME> \
#     [CONFIG_JSON]
#
# Esempio:
#   ./promote-iflow.sh \
#     Exchange_Return_Order_Event_Listener \
#     TestFCG \
#     Exchange_Return_Order_Event_Listener_SIT \
#     OrdersManagementSIT \
#     "Exchange Return Order Event Listener SIT" \
#     sit-config.json
#
# Formato CONFIG_JSON (v2, richiede resolve-iflow-config.py nella stessa cartella):
# {"parameters":{"SenderAddress":"/exchange-return-order-event-sit"},"inherit":[]}
# Uso --dry-run come settimo argomento per sola validazione read-only.
# Ogni chiave in parameters.prop deve comparire in parameters o in inherit.

SOURCE_ID="${1:-}"
SOURCE_PACKAGE="${2:-}"
TARGET_ID="${3:-}"
TARGET_PACKAGE="${4:-}"
TARGET_NAME="${5:-}"
CONFIG_JSON="${6:-}"
DRY_RUN=false
if [[ "${7:-}" == "--dry-run" ]]; then DRY_RUN=true; elif [[ -n "${7:-}" ]]; then echo "Opzione sconosciuta: $7" >&2; exit 2; fi

VERSION="${CPI_ARTIFACT_VERSION:-1.0.0}"
POLL_SECONDS="${CPI_POLL_SECONDS:-5}"
MAX_POLLS="${CPI_MAX_POLLS:-60}"

required_env=(
  CPI_API_URL
  CPI_TOKEN_URL
  CPI_CLIENT_ID
  CPI_CLIENT_SECRET
)

die() {
  echo "ERROR: $*" >&2
  exit 1
}

info() {
  echo
  echo "==> $*"
}

cleanup() {
  if [[ -n "${WORKDIR:-}" && -d "${WORKDIR:-}" ]]; then
    rm -rf "$WORKDIR"
  fi
}
trap cleanup EXIT

for cmd in curl jq unzip zip base64 python3; do
  command -v "$cmd" >/dev/null 2>&1 || die "Comando richiesto non trovato: $cmd"
done

for var in "${required_env[@]}"; do
  [[ -n "${!var:-}" ]] || die "Variabile ambiente non valorizzata: $var"
done

[[ -n "$SOURCE_ID" ]] || die "SOURCE_ID mancante"
[[ -n "$SOURCE_PACKAGE" ]] || die "SOURCE_PACKAGE mancante"
[[ -n "$TARGET_ID" ]] || die "TARGET_ID mancante"
[[ -n "$TARGET_PACKAGE" ]] || die "TARGET_PACKAGE mancante"
[[ -n "$TARGET_NAME" ]] || die "TARGET_NAME mancante"
[[ -n "$CONFIG_JSON" ]] || die "CONFIG_JSON obbligatorio: ogni parametro deve essere classificato"
[[ "$SOURCE_ID" != "$TARGET_ID" ]] || die "SOURCE_ID e TARGET_ID devono essere differenti"

if [[ -n "$CONFIG_JSON" && ! -f "$CONFIG_JSON" ]]; then
  die "File configurazione non trovato: $CONFIG_JSON"
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SCRIPT_DIR/resolve-iflow-config.py" ]] || die "resolve-iflow-config.py non trovato accanto allo script"
API="${CPI_API_URL%/}/api/v1"
WORKDIR="$(mktemp -d)"
SOURCE_ZIP="$WORKDIR/source.zip"
TARGET_DIR="$WORKDIR/target"
TARGET_ZIP="$WORKDIR/target.zip"
CREATE_JSON="$WORKDIR/create.json"
UPDATE_JSON="$WORKDIR/update.json"

info "Autenticazione OAuth"

TOKEN_RESPONSE="$(
  curl -sS -X POST \
    "$CPI_TOKEN_URL" \
    -u "$CPI_CLIENT_ID:$CPI_CLIENT_SECRET" \
    -d "grant_type=client_credentials"
)"

TOKEN="$(jq -r '.access_token // empty' <<<"$TOKEN_RESPONSE")"
[[ -n "$TOKEN" ]] || {
  echo "$TOKEN_RESPONSE" | jq . >&2 || true
  die "Impossibile ottenere access_token"
}

auth_header=(-H "Authorization: Bearer $TOKEN")

info "Verifica artifact sorgente"

SOURCE_META="$(
  curl -fsS \
    "$API/IntegrationDesigntimeArtifacts(Id='$SOURCE_ID',Version='$VERSION')" \
    "${auth_header[@]}" \
    -H "Accept: application/json"
)" || die "Artifact sorgente non trovato o non accessibile: $SOURCE_ID"

ACTUAL_SOURCE_PACKAGE="$(jq -r '.d.PackageId // empty' <<<"$SOURCE_META")"
SOURCE_NAME="$(jq -r '.d.Name // empty' <<<"$SOURCE_META")"

[[ "$ACTUAL_SOURCE_PACKAGE" == "$SOURCE_PACKAGE" ]] || \
  die "Il source artifact appartiene al package '$ACTUAL_SOURCE_PACKAGE', non a '$SOURCE_PACKAGE'"

echo "Source:  $SOURCE_ID"
echo "Package: $SOURCE_PACKAGE"
echo "Name:    $SOURCE_NAME"
echo "Version: $VERSION"

info "Download ZIP sorgente"

curl -fsS \
  "$API/IntegrationDesigntimeArtifacts(Id='$SOURCE_ID',Version='$VERSION')/\$value" \
  "${auth_header[@]}" \
  -o "$SOURCE_ZIP" \
  || die "Download artifact sorgente fallito"

unzip -q "$SOURCE_ZIP" -d "$TARGET_DIR"

[[ -f "$TARGET_DIR/META-INF/MANIFEST.MF" ]] || die "META-INF/MANIFEST.MF non trovato"
[[ -f "$TARGET_DIR/.project" ]] || die ".project non trovato"

info "Trasformazione Technical ID: $SOURCE_ID -> $TARGET_ID"

python3 - "$TARGET_DIR/META-INF/MANIFEST.MF" "$TARGET_DIR/.project" "$SOURCE_ID" "$TARGET_ID" <<'PY'
import sys
from pathlib import Path

manifest = Path(sys.argv[1])
project = Path(sys.argv[2])
source_id = sys.argv[3]
target_id = sys.argv[4]

for path in (manifest, project):
    text = path.read_text(encoding="utf-8")
    if source_id not in text:
        raise SystemExit(f"Technical ID sorgente non trovato in {path}")
    path.write_text(text.replace(source_id, target_id), encoding="utf-8")
PY

# Controlli di sicurezza sui metadati trasformati.
# Non cerchiamo semplicemente SOURCE_ID, perché il TARGET_ID può contenerlo
# come prefisso (es. Exchange_Return_Order_Event_Listener_SIT).
grep -Fq "Bundle-SymbolicName: $TARGET_ID;" "$TARGET_DIR/META-INF/MANIFEST.MF" \
  || die "Bundle-SymbolicName non aggiornato correttamente"

grep -Fq "Origin-Bundle-SymbolicName: $TARGET_ID" "$TARGET_DIR/META-INF/MANIFEST.MF" \
  || die "Origin-Bundle-SymbolicName non aggiornato correttamente"

grep -Fq "<name>$TARGET_ID</name>" "$TARGET_DIR/.project" \
  || die ".project non aggiornato correttamente"

info "Risoluzione e validazione configurazione target (prima di ogni modifica)"
RESOLVED_CONFIG="$WORKDIR/resolved-config.json"
python3 "$SCRIPT_DIR/resolve-iflow-config.py" "$TARGET_DIR" "$CONFIG_JSON" "$RESOLVED_CONFIG" \
  || die "Configurazione non valida: nessun aggiornamento eseguito"
if [[ "$DRY_RUN" == true ]]; then
  echo "DRY RUN: source scaricato, metadati trasformati e configurazione validata. Nessuna modifica a CPI."
  exit 0
fi

info "Creazione ZIP target"

(
  cd "$TARGET_DIR"
  zip -qr "$TARGET_ZIP" .
)

ARTIFACT_CONTENT="$(base64 -w 0 "$TARGET_ZIP")"

info "Verifica esistenza artifact target"

TARGET_HTTP_CODE="$(
  curl -sS \
    -o "$WORKDIR/target-meta.json" \
    -w "%{http_code}" \
    "$API/IntegrationDesigntimeArtifacts(Id='$TARGET_ID',Version='$VERSION')" \
    "${auth_header[@]}" \
    -H "Accept: application/json"
)"

case "$TARGET_HTTP_CODE" in
  200)
    TARGET_EXISTING_PACKAGE="$(jq -r '.d.PackageId // empty' "$WORKDIR/target-meta.json")"

    [[ "$TARGET_EXISTING_PACKAGE" == "$TARGET_PACKAGE" ]] || \
      die "Il target esiste ma appartiene al package '$TARGET_EXISTING_PACKAGE', non a '$TARGET_PACKAGE'"

    info "UPDATE artifact target esistente"

    jq -n \
      --arg name "$TARGET_NAME" \
      --arg content "$ARTIFACT_CONTENT" \
      '{
        Name: $name,
        ArtifactContent: $content
      }' > "$UPDATE_JSON"

    UPDATE_CODE="$(
      curl -sS \
        -o "$WORKDIR/update-response.txt" \
        -w "%{http_code}" \
        -X PUT \
        "$API/IntegrationDesigntimeArtifacts(Id='$TARGET_ID',Version='$VERSION')" \
        "${auth_header[@]}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        --data-binary @"$UPDATE_JSON"
    )"

    [[ "$UPDATE_CODE" =~ ^2 ]] || {
      cat "$WORKDIR/update-response.txt" >&2
      die "UPDATE fallito, HTTP $UPDATE_CODE"
    }
    ;;

  404)
    info "CREATE nuovo artifact target"

    jq -n \
      --arg id "$TARGET_ID" \
      --arg name "$TARGET_NAME" \
      --arg package "$TARGET_PACKAGE" \
      --arg content "$ARTIFACT_CONTENT" \
      '{
        Id: $id,
        Name: $name,
        PackageId: $package,
        ArtifactContent: $content
      }' > "$CREATE_JSON"

    CREATE_CODE="$(
      curl -sS \
        -o "$WORKDIR/create-response.txt" \
        -w "%{http_code}" \
        -X POST \
        "$API/IntegrationDesigntimeArtifacts" \
        "${auth_header[@]}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        --data-binary @"$CREATE_JSON"
    )"

    [[ "$CREATE_CODE" =~ ^2 ]] || {
      cat "$WORKDIR/create-response.txt" >&2
      die "CREATE fallito, HTTP $CREATE_CODE"
    }
    ;;

  *)
    cat "$WORKDIR/target-meta.json" >&2 || true
    die "Errore verificando il target, HTTP $TARGET_HTTP_CODE"
    ;;
esac

if [[ -s "$RESOLVED_CONFIG" ]]; then
  info "Applicazione configurazioni externalized"

  while IFS= read -r item; do
    KEY="$(jq -r '.key // empty' <<<"$item")"
    VALUE="$(jq -r '.value // empty' <<<"$item")"
    DATATYPE="$(jq -r '.dataType // "xsd:string"' <<<"$item")"

    [[ -n "$KEY" ]] || die "Configurazione senza key"

    echo " - Applico parametro: $KEY ($DATATYPE) [valore non mostrato]"

    BODY="$(
      jq -n \
        --arg key "$KEY" \
        --arg value "$VALUE" \
        --arg datatype "$DATATYPE" \
        '{
          ParameterKey: $key,
          ParameterValue: $value,
          DataType: $datatype
        }'
    )"

    CONFIG_CODE="$(
      curl -sS \
        -o "$WORKDIR/config-response.txt" \
        -w "%{http_code}" \
        -X PUT \
        "$API/IntegrationDesigntimeArtifacts(Id='$TARGET_ID',Version='$VERSION')/\$links/Configurations('$KEY')" \
        "${auth_header[@]}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d "$BODY"
    )"

    [[ "$CONFIG_CODE" =~ ^2 ]] || {
      cat "$WORKDIR/config-response.txt" >&2
      die "Configurazione '$KEY' fallita, HTTP $CONFIG_CODE"
    }

  done < <(jq -c '.[]' "$RESOLVED_CONFIG")
fi

info "Deploy artifact target"

TASK_ID="$(
  curl -fsS -X POST \
    "$API/DeployIntegrationDesigntimeArtifact?Id='$TARGET_ID'&Version='$VERSION'" \
    "${auth_header[@]}" \
    -H "Accept: application/json"
)" || die "Richiesta di deploy fallita"

TASK_ID="$(printf '%s' "$TASK_ID" | tr -d '\r\n[:space:]')"
[[ -n "$TASK_ID" ]] || die "TaskId vuoto"

echo "TaskId: $TASK_ID"

info "Polling BuildAndDeployStatus"

FINAL_STATUS=""
for ((i=1; i<=MAX_POLLS; i++)); do
  STATUS_RESPONSE="$(
    curl -fsS \
      "$API/BuildAndDeployStatus(TaskId='$TASK_ID')" \
      "${auth_header[@]}" \
      -H "Accept: application/json"
  )" || die "Impossibile leggere BuildAndDeployStatus"

  STATUS="$(jq -r '.d.Status // empty' <<<"$STATUS_RESPONSE")"
  echo "[$i/$MAX_POLLS] Status: ${STATUS:-UNKNOWN}"

  case "$STATUS" in
    SUCCESS)
      FINAL_STATUS="$STATUS"
      break
      ;;
    FAIL|FAIL_ON_LICENSE_ERROR)
      echo "$STATUS_RESPONSE" | jq . >&2
      die "Deploy terminato con stato $STATUS"
      ;;
    DEPLOYING|"")
      sleep "$POLL_SECONDS"
      ;;
    *)
      sleep "$POLL_SECONDS"
      ;;
  esac
done

[[ "$FINAL_STATUS" == "SUCCESS" ]] || \
  die "Timeout: deploy non concluso dopo $MAX_POLLS tentativi"

info "Verifica runtime"

RUNTIME_RESPONSE="$(
  curl -fsS \
    "$API/IntegrationRuntimeArtifacts('$TARGET_ID')" \
    "${auth_header[@]}" \
    -H "Accept: application/json"
)" || die "Artifact runtime non trovato"

RUNTIME_STATUS="$(jq -r '.d.Status // empty' <<<"$RUNTIME_RESPONSE")"

echo "Runtime status: $RUNTIME_STATUS"

[[ "$RUNTIME_STATUS" == "STARTED" ]] || {
  echo "$RUNTIME_RESPONSE" | jq . >&2
  die "Runtime non STARTED"
}

echo
echo "============================================================"
echo "PROMOTION COMPLETATA"
echo "Source : $SOURCE_PACKAGE / $SOURCE_ID"
echo "Target : $TARGET_PACKAGE / $TARGET_ID"
echo "Deploy : SUCCESS"
echo "Runtime: STARTED"
echo "============================================================"
