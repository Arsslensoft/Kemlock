# Sequoia's sq 1.5.0 (sequoia-openpgp 2.4.1 with the OpenSSL 4.0.3
# backend, which has ML-KEM and ML-DSA) from Fedora 45's packages. The
# fixtures of test/fixtures/keys/sequoia/pqc were made in it (see their
# README.md):
#
#   docker build -t kemlock-sq:1.5.0 -f tool/keys/docker/sq-1.5.0.Dockerfile tool/keys/docker
FROM registry.fedoraproject.org/fedora@sha256:e203b4174f6a2ce6c160ddc4917d85e6bfce32dfc610d953b355d63ec4c17909
RUN dnf -q -y install sequoia-sq-1.5.0-2.fc45 && dnf clean all
