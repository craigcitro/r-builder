#! /bin/bash

set -e
set -x

export PATH=/usr/local/bin:$PATH
export CRAN=http://cran.r-project.org
export roptions=""

# Detect OS
export OS=linux
if uname -a | grep -q Darwin; then
    export OS=osx
    roptions=--with-tcl-config=/usr/local/opt/tcl-tk/lib/tclConfig.sh \
	    --with-tk-config=/usr/local/opt/tcl-tk/lib/tkConfig.sh \
	    ${roptions}
fi

if [ "$DRONE" == "true" ]; then
    export CI="drone"
    export REPO_SLUG=$(echo "$DRONE_REPO_SLUG" | sed -s '/github\.com\///')
    export ADD_REPO="sudo add-apt-repository -y -s"
elif [ "$SEMAPHORE" == "true" ]; then
    export CI="semaphore"
    export REPO_SLUG="$SEMAPHORE_REPO_SLUG"
    export ADD_REPO="sudo add-apt-repository -y -s"
elif [ "$TRAVIS" == "true" ]; then
    export CI="travis"
    export REPO_SLUG="$TRAVIS_REPO_SLUG"
    export ADD_REPO="sudo add-apt-repository"
else
    echo "Unknown CI"
    exit 1
fi

if [ ! -f version ]; then
    echo "No version file, don't know what to build"
    exit 1
fi

version=$(cat version)

export tag=${CI}-${version}
export branch=${CI}_${version}

CheckDone() {
    if git fetch -q origin $tag 2>/dev/null; then
	echo "This R version was already built for this CI."
	echo "If you want to rebuild it, then remove its tag and branch"
	exit 0
    fi
}

GetGFortran() {
    curl -O ${CRAN}/bin/macosx/tools/gfortran-4.2.3.pkg
    sudo installer -pkg gfortran-4.2.3.pkg -target /
}

GetDeps() {
    if [ $OS == "osx" ]; then
	GetGFortran
    elif [ $OS == "linux" ]; then
	sudo apt-get clean
	sudo $ADD_REPO "deb ${CRAN}/bin/linux/ubuntu $(lsb_release -cs)/"
	sudo apt-key adv --keyserver keyserver.ubuntu.com --recv-keys E084DAB9
	(Retry sudo apt-get update) || true
	Retry sudo apt-get -y build-dep r-base
	Retry sudo apt-get -y install subversion ccache texlive \
	      texlive-fonts-extra texlive-latex-extra
    fi
    if [ $CI == "drone" ]; then
	sudo add-apt-repository ppa:git-core/ppa
	sudo apt-get update
	sudo apt-get install git
    fi
}

GetSource() {
    rm -rf R-${version} R-${version}.tar.gz
    major=$(echo $version | sed 's/\..*$//')
    url="${CRAN}/src/base/R-${major}/R-${version}.tar.gz"
    curl -O "$url"
    tar xzf "R-${version}.tar.gz"
}

GetDevelSource() {
    svn checkout --non-interactive \
	http://svn.r-project.org/R/trunk/ R-devel
}

GetRecommended() {
    (
	cd R-${version}
	Retry tools/rsync-recommended
    )
}

CreateInstDir() {
    sudo mkdir -p /opt/R/R-${version}
    sudo chown -R $(id -un):$(id -gn) /opt/R
}

Configure() {
    (
	cd R-${version}
	R_PAPERSIZE=letter                                       \
	R_BATCHSAVE="--no-save --no-restore"                     \
	PERL=/usr/bin/perl                                       \
	R_UNZIPCMD=/usr/bin/unzip                                \
	R_ZIPCMD=/usr/bin/zip                                    \
	R_PRINTCMD=/usr/bin/lpr                                  \
	AWK=/usr/bin/awk                                         \
	CFLAGS="-std=gnu99 -Wall -pedantic"                      \
	CXXFLAGS="-Wall -pedantic"                               \
	./configure                                              \
	--prefix=/opt/R/R-${version}
	${roptions}
    )
}

Make() {
    (
	cd R-${version}
	make
    )
}

Install() {
    (
	cd R-${version}
	make install
    )
}

Deploy() {
    (
	cd /tmp
	git config --global user.name "Gabor Csardi"
	git config --global user.email "csardi.gabor@gmail.com"
	git config --global push.default matching

	mkdir _deploy
	cd _deploy
	git init .
	git symbolic-ref HEAD refs/heads/${branch}
	cp -r /opt/R/R-${version} .
	git add -A .

	git remote add origin https://github.com/"${REPO_SLUG}"
	git remote set-branches --add origin ${branch}
	git config credential.helper "store --file=.git/credentials"
	python -c 'import os; print "https://" + os.environ["GH_TOKEN"] + ":@github.com"' > .git/credentials

	git commit -q --allow-empty -m "Building R ${version} on ${CI}"
	git tag -d ${tag} || true
	git tag ${tag}
	git push -f --tags -q origin ${branch}
    )
}

Retry() {
    if "$@"; then
        return 0
    fi
    for wait_time in 5 20 30 60; do
        echo "Command failed, retrying in ${wait_time} ..."
        sleep ${wait_time}
        if "$@"; then
            return 0
        fi
    done
    echo "Failed all retries!"
    exit 1
}

BuildVersion() {
    CheckDone
    GetDeps
    GetSource
    CreateInstDir
    Configure
    Make
    Install
    Deploy
}

BuildDevel() {
    GetDeps
    GetDevelSource
    GetRecommended
    CreateInstDir
    Configure
    Make
    Install
    Deploy
}

if [ "$version" == "devel" ]; then
    BuildDevel
else
    BuildVersion
fi
