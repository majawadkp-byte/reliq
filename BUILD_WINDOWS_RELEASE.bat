@echo off
setlocal EnableExtensions
cd /d "%~dp0"

echo ==============================================
echo  RELIQ Solutions V2.3.1 - Windows Release Build
echo ==============================================

where flutter >nul 2>nul
if errorlevel 1 (
  echo Flutter was not found in PATH.
  exit /b 1
)

call flutter config --enable-windows-desktop
if not exist windows (
  echo Creating the Windows runner...
  call flutter create --platforms=windows .
  if errorlevel 1 exit /b 1
)

if exist test\widget_test.dart del /q test\widget_test.dart
if exist test rmdir test 2>nul

if exist release_assets\windows\app_icon.ico copy /y release_assets\windows\app_icon.ico windows\runner\resources\app_icon.ico >nul

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$p='windows\CMakeLists.txt'; if(Test-Path $p){$s=Get-Content $p -Raw; $s=$s -replace 'set\(BINARY_NAME \"[^\"]+\"\)','set(BINARY_NAME \"RELIQ_Solutions\")'; Set-Content $p $s -NoNewline};" ^
  "$p='windows\runner\main.cpp'; if(Test-Path $p){$s=Get-Content $p -Raw; $s=$s -replace 'CreateAndShow\(L\"[^\"]+\"','CreateAndShow(L\"RELIQ Solutions\"'; Set-Content $p $s -NoNewline};" ^
  "$p='windows\runner\Runner.rc'; if(Test-Path $p){$s=Get-Content $p -Raw; $s=$s -replace 'VALUE \"FileDescription\", \"[^\"]*\"','VALUE \"FileDescription\", \"RELIQ Solutions\"'; $s=$s -replace 'VALUE \"InternalName\", \"[^\"]*\"','VALUE \"InternalName\", \"RELIQ_Solutions\"'; $s=$s -replace 'VALUE \"OriginalFilename\", \"[^\"]*\"','VALUE \"OriginalFilename\", \"RELIQ_Solutions.exe\"'; $s=$s -replace 'VALUE \"ProductName\", \"[^\"]*\"','VALUE \"ProductName\", \"RELIQ Solutions\"'; $s=$s -replace 'VALUE \"LegalCopyright\", \"[^\"]*\"','VALUE \"LegalCopyright\", \"Copyright (C) 2026 RELIQ Solutions. All rights reserved.\"'; Set-Content $p $s -NoNewline}"
if errorlevel 1 exit /b 1

call flutter clean
call flutter pub get
call flutter build windows --release
if errorlevel 1 exit /b 1

set "BUILT=build\windows\x64\runner\Release"
if not exist "%BUILT%\RELIQ_Solutions.exe" (
  echo RELIQ_Solutions.exe was not found after build.
  exit /b 1
)

if not exist dist mkdir dist
if exist "dist\RELIQ_Solutions_Windows" rmdir /s /q "dist\RELIQ_Solutions_Windows"
xcopy "%BUILT%" "dist\RELIQ_Solutions_Windows\" /E /I /Y >nul
if exist "dist\RELIQ_Solutions_Windows.zip" del /q "dist\RELIQ_Solutions_Windows.zip"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Compress-Archive -Path 'dist\RELIQ_Solutions_Windows\*' -DestinationPath 'dist\RELIQ_Solutions_Windows.zip' -Force"

echo.
echo DONE
echo EXE: dist\RELIQ_Solutions_Windows\RELIQ_Solutions.exe
echo ZIP: dist\RELIQ_Solutions_Windows.zip
echo IMPORTANT: distribute the whole Windows folder or ZIP, not only the EXE, because Flutter also needs its DLL and data files.
endlocal
