# The container bootc-image-builder runs `bootc install` in. It is the vm image itself, so the
# disk is laid out by the image's own bootc, with one change that never reaches the disk: the
# image's policy.json rejects every transport it does not name, containers-storage included, and
# that is where the builder hands bootc the (already cosign-verified) image from.
ARG SOURCE
FROM ${SOURCE}
RUN python3 -c 'import json; p = "/usr/share/containers/policy.json"; d = json.load(open(p)); d["transports"]["containers-storage"] = {"": [{"type": "insecureAcceptAnything"}]}; json.dump(d, open("/etc/containers/policy.json", "w"), indent=2)'
