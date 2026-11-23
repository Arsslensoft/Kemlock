# GnuPG 2.5.24 built from its release tarball on Alpine edge, whose
# packages have GnuPG 2.5.22 only. The post-quantum fixtures of
# test/fixtures/keys/gnupg/pqc were made in it (see their README.md):
#
#   docker build -t kemlock-gnupg:2.5.24 -f tool/keys/docker/gnupg-2.5.24.Dockerfile tool/keys/docker
FROM alpine:edge@sha256:020dfcbaaf4cc1078bf2d9c7ba31a8466e334061dcd2f248001d68f79e52c000
RUN apk add --no-cache build-base libgcrypt-dev libgpg-error-dev libassuan-dev libksba-dev npth-dev zlib-dev bzip2-dev sqlite-dev wget bzip2 bash
RUN wget -q https://gnupg.org/ftp/gcrypt/gnupg/gnupg-2.5.24.tar.bz2 \
 && echo 'bf149d01a2b9fcc0e4589b8ae8697d3d5c557ea48ed95a3fa55dd3b1187e6039  gnupg-2.5.24.tar.bz2' | sha256sum -c \
 && tar xjf gnupg-2.5.24.tar.bz2 && cd gnupg-2.5.24 \
 && ./configure --prefix=/usr/local --disable-doc --disable-ldap --disable-gnutls --disable-wks-tools --disable-card-support --disable-ccid-driver >/dev/null \
 && make -j8 >/dev/null && make install >/dev/null && cd .. && rm -rf gnupg-2.5.24 gnupg-2.5.24.tar.bz2
