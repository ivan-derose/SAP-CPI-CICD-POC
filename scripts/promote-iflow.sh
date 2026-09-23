#!/usr/bin/env bash
set -Eeuo pipefail

# Promozione da un progetto iFlow presente nel repository Git a SAP CPI.
# Uso: ./scripts/promote-iflow.sh <IFLOW_DIRECTORY> <SIT|UAT|PROD> [--dry-run]
# Legge cicd/artifact.json e cicd/<ambiente>.json dalla cartella iFlow.
# --dry-run lavora esclusivamente in locale e non contatta SAP CPI.
# Per il deploy servono CPI_API_URL, CPI_TOKEN_URL, CPI_CLIENT_ID,
# CPI_CLIENT_SECRET. Richiede resolve-iflow-config.py accanto allo script.

# Usage: scripts/promote-iflow.sh <IFLOW_DIRECTORY> <SIT|UAT|PROD> [--dry-run]
IFLOW="${1:-}"
ENVIRONMENT="${2:-}"
DRY_RUN=false
if [[ "${3:-}" == "--dry-run" ]]; then DRY_RUN=true; elif [[ -n "${3:-}" ]]; then echo "Opzione sconosciuta: $3" >&2; exit 2; fi

VERSION="${CPI_ARTIFACT_VERSION:-1.0.0}"
POLL_SECONDS="${CPI_POLL_SECONDS:-5}"
MAX_POLLS="${CPI_MAX_POLLS:-60}"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo; echo "==> $*"; }
cleanup() { if [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]]; then rm -rf "$WORKDIR"; fi; }
trap cleanup EXIT

for cmd in curl jq zip base64 python3; do command -v "$cmd" >/dev/null 2>&1 || die "Comando richiesto non trovato: $cmd"; done
[[ "$IFLOW" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ && "$IFLOW" != *..* ]] || die "Nome cartella iFlow non valido"
[[ "$ENVIRONMENT" =~ ^(SIT|UAT|PROD)$ ]] || die "Ambiente consentito: SIT, UAT oppure PROD"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
ARTIFACT_DIR="$REPO_ROOT/$IFLOW"
[[ -d "$ARTIFACT_DIR" && ! -L "$ARTIFACT_DIR" ]] || die "Cartella iFlow non trovata: $ARTIFACT_DIR"
ARTIFACT_JSON="$ARTIFACT_DIR/cicd/artifact.json"
CONFIG_JSON="$ARTIFACT_DIR/cicd/${ENVIRONMENT,,}.json"
[[ -f "$ARTIFACT_JSON" ]] || die "Manca $ARTIFACT_JSON"
[[ -f "$CONFIG_JSON" ]] || die "Manca $CONFIG_JSON"
[[ -f "$SCRIPT_DIR/resolve-iflow-config.py" ]] || die "Resolver non trovato in scripts/"

# Validate JSON before reading values, and require known OData-safe technical IDs.
jq -e --arg env "$ENVIRONMENT" '.source.artifactId | type == "string"' "$ARTIFACT_JSON" >/dev/null || die "source.artifactId non valido"
SOURCE_ID="$(jq -r '.source.artifactId // empty' "$ARTIFACT_JSON")"
SOURCE_PACKAGE="$(jq -r '.source.packageId // empty' "$ARTIFACT_JSON")"
TARGET_ID="$(jq -r --arg env "$ENVIRONMENT" '.targets[$env].artifactId // empty' "$ARTIFACT_JSON")"
TARGET_PACKAGE="$(jq -r --arg env "$ENVIRONMENT" '.targets[$env].packageId // empty' "$ARTIFACT_JSON")"
TARGET_NAME="$(jq -r --arg env "$ENVIRONMENT" '.targets[$env].artifactName // empty' "$ARTIFACT_JSON")"
VERSION="$(jq -r '.source.version // "1.0.0"' "$ARTIFACT_JSON")"
for id in "$SOURCE_ID" "$TARGET_ID" "$SOURCE_PACKAGE" "$TARGET_PACKAGE"; do
  [[ "$id" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] || die "Technical ID/package non valido: $id"
done
[[ -n "$TARGET_NAME" ]] || die "artifactName target mancante"
[[ "$VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "Versione artifact non valida"

WORKDIR="$(mktemp -d)"
TARGET_DIR="$WORKDIR/target"
TARGET_ZIP="$WORKDIR/target.zip"
CREATE_JSON="$WORKDIR/create.json"
UPDATE_JSON="$WORKDIR/update.json"
mkdir -p "$TARGET_DIR"

info "Packaging da Git: $IFLOW ($ENVIRONMENT)"
# Include only artifact content, not cicd/, .git, local caches, credentials etc.
python3 - "$ARTIFACT_DIR" "$TARGET_DIR" <<'PYTHON'
from pathlib import Path
import shutil, sys
source, target = map(Path, sys.argv[1:])
allowed = {'.project','metainfo.prop','META-INF','src'}
actual = {p.name for p in source.iterdir()} - {'cicd'}
extra = actual - allowed
if extra:
    raise SystemExit(f"Unknown top-level artifact entries (review packaging): {sorted(extra)}")
for name in allowed:
    path = source / name
    if not path.exists():
        if name in {'.project','META-INF','src'}:
            raise SystemExit(f"Required artifact entry missing: {name}")
        continue
    if path.is_symlink() or any(p.is_symlink() for p in ([path] if path.is_file() else path.rglob('*'))):
        raise SystemExit(f"Symlinks not allowed in artifact: {name}")
    if path.is_dir():
        shutil.copytree(path, target / name)
    else:
        shutil.copy2(path, target / name)
PYTHON

info "Validazione della configurazione $CONFIG_JSON"
RESOLVED_CONFIG="$WORKDIR/resolved-config.json"
python3 "$SCRIPT_DIR/resolve-iflow-config.py" "$TARGET_DIR" "$CONFIG_JSON" "$RESOLVED_CONFIG" || die "Configurazione non valida"

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
    if source_id != target_id:
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

if [[ "$DRY_RUN" == true ]]; then
  info "DRY RUN completato: nessun accesso o modifica al tenant CPI"
  exit 0
fi

for var in CPI_API_URL CPI_TOKEN_URL CPI_CLIENT_ID CPI_CLIENT_SECRET; do
  [[ -n "${!var:-}" ]] || die "Variabile ambiente mancante: $var"
done
API="${CPI_API_URL%/}/api/v1"
info "Autenticazione OAuth"
TOKEN_RESPONSE="$(curl -fsS -X POST "$CPI_TOKEN_URL" -u "$CPI_CLIENT_ID:$CPI_CLIENT_SECRET" -d 'grant_type=client_credentials')" || die "OAuth fallito"
TOKEN="$(jq -r '.access_token // empty' <<<"$TOKEN_RESPONSE")"
[[ -n "$TOKEN" ]] || die "Token OAuth assente"
auth_header=(-H "Authorization: Bearer $TOKEN")

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
echo "Source : Git / $IFLOW ($SOURCE_PACKAGE / $SOURCE_ID)"
echo "Target : $TARGET_PACKAGE / $TARGET_ID"
echo "Deploy : SUCCESS"
echo "Runtime: STARTED"
echo "============================================================"
