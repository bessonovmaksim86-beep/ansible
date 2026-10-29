<#
.SYNOPSIS
    Включает компоненты Windows, необходимые для WSL2 + дистрибутив Debian.

.DESCRIPTION
    Запускать в PowerShell ОТ АДМИНИСТРАТОРА:
        powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\enable-wsl2.ps1

    ВАЖНО: перед запуском WSL2 нужно включить аппаратную виртуализацию (SVM)
    в BIOS/UEFI — без неё WSL2 не стартует. Скрипт проверяет это и подсказывает.
    После включения компонентов потребуется ПЕРЕЗАГРУЗКА.

.NOTES
    Проверено на Windows 10 Pro (19044+), Windows 11.
#>

$ErrorActionPreference = 'Stop'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host "Нужны права администратора. Откройте PowerShell 'От имени администратора' и повторите." -ForegroundColor Red
    exit 1
}

Write-Host "`n=== 1. Проверка аппаратной виртуализации ===" -ForegroundColor Cyan
$cpu = Get-CimInstance Win32_Processor
$vmFW = $cpu.VirtualizationFirmwareEnabled
$slat = $cpu.SecondLevelAddressTranslationExtensions
Write-Host ("CPU: " + $cpu.Name)
Write-Host ("Виртуализация включена в BIOS (SVM/VT-x): " + $vmFW)
Write-Host ("SLAT (RVI/NPT) поддерживается:            " + $slat)

if ($vmFW -eq $false) {
    Write-Host @"

------------------------------------------------------------------
  АППАРАТНАЯ ВИРТУАЛИЗАЦИЯ ВЫКЛЮЧЕНА В BIOS/UEFI - WSL2 НЕ ЗАРАБОТАЕТ.

  1. Перезагрузитесь и войдите в BIOS (обычно DEL или F2 при старте).
  2. AMD Ryzen: найдите 'SVM Mode' / 'SVM Support'
     (обычно Advanced -> CPU Configuration) -> поставьте [Enabled].
     Intel:      'Intel Virtualization Technology (VT-x)' -> [Enabled].
  3. Заодно проверьте 'SVM Mode' и отключите опцию 'VirG'/'Secure Virtual
     Machine (SVM)' только если она конфликтует - обычно включать надо SVM.
  4. Сохраните (F10), загрузите Windows и запустите этот скрипт снова.
------------------------------------------------------------------
"@ -ForegroundColor Yellow
    Write-Host "Продолжить установку компонентов Windows (виртуализацию это НЕ включит)? [y/N]" -NoNewline
    if ((Read-Host) -notmatch '^[yY]') { exit 2 }
}

Write-Host "`n=== 2. Включение компонентов Windows ===" -ForegroundColor Cyan
$features = @(
    'Microsoft-Windows-Subsystem-Linux',   # ядро подсистемы Windows для Linux
    'VirtualMachinePlatform'               # платформа виртуальных машин (нужна для WSL2)
)
foreach ($f in $features) {
    $state = (Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction SilentlyContinue).State
    Write-Host ("{0,-40} {1}" -f $f, $state)
    if ($state -ne 'Enabled') {
        Enable-WindowsOptionalFeature -Online -FeatureName $f -NoRestart -All | Out-Null
        Write-Host "  -> включено" -ForegroundColor Green
    }
}

Write-Host "`n=== 3. WSL 2 по умолчанию + обновление ядра ===" -ForegroundColor Cyan
$wsl = "$env:SystemRoot\System32\wsl.exe"
& $wsl --set-default-version 2 2>&1 | Out-String
# Обновление ядра WSL2 (для Windows 10 19041+ ставится отдельно)
try { & $wsl --update 2>&1 | Out-String } catch { Write-Host "wsl --update недоступен - ядро поставится при установке дистрибутива" }

Write-Host "`n=== 4. Установка дистрибутива Debian ===" -ForegroundColor Cyan
$installed = (& $wsl --list --quiet 2>&1) | ForEach-Object { $_.Trim() } | Where-Object { $_ }
if ($installed -match 'debian') {
    Write-Host "Debian уже установлен." -ForegroundColor Green
} else {
    Write-Host "Устанавливаю Debian (нужен доступ к Microsoft Store / интернет)..." -ForegroundColor Yellow
    & $wsl --install -d Debian --no-launch
}

Write-Host @"

=== ДАЛЬНЕЙШИЕ ШАГИ ===
  1. ПЕРЕЗАГРУЗИТЕ компьютер (обязательно - компоненты требуют перезагрузки).
  2. После перезагрузки, если виртуализация была выключена - включите SVM в BIOS.
  3. Откройте 'Debian' из меню Пуск, придумайте логин/пароль (первый пользователь
     автоматически получит sudo).
  4. Внутри Debian выполните подготовку и прогон Ansible - см. docs/WSL2.md
"@ -ForegroundColor Cyan
