#!/bin/bash
# David Kedves <kedazo@gmail.com>

if [ ! -d debian ]; then
    echo "Please execute this script inside the project directory."
    exit 1
fi

echo "WARNING: this script will remove all ../libssh* files"
read

rm -fv ../libssh*

# libssh 0.11 it requires libssl >= 1.1.1, so only >= jammy
for distro in jammy noble; do
    debchange --team --distribution=$distro "Release for $distro."

    dpkg-buildpackage -rfakeroot -S
done

dput ppa:kedazo/libssh-0.7.x ../libssh*.changes

