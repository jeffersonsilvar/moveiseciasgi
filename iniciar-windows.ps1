# Móveis & Cia SGI — inicialização local Windows
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
  Write-Error "Node.js/npm não encontrado. Instale Node.js LTS antes de iniciar."
  exit 1
}
if (-not (Test-Path ".env.local")) {
  Write-Host "Falta .env.local. Copie .env.example e informe APENAS a chave publicável do projeto." -ForegroundColor Yellow
  exit 1
}
Write-Host "Instalando dependências..." -ForegroundColor Cyan
npm install
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Host "Verificando e compilando..." -ForegroundColor Cyan
npm run build
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Host "Abrindo servidor local..." -ForegroundColor Green
npm run dev
