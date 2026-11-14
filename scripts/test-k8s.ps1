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

$ErrorActionPreference='Stop'
$api='http://api.lokal:8088'
$oidc='http://auth.lokal:8088/realms/sbdt-uts'
Invoke-RestMethod "$api/health"
$token=Invoke-RestMethod -Uri "$oidc/protocol/openid-connect/token" -Method Post -Body @{
 grant_type='password'; client_id='sbdt-client'; username='mahasiswa'; password=$demoPassword
}
$headers=@{Authorization="Bearer $($token.access_token)"}
Invoke-RestMethod "$api/db/topology" -Headers $headers
$payload = @{nominal=12000000;gagal_login=4;usia_akun_hari=7;jam_transaksi=2} | ConvertTo-Json
Invoke-RestMethod "$api/predict" -Headers $headers -Method Post -ContentType 'application/json' -Body $payload
Invoke-RestMethod "$api/history" -Headers $headers
