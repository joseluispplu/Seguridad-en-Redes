<#
.SYNOPSIS
    Limpia el DC del laboratorio del Hito 3: elimina las GPO creadas durante el hito,
    quita el bloqueo de cuentas de la Default Domain Policy y desbloquea las cuentas.

.DESCRIPTION
    Por defecto NO cambia nada: solo muestra lo que haría. Para aplicar los cambios,
    ejecútalo con -Aplicar. Antes de borrar cada GPO hace una copia de seguridad
    (Backup-GPO) en -RutaBackup, de modo que se puede recuperar con Restore-GPO.

    Debe ejecutarse en el DC, en una consola de PowerShell como administrador del dominio.

    Limitaciones (para eso está el snapshot AD-base):
      - Solo limpia el DC. En las estaciones, algunas opciones de seguridad (p. ej. el
        aviso de inicio de sesión) quedan grabadas en el registro aunque se borre la GPO.
      - No deshace cambios hechos a mano: usuarios, grupos, recursos compartidos,
        contraseñas en el campo Descripción, ficheros copiados, etc.

.EXAMPLE
    .\Limpiar-LabAD.ps1              # simulación: muestra lo que haría
    .\Limpiar-LabAD.ps1 -Aplicar     # aplica los cambios
#>
[CmdletBinding()]
param(
    [switch]$Aplicar,
    [string]$RutaBackup = "C:\BackupGPO\$(Get-Date -Format 'yyyyMMdd_HHmmss')"
)

$ErrorActionPreference = 'Stop'
Import-Module GroupPolicy, ActiveDirectory

$dominio = Get-ADDomain
$modo = if ($Aplicar) { 'APLICANDO CAMBIOS' } else { 'SIMULACIÓN (usa -Aplicar para ejecutar)' }
Write-Host "`n=== Limpieza del laboratorio AD: $($dominio.DNSRoot) - $modo ===`n" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 1. GPO creadas durante el hito (todas menos las dos que vienen por defecto)
# ---------------------------------------------------------------------------
$porDefecto = @('Default Domain Policy', 'Default Domain Controllers Policy')
$gpos = @(Get-GPO -All | Where-Object { $porDefecto -notcontains $_.DisplayName })

Write-Host "[1] GPO que se eliminarán: $($gpos.Count)" -ForegroundColor Yellow
foreach ($g in $gpos) {
    $xml = [xml](Get-GPOReport -Guid $g.Id -ReportType Xml)
    $vinculos = @($xml.GPO.LinksTo | ForEach-Object { $_.SOMPath }) -join ', '
    if (-not $vinculos) { $vinculos = '(sin vincular)' }
    Write-Host ("    - {0}  ->  {1}" -f $g.DisplayName, $vinculos)
}

if ($Aplicar -and $gpos.Count -gt 0) {
    New-Item -ItemType Directory -Path $RutaBackup -Force | Out-Null
    foreach ($g in $gpos) {
        Backup-GPO -Guid $g.Id -Path $RutaBackup | Out-Null
        Remove-GPO -Guid $g.Id      # elimina la GPO y todos sus vínculos
        Write-Host "    Eliminada: $($g.DisplayName)" -ForegroundColor Green
    }
    Write-Host "    Copia de seguridad en: $RutaBackup"
}

# ---------------------------------------------------------------------------
# 2. Bloqueo de cuentas en la Default Domain Policy
#    Hay que cambiarlo en la propia GPO (GptTmpl.inf); si solo se cambia con
#    Set-ADDefaultDomainPasswordPolicy, la GPO lo vuelve a imponer en el
#    siguiente refresco.
# ---------------------------------------------------------------------------
$ddpGuid = '{31B2F340-016D-11D2-945F-00C04FB984F9}'
$gpoDir  = "\\$($dominio.DNSRoot)\SYSVOL\$($dominio.DNSRoot)\Policies\$ddpGuid"
$inf     = "$gpoDir\MACHINE\Microsoft\Windows NT\SecEdit\GptTmpl.inf"

$umbral = (Get-ADDefaultDomainPasswordPolicy).LockoutThreshold
Write-Host "`n[2] Umbral de bloqueo actual del dominio: $umbral" -ForegroundColor Yellow

$contenido = Get-Content -Path $inf -Encoding Unicode
$lineaBloqueo = $contenido | Where-Object { $_ -match '^\s*LockoutBadCount\s*=' }
$hayQueCambiar = ($umbral -ne 0) -or ($lineaBloqueo -and $lineaBloqueo -notmatch '=\s*0\s*$')

if (-not $hayQueCambiar) {
    Write-Host "    No hay bloqueo de cuentas configurado. Nada que hacer."
}
elseif (-not $Aplicar) {
    Write-Host "    Se pondría LockoutBadCount = 0 en la Default Domain Policy."
}
else {
    Copy-Item $inf "$inf.bak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    # Umbral a 0 y fuera la duración y el restablecimiento, que no tienen sentido sin umbral
    $nuevo = $contenido |
        Where-Object { $_ -notmatch '^\s*(ResetLockoutCount|LockoutDuration)\s*=' } |
        ForEach-Object { $_ -replace '^\s*LockoutBadCount\s*=.*$', 'LockoutBadCount = 0' }
    if (-not ($nuevo -match '^\s*LockoutBadCount\s*=')) {
        $i = [array]::IndexOf($nuevo, ($nuevo | Where-Object { $_ -match '^\[System Access\]' } | Select-Object -First 1))
        $nuevo = $nuevo[0..$i] + 'LockoutBadCount = 0' + $nuevo[($i + 1)..($nuevo.Count - 1)]
    }
    Set-Content -Path $inf -Value $nuevo -Encoding Unicode

    # Subir la versión de equipo de la GPO (AD y GPT.INI) para que se vuelva a aplicar
    $gpoAD = Get-ADObject -Identity "CN=$ddpGuid,CN=Policies,CN=System,$($dominio.DistinguishedName)" -Properties versionNumber
    $nuevaVersion = [int]$gpoAD.versionNumber + 1
    Set-ADObject -Identity $gpoAD -Replace @{ versionNumber = $nuevaVersion }
    $gptIni = "$gpoDir\GPT.INI"
    (Get-Content $gptIni) -replace '^Version=\d+', "Version=$nuevaVersion" | Set-Content $gptIni -Encoding ASCII

    # Aplicarlo ya en el objeto de dominio, sin esperar al refresco
    Set-ADDefaultDomainPasswordPolicy -Identity $dominio.DNSRoot -LockoutThreshold 0
    Write-Host "    Umbral de bloqueo puesto a 0 en la Default Domain Policy." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# 3. Cuentas bloqueadas
# ---------------------------------------------------------------------------
$bloqueadas = @(Search-ADAccount -LockedOut -UsersOnly)
Write-Host "`n[3] Cuentas bloqueadas: $($bloqueadas.Count)" -ForegroundColor Yellow
foreach ($u in $bloqueadas) {
    if ($Aplicar) { Unlock-ADAccount -Identity $u; Write-Host "    Desbloqueada: $($u.SamAccountName)" -ForegroundColor Green }
    else          { Write-Host "    - $($u.SamAccountName)" }
}

# ---------------------------------------------------------------------------
# 4. Avisos: cosas que el script no deshace pero conviene revisar
# ---------------------------------------------------------------------------
Write-Host "`n[4] Revisa a mano:" -ForegroundColor Yellow
$conDescripcion = @(Get-ADUser -Filter 'Description -like "*"' -Properties Description |
    Where-Object { $_.SamAccountName -notin @('Administrator', 'Administrador', 'Guest', 'Invitado', 'krbtgt', 'DefaultAccount') })
foreach ($u in $conDescripcion) {
    Write-Host ("    - Usuario {0} con descripción: '{1}'" -f $u.SamAccountName, $u.Description)
}
$recursos = @(Get-SmbShare | Where-Object { -not $_.Special -and $_.Name -notin @('NETLOGON', 'SYSVOL') })
foreach ($r in $recursos) {
    Write-Host ("    - Recurso compartido en el DC: {0} -> {1}" -f $r.Name, $r.Path)
}
Write-Host "    - En las estaciones: ejecuta 'gpupdate /force' y reinícialas."
Write-Host "      Las opciones de seguridad (aviso de inicio de sesión, etc.) pueden seguir"
Write-Host "      grabadas en el registro: la vuelta atrás completa es el snapshot AD-base.`n"
