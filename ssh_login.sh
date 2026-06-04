#!/usr/bin/env bash

set -o pipefail

DEFAULT_SSH_CONFIG_PATH="$HOME/.ssh/config"
SSH_CONFIG_PATH="${SSH_CONFIG_PATH:-$DEFAULT_SSH_CONFIG_PATH}"
LIST_ONLY=0
INITIAL_FILTER=""
LOCAL_USER="${USER:-}"

if [ -z "$LOCAL_USER" ]; then
    LOCAL_USER="$(id -un 2>/dev/null || printf "%s" "unknown")"
fi

HOSTS=()
PARSED_CONFIGS=()
DISPLAY_INDEXES=()
MATCH_INDEXES=()
HOST_USERS=()
HOST_NAMES=()
HOST_PORTS=()
HOST_KEYS=()
HOST_READY=()

usage() {
    printf "用法: %s [选项] [关键词]\n" "${0##*/}"
    printf "\n"
    printf "选项:\n"
    printf "  -c, --config PATH   指定 SSH config 文件，默认: %s\n" "$DEFAULT_SSH_CONFIG_PATH"
    printf "  -l, --list          只列出可用 Host，不发起连接\n"
    printf "  -h, --help          显示帮助\n"
    printf "\n"
    printf "交互中输入编号或字符实时筛选，方向键选择，回车连接，Esc/Ctrl-C 退出。\n"
}

die() {
    printf "错误: %s\n" "$*" >&2
    exit 1
}

expand_user_path() {
    local path="$1"
    local tilde_prefix="~/"

    case "$path" in
        "~")
            printf "%s\n" "$HOME"
            ;;
        "~/"*)
            printf "%s/%s\n" "$HOME" "${path#$tilde_prefix}"
            ;;
        *)
            printf "%s\n" "$path"
            ;;
    esac
}

display_path() {
    local path="$1"
    local home_prefix="$HOME/"

    case "$path" in
        "$HOME")
            printf "~"
            ;;
        "$HOME"/*)
            printf "~/%s" "${path#$home_prefix}"
            ;;
        *)
            printf "%s" "$path"
            ;;
    esac
}

config_already_parsed() {
    local file="$1"
    local parsed=""

    for parsed in "${PARSED_CONFIGS[@]}"; do
        [ "$parsed" = "$file" ] && return 0
    done
    return 1
}

add_host_alias() {
    local alias="$1"
    local host=""

    case "$alias" in
        ""|\!*|*\**|*\?*)
            return 0
            ;;
    esac

    for host in "${HOSTS[@]}"; do
        [ "$host" = "$alias" ] && return 0
    done

    HOSTS+=("$alias")
}

expand_include_pattern() {
    local pattern="$1"
    local base_dir="$2"
    local tilde_prefix="~/"

    case "$pattern" in
        "~")
            printf "%s\n" "$HOME"
            ;;
        "~/"*)
            printf "%s/%s\n" "$HOME" "${pattern#$tilde_prefix}"
            ;;
        /*)
            printf "%s\n" "$pattern"
            ;;
        *)
            printf "%s/%s\n" "${base_dir%/}" "$pattern"
            ;;
    esac
}

parse_include_pattern() {
    local raw_pattern="$1"
    local base_dir="$2"
    local depth="$3"
    local pattern=""
    local match=""
    local matched=0

    pattern="$(expand_include_pattern "$raw_pattern" "$base_dir")"

    while IFS= read -r match; do
        [ -f "$match" ] || continue
        matched=1
        parse_config_file "$match" "$depth"
    done < <(compgen -G "$pattern")

    if [ "$matched" -eq 0 ] && [ -f "$pattern" ]; then
        parse_config_file "$pattern" "$depth"
    fi
}

parse_config_file() {
    local file="$1"
    local depth="${2:-0}"
    local line=""
    local key=""
    local base_dir=""
    local i=0
    local -a fields=()

    [ "$depth" -gt 8 ] && return 0
    [ -r "$file" ] || return 0
    config_already_parsed "$file" && return 0

    PARSED_CONFIGS+=("$file")
    base_dir="${file%/*}"
    [ "$base_dir" = "$file" ] && base_dir="."

    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        fields=()
        read -r -a fields <<< "$line"
        [ "${#fields[@]}" -eq 0 ] && continue

        key="${fields[0]}"
        case "$key" in
            [Hh][Oo][Ss][Tt])
                for ((i = 1; i < ${#fields[@]}; i++)); do
                    add_host_alias "${fields[$i]}"
                done
                ;;
            [Ii][Nn][Cc][Ll][Uu][Dd][Ee])
                for ((i = 1; i < ${#fields[@]}; i++)); do
                    parse_include_pattern "${fields[$i]}" "$base_dir" "$((depth + 1))"
                done
                ;;
        esac
    done < "$file"
}

is_default_identity_file() {
    local path="$1"

    case "$path" in
        "$HOME/.ssh/id_rsa"|\
        "$HOME/.ssh/id_ecdsa"|\
        "$HOME/.ssh/id_ecdsa_sk"|\
        "$HOME/.ssh/id_ed25519"|\
        "$HOME/.ssh/id_ed25519_sk"|\
        "$HOME/.ssh/id_dsa"|\
        "$HOME/.ssh/id_xmss")
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

expand_identity_path() {
    local raw_path="$1"
    local host="$2"
    local path="$raw_path"
    local tilde_prefix="~/"

    path="${path%\"}"
    path="${path#\"}"
    path="${path//%d/$HOME}"
    path="${path//%u/$LOCAL_USER}"
    path="${path//%h/$host}"

    case "$path" in
        "~")
            printf "%s\n" "$HOME"
            ;;
        "~/"*)
            printf "%s/%s\n" "$HOME" "${path#$tilde_prefix}"
            ;;
        /*)
            printf "%s\n" "$path"
            ;;
        *)
            printf "%s/%s\n" "$HOME" "${path#./}"
            ;;
    esac
}

ssh_g_output() {
    local host="$1"

    if [ "$SSH_CONFIG_PATH" = "$DEFAULT_SSH_CONFIG_PATH" ]; then
        ssh -G "$host"
    else
        ssh -G -F "$SSH_CONFIG_PATH" "$host"
    fi
}

populate_effective_details() {
    local idx="$1"
    local host="${HOSTS[$idx]}"
    local output=""
    local line=""
    local key=""
    local value=""
    local rest=""
    local expanded=""
    local eff_user="$LOCAL_USER"
    local eff_hostname="$host"
    local eff_port="22"
    local eff_key=""
    local custom_key=""
    local custom_exists=0
    local default_key=""

    [ "${HOST_READY[$idx]+set}" = "set" ] && return 0

    if output="$(ssh_g_output "$host" 2>/dev/null)"; then
        while IFS= read -r line || [ -n "$line" ]; do
            [ -z "$line" ] && continue
            read -r key value <<< "$line"
            rest="${line#"$key"}"
            rest="${rest#"${rest%%[![:space:]]*}"}"

            case "$key" in
                user)
                    [ -n "$value" ] && eff_user="$value"
                    ;;
                hostname)
                    [ -n "$value" ] && eff_hostname="$value"
                    ;;
                port)
                    [ -n "$value" ] && eff_port="$value"
                    ;;
                identityfile)
                    [ -z "$rest" ] && continue
                    [ "$rest" = "none" ] && continue

                    expanded="$(expand_identity_path "$rest" "$host")"
                    if is_default_identity_file "$expanded"; then
                        if [ -z "$default_key" ] && [ -f "$expanded" ]; then
                            default_key="$expanded"
                        fi
                        continue
                    fi

                    if [ "$custom_exists" -eq 0 ]; then
                        [ -z "$custom_key" ] && custom_key="$expanded"
                        if [ -f "$expanded" ]; then
                            custom_key="$expanded"
                            custom_exists=1
                        fi
                    fi
                    ;;
            esac
        done <<< "$output"
    fi

    if [ "$custom_exists" -eq 1 ]; then
        eff_key="$(display_path "$custom_key")"
    elif [ -n "$custom_key" ]; then
        eff_key="缺失:$(display_path "$custom_key")"
    fi

    HOST_USERS[$idx]="$eff_user"
    HOST_NAMES[$idx]="$eff_hostname"
    HOST_PORTS[$idx]="$eff_port"
    HOST_KEYS[$idx]="$eff_key"
    HOST_READY[$idx]=1
}

build_display_indexes() {
    local filter="$1"
    local i=0

    DISPLAY_INDEXES=()

    if [[ "$filter" =~ ^[0-9]+$ ]] && [ "$filter" -ge 1 ] && [ "$filter" -le "${#HOSTS[@]}" ]; then
        DISPLAY_INDEXES+=("$((filter - 1))")
        return 0
    fi

    for ((i = 0; i < ${#HOSTS[@]}; i++)); do
        if [ -z "$filter" ] || [[ "${HOSTS[$i]}" == *"$filter"* ]]; then
            DISPLAY_INDEXES+=("$i")
        fi
    done
}

print_table() {
    local filter="$1"
    local row=0
    local idx=0

    if [ -n "$filter" ]; then
        printf "过滤关键词: %s\n\n" "$filter"
    fi

    printf "%-4s %-24s %-16s %-28s %-6s %s\n" "ID" "HOST" "USER" "HOSTNAME" "PORT" "KEY"
    printf "%-4s %-24s %-16s %-28s %-6s %s\n" "----" "----" "----" "--------" "----" "---"

    for ((row = 0; row < ${#DISPLAY_INDEXES[@]}; row++)); do
        idx="${DISPLAY_INDEXES[$row]}"
        populate_effective_details "$idx"
        printf "%-4s %-24.24s %-16.16s %-28.28s %-6.6s %s\n" \
            "$((idx + 1))" \
            "${HOSTS[$idx]}" \
            "${HOST_USERS[$idx]}" \
            "${HOST_NAMES[$idx]}" \
            "${HOST_PORTS[$idx]}" \
            "${HOST_KEYS[$idx]}"
    done
    printf "\n"
}

print_live_table() {
    local filter="$1"
    local selected_row="$2"
    local row=0
    local idx=0
    local marker=""

    printf "SSH 登录选择器\n"
    printf "筛选: %s\n" "${filter:-<全部>}"
    printf "操作: 输入编号或字符即筛选 | ↑/↓ 选择 | Enter 连接 | Backspace 删除 | Ctrl-U 清空 | Esc/Ctrl-C 退出\n\n"

    if [ "${#DISPLAY_INDEXES[@]}" -eq 0 ]; then
        printf "没有匹配项。\n"
        return 0
    fi

    printf "%-2s %-4s %-24s %-16s %-28s %-6s %s\n" "" "ID" "HOST" "USER" "HOSTNAME" "PORT" "KEY"
    printf "%-2s %-4s %-24s %-16s %-28s %-6s %s\n" "" "----" "----" "----" "--------" "----" "---"

    for ((row = 0; row < ${#DISPLAY_INDEXES[@]}; row++)); do
        idx="${DISPLAY_INDEXES[$row]}"
        populate_effective_details "$idx"
        marker=" "
        [ "$row" -eq "$selected_row" ] && marker=">"
        printf "%-2s %-4s %-24.24s %-16.16s %-28.28s %-6.6s %s\n" \
            "$marker" \
            "$((idx + 1))" \
            "${HOSTS[$idx]}" \
            "${HOST_USERS[$idx]}" \
            "${HOST_NAMES[$idx]}" \
            "${HOST_PORTS[$idx]}" \
            "${HOST_KEYS[$idx]}"
    done
}

clear_screen() {
    if command -v tput >/dev/null 2>&1 && [ -t 1 ] && [ -n "${TERM:-}" ] && [ "$TERM" != "dumb" ]; then
        tput clear
    else
        printf "\033[H\033[2J"
    fi
}

hide_cursor() {
    command -v tput >/dev/null 2>&1 && [ -t 1 ] && [ -n "${TERM:-}" ] && [ "$TERM" != "dumb" ] && tput civis
}

show_cursor() {
    command -v tput >/dev/null 2>&1 && [ -t 1 ] && [ -n "${TERM:-}" ] && [ "$TERM" != "dumb" ] && tput cnorm
}

resolve_choice() {
    local choice="$1"
    local row=0
    local idx=0
    local i=0

    if [[ "$choice" =~ ^[0-9]+$ ]]; then
        if [ "$choice" -ge 1 ] && [ "$choice" -le "${#HOSTS[@]}" ]; then
            printf "%s\n" "$((choice - 1))"
            return 0
        fi
        return 1
    fi

    for ((row = 0; row < ${#DISPLAY_INDEXES[@]}; row++)); do
        idx="${DISPLAY_INDEXES[$row]}"
        if [ "${HOSTS[$idx]}" = "$choice" ]; then
            printf "%s\n" "$idx"
            return 0
        fi
    done

    for ((i = 0; i < ${#HOSTS[@]}; i++)); do
        if [ "${HOSTS[$i]}" = "$choice" ]; then
            printf "%s\n" "$i"
            return 0
        fi
    done

    return 1
}

find_substring_matches() {
    local keyword="$1"
    local i=0

    MATCH_INDEXES=()
    [ -z "$keyword" ] && return 0

    for ((i = 0; i < ${#HOSTS[@]}; i++)); do
        if [[ "${HOSTS[$i]}" == *"$keyword"* ]]; then
            MATCH_INDEXES+=("$i")
        fi
    done
}

connect_host() {
    local host="$1"

    printf "正在连接: %s\n" "$host"

    if [ "$SSH_CONFIG_PATH" = "$DEFAULT_SSH_CONFIG_PATH" ]; then
        exec ssh "$host"
    else
        exec ssh -F "$SSH_CONFIG_PATH" "$host"
    fi
}

line_interactive_loop() {
    local filter="$1"
    local choice=""
    local idx=""

    while true; do
        build_display_indexes "$filter"
        if [ "${#DISPLAY_INDEXES[@]}" -eq 0 ]; then
            if [ -n "$filter" ]; then
                printf "没有匹配关键词的 Host: %s\n\n" "$filter"
                filter=""
                continue
            fi
            printf "未找到可用的 Host 配置。\n"
            return 1
        fi

        print_table "$filter"
        read -r -p "输入序号/Host，/关键词过滤，q 退出: " choice || return 1

        case "$choice" in
            "")
                continue
                ;;
            q|Q|quit|exit)
                return 0
                ;;
            /*)
                filter="${choice#/}"
                continue
                ;;
        esac

        if idx="$(resolve_choice "$choice")"; then
            connect_host "${HOSTS[$idx]}"
            return $?
        fi

        find_substring_matches "$choice"
        if [ "${#MATCH_INDEXES[@]}" -eq 1 ]; then
            connect_host "${HOSTS[${MATCH_INDEXES[0]}]}"
            return $?
        fi
        if [ "${#MATCH_INDEXES[@]}" -gt 1 ]; then
            filter="$choice"
            continue
        fi

        printf "无效输入，请重试。\n\n"
    done
}

interactive_loop() {
    local filter="$1"
    local key=""
    local next=""
    local selected_row=0
    local selected_idx=""

    if [ ! -t 0 ]; then
        line_interactive_loop "$filter"
        return $?
    fi

    hide_cursor
    trap 'show_cursor; printf "\n"; exit 130' INT
    trap 'show_cursor' EXIT

    while true; do
        build_display_indexes "$filter"
        if [ "${#DISPLAY_INDEXES[@]}" -eq 0 ]; then
            selected_row=0
        elif [ "$selected_row" -ge "${#DISPLAY_INDEXES[@]}" ]; then
            selected_row="$((${#DISPLAY_INDEXES[@]} - 1))"
        elif [ "$selected_row" -lt 0 ]; then
            selected_row=0
        fi

        clear_screen
        print_live_table "$filter" "$selected_row"

        IFS= read -rsn1 key || {
            show_cursor
            trap - INT EXIT
            return 1
        }

        case "$key" in
            "")
                if [ "${#DISPLAY_INDEXES[@]}" -gt 0 ]; then
                    selected_idx="${DISPLAY_INDEXES[$selected_row]}"
                    show_cursor
                    trap - INT EXIT
                    clear_screen
                    connect_host "${HOSTS[$selected_idx]}"
                    return $?
                fi
                ;;
            $'\033')
                IFS= read -rsn1 -t 0.01 next || next=""
                if [ "$next" = "[" ]; then
                    IFS= read -rsn1 -t 0.01 next || next=""
                    case "$next" in
                        A)
                            [ "$selected_row" -gt 0 ] && selected_row="$((selected_row - 1))"
                            ;;
                        B)
                            if [ "$selected_row" -lt "$((${#DISPLAY_INDEXES[@]} - 1))" ]; then
                                selected_row="$((selected_row + 1))"
                            fi
                            ;;
                    esac
                else
                    show_cursor
                    trap - INT EXIT
                    clear_screen
                    return 0
                fi
                ;;
            $'\177'|$'\b')
                if [ -n "$filter" ]; then
                    filter="${filter%?}"
                    selected_row=0
                fi
                ;;
            $'\025')
                filter=""
                selected_row=0
                ;;
            *)
                case "$key" in
                    [[:print:]])
                        filter="${filter}${key}"
                        selected_row=0
                        ;;
                esac
                ;;
        esac
    done
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            -l|--list)
                LIST_ONLY=1
                ;;
            -c|--config)
                shift
                [ "$#" -gt 0 ] || die "--config 需要路径"
                SSH_CONFIG_PATH="$1"
                ;;
            --config=*)
                SSH_CONFIG_PATH="${1#--config=}"
                ;;
            -*)
                die "未知选项: $1"
                ;;
            *)
                [ -z "$INITIAL_FILTER" ] || die "只支持一个关键词参数"
                INITIAL_FILTER="$1"
                ;;
        esac
        shift
    done
}

main() {
    parse_args "$@"
    SSH_CONFIG_PATH="$(expand_user_path "$SSH_CONFIG_PATH")"

    command -v ssh >/dev/null 2>&1 || die "找不到 ssh 命令"
    [ -r "$SSH_CONFIG_PATH" ] || die "找不到或无法读取 SSH 配置文件: $SSH_CONFIG_PATH"

    parse_config_file "$SSH_CONFIG_PATH" 0
    if [ "${#HOSTS[@]}" -eq 0 ]; then
        die "未找到可用的 Host 配置"
    fi

    build_display_indexes "$INITIAL_FILTER"
    if [ "$LIST_ONLY" -eq 1 ]; then
        if [ "${#DISPLAY_INDEXES[@]}" -eq 0 ]; then
            die "没有匹配关键词的 Host: $INITIAL_FILTER"
        fi
        print_table "$INITIAL_FILTER"
        exit 0
    fi

    interactive_loop "$INITIAL_FILTER"
}

main "$@"
