# scripts

一组日常运维与性能测试的实用脚本，涵盖服务器初始化、用户管理、Shell 配置、磁盘/推理压测以及 SSH 登录等场景。

## 脚本一览

| 脚本 | 类型 | 用途 |
| --- | --- | --- |
| `create_sudouser.sh` | Bash | 创建带 SSH 公钥的 sudo 用户 |
| `set_zsh.sh` | Bash | 安装并切换默认 Shell 为 zsh |
| `setup_bashlog.sh` | Bash | 全局记录 bash/zsh 命令操作日志 |
| `setup_env.sh` | Bash | 初始化 evalscope 性能测试 Python 环境 |
| `disk_speed_test.sh` | Bash | 测试磁盘/NFS 读写速度 |
| `perf_random_dataset.py` | Python | 基于 evalscope 跑推理压测并导出 CSV/XLSX |
| `ssh_login.sh` | Bash | 交互式 SSH 登录选择器 |

---

## create_sudouser.sh

创建一个新用户，设置密码、写入 SSH 公钥并加入 `sudo` 组。需要 root 权限。

```bash
sudo ./create_sudouser.sh <username> <password> <pubkey-or-filepath> [--shell /bin/bash]
```

示例：

```bash
# 直接传入公钥字符串
sudo ./create_sudouser.sh alice 'MyPassw0rd!' "ssh-ed25519 AAAAC3..." --shell /bin/bash

# 传入公钥文件路径
sudo ./create_sudouser.sh devops '123456' ~/.ssh/id_ed25519.pub
```

- 第三个参数既可以是公钥内容，也可以是公钥文件路径，脚本会自动识别。
- 默认 Shell 为 `/bin/bash`，可用 `--shell` 覆盖。
- 用户已存在或公钥已写入时会自动跳过，可重复执行。
- 自动为 `~/.ssh` 设置正确权限（`700` / `600`）。

## set_zsh.sh

安装 `zsh git curl` 并将当前用户默认 Shell 切换为 zsh（基于 apt，适用于 Debian/Ubuntu）。

脚本以函数 `downloadzsh` 形式提供，使用时可直接 source 后调用：

```bash
source ./set_zsh.sh
downloadzsh
```

> 注意：`chsh` 在下次登录后生效。

## setup_bashlog.sh

配置全局 bash/zsh 命令日志，将所有用户的操作历史记录到 `/var/log/shell.log`，包含时间、用户、来源 IP、终端、退出码、历史编号与命令内容。需要 root 权限。

```bash
sudo ./setup_bashlog.sh
```

- 向 `/etc/bash.bashrc` 与全局 zsh 配置（`/etc/zsh/zshrc` 或 `/etc/zshrc`）注入日志钩子。
- 通过历史编号去重，避免同一命令重复记录。
- 自动配置 `logrotate`（每日轮转、保留 30 天、压缩）。
- 已有会话需重新登录后生效。

日志格式示例：

```
[2026-06-03 10:20:30] [USER:alice] [IP:192.168.1.10] [TTY:pts/0] [EXIT:0] [HIST:123] ls -la
```

## setup_env.sh

为 evalscope 性能测试初始化 Python 环境（面向 Ubuntu 22.04 LTS）。

```bash
./setup_env.sh
```

执行步骤：

1. 检查并为当前用户添加免密 sudo 权限。
2. 检查 Python 版本（要求 `>= 3.10`）。
3. 检查并安装 `virtualenv`。
4. 在 `~/perftest/venv/evalscope-py` 创建虚拟环境。
5. 使用清华镜像源安装依赖：`evalscope==1.0.1`、`uvicorn`、`fastapi`、`sse_starlette`、`openpyxl`、`jinja2`。
6. 校验 evalscope 版本为 `1.0.1`。

完成后激活环境：

```bash
source ~/perftest/venv/evalscope-py/bin/activate
```

## disk_speed_test.sh

使用 `dd` 对指定路径进行多轮读写速度测试，并输出平均值。适合测试本地磁盘或 NFS 挂载点。

```bash
bash disk_speed_test.sh [挂载路径] [测试文件大小GiB] [轮数]
```

示例：

```bash
bash disk_speed_test.sh /Volumes/data 8 3
```

参数默认值：路径 `/Volumes/data`、大小 `8` GiB、轮数 `3`。

- 写测试使用 `conv=fsync` 确保落盘。
- 测试文件在每轮结束及退出时自动清理。
- 测试 NFS 性能时，将路径改为 NFS 挂载点即可。

> 说明：脚本使用 `dd` 的 `bs=1m` 等 BSD 风格参数，适用于 macOS。

## perf_random_dataset.py

通过 [evalscope](https://github.com/modelscope/evalscope) 对 OpenAI 兼容的推理服务跑性能压测，遍历多组并发后将结果汇总导出为 CSV 与 XLSX。需先运行 `setup_env.sh` 准备环境。

```bash
python perf_random_dataset.py [选项]
```

常用选项：

| 选项 | 默认值 | 说明 |
| --- | --- | --- |
| `--ip` | `127.0.0.1` | 服务管理 IP |
| `--port` | `10011` | API 端口 |
| `--parallel` | `'1 4'` | 并发数列表，需用引号包裹 |
| `--number` | `'1 4'` | 请求数列表，需用引号包裹 |
| `--model` | `/mnt/shared/models/DeepSeek-R1-0528` | 模型名称/路径 |
| `--tokenizer-path` | 同 `--model` | tokenizer 路径 |
| `--api-key` | （内置示例） | API Key，从 AMaaS 上创建 |
| `--input-length` | `128` | 输入 token 长度 |
| `--output-length` | `512` | 输出 token 长度 |
| `--loop` | `1` | 测试轮数 |
| `--use-chat` | 关闭 | 使用 `/v1/chat/completions` 而非 `/v1/completions` |
| `--output-csv` | 时间戳 | 输出 CSV 文件名（不含后缀） |

示例：

```bash
python perf_random_dataset.py \
  --ip 127.0.0.1 --port 10011 \
  --parallel '1 4 8' --number '10 40 80' \
  --input-length 128 --output-length 512 \
  --loop 3 --output-csv my_bench
```

输出会在结果中额外计算「单轮次 Avg TPS」「单路吞吐」以及「所有轮次平均」等指标，同时生成同名的 `.csv` 与 `.xlsx`。

## ssh_login.sh

一个纯 Bash 实现的交互式 SSH 登录选择器，解析 `~/.ssh/config`（含 `Include`），展示 Host、用户、地址、端口与密钥信息，支持实时筛选与方向键选择。

```bash
./ssh_login.sh [选项] [关键词]
```

选项：

- `-c, --config PATH`：指定 SSH config 文件，默认 `~/.ssh/config`。
- `-l, --list`：只列出可用 Host，不发起连接。
- `-h, --help`：显示帮助。

交互操作：

- 输入编号或字符即可实时筛选。
- `↑/↓` 选择，`Enter` 连接。
- `Backspace` 删除筛选字符，`Ctrl-U` 清空。
- `Esc` / `Ctrl-C` 退出。

非交互终端下自动降级为按行输入模式。
