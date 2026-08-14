# Repository Instructions

## Android Emulator Admin Password

When interacting with the embedded Android backend admin account in the emulator, read the password from the repository root `.env` file using `ALIST_ANDROID_ADMIN_PASSWORD`.

Treat the root `.env` value as the source of truth. Do not guess, hardcode, or replace the emulator admin password with another value, and do not copy the secret into this file.
