#!/bin/bash
# David Kedves <kedazo@gmail.com>

if [ ! -d debian ]; then
    echo "Please execute this script inside the project directory."
    exit 1
fi

echo "WARNING: this script will remove all ../libssh* files"
read

rm -fv ../libssh*

# trusty is too old
for distro in xenial bionic eoan focal; do
    debchange --team --distribution=$distro "Release for $distro."

    dpkg-buildpackage -rfakeroot -S
done

dput ppa:kedazo/libssh-0.7.x ../libssh*.changes
# now it is the same, release day!
dput ppa:kedazo/libssh-master ../libssh*.changes

