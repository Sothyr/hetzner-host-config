<#
.SYNOPSIS
  Signs an SSH key with the user CA. Login on the hosts works only with such a certificate.

.EXAMPLE
  # Once: create the CA (keep the private key offline or in a password manager)
  .\scripts\ssh-sign.ps1 -InitCa

  # Your daily login, valid 12 hours
  .\scripts\ssh-sign.ps1 -Key $HOME\.ssh\id_ed25519 -Identity florian -Principals florian -Validity +12h

  # Key of OpenTofu, principal of the bootstrap user
  .\scripts\ssh-sign.ps1 -Key $HOME\.ssh\hhc_deploy -Identity tofu -Principals hhc-deploy -Validity +8h
#>
param(
  [string]$Ca = "$HOME\.ssh\hhc_user_ca",
  [string]$Key,
  [string]$Identity,
  [string]$Principals,
  [string]$Validity = "+12h",
  [switch]$InitCa
)

$ErrorActionPreference = "Stop"

if ($InitCa) {
  if (Test-Path $Ca) { throw "CA $Ca exists already." }
  ssh-keygen -t ed25519 -f $Ca -C "hhc-user-ca"
  Write-Host "Public key for ssh.user_ca_public_keys:"
  Get-Content "$Ca.pub"
  exit 0
}

if (-not $Key -or -not $Identity -or -not $Principals) { throw "Key, Identity and Principals are required." }
if (-not (Test-Path $Ca)) { throw "CA $Ca not found." }

if (-not (Test-Path $Key)) {
  ssh-keygen -t ed25519 -f $Key -C $Identity
}

ssh-keygen -s $Ca -I $Identity -n $Principals -V $Validity "$Key.pub"
if ($LASTEXITCODE -ne 0) { throw "Signing failed." }
ssh-keygen -L -f "$Key-cert.pub"
