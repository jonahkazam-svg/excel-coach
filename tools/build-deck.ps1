# build-deck.ps1 - one-time generator for the practice deck.
# Reads your curriculum and asks the model to write flashcards/definitions/
# formulas for every topic, caching them to data\deck.json.
#
# Run once (uses your OPENAI_API_KEY from .env; makes one model call per topic,
# so it takes a few minutes and costs a little):
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\build-deck.ps1
# Rebuild from scratch later:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\build-deck.ps1 -Force
param([switch]$Force)
. (Join-Path $PSScriptRoot "deck.ps1")
Write-Host "Building the practice deck from your curriculum..."
Write-Host "(one model call per topic - this can take a few minutes; leave it running)"
try{
  if($Force){ $r=Build-Deck -Force } else { $r=Build-Deck }
  Write-Host ""
  Write-Host ("Done. Deck saved to: " + (Join-Path (Split-Path $PSScriptRoot -Parent) "data\deck.json"))
}catch{
  Write-Host ("Deck build failed: " + $_.Exception.Message)
}