# Blackgate Debian 13 Appliance

Separate experimental appliance builder. Does not modify the Ubuntu builder.

Base: `debian-13.6.0-amd64-netinst.iso`. Installer uses Debian preseed and a
bundled package repository; it never selects an Internet mirror. First boot
rebuilds Desktop Video DKMS for the running kernel, activates Quad 2 `2dhd`,
then enables Blackgate.

## Required inputs

```text
/home/woi/Downloads/debian-13.6.0-amd64-netinst.iso
/home/woi/Downloads/Blackmagic_Desktop_Video_Linux_16.0.1/deb/x86_64/desktopvideo_16.0.1a2_amd64.deb
files/blackgate-release-debian13.tar.gz
```

The release tarball must be built on Debian 13 from the tested branch:

```bash
make build
tar czf /tmp/blackgate-release-debian13.tar.gz -C _build/prod/rel blackgate
```

Copy it into this directory's `files/` folder. This avoids shipping an
Ubuntu-built native GStreamer binary in the Debian appliance.

## Build

```bash
./build.sh
```

Output: `output/blackgate-debian13-installer-amd64.iso`.

Warning: installer wipes first non-removable disk. Test only disposable
hardware or VM disks.
