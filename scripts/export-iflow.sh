#!/usr/bin/env bash
set -Eeuo pipefail

# Esporta un iFlow da CPI DEV nella cartella Git corrispondente.
# Uso: ./scripts/export-iflow.sh <cartella-iflow> [--version 1.0.0]
# Esempio: ./scripts/export-iflow.sh Exchange_Return_Order_Event_Listener
# Richiede: curl, jq, python3, git; CPI_API_URL, CPI_TOKEN_URL,
# CPI_CLIENT_ID, CPI_CLIENT_SECRET. Non esegue commit né push.

fail() { printf 'ERRORE: %s\n' "$*" >&2; exit 1; }
for bin in curl jq python3 git; do command -v "$bin" >/dev/null || fail "Manca $bin"; done
[[ $# -eq 1 || $# -eq 3 ]] || fail 'Uso: export-iflow.sh <cartella-iflow> [--version VERSIONE]'
FLOW_DIR="$1"
[[ "$FLOW_DIR" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || fail 'Specificare il nome della cartella, senza percorsi.'
VERSION=""
if [[ $# -eq 3 ]]; then
  [[ "$2" == '--version' ]] || fail 'Atteso --version'
  VERSION="$3"
fi
for var in CPI_API_URL CPI_TOKEN_URL CPI_CLIENT_ID CPI_CLIENT_SECRET; do
  [[ -n "${!var:-}" ]] || fail "Variabile $var mancante"
done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TARGET="$ROOT/$FLOW_DIR"
CONFIG="$TARGET/cicd/artifact.json"
[[ -d "$TARGET" ]] || fail "Cartella inesistente: $TARGET"
[[ -f "$CONFIG" ]] || fail "Configurazione mancante: $CONFIG"
git -C "$ROOT" rev-parse --show-toplevel >/dev/null 2>&1 || fail 'La cartella non è in un repository Git.'
# Vietiamo la sovrascrittura di modifiche locali nell'iFlow selezionato.
[[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=all -- "$FLOW_DIR")" ]] || \
  fail "La cartella $FLOW_DIR ha modifiche locali; esegui commit/stash prima dell'export."
SOURCE_ID="$(jq -er '.source.artifactId | select(type == "string" and length > 0)' "$CONFIG")" || fail 'source.artifactId assente'
SOURCE_PACKAGE="$(jq -er '.source.packageId | select(type == "string" and length > 0)' "$CONFIG")" || fail 'source.packageId assente'
if [[ -z "$VERSION" ]]; then
  VERSION="$(jq -r '.source.version // "1.0.0"' "$CONFIG")"
fi
[[ "$SOURCE_ID" =~ ^[A-Za-z0-9_.-]+$ && "$VERSION" =~ ^[A-Za-z0-9_.-]+$ ]] || fail 'ID/versione non validi.'
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
API="${CPI_API_URL%/}/api/v1"
printf 'Richiesta token OAuth...\n'
TOKEN="$(curl --fail-with-body -sS -X POST "$CPI_TOKEN_URL" \
  -u "$CPI_CLIENT_ID:$CPI_CLIENT_SECRET" -d 'grant_type=client_credentials' | jq -er '.access_token')" \
  || fail 'Autenticazione fallita'
ENTITY="IntegrationDesigntimeArtifacts(Id='$SOURCE_ID',Version='$VERSION')"
printf 'Verifica artifact %s, package %s, versione %s...\n' "$SOURCE_ID" "$SOURCE_PACKAGE" "$VERSION"
curl --fail-with-body -sS "$API/$ENTITY" \
  -H "Authorization: Bearer $TOKEN" -H 'Accept: application/json' -o "$TMP/metadata.json" \
  || fail 'Lettura metadati non riuscita'
ACTUAL_PACKAGE="$(jq -r '.d.PackageId // empty' "$TMP/metadata.json")"
[[ "$ACTUAL_PACKAGE" == "$SOURCE_PACKAGE" ]] || fail "Package diverso: CPI=$ACTUAL_PACKAGE Git=$SOURCE_PACKAGE"
printf 'Download ZIP da CPI DEV...\n'
curl --fail-with-body -sS "$API/$ENTITY/\$value" \
  -H "Authorization: Bearer $TOKEN" -o "$TMP/source.zip" \
  || fail 'Download ZIP non riuscito'
# Verifica archivio e prepara la copia senza alterare il progetto Git.
python3 - "$TMP/source.zip" "$TMP/extracted" "$SOURCE_ID" <<'PY'
import sys, zipfile, pathlib, stat, xml.etree.ElementTree as ET
archive, dest, expected_id = sys.argv[1:]
root = pathlib.Path(dest)
allowed = {'.project', 'metainfo.prop', 'META-INF', 'src'}
with zipfile.ZipFile(archive) as z:
    names = z.namelist()
    if not names or z.testzip() is not None:
        raise SystemExit('ZIP danneggiato o vuoto')
    for info in z.infolist():
        p = pathlib.PurePosixPath(info.filename)
        if p.is_absolute() or '..' in p.parts or '\\' in info.filename or p.parts[0] not in allowed:
            raise SystemExit(f'Voce ZIP non prevista: {info.filename}')
        if stat.S_ISLNK(info.external_attr >> 16):
            raise SystemExit('ZIP contiene un link simbolico non consentito')
    z.extractall(root)
project = root / '.project'
manifest = root / 'META-INF' / 'MANIFEST.MF'
if not project.is_file() or not manifest.is_file() or not (root / 'src').is_dir():
    raise SystemExit('ZIP non contiene un progetto CPI completo')
project_id = ET.parse(project).getroot().findtext('name')
if project_id != expected_id:
    raise SystemExit(f'ID nel file .project inatteso: {project_id!r}')
print(f'ZIP verificato: {len(names)} voci; technical ID: {project_id}')
PY
# Verifica che Git non sia cambiato durante il download.
[[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=all -- "$FLOW_DIR")" ]] || \
  fail 'Modifiche locali rilevate durante il download; export annullato.'
# Aggiorna SOLO gli elementi di proprietà SAP. Preserva cicd/, README e altri file del progetto.
python3 - "$TMP/extracted" "$TARGET" <<'PY'
import pathlib, shutil, sys
src, dest = (pathlib.Path(p) for p in sys.argv[1:])
for name in ('.project', 'metainfo.prop', 'META-INF', 'src'):
    incoming = src / name
    existing = dest / name
    if existing.is_dir() and not existing.is_symlink():
        shutil.rmtree(existing)
    elif existing.exists() or existing.is_symlink():
        existing.unlink()
    if incoming.is_dir():
        shutil.copytree(incoming, existing)
    elif incoming.is_file():
        shutil.copy2(incoming, existing)
print('File SAP sincronizzati: .project, metainfo.prop, META-INF/, src/')
PY
printf '\nExport completato. Controlla le modifiche prima del commit:\n'
git -C "$ROOT" status --short -- "$FLOW_DIR"
printf '\nVerifica: git diff -- %s\n' "$FLOW_DIR"
