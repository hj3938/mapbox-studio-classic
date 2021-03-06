#!/usr/bin/env bash

cwd=$(pwd)

if [ -z "$1" ]; then
    gitsha="master"
else
    gitsha=$1
fi

if [ -z "$2" ]; then
    platform=$(uname -s | sed "y/ABCDEFGHIJKLMNOPQRSTUVWXYZ/abcdefghijklmnopqrstuvwxyz/")
else
    platform=$2
fi

if [ -z "$3" ]; then
    arch="x64"
else
    arch=$3
fi

atom_arch=$arch
arch_common_name=$arch
extra_install_args=""
if [ "$platform" == "win32" ]; then
    atom_arch="ia32"
    extra_install_args="--toolset=v140"
    if [[ $arch == "ia32" ]]; then
        arch_common_name="x86"
    fi
fi

set -e -u
set -o pipefail

if ! which git > /dev/null; then echo "git command not found"; exit 1; fi;
if ! which aws > /dev/null; then echo "aws command not found"; exit 1; fi;
if ! which npm > /dev/null; then echo "npm command not found"; exit 1; fi;
if ! which tar > /dev/null; then echo "tar command not found"; exit 1; fi;
if ! which curl > /dev/null; then echo "curl command not found"; exit 1; fi;
if ! which unzip > /dev/null; then echo "unzip command not found"; exit 1; fi;

build_dir="/tmp/mapbox-studio-$platform-$arch_common_name-$gitsha"
shell_url="https://github.com/atom/atom-shell/releases/download/v$ATOM_VERSION/atom-shell-v$ATOM_VERSION-$platform-$atom_arch.zip"
shell_file="/tmp/atom-shell-v$ATOM_VERSION-$platform-$atom_arch.zip"

if [ "$platform" == "darwin" ]; then
    app_dir="/tmp/mapbox-studio-$platform-$arch_common_name-$gitsha/Atom.app/Contents/Resources/app"
else
    app_dir="/tmp/mapbox-studio-$platform-$arch_common_name-$gitsha/resources/app"
fi

echo "Building bundle in $build_dir"

if [ -d $build_dir ]; then
    echo "Build dir $build_dir already exists"
    exit 1
fi

echo "Downloading atom $shell_url"
curl -Lsfo $shell_file $shell_url
unzip -qq $shell_file -d $build_dir
rm $shell_file

echo "downloading studio"
git clone https://github.com/mapbox/mapbox-studio.git $app_dir
cd $app_dir
git checkout $gitsha
rm -rf $app_dir/.git

echo "updating license"
# Update LICENSE and version files from atom default.
ver=$(node -e "var fs = require('fs'); console.log(JSON.parse(fs.readFileSync('$app_dir/package.json')).version);")
echo $ver > $build_dir/version
cp $app_dir/LICENSE.md $build_dir/LICENSE
mv $build_dir/version $build_dir/version.txt
mv $build_dir/LICENSE $build_dir/LICENSE.txt

echo "running npm install"
BUILD_PLATFORM=$platform TARGET_ARCH=$arch npm install --production \
--target_platform=$platform \
--target=$NODE_VERSION \
--target_arch=$arch \
--fallback-to-build=false $extra_install_args

# Remove extra deps dirs to save space
deps="node_modules/mbtiles/node_modules/sqlite3/deps
node_modules/gdal/deps"
for depdir in $deps; do
    rm -r $app_dir/$depdir
done

cd /tmp

# win32: installer using nsis
if [ $platform == "win32" ]; then
    if ! which makensis > /dev/null; then echo "makensis command not found"; exit 1; fi;
    if ! which signcode > /dev/null; then echo "signcode command not found"; exit 1; fi;
    if ! which expect > /dev/null; then echo "expect command not found"; exit 1; fi;
    if ! which windowsign > /dev/null; then echo "windowsign command not found"; exit 1; fi;

    # windows code signing
    # context on signing at https://github.com/mapbox/mapbox-studio-classic-internal/wiki/code-signing
    aws s3 cp s3://mapbox/mapbox-studio/certs/authenticode.pvk authenticode.pvk
    aws s3 cp s3://mapbox/mapbox-studio/certs/authenticode.spc authenticode.spc

    echo "running windows signing on mapbox-studio.exe"
    mv $build_dir/atom.exe $build_dir/mapbox-studio.exe
    N='Mapbox Studio' I='https://www.mapbox.com/' P=$WINCERT_PASSWORD \
    SPC=authenticode.spc PVK=authenticode.pvk \
    windowsign $build_dir/mapbox-studio.exe

    rm $build_dir/mapbox-studio.exe.bak

    #bundle runtime DLLs directly into vendor and node-mapnik binding directory
    vc_runtime_version="VS2015"
    vc_runtime_file="vcredist_${arch_common_name}-mini.7z"
    vc_runtime_file_local="/tmp/vcredist_${arch_common_name}-mini.7z"
    vc_runtime_url="https://mapbox.s3.amazonaws.com/windows-builds/visual-studio-runtimes/vcredist-${vc_runtime_version}/${vc_runtime_file}"

    echo "downloading c++ lib ${vc_runtime_file}"
    curl -Lfo $vc_runtime_file_local $vc_runtime_url
    echo "extracting c++ lib to $build_dir"
    7z -y e $vc_runtime_file -o"$build_dir/resources/app/vendor/"
    echo "extracting c++ lib to node-mapnik binding dir"
    #TODO determine node version automatically
    #node 0.10.40
    7z -y e $vc_runtime_file -o"$build_dir/resources/app/node_modules/mapnik/lib/binding/node-v11-win32-${arch}/"
    #node 0.12.7
    #7z -y e $vc_runtime_file -o"$build_dir/resources/app/node_modules/mapnik/lib/binding/node-v14-win32-${arch}/"

    if [[ $arch == "x64" ]]; then
        # alternative package for windows: no-installer / can be run from usb drive
        7z a -r -mx9 ${build_dir}.7z $(basename $build_dir) > /dev/null
        echo "uploading ${build_dir}.7z"
        aws s3 cp --acl=public-read ${build_dir}.7z s3://mapbox/mapbox-studio/
        echo "Build at https://mapbox.s3.amazonaws.com/mapbox-studio/$(basename ${build_dir}.7z)"
    fi

    echo "running makensis"
    makensis -V2 \
      -DTARGET_ARCH=${arch_common_name} \
      -DSOURCE_ROOT=${build_dir}/ \
      -DOUTPUT_FILE=${build_dir}.exe \
      -DVERSION=${ver} \
      ${build_dir}/resources/app/scripts/mapbox-studio.nsi
    echo "cleaning up after makensis"
    rm -rf $build_dir

    echo "running windows signing on installer"
    N='Mapbox Studio' I='https://www.mapbox.com/' P=$WINCERT_PASSWORD \
    SPC=authenticode.spc PVK=authenticode.pvk \
    windowsign $build_dir.exe

    # remove cert
    rm -f authenticode.pvk
    rm -f authenticode.spc

    echo "uploading $build_dir.exe"
    aws s3 cp --acl=public-read $build_dir.exe s3://mapbox/mapbox-studio/
    echo "Build at https://mapbox.s3.amazonaws.com/mapbox-studio/$(basename $build_dir.exe)"
    rm -f $build_dir.exe
# darwin: add app resources, zip up
elif [ $platform == "darwin" ]; then
    # Update Info.plist with correct version number.
    sed -i.bak s/VREPLACE/$ver/ $app_dir/scripts/assets/Info.plist

    rm $build_dir/Atom.app/Contents/Resources/atom.icns
    cp $app_dir/scripts/assets/mapbox-studio.icns $build_dir/Atom.app/Contents/Resources/mapbox-studio.icns
    cp $app_dir/scripts/assets/Info.plist $build_dir/Atom.app/Contents/Info.plist
    mv $build_dir/Atom.app "$build_dir/Mapbox Studio.app"

    # Test getting signing key.
    # context on signing at https://github.com/mapbox/mapbox-studio-classic-internal/wiki/code-signing
    aws s3 cp "s3://mapbox/mapbox-studio/keys2/Developer ID Certification Authority.cer" authority.cer
    aws s3 cp "s3://mapbox/mapbox-studio/keys2/Developer ID Application- Mapbox, Inc. (GJZR2MEM28).cer" signing-key.cer
    aws s3 cp "s3://mapbox/mapbox-studio/keys2/Mac Developer ID Application- Mapbox, Inc..p12" signing-key.p12
    KEYCHAIN_NAME="circle.keychain"
    KEYCHAIN_PASSWORD="circle"
    security create-keychain -p ${KEYCHAIN_PASSWORD} ${KEYCHAIN_NAME} \
        && echo "+ signing keychain created"
    security list-keychains -s ${KEYCHAIN_NAME}
    security list-keychains
    security show-keychain-info ${KEYCHAIN_NAME}
    security unlock-keychain -p ${KEYCHAIN_PASSWORD} ${KEYCHAIN_NAME}
    security set-keychain-settings -lut 7200 ${KEYCHAIN_NAME}
    security import authority.cer -k ~/Library/Keychains/${KEYCHAIN_NAME} -T /usr/bin/codesign -A \
        && echo "+ authority cer added to keychain"
    security import signing-key.cer -k ~/Library/Keychains/${KEYCHAIN_NAME} -T /usr/bin/codesign -A \
        && echo "+ signing cer added to keychain"
    security import signing-key.p12 -k ~/Library/Keychains/${KEYCHAIN_NAME} -P "" -T /usr/bin/codesign -A \
        && echo "+ signing key added to keychain"

    # https://discuss.circleci.com/t/xcode-8-3-build-timing-out/11721
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k ${KEYCHAIN_PASSWORD} ${KEYCHAIN_NAME}

    rm authority.cer
    rm signing-key.cer
    rm signing-key.p12

    # update time to try to avoid occasional codesign error of "timestamps differ by N seconds - check your system clock"
    sudo ntpdate -u time.apple.com

    # Sign .app file.
    which codesign
    security list-keychains
    codesign --keychain ~/Library/Keychains/${KEYCHAIN_NAME} --sign "Developer ID Application: Mapbox, Inc." --deep --verbose --force "$build_dir/Mapbox Studio.app"

    # Nuke signin keychain.
    #security delete-keychain ${KEYCHAIN_NAME}

    # Use ditto rather than zip to preserve code signing.
    ditto -c -k --sequesterRsrc --keepParent --zlibCompressionLevel 9 $(basename $build_dir) $build_dir.zip

    rm -rf $build_dir
    aws s3 cp --acl=public-read $build_dir.zip s3://mapbox/mapbox-studio/
    echo "Build at https://mapbox.s3.amazonaws.com/mapbox-studio/$(basename $build_dir.zip)"
    rm -f $build_dir.zip
# linux: zip up
else
    zip -qr -9 $build_dir.zip $(basename $build_dir)
    rm -rf $build_dir
    aws s3 cp --acl=public-read $build_dir.zip s3://mapbox/mapbox-studio/
    echo "Build at https://mapbox.s3.amazonaws.com/mapbox-studio/$(basename $build_dir.zip)"
    rm -f $build_dir.zip
fi

if [ "$ver" ==  "$(echo $gitsha | tr -d v)" ]; then
    echo $ver > latest
    aws s3 cp --acl=public-read latest s3://mapbox/mapbox-studio/latest
    rm -f latest
    echo "Latest build version at https://mapbox.s3.amazonaws.com/mapbox-studio/latest"
fi

cd $cwd
