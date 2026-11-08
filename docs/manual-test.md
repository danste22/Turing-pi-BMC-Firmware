# Manual test — current image

Board is booted from the image that pins bmcd `f3b8f37` (crate `2.4.0`) and BMC-UI `v3.3.8`. Browser is `https://<bmc>/`. SSH user is the board login.

Stop on the first failure. Firmware Upgrade, Flash Node, Reset Network, and Reboot change the board. Run those last.

## Versions

1. Open the UI. The header shows **firmware version** and a hostname. It does not say daemon.
2. Open **About**.
   - Firmware version matches `cat /etc/os-release` on the board (`VERSION=`).
   - Daemon version is `v2.4.0`.
   - BMC UI is `v3.3.8`.
   - Buildroot release is `2026.08`.
   - Build time is a date, not blank.

## Login

1. Log out. Open `https://<bmc>/login?redirect=https://evil.example`. After a good login the address is `/info`, not the external site.
2. Wrong password shows "Invalid username or password".
3. Log in with **Remember me** checked. Close the browser and open the UI again. The session is still logged in.
4. Log out, log in with **Remember me** unchecked, close the browser, open the UI again. The login page is back.
5. Change language and theme. The labels follow the language. Reload keeps both.

## Info

1. Storage rows show a used/total bar for each device.
2. **Backup User Data** downloads a file whose name ends in `.tar.gz` and does not contain `..` or a slash. The toast says the download succeeded.
3. If a fan slider is present, move it and release. The percent stays at the new value after reload.
4. **Network Interfaces** lists BMC kernel devices that have an address. `node1`–`node4` here are the switch ports on the BMC, not the operating systems on the modules. `br0` is present. `eth0`, `br0`, `ge0`, `ge1`, and `node1`–`node4` show the same factory MAC. That is the DSA conduit address. `bond0`, while it is down, keeps a different local MAC.
5. On **Info**, in the **BMC** section, the button next to **Reboot** is **Reload Daemon**. Press it. The notice says "The BMC daemon is reloading...". After it returns, **About** still shows daemon `v2.4.0` and the Nodes page still loads.

## Nodes

1. Each populated slot shows a name and a power state.
2. Toggle one node off, confirm, and wait until the UI says it was powered off. Toggle it back on and confirm it was powered on.
3. **Restart** that node and confirm the restart notice.
4. **Edit** a node name, **Save**, and reload. The new name is still there. Restore the original name.

## USB

1. Note the current USB mode.
2. Set **Host** and **Change**. The success dialog appears. Set it back to the original mode and **Change** again.
3. If a module that supports USB flash is installed, set **Flash**, pick that node, and **Change**. Confirm the host sees the module on the USB_OTG port, then return the mode to **Device**.

## Firmware Upgrade and Flash Node

Do not run these against a module you cannot reinstall.

1. On **Firmware Upgrade**, type `ftp://example.com/a.tpu` and **Upgrade**. The form rejects it. Same for a value that is not an `http` or `https` URL.
2. Type a 63-character string in SHA-256. The form rejects it. A 64-character hex string is accepted as a checksum.
3. On **Flash Node**, the same URL and SHA-256 checks apply to the file and checksum fields.
4. Optional: upgrade with a known-good `.tpu` of this image, local file or `https` URL. The progress line reaches the success dialog. A failed write shows the error text, not a green completed bar.
5. Optional: install a known-good node image on one node. The progress line names that node and ends on the success dialog.

## Reset and reboot

1. **Info** → **Reset Network**. Confirm `br0` gets an address again and the UI loads.
2. **Info** → **Reboot** and confirm. The board returns, the UI login works, and **About** versions are unchanged.

## Hardware script

On the board the same file is `/usr/share/tp2/hw-validate.sh`. `/work/tp2bmc/board/tp2bmc/overlay/usr/share/tp2/hw-validate.sh` is the copy in the build tree.

Run it as root. `tcpdump`, the EEPROM file, and `hwclock` fail for a normal login, and `tee` cannot create `/tmp/hw-validate.log` in that case.

```sh
sudo sh -c 'EXPECTED_KERNEL=6.18.50 /usr/share/tp2/hw-validate.sh --mac <factory-mac> | tee /tmp/hw-validate.log'
echo exit:$?
```

Pass is exit 0 and no `FAIL` lines. `WARN` lines are recorded, not ignored. `SKIP` on section M is expected until you pass `--mode`.

On a flat board, `bond0` can exist and stay down while `ge0` and `ge1` belong to `br0`. Section G then warns that `ge0`/`ge1` are not on `bond0`. That warning matches this layout. Assert the layout with `--mode 1`.

```sh
sudo sh -c 'EXPECTED_KERNEL=6.18.50 /usr/share/tp2/hw-validate.sh --mac <factory-mac> --mode 1 | tee /tmp/hw-validate-mode1.log'
```

`1` flat, `2` LACP, `3` VLAN, `4` VLAN+LACP.

On this v2.5.2 board in flat mode the root `--mode 1` run is a pass with these warnings and no failures:

- `B1` `tcpdump -i eth0` opened a capture. The script only warns because an older note expected the conduit tag to reject it.
- `F4` EMC2301 is absent. This board uses the PWM fan (`I4`), not that v2.4 fan chip.
- `G3` and `G5` see a down `bond0` while `ge0` and `ge1` stay on `br0`. `M1` still passes: no LACP, `vlan_filtering=0`, both `ge*` on `br0`.
- `M` has no `/etc/tp2/network.conf`. The flat profile is already in effect without that file.

`ge1` with no link reports speed `-1`. `SKIP` lines are the checks that need a node console, a USB stick, or LACP.

Opt-in, only when that setup is present:

- Node console: `node1` (and `node2`–`node4` if populated). A screen session opens on the UART. Quit with Ctrl-A then `\`.
- USB mass-storage: with a stick on a node, `/dev/disk/by-tpi/nodeN` points at the live disk and disappears when the stick is removed.
- LACP with a powered node: `sudo sh -c 'UPLINK_HAIRPIN_TEST=1 EXPECTED_KERNEL=6.18.50 /usr/share/tp2/hw-validate.sh --mac <factory-mac> --mode 2'`.
