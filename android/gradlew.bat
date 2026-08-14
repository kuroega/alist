@ECHO OFF
SETLOCAL
WHERE gradle >NUL 2>NUL
IF NOT ERRORLEVEL 1 (
  gradle %*
  EXIT /B %ERRORLEVEL%
)

SET APP_HOME=%~dp0
SET GRADLE_VERSION=8.9
IF NOT DEFINED GRADLE_USER_HOME SET GRADLE_USER_HOME=%USERPROFILE%\.gradle
SET GRADLE_DIR=%GRADLE_USER_HOME%\wrapper\dists\alist-gradle-%GRADLE_VERSION%\gradle-%GRADLE_VERSION%
SET GRADLE_BIN=%GRADLE_DIR%\bin\gradle.bat

IF EXIST "%GRADLE_BIN%" GOTO runGradle
SET CACHE_DIR=%GRADLE_USER_HOME%\wrapper\dists\alist-gradle-%GRADLE_VERSION%
SET ARCHIVE=%TEMP%\alist-gradle-%GRADLE_VERSION%-%RANDOM%.zip
SET URL=https://services.gradle.org/distributions/gradle-%GRADLE_VERSION%-bin.zip
IF NOT EXIST "%CACHE_DIR%" MKDIR "%CACHE_DIR%"
WHERE curl >NUL 2>NUL
IF ERRORLEVEL 1 GOTO noCurl
curl.exe -fL --retry 3 --retry-delay 2 "%URL%" -o "%ARCHIVE%"
IF ERRORLEVEL 1 EXIT /B 1
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -LiteralPath '%ARCHIVE%' -DestinationPath '%TEMP%\alist-gradle-%GRADLE_VERSION%' -Force"
IF ERRORLEVEL 1 EXIT /B 1
IF EXIST "%GRADLE_DIR%" RMDIR /S /Q "%GRADLE_DIR%"
MOVE "%TEMP%\alist-gradle-%GRADLE_VERSION%\gradle-%GRADLE_VERSION%" "%GRADLE_DIR%" >NUL
DEL /Q "%ARCHIVE%" >NUL 2>NUL
GOTO runGradle

:noCurl
ECHO Gradle 8.9 is not cached and curl.exe is unavailable.
EXIT /B 1

:runGradle
CALL "%GRADLE_BIN%" %*
EXIT /B %ERRORLEVEL%
