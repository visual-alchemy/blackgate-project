# Client support access

How a Blackgate appliance is reached for support, who can do what, and how that access is taken away again.
Two files implement it: `iso-builder/autoinstall/user-data` (installs the doors and the keys) and
`iso-builder/files/support-authorized-keys` (the vendor's public key).

## Doors

| Door | Account | Auth | What it can do | Where it is logged |
| --- | --- | --- | --- | --- |
| Routine | dashboard, and the `blackgate` user over SSH | dashboard password / blackgate password | restart, power actions, deploy, system report through the dashboard helper; `journalctl -u blackgate` (the user is in `adm`); no sudo | `system_action` events, journal |
| Support (daily) | `bg-support` | SSH key only, password locked | full `sudo` (NOPASSWD) for debugging | `/var/log/auth.log`, sudo log |
| Break-glass | `root` | SSH key only; console password in `/root/blackgate-root-password.txt` | everything | `/var/log/auth.log` |

No account on the appliance carries a password that is identical across installations: `root` gets a random
password per install (console only, `PermitRootLogin prohibit-password`) and `bg-support` has its password locked.

## The key

- The public key lives in `iso-builder/files/support-authorized-keys`.
- The matching PRIVATE key (`bg-key.pem`) is held by the vendor and is deliberately not in this repository.
- Verify a local copy against the fingerprint recorded in that file:

      ssh-keygen -lf bg-key.pem
      # expect: 4096 SHA256:MJcEUrtUUd4GoUmG2WfZYO1mpbfN6CEco5xqmLbcHAk blackgate support key (RSA)

## Using it

    ssh -i bg-key.pem bg-support@<appliance>     # then `sudo -i` for a root shell
    ssh -i bg-key.pem root@<appliance>           # break-glass, direct root

## Revoking, on the appliance as root

    sed -i '/blackgate support key/d' /root/.ssh/authorized_keys /home/bg-support/.ssh/authorized_keys

That ends the access: `bg-support` keeps its sudo rule, but nobody can log in as it any more.

## Before handing an ISO to a client

- [ ] Confirm the key in `iso-builder/files/support-authorized-keys` is the intended one (fingerprint above).
- [ ] Agree with the client what happens to `/root/blackgate-root-password.txt`.
- [ ] Tell the client the revocation command above, and that logins are recorded in `/var/log/auth.log`.
- [ ] Optional upgrade for time-boxed access: an SSH CA (`TrustedUserCAKeys` plus principals) so each support
      session uses a short-lived certificate instead of a long-lived key.
