# Hito 3 – Laboratorio de Active Directory

## Limpiar-LabAD.ps1

Script para dejar el controlador de dominio (DC) limpio al terminar el Hito 3, si **no** se puede restaurar el snapshot `AD-base`:

- elimina las GPO creadas durante el hito (todas salvo *Default Domain Policy* y *Default Domain Controllers Policy*), después de guardar una copia de seguridad en `C:\BackupGPO\<fecha>`;
- quita el bloqueo de cuentas de la *Default Domain Policy*;
- desbloquea las cuentas bloqueadas;
- avisa de lo que hay que revisar a mano (usuarios con descripción, recursos compartidos del DC).

No deshace los cambios hechos a mano ni limpia las estaciones de trabajo. La vuelta atrás completa es el snapshot `AD-base`.

### Dónde se ejecuta

| Máquina | Qué hacer |
|---|---|
| **DC** (Windows Server 2022) | Ejecutar el script, en PowerShell **como administrador del dominio**. |
| **WS01 y WS02** (Windows 10) | No ejecutar el script. Después de limpiar el DC: `gpupdate /force` y reiniciar. |
| **Kali** | Nada. |

### Cómo se ejecuta (en el DC)

```powershell
cd $env:USERPROFILE\Desktop
Invoke-WebRequest -UseBasicParsing -Uri https://raw.githubusercontent.com/joseluispplu/Seguridad-en-Redes/main/Hito-3-Active-Directory/Limpiar-LabAD.ps1 -OutFile Limpiar-LabAD.ps1

# 1) Simulación: muestra lo que haría, sin cambiar nada
powershell -ExecutionPolicy Bypass -File .\Limpiar-LabAD.ps1

# 2) Si lo que muestra es correcto, aplicar los cambios
powershell -ExecutionPolicy Bypass -File .\Limpiar-LabAD.ps1 -Aplicar
```

Para recuperar una GPO borrada: `Restore-GPO -Name "<nombre>" -Path C:\BackupGPO\<fecha>`.
