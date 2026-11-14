# Membaca password demo Keycloak dari .env
$envFile = Join-Path (Split-Path -Parent $PSScriptRoot) '.env'

if (-not (Test-Path -LiteralPath $envFile -PathType Leaf)) {
    throw "File .env tidak ditemukan."
}

$demoEntries = @(
    Get-Content -LiteralPath $envFile |
    Where-Object {
        $_ -match '^\s*SBDT_DEMO_USER_PASSWORD\s*='
    }
)

if ($demoEntries.Count -ne 1) {
    throw "SBDT_DEMO_USER_PASSWORD harus ada tepat satu kali di .env."
}

$demoPassword = ($demoEntries[0] -split '=', 2)[1].Trim()

# Menghapus tanda petik pembungkus bila ada.
if ($demoPassword.Length -ge 2) {
    $singleQuoted = (
        $demoPassword.StartsWith("'") -and
        $demoPassword.EndsWith("'")
    )
    $doubleQuoted = (
        $demoPassword.StartsWith('"') -and
        $demoPassword.EndsWith('"')
    )

    if ($singleQuoted -or $doubleQuoted) {
        $demoPassword = $demoPassword.Substring(
            1, $demoPassword.Length - 2
        )
    }
}

if ([string]::IsNullOrWhiteSpace($demoPassword)) {
    throw "Password demo pada .env kosong."
}

# Jalankan setelah docker compose up -d --build selesai dan Keycloak siap.
$ErrorActionPreference = 'Stop'
$oidc='http://localhost:8081/realms/sbdt-uts'
$api='http://localhost:8000'
Write-Host 'Health endpoint:'
Invoke-RestMethod "$api/health" | ConvertTo-Json
Write-Host 'Verifikasi replika PostgreSQL:'
docker compose exec db-primary psql -U sbdtapp -d sbdt_uts -tAc 'SELECT pg_is_in_recovery()'
docker compose exec db-replica psql -U sbdtapp -d sbdt_uts -tAc 'SELECT pg_is_in_recovery()'
Write-Host 'Mengambil token Keycloak pengguna LAB...'
$token = Invoke-RestMethod -Uri "$oidc/protocol/openid-connect/token" -Method Post -Body @{
 grant_type='password';client_id='sbdt-client';username='mahasiswa';password=$demoPassword
}
$header=@{Authorization="Bearer $($token.access_token)"}
Write-Host 'Role database dari backend:'
Invoke-RestMethod "$api/db/topology" -Headers $header | ConvertTo-Json
Write-Host 'POST /predict ke primary:'
$payload = @{nominal=12000000;gagal_login=4;usia_akun_hari=7;jam_transaksi=2} | ConvertTo-Json
Invoke-RestMethod "$api/predict" -Method Post -Headers $header -ContentType 'application/json' -Body $payload | ConvertTo-Json
Write-Host 'GET /history dari standby (asynchronous, mungkin tertunda):'
Invoke-RestMethod "$api/history" -Headers $header | ConvertTo-Json -Depth 6
