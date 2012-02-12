#!/bin/bash

curl=`which curl 2>/dev/null`
if [ $? -gt 0 ]; then
    wget=`which wget 2>/dev/null`
    if [ $? -gt 0 ]; then
        echo "need access to curl or wget."
        exit
    fi
    fetchCmd='wget -O '
else
    fetchCmd='curl -so '
fi

dirs='.vim/autoload .vim/bundle'
for dir in $dirs; do
    if [ -d ~/${dir} ]; then
        rm -rf ~/${dir}
    fi
    mkdir -p ~/${dir}
done

if [ -f ~/.vimrc ]; then
    rm -f ~/.vimrc
fi

cp -f ./vimrc ~/.vimrc

${fetchCmd} ~/.vim/autoload/pathogen.vim \
  https://raw.github.com/tpope/vim-pathogen/HEAD/autoload/pathogen.vim

git clone git://github.com/majutsushi/tagbar.git ~/.vim/bundle/tagbar

