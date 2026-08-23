# Agent Rules

## Go Backend Network

When starting or restarting the local Go/AList backend, MUST disable HTTP proxy use. Clear `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY` and their lowercase variants, and set both `NO_PROXY=*` and `no_proxy=*`. Verify its active TCP sockets do not connect to `127.0.0.1:7897`; the backend must connect directly to upstream services to avoid unnecessary proxy overhead during media streaming.
