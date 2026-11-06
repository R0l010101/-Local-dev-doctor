@echo off
rem ERP Doctor launcher for CMD and PowerShell (found via PATH).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0doctor.ps1" %*
