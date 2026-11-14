
# ============================================================
# UTS SISTEM BASIS DATA TERDISTRIBUSI
# Kubernetes Deployment - Windows PowerShell 5.1+
#
# Menjalankan:
# - PostgreSQL Primary dan Read-Replica
# - Keycloak SSO
# - FastAPI Machine Learning
# - Kubernetes Service, ConfigMap, Secret, PVC, Ingress
#
# PENTING:
# Script ini hanya untuk deployment awal pada namespace baru.
# Jangan menjalankannya pada instalasi UTS yang sedang aktif.
# ============================================================

$ErrorActionPreference = 'Stop'

$ctx = 'kind-uts-sbdt'
$ns = 'uts-sbdt'

# ------------------------------------------------------------
# 1. VALIDASI FILE PROYEK
# ------------------------------------------------------------

$requiredFiles = @(
    '.env'
    'keycloak/realm.json'
    'postgres/01_init_primary.sh'
    'postgres/02_schema.sql'
    'postgres/standby.sh'
    'k8s/00-namespace.yaml'
    'k8s/01-services.yaml'
    'k8s/02-configmap-api.yaml'
    'k8s/03-postgres.yaml'
    'k8s/04-apps.yaml'
    'k8s/05-ingress.yaml'
)

foreach ($path in $requiredFiles) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "File tidak ditemukan: $path"
    }
}

Write-Host "FILE PROYEK LENGKAP" -ForegroundColor Green

# ------------------------------------------------------------
# 2. MEMBACA .ENV
# ------------------------------------------------------------

$values = @{}

Get-Content -LiteralPath '.env' | ForEach-Object {

    $line = $_.Trim()

    if ([string]::IsNullOrWhiteSpace($line)) {
        return
    }

    if ($line.StartsWith('#')) {
        return
    }

    if ($line -match '^([A-Z][A-Z0-9_]*)\s*=\s*(.*)$') {

        $key = $matches[1]
        $value = $matches[2].Trim()

        if ($values.ContainsKey($key)) {
            throw "Variabel duplikat pada .env: $key"
        }

        # Menghapus tanda petik pembungkus bila tersedia.
        if ($value.Length -ge 2) {

            $singleQuoted = (
                $value.StartsWith("'") -and
                $value.EndsWith("'")
            )

            $doubleQuoted = (
                $value.StartsWith('"') -and
                $value.EndsWith('"')
            )

            if ($singleQuoted -or $doubleQuoted) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }

        $values[$key] = $value
    }
}

$requiredKeys = @(
    'POSTGRES_USER'
    'POSTGRES_DB'
    'POSTGRES_PASSWORD'
    'REPL_PASSWORD'
    'KEYCLOAK_ADMIN'
    'KEYCLOAK_ADMIN_PASSWORD'
    'SBDT_DEMO_USER_PASSWORD'
)

foreach ($key in $requiredKeys) {

    if (
        -not $values.ContainsKey($key) -or
        [string]::IsNullOrWhiteSpace($values[$key])
    ) {
        throw "Variabel $key belum tersedia pada .env"
    }
}

if ($values['SBDT_DEMO_USER_PASSWORD'].Length -lt 12) {
    throw "Password demo harus memiliki minimal 12 karakter."
}

Write-Host "KONFIGURASI .ENV VALID" -ForegroundColor Green

# ------------------------------------------------------------
# 3. VALIDASI REALM KEYCLOAK
# ------------------------------------------------------------

$realm = Get-Content 'keycloak/realm.json' -Raw |
    ConvertFrom-Json

$client = @(
    $realm.clients |
    Where-Object { $_.clientId -eq 'sbdt-client' }
)

$demoUser = @(
    $realm.users |
    Where-Object { $_.username -eq 'mahasiswa' }
)

if ($client.Count -ne 1 -or $demoUser.Count -ne 1) {
    throw "Client atau user Keycloak tidak ditemukan secara unik."
}

$mapper = @(
    $client[0].protocolMappers |
    Where-Object { $_.name -eq 'audience-sbdt-api' }
)

if (
    $mapper.Count -ne 1 -or
    $mapper[0].config.'included.custom.audience' -ne 'sbdt-api'
) {
    throw "Audience Mapper Keycloak belum benar."
}

if (
    $demoUser[0].credentials[0].value -ne
    '${SBDT_DEMO_USER_PASSWORD}'
) {
    throw "Password placeholder Keycloak belum benar."
}

$accountRoles = @($demoUser[0].clientRoles.account)

if (
    'manage-account' -notin $accountRoles -or
    'view-profile' -notin $accountRoles
) {
    throw "Role akun demo Keycloak belum lengkap."
}

$appsManifest = Get-Content 'k8s/04-apps.yaml' -Raw

if (-not $appsManifest.Contains('SBDT_DEMO_USER_PASSWORD')) {
    throw "Deployment Keycloak belum menggunakan password demo."
}

Write-Host "KONFIGURASI REALM KEYCLOAK VALID" -ForegroundColor Green

# ------------------------------------------------------------
# 4. VALIDASI KUBERNETES CONTEXT
# ------------------------------------------------------------

$contexts = @(kubectl config get-contexts -o name)

if ($LASTEXITCODE -ne 0) {
    throw "Gagal membaca daftar Kubernetes Context."
}

if ($ctx -notin $contexts) {
    throw "Kubernetes Context $ctx tidak ditemukan."
}

# Pengaman: jangan menimpa namespace yang sudah ada.
$existingNamespace = kubectl --context $ctx `
    get namespace $ns --ignore-not-found -o name

if ($LASTEXITCODE -ne 0) {
    throw "Gagal memeriksa namespace Kubernetes."
}

if (-not [string]::IsNullOrWhiteSpace(
    [string]($existingNamespace -join '')
)) {
    throw "Namespace $ns sudah ada. Deployment dibatalkan untuk melindungi data."
}

Write-Host "PREFLIGHT KUBERNETES VALID" -ForegroundColor Green

# ------------------------------------------------------------
# 5. MEMBUAT NAMESPACE
# ------------------------------------------------------------

kubectl --context $ctx apply -f 'k8s/00-namespace.yaml'

if ($LASTEXITCODE -ne 0) {
    throw "Gagal membuat namespace."
}

# ------------------------------------------------------------
# 6. FUNGSI PEMBUATAN SECRET
# ------------------------------------------------------------

# Secret dikirim melalui stdin dalam format JSON.
# Nilai password tidak ditampilkan ke console atau dimasukkan
# sebagai argumen --from-literal pada command line.

function Apply-KubernetesSecret {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [hashtable]$SecretValues
    )

    $encodedData = @{}

    foreach ($entry in $SecretValues.GetEnumerator()) {

        $encodedData[$entry.Key] = (
            [Convert]::ToBase64String(
                [System.Text.Encoding]::UTF8.GetBytes(
                    [string]$entry.Value
                )
            )
        )
    }

    $secretObject = @{
        apiVersion = 'v1'
        kind = 'Secret'
        metadata = @{
            name = $Name
            namespace = $ns
        }
        type = 'Opaque'
        data = $encodedData
    }

    $secretJson = ConvertTo-Json `
        -InputObject $secretObject `
        -Depth 10 `
        -Compress

    $secretJson | kubectl --context $ctx -n $ns apply -f -

    if ($LASTEXITCODE -ne 0) {
        throw "Gagal membuat Secret: $Name"
    }
}

# ------------------------------------------------------------
# 7. POSTGRESQL SECRET
# ------------------------------------------------------------

Apply-KubernetesSecret `
    -Name 'sbdt-db-secret' `
    -SecretValues @{
        POSTGRES_USER = $values['POSTGRES_USER']
        POSTGRES_DB = $values['POSTGRES_DB']
        POSTGRES_PASSWORD = $values['POSTGRES_PASSWORD']
        REPL_PASSWORD = $values['REPL_PASSWORD']
    }

Write-Host "POSTGRESQL SECRET BERHASIL" -ForegroundColor Green

# ------------------------------------------------------------
# 8. KEYCLOAK SECRET
# ------------------------------------------------------------

Apply-KubernetesSecret `
    -Name 'sbdt-sso-secret' `
    -SecretValues @{
        KC_BOOTSTRAP_ADMIN_USERNAME = $values['KEYCLOAK_ADMIN']
        KC_BOOTSTRAP_ADMIN_PASSWORD = $values['KEYCLOAK_ADMIN_PASSWORD']
        SBDT_DEMO_USER_PASSWORD = $values['SBDT_DEMO_USER_PASSWORD']
    }

Write-Host "KEYCLOAK SECRET BERHASIL" -ForegroundColor Green

# ------------------------------------------------------------
# 9. CONFIGMAP POSTGRESQL PRIMARY
# ------------------------------------------------------------

kubectl --context $ctx -n $ns create configmap `
    sbdt-primary-init `
    --from-file="01_init_primary.sh=postgres/01_init_primary.sh" `
    --from-file="02_schema.sql=postgres/02_schema.sql" `
    --dry-run=client -o yaml |
    kubectl --context $ctx -n $ns apply -f -

if ($LASTEXITCODE -ne 0) {
    throw "Gagal membuat ConfigMap PostgreSQL Primary."
}

# ------------------------------------------------------------
# 10. CONFIGMAP POSTGRESQL REPLICA
# ------------------------------------------------------------

kubectl --context $ctx -n $ns create configmap `
    sbdt-standby-script `
    --from-file="standby.sh=postgres/standby.sh" `
    --dry-run=client -o yaml |
    kubectl --context $ctx -n $ns apply -f -

if ($LASTEXITCODE -ne 0) {
    throw "Gagal membuat ConfigMap PostgreSQL Replica."
}

# ------------------------------------------------------------
# 11. CONFIGMAP KEYCLOAK REALM
# ------------------------------------------------------------

kubectl --context $ctx -n $ns create configmap `
    sbdt-keycloak-realm `
    --from-file="realm.json=keycloak/realm.json" `
    --dry-run=client -o yaml |
    kubectl --context $ctx -n $ns apply -f -

if ($LASTEXITCODE -ne 0) {
    throw "Gagal membuat ConfigMap Keycloak."
}

Write-Host "SELURUH CONFIGMAP BERHASIL DIBUAT" -ForegroundColor Green

# ------------------------------------------------------------
# 12. KUBERNETES SERVICES DAN API CONFIGMAP
# ------------------------------------------------------------

kubectl --context $ctx -n $ns apply -f 'k8s/01-services.yaml'

if ($LASTEXITCODE -ne 0) {
    throw "Gagal menerapkan Kubernetes Services."
}

kubectl --context $ctx -n $ns apply -f 'k8s/02-configmap-api.yaml'

if ($LASTEXITCODE -ne 0) {
    throw "Gagal menerapkan API ConfigMap."
}

# ------------------------------------------------------------
# 13. DEPLOY POSTGRESQL STATEFULSET DAN PVC
# ------------------------------------------------------------

kubectl --context $ctx -n $ns apply -f 'k8s/03-postgres.yaml'

if ($LASTEXITCODE -ne 0) {
    throw "Gagal menerapkan PostgreSQL StatefulSet."
}

kubectl --context $ctx -n $ns rollout status `
    statefulset/db-primary --timeout=300s

if ($LASTEXITCODE -ne 0) {
    throw "PostgreSQL Primary belum Ready."
}

kubectl --context $ctx -n $ns rollout status `
    statefulset/db-replica --timeout=300s

if ($LASTEXITCODE -ne 0) {
    throw "PostgreSQL Replica belum Ready."
}

Write-Host "POSTGRESQL PRIMARY DAN REPLICA READY" -ForegroundColor Green

# ------------------------------------------------------------
# 14. DEPLOY KEYCLOAK DAN FASTAPI
# ------------------------------------------------------------

kubectl --context $ctx -n $ns apply -f 'k8s/04-apps.yaml'

if ($LASTEXITCODE -ne 0) {
    throw "Gagal menerapkan Deployment aplikasi."
}

kubectl --context $ctx -n $ns rollout status `
    deployment/keycloak --timeout=300s

if ($LASTEXITCODE -ne 0) {
    throw "Keycloak belum Ready."
}

kubectl --context $ctx -n $ns rollout status `
    deployment/sbdt-api --timeout=300s

if ($LASTEXITCODE -ne 0) {
    throw "FastAPI belum Ready."
}

Write-Host "KEYCLOAK DAN FASTAPI READY" -ForegroundColor Green

# ------------------------------------------------------------
# 15. TRAEFIK INGRESS
# ------------------------------------------------------------

# Traefik Ingress Controller harus sudah terinstal
# pada cluster sebelum aturan Ingress ini digunakan.

kubectl --context $ctx -n $ns apply -f 'k8s/05-ingress.yaml'

if ($LASTEXITCODE -ne 0) {
    throw "Gagal menerapkan Ingress."
}

# ------------------------------------------------------------
# 16. VERIFIKASI RESOURCE
# ------------------------------------------------------------

kubectl --context $ctx -n $ns get `
    pods,pvc,svc,ingress

if ($LASTEXITCODE -ne 0) {
    throw "Gagal melakukan verifikasi resource."
}

Write-Host ""
Write-Host "=======================================" -ForegroundColor Green
Write-Host "DEPLOYMENT KUBERNETES SELESAI" -ForegroundColor Green
Write-Host "=======================================" -ForegroundColor Green
Write-Host "Namespace : $ns"
Write-Host "Context   : $ctx"
Write-Host "PostgreSQL, Keycloak, dan FastAPI telah diterapkan."
