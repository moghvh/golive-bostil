@echo off
rem Duplo clique = Forge (patch encoder + forja op1 + play shim). Com argumentos:
rem   GoLive-Bostil.cmd -ForgeIp 8.8.8.8
rem   GoLive-Bostil.cmd -Mode Revert
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0GoLive-Bostil.ps1" %*
