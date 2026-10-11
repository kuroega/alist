# Develop on the AList VM from macOS

## Recommended connection

Connect directly from the Mac to the bridged VM:

```text
MacBook -- home LAN / TCP 22 --> Alpine VM (10.127.1.109)
                                  hosted by Windows / VMware Workstation
```

Inspection on 2026-10-11 confirmed:

- `AListBackend.vmx` uses `ethernet0.connectionType = "bridged"` on VMnet0.
- Windows Wi-Fi is `10.127.1.247`; the VM is `10.127.1.109/24`.
- The VM gateway is `10.127.1.254`, and SSH as `kuroega` works from Windows.
- The guest is Alpine Linux with Go 1.26.3 on linux/amd64; Delve is not installed.
- Production runs `/opt/alist/alist --data /var/lib/alist --log-std server`.

No Windows SSH server, Windows port proxy, or VMware NAT port forwarding is
needed. A script is optional; `alist-vm.sh` is a convenience wrapper for native
OpenSSH. Mac-to-VM connectivity still needs to be checked on the Mac.

Reserve `10.127.1.109` for VM MAC `00:0c:29:b4:5a:a4` in the router's DHCP
settings, after confirming the reservation does not conflict. The guest uses
DHCP, so otherwise its address may change. Keep Windows awake and the VM running.
Use the normal home Wi-Fi, with guest/client isolation disabled for these devices.

## First-time Mac setup

1. Check the network from macOS Terminal:

   ```sh
   nc -vz -G 5 10.127.1.109 22
   ```

2. Create a dedicated Mac key (do not overwrite an existing file):

   ```sh
   ssh-keygen -t ed25519 -f ~/.ssh/alist_vm_ed25519 -C alist-macbook
   cat ~/.ssh/alist_vm_ed25519.pub
   ```

   Choose a passphrase. Only the `.pub` content goes to the VM; private keys stay
   on their original computer and never go in Git.

3. On Windows, use the existing trusted connection:

   ```powershell
   ssh kuroega@10.127.1.109
   ```

   In that VM shell, run the following, paste the Mac's complete public-key line,
   then press Enter and Ctrl-D. This appends without replacing existing keys:

   ```sh
   umask 077
   mkdir -p ~/.ssh
   chmod 700 ~/.ssh
   cat >> ~/.ssh/authorized_keys
   chmod 600 ~/.ssh/authorized_keys
   ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
   ```

4. Back on the Mac, verify the VM host key before accepting it:

   ```sh
   ssh -o HostKeyAlgorithms=ssh-ed25519 -o IdentitiesOnly=yes \
     -i ~/.ssh/alist_vm_ed25519 kuroega@10.127.1.109
   ```

   The ED25519 fingerprint observed through the trusted Windows connection was
   `SHA256:ljHP0C6kDOSeNsGqb1Xiv8K3SOHHPscZrdP+zvMi1vc`. Compare with the current
   output from step 3; investigate unexpected changes instead of bypassing checks.

5. Merge this block into `~/.ssh/config` (do not overwrite other entries):

   ```sshconfig
   Host alist-vm
       HostName 10.127.1.109
       User kuroega
       Port 22
       IdentityFile ~/.ssh/alist_vm_ed25519
       IdentitiesOnly yes
       StrictHostKeyChecking yes
       ServerAliveInterval 30
       ServerAliveCountMax 3
   ```

   ```sh
   chmod 600 ~/.ssh/config
   ssh-add ~/.ssh/alist_vm_ed25519
   ssh alist-vm 'hostname; go version'
   ```

   Loading the key into the agent allows noninteractive commands with a
   passphrase-protected key. Reload it when necessary after logout/restart.

## Current working setup (verified 2026-10-11)

The Mac (`10.127.1.139` on `en0`) connects directly to the VM with key-only login:

- Key: `~/.ssh/alist_vm_ed25519` (comment `alist-macbook`, fingerprint
  `SHA256:r4u5M7L39pf/uMVLkI7Uw6WEYFRfSorXG6D/rXdZ/t0`), created without a
  passphrase so noninteractive commands work. To add one later:
  `ssh-keygen -p -f ~/.ssh/alist_vm_ed25519`, then
  `ssh-add --apple-use-keychain ~/.ssh/alist_vm_ed25519`.
- The public key was appended to the VM's `~/.ssh/authorized_keys` (the existing
  Windows key was kept) over a one-time password login; the password file was
  then deleted.
- `~/.ssh/config` contains exactly the `alist-vm` block from step 5.
- Host key in `~/.ssh/known_hosts` matches the ED25519 fingerprint above.

Verified with:

```sh
ssh -o BatchMode=yes -o PasswordAuthentication=no alist-vm 'hostname; go version'
ALIST_VM_HOST=alist-vm sh tools/macos/alist-vm.sh doctor
ssh alist-vm 'wget -qO- -T 5 http://127.0.0.1:5244/ping'   # prints: pong
```

Notes:

- Claude Code's Bash sandbox blocks LAN traffic and reports
  `No route to host` (even though ARP resolves the VM). Run SSH/`nc` commands to
  the VM with the sandbox disabled; a normal macOS Terminal is unaffected.
- From the Mac, ARP shows `10.127.1.109` at `3c:e9:f7:e7:a5:e0`, not the VM's
  `00:0c:29:b4:5a:a4`; VMware bridging over Wi-Fi likely presents the Windows
  Wi-Fi MAC. Check which MAC the router sees before creating the DHCP reservation.

## Repository helper

After pushing these files and pulling them on the Mac, run from the repository:

```sh
export ALIST_VM_HOST=alist-vm
sh tools/macos/alist-vm.sh doctor
sh tools/macos/alist-vm.sh shell
sh tools/macos/alist-vm.sh exec 'hostname; go version'
sh tools/macos/alist-vm.sh tunnel
```

The last command stays open; browse `http://127.0.0.1:15244` to reach the existing
VM service on port 5244. Ctrl-C closes the tunnel. Run only one tunnel using that
local port at a time. Forward establishment does not prove the destination HTTP
service is healthy; open the URL to check it.

Use `--dry-run` before a mode to inspect arguments. `exec` takes a single quoted
remote shell program and preserves its exit status. `doctor` and `exec` use
`BatchMode=yes`, so establish trust and load your key first. Environment overrides
are listed by `sh tools/macos/alist-vm.sh help`. The wrapper defaults to user
`kuroega` and port 22 even with an alias; set its environment variables if needed.

## Troubleshooting and alternatives

- Timeout: confirm the VM is running, its current IP, the Mac's Wi-Fi/subnet,
  router client isolation, and guest firewall access to TCP 22. A VPN may route
  `10.127.1.0/24` elsewhere. Windows-to-VM success does not test Mac Wi-Fi isolation.
- `Permission denied (publickey)`: verify the Mac public key is installed for
  `kuroega`, permissions are correct, and the matching key is selected/loaded.
- Host-key error: verify the fingerprint from the VM console or trusted Windows
  connection before updating the Mac's known_hosts entry.
- Local port in use: stop the previous tunnel or set
  `ALIST_VM_LOCAL_HTTP_PORT=15245` (and adjust the browser URL).
- If you later switch to VMware NAT, direct LAN access will require a different
  design: VMware NAT port forwarding or an SSH jump host on Windows. Neither is
  necessary for the currently verified bridged setup.
- For access away from home, a private overlay network installed directly in the
  VM and Mac is an option. Windows having Tailscale alone does not automatically
  make its bridged VM accessible through Tailscale.

References: [VMware networking modes](https://knowledge.broadcom.com/external/article/309842/understanding-networking-types-in-hosted.html),
[OpenSSH commands and forwarding](https://man.openbsd.org/ssh).
