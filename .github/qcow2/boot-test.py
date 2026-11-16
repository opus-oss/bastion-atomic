#!/usr/bin/env python3
"""Boot a qcow2 of the vm image in QEMU and check it through qemu-guest-agent.

The image boots with loglevel=0 and no serial console, so the guest agent is the only way in.
It is started by udev once systemd is up, and the vm image lets it run commands (guest-exec).

Checks: GNOME on screen, one deployment tracking the signed image, SELinux enforcing.

usage: boot-test.py <arch: amd64|arm64> <disk.qcow2> <expected origin> <timeout seconds>
"""
import base64, json, os, re, shutil, socket, subprocess, sys, time

arch, disk, want_origin, timeout = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
work = os.path.abspath("boot-test")
os.makedirs(work, exist_ok=True)
sock = os.path.join(work, "qga.sock")

# Boot an overlay, never the disk itself: the published qcow2 must be a machine that has never
# booted (no machine-id, no first-boot state).
overlay = os.path.join(work, "overlay.qcow2")
subprocess.run(["qemu-img", "create", "-q", "-f", "qcow2", "-b", os.path.abspath(disk),
                "-F", "qcow2", overlay], check=True)

kvm = os.access("/dev/kvm", os.W_OK)
if arch == "amd64":
    qemu, machine = "qemu-system-x86_64", ["-machine", "q35"]
    code, vars_ = "/usr/share/OVMF/OVMF_CODE_4M.fd", "/usr/share/OVMF/OVMF_VARS_4M.fd"
    cpu = ["-accel", "kvm", "-cpu", "host"] if kvm else ["-accel", "tcg", "-cpu", "max"]
else:
    qemu, machine = "qemu-system-aarch64", ["-machine", "virt"]
    code, vars_ = "/usr/share/AAVMF/AAVMF_CODE.fd", "/usr/share/AAVMF/AAVMF_VARS.fd"
    cpu = (["-accel", "kvm", "-cpu", "host"] if kvm
           else ["-accel", "tcg,thread=multi", "-cpu", "max,pauth-impdef=on"])
shutil.copy(vars_, os.path.join(work, "vars.fd"))
print(f"{qemu}, {'KVM' if kvm else 'TCG (no /dev/kvm)'}", flush=True)

# Secure Boot off (non-secboot firmware), as on the user's UTM and libvirt machines.
cmd = [qemu, *machine, *cpu, "-m", "4096", "-smp", str(os.cpu_count() or 2),
       "-drive", f"if=pflash,format=raw,readonly=on,file={code}",
       "-drive", f"if=pflash,format=raw,file={work}/vars.fd",
       "-drive", f"if=virtio,format=qcow2,file={overlay}",
       "-nic", "user,model=virtio-net-pci",
       "-device", "virtio-rng-pci",  # random.trust_cpu=off: give the guest an entropy source
       "-device", "virtio-gpu-pci", "-display", "none",
       "-device", "virtio-serial-pci",
       "-chardev", f"socket,id=qga,path={sock},server=on,wait=off",
       "-device", "virtserialport,chardev=qga,name=org.qemu.guest_agent.0",
       "-qmp", f"unix:{work}/qmp.sock,server=on,wait=off",
       "-serial", f"file:{work}/serial.log"]
vm = subprocess.Popen(cmd)


def qga(request, wait=10):
    """One request on a fresh connection, synced first so stale output is skipped."""
    with socket.socket(socket.AF_UNIX) as s:
        s.settimeout(wait)
        s.connect(sock)
        f = s.makefile("rwb")
        sync = int(time.time())
        for req in ({"execute": "guest-sync", "arguments": {"id": sync}}, request):
            f.write(json.dumps(req).encode() + b"\n"); f.flush()
            while True:
                line = f.readline()
                if not line:
                    raise ConnectionError("agent closed the connection")
                try:
                    reply = json.loads(line)
                except ValueError:
                    continue
                if req is not request and reply.get("return") != sync:
                    continue
                break
        if "error" in reply:
            raise RuntimeError(reply["error"])
        return reply["return"]


def run(*argv, wait=120):
    pid = qga({"execute": "guest-exec",
               "arguments": {"path": argv[0], "arg": list(argv[1:]), "capture-output": True}})["pid"]
    end = time.time() + wait
    while time.time() < end:
        st = qga({"execute": "guest-exec-status", "arguments": {"pid": pid}})
        if st["exited"]:
            out = base64.b64decode(st.get("out-data", "")).decode(errors="replace")
            err = base64.b64decode(st.get("err-data", "")).decode(errors="replace")
            return st.get("exitcode"), out, err
        time.sleep(2)
    raise TimeoutError(" ".join(argv))


def screen_colours():
    """Take a screendump through QMP; return how many colours it has (0 if none yet)."""
    out = os.path.join(work, "screen.ppm")
    with socket.socket(socket.AF_UNIX) as s:
        s.settimeout(30)
        s.connect(os.path.join(work, "qmp.sock"))
        f = s.makefile("rwb")
        f.readline()  # greeting
        for cmd in ({"execute": "qmp_capabilities"},
                    {"execute": "screendump", "arguments": {"filename": out}}):
            f.write(json.dumps(cmd).encode() + b"\n"); f.flush()
            while True:
                reply = json.loads(f.readline())
                if "return" in reply or "error" in reply:
                    break
    if not os.path.exists(out):
        return 0
    data = open(out, "rb").read()
    # P6 header: magic, width height, maxval, then RGB triplets.
    parts = data.split(b"\n", 3)
    pixels = parts[3]
    return len({pixels[i:i + 3] for i in range(0, len(pixels) - 2, 3 * 97)})


failed = []
try:
    start, up = time.time(), False
    while time.time() - start < timeout:
        if vm.poll() is not None:
            sys.exit(f"QEMU exited with {vm.returncode} before the guest agent answered")
        try:
            qga({"execute": "guest-ping"}, wait=5)
            up = True
            break
        except (OSError, ConnectionError, RuntimeError):
            time.sleep(5)
    if not up:
        sys.exit(f"guest agent did not answer within {timeout}s")
    print(f"guest agent up after {time.time() - start:.0f}s", flush=True)

    # The agent runs confined: plain binaries (sh, cat) are allowed, but SELinux refuses it a
    # transition into rpm-ostree's or systemctl's domains, so everything here is read from files.
    def sh(script, wait=120):
        rc, out, err = run("/usr/bin/sh", "-c", script, wait=wait)
        return out.strip() + (("\n" + err.strip()) if err.strip() else "")

    print("kernel:", sh("uname -r"))

    # A drawn GNOME screen (Initial Setup, from gdm) is as far as a headless check can see the
    # desktop come up. The agent cannot ask systemd or see other processes, and the arm64 serial
    # console stays quiet, so look at the screen: a text console or blank framebuffer has a
    # handful of colours, GNOME's antialiased UI has hundreds.
    gdm, colours, end = False, 0, time.time() + 900
    while time.time() < end:
        try:
            colours = screen_colours()
        except (OSError, ValueError) as e:
            print("screendump:", e)
        if colours > 64:
            gdm = True
            break
        time.sleep(20)
    print(f"screen: {colours} colours sampled, desktop {'up' if gdm else 'not up'}")
    if not gdm:
        failed.append("the GNOME screen never came up")
        print(sh("ls -l /dev/dri; cat /proc/fb; ls /sys/class/drm"))
        print(sh("journalctl -b --no-pager -o short-monotonic -u gdm -u display-manager | tail -40"))
        print(sh("journalctl -b --no-pager -o short-monotonic -p warning | tail -60"))

    deployments = sh("ls -d /sysroot/ostree/deploy/*/deploy/*.origin").split()
    print("deployments:", deployments)
    origin = sh("sed -n 's/^container-image-reference=//p' /sysroot/ostree/deploy/*/deploy/*.origin")
    print("origin:", origin)
    if len(deployments) != 1 or origin != want_origin:
        failed.append(f"origin is {origin!r} ({len(deployments)} deployments), want {want_origin}")

    enforce = sh("cat /sys/fs/selinux/enforce")
    print("SELinux enforcing:", enforce)
    if enforce != "1":
        failed.append(f"SELinux enforce is {enforce!r}")

    print("cmdline:", sh("cat /proc/cmdline"))
finally:
    try:
        qga({"execute": "guest-shutdown"}, wait=5)
    except Exception:
        pass
    try:
        vm.wait(120)
    except subprocess.TimeoutExpired:
        vm.kill()

if failed:
    sys.exit("FAIL: " + "; ".join(failed))
print("boot test passed")
