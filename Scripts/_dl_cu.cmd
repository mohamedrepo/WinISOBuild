@echo off
setlocal
set FILE=D:\WimMount\Updates\windows11.0-kb5127648-x64_2b88d2d308adc938fcd4d2876a68ee0b2a3c4c09.msu
set URL=https://catalog.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/4225b261-8248-43e5-a808-34f3faafe3f6/public/windows11.0-kb5127648-x64_2b88d2d308adc938fcd4d2876a68ee0b2a3c4c09.msu
set TARGET=5308811935
set LOG=D:\WimMount\Logs\download-cu-task.log
:loop
for %%A in ("%FILE%") do set SZ=%%~zA
if %SZ% GEQ %TARGET% goto done
echo [%DATE% %TIME%] have %SZ% of %TARGET% >> "%LOG%"
"C:\Windows\System32\curl.exe" -sS -L -C - --retry 20 --retry-delay 5 --retry-all-errors -o "%FILE%" "%URL%" >> "%LOG%" 2>&1
timeout /t 5 /nobreak > nul
goto loop
:done
echo [%DATE% %TIME%] complete >> "%LOG%"
