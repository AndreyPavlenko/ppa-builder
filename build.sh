#!/bin/sh
set -e

# Working dir
: ${DIR:="$(cd "$(dirname "$0")" && pwd)"}

# Path to the currently executing build script
: ${BUILD_SCRIPT_PATH:="$DIR/$(basename "$0")"}

# Load ~/.build.config script if exists.
[ ! -f "$HOME/.build.config" ] || [ ! -z "$IGNORE_GLOBAL_CONFIG" ] || . "$HOME/.build.config"

# Load build.config script if exists.
[ ! -f "$DIR/build.config" ] || [ ! -z "$IGNORE_CONFIG" ] || . "$DIR/build.config"

################### Mandatory variables to be defined ##########################
_checkvar () { if eval "[ -z \"\$$1\" ]"; then echo "Variable $1 is not set"; exit 1; fi }

# Package name.
_checkvar PKG_NAME

# PPA url. Example: PPA_URL='http://ppa.launchpad.net/myppa'.
_checkvar PPA_URL

# PPA name for upload.
_checkvar PPA
################################################################################

################## Mandatory functions to be implemented #######################
_checkfunc () { if ! type "$1" 2>&1 >/dev/null; then echo "Function $1 is not implemented" 1>&2; exit 1; fi; }
_checkfuncs() {
    # Print version of the package to be built.
    _checkfunc version

    # Update sources.
    _checkfunc update

    # Print changelog for the specified distrib. This in non-public function.
    _checkfunc _changelog

    # Checkout sources to the specified directory. This in non-public function.
    _checkfunc _checkout
}
################################################################################

########################## Optional variables ##################################

# Package epoch version
: ${PKG_EPOCH:=''}

# Package maintainer
: ${MAINTAINER:='Unknown <unknown@unknown>'}

# Source directories
: ${SOURCES_DIR:="$DIR/sources"}
: ${SRC_DIR_NAME:="$PKG_NAME"}
: ${SRC_DIR:="$SOURCES_DIR/$SRC_DIR_NAME"}

# Path to the debian directory
: ${DEB_DIR:="$DIR/debian"}

# Source revision
: ${REV:='origin/master'}

# Cache directories
: ${CACHE_DIR:="$DIR/cache"}
: ${BASETGZ_DIR:="$CACHE_DIR/base"}
: ${APT_CACHE_DIR:="$CACHE_DIR/apt"}

# Temporary build directory
: ${BUILD_DIR:="$DIR/build"}

# Output directory for built packages
BUILD_DATE=$(date +%d.%m.%y)
: ${DISTRIBS_DIR:="$DIR/distribs"}
: ${DISTRIBS_SRC_DIR:="$DISTRIBS_DIR/$BUILD_DATE/src"}
: ${DISTRIBS_DEB_DIR:="$DISTRIBS_DIR/$BUILD_DATE/deb"}

# pbuilder arguments
: ${PBUILDER_ARGS:=--aptcache "$APT_CACHE_DIR" \
                    --buildplace "$BUILD_DIR" --buildresult "$DISTRIBS_DEB_DIR"\
                    --override-config}
[ -z "$http_proxy" ] || PBUILDER_ARGS="$PBUILDER_ARGS --http-proxy "$http_proxy""

# URL of a Debian mirror
: ${DEB_MIRROR:='http://archive.ubuntu.com/ubuntu'}

# dpkg-buildpackage args
: ${BUILDPACKAGE_ARGS:="-uc -us"}

# Build script dependencies
DEPENDS="pbuilder debootstrap lsb-release dpkg-dev debhelper $DEPENDS"

# Aptitude tag to mark all installed dependencies
: ${DEPENDS_TAG:="$PKG_NAME-build"}

# URL of a ppa containing build dependencies
: ${PPA_DEPENDS:="deb $PPA_URL/$PPA/ubuntu #DISTRIB# main"}

# URL of ppa sources
: ${PPA_SOURCES:="$PPA_URL/$PPA/ubuntu/dists/#DISTRIB#/main/source/Sources.gz"}

# PPA version
: ${PPAN:="ppa1"}

# Target platforms
: ${TARGET_PLATFORMS:="$(lsb_release -cs):$(dpkg-architecture -qDEB_BUILD_ARCH)"}

# Maximum number of changelog records.
: ${MAX_CHANGELOGS:='1000'}

# Command aliases
: ${SUDO:='sudo'}
: ${RM:='/bin/rm'}

# Skip targets
: ${SKIP_DEPENDS:='false'}
: ${SKIP_UPDATE:='false'}
: ${SKIP_UPDATE_BASE:='false'}
: ${SKIP_BUILD:='false'}
: ${SKIP_UPLOAD:='true'}
################################################################################

################################## Targets #####################################

create() {
    echo "create:"
    local version=$(version)
    local name_ver="${PKG_NAME}_${version}"
    local src="$BUILD_DIR/$name_ver"
    local orig_tar="$BUILD_DIR/$name_ver.orig.tar.bz2"
    local bp_args="$BUILDPACKAGE_ARGS"
    echo "$BUILDPACKAGE_ARGS" | grep -qE '\-sa|\-sd|\-si' || sa="-sa"
    
    # Checkout
    "$RM" -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    _checkout "$src"
    
    # Create orig source tarball
    _orig_tarball "$src" "$orig_tar"
    
    # Create source packages
    for dist in $(for i in $TARGET_PLATFORMS; do echo $i | awk -F ':' '{print $1}'; done | sort -u)
    do
        local deb_dir="$(_deb_dir "$src" "$dist")"
        [ -d "$deb_dir" ] || (echo "Debian directory does not exist: $deb_dir" 1>&2 && exit 1)
        
        $RM -rf "$src/debian"
        cp -r "$deb_dir" "$src"
        _changelog "$dist" | _gen_changelog "$version" "$dist" > "$src/debian/changelog"
        sed -i "s/#MAINTAINER#/$MAINTAINER/" "$src/debian/control"

        cd "$src"
        dpkg-buildpackage -rfakeroot $BUILDPACKAGE_ARGS $sa -S
        [ -z "$sa" ] || sa='-sd'
    done

    # Move package to $DISTRIBS_SRC_DIR
    [ -d "$DISTRIBS_SRC_DIR" ] || mkdir -p "$DISTRIBS_SRC_DIR"
    cd "$BUILD_DIR"
    PACKAGES=$(ls *.dsc)
    mv *.tar.* *.dsc *.changes "$DISTRIBS_SRC_DIR"
    $RM -rf "$BUILD_DIR"
}

build() {
    echo "build:"
    cd "$DISTRIBS_SRC_DIR"
    : ${PACKAGES:=$(ls *.dsc)}
    $RM -rf "$BUILD_DIR"

    for i in $TARGET_PLATFORMS
    do
        local distrib=$(echo $i | awk -F ':' '{print $1}')
        local arch=$(echo $i | awk -F ':' '{print $2}')

        _pbuild_create $distrib $arch
        _pbuild_build  $distrib $arch
    done

    cd "$DISTRIBS_DEB_DIR"
    $RM -f *.tar.bz2 *.dsc *.changes
    $RM -rf "$BUILD_DIR"
}

depends() {
cat << EOF
depends:

Installing dependencies: $DEPENDS

Note: you may uninstall the installed dependencies with the following command:
sudo aptitude purge '?user-tag($DEPENDS_TAG)'

EOF

    $SUDO apt-get install aptitude
    $SUDO aptitude install --add-user-tag "$DEPENDS_TAG" $DEPENDS
}

clean() {
    echo "clean:"
    $RM -rf "$DISTRIBS_DIR"
}

clean_cache() {
    echo "clean_cache:"
    $RM -rf "$CACHE_DIR"
}

clean_depends() {
    echo "clean_depends:"
    $SUDO aptitude purge "?user-tag($DEPENDS_TAG)"
}

clean_sources() {
    echo "clean_sources:"
    $RM -rf "$SRC_DIR"
}

clean_all() {
    echo "clean_all:"
    clean
    clean_cache
    clean_depends
    clean_sources
}

cur_version() {
    for dist in $(for i in $TARGET_PLATFORMS; do echo $i | awk -F ':' '{print $1}'; done | sort -u)
    do
        echo "$dist: $(_cur_version "$dist")"
    done
}

check_updates() {
    local version="$(version)"
    local names=''
    for dist in $(for i in $TARGET_PLATFORMS; do echo $i | awk -F ':' '{print $1}'; done | sort -u)
    do
        local cur_version="$(_cur_version "$dist")"
        local epoch=''
        echo "$cur_version" | grep -q ':' && epoch="${cur_version%%:*}"
        
        if [ "$version" != "${cur_version#*:}" ] || [ "$PKG_EPOCH" != "$epoch" ]
        then
            names="$names $dist"
        fi
    done
    
    if [ -z "$names" ]
    then
        echo "Up to date."
    else
        echo "Updates are available for:$names"
    fi
}

upload() {
    echo "upload:"
    
    cd "$DISTRIBS_SRC_DIR"
    : ${PACKAGES:=$(ls *.dsc)}
    local changes="$(for i in $PACKAGES; do echo $i | sed 's/.dsc$/_source.changes/'; done)"

    echo dput "$PPA" $changes
    dput "$PPA" $changes
}

all() {
    [ "$SKIP_DEPENDS" = "true" ] || depends
    [ "$SKIP_UPDATE" = "true" ] || update
    create
    [ "$SKIP_BUILD" = "true" ] || build
    [ "$SKIP_UPLOAD" = "true" ] || upload
}
################################################################################

############################## Main function ###################################
_main() {
    _checkfuncs
    local TARGETS=$(_print_functions "$BUILD_SCRIPT_PATH" | tr '\n' '|' | head -c -1)
    
    if [ -z "$1" ]
    then 
        local targets='all'
    else
        local targets="$*"
    fi

    for t in $targets
    do
        if echo "$t" | grep -Eq "^($TARGETS)\$"
        then
            $t
        else
            echo "Unknown target $t"
            echo "Usage: $(basename "$BUILD_SCRIPT_PATH") <$TARGETS>"
        fi
    done
}
################################################################################

########################## Non-public functions ################################

_git_update() {
    local src_url="$1"
    local src_dir="${2:-"$SRC_DIR"}"
    local branch="${3:-"${REV#*/}"}"
    local remote="${4:-"${REV%/*}"}"

    if [ ! -d "$src_dir" ]
    then
        git clone --no-checkout -b "$branch" "$src_url" "$src_dir"
    else
        git --git-dir="$src_dir/.git" fetch $remote $branch:refs/remotes/origin/$branch -f
    fi
}

_git_checkout() {
    local dest="$1"
    local rev="${2:-"$REV"}"
    local src_dir="${3:-"$SRC_DIR"}"
    local subdir="$4"
    
    
    if [ -z "$subdir" ]
    then
        mkdir -p "$dest"
        git --git-dir="$src_dir/.git" --work-tree="$dest" reset --hard "$rev"
    else
        local tmp="$BUILD_DIR/tmp.co.dir"
        mkdir -p "$tmp"
        git --git-dir="$src_dir/.git" --work-tree="$tmp" reset --hard "$rev"
        mv "$tmp/$subdir" "$dest"
        "$RM" -rf "$tmp"
    fi
}

_git_changelog() {
    local rev1="$1"
    local rev2="${2:-"$REV"}"
    local src_dir="${3:-"$SRC_DIR"}"
    local path="$4"
    local format="${5:-"  * [%H]%n%B%n"}"
    local max="${6:-"$MAX_CHANGELOGS"}"
    local rev;
    rev2="$(git --git-dir="$src_dir/.git" log -n1 --format='%H' "$rev2" -- "$path")"
    
    if [ "$rev1" = "Unknown" ]
    then
        rev="$rev2"
    else
        rev1="$(git --git-dir="$src_dir/.git" log -n1 --format='%H' "$rev1" -- "$path" 2>/dev/null || true)"

        if [ -z "$rev1" ]
        then
            rev="$rev2"
        elif [ "$rev1" = "$rev2" ]
        then 
            rev="$rev2~1..$rev2"
        else
            rev="$rev1..$rev2"
        fi
    fi

    if [ -z "$(git --git-dir="$src_dir/.git" log -n1 --format='%H' "$rev" -- "$path" 2>/dev/null || true)" ]
    then
        echo "  * Revision: $rev2\n"
    else
        git --git-dir="$src_dir/.git" log -n $max --format="$format" "$rev" -- "$path" | \
        head -c -1 | sed -r  '/  \* /! s/^(.*)$/    \1/g'
    fi
}

_hg_update() {
    local src_url="$1"
    local src_dir="${2:-"$SRC_DIR"}"
    
    if [ ! -d "$src_dir" ]
    then
        hg clone -U "$src_url" "$src_dir"
    else
        hg --cwd "$src_dir" pull -u
    fi
}

_hg_checkout() {
    local dest="$1"
    local rev="${2:-"$REV"}"
    local src_dir="${3:-"$SRC_DIR"}"
    local subdir="$4"
    
    
    if [ -z "$subdir" ]
    then
        mkdir -p "$dest"
        cp -r "$src_dir/.hg" "$dest"
        hg --cwd "$dest" update -C "$rev"
        "$RM" -rf "$dest/.hg"
    else
        local tmp="$BUILD_DIR/tmp.co.dir"
        mkdir -p "$tmp"
        cp -r "$src_dir/.hg" "$tmp"
        hg --cwd "$tmp" update -C "$rev"
        mv "$tmp/$subdir" "$dest"
        "$RM" -rf "$tmp"
    fi
}

_hg_changelog() {
    local rev1="$1"
    local rev2="${2:-"$REV"}"
    local src_dir="${3:-"$SRC_DIR"}"
    local path="$4"
    local template="${5:-"  * [\{node\}]\\n\{desc\}\\n\\n"}"
    local max="${6:-"$MAX_CHANGELOGS"}"
    local rev;
    rev2="$(hg --cwd "$src_dir" log -l 1 --template '{node}' -r "$rev2" "$path")"
    
    if [ "$rev1" = "Unknown" ]
    then
        rev="..$rev2"
    else
        rev1="$(hg --cwd "$src_dir" log -l 1 --template '{node}' -r "$rev1" "$path" 2>/dev/null || true)"
        rev="$rev1..$rev2"
    fi
    
    if [ -z "$(hg --cwd "$src_dir" log -l 1 --template '{node}' -r "$rev" "$path" 2>/dev/null || true)" ]
    then
        echo "  * Revision: $rev2\n"
    else
        hg -l $max --cwd "$src_dir" log --template "$template" -r "$rev" "$path" | \
        sed -r  '/  \* /! s/^(.*)$/    \1/g'
    fi
}

_svn_update() {
    local src_url="$1"
    local src_dir="${2:-"$SRC_DIR"}"
    local rev="${3:-"$REV"}"
    [ -z "$rev" ] || rev="-r $rev"
    
    if [ ! -d "$src_dir" ]
    then
        svn checkout $rev "$src_url" "$src_dir"
    else
        svn update $rev "$src_dir"
    fi
}

_svn_checkout() {
    local dest="$1"
    local src_dir="${2:-"$SRC_DIR"}"
    local subdir="$3"
    
    if [ -z "$subdir" ]
    then
        mkdir -p "$dest"
        cp -r "$src_dir/.svn" "$dest"
        svn revert -R "$dest"
        "$RM" -rf "$dest/.svn"
    else
        local tmp="$BUILD_DIR/tmp.co.dir"
        mkdir -p "$tmp"
        cp -r "$src_dir/.svn" "$tmp"
        svn revert -R "$tmp"
        mv "$tmp/$subdir" "$dest"
        "$RM" -rf "$tmp"
    fi
}

_svn_changelog() {
    local rev1="$1"
    local rev2="${2:-"$REV"}"
    local src_dir="${3:-"$SRC_DIR"}"
    local path="$4"
    local format="${5:-"s/^-+\$/\\n/; s/^(r[0-9]+) \\| .+\$/  * [\\1]/"}"
    local max="${6:-"$MAX_CHANGELOGS"}"
    [ -z "$path" ] || src_dir="$src_dir/$path"
    
    if ! echo "$rev1" | grep -Exq  'r?[0-9]+'
    then
        rev1="0"
    fi
    
    if ! echo "$rev2" | grep -Exq  'r?[0-9]+'
    then
        rev2="$(svn info --xml "$src_dir" | tr '\n' ' ' | grep -oE '<commit\s+revision\s*=\s*"[0-9]+"\s*>' | grep -oE '[0-9]+')"
    fi
    
    svn log -l $max -r "$rev1:$rev2" "$src_dir" | sed -r "$format" | \
    sed -r  '/  \* /! s/^(.*)$/    \1/g'
}

_gen_changelog() {
    local version="$1"
    local dist="$2"
    local epoch="${3:-"$PKG_EPOCH"}"
    local qualifier="${4:-"-$PPAN~$dist"}"
    local date="${5:-"$(date -R)"}"
    
    [ -z "$epoch" ] || version="$epoch:$version"
    echo "$PKG_NAME (${version}${qualifier}) $dist; urgency=medium"
    echo
    cat
    echo
    echo " -- $MAINTAINER  $date"
}

_orig_tarball() {
    local src="$1"
    local dest="$2"
    local options="${3:-"-cjf"}"
    tar -C "$(dirname "$src")" $options "$dest" "$(basename "$src")"
}

_print_functions_in_file() {
    local file="$1"
    grep -Eo '^\s*[a-z]\w+\s*\(\s*\)' "$file" | tr -d '[ \t\(\)]'
}
_print_functions() {
    local file="$1"
    (_print_functions_in_file "$file"; \
    grep -E '^\s*\.\s+' "$file" | awk '{$1 = ""; print $0}' | \
    while read i; do _print_functions "$(eval echo "$i")"; done) | \
    sort -u
}

_gen_pbuilderrc() {
    local distrib="$1"
    local pbuilderrc="$2"
    local ppa_depends="$(echo "$PPA_DEPENDS" | sed "s/#DISTRIB#/$distrib/g")"
    
    if [ -f "$DIR/.pbuilderrc" ]
    then
    	sed "s/#DISTRIB#/$distrib/g; s;#DEB_MIRROR#;$DEB_MIRROR;g; \
             s;#PPA_DEPENDS#;$ppa_depends;g" < "$DIR/.pbuilderrc" > "$pbuilderrc"
    else
cat << EOF > "$pbuilderrc"
ALLOWUNTRUSTED=yes
APTCACHEHARDLINK=no
BUILDRESULTUID=$SUDO_UID
OTHERMIRROR="deb $DEB_MIRROR $distrib main restricted universe multiverse|\
             deb $DEB_MIRROR $distrib-security main restricted universe multiverse|\
             deb $DEB_MIRROR $distrib-updates main restricted universe multiverse|\
             $ppa_depends"
EOF
    fi
}

_pbuild_create() {
    local distrib=$1
    local arch=$2
    local btgz="$BASETGZ_DIR/${distrib}_${arch}.tgz"
    local pbuilderrc="$BUILD_DIR/$distrib.pbuilderrc"
    
    [ -d "$BUILD_DIR" ] || mkdir -p "$BUILD_DIR"
    [ -d "$BASETGZ_DIR" ] || mkdir -p "$BASETGZ_DIR"
    [ -d "$APT_CACHE_DIR" ] || mkdir -p "$APT_CACHE_DIR"
    [ -d "$DISTRIBS_DEB_DIR" ] || mkdir -p "$DISTRIBS_DEB_DIR"

    if [ ! -f "$btgz" ]
    then
        echo "Creating base tarball: $btgz"
        _gen_pbuilderrc "$distrib" "$pbuilderrc"
        $SUDO pbuilder create --configfile "$pbuilderrc" --debootstrapopts --variant=buildd --basetgz "$btgz"\
              --distribution ${distrib} --architecture ${arch} \
              $PBUILDER_ARGS || ($RM -f "$btgz" && return 1)
    elif [ "$SKIP_UPDATE_BASE" != "true" ]
    then
        echo "Updating base tarball: $btgz"
        _gen_pbuilderrc "$distrib" "$pbuilderrc"
        $SUDO pbuilder update --configfile "$pbuilderrc" --basetgz "$btgz" $PBUILDER_ARGS
    fi
}

_pbuild_build() {
    local distrib=$1
    local arch=$2
    local btgz="$BASETGZ_DIR/${distrib}_${arch}.tgz"
    local pkgs=$(for i in $PACKAGES; do case $i in *~$distrib.dsc) echo $i;; esac; done)
    local pbuilderrc="$BUILD_DIR/$distrib.pbuilderrc"

    echo "Building packages: $pkgs"
    [ -d "$BUILD_DIR" ] || mkdir -p "$BUILD_DIR"
    [ -d "$DISTRIBS_DEB_DIR" ] || mkdir -p "$DISTRIBS_DEB_DIR"
    [ -d "$APT_CACHE_DIR" ] || mkdir -p "$APT_CACHE_DIR"

    _gen_pbuilderrc "$distrib" "$pbuilderrc"
    $SUDO pbuilder build --configfile "$pbuilderrc" --basetgz "$btgz" $PBUILDER_ARGS $pkgs
}

_cur_version() {
    local dist="$1"
    [ ! -z "$dist" ] || (echo "Distrib name is not specified" 1>&2; exit 1)
    local url="$(echo "$PPA_SOURCES" | sed "s/#DISTRIB#/$dist/")"
    local version="$(curl "$url" 2>/dev/null | gunzip 2>/dev/null | \
    grep "^Package: $PKG_NAME$" -A2 | grep '^Version: ' | awk '{print $2}')"
    ([ -z "$version" ] && echo "Unknown") || echo "${version%-*}"
}

# Print (and possibly generate) path to the deb directory for the specified 
# checkout directory and distrib.
_deb_dir() {
    echo "$DEB_DIR"
}
################################################################################
