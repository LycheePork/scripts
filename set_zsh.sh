#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'


downloadzsh(){
    # 更新软件源
    sudo apt update && sudo apt upgrade -y
    # 安装 zsh git curl
    sudo apt install zsh git curl -y

    chsh -s /bin/zsh
}



