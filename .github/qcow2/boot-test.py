#!/usr/bin/env python3
"""Boot a qcow2 of the vm image in QEMU and check it through qemu-guest-agent.

The image boots with loglevel=0 and no serial console, so the guest agent is the only way in.
It is started by udev once systemd is up, and the vm image lets it run commands (guest-exec).

usage: boot-test.py <arch: amd64|arm64> <disk.qcow2> <expected origin> <timeout seconds>
"""
import base64, json, os, shutil, socket, subprocess, sys, time

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

    # Let boot settle before judging it; degraded is reported, not fatal.
    _, state, _ = run("/usr/bin/systemctl", "is-system-running", "--wait", wait=900)
    print("system state:", state.strip())
    print(run("/usr/bin/systemctl", "--failed", "--no-legend")[1] or "no failed units")
    print(run("/usr/bin/uname", "-r")[1].strip())

    rc, out, err = run("/usr/bin/rpm-ostree", "status", "--json", "--booted")
    if rc != 0:
        failed.append(f"rpm-ostree status failed: {err}")
    else:
        booted = [d for d in json.loads(out)["deployments"] if d.get("booted")][0]
        origin = booted.get("container-image-reference")
        print("origin:", origin)
        if origin != want_origin:
            failed.append(f"origin is {origin}, want {want_origin}")

    enforce = run("/usr/sbin/getenforce")[1].strip()
    print("SELinux:", enforce)
    if enforce != "Enforcing":
        failed.append(f"SELinux is {enforce}")

    gdm = run("/usr/bin/systemctl", "is-active", "gdm.service")[1].strip()
    print("gdm:", gdm)
    if gdm != "active":
        failed.append(f"gdm is {gdm}")

    # Informational: does the signed update path reach the registry from inside the guest?
    rc, out, err = run("/usr/bin/rpm-ostree", "upgrade", "--check", wait=600)
    print(f"rpm-ostree upgrade --check: exit {rc}\n{out}{err}")
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
